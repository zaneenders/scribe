#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/main.swift" <<'SWIFT'
import Foundation
import Darwin
try AppConsoleLog.start()
print("client fps test")
AppConsoleLog.event("server connection test")
let child = Process()
child.executableURL = URL(fileURLWithPath: "/bin/sh")
child.arguments = ["-c", "echo backend-test >&2; printf '12345\\n'"]
let readiness = Pipe()
child.standardOutput = readiness
child.standardError = FileHandle.standardError
try child.run()
try readiness.fileHandleForWriting.close()
let data = readiness.fileHandleForReading.readDataToEndOfFile()
child.waitUntilExit()
precondition(String(data: data, encoding: .utf8) == "12345\n")
SWIFT
swiftc "$root/Sources/ScribeMacApp/AppConsoleLog.swift" "$tmp/main.swift" -o "$tmp/check"
SCRIBE_HOME="$tmp/home" "$tmp/check"
SCRIBE_HOME="$tmp/home" "$tmp/check"
log="$tmp/home/logs/remote-$(date +%y-%m-%d).log"
test "$(grep -c 'client fps test' "$log")" = 2
test "$(grep -c 'server connection test' "$log")" = 2
test "$(grep -c 'backend-test' "$log")" = 2
! grep -q '12345' "$log"
test "$(stat -f %Lp "$log")" = 600
printf 'PASS: stdout/stderr capture, append, child stderr, private readiness pipe, permissions\n'
