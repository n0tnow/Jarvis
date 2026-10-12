"""JARVIS wake-word head (V0.8): a tiny MLP over openWakeWord's frozen speech embeddings.

Runtime pieces (all local, offline, no network, no API key):
  * mel-spectrogram + Google speech-embedding models (ONNX, Apache-2.0) from the `openwakeword` package (AudioFeatures) - 2.4 MB, frozen
  * `HeadMLP`: 16 embedding frames (1.28 s) x 96 -> 96 hidden -> 1 probability. Weights are trained on SYNTHETIC speech by `bench/train_wake.py`
    (never committed; the training script writes it; installed to ~/Library/Application Support/JARVIS/runtime/wake/jarvis_head.npz by `scripts/setup_voice_ai.sh --wake`).

The same module is imported by the training script, the benchmark and the live helper so all three evaluate exactly the same computation.
"""
import numpy as np

SAMPLE_RATE = 16000
FRAME = 1280                 # 80 ms: one embedding step
WINDOW = 16                  # embedding frames in the classifier input
EMBED_DIM = 96
EMBED_SPAN = 12400           # samples covered by one embedding (76 mel frames)


def embedding_end_seconds(index):
    """Time (s) at which the audio covered by embedding frame `index` ends."""
    return (FRAME * index + EMBED_SPAN) / SAMPLE_RATE


class HeadMLP:
    def __init__(self, w1, b1, w2, b2, mean, std):
        self.w1, self.b1, self.w2, self.b2, self.mean, self.std = w1, b1, w2, b2, mean, std

    @staticmethod
    def load(path):
        d = np.load(path)
        return HeadMLP(d["w1"], d["b1"], d["w2"], d["b2"], d["mean"], d["std"])

    def predict(self, windows):
        """windows: (n, WINDOW, EMBED_DIM) or (n, WINDOW*EMBED_DIM) -> probabilities (n,)."""
        x = np.asarray(windows, dtype=np.float32).reshape(len(windows), -1)
        h = np.maximum((x - self.mean) / self.std @ self.w1 + self.b1, 0.0)
        z = h @ self.w2 + self.b2
        return 1.0 / (1.0 + np.exp(-np.clip(z, -30, 30)))


class WakeStream:
    """Streaming scorer: feed 80 ms int16 frames, get one probability per frame (0 until the embedding buffer is primed)."""

    def __init__(self, head, models_dir):
        from jarvis_audio_features import SpeechFeatures
        self.features = SpeechFeatures(models_dir)
        self.head = head
        self.count = 0

    def reset(self):
        self.features.reset()
        self.count = 0

    def feed(self, frame_int16):
        self.features.feed(np.asarray(frame_int16, dtype=np.int16))
        self.count += 1
        if self.count < 8:                      # the first frames only prime the mel / embedding buffers
            return 0.0
        return float(self.head.predict(self.features.window(WINDOW))[0])
