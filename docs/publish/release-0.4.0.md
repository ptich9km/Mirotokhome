# Release 0.4.0 — itch.io devlog text

Draft for Dashboard → Devlog. itch.io has no API for posts, so it is pasted by hand.
**The page and the devlog are English-only** (player decision 11.11).

---

## Title

Update 0.4.0 — story chains, town raids and a readable quest board

## Body

**The quest board is readable now.** The town head used to show three tall cards
that filled the whole window: a title, three lines of text, a place line, a reward
line and a button each. It is a list of rows now — five offers plus a story stage,
six visible without scrolling. Every row carries the icon of the mission, a
colour-coded difficulty badge (green common, blue medium, red hard, gold for a
story stage) and one line of progress.

**A taken quest no longer vanishes.** Take it and the row stays in the same place,
marked red "Taken", with the "Turn in" button appearing there once it is done.
Before, taking a quest made it disappear and the only place to hand it back was a
journal window you had to know about.

**Story chains.** Four-stage storylines on top of the rotating chores, starting
with a human line: hunt six Greys, find the clerk's token, carry the ledger to the
neighbouring town, kill the elite behind it. Stages remember their progress,
count once, and change the world — a flag, reputation, a trophy, a line in the
world feed.

**Raids on a town.** A rare event, one or two towns per rotation: four to six
beasts of a single species walk on the town, and the guards fight back. If they
wipe the guards the town does not fall — replacements arrive at their posts and
grind the raid down. Your task is to help.

**Quest signs on the minimap.** Every taken quest now shows the sign of its type
on the minimap — a chest, crossed swords, a daisy, a shield under stones — instead
of a generic plus. Small, flat, readable on any terrain.

**Under the hood.** All mission icons are animated sprite sheets generated for the
nine mission types; the minimap signs are a separate set of hand-made 16×16 glyphs,
because a painted 64×64 frame turns into a smudge at map scale. Quests of the same
type but a different meaning (herb picking and faction tags) no longer share an
icon.

## Notes

- Save files from 0.3.0 load as-is; a save without chain state starts its first
  stage.
- Existing bugs fixed: kills of respawned Greys were not counted in hunts at all;
  a killed guard never came back and the town stayed defenceless until you
  reloaded the map.
