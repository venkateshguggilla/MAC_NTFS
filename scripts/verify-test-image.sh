#!/bin/bash
# Verify an NTFS test image against its manifest.
#  1. Consistency check with ntfsfix (no changes made).
#  2. Read every file back with ntfscat (libntfs-3g) and compare checksums.
#  3. Mount it read-only with macOS's own NTFS driver and compare again.
#     This guards against ntfs-3g only agreeing with itself.
#
# Usage: scripts/verify-test-image.sh [name]
set -euo pipefail

NAME="${1:-basic}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/ntfs-3g/prefix"
OUT="$ROOT/build/fixtures/$NAME"
IMG="$OUT/$NAME.img"
MANIFEST="$OUT/manifest.sha256"

fail=0

echo "==> ntfsfix consistency check"
"$BIN/bin/ntfsfix" -n "$IMG"

check_tree() {  # $1 = label, $2 = command that prints the file named by $f
    local label="$1" reader="$2" expected actual f
    while read -r expected f; do
        f="${f# }"; f="${f#\*}"
        actual="$(eval "$reader" | shasum -a 256 | cut -d' ' -f1)"
        if [[ "$actual" == "$expected" ]]; then
            echo "  ok    [$label] $f"
        else
            echo "  FAIL  [$label] $f"
            fail=1
        fi
    done < "$MANIFEST"
}

echo "==> Reading back via libntfs-3g"
check_tree "ntfs-3g" '"$BIN/bin/ntfscat" "$IMG" "/$f"'

echo "==> Reading back via macOS NTFS driver"
DEV="$(hdiutil attach -readonly -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" \
       | awk 'NR==1 {print $1}')"
MNT="$(mktemp -d)"
trap 'umount "$MNT" 2>/dev/null; hdiutil detach -quiet "$DEV" 2>/dev/null; rmdir "$MNT" 2>/dev/null' EXIT
diskutil quiet mount readOnly -mountPoint "$MNT" "$DEV"
check_tree "macOS" 'cat "$MNT/$f"'

if [[ $fail -ne 0 ]]; then
    echo "==> VERIFY FAILED"
    exit 1
fi
echo "==> All checks passed"
