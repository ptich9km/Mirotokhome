#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Alchemy data: four high-tier herbs, seven elixirs, readable potion names.

Why a generator and not a hand edit: `json.dumps` reformats the whole 10 000
line base (journal 05.10), so the file is edited as TEXT - blocks are split by
their braces and only the touched lines are rewritten. The same helper appends
the new items before the closing bracket.

What it does:
  1. renames the potions whose Russian name still starts with "Potion";
  2. appends the four tier 3-4 herbs and the seven elixirs (idempotent: an
     existing key is left alone);
  3. `--check` verifies the result without writing (used by the smoke test).

Run:
    python tests/gen_alchemy_db.py --check
    python tests/gen_alchemy_db.py
"""

from __future__ import annotations

import argparse
import json
import os
import re

DB = os.path.join("assets", "items", "item_db.json")

# key -> (name_ru, name_en). The English prefix "Potion" stayed in the Russian
# name after the import and reads as a bug in the shop and in tooltips.
RENAMES = {
    "Potion Antipoison": ("Зелье антидота", "Antipoison Potion"),
    "Potion Big Healing": ("Зелье большого лечения", "Great Potion of Healing"),
    "Potion Big Mana": ("Зелье большой маны", "Great Potion of Mana"),
    "Potion Health Regeneration": (
        "Зелье восстановления жизни", "Potion of Health Regeneration"),
    "Potion Mana Regeneration": (
        "Зелье восстановления маны", "Potion of Mana Regeneration"),
    "Potion Medium Healing": ("Зелье среднего лечения", "Potion of Medium Healing"),
    "Potion Medium Mana": ("Зелье средней маны", "Potion of Medium Mana"),
    "Potion Small Healing": ("Зелье малого лечения", "Potion of Minor Healing"),
    "Potion Small Mana": ("Зелье малой маны", "Potion of Minor Mana"),
    # Permanent stat potions. They are NOT craftable (the player's rule); they
    # stay in the base for the future quest rewards, and the name is fixed too.
    "Potion Body": ("Зелье тела", "Potion of Body"),
    "Potion Mind": ("Зелье разума", "Potion of Mind"),
    "Potion Reaction": ("Зелье реакции", "Potion of Reaction"),
    "Potion Spirit": ("Зелье духа", "Potion of Spirit"),
}

HERB_DIR = "res://assets/professions/herbalism/"
POTION_DIR = "res://assets/potions/"

# Tier 3-4 herbs. Prices follow the tier: a rare herb must be worth the walk
# into the wild, but still cheaper than the potion it makes.
HERBS = [
    (1477, "Herb Glowmoss", "Трава: светомох", "Glowmoss Herb", 14, "glowmoss.png"),
    (1478, "Herb Shadow Fern", "Трава: тенепапоротник", "Shadow Fern Herb", 30,
     "shadow_fern.png"),
    (1479, "Herb Astral Lotus", "Трава: астральный лотос", "Astral Lotus Herb", 36,
     "astral_lotus.png"),
    (1480, "Herb Ember Root", "Трава: углекорень", "Ember Root Herb", 32,
     "ember_root.png"),
]

# Effect channels: attack/defense go through StatusEffects "bless",
# *Resistance through "resist", speed through "haste".
ELIXIRS = [
    (1481, "Potion Elixir Rage", "Эликсир ярости", "Elixir of Rage",
     "Elixir Rage", 160, "attack=+12: duration 30", "elixir_rage.png"),
    (1482, "Potion Elixir Stone", "Эликсир камня", "Elixir of Stone",
     "Elixir Stone", 180, "defense=+15: duration 45", "elixir_stone.png"),
    (1483, "Potion Elixir Fire Ward", "Эликсир огненной защиты",
     "Elixir of Fire Ward", "Elixir Fire Ward", 220,
     "fireResistance=+25: duration 60", "elixir_fire.png"),
    (1484, "Potion Elixir Frost Ward", "Эликсир ледяной защиты",
     "Elixir of Frost Ward", "Elixir Frost Ward", 220,
     "waterResistance=+25: duration 60", "elixir_frost.png"),
    (1485, "Potion Elixir Wind", "Эликсир ветра", "Elixir of Wind",
     "Elixir Wind", 240, "speed=30: duration 20", "light_wings.png"),
    (1486, "Potion Elixir Mending", "Эликсир исцеления", "Elixir of Mending",
     "Elixir Mending", 260, "healthRegeneration=100: duration 20",
     "elixir_mending.png"),
    (1487, "Potion Elixir Fury", "Эликсир неистовства", "Elixir of Fury",
     "Elixir Fury", 320, "attack=+20: duration 20", "dark_skull.png"),
]


def split_blocks(text: str) -> tuple[str, list[str], str]:
    lines = text.split("\n")
    blocks: list[str] = []
    start = None
    for i, line in enumerate(lines):
        if start is None and line == " {":
            start = i
            continue
        if start is not None and line in (" }", " },"):
            blocks.append("\n".join(lines[start : i + 1]))
            start = None
    if start is not None:
        raise SystemExit("FAIL: item block is not closed - unexpected JSON layout")
    if not blocks:
        raise SystemExit("FAIL: no item blocks found")
    prefix = text[: text.index(blocks[0])]
    suffix = text[text.rindex(blocks[-1]) + len(blocks[-1]) :]
    return prefix, blocks, suffix


def key_of(block: str) -> str:
    m = re.search(r'^\s*"key":\s*"(.*)",\s*$', block, re.M)
    return m.group(1) if m else ""


def _field(block: str, name: str, value: str) -> str:
    pattern = r'^(\s*)"%s":\s*"[^"]*"(,?)\s*$' % re.escape(name)
    m = re.search(pattern, block, re.M)
    if m is None:
        raise SystemExit("FAIL: no %s line" % name)
    return block[: m.start()] + '%s"%s": "%s"%s' % (
        m.group(1), name, value, m.group(2)) + block[m.end():]


def _item_block(item: dict) -> str:
    lines = [" {"]
    order = ["key", "name_ru", "name_en", "quality", "material", "type", "price",
             "weight", "damage_min", "damage_max", "to_hit", "defence",
             "absorption", "magcap", "level", "effects", "icon"]
    for field in order:
        value = item[field]
        if isinstance(value, str):
            lines.append('  "%s": "%s",' % (field, value))
        else:
            lines.append('  "%s": %s,' % (field, json.dumps(value, ensure_ascii=False)))
    lines.append('  "id": %d' % item["id"])
    lines.append(" }")
    return "\n".join(lines)


def _item(key: str, name_ru: str, name_en: str, quality: str, kind: str,
          price: int, effects: list, icon: str, item_id: int) -> dict:
    return {
        "key": key, "name_ru": name_ru, "name_en": name_en,
        "quality": quality, "material": "None", "type": kind,
        "price": price, "weight": 0.1 if quality == "Herb" else 1.0,
        "damage_min": 0, "damage_max": 0, "to_hit": 0, "defence": 0,
        "absorption": 0, "magcap": 0, "level": 1,
        "effects": effects, "icon": icon, "id": item_id,
    }


def build(preview: bool) -> int:
    path = DB
    with open(path, encoding="utf-8", newline="") as handle:
        raw = handle.read()
    nl = "\r\n" if "\r\n" in raw else "\n"
    text = raw.replace("\r\n", "\n")
    prefix, blocks, suffix = split_blocks(text)

    renamed: list[str] = []
    out: list[str] = []
    present: set[str] = set()
    for block in blocks:
        block = block.rstrip().rstrip(",")
        key = key_of(block)
        present.add(key)
        if key in RENAMES:
            name_ru, name_en = RENAMES[key]
            block = _field(block, "name_ru", name_ru)
            block = _field(block, "name_en", name_en)
            renamed.append(key)
        out.append(block)

    added: list[str] = []
    for item_id, key, name_ru, name_en, price, icon in HERBS:
        if key in present:
            continue
        out.append(_item_block(_item(
            key, name_ru, name_en, "Herb", "Herb", price, [], HERB_DIR + icon,
            item_id)))
        added.append(key)
    for item_id, key, name_ru, name_en, kind, price, effect, icon in ELIXIRS:
        if key in present:
            continue
        out.append(_item_block(_item(
            key, name_ru, name_en, "Potion", kind, price, [effect],
            POTION_DIR + icon, item_id)))
        added.append(key)

    print("renamed:", len(renamed), renamed)
    print("added:", len(added), added)

    if preview:
        print("RESULT: OK (dry-run, file untouched)")
        return 0

    result = prefix + ",\n".join(out) + suffix
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(result.replace("\n", nl))

    with open(path, encoding="utf-8") as handle:
        check = json.load(handle)
    print("after write:", len(check), "items, JSON valid")
    return check_data(check)


def check_data(items: list) -> int:
    problems: list[str] = []
    by_key = {str(i.get("key", "")): i for i in items}
    ids: dict[int, str] = {}
    for key, item in by_key.items():
        item_id = item.get("id")
        if item_id in (None, 0):
            continue        # recipes carry no own id in the base
        if item_id in ids:
            problems.append("duplicate id %s: %s / %s" % (item_id, ids[item_id], key))
        ids[item_id] = key
    expected_herbs = {key for _, key, *_ in HERBS}
    expected_potions = {key for _, key, *_ in ELIXIRS}
    for key, (name_ru, _) in RENAMES.items():
        item = by_key.get(key)
        if item is None:
            problems.append("missing renamed potion: " + key)
        elif str(item.get("name_ru", "")) != name_ru:
            problems.append("name not applied: %s = %s" % (key, item.get("name_ru")))
    for key in sorted(expected_herbs | expected_potions):
        item = by_key.get(key)
        if item is None:
            problems.append("missing item: " + key)
            continue
        icon = str(item.get("icon", "")).replace("res://", "")
        if not os.path.exists(icon.replace("/", os.sep)):
            problems.append("missing icon file: %s -> %s" % (key, icon))
    for key in sorted(expected_potions):
        item = by_key[key]
        if str(item.get("quality", "")) != "Potion":
            problems.append("not a potion: " + key)
        if not item.get("effects"):
            problems.append("potion without effect: " + key)
    for item in items:
        if str(item.get("quality", "")) != "Potion":
            continue
        if str(item.get("name_ru", "")).startswith("Potion "):
            problems.append("English prefix left: " + str(item.get("key")))
    if problems:
        for problem in problems:
            print("FAIL:", problem)
        print("RESULT: FAIL", len(problems))
        return 2
    print("herbs:", len(expected_herbs), "elixirs:", len(expected_potions),
          "potions total:", sum(1 for i in items if i.get("quality") == "Potion"))
    print("RESULT: OK")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.check:
        with open(DB, encoding="utf-8") as handle:
            return check_data(json.load(handle))
    return build(preview=False)


if __name__ == "__main__":
    raise SystemExit(main())
