#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

for tool in xcrun sips iconutil codesign; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        print -u2 "缺少 $tool。请安装 Apple Command Line Tools：xcode-select --install"
        exit 1
    fi
done

mkdir -p dist
build_work=$(mktemp -d "$PWD/dist/.DroidLink.XXXXXX")
trap 'rm -rf "$build_work"' EXIT
app="$build_work/DroidLink.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$build_work/AppIcon.iconset"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/AppIcon.png --out "$build_work/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" Assets/AppIcon.png --out "$build_work/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$build_work/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"

xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 \
    Sources/ADB.swift Sources/DeviceNames.swift Sources/App.swift \
    -o "$app/Contents/MacOS/DroidLink" -framework SwiftUI -framework AppKit

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DroidLink</string>
<key>CFBundleIdentifier</key><string>io.github.afetmin.droidlink</string>
<key>CFBundleName</key><string>DroidLink</string>
<key>CFBundleDisplayName</key><string>DroidLink</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>发现同一 Wi-Fi 下开启无线调试的安卓手机。</string>
<key>NSBonjourServices</key><array><string>_adb-tls-connect._tcp</string><string>_adb-tls-pairing._tcp</string></array>
</dict></plist>
PLIST

plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

destination="$PWD/dist/DroidLink.app"
if [[ -e "$destination" ]]; then rm -rf "$destination"; fi
mv "$app" "$destination"
print "已生成：$destination"
