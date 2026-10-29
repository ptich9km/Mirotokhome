extends RefCounted
class_name GameConfig
##
## Game config: every number that can be tweaked without touching the code.
##
## The idea comes from the file `import/rates.properties` (AION server settings).
## The good decisions were taken from there: the damage multiplier and the HP/PW multipliers
## per mob tier. The rest was dropped: in AION ~80% of the file is `regular/premium/vip`,
## three copies of one multiplier for monetisation; we have nothing to repeat.
##
## Where it lives:
##   res://assets/config/game.cfg  — the reference copy, in the repository
##   user://config/game.cfg        — your edits, outside git, override res
##
## Rules baked in on purpose:
##   1. Every key has a default value. A typo in the config must not
##      crash the game — we take the default and log a warning.
##   2. The defaults equal the numbers that were hardcoded. Adding the config
##      changes nothing in the game behaviour, it only makes the numbers visible.
##   3. The config is read at start. There is no hot reload.
##

## Paths. USER_PATH is the one you edit by hand.
const RES_PATH := "res://assets/config/game.cfg"
const USER_PATH := "user://config/game.cfg"

## Default values = the current numbers from the code (rule 2).
## The key order here = the section order in .cfg.
const DEFAULTS := {
	"combat": {
		"hit_base": 70,             # hit base, %
		"hit_soften": 5,            # softening: chance = base*(att+soft)/(def+soft)
		"hit_min": 5,
		"hit_max": 95,
		"damage_multiplier": 1.0,   # global damage multiplier (taken from AION)
		"attack_cooldown": 1.0,     # before, 1.0 was duplicated in three files
		"enemy_defense_div": 25,    # it was max_hp/25
		"enemy_attack_dmg_div": 2,  # it was damage/2
		"enemy_attack_hp_div": 30,  # it was max_hp/30
		"enemy_absorption_div": 40, # it was max_hp/40
		"protection_max": 95,       # elemental resistance cap, %
	},
	"magic": {
		"sp_offset": 15.0,          # SP = skill + mind - offset
		"staff_mana_cost": 4,       # mana per staff hit
		"chain_min_targets": 4,
		"chain_max_targets": 6,
		"chain_radius": 160.0,
		"auto_heal_ratio": 0.45,    # auto-heal when HP/max is below the threshold
		"auto_buff_interval": 2.0,  # seconds between auto-buff checks
		"npc_heal_cooldown": 6.0,   # NPC mages: pause between heals, seconds
		"npc_heal_percent": 0.12,   # NPC mages: share of max HP per heal
	},
	"economy": {
		"start_gold": 20,           # IT USED TO BE 20. Stage 2 will raise it to 400:
		"sell_price_div": 2,        # sale = price / div (hardcoded in two places)
		"loot_gold_multiplier": 1.0,
	},
	"loot": {
		"enemy_potion_chance": 45,   # it was randi()%100 < 45
		"enemy_gear_chance": 35,
		"npc_citizen_potion_chance": 50,
		"npc_guard_potion_chance": 25,
		# npc_guard_gear_chance was REMOVED on 07.10: NPCs always drop a broken
		# item, not with a chance. The chance was part of the old model where NPCs
		# dropped a whole item — now it is broken by definition.
	},
	"progression": {
		"unit_exp_base": 100,
	},
	"npc": {
		# Aggro radius of the city guard against Greys. 190 -> 133 (-30%):
		# the guard stands at the city edge and must not scoop up Greys over an area.
		"guard_aggro_radius": 133.0,
		# Beyond this distance from the post a guard does not chase a Grey.
		"guard_leash": 380.0,
	},
	"movement": {
		"accel": 1100.0,   # duplicated in player.gd and enemy.gd
		"decel": 1800.0,
		"speed_multiplier": 1.0,
	},
	"autosave": {
		"interval": 60.0,
	},
	"world": {
		# Calendar of the live game (28.10): how many REAL seconds one
		# game day lasts. Before that the world day only ticked in the headless sim_runner,
		# so in the game the world feed, the threat and the quest rotation stood still
		# ([quests] offer_ttl_days). 300 s = 5 minutes: quest rotation ~15 min.
		# 0 or less — the calendar is off (the previous behaviour).
		"day_seconds": 300.0,
	},
	"metal": {
		# absorption_min/max — the absorption cap per metal. Referenced by the
		# game_config_smoke test; the game code does not read them yet.
		"absorption_min": 1,
		"absorption_max": 6,

		# --- The "metal -> stats" formula (stage 2, 03.10) -------------------
		# Historically the ingot-price scaler copied damage from the
		# template, and 554 of the 651 faction metal items turned out to be
		# byte-for-byte clones. Now stats = base(type, quality) x
		# (ingot/ingot_ref) ^ exp.
		# The exponents were fitted to the existing "real" metals so that the
		# migration would NOT break them: bronze 1.00, iron 1.40 (was 1.38).
		# Monotonicity by ingot price follows BY ITSELF rather than from
		# a table that has to be maintained by hand.
		# Package A (28.10): 16 faction metals were removed, the formula
		# stayed and still drives the stats of bronze/iron/steel/gold
		# (ingots 2/9/20/80); metal_stats_smoke guards it.
		"reference_metal": "bronze",   # ingot with a multiplier of exactly 1.0
		"damage_exp": 0.22,
		"to_hit_exp": 0.10,            # accuracy grows slower than damage
		"defence_exp": 0.22,
		"absorption_exp": 0.15,
	},
	"craft": {
		# --- Workshop (07.10, package 1) ---------------------------------
		# Blacksmith/Tailor/Master. Metal exists in the game ONLY as
		# a derivative of killed NPCs: broken item -> smelting -> ingot
		# -> recipe. The shop STILL sells armour and weapons — that is a deliberate
		# debt of package 2 (see AGENTS.md), not a workshop bug.

		# Output of smelting a broken item. The amount does NOT depend on the
		# metal price — the ratio is expressed by the item quality, otherwise a
		# fourth currency would appear. Verified against ingot prices: bronze 2 ... gold 80
		# (package A: faction metals removed), the 40-fold spread
		# is covered by three steps.
		"yield_broken": 1,          # ingots from armour/weapons: Broken
		"yield_broken_fine": 2,     # Broken Fine
		"yield_broken_rare": 4,     # Broken Rare
		# The blacksmith gives cloth as a counterweight to the tailor: the tailor needs
		# a lot of cloth, so little of it comes out of a metal item. The exchange is asymmetric
		# on purpose — that is the balance of the two professions.
		"fabric_from_armor": 1,
		"fabric_from_armor_fine": 2,
		"fabric_from_armor_rare": 2,
		"fabric_from_weapon": 0,
		"fabric_from_weapon_fine": 1,
		"fabric_from_weapon_rare": 1,
		# Mage clothing: cloth + magic essence.
		"fabric_from_garment": 2,
		"fabric_from_garment_fine": 4,
		"fabric_from_garment_rare": 6,
		"essence_from_garment": 1,
		"essence_from_garment_fine": 2,
		"essence_from_garment_rare": 3,

		# --- Chances of the three crafting levels -------------------------------
		# 80 / 15 / 5 at skill 0. Skill shifts them so the sum is always 100:
		#   ordinary   = chance_ordinary - ordinary_step * skill
		#   improved   = chance_improved + improved_step * skill
		#   masterwork = chance_master  + master_step  * skill
		# Skill 20 -> 52 / 33 / 15. The ordinary chance is clamped from below by floor_ordinary.
		"chance_ordinary": 80.0,
		"chance_improved": 15.0,
		"chance_master": 5.0,
		"ordinary_step": 1.4,
		"improved_step": 0.9,
		"master_step": 0.5,
		"floor_ordinary": 5.0,

		# Stat multipliers of crafted items. All three
		# levels share ONE texture, only the numbers and the glow shader differ.
		"tier_improved_mult": 1.15,
		"tier_master_mult": 1.35,

		# --- Crafting skills ---------------------------------------------
		# Experience for creating an item. The level growth formula is shared with the combat
		# skills (1.1^n in player.skill_to_exp) — it slows growth by itself.
		"xp_per_craft": 20,
		"xp_per_recycle": 4,
		"xp_tier_bonus": 15,       # extra experience for an improved/masterwork item

		# The master of upgrades - the third tab. Enabled 08.10: the player
		# asked to "do it completely".
		"master_enabled": 1,

		# --- Drops -------------------------------------------------------
		# The essence chance for Greys does NOT live here but in assets/config/
		# loot_tables.json next to gear_chance/potion_chance: it depends on the
		# family (beast / insect / undead / monster), and keeping
		# half the table in the config and half in json is two sources of
		# truth for one number.
		"boss_intact_chance": 12,  # boss/dragon drops a WHOLE item instead of a broken one
	},
	"spawn": {
		# City size and density. city_gap — the gap between buildings, its
		# 26.09 decision ("1 -> 2") was NOT applied in the code: _footprint_fits
		# contained a hardcoded 1, and city_layout_smoke adapted to the fact
		# (`gap >= CITY_GAP - 1`) and silently allowed it to grow.
		#
		# Measurement 03.10: with radius 8 and gap 2 only 3 of 5
		# functional buildings fit into the oval (shop/tavern/forge/school/alchemy) — that
		# is, the city could be left without a forge. So the radius was raised to 9:
		# gap 2 is preserved, all five buildings fit (verified: 8 -> 3
		# of 5, 9 -> 5 of 5).
		"herb_region_grid": 4,
		"herb_min_distance": 4,
		"city_radius": 9,
		"city_gap": 2,

		# Grey respawn. Measurement 03.10: there was NO respawn at all — you killed everyone in the zone,
		# and the zone stayed empty forever. Now we keep a limit.
		# gray_target — how many live Greys we keep; taken from the zone if 0.
		# gray_respawn_min_dist — cells from the hero so a beast does not appear in plain sight.
		# 07.10 package B: the target was raised, the maps must not be "empty".
		"gray_target": 150,
		"gray_respawn_seconds": 20.0,
		"gray_respawn_min_dist": 26,
	},
	"mob_tier": {
		# Multipliers per mob tier (an idea from AION). Grey tiers do not exist in the game yet,
		# the place is reserved in advance — see the audit, package C.
		"hp_multiplier": 1.0,
		"damage_multiplier": 1.0,
	},
	"zone": {
		# Flat keys of the form zone.<name>.<key> — ConfigFile has no nested
		# sections, so the zones live in one section with a prefix.
		#
		# IMPORTANT: the values below = the CURRENT generator behaviour, not the desired one.
		# Right now the zones differ only by Greys (GRAY_ZONE), while the guards and
		# the townsfolk are the same everywhere. The balance stage will raise the Greys in the early zones,
		# the spawn stage will spread the guards over the zones. For now the defaults = as before.
		"start.gray_count_min": 40,     "start.gray_count_max": 60,
		"start.gray_hp_min": 25,       "start.gray_hp_max": 45,
		"start.gray_damage_min": 4,    "start.gray_damage_max": 6,
		"start.guard_hp_min": 60,      "start.guard_hp_max": 100,
		"start.guard_damage_min": 6,   "start.guard_damage_max": 10,
		"start.guard_count_min": 5,    "start.guard_count_max": 8,
		"start.citizen_hp": 30,
		"start.citizen_count_min": 6, "start.citizen_count_max": 9,
		"start.captain_hp": 120,       "start.captain_damage": 12,
		"start.interest_points": 0,    # ruins/camps/shrines. The beginner zone stays quiet: points near the start kill the point of the first city.
		"start.poi_hp": 60,           "start.poi_damage": 6,
		"start.tree_density": 0.18,

		"mid.gray_count_min": 120,     "mid.gray_count_max": 150,
		"mid.gray_hp_min": 45,         "mid.gray_hp_max": 75,
		"mid.gray_damage_min": 6,      "mid.gray_damage_max": 9,
		"mid.guard_hp_min": 60,        "mid.guard_hp_max": 100,
		"mid.guard_damage_min": 6,     "mid.guard_damage_max": 10,
		"mid.guard_count_min": 5,      "mid.guard_count_max": 8,
		"mid.citizen_hp": 30,
		"mid.citizen_count_min": 6,   "mid.citizen_count_max": 9,
		"mid.captain_hp": 120,         "mid.captain_damage": 12,
		"mid.interest_points": 0,
		"mid.poi_hp": 60,             "mid.poi_damage": 6,
		"mid.tree_density": 0.20,

		"hard.gray_count_min": 140,    "hard.gray_count_max": 180,
		"hard.gray_hp_min": 70,        "hard.gray_hp_max": 120,
		"hard.gray_damage_min": 9,     "hard.gray_damage_max": 14,
		"hard.guard_hp_min": 60,       "hard.guard_hp_max": 100,
		"hard.guard_damage_min": 6,    "hard.guard_damage_max": 10,
		"hard.guard_count_min": 5,     "hard.guard_count_max": 8,
		"hard.citizen_hp": 30,
		"hard.citizen_count_min": 6,  "hard.citizen_count_max": 9,
		"hard.captain_hp": 120,        "hard.captain_damage": 12,
		"hard.interest_points": 0,
		"hard.poi_hp": 60,            "hard.poi_damage": 6,
		"hard.tree_density": 0.22,

		"faction.gray_count_min": 100, "faction.gray_count_max": 130,
		"faction.gray_hp_min": 50,     "faction.gray_hp_max": 95,
		"faction.gray_damage_min": 7,  "faction.gray_damage_max": 11,
		"faction.guard_hp_min": 60,    "faction.guard_hp_max": 100,
		"faction.guard_damage_min": 6, "faction.guard_damage_max": 10,
		"faction.guard_count_min": 5,  "faction.guard_count_max": 8,
		"faction.citizen_hp": 30,
		"faction.citizen_count_min": 6, "faction.citizen_count_max": 9,
		"faction.captain_hp": 120,     "faction.captain_damage": 12,
		"faction.interest_points": 0,
		"faction.poi_hp": 60,         "faction.poi_damage": 6,
		"faction.tree_density": 0.20,
	},
	"events": {
		# Dynamic events on the hero map (19.10): NPC vs NPC skirmishes
		# with a lifetime in REAL seconds (the world day is too coarse for
		# a two-minute skirmish — [world] day_seconds); the event marker is always
		# visible on the minimap.
		"enabled": 1,           # enabled after the 19.10 check; 0 = off
		"spawn_period": 45.0,   # seconds between spawn attempts
		"spawn_chance": 35,     # % chance of an event per attempt
		"max_active": 2,        # maximum simultaneous events on the map
		"ttl_seconds_min": 90,
		"ttl_seconds_max": 240,
		"spawn_min_dist": 400,  # px from the hero to the event site
		"spawn_max_dist": 900,
		"members_min": 2,       # size of one skirmish group
		"members_max": 3,
	},
	"quests": {
		# City head quests (22.10): offers by map seed, rotation by the world
		# day, reward = gold + faction reputation + mage power +
		# a blueprint for a hard quest.
		"enabled": 1,
		"offer_slots": 3,          # how many offers one city holds
		"max_active": 5,           # how many quests can be taken at once
		"offer_ttl_days": 3,       # an offer lives this many world days, then rotates
		"urgent_seconds": 120.0,   # time limit of an urgent quest, real seconds
		"blueprint_min_difficulty": 3,
		"kill_elite_hp_mult": 2.5,
		"kill_elite_dmg_mult": 1.5,
		"gray_kill_base": 4,       # base amount in "kill N creatures"
		"rep_base": 5,             # faction reputation for difficulty 1
		"power_base": 0.2,         # mage power for difficulty 1
		"prep_min_dist": 6,        # cells from the hero to the target at spawn
		"prep_max_dist": 22,
	},
	"reputation": {
		# Hero reputation as a pass to goods (28.10). The axis keys are the city
		# race ("humans"/"ork"/"necro"/"druid"), written by the head quests
		# ([quests] rep_base = 5 for difficulty 1).
		#
		# The thresholds were chosen by pacing: one hard quest gives 15, a medium one 9,
		# an easy one 5. Tier 1 = 1 hard quest, tier 3 = 6 hard ones.
		"tier_1": 15,        # second mercenary tier, recipes in the shop
		"tier_2": 40,        # third mercenary tier, elven scrolls
		"tier_3": 80,        # fourth mercenary tier
		"discount_1": 5,     # shop discount, % (cumulative across the tiers)
		"discount_2": 10,
		"discount_3": 15,
		"elven_rep": 40,     # from which reputation elven scrolls are sold
		"inn_tier_cost": 40, # surcharge per mercenary tier, gold
	},
	"outpost": {
		# Faction outposts (package B, 28.10). A camp outside the city: the race tent,
		# a campfire and guards. Clearing all the guards = capturing the outpost.
		#
		# There are no outposts in the starting zone at all (player decision): a beginner
		# must meet only Greys.
		"per_map": 3,        # camps per map (except the starting zone)
		"guards_min": 3,     # guards in a camp
		"guards_max": 5,
		"rep_penalty": 5,    # faction reputation for every guard killed
		"capture_gold": 40,  # gold for capturing an outpost (on top of the guards loot)
	},
	"debug": {
		# Debug toggles (0 = off, 1 = on). The keys exist so that
		# you do not edit code for debugging and do not leave junk in a build.
		#
		# perf: frame profiler (29.10). Every 2 s it prints a table of
		# "ms per frame" by block: guard/enemy AI, pathfinding, hover,
		# the separation grid, fog, quests, events, UI. An enabled
		# profiler costs time itself — for measurements, not for playing.
		"perf": 0,
		#
		# all_magic: all 31 spells + infinite mana. Until 03.10 this was a
		# hard `static var debug_magic = true` in game.gd — that is, the beta build
		# handed out all the magic, and it could not be turned off without editing the code.
		# Now it is just a key.
		"all_magic": 1,
		#
		# fog_of_war: fog of war on the hero map (19.10, FogOfWar). Visibility
		# radius ~14 cells, explored terrain stays dimmed, enemies
		# outside the visible area are hidden. Enabled after the player check on 19.10.
		"fog_of_war": 1,
		#
		# show_coords: a coordinate label in the HUD. Off by default —
		# on screen it looked like a debug thing, which made the build read
		# as a debug build rather than a game.
		"show_coords": 0,
	},
	"archmage": {
		# Faction great mage (package 3.0, docs/lore/gdd_archmage.md).
		#
		# IMPORTANT about decay_base/decay_threat: this is the decay PER TICK, and a tick runs
		# every sim_interval seconds. A day has 86400/sim_interval ticks, therefore
		# the daily decay = decay * 86400/sim_interval.
		#
		# The first version was 0.02 + 0.06, and that gave 4.32 decay per DAY
		# (4320 ticks * 0.02) — the faction fell from 60 to 0 in 14 days, and sustaining
		# it took 216 ingots a day. The run tests/sim_archmage_stakes.py
		# showed the real numbers; see the commit that introduced this key.
		"sim_interval": 20.0,     # seconds between mage ticks
		"decay_base": 0.0005,     # decay per tick at global_threat = 0  -> 2.16/day
		"decay_threat": 0.0015,   # decay per tick at global_threat = 1  -> 8.64/day
		# Payment stakes. A potion is stronger than an ingot on purpose: what the player needs
		# the faction needs too — that is the conflict of choice.
		"stake_ingot": 1.0,       # an ingot of any metal
		"stake_gold": 1.0,        # for gold_per_stake units of gold
		"stake_potion": 1.5,      # a potion
		"gold_per_stake": 100,    # how much gold 1.0 of payment gives
		"power_start": 60.0,      # starting power
		"power_max": 100.0,
		"tier_1": 35.0,           # threshold of stage 1 (offensive)
		"tier_2": 65.0,
		"tier_3": 90.0,
	},
	"stress": {
		# Engine stress test (player 07.10): 1000×1000, ×100 trees/NPCs.
		# enabled=1 only for a run; 0 in production.
		"enabled": 0,
		"map_size": 1000,
		"tree_count": 83700,
		"gray_count": 7500,
		"city_guard_count": 2000,
		"city_citizen_count": 1800,
		"gen_version": 99,
	},
}

