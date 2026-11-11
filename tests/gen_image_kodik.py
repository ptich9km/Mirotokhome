#!/usr/bin/env python3
"""KodikRouter image generation CLI.

OpenAI-совместимый шлюз: POST /v1/images -> b64_json.

Ключ читается из env KODIK_API_KEY или файла .kodik_key в корне репо
(файл в .gitignore, в git не попадает).

Usage:
  python tests/gen_image_kodik.py --list-models
  python tests/gen_image_kodik.py --prompt "orc warrior, pixel art" --out import/test.png
  python tests/gen_image_kodik.py --compare qwen/qwen-image-3-pro,black-forest-labs/flux-2 \
      --prompt "..." --out-dir import/_compare
"""
import argparse
import base64
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

BASE = "https://api.kodikrouter.ru/v1"
REPO = Path(__file__).resolve().parent.parent
KEY_FILE = REPO / ".kodik_key"
## Secrets live outside the repository: an archive of the project folder must
## never carry an API key.
USER_KEY_FILE = Path(os.environ.get("APPDATA", Path.home())) / "Mirotokhome" / "kodik_key"


def load_key() -> str:
    # Lookup order: environment, then the user profile folder (outside the
    # repository, so an archive of the project never carries the secret), then
    # the legacy file in the repo root.
    key = os.environ.get("KODIK_API_KEY", "").strip()
    if key:
        return key
    for path in (USER_KEY_FILE, KEY_FILE):
        if path.exists():
            key = path.read_text(encoding="utf-8").strip()
            if key:
                return key
    sys.exit(f"API key not found: set KODIK_API_KEY or create {USER_KEY_FILE}")


## The router drops roughly every second TCP connection from this provider: the
## same GET alternates between 0.5 s and a 21 s connect timeout (measured
## 11.11.2026). A refused/timed-out CONNECT means the request never reached the
## server, so replaying it cannot bill twice; a read timeout after the request
## was sent is a different story, so only connect-phase errors are retried.
CONNECT_RETRIES = 5
## Socket level codes instead of message text: the OS translates the message, and
## a Russian Windows build has no "10060" substring in it.
_CONNECT_ERRNOS = (110, 111, 113)          # ETIMEDOUT, ECONNREFUSED, EHOSTUNREACH
_CONNECT_WINERRORS = (10060, 10061, 10065)  # timed out, refused, no route


def _is_connect_error(err: BaseException) -> bool:
    seen = err
    for _ in range(6):
        if seen is None or not isinstance(seen, BaseException):
            break
        if isinstance(seen, socket.gaierror):
            return True
        if getattr(seen, "winerror", None) in _CONNECT_WINERRORS:
            return True
        if getattr(seen, "errno", None) in _CONNECT_ERRNOS + _CONNECT_WINERRORS:
            return True
        nxt = getattr(seen, "reason", None)
        if nxt is None:
            nxt = seen.__cause__ or seen.__context__
        seen = nxt
    return False


def _req(method: str, path: str, body: dict | None, key: str, timeout: int = 300) -> dict:
    url = BASE + path
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {key}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    last: Exception | None = None
    for attempt in range(1, CONNECT_RETRIES + 1):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", errors="replace")
            sys.exit(f"HTTP {e.code} {path}\n{detail}")
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            last = e
            if not _is_connect_error(e) or attempt == CONNECT_RETRIES:
                break
            print(f"  connect retry {attempt}/{CONNECT_RETRIES - 1}: {str(e)[:70]}")
            time.sleep(min(8, attempt * 2))
    raise SystemExit(f"{method} {path}: no server after {CONNECT_RETRIES} tries\n{last}")


def list_models(key: str) -> None:
    models = _req("GET", "/images/models", None, key)
    items = models.get("data", models if isinstance(models, list) else [])
    print(f"{'id':<50} {'owned_by':<20}")
    print("-" * 72)
    for m in items:
        if isinstance(m, dict):
            print(f"{m.get('id', '?'):<50} {m.get('owned_by', ''):<20}")
    print(f"\ntotal: {len(items)}")


