#!/bin/bash
# Shows the native continuity fixture windows for the coordinated live QA (README.md in this folder). Never unattended.
#
# The fixture is the disposable receiving app (bundle id dev.pi-os.input-fixture, like host-macos/scripts/test-native.py):
# it requests no permission, runs nothing, deletes nothing (its Delete button only counts) and writes counts, never
# values, to the state file it prints. Ctrl-D (EOF on stdin) quits it; Ctrl-C stops this exact process.
set -euo pipefail
if [[ "${PI_OS_CONTINUITY_QA:-}" != 1 ]]; then
    echo "Live QA only: agree a window with Tom, check README.md preconditions, then set PI_OS_CONTINUITY_QA=1." >&2
    exit 64
fi
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
swift build --package-path "$ROOT/host-macos" --product pi-os-input-fixture
"$ROOT/host-macos/.build/debug/pi-os-input-fixture" --self-test
WORK="$(mktemp -d -t pi-os-continuity-fixture)"
APP="$WORK/Input Fixture.app"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/host-macos/.build/debug/pi-os-input-fixture" "$APP/Contents/MacOS/fixture"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.pi-os.input-fixture</string>
    <key>CFBundleExecutable</key><string>fixture</string>
    <key>CFBundleName</key><string>pi-os input fixture</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
# Ad hoc signing of this receiving fixture only (as test-native.py does); it holds no TCC grant. Never pi-os itself.
codesign --force --sign - "$APP"
echo "Continuity fixture state (counts only): $WORK/state.json"
echo "Commands on stdin, one JSON object per line, e.g. {\"command\":\"focus\",\"field\":\"search\"} or {\"command\":\"reset\"}."
exec "$APP/Contents/MacOS/fixture" "$WORK/state.json" --continuity
