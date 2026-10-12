#!/usr/bin/env python3
"""Numerical equivalence of jarvis_audio_features.SpeechFeatures with openWakeWord's AudioFeatures (needs `openwakeword` installed — research venv only).

    python check_features.py <models-dir with melspectrogram.onnx + embedding_model.onnx> <some 16 kHz wav>
"""
import os, sys
import numpy as np
from scipy.io import wavfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from jarvis_audio_features import SpeechFeatures  # noqa: E402
from openwakeword.utils import AudioFeatures  # noqa: E402

models, wav = sys.argv[1], sys.argv[2]
sr, x = wavfile.read(wav)
x = x[: 16000 * 6].astype(np.int16)
mine = SpeechFeatures(models)
ref = AudioFeatures(melspec_model_path=os.path.join(models, "melspectrogram.onnx"), embedding_model_path=os.path.join(models, "embedding_model.onnx"), inference_framework="onnx")
a = mine.embed_clip(x)
b = ref.embed_clips(x[None, :], batch_size=1)[0]
n = min(len(a), len(b))
print("batch  : frames", len(a), len(b), "max abs diff", float(np.abs(a[:n] - b[:n]).max()))
mine.reset(); ref.reset()
worst = 0.0
for k, i in enumerate(range(0, len(x) - 1279, 1280)):
    mine.feed(x[i:i + 1280]); ref(x[i:i + 1280])
    if k >= 24:       # after 16+ real frames both windows are made only of real audio (the primed history is random noise in the original)
        wa, wb = mine.window(16), ref.get_features(16)
        worst = max(worst, float(np.abs(wa - wb).max()))
print("stream : max abs diff of the 16-frame window once primed with real audio", worst)
