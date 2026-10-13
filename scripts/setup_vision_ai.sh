#!/bin/zsh
# Sets up the OPTIONAL local visual-grounding helper for JARVIS (V0.13, docs/VISUAL_GROUNDING.md). Without it JARVIS still reads text labels with Apple's on-device text
# recognition and says plainly that icon-only controls and 3D scenes need the model. JARVIS itself never downloads anything.
# - Private virtualenv: ~/Library/Application Support/JARVIS/runtime/vision-venv (mlx-vlm + dependencies, pinned in scripts/vision-ai/requirements-vision.txt; no PyTorch).
# - Models (Apache-2.0, 4-bit MLX, pinned by revision, downloaded only when you run this script):
#       --model 4b (default)  mlx-community/Qwen3-VL-4B-Instruct-4bit @ 2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b  (≈ 3.1 GB, ≈ 3.2 GB resident while loaded)
#       --model 2b            mlx-community/Qwen3-VL-2B-Instruct-4bit @ 9c4f5209e57b31f4b9dfba735de3fb983739c9cc  (≈ 1.8 GB, ≈ 2.0 GB resident)
#   → ~/AI/models/vision/<name>   (override with JARVIS_VISION_MODEL_DIR)
# Remove everything again with:
#       rm -rf "$HOME/Library/Application Support/JARVIS/runtime/vision-venv" "$HOME/Library/Application Support/JARVIS/runtime/jarvis_vision_worker.py" "$HOME/AI/models/vision"
set -euo pipefail
ROOT="${0:A:h:h}"
RUNTIME="$HOME/Library/Application Support/JARVIS/runtime"
VENV="$RUNTIME/vision-venv"
MODELS="${JARVIS_VISION_MODEL_DIR:-$HOME/AI/models/vision}"
WHICH="${2:-4b}"
[[ "${1:-}" == "--model" ]] || WHICH="4b"
command -v uv >/dev/null || { echo "uv is required (https://docs.astral.sh/uv/)"; exit 1; }
mkdir -p "$RUNTIME" "$MODELS"
[ -x "$VENV/bin/python" ] || uv venv --python 3.12 "$VENV"
uv pip install --python "$VENV/bin/python" -r "$ROOT/scripts/vision-ai/requirements-vision.txt"
cp "$ROOT/scripts/vision-ai/jarvis_vision_worker.py" "$RUNTIME/jarvis_vision_worker.py"; chmod 600 "$RUNTIME/jarvis_vision_worker.py"
fetch() { # repo, revision, dir
  [ -f "$MODELS/$3/config.json" ] && { echo "$3 already present"; return; }
  echo "Downloading $1 @ $2 → $MODELS/$3"
  "$VENV/bin/python" - "$1" "$2" "$MODELS/$3" <<'PY'
import sys
from huggingface_hub import snapshot_download
snapshot_download(repo_id=sys.argv[1], revision=sys.argv[2], local_dir=sys.argv[3])
PY
}
case "$WHICH" in
  4b) fetch mlx-community/Qwen3-VL-4B-Instruct-4bit 2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b Qwen3-VL-4B-Instruct-4bit ;;
  2b) fetch mlx-community/Qwen3-VL-2B-Instruct-4bit 9c4f5209e57b31f4b9dfba735de3fb983739c9cc Qwen3-VL-2B-Instruct-4bit ;;
  both) fetch mlx-community/Qwen3-VL-4B-Instruct-4bit 2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b Qwen3-VL-4B-Instruct-4bit; fetch mlx-community/Qwen3-VL-2B-Instruct-4bit 9c4f5209e57b31f4b9dfba735de3fb983739c9cc Qwen3-VL-2B-Instruct-4bit ;;
  *) echo "usage: setup_vision_ai.sh [--model 4b|2b|both]"; exit 2 ;;
esac
"$VENV/bin/python" -c "import mlx_vlm, mlx.core as mx; print('mlx-vlm OK · Metal', mx.metal.is_available())"
