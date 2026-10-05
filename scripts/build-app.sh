#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox -c release
APP="$PWD/dist/Context.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Replace the binary atomically so a copy that's still running isn't corrupted mid-flight.
cp .build/release/Context "$APP/Contents/MacOS/Context.new"
mv -f "$APP/Contents/MacOS/Context.new" "$APP/Contents/MacOS/Context"
swift scripts/make-icon.swift "$PWD/.build/Context.iconset"
python3 scripts/pack-icon.py .build/Context.iconset "$APP/Contents/Resources/Context.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Context</string>
<key>CFBundleDisplayName</key><string>Context</string>
<key>CFBundleIdentifier</key><string>local.context.workspace</string>
<key>CFBundleExecutable</key><string>Context</string>
<key>CFBundleIconFile</key><string>Context</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.5.0</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Personal local workspace</string>
<key>NSDocumentsFolderUsageDescription</key><string>Context shows files from folders you connect to a project. It only reads them.</string>
<key>NSDesktopFolderUsageDescription</key><string>Context shows files from folders you connect to a project. It only reads them.</string>
<key>NSDownloadsFolderUsageDescription</key><string>Context shows files from folders you connect to a project. It only reads them.</string>
<key>NSRemovableVolumesUsageDescription</key><string>Context shows files from connected folders on external drives. It only reads them.</string>
<key>NSNetworkVolumesUsageDescription</key><string>Context shows files from connected folders on network drives. It only reads them.</string>
<key>NSFileProviderDomainUsageDescription</key><string>Context saves its backups into the cloud folder you choose (Google Drive, iCloud Drive, OneDrive, or Dropbox).</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built: $APP"

# `zsh scripts/build-app.sh --install` also replaces /Applications/Context.app (quitting the running copy first).
if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'tell application id "local.context.workspace" to quit' >/dev/null 2>&1 || true
  sleep 2
  rm -rf /Applications/Context.app.new
  ditto "$APP" /Applications/Context.app.new
  rm -rf /Applications/Context.app
  mv /Applications/Context.app.new /Applications/Context.app
  echo "Installed: /Applications/Context.app"
  open /Applications/Context.app
fi
