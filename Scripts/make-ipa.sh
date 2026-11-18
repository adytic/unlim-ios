#!/usr/bin/env bash
# Build an UNSIGNED .ipa for sideloading with SideStore / AltStore.
#
# Packaging pattern adapted from PhotosBackup's Scripts/make-ipa.sh
# (project structure only — the app itself is Unlim, a Telegram
# Saved Messages client, not a Google Photos client).
#
# The output is deliberately unsigned: SideStore re-signs it on device with
# the user's own Apple ID. DEVELOPER_DIR may be set by CI to pin an Xcode
# version; otherwise the default Xcode is used.
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -n "${DEVELOPER_DIR:-}" ]; then export DEVELOPER_DIR; fi

CONFIG="${1:-Release}"
BUILD_DIR="$(mktemp -d)"
OUT="$PWD/build/Unlim.ipa"

command -v xcodegen >/dev/null || { echo "xcodegen not found" >&2; exit 1; }
xcodegen generate

xcodebuild -project Unlim.xcodeproj -scheme Unlim \
  -sdk iphoneos -configuration "$CONFIG" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  -derivedDataPath "$BUILD_DIR" build

APP="$BUILD_DIR/Build/Products/$CONFIG-iphoneos/Unlim.app"
[ -d "$APP" ] || { echo "no .app at $APP" >&2; exit 1; }

STAGE="$BUILD_DIR/stage"
mkdir -p "$STAGE/Payload" "$PWD/build"
cp -R "$APP" "$STAGE/Payload/"
rm -f "$OUT"
( cd "$STAGE" && zip -qry "$OUT" Payload )
rm -rf "$BUILD_DIR"

echo "Unsigned IPA: $OUT ($(du -h "$OUT" | cut -f1))"
echo "Install by opening it in SideStore; it signs with your Apple ID on device."
