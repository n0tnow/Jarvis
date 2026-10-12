#!/bin/zsh
# Trains the LOCAL "Jarvis" wake-word head (V0.8, docs/NATURAL_VOICE.md) on SYNTHETIC speech and installs it into
#   ~/Library/Application Support/JARVIS/runtime/wake/jarvis_head.npz      (≈ 0.6 MB; never committed, never downloaded)
# Needs `scripts/setup_voice_ai.sh --natural` first (runtime + feature models + the Supertonic 3 voice used to synthesise training speech).
# No recording of any person is used. Takes roughly 20–60 minutes (speech synthesis + embedding + training). Scratch data is deleted afterwards.
#   scripts/train_wake_head.sh [--quick]     --quick: fewer negative sentences (faster, slightly less robust)
set -euo pipefail
ROOT="${0:A:h:h}"
RUNTIME="$HOME/Library/Application Support/JARVIS/runtime"
NPY="$RUNTIME/natural-venv/bin/python"
WAKE_DIR="$RUNTIME/wake"
VOICE_DIR="${JARVIS_SUPERTONIC_DIR:-$HOME/AI/models/supertonic-3}"
[ -x "$NPY" ] && [ -f "$WAKE_DIR/embedding_model.onnx" ] && [ -f "$VOICE_DIR/onnx/vocoder.onnx" ] || { echo "Run scripts/setup_voice_ai.sh --natural first."; exit 1; }
EN=450; TR=260; SETS=(negB negC negD)
[ "${1:-}" = "--quick" ] && { EN=200; TR=120; SETS=(negB negC); }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/jarvis-wake-train.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export SUPERTONIC_CACHE_DIR="$VOICE_DIR" HF_HUB_OFFLINE=1 SUPERTONIC_INTRA_OP_THREADS=2 SUPERTONIC_INTER_OP_THREADS=1
G="$ROOT/scripts/voice-ai/bench/gen_wake_train.py"
echo "Synthesising training speech into $WORK (parallel, a few minutes per part) …"
"$NPY" "$G" "$WORK" --part pos --seed 1 > "$WORK/gen_pos.log" 2>&1 &
"$NPY" "$G" "$WORK" --part hard --seed 1 > "$WORK/gen_hard.log" 2>&1 &
"$NPY" "$G" "$WORK" --part neg --seed 1 > "$WORK/gen_neg.log" 2>&1 &
seed=2
for s in $SETS; do
  "$NPY" "$G" "$WORK" --part neg --name $s --seed $seed --count-en $EN --count-tr $TR > "$WORK/gen_$s.log" 2>&1 &
  seed=$((seed+1))
done
wait
MINE="${(j:,:)SETS[2,-1]}"
echo "Training the head (hard-negative rounds on: $MINE) …"
"$NPY" "$ROOT/scripts/voice-ai/bench/train_wake.py" "$WORK" "$WORK/jarvis_head.npz" --models "$WAKE_DIR" --neg-sets neg,negB --mine-sets "$MINE" --epochs 25 --pos-weight 6
install -m 600 "$WORK/jarvis_head.npz" "$WAKE_DIR/jarvis_head.npz"
echo "Installed $WAKE_DIR/jarvis_head.npz"
