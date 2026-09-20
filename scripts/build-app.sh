#!/bin/zsh
set -euo pipefail
swift build -c release --arch arm64
app_dir="outputs/RegionBlur.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp .build/arm64-apple-macosx/release/RegionBlur "$app_dir/Contents/MacOS/RegionBlur"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
xattr -cr "$app_dir" 2>/dev/null || true
codesign --force --deep --sign - "$app_dir"
xattr -cr "$app_dir" 2>/dev/null || true
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
echo "Built $app_dir"
