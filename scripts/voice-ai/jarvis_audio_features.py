"""Streaming speech features for the JARVIS wake head: mel-spectrogram -> Google speech-embedding (96 values per 80 ms).

This is a small re-implementation of the feature path of openWakeWord's `AudioFeatures` (https://github.com/dscripka/openWakeWord, Apache License 2.0,
Copyright 2022 David Scripka) so the runtime needs only onnxruntime + numpy — importing the openwakeword package would pull in its training/network
helpers (requests, scikit-learn) that JARVIS never uses. The two ONNX models are openWakeWord's release assets v0.5.1 (`melspectrogram.onnx`,
`embedding_model.onnx`: Google's speech_embedding model, Apache License 2.0); `scripts/setup_voice_ai.sh --natural` downloads them with pinned checksums.
Equivalence with the original implementation (batch and streaming) is checked by `bench/check_features.py`.
"""
import os
from collections import deque

import numpy as np
import onnxruntime as ort

SAMPLE_RATE = 16000
FRAME = 1280           # 80 ms: one embedding step
MEL_BINS = 32
WINDOW_MELS = 76       # mel frames per embedding
EMBED_DIM = 96
MEL_BUFFER_MAX = 10 * 97
FEATURE_BUFFER_MAX = 120


class SpeechFeatures:
    def __init__(self, models_dir, threads=1):
        so = ort.SessionOptions()
        so.intra_op_num_threads = threads
        so.inter_op_num_threads = threads
        providers = ["CPUExecutionProvider"]
        self.mel = ort.InferenceSession(os.path.join(models_dir, "melspectrogram.onnx"), sess_options=so, providers=providers)
        self.emb = ort.InferenceSession(os.path.join(models_dir, "embedding_model.onnx"), sess_options=so, providers=providers)
        self.reset()

    # ----- batch (training, benchmarks) -----------------------------------------------------------------------------------------------------
    def _mel(self, x):
        x = np.asarray(x)
        if x.dtype != np.int16:
            raise ValueError("audio must be int16 PCM")
        out = self.mel.run(None, {"input": x[None, :].astype(np.float32)})
        return np.squeeze(out[0]) / 10 + 2

    def _embed(self, windows):
        return np.squeeze(self.emb.run(None, {"input_1": windows})[0])

    def embed_clip(self, x):
        """(frames, 96) embeddings of a whole int16 clip (windows of 76 mel frames, step 8)."""
        spec = self._mel(x)
        windows = [spec[i:i + WINDOW_MELS] for i in range(0, spec.shape[0], 8) if spec[i:i + WINDOW_MELS].shape[0] == WINDOW_MELS]
        if not windows:
            return np.zeros((0, EMBED_DIM), dtype=np.float32)
        out = self._embed(np.expand_dims(np.array(windows), axis=-1).astype(np.float32))
        return out.reshape(len(windows), EMBED_DIM)

    # ----- streaming (the live sentinel) ----------------------------------------------------------------------------------------------------
    def reset(self):
        self.raw = deque(maxlen=SAMPLE_RATE * 10)
        self.mel_buffer = np.ones((WINDOW_MELS, MEL_BINS))
        self.accumulated = 0
        self.remainder = np.empty(0, dtype=np.int16)
        rng = np.random.default_rng(0)
        self.features = self.embed_clip(rng.integers(-1000, 1000, SAMPLE_RATE * 4).astype(np.int16))
        self.frames_fed = 0

    def feed(self, x):
        """Adds int16 audio; returns the number of samples now turned into features (a multiple of 1280) or the pending count."""
        x = np.asarray(x, dtype=np.int16)
        processed = 0
        if self.remainder.shape[0]:
            x = np.concatenate((self.remainder, x))
            self.remainder = np.empty(0, dtype=np.int16)
        if self.accumulated + x.shape[0] >= FRAME:
            rest = (self.accumulated + x.shape[0]) % FRAME
            if rest:
                even = x[:-rest]
                self.raw.extend(even.tolist())
                self.accumulated += len(even)
                self.remainder = x[-rest:]
            else:
                self.raw.extend(x.tolist())
                self.accumulated += x.shape[0]
        else:
            self.accumulated += x.shape[0]
            self.raw.extend(x.tolist())
        if self.accumulated >= FRAME and self.accumulated % FRAME == 0:
            n = self.accumulated
            tail = np.array(list(self.raw)[-n - 160 * 3:], dtype=np.int16)
            self.mel_buffer = np.vstack((self.mel_buffer, self._mel(tail)))
            if self.mel_buffer.shape[0] > MEL_BUFFER_MAX:
                self.mel_buffer = self.mel_buffer[-MEL_BUFFER_MAX:, :]
            for i in np.arange(n // FRAME - 1, -1, -1):
                end = -8 * i if i else len(self.mel_buffer)
                window = self.mel_buffer[-WINDOW_MELS + end:end].astype(np.float32)[None, :, :, None]
                if window.shape[1] == WINDOW_MELS:
                    self.features = np.vstack((self.features, self._embed(window).reshape(1, EMBED_DIM)))
            processed = n
            self.accumulated = 0
            self.frames_fed += n // FRAME
        if self.features.shape[0] > FEATURE_BUFFER_MAX:
            self.features = self.features[-FEATURE_BUFFER_MAX:, :]
        return processed if processed else self.accumulated

    def window(self, frames=16):
        return self.features[-frames:, :][None, :].astype(np.float32)
