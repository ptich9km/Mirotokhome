# Release 0.2.0 — itch.io devlog text

Draft for Dashboard → Devlog. itch.io has no API for posts, so it is pasted by hand.

**The page and the devlog are English-only** (player decision 11.11). The existing
Russian post "Обновление 0.2.0" should be replaced with the text below, or kept as
the first Russian-only entry and all further posts written in English.

---

## Title

Update 0.2.0 — herbalism, voice-over, city heads and a rescue event

## Body

First update since the release. The game interface is still in Russian; an English
translation is in progress.

**Herbalism and alchemy.** Twelve herbs in four tiers, all of them animated,
gathered by hand and regrowing over time. Sixteen recipes, including seven tactical
elixirs (attack, defence, fire, frost, speed, healing, frenzy). Shops now sell only
two healing potions per city per day, so brewing beats buying.

**Voice-over.** Every line was re-recorded in Russian with a separate timbre per
race: orcs speak through overdrive, the undead with breath and tremble, druids
higher and quieter.

**Cities.** The head of each of the four races got his own portrait instead of
borrowed guard art. The head is also the quest giver — look for "!" or "?" above.

**A random encounter.** Grey monsters attack a peaceful traveller. Intervene and
you get gold plus reputation with the nearest city; the traveller walks off to the
city. Too slow and he dies, no reward.

**Combat and movement.** Units are smaller and no longer stick to each other:
20 px bodies, pathing around bodies, clicking a unit moves your target to a free
cell, mercenaries no longer block you, and you can step out of melee. Patrolling
guards finally walk — before, the animation played while the body stood still.

## Plans for the near future

1. **Quest chains.** Templates and quest givers exist; chains with consequences
   for the world are next.
2. **Forging from ingots.** The forge currently only salvages and crafts recipes;
   the goal is to choose what to forge from a metal.
3. **Line of sight** for the fog of war — a cell behind a tree should not be visible.
4. **More map events.** "Save the traveller" is the first; caravans, ambushes and
   helping the guard come next.
5. **City art and factions** per zone.
6. **Balance and audio:** measure combat loudness, tune elixirs and economy.

---

## Technical notes for me

- Build: `godot --headless --path . --export-release "Windows Desktop"` → one
  `build/windows/Mirotokhome.exe`, 179.6 MB (pck inside).
- Publish: butler, channel `windows`, `--userversion 0.2.0`, build 2357316.
- Old manual upload removed 11.11; the page now lists a single file.
