#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Compiling cc-focus.swift..."

# Inject version from git tag (e.g. "v0.1.0" or "v0.1.0-3-gabcdef")
GIT_VERSION=$(git describe --tags --always 2>/dev/null || echo "dev")
SHORT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
VERSION_STRING="${GIT_VERSION} ${SHORT_HASH}"

# Patch version into a temp copy and compile that
TEMP_SWIFT=$(mktemp /tmp/cc-focus-build.XXXXXX.swift)
sed "s|let ccFocusVersion = \"dev\"|let ccFocusVersion = \"${VERSION_STRING}\"|" cc-focus.swift > "$TEMP_SWIFT"
swiftc "$TEMP_SWIFT" -o cc-focus -framework AppKit -swift-version 5 -O
rm -f "$TEMP_SWIFT"

echo "Creating app bundle..."
rm -rf cc-focus.app
mkdir -p cc-focus.app/Contents/MacOS
mkdir -p cc-focus.app/Contents/Resources

cp cc-focus cc-focus.app/Contents/MacOS/cc-focus
cp Info.plist cc-focus.app/Contents/Info.plist

chmod +x cc-focus-hook.sh

echo "Build complete: cc-focus.app"
echo ""
echo "To run:  open cc-focus.app"
echo "To test: echo '{\"event_type\":\"session_start\",\"session_id\":\"test1\",\"cwd\":\"/tmp/test\"}' | nc -U /tmp/cc-focus-\$(id -u).sock"
