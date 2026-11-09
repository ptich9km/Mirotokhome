#!/usr/bin/env python3
"""Game voice-over with Silero v5_ru (local, free, deterministic).

Replaces the ElevenLabs/KodikRouter route for this machine: the stock library
voices (george/bella) are native US English speakers, so Russian came out with
an American accent. Silero speakers are native Russian.

Data lives in `assets/audio/voice_lines.json`: `cast` maps role+race to a
speaker and a DSP preset, `lines` holds the text and the per-take direction.
Files go to `assets/audio/sfx/voice/`, and only `voice.*` keys of
`sound_db.json` are rewritten.

Requires the ComfyUI venv (torch/torchaudio/scipy/av) and the Silero model:
    set PYTHONPATH=C:\\Work\\ComfyUI\\_music_album\\libs
    C:\\Work\\ComfyUI\\.venv\\Scripts\\python.exe tests\\gen_voice_silero.py

Usage:
  ... gen_voice_silero.py --list            # what is missing
  ... gen_voice_silero.py                   # render the missing takes
  ... gen_voice_silero.py --force           # re-render everything
  ... gen_voice_silero.py --force --only merchant.ork
  ... gen_voice_silero.py --check           # files, keys and levels only
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent
LINES = REPO / "assets" / "audio" / "voice_lines.json"
DB = REPO / "assets" / "audio" / "sound_db.json"
OUT = REPO / "assets" / "audio" / "sfx" / "voice"
SR = 48000
BITRATE = 96_000

sys.path.insert(0, str(Path(__file__).resolve().parent))
from voice_fx import apply_preset  # noqa: E402


def silero_libs() -> Path:
    raw = os.environ.get("SILERO_LIBS", r"C:\Work\ComfyUI\_music_album\libs")
    path = Path(raw)
    if not (path / "silero").is_dir():
        sys.exit(f"Silero package not found in {path} (set SILERO_LIBS)")
    return path


def load_model():
    """Load v5_ru. Silero's downloader drops `latest_silero_models.yml` into the
    current directory, so the call runs from the model folder and the game repo
    stays clean."""
    libs = silero_libs()
    sys.path.insert(0, str(libs))
    from silero import silero_tts

    cwd = Path.cwd()
    os.chdir(libs.parent)
    try:
        model, _example = silero_tts(language="ru", speaker="v5_ru")
    finally:
        os.chdir(cwd)
    return model


def synth(model, text: str, speaker: str, rate: str, pitch: str) -> np.ndarray:
    ssml = f'<speak><prosody rate="{rate}" pitch="{pitch}">{text}</prosody></speak>'
    a = model.apply_tts(ssml_text=ssml, speaker=speaker, sample_rate=SR,
                        put_accent=True, put_stress_homo=True, put_yo=True)
    return np.asarray(a.detach().cpu().numpy() if hasattr(a, "detach") else a,
                      dtype=np.float32).reshape(-1)


def write_mp3(path: Path, x: np.ndarray) -> None:
    """Mono s16 mp3 through libmp3lame (soundfile has no bitrate control)."""
    import av

    pcm = (np.clip(x, -1.0, 1.0) * 32767.0).astype("<i2")
    frame = av.AudioFrame.from_ndarray(pcm.reshape(1, -1), format="s16", layout="mono")
    frame.sample_rate = SR
    path.parent.mkdir(parents=True, exist_ok=True)
    with av.open(str(path), "w", format="mp3") as out:
        stream = out.add_stream("libmp3lame", rate=SR)
        stream.bit_rate = BITRATE
        for packet in stream.encode(frame):
            out.mux(packet)
        for packet in stream.encode(None):
            out.mux(packet)


def raced_key(key: str, race: str) -> str:
    if race in ("", "human"):
        return key
    parts = key.split(".")
    parts.insert(-1, race)
    return ".".join(parts)


def file_of(key: str, take: int = 1) -> str:
    name = key.split(".", 1)[1].replace(".", "_")
    if take > 1:
        name += f"_{take}"
    return f"voice/{name}.mp3"


def expand(lines: list[dict]) -> list[dict]:
    """One job per rendered file: key, file, text, direction, preset."""
    jobs: list[dict] = []
    for line in lines:
        races = line.get("races") or [""]
        variants = line.get("variants") or [{}]
        for race in races:
            role = str(line["role"]) + (f".{race}" if race else "")
            for take, variant in enumerate(variants, 1):
                jobs.append({
                    "key": raced_key(str(line["key"]), race),
                    "role": role,
                    "take": take,
                    "text": str(variant.get("text", line["text"])),
                    "rate": variant.get("rate"),
                    "pitch": variant.get("pitch"),
                    "preset": line.get("preset"),
                    "subtitle": str(line.get("subtitle", "")),
                })
    return jobs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", nargs="*", default=None,
                    help="keys/roles to re-render; bare --force means everything")
    ap.add_argument("--only", default="", help="substring filter over key and role")
    args = ap.parse_args()

    cfg = json.loads(LINES.read_text(encoding="utf-8"))
    cast: dict = cfg["cast"]
    jobs = expand(cfg["lines"])

    if args.only:
        jobs = [j for j in jobs if args.only in j["key"] or args.only in j["role"]]
    missing = {(j["key"], j["take"]) for j in jobs
               if not (OUT / Path(file_of(j["key"], j["take"])).name).exists()}

    force_all = args.force is not None and len(args.force) == 0
    forced = set(args.force or [])
    todo = jobs if force_all else [
        j for j in jobs
        if (j["key"], j["take"]) in missing or j["key"] in forced or j["role"] in forced]

    if args.list or args.check:
        for job in jobs:
            have = (OUT / Path(file_of(job["key"], job["take"])).name).exists()
            print(f"{'есть ' if have else 'нет  '}{job['key']}  take {job['take']}")
        print(f"\nвсего файлов: {len(jobs)}, нет: {len(missing)}")

    if args.check:
        db = json.loads(DB.read_text(encoding="utf-8"))["keys"]
        voice_keys = {k: v for k, v in db.items() if k.startswith("voice.")}
        want = {j["key"] for j in jobs}
        print(f"sound_db voice-ключей: {len(voice_keys)}, ожидается: {len(want)}")
        print("лишние ключи:", sorted(set(voice_keys) - want) or "нет")
        print("не хватает ключей:", sorted(want - set(voice_keys)) or "нет")
        return 0

    if args.list:
        return 0
    if not todo:
        print("всё озвучено")
    else:
        print(f"к рендеру: {len(todo)} файл(ов)")
        model = None if args.dry_run else load_model()
        for job in todo:
            conf = cast[job["role"]]
            rate = job["rate"] or conf.get("rate", "medium")
            pitch = job["pitch"] or conf.get("pitch", "medium")
            preset = job["preset"] or conf.get("preset", "human")
            rel = file_of(job["key"], job["take"])
            if args.dry_run:
                print(f"  {rel:38s} {conf['speaker']:8s} {preset:6s} {rate:8s} {pitch:8s} {job['text'][:40]}")
                continue
            raw = synth(model, job["text"], conf["speaker"], rate, pitch)
            audio = apply_preset(raw, preset)
            write_mp3(OUT / Path(rel).name, audio)
            print(f"  OK {rel:38s} {len(audio) / SR:5.2f}s  {job['text'][:38]}")

    if args.dry_run:
        return 0

    # sound_db.json: only the voice.* branch is rewritten.
    db = json.loads(DB.read_text(encoding="utf-8"))
    keys: dict = db.setdefault("keys", {})
    grouped: dict[str, list[str]] = {}
    for job in jobs:
        grouped.setdefault(job["key"], []).append(file_of(job["key"], job["take"]))
    for key, files in grouped.items():
        first = next(j for j in jobs if j["key"] == key)
        keys[key] = {
            "bus": "Voice",
            "gain_db": 0.0,
            "pitch_jitter": 0.03 if first["role"].startswith("hero.") else 0.0,
            "files": files,
            "subtitle": first["subtitle"],
        }
    DB.write_text(json.dumps(db, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"sound_db.json: voice-ключей {sum(1 for k in keys if k.startswith('voice.'))}, "
          f"файлов {len(jobs)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
