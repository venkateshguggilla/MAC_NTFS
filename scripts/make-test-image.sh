#!/bin/bash
# Create an NTFS disk image populated with fixture files, for safe testing.
#
# Usage: scripts/make-test-image.sh [name] [size_mb]
# Output: build/fixtures/<name>/{<name>.img, manifest.sha256, files/}
set -euo pipefail

NAME="${1:-basic}"
SIZE_MB="${2:-64}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/ntfs-3g/prefix"
OUT="$ROOT/build/fixtures/$NAME"
IMG="$OUT/$NAME.img"
FILES="$OUT/files"

if [[ ! -x "$BIN/sbin/mkntfs" ]]; then
    echo "ntfs-3g tools not built; run scripts/build-ntfs3g.sh first" >&2
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$FILES"

echo "==> Generating fixture files"
: > "$FILES/empty.txt"                                           # zero length
echo "Hello from macOS. This file is small enough to be resident." \
    > "$FILES/small.txt"                                         # resident in MFT record
head -c 65536    /dev/urandom > "$FILES/medium.bin"              # non-resident, few clusters
head -c 8388608  /dev/urandom > "$FILES/large.bin"               # 8 MiB, many runs
head -c 1000003  /dev/urandom > "$FILES/odd-size.bin"            # not cluster aligned
echo "unicode" > "$FILES/héllo wörld 日本語.txt"                    # non-ASCII name
echo "spaces"  > "$FILES/name with  spaces.txt"
echo "long"    > "$FILES/$(printf 'L%.0s' {1..200}).txt"         # long name (NTFS max 255)

echo "==> Creating ${SIZE_MB} MiB NTFS image"
mkfile -n "${SIZE_MB}m" "$IMG"
# -F: target is a regular file. Geometry flags are required since there is no device to query.
"$BIN/sbin/mkntfs" -F -Q -q -L "$NAME" -s 512 -p 0 -H 255 -S 63 "$IMG"

echo "==> Copying fixtures into image"
(
    cd "$FILES"
    for f in *; do
        "$BIN/sbin/ntfscp" -q "$IMG" "$f" "/$f"
    done
    shasum -a 256 * > "$OUT/manifest.sha256"
)

echo "==> Done: $IMG"
