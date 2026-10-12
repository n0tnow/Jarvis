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
#
# V0.8 — natural voice (OPTIONAL, explicit):  scripts/setup_voice_ai.sh --natural
# - Creates a second private virtualenv, ~/Library/Application Support/JARVIS/runtime/natural-venv (onnxruntime, numpy, scipy, supertonic, soundfile; pinned in
#   scripts/voice-ai/requirements-natural.txt — no PyTorch, no MLX).
# - Downloads pinned model files, ONLY when you run this script:
#       wake word / VAD feature models  github.com/dscripka/openWakeWord release v0.5.1  (melspectrogram.onnx, embedding_model.onnx: Apache-2.0;
#                                       silero_vad.onnx: MIT)  → ~/Library/Application Support/JARVIS/runtime/wake/   (≈ 4.2 MB, SHA-256 verified)
#       neural voice                    Supertone/supertonic-3 @ 724fb5abbf5502583fb520898d45929e62f02c0b (ONNX, OpenRAIL-M weights, MIT code, ≈ 400 MB)
#                                       → ~/AI/models/supertonic-3   (override with JARVIS_SUPERTONIC_DIR)
# - The wake-word HEAD ("Jarvis", ≈ 0.6 MB) is trained locally on synthetic speech by scripts/train_wake_head.sh (not downloaded, not committed).
# Remove everything of V0.8 again with:
#       rm -rf "$HOME/Library/Application Support/JARVIS/runtime/natural-venv" "$HOME/Library/Application Support/JARVIS/runtime/wake" "$HOME/AI/models/supertonic-3"
#       rm -f "$HOME/Library/Application Support/JARVIS/runtime/"jarvis_{sentinel_worker,tts_worker,wake_head,audio_features}.py
set -euo pipefail
ROOT="${0:A:h:h}"
RUNTIME="$HOME/Library/Application Support/JARVIS/runtime"
if [[ "${1:-}" == "--natural" ]]; then
  NVENV="$RUNTIME/natural-venv"
  WAKE_DIR="$RUNTIME/wake"
  VOICE_DIR="${JARVIS_SUPERTONIC_DIR:-$HOME/AI/models/supertonic-3}"
  OWW_URL="https://github.com/dscripka/openWakeWord/releases/download/v0.5.1"
  command -v uv >/dev/null || { echo "uv is required (https://docs.astral.sh/uv/)"; exit 1; }
  mkdir -p "$RUNTIME" "$WAKE_DIR"
  [ -x "$NVENV/bin/python" ] || uv venv --python 3.12 "$NVENV"
  uv pip install --python "$NVENV/bin/python" -r "$ROOT/scripts/voice-ai/requirements-natural.txt"
  for f in jarvis_sentinel_worker.py jarvis_tts_worker.py jarvis_wake_head.py jarvis_audio_features.py; do
    cp "$ROOT/scripts/voice-ai/$f" "$RUNTIME/$f"; chmod 600 "$RUNTIME/$f"
  done
  fetch() {  # name sha256
    local name="$1" sha="$2"
    if [ ! -f "$WAKE_DIR/$name" ]; then
      echo "Downloading $name (openWakeWord v0.5.1 release asset)"
      curl -fsSL "$OWW_URL/$name" -o "$WAKE_DIR/$name.part"
      [ "$(shasum -a 256 "$WAKE_DIR/$name.part" | cut -d' ' -f1)" = "$sha" ] || { rm -f "$WAKE_DIR/$name.part"; echo "checksum mismatch for $name"; exit 1; }
      mv "$WAKE_DIR/$name.part" "$WAKE_DIR/$name"
    fi
  }
  fetch melspectrogram.onnx ba2b0e0f8b7b875369a2c89cb13360ff53bac436f2895cced9f479fa65eb176f
  fetch embedding_model.onnx 70d164290c1d095d1d4ee149bc5e00543250a7316b59f31d056cff7bd3075c1f
  fetch silero_vad.onnx a35ebf52fd3ce5f1469b2a36158dba761bc47b973ea3382b3186ca15b1f5af28
  if [ ! -f "$VOICE_DIR/onnx/vocoder.onnx" ]; then
    echo "Downloading Supertone/supertonic-3 @ 724fb5abbf5502583fb520898d45929e62f02c0b → $VOICE_DIR"
    "$NVENV/bin/python" - "$VOICE_DIR" <<'PY'
import sys
from huggingface_hub import snapshot_download
snapshot_download(repo_id="Supertone/supertonic-3", revision="724fb5abbf5502583fb520898d45929e62f02c0b", local_dir=sys.argv[1],
                  allow_patterns=["onnx/*", "voice_styles/M*.json", "LICENSE", "README.md", "config.json"])
PY
  fi
  "$NVENV/bin/python" -c "import onnxruntime, supertonic, numpy; print('onnxruntime', onnxruntime.__version__, '· supertonic', supertonic.__version__)"
  du -sh "$NVENV" "$WAKE_DIR" "$VOICE_DIR"
  if [ -f "$WAKE_DIR/jarvis_head.npz" ]; then echo "wake head present: $WAKE_DIR/jarvis_head.npz"; else echo "NEXT: scripts/train_wake_head.sh  (trains the local “Jarvis” wake head; ≈ 20–60 min)"; fi
  exit 0
fi
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
