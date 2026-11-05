#!/usr/bin/env bash
# build.sh — compile the VmQuotaBar menu-bar app (no Xcode project needed).
#   ./build.sh                  -> bin/VmQuotaBar          (native arch binary)
#   ./build.sh --app            -> bin/VmQuotaBar.app      (bundle for this arch)
#   ./build.sh --app --universal-> bin/VmQuotaBar.app      (Intel + Apple Silicon)
#   ./build.sh --app --zip      -> bin/VmQuotaBar-<ver>.zip (shareable archive)
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "ERROR: swiftc not found. Install Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi

APP=0; UNIVERSAL=0; ZIP=0
for arg in "$@"; do
  case "$arg" in
    --app) APP=1 ;;
    --universal) UNIVERSAL=1 ;;
    --zip) ZIP=1 ;;
  esac
done

mkdir -p bin
if [ "$UNIVERSAL" = "1" ]; then
  echo "compiling (universal: arm64 + x86_64)…"
  swiftc -O -target arm64-apple-macos13.0 -o bin/VmQuotaBar-arm64 VmQuotaBar.swift
  swiftc -O -target x86_64-apple-macos13.0 -o bin/VmQuotaBar-x86_64 VmQuotaBar.swift
  lipo -create -output bin/VmQuotaBar bin/VmQuotaBar-arm64 bin/VmQuotaBar-x86_64
  rm -f bin/VmQuotaBar-arm64 bin/VmQuotaBar-x86_64
else
  echo "compiling…"
  swiftc -O -o bin/VmQuotaBar VmQuotaBar.swift
fi
echo "built: bin/VmQuotaBar — run it with: ./bin/VmQuotaBar"

if [ "$APP" = "1" ]; then
  rm -rf bin/VmQuotaBar.app
  mkdir -p bin/VmQuotaBar.app/Contents/MacOS
  cp bin/VmQuotaBar bin/VmQuotaBar.app/Contents/MacOS/VmQuotaBar
  cat > bin/VmQuotaBar.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>VmQuotaBar</string>
  <key>CFBundleIdentifier</key><string>com.gwen.vmquotabar</string>
  <key>CFBundleName</key><string>VmQuotaBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
  echo "built: bin/VmQuotaBar.app — launch with: open bin/VmQuotaBar.app"
  if [ "$ZIP" = "1" ]; then
    VER=$(sed -n 's/.*version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' ../vm2api-quota/.zcode-plugin/plugin.json | head -1)
    [ -n "$VER" ] || VER=dev
    ditto -c -k --keepParent bin/VmQuotaBar.app "bin/VmQuotaBar-${VER}.zip"
    echo "archived: bin/VmQuotaBar-${VER}.zip — send this file to colleagues"
  fi
fi
