#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift build -c release
binary="$root/.build/release/SplitSound"
app="$root/build/SplitSound.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/SplitSound"
cp "$root/Packaging/Info.plist" "$app/Contents/Info.plist"
cp "$root/Packaging/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp -R "$root/Packaging/"*.lproj "$app/Contents/Resources/"
chmod +x "$app/Contents/MacOS/SplitSound"

identity="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$identity" "$app"

echo "Built $app"
