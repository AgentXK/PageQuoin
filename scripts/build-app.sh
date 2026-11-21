#!/bin/bash
set -euo pipefail

configuration="${1:-release}"
if [[ $# -gt 1 || ( "$configuration" != release && "$configuration" != debug ) ]]; then
    printf 'Usage: %s [release|debug]\n' "$0" >&2
    exit 2
fi

project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
build_dir="$project_dir/.build"
app_name="PageQuoin"
app_display_name="PageQuoin"
app_path="$build_dir/$app_name.app"
icon_source="$project_dir/Assets/AppIcon.png"

if [[ ! -f "$icon_source" ]]; then
    printf 'App icon missing: %s\n' "$icon_source" >&2
    exit 1
fi

swift build --package-path "$project_dir" --configuration "$configuration" --product LocalTeX >&2
bin_dir="$(swift build --package-path "$project_dir" --configuration "$configuration" --show-bin-path)"

staging_dir="$(mktemp -d "$build_dir/$app_name-stage.XXXXXX")"
trap 'rm -rf -- "$staging_dir"' EXIT
staged_app="$staging_dir/$app_name.app"
contents_dir="$staged_app/Contents"
iconset_dir="$staging_dir/AppIcon.iconset"
mkdir -p -- "$contents_dir/MacOS" "$contents_dir/Resources" "$iconset_dir"
/usr/bin/install -m 755 "$bin_dir/LocalTeX" "$contents_dir/MacOS/LocalTeX"

for size in 16 32 128 256 512; do
    retina_size=$((size * 2))
    /usr/bin/sips -z "$size" "$size" "$icon_source" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    /usr/bin/sips -z "$retina_size" "$retina_size" "$icon_source" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset_dir" -o "$contents_dir/Resources/AppIcon.icns"

cat > "$contents_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$app_display_name</string>
    <key>CFBundleExecutable</key>
    <string>LocalTeX</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIdentifier</key>
    <string>org.localtex.editor</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$app_name</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>LaTeX Document</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.tug.tex</string>
            </array>
            <key>NSDocumentClass</key>
            <string>TeXDocument</string>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Plain Text Document</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.plain-text</string>
                <string>public.json</string>
                <string>public.xml</string>
                <string>public.html</string>
                <string>public.yaml</string>
                <string>public.comma-separated-values-text</string>
                <string>net.daringfireball.markdown</string>
            </array>
            <key>NSDocumentClass</key>
            <string>TeXDocument</string>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Image</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.image</string>
            </array>
            <key>NSDocumentClass</key>
            <string>TeXDocument</string>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>PDF Document</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.adobe.pdf</string>
            </array>
            <key>NSDocumentClass</key>
            <string>TeXDocument</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$contents_dir/Info.plist" >&2
/usr/bin/codesign --force --sign - "$staged_app"
/usr/bin/codesign --verify --strict "$staged_app"

rm -rf -- "$app_path"
mv -- "$staged_app" "$app_path"
printf '%s\n' "$app_path"
