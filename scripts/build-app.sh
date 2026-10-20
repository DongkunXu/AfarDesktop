#!/bin/zsh
# Builds "Afar Desktop.app" (release), optionally installing it.
#   scripts/build-app.sh            -> build/stage.noindex/Afar Desktop.app
#   scripts/build-app.sh --install  -> installs to /Applications (or ~/Applications), launches it
#                                      and removes the staged copy
# Signing follows config/signing.env (see config/signing.example.env); ad hoc by default.
set -euo pipefail
source "${0:A:h}/_env.sh"

[[ -f "$PREFIX/lib/libAfarFreeRDP.a" ]] || "$ROOT/scripts/build-deps.sh"

VERSION=$(<"$ROOT/VERSION")
BUILD_NUMBER=$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)

# The app is built for the architectures the third-party libraries contain (see build-deps.sh):
# arm64, or arm64 and x86_64 for a universal app.
ARCH_FLAGS=()
for arch in $(lipo -archs "$PREFIX/lib/libAfarFreeRDP.a"); do ARCH_FLAGS+=(--arch "$arch"); done

# The compiler lists every localizable string it sees; the folder persists so an incremental
# build (which only recompiles changed files) still has the lists of the unchanged ones.
STRINGS="$ROOT/.build/stringsdata"
mkdir -p "$STRINGS"
swift build -c release "${ARCH_FLAGS[@]}" --product "$EXECUTABLE_NAME" \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$STRINGS"
python3 "$ROOT/tools/sync-strings.py" "$STRINGS" "$ROOT/Resources/Localizable.xcstrings"
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/$EXECUTABLE_NAME"

APP="$STAGED_APP"
_afar_remove_staged_app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE_NAME"
# Debug symbols name every source and build path on this machine; the app ships without them.
strip -S -x "$APP/Contents/MacOS/$EXECUTABLE_NAME"
sed -e "s/\$(BUNDLE_ID)/$BUNDLE_ID/" -e "s/\$(VERSION)/$VERSION/" -e "s/\$(BUILD_NUMBER)/$BUILD_NUMBER/" \
    "$ROOT/Resources/Info.plist" >"$APP/Contents/Info.plist"
# The icon is an Icon Composer document: actool renders the Liquid Glass icon into Assets.car
# and an AppIcon.icns for macOS versions before 26.
xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist "$TMPDIR/icon-info.plist" >/dev/null
for catalog in Localizable InfoPlist; do
    xcrun xcstringstool compile "$ROOT/Resources/$catalog.xcstrings" --output-directory "$APP/Contents/Resources"
done
# English is the source language and needs no table, but its folder tells macOS it is supported.
mkdir -p "$APP/Contents/Resources/en.lproj"
cp -R "$ROOT/Resources/Backgrounds" "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Licenses"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/Licenses/"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - --timestamp=none "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION, build $BUILD_NUMBER, $(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE_NAME"), signed: $SIGN_IDENTITY)"

if [[ "${1:-}" == "--install" ]]; then
    DEST_DIR="/Applications"
    [[ -w "$DEST_DIR" ]] || DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
    DEST="$DEST_DIR/$APP_NAME.app"

    if pgrep -x "$EXECUTABLE_NAME" >/dev/null; then
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        for _ in {1..20}; do pgrep -x "$EXECUTABLE_NAME" >/dev/null || break; sleep 0.25; done
        if pgrep -x "$EXECUTABLE_NAME" >/dev/null; then
            echo "$APP_NAME is still running; quit it and re-run." >&2
            exit 1
        fi
    fi

    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    _afar_remove_staged_app
    touch "$DEST"
    "$LSREGISTER" -f "$DEST"
    open "$DEST"
    echo "Installed and launched $DEST"
fi
