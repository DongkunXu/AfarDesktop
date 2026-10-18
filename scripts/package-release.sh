#!/bin/zsh
# Builds a signed, notarized release for GitHub:
#   build/AfarDesktop-<version>.zip and build/AfarDesktop-<version>.zip.sha256
# The version comes from VERSION; the app contains every architecture the third-party
# libraries were built for (ARCHS="arm64 x86_64" scripts/build-deps.sh for a universal app).
#
# Needs SIGN_IDENTITY (a "Developer ID Application" identity) and NOTARY_PROFILE (a notarytool
# keychain profile, `xcrun notarytool store-credentials`) in config/signing.env.
set -euo pipefail
source "${0:A:h}/_env.sh"

identity=$(security find-identity -v -p codesigning | grep -F -- "$SIGN_IDENTITY" || true)
if [[ "$SIGN_IDENTITY" == "-" || "$identity" != *"Developer ID Application"* ]]; then
    echo "SIGN_IDENTITY in config/signing.env must be a Developer ID Application identity." >&2
    exit 1
fi
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    echo "NOTARY_PROFILE in config/signing.env is empty." >&2
    exit 1
fi

# build-app.sh signs with the hardened runtime and a secure timestamp, as notarization requires.
"$ROOT/scripts/build-app.sh"
mkdir -p "$TMPDIR" # build-app.sh removes the shared temp directory when it exits
APP="$STAGED_APP"
trap '_afar_remove_staged_app; _afar_cleanup_tmp' EXIT

codesign --verify --strict --deep --verbose=2 "$APP"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
    echo "The app carries get-task-allow; notarization would reject it." >&2
    exit 1
fi

# Notarize a temporary zip, staple the ticket to the app, then package the stapled app.
SUBMISSION="$TMPDIR/AfarDesktop-notarize.zip"
ditto -c -k --keepParent "$APP" "$SUBMISSION"
xcrun notarytool submit "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

VERSION=$(<"$ROOT/VERSION")
ZIP="$ROOT/build/AfarDesktop-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$ROOT/build" && shasum -a 256 "${ZIP:t}" > "${ZIP:t}.sha256")

echo "Packaged $ZIP ($(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE_NAME"))"
cat "$ZIP.sha256"
