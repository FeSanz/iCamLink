#!/usr/bin/env bash
# Builds dist/iCamLink.app (Apple Silicon / arm64) with libvlc bundled, plus dist/iCamLink-<version>-macos-arm64.zip.
# Needs only the Xcode Command Line Tools. The first run downloads the official VLC arm64 disk image
# into vendor/ to take libvlc and its plugins from it.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.2.0}"
VLC_VERSION="${VLC_VERSION:-3.0.24}"
VLC_URL="https://download.videolan.org/vlc/${VLC_VERSION}/macosx/vlc-${VLC_VERSION}-arm64.dmg"
APP="dist/iCamLink.app"

# The macOS 27 SDK needs Xcode's SwiftUI macro plugins; the 26.x SDK builds with the CLT alone.
if [ -z "${SDKROOT:-}" ] && ! xcodebuild -version >/dev/null 2>&1; then
  SDKROOT="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1 || true)"
  [ -n "$SDKROOT" ] && export SDKROOT
fi

echo "==> swift build (release, arm64)"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/ICamLink"

if [ ! -f vendor/libvlc/libvlc.dylib ]; then
  echo "==> fetching libvlc from VLC ${VLC_VERSION}"
  mkdir -p vendor
  [ -f vendor/vlc.dmg ] || curl -fL -o vendor/vlc.dmg "$VLC_URL"
  MNT="$(mktemp -d)"
  hdiutil attach vendor/vlc.dmg -mountpoint "$MNT" -nobrowse -quiet
  trap 'hdiutil detach "$MNT" -quiet || true' EXIT
  rm -rf vendor/libvlc vendor/plugins
  mkdir -p vendor/libvlc
  cp -a "$MNT/VLC.app/Contents/MacOS/lib/libvlc.5.dylib" "$MNT/VLC.app/Contents/MacOS/lib/libvlccore.9.dylib" vendor/libvlc/
  cp -a "$MNT/VLC.app/Contents/MacOS/plugins" vendor/plugins
  cp -a "$MNT/VLC.app/Contents/MacOS/share" vendor/share 2>/dev/null || true
  hdiutil detach "$MNT" -quiet; trap - EXIT
  ln -sf libvlc.5.dylib vendor/libvlc/libvlc.dylib
  ln -sf libvlccore.9.dylib vendor/libvlc/libvlccore.dylib
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/vlc"
cp "$BIN" "$APP/Contents/MacOS/ICamLink"
cp -a vendor/libvlc/. "$APP/Contents/Frameworks/"
cp -a vendor/plugins "$APP/Contents/Resources/vlc/plugins"
install_name_tool -add_rpath @loader_path "$APP/Contents/Frameworks/libvlc.5.dylib" 2>/dev/null || true

# Icon from the shared 512px app icon
ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
SRC="../icon-app.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>iCamLink</string>
  <key>CFBundleDisplayName</key><string>iCamLink</string>
  <key>CFBundleIdentifier</key><string>com.icamlink.mac</string>
  <key>CFBundleExecutable</key><string>ICamLink</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>iCamLink busca y se conecta a las cámaras de tu red local.</string>
</dict></plist>
PLIST

echo "==> ad-hoc signing"
find "$APP" \( -name "*.dylib" -o -name "*.so" \) -print0 | xargs -0 -n 20 codesign --force --sign - >/dev/null 2>&1
codesign --force --sign - "$APP/Contents/MacOS/ICamLink" >/dev/null
codesign --force --sign - "$APP" >/dev/null
codesign --verify --deep "$APP" && echo "signature ok"

ZIP="dist/iCamLink-${VERSION}-macos-arm64.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Done: $APP  ($(du -sh "$APP" | cut -f1)),  $ZIP"
