#!/bin/zsh
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
app_dir="$project_dir/dist/Skreen2Go.app"
entitlements="$project_dir/Resources/Skreen2Go.entitlements"
info_plist="$project_dir/Resources/Info.plist"
privacy_manifest="$project_dir/Resources/PrivacyInfo.xcprivacy"
app_icon="${APP_ICON:-$project_dir/Resources/AppIcon.icns}"

signing_identity="${SIGNING_IDENTITY:--}"
app_store="${APP_STORE:-0}"
provisioning_profile="${PROVISIONING_PROFILE:-}"
app_version="${APP_VERSION:-}"
app_build="${APP_BUILD:-}"

if [[ "$app_store" == "1" ]]; then
    if [[ "$signing_identity" == "-" ]]; then
        print -u2 "APP_STORE=1 requires SIGNING_IDENTITY with an Apple distribution certificate."
        exit 2
    fi
    if [[ -z "$provisioning_profile" ]]; then
        print -u2 "APP_STORE=1 requires PROVISIONING_PROFILE pointing to a Mac App Store profile."
        exit 2
    fi
    if [[ ! -f "$provisioning_profile" ]]; then
        print -u2 "Provisioning profile not found: $provisioning_profile"
        exit 2
    fi
    if [[ ! -f "$app_icon" ]]; then
        print -u2 "App Store builds require a final .icns icon: $app_icon"
        exit 2
    fi
fi

if [[ ! -f "$entitlements" || ! -f "$info_plist" || ! -f "$privacy_manifest" ]]; then
    print -u2 "Release resources are missing from Resources/."
    exit 2
fi

swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/Skreen2Go" "$app_dir/Contents/MacOS/Skreen2Go"
cp "$info_plist" "$app_dir/Contents/Info.plist"
cp "$privacy_manifest" "$app_dir/Contents/Resources/PrivacyInfo.xcprivacy"

# SwiftPM emits localized resources as a separate bundle beside the binary. Without it
# every string falls back to the built-in English, so treat a missing bundle as fatal.
resource_bundle="$bin_dir/Skreen2Go_Skreen2GoCore.bundle"
if [[ ! -d "$resource_bundle" ]]; then
    print -u2 "Localization bundle not found: $resource_bundle"
    exit 2
fi
cp -R "$resource_bundle" "$app_dir/Contents/Resources/"

if [[ -f "$app_icon" ]]; then
    cp "$app_icon" "$app_dir/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon.icns" \
        "$app_dir/Contents/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon.icns" \
            "$app_dir/Contents/Info.plist"
fi

if [[ -n "$app_version" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" \
        "$app_dir/Contents/Info.plist"
fi
if [[ -n "$app_build" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $app_build" \
        "$app_dir/Contents/Info.plist"
fi

if [[ -n "$provisioning_profile" ]]; then
    cp "$provisioning_profile" "$app_dir/Contents/embedded.provisionprofile"
fi

sign_args=(--force --sign "$signing_identity" --entitlements "$entitlements")
if [[ "$signing_identity" != "-" ]]; then
    sign_args+=(--timestamp)
fi
# Nested bundles have to be signed before the enclosing app.
codesign --force --sign "$signing_identity" "$app_dir/Contents/Resources/Skreen2Go_Skreen2GoCore.bundle"
codesign "${sign_args[@]}" "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"
plutil -lint "$app_dir/Contents/Info.plist" >/dev/null

if [[ "$app_store" == "1" ]]; then
    print "App Store signing inputs were applied. Upload this bundle through Xcode Organizer or Transporter after final validation."
else
    print "Built and ad-hoc signed for local testing: $app_dir"
fi
