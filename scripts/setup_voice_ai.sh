#!/bin/zsh
# Sets up the OPTIONAL local speech-to-text runtime used by JARVIS Voice (V0.7, docs/VOICE_IO.md).
# - Creates a private virtualenv under ~/Library/Application Support/JARVIS/runtime/voice-venv (system Python is never touched).
# - Installs ONLY the pinned packages in scripts/voice-ai/requirements.txt (PyPI, via uv) plus mlx-whisper (--no-deps).
# - Downloads ONE model, explicitly, only when you run this script:
#       mlx-community/whisper-small-mlx  (OpenAI Whisper "small" converted to MLX; MIT-licensed upstream; ≈ 460 MB)
#       pinned revision 45f3915923c7a79a5a5b5a7d909d39aeb0e5630e  →  ~/AI/models/whisper-small-mlx   (override with JARVIS_WHISPER_DIR)
#   JARVIS itself never downloads anything. Without this script, Voice still works with Apple's on-device recogniser.
# Remove everything again with:
#       rm -rf "$HOME/Library/Application Support/JARVIS/runtime/voice-venv" "$HOME/Library/Application Support/JARVIS/runtime/jarvis_stt_worker.py" "$HOME/AI/models/whisper-small-mlx"
set -euo pipefail
ROOT="${0:A:h:h}"
RUNTIME="$HOME/Library/Application Support/JARVIS/runtime"
VENV="$RUNTIME/voice-venv"
MODEL_DIR="${JARVIS_WHISPER_DIR:-$HOME/AI/models/whisper-small-mlx}"
REPO="mlx-community/whisper-small-mlx"
REVISION="45f3915923c7a79a5a5b5a7d909d39aeb0e5630e"
command -v uv >/dev/null || { echo "uv is required (https://docs.astral.sh/uv/)"; exit 1; }
mkdir -p "$RUNTIME"
[ -x "$VENV/bin/python" ] || uv venv --python 3.12 "$VENV"
uv pip install --python "$VENV/bin/python" -r "$ROOT/scripts/voice-ai/requirements.txt"
uv pip install --python "$VENV/bin/python" --no-deps mlx-whisper==0.4.3
cp "$ROOT/scripts/voice-ai/jarvis_stt_worker.py" "$RUNTIME/jarvis_stt_worker.py"
chmod 600 "$RUNTIME/jarvis_stt_worker.py"
if [ ! -f "$MODEL_DIR/config.json" ]; then
  echo "Downloading $REPO @ $REVISION → $MODEL_DIR"
  "$VENV/bin/python" - "$REPO" "$REVISION" "$MODEL_DIR" <<'PY'
import sys
from huggingface_hub import snapshot_download
snapshot_download(repo_id=sys.argv[1], revision=sys.argv[2], local_dir=sys.argv[3])
PY
fi
"$VENV/bin/python" -c "import mlx.core as mx, mlx_whisper; print('mlx', getattr(mx,'__version__','?'), '· mlx_whisper OK')"
du -sh "$VENV" "$MODEL_DIR"
