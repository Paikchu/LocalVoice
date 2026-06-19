#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h:h}
DERIVED="$ROOT/.derived"
OUTPUT="$ROOT/build"
SIGNING_IDENTITY=98F70D2FBDB5468291D95F9A2ED8CE3AC1F770DB
MODEL_SRC="$ROOT/Resources/WhisperModels"
MODEL_DST="$OUTPUT/LocalVoice.app/Contents/Resources/WhisperModels"

cd "$ROOT"
if ! security find-identity -v -p codesigning |
  grep -Fq "$SIGNING_IDENTITY"; then
  echo "Missing required LocalVoice signing identity: $SIGNING_IDENTITY" >&2
  exit 1
fi

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

# Bundle Whisper model if present — skip silently for dev builds without it.
if [[ -d "$MODEL_SRC" && -n "$(ls -A "$MODEL_SRC")" ]]; then
  echo "Bundling Whisper model into app…"
  rm -rf "$MODEL_DST"
  ditto "$MODEL_SRC" "$MODEL_DST"
  echo "Model bundled ($(du -sh "$MODEL_DST" | cut -f1))"
else
  echo "No model at $MODEL_SRC — app will download on first use."
fi

for framework in "$OUTPUT/LocalVoice.app/Contents/Frameworks/"*.framework; do
  [[ -d "$framework" ]] || continue
  codesign --force --sign "$SIGNING_IDENTITY" "$framework"
done
codesign \
  --force \
  --options runtime \
  --entitlements "$ROOT/Sources/LocalVoiceApp/LocalVoice.entitlements" \
  --sign "$SIGNING_IDENTITY" \
  "$OUTPUT/LocalVoice.app"

codesign --verify --deep --strict --verbose=2 "$OUTPUT/LocalVoice.app"
