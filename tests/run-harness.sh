#!/bin/bash
# Run the FSKit volume harness on a fresh image, then check the image.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/ntfs-3g/prefix"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
IMG="$TMP/harness.img"
mkfile -n 64m "$IMG"
"$BIN/sbin/mkntfs" -F -Q -q -s 512 -p 0 -H 255 -S 63 "$IMG" 2>/dev/null
"$ROOT/build/out/volume-harness" "$IMG"
"$BIN/bin/ntfsfix" -n "$IMG" > /dev/null && echo "==> image consistent after harness"
