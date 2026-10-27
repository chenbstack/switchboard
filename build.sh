#!/bin/zsh
# 构建并打包为 build/SwitchBoard.app（SwiftUI 宏需要完整 Xcode 工具链）
set -e
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build -c release
APP=build/SwitchBoard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/SwitchBoard "$APP/Contents/MacOS/"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
# CI 通过 VERSION 注入版本号（来自 git tag）
[ -n "$VERSION" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "✅ $APP"
