#!/bin/zsh
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
bin_dir="$(swift build -c release --show-bin-path)"
swift build -c release

app_dir="$project_dir/dist/Skreen2Go.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/Skreen2Go" "$app_dir/Contents/MacOS/Skreen2Go"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"

codesign --force --deep --sign - \
  --requirements '=designated => identifier "com.skreen2go.app"' \
  "$app_dir" >/dev/null 2>&1 || true

echo "Built: $app_dir"