def gen_once(key: str, model: str, prompt: str, out: Path, size: str | None,
             seed: int | None, n: int, extra: dict | None) -> dict:
    body: dict = {"model": model, "prompt": prompt, "n": n,
                  "response_format": "b64_json"}
    if size:
        body["size"] = size
    if seed is not None:
        body["seed"] = seed
    if extra:
        body.update(extra)
    t0 = time.time()
    resp = _req("POST", "/images", body, key, timeout=600)
    dt = time.time() - t0
    usage = resp.get("usage", {})
    data = resp.get("data", [])
    if not data or not data[0].get("b64_json"):
        sys.exit(f"No b64_json in response: {json.dumps(resp)[:500]}")
    out.parent.mkdir(parents=True, exist_ok=True)
    raw = base64.b64decode(data[0]["b64_json"])
    # seedream и часть провайдеров отдают JPEG-байты с b64; Godot импортирует
    # только настоящий PNG — конвертируем на месте.
    if raw[:3] == b"\xff\xd8\xff":
        import io
        from PIL import Image
        raw_buf = io.BytesIO(raw)
        img = Image.open(raw_buf)
        buf = io.BytesIO()
        img.save(buf, "PNG")
        raw = buf.getvalue()
    out.write_bytes(raw)
    cost = usage.get("cost", "?")
    print(f"OK  {out}  {len(raw) // 1024} KB  {dt:.1f}s  cost={cost}  "
          f"tokens={usage.get('total_tokens', '?')}")
    return {"model": model, "out": str(out), "cost": cost, "sec": round(dt, 1),
            "bytes": len(raw)}


def contact_sheet(paths: list[Path], out: Path, cell: int = 512,
                  labels: list[str] | None = None) -> None:
    from PIL import Image, ImageDraw, ImageFont
    bar = 28
    imgs = []
    for i, p in enumerate(paths):
        im = Image.open(p).convert("RGB")
        im.thumbnail((cell, cell - bar))
        text = labels[i] if labels and i < len(labels) else p.stem
        imgs.append((im, text))
    cols = min(3, len(imgs))
    rows = (len(imgs) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * cell, rows * cell), (32, 32, 36))
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("arial.ttf", 16)
    except OSError:
        font = ImageFont.load_default()
    for i, (im, text) in enumerate(imgs):
        cx = (i % cols) * cell
        cy = (i // cols) * cell
        sheet.paste(im, (cx + (cell - im.width) // 2, cy + bar))
        draw.text((cx + 8, cy + 6), text, fill=(255, 220, 120), font=font)
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out)
    print(f"sheet: {out}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--list-models", action="store_true")
    ap.add_argument("--prompt", default="")
    ap.add_argument("--model", default="qwen/qwen-image-3-pro")
    ap.add_argument("--compare", default="",
                    help="comma-separated model ids, same prompt for each")
    ap.add_argument("--out", default="import/_kodik_test.png")
    ap.add_argument("--out-dir", default="import/_compare")
    ap.add_argument("--size", default="1024x1024")
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("-n", type=int, default=1)
    args = ap.parse_args()
    key = load_key()

    if args.list_models:
        list_models(key)
        return
    if not args.prompt:
        ap.error("--prompt required (or --list-models)")

    if args.compare:
        out_dir = Path(args.out_dir)
        results, paths = [], []
        for m in [s.strip() for s in args.compare.split(",") if s.strip()]:
            slug = m.replace("/", "_")
            out = out_dir / f"{slug}.png"
            try:
                r = gen_once(key, m, args.prompt, out, args.size, args.seed, 1, None)
                results.append(r)
                paths.append(out)
            except SystemExit as e:
                print(f"FAIL {m}: {e}")
        if paths:
            labels = [f"{r['model']}  ${r['cost']}" for r in results]
            contact_sheet(paths, out_dir / "_sheet.png", labels=labels)
        print("\n--- compare summary ---")
        for r in results:
            print(f"{r['model']:<45} cost={r['cost']:<8} {r['sec']}s  {r['out']}")
        (out_dir / "summary.json").write_text(
            json.dumps(results, indent=2, ensure_ascii=False), encoding="utf-8")
        return

    gen_once(key, args.model, args.prompt, Path(args.out), args.size,
             args.seed, args.n, None)


if __name__ == "__main__":
    main()
