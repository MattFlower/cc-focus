import AppKit
import Foundation

// MARK: - Version (injected by build.sh, or default)

let ccFocusVersion = "dev"

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
    var pid: Int?
}

struct HookEvent: Codable {
    let event_type: String
    let session_id: String?
    let cwd: String?
    let transcript_path: String?
    let source: String?
    let pid: Int?

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

    private let socketPath = "/tmp/cc-focus-\(getuid()).sock"
    private let pidPath = "/tmp/cc-focus-\(getuid()).pid"

    func applicationDidFinishLaunching(_ notification: Notification) {
        startSocketListener()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.cleanupStaleSessions()
        }
        updateStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanupSocket()
        unlink(pidPath)
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
            if let pid = event.pid {
                session.pid = pid
            }
            sessions[sessionId] = session
        } else {
            sessions[sessionId] = ClaudeSession(
                sessionId: sessionId,
                cwd: event.cwd ?? "unknown",
                status: status,
                lastEvent: Date(),
                needsInputSince: status == .needsInput ? Date() : nil,
                pid: event.pid
            )
        }

        updateStatusItem()
    }

    // MARK: - Cleanup

    private func cleanupStaleSessions() {
        // Remove sessions whose Claude Code process is no longer running.
        let deadKeys = sessions.filter { (_, sess) in
            guard let pid = sess.pid else { return false }
            return kill(Int32(pid), 0) != 0 // signal 0 = check if process exists
        }.map { $0.key }
        for key in deadKeys {
            sessions.removeValue(forKey: key)
        }
        if !deadKeys.isEmpty {
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
        // Version header
        let versionItem = NSMenuItem(title: "cc-focus \(ccFocusVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let copyItem = NSMenuItem(title: "Copy to clipboard", action: #selector(copyVersionToClipboard), keyEquivalent: "c")
        menu.addItem(copyItem)

        menu.addItem(.separator())

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
            let item = NSMenuItem(title: title, action: #selector(switchToSession(_:)), keyEquivalent: "")
            item.representedObject = session.sessionId
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func copyVersionToClipboard(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("cc-focus \(ccFocusVersion)", forType: .string)
    }

    // MARK: - Terminal Switching

    private func debugLog(_ msg: String) {
        let entry = "\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)) \(msg)\n"
        let path = "/tmp/cc-focus-debug.log"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(entry.data(using: .utf8)!)
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: entry.data(using: .utf8))
        }
    }

    @objc func switchToSession(_ sender: NSMenuItem) {
        debugLog("switchToSession called")
        guard let sessionId = sender.representedObject as? String else {
            debugLog("no sessionId in representedObject")
            return
        }
        guard let session = sessions[sessionId] else {
            debugLog("session not found for id=\(sessionId)")
            return
        }
        guard let pid = session.pid else {
            debugLog("no pid for session \(sessionId)")
            return
        }
        debugLog("switching to session=\(sessionId) pid=\(pid)")
        activateTerminalForPID(pid)
    }

    private func activateTerminalForPID(_ pid: Int) {
        guard let tty = getTTYForPID(pid) else {
            debugLog("no TTY for pid \(pid), using fallback")
            activateTerminalAppForPID(pid)
            return
        }
        debugLog("pid \(pid) -> tty \(tty)")

        // Try iTerm2
        let iterm = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2").isEmpty
        debugLog("iTerm2 running=\(iterm)")
        if iterm {
            if activateITermTab(tty: tty) { return }
            debugLog("iTerm2 AppleScript did not match")
        }

        // Try Terminal.app
        let terminal = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty
        debugLog("Terminal.app running=\(terminal)")
        if terminal {
            if activateTerminalTab(tty: tty) { return }
            debugLog("Terminal.app AppleScript did not match")
        }

        // Fallback: activate the terminal app that owns this process
        debugLog("falling back to process tree walk")
        activateTerminalAppForPID(pid)
    }

    private func getTTYForPID(_ pid: Int) -> String? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "tty=", "-p", "\(pid)"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let ttyShort = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !ttyShort.isEmpty, ttyShort != "??" else { return nil }
        return "/dev/tty\(ttyShort)"
    }

    private func activateITermTab(tty: String) -> Bool {
        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            tell t to select
                            tell w to select
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
        return runAppleScript(script)
    }

    private func activateTerminalTab(tty: String) -> Bool {
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
        return runAppleScript(script)
    }

    private func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            debugLog("failed to create NSAppleScript")
            return false
        }
        let result = script.executeAndReturnError(&error)
        if let error = error {
            debugLog("AppleScript error: \(error)")
            return false
        }
        debugLog("AppleScript result: \(result.description)")
        return result.booleanValue
    }

    private func activateTerminalAppForPID(_ pid: Int) {
        let runningApps = NSWorkspace.shared.runningApplications
        var currentPID = pid

        while currentPID > 1 {
            if let app = runningApps.first(where: { $0.processIdentifier == Int32(currentPID) }) {
                app.activate(options: [.activateAllWindows])
                return
            }
            guard let ppid = getParentPID(currentPID) else { break }
            currentPID = ppid
        }
    }

    private func getParentPID(_ pid: Int) -> Int? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "ppid=", "-p", "\(pid)"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let ppidStr = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let ppid = Int(ppidStr), ppid > 0, ppid != pid else { return nil }
        return ppid
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

// Prevent multiple instances via PID file
let pidPath = "/tmp/cc-focus-\(getuid()).pid"
if let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8),
   let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
   kill(pid, 0) == 0 {
    NSLog("cc-focus: Another instance already running (PID %d)", pid)
    exit(0)
}
try? "\(ProcessInfo.processInfo.processIdentifier)".write(
    toFile: pidPath, atomically: true, encoding: .utf8)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
