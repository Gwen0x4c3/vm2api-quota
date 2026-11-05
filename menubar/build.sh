#!/usr/bin/env bash
# build.sh — compile the VmQuotaBar menu-bar app (no Xcode project needed).
#   ./build.sh         -> bin/VmQuotaBar          (plain binary, run directly)
#   ./build.sh --app   -> bin/VmQuotaBar.app      (bundle; open with `open`)
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "ERROR: swiftc not found. Install Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi

mkdir -p bin
echo "compiling…"
swiftc -O -o bin/VmQuotaBar VmQuotaBar.swift
echo "built: bin/VmQuotaBar — run it with: ./bin/VmQuotaBar"

if [ "${1:-}" = "--app" ]; then
  APP=bin/VmQuotaBar.app
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS"
  cp bin/VmQuotaBar "$APP/Contents/MacOS/VmQuotaBar"
  cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>VmQuotaBar</string>
  <key>CFBundleIdentifier</key><string>com.gwen.vmquotabar</string>
  <key>CFBundleName</key><string>VmQuotaBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
  echo "built: $APP — launch with: open $APP"
fi
