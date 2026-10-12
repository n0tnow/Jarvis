#!/bin/zsh
# Sets up the OPTIONAL local embedding helper for JARVIS Project Memory (V0.10, docs/PROJECT_MEMORY.md). Semantic retrieval only: without it Project Memory
# works with structured + lexical retrieval and says that semantic search is unavailable. JARVIS itself never downloads anything.
# - Private virtualenv: ~/Library/Application Support/JARVIS/runtime/memory-venv (onnxruntime, numpy, tokenizers — pinned in scripts/memory-ai/requirements-memory.txt;
#   no PyTorch). System Python is never touched.
# - ONE model, pinned and SHA-256 verified, downloaded only when you run this script:
#       sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2 @ e8f8c211226b894fcb81acc59f3b34ba3efd5f42  (Apache-2.0, int8 ONNX for arm64, 118 MB)
#       → ~/AI/models/memory-minilm-l12   (override with JARVIS_MEMORY_MODEL_DIR)
#   Chosen by measurement among 5 ONNX candidates + Apple NaturalLanguage (docs/PROJECT_MEMORY.md §Embedding research). `--bench` additionally downloads the other
#   benchmark candidates (≈ 2.4 GB, only needed to reproduce scripts/memory-ai/bench).
# Remove everything again with:
#       rm -rf "$HOME/Library/Application Support/JARVIS/runtime/memory-venv" "$HOME/Library/Application Support/JARVIS/runtime/jarvis_embed_worker.py" "$HOME/AI/models/memory-minilm-l12"
set -euo pipefail
ROOT="${0:A:h:h}"
RUNTIME="$HOME/Library/Application Support/JARVIS/runtime"
MVENV="$RUNTIME/memory-venv"
MODEL_DIR="${JARVIS_MEMORY_MODEL_DIR:-$HOME/AI/models/memory-minilm-l12}"
REPO="sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
REV="e8f8c211226b894fcb81acc59f3b34ba3efd5f42"
ONNX_SHA="783fea82d71a58179b830a4dbd2d58447e640609e98eedf9ffa12622d375a672"
TOK_SHA="2c3387be76557bd40970cec13153b3bbf80407865484b209e655e5e4729076b8"
command -v uv >/dev/null || { echo "uv is required (https://docs.astral.sh/uv/)"; exit 1; }
mkdir -p "$RUNTIME" "$MODEL_DIR"
[ -x "$MVENV/bin/python" ] || uv venv --python 3.12 "$MVENV"
uv pip install --python "$MVENV/bin/python" -r "$ROOT/scripts/memory-ai/requirements-memory.txt"
cp "$ROOT/scripts/memory-ai/jarvis_embed_worker.py" "$RUNTIME/jarvis_embed_worker.py"; chmod 600 "$RUNTIME/jarvis_embed_worker.py"
if [ ! -f "$MODEL_DIR/model.onnx" ] || [ ! -f "$MODEL_DIR/tokenizer.json" ]; then
  echo "Downloading $REPO @ $REV → $MODEL_DIR"
  "$MVENV/bin/python" - "$MODEL_DIR" "$REPO" "$REV" <<'PY'
import sys, shutil, os
from huggingface_hub import hf_hub_download
d, repo, rev = sys.argv[1:4]
src = hf_hub_download(repo_id=repo, revision=rev, filename="onnx/model_qint8_arm64.onnx", local_dir=d + "/.dl")
shutil.copyfile(src, d + "/model.onnx")
shutil.copyfile(hf_hub_download(repo_id=repo, revision=rev, filename="tokenizer.json", local_dir=d + "/.dl"), d + "/tokenizer.json")
shutil.copyfile(hf_hub_download(repo_id=repo, revision=rev, filename="config.json", local_dir=d + "/.dl"), d + "/config.json")
shutil.rmtree(d + "/.dl", ignore_errors=True)
PY
fi
[ "$(shasum -a 256 "$MODEL_DIR/model.onnx" | cut -d' ' -f1)" = "$ONNX_SHA" ] || { echo "model.onnx checksum mismatch"; rm -f "$MODEL_DIR/model.onnx"; exit 1; }
[ "$(shasum -a 256 "$MODEL_DIR/tokenizer.json" | cut -d' ' -f1)" = "$TOK_SHA" ] || { echo "tokenizer.json checksum mismatch"; rm -f "$MODEL_DIR/tokenizer.json"; exit 1; }
if [[ "${1:-}" == "--bench" ]]; then
  echo "Downloading the other benchmark candidates into ~/AI/models/memory-bench (≈ 2.4 GB)"
  "$MVENV/bin/python" - <<'PY'
import os
from huggingface_hub import hf_hub_download
R = os.path.expanduser("~/AI/models/memory-bench")
C = {"intfloat/multilingual-e5-small": ("614241f622f53c4eeff9890bdc4f31cfecc418b3", ["onnx/model.onnx", "tokenizer.json", "1_Pooling/config.json", "config.json"]),
     "intfloat/multilingual-e5-base": ("d128750597153bb5987e10b1c3493a34e5a4502a", ["onnx/model.onnx", "tokenizer.json", "1_Pooling/config.json", "config.json"]),
     "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2": ("e8f8c211226b894fcb81acc59f3b34ba3efd5f42", ["onnx/model_qint8_arm64.onnx", "tokenizer.json", "1_Pooling/config.json", "config.json"]),
     "ibm-granite/granite-embedding-107m-multilingual": ("d6cffd338414d6a1c1f5decfad5fec62eebc90d5", ["model.onnx", "tokenizer.json", "1_Pooling/config.json", "config.json"]),
     "Snowflake/snowflake-arctic-embed-m-v2.0": ("95c2741480856aa9666782eb4afe11959938017f", ["onnx/model_int8.onnx", "tokenizer.json", "1_Pooling/config.json", "config.json"])}
for repo, (rev, files) in C.items():
    for f in files: hf_hub_download(repo_id=repo, revision=rev, filename=f, local_dir=os.path.join(R, repo.replace("/", "__")))
PY
fi
"$MVENV/bin/python" -c "import onnxruntime, numpy, tokenizers; print('onnxruntime', onnxruntime.__version__, '· tokenizers', tokenizers.__version__, '· model OK:', '$MODEL_DIR')"