static var _cfg: ConfigFile = null
static var _loaded := false
static var _unknown_keys: PackedStringArray = PackedStringArray()


static func load_all() -> void:
	## Reads the res reference, then the user file on top. An error in either
	## is not fatal: the game runs on the defaults.
	_loaded = true
	_unknown_keys = PackedStringArray()
	var cfg := ConfigFile.new()
	var res_err := cfg.load(RES_PATH)
	if res_err != OK:
		push_warning("GameConfig: не читается %s (ошибка %d) — беру дефолты" % [RES_PATH, res_err])
	var user_err := cfg.load(USER_PATH)
	if user_err != OK and user_err != ERR_FILE_NOT_FOUND:
		push_warning("GameConfig: не читается %s (ошибка %d) — он проигнорирован" % [USER_PATH, user_err])
	_cfg = cfg


static func _ensure() -> void:
	if not _loaded:
		load_all()


static func _default_for(section: String, key: String) -> Variant:
	var sec: Variant = DEFAULTS.get(section, null)
	if sec is Dictionary:
		return (sec as Dictionary).get(key, null)
	return null


static func geti(section: String, key: String) -> int:
	_ensure()
	var d: Variant = _default_for(section, key)
	if _cfg != null and _cfg.has_section_key(section, key):
		return int(_cfg.get_value(section, key, d))
	if d == null:
		push_warning("GameConfig: неизвестный ключ %s.%s" % [section, key])
		return 0
	return int(d)


