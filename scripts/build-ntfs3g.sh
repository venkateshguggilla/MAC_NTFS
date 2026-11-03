#!/bin/bash
# Fetch, verify and build libntfs-3g + ntfsprogs (mkntfs, ntfscp, ntfsls, ...).
# The FUSE driver itself is disabled: we only need the library and the tools.
#
# Output: build/ntfs-3g/prefix/{lib,include,bin,sbin}
set -euo pipefail

VERSION="2026.9.28"
SHA256="350d9415c59f7c3fa74e23985ad2d56423c6a168337368f672e2e362d8f295c8"
URL="https://download.tuxera.com/opensource/ntfs-3g_ntfsprogs-${VERSION}.tgz"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARBALL="$ROOT/third_party/ntfs-3g_ntfsprogs-${VERSION}.tgz"
SRC="$ROOT/build/ntfs-3g/src"
PREFIX="$ROOT/build/ntfs-3g/prefix"

mkdir -p "$ROOT/third_party" "$SRC"

if [[ ! -f "$TARBALL" ]]; then
    echo "==> Downloading ntfs-3g $VERSION"
    curl -fsSL -o "$TARBALL" "$URL"
fi

echo "==> Verifying checksum"
echo "$SHA256  $TARBALL" | shasum -a 256 -c -

if [[ ! -f "$SRC/configure" ]]; then
    tar xzf "$TARBALL" -C "$SRC" --strip-components=1
fi

echo "==> Configuring"
cd "$SRC"
PATH="$ROOT/scripts/tools:$PATH" ./configure \
    --prefix="$PREFIX" \
    --disable-ntfs-3g \
    --enable-ntfsprogs \
    --disable-crypto \
    --disable-shared \
    --enable-static \
    --disable-ldconfig \
    --disable-mtab \
    CFLAGS="-O2 -g" > "$ROOT/build/ntfs-3g/configure.log"

echo "==> Building"
make -j"$(sysctl -n hw.ncpu)" > "$ROOT/build/ntfs-3g/make.log"
# ntfs-3g defaults to moving libs/tools into /lib, /bin, /sbin; keep them in PREFIX.
make install \
    rootlibdir="$PREFIX/lib" rootbindir="$PREFIX/bin" rootsbindir="$PREFIX/sbin" \
    > "$ROOT/build/ntfs-3g/install.log"

echo "==> Done: $PREFIX"
ls "$PREFIX/lib" "$PREFIX/sbin" "$PREFIX/bin" 2>/dev/null
