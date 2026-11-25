#!/bin/zsh
# Build StickerSend.app and package it into a drag-to-Applications DMG.
set -euo pipefail
cd "${0:A:h}"

./make-app.sh

DMG="StickerSend.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R StickerSend.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "StickerSend" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG"

echo "built $PWD/$DMG"
