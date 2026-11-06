#!/usr/bin/env python3
"""Generate animated potion bottle icons (32x32) for Allodshome.

Types: health (red) and mana (blue)
Sizes: small, medium, large
Frames: 4 (bobbing animation)
"""

import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

DST = str(Path(__file__).resolve().parents[1] / "assets" / "loot_icons")


def draw_potion(img, size, liquid_color, liquid_dark, glass_color, frame):
    """Draw a potion bottle with animation."""
    draw = ImageDraw.Draw(img)
    w, h = img.size

    # Animation: bobbing offset
    bob_y = int(2 * math.sin(frame * math.pi / 2))

    # Bottle dimensions based on size
    if size == "small":
        body_w, body_h = 10, 12
        neck_w, neck_h = 4, 4
        cork_w, cork_h = 5, 3
    elif size == "medium":
        body_w, body_h = 14, 16
        neck_w, neck_h = 5, 5
        cork_w, cork_h = 6, 3
    else:  # large
        body_w, body_h = 18, 20
        neck_w, neck_h = 6, 6
        cork_w, cork_h = 7, 3

    cx = w // 2
    cy = h // 2 + bob_y

    # Cork (top)
    cork_y = cy - body_h // 2 - neck_h - cork_h
    draw.rectangle([
        (cx - cork_w // 2, cork_y),
        (cx + cork_w // 2, cork_y + cork_h)
    ], fill=(139, 90, 43))

    # Neck
    neck_y = cork_y + cork_h
    draw.rectangle([
        (cx - neck_w // 2, neck_y),
        (cx + neck_w // 2, neck_y + neck_h)
    ], fill=glass_color)

    # Body (rounded rectangle)
    body_top = neck_y + neck_h
    body_bottom = body_top + body_h

    # Main body
    draw.rounded_rectangle([
        (cx - body_w // 2, body_top),
        (cx + body_w // 2, body_bottom)
    ], radius=3, fill=glass_color)

    # Liquid (fills bottom 70% of body)
    liquid_top = body_top + int(body_h * 0.3)
    draw.rounded_rectangle([
        (cx - body_w // 2 + 1, liquid_top),
        (cx + body_w // 2 - 1, body_bottom - 1)
    ], radius=2, fill=liquid_color)

    # Liquid highlight (shimmer)
    shimmer_offset = int(2 * math.sin(frame * math.pi / 2 + 1))
    draw.ellipse([
        (cx - body_w // 4 + shimmer_offset, liquid_top + 2),
        (cx - body_w // 4 + 2 + shimmer_offset, liquid_top + 4)
    ], fill=(255, 255, 255, 180))

    # Glass highlight (left edge)
    draw.line([
        (cx - body_w // 2 + 1, body_top + 2),
        (cx - body_w // 2 + 1, body_bottom - 2)
    ], fill=(255, 255, 255, 100), width=1)

    # Liquid dark (bottom shadow)
    draw.rounded_rectangle([
        (cx - body_w // 2 + 1, body_bottom - 4),
        (cx + body_w // 2 - 1, body_bottom - 1)
    ], radius=1, fill=liquid_dark)


def main():
    # Potion definitions
    potions = {
        "health": {
            "liquid": (220, 50, 50),
            "liquid_dark": (150, 30, 30),
            "glass": (200, 220, 230, 180),
        },
        "mana": {
            "liquid": (50, 100, 220),
            "liquid_dark": (30, 60, 150),
            "glass": (200, 220, 230, 180),
        },
    }

    sizes = ["small", "medium", "large"]
    frames = 4

    for potion_type, colors in potions.items():
        for size in sizes:
            # Create frames
            frame_images = []
            for frame in range(frames):
                img = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
                draw_potion(img, size, colors["liquid"], colors["liquid_dark"],
                           colors["glass"], frame)
                frame_images.append(img)

                # Save individual frame
                path = f"{DST}/{potion_type}_{size}_frame{frame:02d}.png"
                img.save(path)

            # Create spritesheet (4 frames horizontally)
            sheet = Image.new("RGBA", (32 * frames, 32), (0, 0, 0, 0))
            for i, frame_img in enumerate(frame_images):
                sheet.paste(frame_img, (i * 32, 0))
            sheet_path = f"{DST}/{potion_type}_{size}_spritesheet.png"
            sheet.save(sheet_path)

            print(f"  {potion_type} {size}: 4 frames + spritesheet")

    print(f"\nDone! Saved to {DST}")


if __name__ == "__main__":
    print("Generating potion bottle icons (32x32, animated)...")
    main()
