#!/bin/zsh
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
source_dir="${ICON_SOURCE_DIR:-$HOME/Desktop/icons}"
output="${APP_ICON:-$project_dir/Resources/AppIcon.icns}"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/skreen2go-icon.XXXXXX")"
iconset_dir="$temp_dir/AppIcon.iconset"

cleanup() { rm -rf "$temp_dir" }
trap cleanup EXIT
mkdir -p "$iconset_dir" "${output:h}"

for file in 32 64 128 256 512 1024; do
    if [[ ! -f "$source_dir/1024-$file.png" ]]; then
        print -u2 "Missing icon source: $source_dir/1024-$file.png"
        exit 2
    fi
done

# The source pack contains one square PNG for each physical size. iconutil expects
# Apple's iconset naming scheme, where @2x files are the next physical size.
sips -z 16 16 "$source_dir/1024-32.png" --out "$iconset_dir/icon_16x16.png" >/dev/null
cp "$source_dir/1024-32.png" "$iconset_dir/icon_16x16@2x.png"
sips -z 32 32 "$source_dir/1024-64.png" --out "$iconset_dir/icon_32x32.png" >/dev/null
cp "$source_dir/1024-64.png" "$iconset_dir/icon_32x32@2x.png"
cp "$source_dir/1024-128.png" "$iconset_dir/icon_128x128.png"
cp "$source_dir/1024-256.png" "$iconset_dir/icon_128x128@2x.png"
cp "$source_dir/1024-256.png" "$iconset_dir/icon_256x256.png"
cp "$source_dir/1024-512.png" "$iconset_dir/icon_256x256@2x.png"
cp "$source_dir/1024-512.png" "$iconset_dir/icon_512x512.png"
cp "$source_dir/1024-1024.png" "$iconset_dir/icon_512x512@2x.png"

iconutil -c icns "$iconset_dir" -o "$output"
file "$output"
print "Built app icon: $output"
