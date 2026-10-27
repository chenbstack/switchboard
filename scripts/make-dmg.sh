#!/bin/zsh
# 把 build/SwitchBoard.app 打成带背景图和图标排布的 dmg：scripts/make-dmg.sh <version>
# 依赖 dmgbuild（pip install dmgbuild），不依赖 Finder/AppleScript，CI 上也能跑
set -e
cd "$(dirname "$0")/.."
V="${1:?usage: make-dmg.sh <version>}"
swift scripts/make-dmg-bg.swift build
tiffutil -cathidpicheck build/dmg-bg.png build/dmg-bg@2x.png -out build/dmg-bg.tiff
rm -f "build/SwitchBoard-$V.dmg"
dmgbuild -s scripts/dmg-settings.py \
  -D app=build/SwitchBoard.app -D bg=build/dmg-bg.tiff -D icon=Resources/AppIcon.icns \
  "SwitchBoard" "build/SwitchBoard-$V.dmg" >/dev/null
echo "✅ build/SwitchBoard-$V.dmg"
