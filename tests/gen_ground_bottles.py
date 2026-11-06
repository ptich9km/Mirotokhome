#!/usr/bin/env python3
"""Ground bottle frames (06.11): health, mana, essence, boss essence.

The base is the AI essence sheet already approved by the player
(assets/ui/essence/essence-000..003.png). Health and mana are hue-shifted
variants, boss essence is an amber/dark variant, so all four ground bottles
share one hand-painted style. KodikRouter is not used here: the machine cannot
reach the API right now; tests/gen_bottle_art_kodik.py holds the prompts for a
proper regeneration when the network/VPN is available.

Output: assets/loot_icons/bottle_<kind>_frame00..03.png (32x32, RGBA).
Run: python tests/gen_ground_bottles.py
Then: godot --headless --path . --import
"""
from pathlib import Path

from PIL import Image
import colorsys

REPO = Path(__file__).resolve().parent.parent
SRC_DIR = REPO / "assets" / "ui" / "essence"
DST = REPO / "assets" / "loot_icons"

# kind -> (hue, saturation multiplier, value multiplier)
VARIANTS = {
	"health": (0.99, 1.18, 1.00),
	"mana": (0.60, 1.12, 1.02),
	"boss": (0.10, 1.25, 1.12),
}


def tint(src: Image.Image, hue: float, sat_m: float, val_m: float) -> Image.Image:
	out = src.copy()
	px = out.load()
	w, h = out.size
	for y in range(h):
		for x in range(w):
			r, g, b, a = px[x, y]
			if a == 0:
				continue
			hh, ss, vv = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
			# Grey/white highlights and the dark outline keep their value.
			if ss > 0.08:
				hh = hue
				ss = min(1.0, ss * sat_m)
			vv = min(1.0, vv * val_m)
			nr, ng, nb = colorsys.hsv_to_rgb(hh, ss, vv)
			px[x, y] = (int(nr * 255), int(ng * 255), int(nb * 255), a)
	return out


def main() -> None:
	frames = []
	for i in range(4):
		src = SRC_DIR / f"essence-{i:03d}.png"
		if not src.exists():
			raise SystemExit(f"missing base frame: {src}")
		frames.append(Image.open(src).convert("RGBA"))

	for kind, (hue, sat_m, val_m) in VARIANTS.items():
		for i, base in enumerate(frames):
			out = tint(base, hue, sat_m, val_m)
			out.save(DST / f"bottle_{kind}_frame{i:02d}.png")

	# The plain essence bottle keeps the approved AI colours.
	for i, base in enumerate(frames):
		base.save(DST / f"bottle_essence_frame{i:02d}.png")

	print(f"ground bottles: {len(VARIANTS) + 1} kinds x 4 frames -> {DST}")


if __name__ == "__main__":
	main()
