#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
real_home="$HOME"
scratch_dir="$project_root/.build-intel"
bundle_dir="$scratch_dir/AppMan.app"
contents_dir="$bundle_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
plist_file="$contents_dir/Info.plist"
icon_file="$project_root/Resources/AppIcon/Icon.icns"
recipes_dir="$project_root/Resources/UpdateRecipes"
release_dir="$project_root/dist"
archive_file="$release_dir/AppMan-macOS-Intel-x86_64.zip"
export HOME="$scratch_dir/home"
export CLANG_MODULE_CACHE_PATH="$scratch_dir/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$scratch_dir/clang-module-cache"
mkdir -p "$HOME" "$CLANG_MODULE_CACHE_PATH"

swift build \
    --disable-sandbox \
    --configuration release \
    --arch x86_64 \
    --scratch-path "$scratch_dir"
bin_path="$(swift build \
    --disable-sandbox \
    --configuration release \
    --arch x86_64 \
    --scratch-path "$scratch_dir" \
    --show-bin-path)"

timestamp="$(date +%Y%m%d-%H%M%S)"
if [[ -d "$bundle_dir" ]]; then
    mv "$bundle_dir" "$real_home/.Trash/AppMan-Intel-build-$timestamp.app"
fi
if [[ -f "$archive_file" ]]; then
    mv "$archive_file" "$real_home/.Trash/AppMan-macOS-Intel-x86_64-$timestamp.zip"
fi

mkdir -p "$macos_dir" "$resources_dir" "$release_dir"
cp "$bin_path/AppMan" "$macos_dir/AppMan"
chmod +x "$macos_dir/AppMan"
cp "$icon_file" "$resources_dir/AppMan.icns"
if [[ -d "$recipes_dir" ]]; then
    cp -R "$recipes_dir" "$resources_dir/UpdateRecipes"
fi

cat > "$plist_file" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>AppMan</string>
    <key>CFBundleIdentifier</key>
    <string>com.dengpeng.AppMan</string>
    <key>CFBundleName</key>
    <string>AppMan</string>
    <key>CFBundleIconFile</key>
    <string>AppMan</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
PLIST

signing_identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)"
if [[ -n "$signing_identity" ]]; then
    codesign --force --deep --sign "$signing_identity" \
        --identifier com.dengpeng.AppMan "$bundle_dir"
else
    codesign --force --deep --sign - \
        --identifier com.dengpeng.AppMan "$bundle_dir"
fi

codesign --verify --deep --strict "$bundle_dir"
ditto -c -k --sequesterRsrc --keepParent "$bundle_dir" "$archive_file"

echo "$bundle_dir"
echo "$archive_file"
