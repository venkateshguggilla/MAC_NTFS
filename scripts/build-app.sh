#!/bin/bash
# Build MAC_NTFS.app with the FSKit module embedded.
#
#   scripts/build-app.sh                 ad-hoc signed (compiles and launches,
#                                        but macOS won't load the FSKit module)
#   SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" \
#   PROVISIONING_PROFILE=path/to/fsmodule.provisionprofile \
#   scripts/build-app.sh                 signed with your team; the module loads
#                                        once enabled in System Settings
#
# Output: build/app/MAC_NTFS.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ARCH="${ARCH:-$(uname -m)}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="$ARCH-apple-macos26.0"

APP="build/app/MAC_NTFS.app"
APPEX="$APP/Contents/Extensions/NTFSModule.appex"

echo "==> Building engine"
make -s build/out/libmn.a

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APPEX/Contents/MacOS"

echo "==> Compiling FSKit module"
xcrun swiftc -O -parse-as-library -target "$TARGET" -sdk "$SDK" \
    -module-name NTFSModule \
    -import-objc-header engine/include/mn.h \
    fskit/Sources/*.swift \
    build/out/libmn.a build/ntfs-3g/prefix/lib/libntfs-3g.a \
    -framework CoreFoundation -framework FSKit \
    -o "$APPEX/Contents/MacOS/NTFSModule"
cp fskit/Info.plist "$APPEX/Contents/Info.plist"

echo "==> Compiling app"
xcrun swiftc -O -parse-as-library -target "$TARGET" -sdk "$SDK" \
    -module-name MacNTFS \
    app/Sources/*.swift \
    -framework SwiftUI -framework DiskArbitration \
    -o "$APP/Contents/MacOS/MacNTFS"
cp app/Info.plist "$APP/Contents/Info.plist"

echo "==> Signing ($SIGN_IDENTITY)"
if [[ -n "${PROVISIONING_PROFILE:-}" ]]; then
    cp "$PROVISIONING_PROFILE" "$APPEX/Contents/embedded.provisionprofile"
fi
# Inside out: the extension first, then the app that contains it.
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" \
    --entitlements fskit/NTFSModule.entitlements "$APPEX"
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Done: $APP"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "    Ad-hoc signed: the FSKit module needs a Developer ID / Apple Development"
    echo "    signature with the FSKit entitlement before macOS will load it."
fi