static func getf(section: String, key: String) -> float:
	_ensure()
	var d: Variant = _default_for(section, key)
	if _cfg != null and _cfg.has_section_key(section, key):
		return float(_cfg.get_value(section, key, d))
	if d == null:
		push_warning("GameConfig: неизвестный ключ %s.%s" % [section, key])
		return 0.0
	return float(d)


## A zone key like "start.gray_hp_min" lives in the [zone] section.
static func zonei(zone: String, key: String) -> int:
	return geti("zone", "%s.%s" % [zone, key])


static func zonef(zone: String, key: String) -> float:
	return getf("zone", "%s.%s" % [zone, key])


static func unknown_keys() -> PackedStringArray:
	return _unknown_keys


## All known keys — for the validator and the value dump.
static func known_keys() -> Array[String]:
	var out: Array[String] = []
	for section in DEFAULTS:
		for key in (DEFAULTS[section] as Dictionary):
			out.append("%s.%s" % [section, key])
	return out


## Copy the reference from the repository into the user file so it
## can be edited by hand. Idempotent: if the file already exists, we do not touch it.
static func seed_user_file() -> bool:
	if FileAccess.file_exists(USER_PATH):
		return false
	var cfg := ConfigFile.new()
	if cfg.load(RES_PATH) != OK:
		push_warning("GameConfig: нечего копировать, %s не читается" % RES_PATH)
		return false
	var dir := USER_PATH.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	# set_value for every known key, otherwise save() would create an empty file:
	# ConfigFile does not store comments, and we need a readable file.
	for section in DEFAULTS:
		for key in DEFAULTS[section]:
			cfg.set_value(section, key, (DEFAULTS[section] as Dictionary)[key])
	var err := cfg.save(USER_PATH)
	if err != OK:
		push_warning("GameConfig: не записался %s (ошибка %d)" % [USER_PATH, err])
		return false
	return true