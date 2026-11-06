#!/usr/bin/env python3
"""Generate detailed loot icons (32x32) for Allodshome: sword + chest armor."""

from PIL import Image, ImageDraw
import os
from pathlib import Path

MATERIALS = {
    # Base
    "bronze": ((184, 115, 51), (120, 75, 33), (220, 160, 90)),
    "iron": ((120, 120, 125), (80, 80, 85), (160, 160, 165)),
    "steel": ((192, 192, 200), (140, 140, 150), (220, 220, 230)),
    # Alliance of Light
    "argentum": ((200, 200, 210), (150, 150, 160), (240, 240, 250)),
    "lutetium": ((230, 220, 180), (180, 170, 130), (255, 245, 210)),
    "lanthanum": ((210, 220, 240), (160, 170, 190), (240, 245, 255)),
    "terbium": ((220, 240, 220), (170, 190, 170), (250, 255, 250)),
    # Hordes of Fire
    "wolfram": ((100, 90, 80), (60, 50, 40), (140, 130, 120)),
    "chromium": ((160, 170, 190), (110, 120, 140), (200, 210, 230)),
    "cobalt": ((60, 80, 140), (30, 50, 100), (100, 120, 180)),
    "titanium": ((140, 120, 160), (90, 70, 110), (180, 160, 200)),
    # Reapers
    "thorium": ((80, 90, 70), (50, 60, 40), (120, 130, 110)),
    "uranium": ((100, 160, 100), (60, 120, 60), (140, 200, 140)),
    "plutonium": ((60, 40, 80), (30, 20, 50), (100, 80, 120)),
    "radium": ((100, 180, 220), (60, 140, 180), (140, 220, 255)),
    # Druid Circle
    "gallium": ((140, 180, 150), (90, 130, 100), (180, 220, 190)),
    "yttrium": ((60, 160, 100), (30, 120, 70), (100, 200, 140)),
    "promethium": ((80, 180, 200), (40, 140, 160), (120, 220, 240)),
    "neodymium": ((200, 190, 220), (150, 140, 170), (240, 230, 255)),
}

DST = str(Path(__file__).resolve().parents[1] / "assets" / "loot_icons")
os.makedirs(DST, exist_ok=True)


def draw_sword_detailed(img, main, shadow, highlight):
    """Draw a detailed pixel-art sword (diagonal, ~45° angle)."""
    draw = ImageDraw.Draw(img)

    # Blade (diagonal, wide at guard, tapered to tip)
    # Tip at top-right (26, 4), base at guard (14, 16)
    blade = [(26, 4), (28, 6), (16, 18), (12, 14)]
    draw.polygon(blade, fill=main)

    # Fuller (center groove - darker line down middle)
    draw.line([(25, 5), (15, 15)], fill=shadow, width=1)

    # Edge highlights (both edges)
    draw.line([(26, 5), (14, 17)], fill=highlight, width=1)
    draw.line([(27, 6), (16, 17)], fill=shadow, width=1)

    # Blade tip (sharp point)
    draw.polygon([(26, 4), (27, 5), (25, 5)], fill=highlight)

    # Guard (cross-shaped, perpendicular to blade)
    # Main bar from (10, 12) to (18, 20)
    draw.line([(10, 12), (18, 20)], fill=shadow, width=4)
    draw.line([(10, 12), (18, 20)], fill=highlight, width=1)
    # Guard ends (decorative balls)
    draw.ellipse([(8, 10), (12, 14)], fill=shadow)
    draw.ellipse([(9, 11), (11, 13)], fill=highlight)
    draw.ellipse([(16, 18), (20, 22)], fill=shadow)
    draw.ellipse([(17, 19), (19, 21)], fill=highlight)

    # Handle (short, continues diagonal)
    # From (14, 16) to (10, 20)
    draw.line([(14, 16), (10, 20)], fill=shadow, width=4)
    # Wrap texture (cross-hatch)
    draw.line([(13, 17), (11, 19)], fill=main, width=1)
    draw.line([(12, 16), (10, 18)], fill=main, width=1)

    # Pommel (round end)
    draw.ellipse([(8, 18), (12, 22)], fill=shadow)
    draw.ellipse([(9, 19), (11, 21)], fill=main)
    draw.ellipse([(10, 20), (10, 20)], fill=highlight)


def draw_armor_detailed(img, main, shadow, highlight):
    """Draw a detailed pixel-art chest armor."""
    draw = ImageDraw.Draw(img)

    # Main chest plate (curved shape)
    chest = [(10, 9), (22, 9), (24, 22), (8, 22)]
    draw.polygon(chest, fill=main)

    # Right side shadow (3D effect)
    shadow_side = [(16, 9), (22, 9), (24, 22), (16, 22)]
    draw.polygon(shadow_side, fill=shadow)

    # Center ridge (highlight)
    draw.line([(16, 9), (16, 22)], fill=highlight, width=1)

    # Chest details (rivets/decorations)
    # Left side rivets
    draw.ellipse([(12, 12), (14, 14)], fill=shadow)
    draw.ellipse([(12, 16), (14, 18)], fill=shadow)
    # Right side rivets
    draw.ellipse([(18, 12), (20, 14)], fill=shadow)
    draw.ellipse([(18, 16), (20, 18)], fill=shadow)

    # Neck opening (curved)
    draw.arc([(13, 7), (19, 11)], 0, 180, fill=shadow, width=1)

    # Left shoulder pad
    draw.ellipse([(4, 7), (12, 13)], fill=main)
    draw.ellipse([(5, 8), (11, 12)], fill=highlight)
    # Shoulder detail
    draw.ellipse([(7, 9), (9, 11)], fill=shadow)

    # Right shoulder pad
    draw.ellipse([(20, 7), (28, 13)], fill=shadow)
    draw.ellipse([(21, 8), (27, 12)], fill=main)
    # Shoulder detail
    draw.ellipse([(23, 9), (25, 11)], fill=highlight)

    # Bottom edge (belt area)
    draw.line([(8, 22), (24, 22)], fill=shadow, width=1)
    draw.line([(8, 23), (24, 23)], fill=main, width=1)


def main():
    for mat_name, (main, shadow, highlight) in MATERIALS.items():
        # Sword
        img_s = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
        draw_sword_detailed(img_s, main, shadow, highlight)
        path_s = f"{DST}/{mat_name}_weapon.png"
        img_s.save(path_s)

        # Chest armor
        img_a = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
        draw_armor_detailed(img_a, main, shadow, highlight)
        path_a = f"{DST}/{mat_name}_armor.png"
        img_a.save(path_a)

        print(f"  {mat_name}: sword + armor (detailed)")

    print(f"\nDone! {len(MATERIALS) * 2} icons saved to {DST}")


if __name__ == "__main__":
    print(f"Generating {len(MATERIALS) * 2} detailed loot icons (32x32)...")
    main()
