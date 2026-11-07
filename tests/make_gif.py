"""Assembles PNG frames (tests/record_window.ps1) into an itch-ready GIF.

GIF quality rules that matter for a store page: one global palette per clip
(flicker is worse than banding), no more than 5 MB per file (itch limit) and a
width that still reads on a phone. The script shrinks colours and drops frames
until the file fits instead of silently shipping a 20 MB monster.

Run:  py -3 tests/make_gif.py --frames import/gif_frames/world --out docs/gifs/world.gif
      py -3 tests/make_gif.py --frames DIR --out X.gif --width 800 --fps 10 --start 10 --end 80
"""

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageChops

# The upload form rejects an image over 3 MB — found the hard way: the help page
# never says it and the search results were empty. 2.9 leaves a little slack,
# because a file that sits on the limit is a re-upload waiting to happen.
ITCH_MAX_MB = 2.9
LIMIT = ITCH_MAX_MB * 1024 * 1024

# Finer than halving: on a busy UI scene 48 colours costs 3.04 MB while 40 costs
# 2.95, and dropping straight to 32 throws away detail nobody had to lose.
COLOUR_STEPS = (96, 80, 64, 56, 48, 40, 32)


def load_frames(folder: Path, start: int, end: int) -> list[Image.Image]:
    files = sorted(folder.glob("f*.png"))
    if not files:
        raise SystemExit(f"no frames in {folder}")
    if start or end:
        files = files[start:end]
    frames = []
    for f in files:
        img = Image.open(f).convert("RGB")
        frames.append(img)
    return frames


def trim_static(frames: list[Image.Image], threshold: int = 6) -> list[Image.Image]:
    """Drop identical leading/trailing frames (a click before the action)."""
    def differs(a, b) -> bool:
        diff = ImageChops.difference(a, b).convert("L")
        return diff.getextrema()[1] > threshold

    lo, hi = 0, len(frames) - 1
    while lo < hi and not differs(frames[lo], frames[lo + 1]):
        lo += 1
    while hi > lo and not differs(frames[hi], frames[hi - 1]):
        hi -= 1
    return frames[lo:hi + 1]


def encode(frames, out: Path, fps: int, width: int, colors: int) -> int:
    scale = width / frames[0].width
    height = int(round(frames[0].height * scale))
    # Nearest neighbour on purpose: the game renders 1280 wide and 640 is an exact
    # half, so the pixel art stays crisp. Smoothing turns flat terrain into
    # thousands of near-identical colours and the GIF grows by half.
    resized = [f.resize((width, height), Image.NEAREST) for f in frames]
    # A single palette for the whole clip: per-frame palettes make flat terrain
    # shimmer, which is exactly what a viewer notices on a store page. Sampling
    # four frames instead of one keeps sky and fire from collapsing into one hue.
    picks = sorted({0, len(resized) // 3, 2 * len(resized) // 3, len(resized) - 1})
    strip = Image.new("RGB", (width, height * len(picks)))
    for i, idx in enumerate(picks):
        strip.paste(resized[idx], (0, height * i))
    palette = strip.quantize(colors=colors, method=Image.MEDIANCUT)
    # Ordered dithering would add noise to flat terrain and inflate the file for
    # no visible gain at this size, so it stays off.
    quantized = [f.quantize(palette=palette) for f in resized]
    quantized[0].save(
        out,
        save_all=True,
        append_images=quantized[1:],
        duration=int(1000 / fps),
        loop=0,
        optimize=True,
        disposal=1,
    )
    return out.stat().st_size


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--fps", type=int, default=12)
    ap.add_argument("--width", type=int, default=640)
    ap.add_argument("--colors", type=int, default=96)
    ap.add_argument("--start", type=int, default=0)
    ap.add_argument("--end", type=int, default=0)
    ap.add_argument("--trim", action="store_true",
                    help="cut static head/tail frames")
    ap.add_argument("--hold", type=int, default=0,
                    help="repeat the last frame N times (a beat on the result)")
    args = ap.parse_args()

    frames = load_frames(Path(args.frames), args.start, args.end)
    if args.trim:
        frames = trim_static(frames)
    if args.hold > 0:
        # Loot drops on the last frame and a viewer needs a moment to notice it.
        frames = frames + [frames[-1]] * args.hold
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)

    colors = args.colors
    fps = args.fps
    clip = frames
    size = encode(clip, out, fps, args.width, colors)
    # A busy scene (combat, particles) simply has more new pixels per second than
    # a menu. Rather than shipping 8 MB or a 12-colour smear, first drop colours
    # in steps, then drop frames (timing stays real: every second frame at half
    # the rate).
    for step in COLOUR_STEPS:
        if size <= LIMIT or step >= colors:
            continue
        colors = step
        size = encode(clip, out, fps, args.width, colors)
    while size > LIMIT and len(clip) > 12 and fps > 4:
        fps = max(4, fps // 2)
        clip = clip[::2]
        size = encode(clip, out, fps, args.width, colors)

    print(f"{out}: {len(clip)} frames @ {fps} fps, {args.width}px, "
          f"{colors} colours, {size / 1024 / 1024:.2f} MB")
    if size > LIMIT:
        print("WARNING: still above the itch limit, reduce --width or --colors")
        sys.exit(2)


if __name__ == "__main__":
    main()
