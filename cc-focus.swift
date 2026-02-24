import AppKit
import Foundation

// MARK: - Data Model

enum SessionStatus: String {
    case working
    case needsInput
}

struct ClaudeSession {
    let sessionId: String
    var cwd: String
    var status: SessionStatus
    var lastEvent: Date
    var needsInputSince: Date?
}

struct HookEvent: Codable {
    let event_type: String
    let session_id: String?
    let cwd: String?
    let transcript_path: String?
    let source: String?

    /// Extract session ID, falling back to parsing it from transcript_path
    var resolvedSessionId: String? {
        if let sid = session_id, !sid.isEmpty { return sid }
        // transcript_path looks like: .../<session-uuid>.jsonl
        if let path = transcript_path {
            let filename = (path as NSString).lastPathComponent
            if filename.hasSuffix(".jsonl") {
                return String(filename.dropLast(6)) // remove .jsonl
            }
        }
        return nil
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var sessions: [String: ClaudeSession] = [:]
    private var serverSocket: Int32 = -1
    private var readSources: [Int32: DispatchSourceRead] = [:]
    private var cleanupTimer: Timer?
    private var receiveBuffers: [Int32: Data] = [:]

    private let socketPath = "/tmp/cc-focus-501.sock"

    func applicationDidFinishLaunching(_ notification: Notification) {
        startSocketListener()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.cleanupStaleSessions()
        }
        updateStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanupSocket()
    }

    // MARK: - Socket Listener

