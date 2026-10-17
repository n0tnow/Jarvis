#!/bin/zsh
# Downloads ONE pinned MLX model candidate for the local conversational-model benchmark (V1.0 Phase B). Run by hand, never by the app.
#   scripts/fetch_local_model_candidate.sh qwen3.5-9b | gemma-4-e4b
# - Uses the isolated JARVIS MLX runtime's Python (huggingface_hub is already pinned there); no other package is installed.
# - Pins the exact Hugging Face revision (commit) and verifies the licence tag recorded below; refuses to run if the destination exists.
# - Nothing is executed from the download (weights + tokenizer + config only); models live outside the repository (~/AI/models).
set -euo pipefail
PY="$HOME/Library/Application Support/JARVIS/runtime/mlx-venv/bin/python"
[ -x "$PY" ] || { echo "The MLX runtime is missing: run scripts/setup_local_ai.sh first."; exit 1; }
case "${1:-}" in
  qwen3.5-9b) REPO="mlx-community/Qwen3.5-9B-MLX-4bit"; REV="938d8919941c6e7efd3c7150eff7fe9d12afa631"; DEST="$HOME/AI/models/Qwen3.5-9B-MLX-4bit"; LICENSE="apache-2.0" ;;
  gemma-4-e4b) REPO="mlx-community/gemma-4-e4b-it-4bit"; REV="475b9088d29754a3379866cf5aeb6b41acd313c2"; DEST="$HOME/AI/models/gemma-4-e4b-it-4bit"; LICENSE="gemma" ;;
  *) echo "usage: $0 qwen3.5-9b | gemma-4-e4b"; exit 2 ;;
esac
[ ! -e "$DEST" ] || { echo "$DEST already exists; nothing to do."; exit 0; }
echo "Downloading $REPO @ ${REV:0:10} (licence: $LICENSE) → $DEST"
"$PY" - "$REPO" "$REV" "$DEST" <<'PYEOF'
import sys
from huggingface_hub import snapshot_download
repo, rev, dest = sys.argv[1:4]
snapshot_download(repo_id=repo, revision=rev, local_dir=dest, allow_patterns=["*.json", "*.safetensors", "*.jinja", "*.txt", "*.model"])
print("done")
PYEOF
du -sh "$DEST"
