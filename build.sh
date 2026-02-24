#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Compiling cc-focus.swift..."
swiftc cc-focus.swift -o cc-focus -framework AppKit -swift-version 5 -O

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
echo "To test: echo '{\"event_type\":\"session_start\",\"session_id\":\"test1\",\"cwd\":\"/tmp/test\"}' | nc -U /tmp/cc-focus-501.sock"
