#!/bin/zsh
# 把 build/SwitchBoard.app 打成带背景图和图标排布的 dmg：scripts/make-dmg.sh <version>
# 依赖 dmgbuild（pip install dmgbuild），不依赖 Finder/AppleScript，CI 上也能跑
set -e
cd "$(dirname "$0")/.."
V="${1:?usage: make-dmg.sh <version>}"
rm -f build/dmg-bg@2x.png
swift scripts/make-dmg-bg.swift build
# 只用 1x 单图：多分辨率 TIFF 在部分系统的访达里会被当成 1x 放大显示
rm -f "build/SwitchBoard-$V.dmg"
dmgbuild -s scripts/dmg-settings.py \
  -D app=build/SwitchBoard.app -D bg=build/dmg-bg.png -D icon=Resources/AppIcon.icns \
  "SwitchBoard" "build/SwitchBoard-$V.dmg" >/dev/null
echo "✅ build/SwitchBoard-$V.dmg"
