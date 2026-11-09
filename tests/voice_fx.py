"""Voice colour presets for the game cast (Silero v5_ru + plain DSP).

Silero gives one timbre per speaker: no growl, no rasp, no air. Everything below
is ordinary DSP on top of the synthesised take, so every character stays
intelligible and no model retraining is involved.

Order matters: pitch first (it moves formants), then colour (shelves,
saturation, roughness), then loudness (RMS + limiter) last.

Only the offline generator imports this module: it needs torch, torchaudio and
scipy from the ComfyUI venv, not the game runtime.
"""
from __future__ import annotations

import numpy as np
import torch
import torchaudio
from scipy.signal import butter, sosfilt

SR = 48000


def pitch(x: np.ndarray, semitones: float, sr: int = SR) -> np.ndarray:
    """Shift pitch without changing duration.

    `n_steps` is measured in `1 / bins_per_octave` octaves, so semitones must go
    with the default `bins_per_octave=12`; asking for 120 bins and passing -3
    shifts by 0.3 semitone instead of 3 (a silent no-op, measured). The 2048
    window is for a 23 Hz resolution at 48 kHz, otherwise deep voices smear.
    """
    if abs(semitones) < 0.01:
        return x
    t = torch.from_numpy(np.ascontiguousarray(x, dtype=np.float32)).reshape(1, -1)
    out = torchaudio.functional.pitch_shift(
        t, sr, n_steps=semitones, bins_per_octave=12, n_fft=2048, hop_length=512)
    return out.reshape(-1).numpy()


def _lp(x: np.ndarray, freq: float, sr: int = SR, order: int = 2) -> np.ndarray:
    sos = butter(order, freq / (sr / 2), btype="low", output="sos")
    return sosfilt(sos, x).astype(np.float32)


def _hp(x: np.ndarray, freq: float, sr: int = SR, order: int = 2) -> np.ndarray:
    sos = butter(order, freq / (sr / 2), btype="high", output="sos")
    return sosfilt(sos, x).astype(np.float32)


def low_shelf(x: np.ndarray, freq: float, gain_db: float, sr: int = SR) -> np.ndarray:
    """Chest resonance: add a scaled lowpassed copy (no biquad phase tricks)."""
    g = 10 ** (gain_db / 20.0) - 1.0
    return (x + g * _lp(x, freq, sr)).astype(np.float32)


def high_shelf(x: np.ndarray, freq: float, gain_db: float, sr: int = SR) -> np.ndarray:
    g = 10 ** (gain_db / 20.0) - 1.0
    return (x + g * _hp(x, freq, sr)).astype(np.float32)


def saturate(x: np.ndarray, drive: float = 2.2) -> np.ndarray:
    """Soft clip: odd harmonics read as a growl on a low male voice."""
    return (np.tanh(x * drive) / np.tanh(drive)).astype(np.float32)


def roughness(x: np.ndarray, rate_hz: float = 34.0, depth: float = 0.30,
              seed: int = 7, sr: int = SR) -> np.ndarray:
    """Irregular amplitude flutter — the audible half of a hoarse voice."""
    rng = np.random.default_rng(seed)
    noise = rng.standard_normal(len(x)).astype(np.float32)
    flutter = _lp(noise, rate_hz, sr, order=2)
    std = float(flutter.std()) or 1.0
    flutter = np.clip(flutter / (std * 2.0), -1.0, 1.0)
    return (x * (1.0 + depth * flutter)).astype(np.float32)


def breath(x: np.ndarray, amount: float = 0.05, seed: int = 11,
           sr: int = SR) -> np.ndarray:
    """Noise gated by the signal envelope: air, not a constant hiss."""
    rng = np.random.default_rng(seed)
    noise = _hp(rng.standard_normal(len(x)).astype(np.float32), 1500.0, sr)
    env = _lp(np.abs(x), 24.0, sr, order=2)
    peak = float(env.max()) or 1.0
    return (x + noise * env / peak * amount).astype(np.float32)


def rms_db(x: np.ndarray) -> float:
    return 20.0 * np.log10(max(float(np.sqrt((x ** 2).mean())), 1e-12))


def set_rms(x: np.ndarray, target_db: float) -> np.ndarray:
    return (x * 10 ** ((target_db - rms_db(x)) / 20.0)).astype(np.float32)


