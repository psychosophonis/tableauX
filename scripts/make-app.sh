#!/usr/bin/env bash
# Builds "tableauX.app" and a zip of it to hand out (GitHub release).
#
# `swift build` makes a bare executable. A Mac app is a BUNDLE: a folder with a
# fixed layout (Contents/MacOS/<binary>, Contents/Info.plist) that Finder shows
# as one double-clickable icon. Info.plist is what tells macOS the app's name,
# identifier and minimum OS. Building the bundle from the SwiftPM binary keeps
# the project free of an Xcode project file.
#
# The binary is UNIVERSAL (Apple silicon + Intel in one file), because the lab
# Mac mini's chip is unknown and the cost is only a larger download.
#
# Signing is AD-HOC (`codesign -s -`): a signature with no developer identity.
# It satisfies macOS's rule that code be signed, but the app isn't notarised by
# Apple, so the first launch on another Mac needs System Settings → Privacy &
# Security → Open Anyway (see README.md).
#
# Usage: scripts/make-app.sh [version]     e.g. scripts/make-app.sh 0.1.0
# Output: dist/tableauX.app and dist/tableauX-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-0.0.0}"
name="tableauX"                 # app name, binary name and process name
app="dist/${name}.app"

swift build -c release --arch arm64 --arch x86_64
bin=".build/apple/Products/Release/${name}"

rm -rf dist && mkdir -p "${app}/Contents/MacOS"
cp "$bin" "${app}/Contents/MacOS/${name}"
cat > "${app}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>${name}</string>
  <key>CFBundleDisplayName</key>        <string>${name}</string>
  <key>CFBundleIdentifier</key>         <string>com.psychosophonis.tableaux</string>
  <key>CFBundleExecutable</key>         <string>${name}</string>
  <key>CFBundlePackageType</key>        <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>${version}</string>
  <key>CFBundleVersion</key>            <string>${version}</string>
  <key>LSMinimumSystemVersion</key>     <string>13.0</string>
  <key>NSHighResolutionCapable</key>    <true/>
  <!-- [claude] v3: macOS asks before an app may reach other devices on the
       local network; this is the reason the prompt shows. -->
  <key>NSLocalNetworkUsageDescription</key>
  <string>tableauX keeps its clock in step with the other Macs playing the same show.</string>
</dict>
</plist>
EOF

codesign --force --sign - "$app"
# ditto, not zip: it keeps the bundle's metadata and code signature intact.
ditto -c -k --keepParent "$app" "dist/${name}-${version}.zip"
echo "built ${app} ($(lipo -archs "${app}/Contents/MacOS/${name}"))"
echo "zipped dist/${name}-${version}.zip"