    private func startSocketListener() {
        // Remove stale socket file
        unlink(socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            NSLog("cc-focus: Failed to create socket")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr)
            raw.copyMemory(from: Array(pathBytes), byteCount: pathBytes.count)
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(serverSocket, sockPtr, addrLen)
            }
        }

        guard bindResult == 0 else {
            NSLog("cc-focus: Failed to bind socket: \(String(cString: strerror(errno)))")
            close(serverSocket)
            serverSocket = -1
            return
        }

        // Allow all users to write to socket (for hook scripts)
        chmod(socketPath, 0o777)

        guard listen(serverSocket, 5) == 0 else {
            NSLog("cc-focus: Failed to listen on socket")
            close(serverSocket)
            serverSocket = -1
            return
        }

        // Set non-blocking
        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: .main)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
            }
        }
        source.resume()

        // Store as a read source so it stays alive
        readSources[-1] = source
    }

    private func acceptConnection() {
        var clientAddr = sockaddr_un()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(serverSocket, sockPtr, &clientAddrLen)
            }
        }

        guard clientFd >= 0 else { return }

        // Set non-blocking on client socket
        let flags = fcntl(clientFd, F_GETFL)
        _ = fcntl(clientFd, F_SETFL, flags | O_NONBLOCK)

        receiveBuffers[clientFd] = Data()

        let source = DispatchSource.makeReadSource(fileDescriptor: clientFd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.readFromClient(fd: clientFd)
        }
        source.setCancelHandler { [weak self] in
            self?.receiveBuffers.removeValue(forKey: clientFd)
            self?.readSources.removeValue(forKey: clientFd)
            close(clientFd)
        }
        source.resume()
        readSources[clientFd] = source
    }

    private func readFromClient(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(fd, &buffer, buffer.count)

        if bytesRead > 0 {
            receiveBuffers[fd]?.append(contentsOf: buffer[0..<bytesRead])
        }

        if bytesRead <= 0 {
            // Connection closed or error - process buffered data
            if let data = receiveBuffers[fd], !data.isEmpty {
                processData(data)
            }
            readSources[fd]?.cancel()
            return
        }

        // Also try to process complete lines in the buffer
        if let data = receiveBuffers[fd],
           let str = String(data: data, encoding: .utf8),
           str.contains("\n") {
            let lines = str.components(separatedBy: "\n")
            for line in lines where !line.isEmpty {
                if let lineData = line.data(using: .utf8) {
                    processData(lineData)
                }
            }
            receiveBuffers[fd] = Data()
        }
    }

    private func processData(_ data: Data) {
        guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
            return
        }
        handleEvent(event)
    }

    private func cleanupSocket() {
        for (fd, source) in readSources {
            source.cancel()
            if fd != -1 {
                // -1 is our server socket, handled by cancel handler
            }
        }
        readSources.removeAll()
        receiveBuffers.removeAll()
        unlink(socketPath)
    }

    // MARK: - State Machine

    private func handleEvent(_ event: HookEvent) {
        let eventType = event.event_type
        guard let sessionId = event.resolvedSessionId else { return }

        NSLog("cc-focus: event=%@ session=%@ cwd=%@", eventType, sessionId, event.cwd ?? "(nil)")

        if eventType == "session_end" {
            sessions.removeValue(forKey: sessionId)
            updateStatusItem()
            return
        }

        // When a session is resumed, Claude fires two session_starts:
        // one "startup" (new wrapper) then one "resume" (the real session).
        // The "startup" session never gets a session_end, so when we see
        // a "resume", remove any other session with the same cwd that
        // started in the last few seconds (the orphaned wrapper).
        if eventType == "session_start" && event.source == "resume" {
            let now = Date()
            let orphanKeys = sessions.filter { (key, sess) in
                key != sessionId &&
                sess.cwd == (event.cwd ?? "") &&
                now.timeIntervalSince(sess.lastEvent) < 5
            }.map { $0.key }
            for key in orphanKeys {
                sessions.removeValue(forKey: key)
            }
        }

        let status: SessionStatus
        switch eventType {
        case "session_start", "user_prompt", "pre_tool_use":
            status = .working
        case "stop", "idle_prompt", "permission_prompt":
            status = .needsInput
        default:
            status = .working
        }

        if var session = sessions[sessionId] {
            if status == .needsInput && session.status != .needsInput {
                session.needsInputSince = Date()
            } else if status == .working {
                session.needsInputSince = nil
            }
            session.status = status
            session.lastEvent = Date()
            if let cwd = event.cwd, !cwd.isEmpty {
                session.cwd = cwd
            }
            sessions[sessionId] = session
        } else {
            sessions[sessionId] = ClaudeSession(
                sessionId: sessionId,
                cwd: event.cwd ?? "unknown",
                status: status,
                lastEvent: Date(),
                needsInputSince: status == .needsInput ? Date() : nil
            )
        }

        updateStatusItem()
    }

    // MARK: - Cleanup

    private func cleanupStaleSessions() {
        let cutoff = Date().addingTimeInterval(-180) // 3 minutes
        let staleKeys = sessions.filter { $0.value.lastEvent < cutoff }.map { $0.key }
        for key in staleKeys {
            sessions.removeValue(forKey: key)
        }
        if !staleKeys.isEmpty {
            updateStatusItem()
        }
    }

    // MARK: - Status Item UI

    private func updateStatusItem() {
        if sessions.isEmpty {
            if statusItem != nil {
                NSStatusBar.system.removeStatusItem(statusItem!)
                statusItem = nil
            }
            return
        }

        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        }

        let anyNeedsInput = sessions.values.contains { $0.status == .needsInput }
        let color: NSColor = anyNeedsInput ? .systemRed : .systemGreen

        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let circleDiameter: CGFloat = 16
            let circleRect = NSRect(
                x: (rect.width - circleDiameter) / 2,
                y: (rect.height - circleDiameter) / 2,
                width: circleDiameter,
                height: circleDiameter
            )
            color.setFill()
            NSBezierPath(ovalIn: circleRect).fill()
            return true
        }
        image.isTemplate = false

        statusItem?.button?.image = image
        statusItem?.button?.toolTip = anyNeedsInput ? "Claude: needs input" : "Claude: working"

        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        populateMenu(menu)
        statusItem?.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        populateMenu(menu)
    }

    private func populateMenu(_ menu: NSMenu) {
        // Sort: red (needsInput) first, then green (working)
        let sorted = sessions.values.sorted { a, b in
            if a.status == .needsInput && b.status != .needsInput { return true }
            if a.status != .needsInput && b.status == .needsInput { return false }
            return a.cwd < b.cwd
        }

        for session in sorted {
            let dot = session.status == .needsInput ? "\u{1F534}" : "\u{1F7E2}"
            let shortCwd = shortenPath(session.cwd)
            var title = "\(dot) \(shortCwd)"
            if session.status == .needsInput, let since = session.needsInputSince {
                let elapsed = Int(Date().timeIntervalSince(since))
                let minutes = elapsed / 60
                let seconds = elapsed % 60
                if minutes > 0 {
                    title += " — Idle for \(minutes)m \(seconds)s"
                } else {
                    title += " — Idle for \(seconds)s"
                }
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var shortened = path
        if shortened.hasPrefix(home) {
            shortened = "~" + shortened.dropFirst(home.count)
        }
        // Show last 2 path components if long
        let components = shortened.components(separatedBy: "/").filter { !$0.isEmpty }
        if components.count > 3 {
            return ".../" + components.suffix(2).joined(separator: "/")
        }
        return shortened
    }
}

// MARK: - Main Entry Point

// Prevent multiple instances
let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mflower.cc-focus")
if runningApps.count > 1 {
    NSLog("cc-focus: Another instance is already running, exiting.")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
