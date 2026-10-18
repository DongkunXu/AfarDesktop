# Sourced by every script in this folder.
# Keeps all build byproducts inside the project: SwiftPM, the compiler and the third-party
# builds write temporary files to $TMPDIR. Pointing TMPDIR into .build/ contains them, and the
# EXIT trap removes them.

ROOT="${0:A:h:h}"
cd "$ROOT"

export TMPDIR="$ROOT/.build/tmp"
mkdir -p "$TMPDIR"

_afar_cleanup_tmp() {
    if [[ -n "${TMPDIR:-}" && "$TMPDIR" == "$ROOT/.build/tmp" ]]; then
        rm -rf "$TMPDIR"
    fi
}
trap _afar_cleanup_tmp EXIT

APP_NAME="Afar Desktop"
EXECUTABLE_NAME="AfarDesktop"
VENDOR="$ROOT/Vendor"
PREFIX="$VENDOR/prefix"

# Optional local signing configuration (never committed). See config/signing.example.env.
BUNDLE_ID="io.github.afardesktop.AfarDesktop"
SIGN_IDENTITY="-"
if [[ -f "$ROOT/config/signing.env" ]]; then
    source "$ROOT/config/signing.env"
fi

# The app bundle is staged in a ".noindex" folder: Spotlight skips it, so a build copy never
# shows up next to the installed app. Installing and packaging remove it when they are done.
STAGED_APP="$ROOT/build/stage.noindex/$APP_NAME.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

_afar_remove_staged_app() {
    if [[ -d "$STAGED_APP" ]]; then
        "$LSREGISTER" -u "$STAGED_APP" 2>/dev/null || true
    fi
    rm -rf "${STAGED_APP:h}"
    rmdir "$ROOT/build" 2>/dev/null || true
}
