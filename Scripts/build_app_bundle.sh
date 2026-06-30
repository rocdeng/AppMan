#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
bundle_dir="$project_root/.build/AppMan.app"
contents_dir="$bundle_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
plist_file="$contents_dir/Info.plist"

swift build
bin_path="$(swift build --show-bin-path)"

rm -rf "$bundle_dir"
mkdir -p "$macos_dir" "$resources_dir"

cp "$bin_path/AppMan" "$macos_dir/AppMan"
chmod +x "$macos_dir/AppMan"

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
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
PLIST

echo "$bundle_dir"
