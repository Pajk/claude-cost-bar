#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."
swift build -c release --disable-sandbox

app="${PWD}/dist/Claude Cost Bar.app"
mkdir -p "${app}/Contents/MacOS"
cp .build/release/ClaudeCostBar "${app}/Contents/MacOS/ClaudeCostBar"
cat > "${app}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claude Cost Bar</string>
  <key>CFBundleDisplayName</key><string>Claude Cost Bar</string>
  <key>CFBundleIdentifier</key><string>dev.local.ClaudeCostBar</string>
  <key>CFBundleExecutable</key><string>ClaudeCostBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
printf 'APPL????' > "${app}/Contents/PkgInfo"
codesign --force --sign - "${app}"
echo "Built ${app}"
