#!/bin/zsh
# Download the bundled WhisperKit model into Resources/WhisperModels/.
# Called by package-dmg.sh before xcodebuild. Safe to re-run (skips if
# the model is already present).
set -euo pipefail

ROOT=${0:A:h:h}
MODEL_VARIANT="openai_whisper-large-v3-v20240930_turbo_632MB"
REPO="argmaxinc/whisperkit-coreml"
DEST="$ROOT/Resources/WhisperModels"
TMP="$ROOT/build/whisper-download"

# Skip if already downloaded (check for AudioEncoder as a proxy).
if [[ -d "$DEST/AudioEncoder.mlmodelc" ]]; then
  echo "Whisper model already present at $DEST — skipping download."
  exit 0
fi

echo "Downloading Whisper model ($MODEL_VARIANT) from $REPO …"
mkdir -p "$DEST" "$TMP"

# Prefer huggingface-cli (ships with huggingface_hub >= 0.17).
# Fall back to python3 -m huggingface_hub.
if command -v huggingface-cli &>/dev/null; then
  huggingface-cli download "$REPO" \
    --include "$MODEL_VARIANT/*" \
    --local-dir "$TMP"
elif python3 -c "import huggingface_hub" 2>/dev/null; then
  python3 - <<PY
from huggingface_hub import snapshot_download
snapshot_download(
    "$REPO",
    allow_patterns=["$MODEL_VARIANT/*"],
    local_dir="$TMP",
)
PY
else
  echo "error: huggingface_hub not found."
  echo "Install it with:  pip3 install huggingface_hub"
  exit 1
fi

# Flatten one level: copy model variant contents directly into DEST so
# WhisperKit can load from the folder without knowing the variant name.
rsync -a --delete "$TMP/$MODEL_VARIANT/" "$DEST/"
rm -rf "$TMP"

echo "Model ready at $DEST"
