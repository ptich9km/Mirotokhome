# Community topics on itch.io — ready texts (English)

**Why by hand:** itch.io has no API for community topics. The full server-side API
reference (`itch.io/docs/api/serverside`) lists only credentials, profile, games
(download keys / purchases / rewards / ownership), collections and wharf. The
`Post a new topic` button on the game page leads to
`itch.io/login?intent=community&...`, so a topic can only be created in a browser
under your account.

**Page is English-only** (player decision 11.11). The three topics created 11.11 are
Russian; either edit the title and the first post, or delete them and recreate with
the texts below.

Create: game page → section **Community** → `Post a new topic`, or
`https://ptich9km.itch.io/mirotokhome/community` → `New topic`. Pin the bug thread
if itch offers the pin control.

---

## 1. Bugs and crashes

**First post:**

This is where bugs go. The game is in development (0.2.0), broken things are part
of the deal.

What helps fix it faster:

1. **What you were doing** before it broke — step by step, as far as you remember.
2. **What happened** instead of what you expected.
3. **A screenshot** if it is about graphics, UI, or "I am stuck".
4. **The world seed** — it is shown on the character creation screen ("World"
   block). With the seed I can reproduce your map locally.
5. If the game crashed, the last console lines if you launched it from a terminal.

Please check whether the bug is already reported and add your case to the existing
thread instead of opening a new one — that shows which problems are common.

## 2. Ideas and suggestions

**First post:**

What would you like to see in the game? Write freely — I read everything, but I
promise nothing.

Already planned, so we do not duplicate: quest chains, forging weapons and armour
from ingots, line of sight for the fog of war, more map events (caravans, ambushes),
city art.

Not planned for the near future: multiplayer, a mobile build.

## 3. Help and questions

**First post:**

Questions about the game — controls, saves, mods, "why is my hero not moving".

The short version:

- **Controls:** LMB — move / attack, 1-3 — spells, Space — tactical pause,
  M — astral map, Esc — menu. Keys can be rebound in the settings.
- **Saves:** 6 slots plus autosave in `%APPDATA%\Godot\app_userdata\Mirotokhome`.
  The map is rebuilt from its seed on load, so items and position persist.
- **Mods:** the `mods` folder next to the saves. Drop a folder with `mod.json`,
  enable it in the mods panel, restart the game.
- **The hero stands still / does not move:** clicking an enemy is an attack (he
  walks over himself); clicking an ally's body moves your target to a free cell.
- **Interface language:** Russian only for now, English translation in progress.

If nobody answers, post in the bug thread with the world seed — it may not be a
question but a bug.

---

## Keep in mind

- Three topics is right for an alpha. Empty sections read as an abandoned project.
- Comments on the game page (Comments tab) still work and are for quick feedback;
  topics are for longer threads.
- Reply to every topic once, even briefly: it shows the developer is present.
