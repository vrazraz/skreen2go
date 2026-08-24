#!/bin/zsh
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
app_path="${APP_PATH:-$project_dir/dist/Skreen2Go.app}"
pkg_path="${PKG_PATH:-$project_dir/dist/Skreen2Go.pkg}"
installer_identity="${INSTALLER_IDENTITY:-}"

if [[ ! -d "$app_path" ]]; then
    print -u2 "App bundle not found: $app_path"
    print -u2 "Build it first with APP_STORE=1 and the distribution signing inputs."
    exit 2
fi

if ! codesign --verify --deep --strict "$app_path"; then
    print -u2 "The app bundle is not strictly signed: $app_path"
    print -u2 "Build it first with APP_STORE=1 and a Developer ID/App Store signing identity."
    exit 2
fi

signature_details="$(codesign -dv --verbose=4 "$app_path" 2>&1 || true)"
if [[ "$signature_details" == *"Signature=adhoc"* ]]; then
    print -u2 "The app is ad-hoc signed; Mac App Store packages require an Apple signature."
    exit 2
fi

if [[ -z "$installer_identity" ]]; then
    print -u2 "INSTALLER_IDENTITY is required for a Mac App Store package."
    print -u2 "Use the Mac Installer Distribution certificate identity from Keychain Access."
    exit 2
fi

if ! command -v productbuild >/dev/null 2>&1 || ! command -v pkgutil >/dev/null 2>&1; then
    print -u2 "productbuild and pkgutil must be available from Xcode Command Line Tools."
    exit 2
fi

mkdir -p "${pkg_path:h}"
rm -f "$pkg_path"
productbuild \
    --component "$app_path" /Applications \
    --sign "$installer_identity" \
    --timestamp \
    "$pkg_path"

pkgutil --check-signature "$pkg_path"
print "Built signed Mac App Store package: $pkg_path"
