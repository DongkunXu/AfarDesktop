#!/bin/zsh
# Builds the pinned OpenSSL and FreeRDP sources (Vendor/versions.env) as static libraries,
# applying Vendor/patches/freerdp-*.patch to FreeRDP in order.
#   scripts/build-deps.sh                 -> host architecture
#   ARCHS="arm64 x86_64" scripts/build-deps.sh   -> universal libraries
# Output: Vendor/prefix/{include,lib}. Downloads are cached in Vendor/.cache, per-arch work
# trees live in Vendor/.work and are removed after a successful build.
set -euo pipefail
source "${0:A:h}/_env.sh"
source "$VENDOR/versions.env"

ARCHS=(${=${ARCHS:-$(uname -m)}})
CACHE="$VENDOR/.cache"
WORK="$VENDOR/.work"
JOBS=$(sysctl -n hw.ncpu)
export MACOSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET"

fetch() { # url sha256
    local file="$CACHE/${1:t}"
    mkdir -p "$CACHE"
    if [[ ! -f "$file" ]]; then
        curl -fsSL --retry 3 -o "$file.part" "$1"
        mv "$file.part" "$file"
    fi
    local actual=$(shasum -a 256 "$file" | cut -d' ' -f1)
    if [[ "$actual" != "$2" ]]; then
        echo "Checksum mismatch for ${file:t}: $actual" >&2
        rm -f "$file"
        exit 1
    fi
    echo "$file"
}

build_openssl() { # arch dest
    local arch=$1 dest=$2 src="$WORK/$1/openssl"
    local target=darwin64-$arch-cc
    rm -rf "$src" && mkdir -p "$src"
    tar -xzf "$(fetch "$OPENSSL_URL" "$OPENSSL_SHA256")" -C "$src" --strip-components 1
    (
        cd "$src"
        # /private/etc/ssl holds the system CA bundle (cert.pem) maintained by macOS.
        ./Configure "$target" no-shared no-module no-tests no-docs no-apps \
            --prefix="$dest" --libdir=lib --openssldir=/private/etc/ssl \
            -mmacosx-version-min="$MACOS_DEPLOYMENT_TARGET" >/dev/null
        make -j"$JOBS" build_libs >/dev/null
        make install_dev >/dev/null
    )
}

build_freerdp() { # arch dest
    local arch=$1 dest=$2 src="$WORK/$1/freerdp" bld="$WORK/$1/freerdp-build"
    rm -rf "$src" "$bld" && mkdir -p "$src"
    tar -xzf "$(fetch "$FREERDP_URL" "$FREERDP_SHA256")" -C "$src" --strip-components 1
    for patch in "$VENDOR"/patches/freerdp-*.patch(N); do
        patch -p1 -s -d "$src" <"$patch"
    done
    # Only our own prefix may satisfy dependencies: anything found in Homebrew would end up
    # linked into the app without being shipped.
    PKG_CONFIG_LIBDIR="$dest/lib/pkgconfig" cmake -S "$src" -B "$bld" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET" \
        -DCMAKE_INSTALL_PREFIX="$dest" \
        -DCMAKE_PREFIX_PATH="$dest" \
        -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local" \
        -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
        -DOPENSSL_ROOT_DIR="$dest" -DOPENSSL_USE_STATIC_LIBS=ON \
        -DUSE_VERSION_FROM_GIT_TAG=OFF \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
        -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT_CHANNELS=ON -DWITH_CHANNELS=ON \
        -DWITH_CLIENT=OFF -DWITH_CLIENT_SDL=OFF -DWITH_CLIENT_MAC=OFF -DWITH_CLIENT_INTERFACE=OFF \
        -DWITH_SERVER=OFF -DWITH_SHADOW=OFF -DWITH_PROXY=OFF -DWITH_SAMPLE=OFF \
        -DWITH_MANPAGES=OFF -DWITH_WINPR_TOOLS=OFF -DWITH_CCACHE=OFF -DWITH_CLANG_FORMAT=OFF \
        -DWITH_VERBOSE_WINPR_ASSERT=OFF \
        -DWITH_MACAUDIO=ON -DWITH_VIDEOTOOLBOX=ON \
        -DWITH_FFMPEG=OFF -DWITH_FFMPEG_HWACCEL=OFF -DWITH_SWSCALE=OFF -DWITH_OPENH264=OFF -DWITH_OPUS=OFF -DWITH_FDK_AAC=OFF \
        -DWITH_JPEG=OFF -DWITH_PNG=OFF -DWITH_WEBP=OFF -DWITH_LODEPNG=OFF -DWITH_CAIRO=OFF \
        -DWITH_KRB5=OFF -DWITH_PKCS11=OFF -DWITH_SMARTCARD_PCSC=OFF -DWITH_CUPS=OFF -DWITH_FUSE=OFF \
        -DWITH_URIPARSER=OFF -DWITH_JSON_DISABLED=ON -DWITH_AAD=OFF -DWITH_SSO_MIB=OFF \
        -DWITH_WEBVIEW_AAD_AUTH_HELPER=OFF -DWITH_SYSTEMD=OFF \
        -DCHANNEL_URBDRC=OFF -DCHANNEL_TSMF=OFF -DCHANNEL_RDPECAM=OFF -DCHANNEL_PRINTER=OFF \
        -DCHANNEL_SERIAL=OFF -DCHANNEL_PARALLEL=OFF -DCHANNEL_SMARTCARD=OFF -DCHANNEL_REMDESK=OFF \
        >"$WORK/$arch/freerdp-configure.log"
    cmake --build "$bld" -j"$JOBS" >"$WORK/$arch/freerdp-build.log"
    cmake --install "$bld" >/dev/null
}

# Folds every static library of one architecture into a single archive.
merge_libs() { # arch dest
    local dest=$2
    libtool -static -no_warning_for_no_symbols -o "$WORK/$1/libAfarFreeRDP.a" "$dest"/lib/*.a
}

rm -rf "$WORK"
for arch in $ARCHS; do
    dest="$WORK/$arch/prefix"
    echo "==> OpenSSL $OPENSSL_VERSION ($arch)"
    build_openssl "$arch" "$dest"
    echo "==> FreeRDP $FREERDP_VERSION ($arch)"
    build_freerdp "$arch" "$dest"
    merge_libs "$arch" "$dest"
done

rm -rf "$PREFIX"
mkdir -p "$PREFIX/lib"
first="$WORK/${ARCHS[1]}/prefix"
cp -R "$first/include" "$PREFIX/include"
cd "$WORK"
lipo -create "${ARCHS[@]/%//libAfarFreeRDP.a}" -output "$PREFIX/lib/libAfarFreeRDP.a"
cd "$ROOT"
cat >"$PREFIX/BUILD-INFO" <<EOF
FreeRDP $FREERDP_VERSION
OpenSSL $OPENSSL_VERSION
Architectures: $ARCHS
Deployment target: macOS $MACOS_DEPLOYMENT_TARGET
EOF
rm -rf "$WORK"
echo "Built $PREFIX ($(lipo -archs "$PREFIX/lib/libAfarFreeRDP.a"))"
