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
version_file="$project_dir/VERSION"
build_number_file="$project_dir/BUILD_NUMBER"
default_version="$(<"$version_file")"
default_build="$(<"$build_number_file")"
app_version="${APP_VERSION:-$default_version}"
app_build="${APP_BUILD:-$default_build}"
architectures="${ARCHS:-native}"

# Xcode's SDK, not the Command Line Tools one, for every build now: the panel's Liquid
# Glass background uses NSGlassEffectView, which arrived in the macOS 26 SDK. The app
# still runs on macOS 15 — the class is behind an availability check — but it has to be
# compiled against an SDK that knows the class exists.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

sdk_version="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo 0)"
if [[ "${sdk_version%%.*}" -lt 26 ]]; then
    print -u2 "Building needs the macOS 26 SDK or newer, found $sdk_version."
    print -u2 "Install Xcode 26 and point DEVELOPER_DIR at it."
    exit 2
fi

if [[ ! "$app_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$' ]]; then
    print -u2 "APP_VERSION/VERSION must be a semantic version, got: $app_version"
    exit 2
fi
if [[ ! "$app_build" =~ '^[0-9]+$' ]]; then
    print -u2 "APP_BUILD/BUILD_NUMBER must be numeric, got: $app_build"
    exit 2
fi

if [[ "$architectures" != "native" && "$architectures" != "universal" ]]; then
    print -u2 "ARCHS must be either native or universal."
    exit 2
fi

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

    profile_plist="$(mktemp "${TMPDIR:-/tmp}/skreen2go-profile.XXXXXX.plist")"
    trap 'rm -f "$profile_plist"' EXIT
    security cms -D -i "$provisioning_profile" -o "$profile_plist"
    profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$profile_plist" 2>/dev/null || true)"
    if [[ "$profile_app_id" != *.com.skreen2go.app ]]; then
        print -u2 "Provisioning profile does not target com.skreen2go.app: $profile_app_id"
        exit 2
    fi
fi

if [[ ! -f "$entitlements" || ! -f "$info_plist" || ! -f "$privacy_manifest" ]]; then
    print -u2 "Release resources are missing from Resources/."
    exit 2
fi

# The Info.plist strings macOS itself shows — the Screen Recording prompt above all —
# are localized from `.lproj` directories in the app bundle, not from the SwiftPM
# resource bundle, which only the app's own code reads.
info_plist_languages=("${(@f)$(/usr/libexec/PlistBuddy -c 'Print :CFBundleLocalizations' "$info_plist" \
    | sed -n 's/^ *\([A-Za-z_-]*\)$/\1/p')}")
if (( ${#info_plist_languages} == 0 )); then
    print -u2 "Info.plist declares no CFBundleLocalizations."
    exit 2
fi
for language in $info_plist_languages; do
    if [[ ! -f "$project_dir/Resources/$language.lproj/InfoPlist.strings" ]]; then
        print -u2 "Missing Resources/$language.lproj/InfoPlist.strings for a declared localization."
        exit 2
    fi
done

if [[ "$architectures" == "universal" ]]; then
    if ! command -v lipo >/dev/null 2>&1; then
        print -u2 "Universal builds require lipo from Xcode Command Line Tools."
        exit 2
    fi

    arm_scratch="$project_dir/.build/release-arm64"
    intel_scratch="$project_dir/.build/release-x86_64"
    swift build -c release --triple arm64-apple-macosx15.0 --scratch-path "$arm_scratch"
    swift build -c release --triple x86_64-apple-macosx15.0 --scratch-path "$intel_scratch"

    arm_bin_dir="$(swift build -c release --triple arm64-apple-macosx15.0 --scratch-path "$arm_scratch" --show-bin-path)"
    intel_bin_dir="$(swift build -c release --triple x86_64-apple-macosx15.0 --scratch-path "$intel_scratch" --show-bin-path)"
    universal_binary="$project_dir/.build/Skreen2Go-universal"
    lipo -create \
        "$arm_bin_dir/Skreen2Go" \
        "$intel_bin_dir/Skreen2Go" \
        -output "$universal_binary"
    bin_dir="$arm_bin_dir"
else
    swift build -c release
    bin_dir="$(swift build -c release --show-bin-path)"
    universal_binary=""
fi

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
if [[ -n "$universal_binary" ]]; then
    cp "$universal_binary" "$app_dir/Contents/MacOS/Skreen2Go"
else
    cp "$bin_dir/Skreen2Go" "$app_dir/Contents/MacOS/Skreen2Go"
fi
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

for language in $info_plist_languages; do
    mkdir -p "$app_dir/Contents/Resources/$language.lproj"
    cp "$project_dir/Resources/$language.lproj/InfoPlist.strings" \
        "$app_dir/Contents/Resources/$language.lproj/InfoPlist.strings"
done

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
