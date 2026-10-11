#!/bin/zsh
# Sets up the isolated MLX runtime used by JARVIS's local lightweight model (V0.3.1, DEC-023).
# - Creates a private virtualenv under ~/Library/Application Support/Jarvis/runtime (system Python is never touched).
# - Installs ONLY the pinned packages in scripts/local-ai/requirements.txt (PyPI, via uv).
# - Does NOT download any model. The model must already exist (default ~/AI/models/Qwen3.5-4B-MLX-4bit).
# Remove everything again with:  rm -rf "$HOME/Library/Application Support/Jarvis/runtime"
set -euo pipefail
ROOT="${0:A:h:h}"
RUNTIME="$HOME/Library/Application Support/Jarvis/runtime"
VENV="$RUNTIME/mlx-venv"
command -v uv >/dev/null || { echo "uv is required (https://docs.astral.sh/uv/)"; exit 1; }
mkdir -p "$RUNTIME"
[ -x "$VENV/bin/python" ] || uv venv --python 3.12 "$VENV"
uv pip install --python "$VENV/bin/python" -r "$ROOT/scripts/local-ai/requirements.txt"
"$VENV/bin/python" -c "import mlx.core as mx, mlx_vlm; print('mlx', mx.__version__ if hasattr(mx,'__version__') else '?', '· mlx_vlm OK')"
du -sh "$VENV"