def limit(x: np.ndarray, ceiling_db: float = -1.0) -> np.ndarray:
    """Soft ceiling: only the overshoot is bent, the body stays untouched."""
    ceiling = 10 ** (ceiling_db / 20.0)
    if float(np.abs(x).max()) <= ceiling:
        return x
    return (np.tanh(x / ceiling * 1.15) * ceiling).astype(np.float32)


def trim(x: np.ndarray, thresh_db: float = -50.0, pad_ms: float = 25.0,
         sr: int = SR) -> np.ndarray:
    """Cut the synthesised silence, then put back a short lead-in (no click)."""
    idx = np.where(np.abs(x) > 10 ** (thresh_db / 20.0))[0]
    if idx.size == 0:
        return x
    pad = int(pad_ms * sr / 1000)
    out = x[max(0, int(idx[0]) - pad):min(len(x), int(idx[-1]) + pad)].copy()
    fade = int(0.006 * sr)
    if len(out) > 3 * fade:
        out[:fade] *= np.linspace(0.0, 1.0, fade, dtype=np.float32)
        out[-fade:] *= np.linspace(1.0, 0.0, fade, dtype=np.float32)
    return out


def fade_out(x: np.ndarray, seconds: float, sr: int = SR) -> np.ndarray:
    n = min(len(x), int(seconds * sr))
    if n <= 1:
        return x
    out = x.copy()
    out[-n:] *= np.linspace(1.0, 0.0, n, dtype=np.float32) ** 1.5
    return out


# --- character presets -------------------------------------------------------
# pitch: semitones; low/shelf: tone; sat: growl; rough: hoarse flutter;
# breath: air; lp: top end; rms: dialogue level (barks sit hotter).
# Character pitch lives in the SSML `pitch` of `voice_lines.json` instead:
# Silero's own prosody is free and artifact-free, while a phase-vocoder shift
# of a deep male voice costs ~2 minutes per second of audio and smears formants.
PRESETS = {
    "human": {"pitch": 0.0, "shelf": None, "sat": 0.0, "rough": 0.0,
              "breath": 0.0, "low": 0.0, "lp": 0.0, "rms": -20.0, "fade": 0.0},
    "ork": {"pitch": 0.0, "shelf": None, "sat": 2.4, "rough": 0.0,
            "breath": 0.0, "low": 4.0, "lp": 9000.0, "rms": -19.0, "fade": 0.0},
    "necro": {"pitch": 0.0, "shelf": None, "sat": 1.5, "rough": 0.34,
              "breath": 0.07, "low": 2.0, "lp": 7000.0, "rms": -20.0, "fade": 0.0},
    "druid": {"pitch": 0.0, "shelf": (6000.0, 2.5), "sat": 0.0, "rough": 0.0,
              "breath": 0.02, "low": 0.0, "lp": 0.0, "rms": -22.0, "fade": 0.0},
    "bark": {"pitch": 0.0, "shelf": (3000.0, 3.0), "sat": 0.0, "rough": 0.0,
             "breath": 0.0, "low": -2.0, "lp": 0.0, "rms": -17.0, "fade": 0.0},
    "death": {"pitch": 0.0, "shelf": None, "sat": 0.0, "rough": 0.15,
              "breath": 0.04, "low": 1.0, "lp": 6500.0, "rms": -21.0, "fade": 0.55},
}


def apply_preset(x: np.ndarray, preset: str, sr: int = SR) -> np.ndarray:
    p = PRESETS[preset]
    y = pitch(x, float(p["pitch"]), sr)
    if p["low"]:
        y = low_shelf(y, 200.0, float(p["low"]), sr)
    if p["shelf"]:
        freq, gain = p["shelf"]
        y = high_shelf(y, float(freq), float(gain), sr)
    if p["sat"]:
        y = saturate(y, float(p["sat"]))
    if p["rough"]:
        y = roughness(y, depth=float(p["rough"]), sr=sr)
    if p["breath"]:
        y = breath(y, amount=float(p["breath"]), sr=sr)
    if p["lp"]:
        y = _lp(y, float(p["lp"]), sr, order=2)
    y = trim(y, sr=sr)
    if p["fade"]:
        y = fade_out(y, float(p["fade"]), sr)
    y = set_rms(y, float(p["rms"]))
    return limit(y)
