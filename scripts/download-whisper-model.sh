#!/bin/zsh
# Download Whisper model + tokenizer into Resources/WhisperModels/.
# Called by package-dmg.sh before xcodebuild. Safe to re-run.
set -euo pipefail

ROOT=${0:A:h:h}
MODEL_VARIANT="openai_whisper-large-v3-v20240930_turbo_632MB"
MODEL_REPO="argmaxinc/whisperkit-coreml"
TOKENIZER_REPO="openai/whisper-large-v3"
DEST="$ROOT/Resources/WhisperModels"
TMP="$ROOT/build/whisper-download"

# Check if already complete (model + tokenizer).
if [[ -d "$DEST/AudioEncoder.mlmodelc" && -f "$DEST/tokenizer.json" ]]; then
  echo "Whisper model + tokenizer already present at $DEST — skipping."
  exit 0
fi

echo "Downloading Whisper model ($MODEL_VARIANT)…"
mkdir -p "$DEST" "$TMP/model" "$TMP/tokenizer"

_hf_download() {
  local repo=$1; local dest=$2; shift 2
  if command -v huggingface-cli &>/dev/null; then
    huggingface-cli download "$repo" "$@" --local-dir "$dest"
  elif python3 -c "import huggingface_hub" 2>/dev/null; then
    python3 - "$repo" "$dest" "$@" <<'PY'
import sys
from huggingface_hub import snapshot_download
repo, dest = sys.argv[1], sys.argv[2]
patterns = sys.argv[3:] if len(sys.argv) > 3 else None
snapshot_download(repo, allow_patterns=patterns, local_dir=dest)
PY
  else
    echo "error: huggingface_hub not found. Install: pip3 install huggingface_hub" >&2
    exit 1
  fi
}

# 1. Download CoreML model weights (mlmodelc directories + config files).
_hf_download "$MODEL_REPO" "$TMP/model" --include "$MODEL_VARIANT/*"

# Flatten: copy model variant contents directly into DEST.
rsync -a --delete "$TMP/model/$MODEL_VARIANT/" "$DEST/"

# 2. Download tokenizer files that WhisperKit needs to decode token IDs.
#    WhisperKit checks modelFolder for tokenizer.json; bundle it alongside the model.
_hf_download "$TOKENIZER_REPO" "$TMP/tokenizer" \
  --include "tokenizer.json" \
  --include "tokenizer_config.json" \
  --include "vocab.json" \
  --include "merges.txt" \
  --include "normalizer.json" \
  --include "special_tokens_map.json" \
  --include "added_tokens.json"

# Copy tokenizer files into the same DEST folder.
for f in tokenizer.json tokenizer_config.json vocab.json merges.txt \
          normalizer.json special_tokens_map.json added_tokens.json; do
  [[ -f "$TMP/tokenizer/$f" ]] && cp "$TMP/tokenizer/$f" "$DEST/$f"
done

rm -rf "$TMP"
echo "Model + tokenizer ready at $DEST"
