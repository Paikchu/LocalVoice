#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h:h}
DERIVED="$ROOT/.derived-release"
OUTPUT="$ROOT/build/releases"
STAGING="$ROOT/build/dmg-staging"
APP="$STAGING/LocalVoice.app"

cd "$ROOT"

# Bundle the Whisper model into Resources/ before the build picks it up.
zsh "$ROOT/scripts/download-whisper-model.sh"

xcodegen generate
xcodebuild \
  -project LocalVoice.xcodeproj \
  -scheme LocalVoice \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath "$ROOT/.packages" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  build

VERSION=$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$DERIVED/Build/Products/Release/LocalVoice.app/Contents/Info.plist"
)
DMG_NAME="LocalVoice-${VERSION}-arm64.dmg"
DMG="$OUTPUT/$DMG_NAME"

rm -rf "$STAGING"
mkdir -p "$STAGING" "$OUTPUT"
ditto "$DERIVED/Build/Products/Release/LocalVoice.app" "$APP"

# Bundle Whisper model (downloaded above by download-whisper-model.sh).
MODEL_SRC="$ROOT/Resources/WhisperModels"
MODEL_DST="$APP/Contents/Resources/WhisperModels"
echo "Bundling Whisper model into DMG app…"
rm -rf "$MODEL_DST"
ditto "$MODEL_SRC" "$MODEL_DST"
echo "Model bundled ($(du -sh "$MODEL_DST" | cut -f1))"

while IFS= read -r code; do
  codesign --force --sign - "$code"
done < <(
  find "$APP/Contents" -depth \
    \( -type d -name '*.framework' -o -type f -name '*.dylib' \) \
    -print
)

codesign \
  --force \
  --options runtime \
  --entitlements "$ROOT/Sources/LocalVoiceApp/LocalVoice.entitlements" \
  --sign - \
  "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "LocalVoice" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG"

hdiutil verify "$DMG"
(
  cd "$OUTPUT"
  shasum -a 256 "$DMG_NAME" > SHA256SUMS
)

rm -rf "$STAGING"
echo "Created: $DMG"
echo "Checksum: $OUTPUT/SHA256SUMS"
