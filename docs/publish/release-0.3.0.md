# Release 0.3.0 — itch.io devlog text

Draft for Dashboard → Devlog. itch.io has no API for posts, so it is pasted by hand.
**The page and the devlog are English-only** (player decision 11.11).

---

## Title

Update 0.3.0 — English by default, mercenary roles and archers

## Body

The biggest change is not a feature: **the game now speaks English by default**.
Interface, items, spells, quests and voice-over were translated, and the whole
Russian version is still there — switch it in the main menu, the choice is
remembered. Every line of dialogue was re-recorded in English with the same
per-race timbres as the Russian take.

**Mercenaries have roles now.** A hired mage used to walk into melee no matter
what; now he has three roles: swing the staff, cast, or heal. A casting mage
keeps his distance and uses the spells of his race and reputation tier — a human
mage starts with a fire arrow and unlocks a fireball and a prismatic spray as
your standing with the city grows. A healer stays with the party, heals 8 % of
maximum health every 2.5 s and never runs at the enemy. Roles are set per
mercenary in the new "Party" tab of the inventory and are kept in the save.
The order buttons (follow / guard / attack / hold) still work exactly as before:
orders say *where* to go, the role says *what to do*.

**Archers.** Four new animated sets — human, orc, druid, undead — and they now
appear in taverns. An archer keeps his distance and shoots: the arrow is a real
projectile with physical damage, and it obeys the weapon table, so it hits
beasts for 125 % and the undead for 75 %.

**Spell books: one book, one spell.** Reading "Book of Fire" used to unlock the
whole school at once. Now a book teaches exactly the single spell written on it —
a quest reward should not be a free upgrade.

**Quest items are a separate category** and can no longer be read, worn or sold
by mistake — a delivered tome handed to you as a quest target is not a spellbook
you can burn.

**Smaller things:** undergrowth you can walk through (mushrooms, ferns, dry
bushes, aloe) fills the poor biomes instead of bare ground; the tooltip of every
slot names the item type properly; and two real bugs are gone — the music could
start a second track on top of the first one if a track changed while the game
was paused, and a damage flash on a unit that died in the same instant printed an
error instead of finishing quietly.

## Plans for the near future

1. **Quest chains.** Templates and quest givers exist; chains with consequences
   for the world are next.
2. **Forging from ingots.** The forge currently only salvages and crafts recipes;
   the goal is to choose what to forge from a metal.
3. **Line of sight** for the fog of war — a cell behind a tree should not be visible.
4. **More map events.** "Save the traveller" is the first; caravans, ambushes and
   helping the guard come next.
5. **City art and factions** per zone.

---

## Technical notes for me

- Build: `tests/build_windows.ps1` → `build/windows/Mirotokhome0.3.0.exe`
  (version in the name and in the Windows file properties).
- Publish: butler, channel `windows`, `--userversion 0.3.0`.
- The store page text (`description_final.txt`) is updated for 0.3.0; only the
  devlog post has to be pasted by hand.
