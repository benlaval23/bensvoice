#!/bin/bash
# Downloads the Parakeet TDT 0.6B v2 CoreML model (~450 MB) from Hugging Face.
# Uses the same folder as FluidVoice/FluidAudio, so if you already have FluidVoice you can skip this.
set -euo pipefail

REPO="FluidInference/parakeet-tdt-0.6b-v2-coreml"
DEST="${1:-$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2-coreml}"
PARTS=(Preprocessor.mlmodelc Encoder.mlmodelc Decoder.mlmodelc JointDecision.mlmodelc)

mkdir -p "$DEST"
files=$(for part in "${PARTS[@]}"; do
    curl -fsSL "https://huggingface.co/api/models/$REPO/tree/main/$part?recursive=true" |
        python3 -c "import json,sys; [print(f['path']) for f in json.load(sys.stdin) if f['type'] == 'file']"
done; echo parakeet_vocab.json)

for f in $files; do
    echo "↓ $f"
    mkdir -p "$DEST/$(dirname "$f")"
    curl -fL --progress-bar -o "$DEST/$f" "https://huggingface.co/$REPO/resolve/main/$f"
done
echo "Model saved to $DEST"
