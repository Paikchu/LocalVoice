#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h:h}
DERIVED="$ROOT/.derived"
OUTPUT="$ROOT/build"

cd "$ROOT"
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

mkdir -p "$OUTPUT"
rm -rf "$OUTPUT/LocalVoice.app"
ditto "$DERIVED/Build/Products/Release/LocalVoice.app" "$OUTPUT/LocalVoice.app"

IDENTITY=$(
  security find-identity -v -p codesigning |
    sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' |
    head -1
)

if [[ -n "$IDENTITY" ]]; then
  for framework in "$OUTPUT/LocalVoice.app/Contents/Frameworks/"*.framework; do
    [[ -d "$framework" ]] || continue
    codesign --force --sign "$IDENTITY" "$framework"
  done
  codesign \
    --force \
    --options runtime \
    --entitlements "$ROOT/Sources/LocalVoiceApp/LocalVoice.entitlements" \
    --sign "$IDENTITY" \
    "$OUTPUT/LocalVoice.app"
else
  codesign \
    --force \
    --entitlements "$ROOT/Sources/LocalVoiceApp/LocalVoice.entitlements" \
    --sign - \
    "$OUTPUT/LocalVoice.app"
fi
