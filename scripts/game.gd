extends Node2D
class_name Game

@onready var alm_map: Node2D = $Map
@onready var player: CharacterBody2D = $Player
@onready var camera: Camera2D = $Camera2D
@onready var ui: CanvasLayer = $UI

## Single direction between two points. Vector2.normalized() on a ZERO vector
## (a unit standing exactly on the waypoint) prints a C++ warning to the console
## "Vector2 cannot be normalized, the elements must be finite", so we normalize
## only a vector longer than the threshold.
static func safe_dir(from: Vector2, to: Vector2, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	var d := to - from
	if d.length_squared() < 0.0001:
		return fallback
	return d.normalized()

## Compass octant of a direction vector: 0..7, the SINGLE source of the convention.
##
## INDEXING IS COUNTER-CLOCKWISE, 0 = NORTH (top of the screen):
##   0=north  7=northeast  6=east  5=southeast
##   4=south  3=southwest  2=west  1=northwest
##
## Extracted from UnitAnim.set_direction_vec because the convention is now read by
## TWO animation backends (sprite sheets and the 2D rig). Duplicating the formula would
## mean that sooner or later the rig would face the wrong way — and direction in combat
## is game information, not decoration. Guard: tests/anim_contract_smoke.gd.
static func unit_octant(dir_vec: Vector2) -> int:
	if dir_vec.length_squared() < 0.001:
		return -1
	var ang := rad_to_deg(dir_vec.angle())  # -180..180, 0 = right
	var d := int(round((ang - 90.0) / 45.0)) % 8
	if d < 0:
		d += 8
	return d

## Nearest cardinal octant: a diagonal collapses onto the neighbouring cardinal.
## Needed by the rig, which has 3 drawn views (south/east/north) while the world asks for 8.
static func snap_octant_to_cardinal(octant: int) -> int:
	if octant < 0:
		return -1
	return posmod(int(round(float(octant) / 2.0)) * 2, 8)

## Whether a unit may step on the map (shared walkability for the player and NPCs).
static var is_paused: bool = false
static var player_target: Vector2 = Vector2.ZERO
static var enemies: Array = []
static var npcs: Array = []               # peaceful residents (Npc) outside Game.enemies
static var hero: Node2D = null            # the player (for mercenaries/loot)
static var fog: FogOfWar = null         # fog of war of the hero map (19.10)
static var pending_fog_rle: String = "" # saved fog mask, applied by FogOfWar
static var pending_events: Array = []   # saved events, applied by EventSystem
## Saved quests (offers, active, history): QuestSystem applies them.
## Empty — a new game; applied=true — the block was already read (do not apply twice).
static var pending_quests: Dictionary = {}
static var pending_quests_applied: bool = false
## Faction outposts (package B, 28.10): what stands on the current map and which are already
## captured. The capture key includes the map (zone|sector|seed) because the
## camp id ("op0") repeats on every map.
static var outposts: Array = []
static var outposts_captured: Dictionary = {}
static var pending_outposts_captured: Dictionary = {}
## Shop stock (09.11): "<seed>|<x>|<y>|<item>" -> bottles left today. The shop
## sells only the temporary regeneration potions and only a couple per city per
## day; a new world day refills the shelves. Saved with the map payload so that
## closing and reopening the panel is not a free refill.
static var shop_stock: Dictionary = {}
static var shop_stock_day: int = -1
## The shop shelf limit per item per city per day (player's decision 09.11).
const SHOP_STOCK_LIMITS := {
	"Potion Health Regeneration": 2,
	"Potion Mana Regeneration": 2,
}


## A new world day refills every shelf. Called from the stock helpers, so the
## panel does not need to listen for day_changed and survives a long sleep.
static func shop_stock_roll(day: int) -> void:
	if shop_stock_day == day:
		return
	shop_stock.clear()
	shop_stock_day = day


## Bottles left today. A key that does not exist yet starts at its limit.
static func shop_stock_left(shop_id: String, item_key: String, limit: int, day: int) -> int:
	shop_stock_roll(day)
	var stock_key := shop_stock_key(shop_id, item_key)
	if not shop_stock.has(stock_key):
		shop_stock[stock_key] = limit
	return int(shop_stock[stock_key])


## Take one from the shelf. False = nothing left, the caller must not charge.
static func shop_stock_take(shop_id: String, item_key: String, limit: int, day: int) -> bool:
	var left := shop_stock_left(shop_id, item_key, limit, day)
	if left <= 0:
		return false
	shop_stock[shop_stock_key(shop_id, item_key)] = left - 1
	return true


static func shop_stock_key(shop_id: String, item_key: String) -> String:
	return "%s|%s" % [shop_id, item_key]
static var _hit_sfx_ms: int = 0          # throttling of the hit sound (single damage point)
## Slot the running game came from ("" — new game). The slot folder holds the
## map files, so a zone change reuses its maps instead of regenerating them.
static var loaded_slot: String = ""
static var party: Array = []              # mercenaries (Mercenary) from the tavern
## Squad from a v2 save: data without nodes. game.gd creates the mercenaries when the map
## is already built (a mercenary needs a walkable tile). Empty — nothing to restore.
static var pending_party: Array = []
static var mana_regen_accum: float = 0.0
static var _trauma: float = 0.0
static var _trauma_t: float = 0.0
static var action_mode: String = "none"  # none, follow, attack, guard
static var action_target: Node2D = null
static var pending_scroll: Dictionary = {}   # scroll targeting: {"spell","item_key"}
## Context for the themed cursor (cursor_layer.gd):
## "" — normal, "cast" — aiming (by pending_*), "buy" — shop,
## "work" — workshop. Set in ui.gd open_shop/open_workshop.
static var cursor_context: String = ""
static var pending_spell: Dictionary = {}    # spell selection from the book: {"name"}
static var hotbar: Dictionary = {}           # quick slot: slot 0..8 (keys 1..9) -> spell name
## Mage auto-magic: settings in Esc → Settings (the "Magic" section).
## auto_buff_tier: base (haste+shield) | medium (+blessing and wards) | max (+invisibility).
## auto_targets:  self (me only) | party (me and the party) | party_neutral (me, party and neutrals).
## auto_spell — manual healing preference (RMB on the book); if empty, the
## first learned healing spell is taken.
static var auto_spell: String = ""
static var auto_buff_tier: String = "base"
static var auto_targets: String = "party"
## Warrior: the ONLY scroll marked with the right button in the magic book.
## Cast automatically on self only, on the spell cooldown, spending 1 scroll.
static var auto_scroll_item: String = ""
static var _spell_targeting_frame: int = -1  # the frame when targeting started (protection against a double cast)
## Debug switches. The source of truth is game.cfg [debug] so that each debug
## session does not require editing code. The value is read ONCE at start;
## tests and debugging assign the variable directly as before (override).
static var debug_magic: bool = GameConfig.geti("debug", "all_magic") != 0
## Frame profiler (29.10, analysing the city slowdown). Enabled by
## [debug] perf = 1 or by assigning Game.perf_enabled = true from a test.
## Accumulates MICROseconds per block name and the call count, every 2 s it prints
## a "ms per frame" table. Needed so we do not guess who eats the frame: AI, pathfinding,
## hover, fog or UI.
static var perf_enabled: bool = GameConfig.geti("debug", "perf") != 0
static var perf_usec: Dictionary = {}
static var perf_calls: Dictionary = {}
static var perf_frames: int = 0
static var _perf_since_ms: int = 0
static var _perf_wall_usec: int = 0
static var _perf_last_usec: int = 0


## Start a block measurement. Returns a timestamp (0 — the profiler is off).
static func perf_begin() -> int:
	return Time.get_ticks_usec() if perf_enabled else 0


## Close a block measurement: key — the block name in the table.
static func perf_end(key: String, t0: int) -> void:
	if not perf_enabled or t0 == 0:
		return
	perf_usec[key] = int(perf_usec.get(key, 0)) + (Time.get_ticks_usec() - t0)


## Event counter (for example, the number of pathfinding calls), not time.
static func perf_count(key: String, amount: int = 1) -> void:
	if not perf_enabled:
		return
	perf_calls[key] = int(perf_calls.get(key, 0)) + amount


## The frame ended: every 2 seconds we print the table and reset the counters.
## Wall time is measured between calls (usually from Game._process), that is, it is
## the real frame duration, not the sum of the measured blocks.
static func perf_frame() -> void:
	if not perf_enabled:
		return
	perf_frames += 1
	var now_us := Time.get_ticks_usec()
	if _perf_last_usec != 0:
		_perf_wall_usec += now_us - _perf_last_usec
	_perf_last_usec = now_us
	var now := Time.get_ticks_msec()
	if _perf_since_ms == 0:
		_perf_since_ms = now
		return
	if now - _perf_since_ms < 2000:
		return
	var frames := maxi(1, perf_frames)
	var wall_ms := float(_perf_wall_usec) / 1000.0
	var lines: Array = []
	var total := 0.0
	for key in perf_usec:
		var ms := float(int(perf_usec[key])) / 1000.0 / float(frames)
		total += ms
		var calls := int(perf_calls.get(key, 0))
		var per_frame := float(calls) / float(frames)
		lines.append("%8.2f ms  %-14s (%6.1f выз/кадр)" % [ms, key, per_frame])
	lines.sort()
	print("--- PERF  кадров: %d, кадр: %.1f мс (%.1f FPS) ---" % [
		frames, wall_ms / float(frames), 1000.0 * float(frames) / maxf(1.0, wall_ms)])
	for l in lines:
		print(l)
	for ck in perf_calls:
		if perf_usec.has(ck):
			continue
		print("%8s     %-14s (%6.1f выз/кадр)" % ["", ck,
			float(int(perf_calls[ck])) / float(frames)])
	print("     сумма замеренных блоков: %.2f мс/кадр" % total)
	perf_usec.clear()
	perf_calls.clear()
	perf_frames = 0
	_perf_wall_usec = 0
	_perf_since_ms = now

# --- Defensive buffs (ward books/scrolls, Shield): incoming damage reduction ---
static func apply_shield(unit: Node2D, strength: int, seconds: float) -> void:
	if not is_instance_valid(unit):
		return
	unit.set_meta("shield_strength", int(unit.get_meta("shield_strength", 0)) + strength)
	unit.set_meta("shield_time", float(unit.get_meta("shield_time", 0.0)) + seconds)

static func shield_reduce(unit: Node2D, dmg: int) -> int:
	if not is_instance_valid(unit):
		return dmg
	var strength := int(unit.get_meta("shield_strength", 0))
	if strength <= 0:
		return dmg
	unit.set_meta("shield_strength", strength - dmg)
	var out := maxi(0, dmg - strength)
	if out == 0:
		print("%s: щит поглотил весь урон!" % unit.name)
	return out

## --- Shared combat math: stats -> chance/damage (for ANY unit) ---

## Hit chance, % — a RELATIVE formula.
##
## It used to be `50 + attack − defense` (clamped 5..95). That is an absolute difference, and
## it broke as soon as equipment entered combat: heavy armour gives
## defence 14, a shield another 4, and an armoured hero held 50 + 8 − 23 = 35 %, while a goblin
## with attack 4 got 5 % (the lower clamp). All the armour in the world hit the floor, and
## "equipment stats do not work" looked like "it works, but you cannot feel it".
##
## Now the chance is the ratio of attack power to defense power, so it works the same
## for a goblin (attack 4), for a troll (attack 30) and for armour.
##   equal stats             -> BASE (70 %)
##   defense twice as high   -> roughly twice as low
##   attack twice as high    -> pinned to MAX
## Combat formula constants moved to GameConfig (assets/config/game.cfg)
## so they can be tuned without editing code. The default values equal
## the previous constants, so game behaviour does not change.
static func hit_chance(attack: int, defense: int) -> int:
	var soften := GameConfig.geti("combat", "hit_soften")
	var a := float(attack) + soften
	var d := float(defense) + soften
	if d <= 0.0:
		return GameConfig.geti("combat", "hit_max")
	return clampi(int(round(float(GameConfig.geti("combat", "hit_base")) * a / d)),
		GameConfig.geti("combat", "hit_min"), GameConfig.geti("combat", "hit_max"))

## Miss? Units with get_attack()/get_defense() methods take part fully.
static func is_miss(attacker: Node2D, defender: Node2D) -> bool:
	var atk := 0
	var dfs := 0
	if attacker != null and attacker.has_method("get_attack"):
		atk = int(attacker.call("get_attack"))
	if defender != null and defender.has_method("get_defense"):
		dfs = int(defender.call("get_defense"))
	return randi() % 100 >= hit_chance(atk, dfs)

## Unit attack (if the method exists — otherwise 0).
static func unit_attack(u: Node2D) -> int:
	return int(u.call("get_attack")) if u != null and u.has_method("get_attack") else 0

## Unit defense (evasion/armour).
static func unit_defense(u: Node2D) -> int:
	return int(u.call("get_defense")) if u != null and u.has_method("get_defense") else 0

## Absorption (material/armour): get_absorption() — present on the hero and enemies.
static func unit_absorption(u: Node2D) -> int:
	return int(u.call("get_absorption")) if u != null and u.has_method("get_absorption") else 0

## Weapon damage kind of a unit for the Allods weapon-kind resistance:
## sword | axe | club | pike | bow. "" means the blow bypasses the table
## (bare hands, a staff — its normal hit is magic anyway, a ranged row that
## the original would clear to slot zero).
static func weapon_kind_of(u: Node2D) -> String:
	if u == null or not is_instance_valid(u) or not ("weapon" in u):
		return ""
	match str(u.get("weapon")):
		"sword", "axe", "club", "pike":
			return str(u.get("weapon"))
		"bow", "xbow":
			return "bow"
	return ""

## Creature type of a damage target: human | undead | beast | insect | monster.
## The hero is always human; a unit without an animation set (a crate, a wall)
## returns "" so the weapon table is skipped.
static func creature_type_of(u: Node2D) -> String:
	if u == null or not is_instance_valid(u):
		return ""
	if u is Player:
		return "human"
	if "anim_set" in u:
		var set_name := str(u.get("anim_set"))
		if set_name != "":
			return UnitDB.creature_type_of(set_name)
	return ""

## Allods weapon-kind damage: `percent` is 125 / 100 / 75 …; the `+75` is the
## source's 0.75 rounding before truncation.
static func apply_weapon_percent(dmg: int, percent: int) -> int:
	if percent == 100:
		return maxi(0, dmg)
	return maxi(0, int((dmg * percent + 75) / 100.0))

## Spell power from the raw numbers (no caster node): skill + mind - offset.
## The creation screen uses it to show a mage's damage before the hero exists.
static func spell_power_value(skill: float, mind: float) -> float:
	return maxf(0.0, skill + mind - GameConfig.getf("magic", "sp_offset"))

## Elemental resistance in PERCENT: what percentage of magic damage
## does not get through. That is how the original does it (main.txt: "shows the percentage of the
## magical effects… which will not affect the character") and it does not break
## on large numbers, unlike flat subtraction.
static func unit_protection(u: Node2D, sphere: String) -> int:
	if u == null or sphere == "":
		return 0
	var m := "get_protection_%s" % sphere.to_lower()
	if u.has_method(m):
		return clampi(int(u.call(m)), 0, GameConfig.geti("combat", "protection_max"))
	return 0

## --- Magic power: ONE stat for damage, healing, shield and vampirism ---
## The original formula (Allods II): SP = sphere skill + mind - 30.
## Clamping to zero is mandatory: with skill 5 and mind 9 it comes out at -16, and the original
## breaks at such values (SP>255 — a byte overflow bug).
static func spell_power(caster: Node2D, sphere: String) -> float:
	if caster == null or not is_instance_valid(caster):
		return 0.0
	var mind := 0.0
	if "mind" in caster:
		mind = float(caster.get("mind"))
	var skill := 0.0
	if caster.has_method("sphere_skill"):
		skill = float(caster.call("sphere_skill", sphere))
	return spell_power_value(skill, mind) + float(StatusEffects.stat_flat(caster, "power"))


## Spell cooldown from KNOWLEDGE of magic, not just the base from spells_db.
##
## The base (`cooldown` in the database) is "reapplying the same spell". But for
## an experienced mage the same spell should be ready sooner: sphere skill and
## mind (the same SP formula as for damage) cut the cooldown down to 50 % at high
## skill. The lower bound of 0.5 s — otherwise the maximum turns into spam.
##
## power_override — for SCROLLS: "knowledge" is taken from the spell power
## embedded in the scroll (50 normal, 100 elven), not from the warrior's skill.
## That is, the cooldown is computed from the magic inside the scroll, not from "using
## an item" (the project has no per-item cooldown and does not need one).
static func spell_cooldown(caster: Node2D, spell_name: String,
		power_override: float = -1.0) -> float:
	var base := SpellDB.cooldown_of(spell_name)
	if base <= 0.0:
		return 0.0
	var sphere := SpellDB.sphere_of(spell_name)
	var power := power_override if power_override >= 0.0 else spell_power(caster, sphere)
	power = clampf(power, 0.0, 100.0)
	return maxf(0.5, base * (1.0 - 0.5 * power / 100.0))


## Magic power threshold: SP = sphere skill + mind - offset.
##
## offset lives in GameConfig: [magic] sp_offset.
##
## In the original Allods II this is 30, and the constant is right FOR THE ORIGINAL
## stats: a level 6 mage has mind ~84. Our stats are 7–10 times smaller
## (a starting mage has mind = 13, sphere skill = 5), and with an offset of 30 it came out
## to 5 + 13 - 30 = -12, that is SP zero for the whole early game: spells did not
## grow with level at all, and Fire_Ball (base 26) hit for exactly its base. A manual
## audit confirmed this.
## Offset 15 was chosen by the player: a starting mage has SP = 3, and as the
## sphere skill goes 5 -> 15 we get SP = 13 (+13 % damage), by 30 — SP = 28. The shape
## of the original is kept, the scale is brought to our numbers.
## Spell damage taking the caster power and the spell multiplier into account.
## final = base * power_coef * (1 + spell_power/100)
static func spell_damage(caster: Node2D, spell_name: String, sphere: String,
		base_damage: int, power_override: float = -1.0) -> int:
	var coef := SpellDB.power_coef_of(spell_name)
	# A scroll carries its own power (50 — normal, 100 — elven). Before, this
	# number was not used at all: the scroll was cast with the hero's skill, and
	# the elven one was not stronger than the normal one.
	var power := power_override if power_override >= 0.0 else spell_power(caster, sphere)
	var raw := float(base_damage) * coef * (1.0 + power / 100.0)
	return maxi(SpellDB.min_damage_of(spell_name), int(round(raw)))


## The SINGLE damage point: physical -> absorption; magic -> elemental defenses; then shield and HP.
## Returns the damage actually dealt (0 — if everything was absorbed/missed).
static func deal_damage(target: Node2D, dmg: int, kind: String, sphere: String, attacker: Node2D) -> int:
	if not is_instance_valid(target) or dmg <= 0:
		return 0
	# Global damage multiplier - the main balance lever (idea from AION).
	# Applied here, at the SINGLE damage point, so the multiplier is the same
	# for melee, magic, projectiles and AoE.
	var final := int(round(float(dmg) * GameConfig.getf("combat", "damage_multiplier")))
	if kind == "magic":
		# Resistance — a percentage of the damage (as in the original)
		var prot := unit_protection(target, sphere)
		final = maxi(0, int(round(float(dmg) * (1.0 - float(prot) / 100.0))))
	else:
		final = maxi(0, final - unit_absorption(target))
		# Allods weapon-kind resistance: a physical blow is reduced (or
		# boosted) by the target's creature type. Only a weapon with a known
		# kind takes part — bare hands, a staff's weak hit and magic do not.
		# Source formula: trunc(damage * (100 - resistance) / 100 + 0.75),
		# i.e. 125% vs undead for a club is resistance -25.
		var wkind := weapon_kind_of(attacker)
		if wkind != "":
			var ctype := creature_type_of(target)
			if ctype != "":
				final = apply_weapon_percent(final, UnitDB.weapon_percent(wkind, ctype))
	if final <= 0:
		# Full absorption BEFORE take_damage. The reason matters to the player: "resilience" is
		# elemental defense, "armour" is a physical hit. Before, both labels were
		# "shield", while the shield has nothing to do with it (shields are counted inside take_damage).
		DamageNumber.show_at(target.global_position, 0,
			"resist" if kind == "magic" else "armor")
		return 0
	var dealt := 0
	if target.has_method("take_damage"):
		dealt = target.call("take_damage", final, attacker)
	# take_damage returned 0 — a SHIELD inside the unit ate the damage. Showing the full
	# number was an outright lie: the player saw "40" where not a single point of
	# damage landed. Now we show that the hit arrived but the shield blocked it.
	if not (dealt is int) or int(dealt) <= 0:
		DamageNumber.show_at(target.global_position, 0, "absorb")
		return 0
	final = int(dealt)
	# The only place where damage is drawn: otherwise the numbers were duplicated
	# in projectile.gd and enemy.gd and showed the raw value instead of the actual one.
	DamageNumber.show_at(target.global_position, final, "damage")
	SpellVFX.hit_flash(target)
	# We voice the physical hit at the single damage point: that way the hero,
	# the mercenaries and NPC skirmishes all get the sound, not only the branches where it was not forgotten.
	if kind != "magic":
		var now := Time.get_ticks_msec()
		if now - _hit_sfx_ms > 55:
			_hit_sfx_ms = now
			var hit_key := "combat.hit.armor" if unit_absorption(target) >= 8 \
				else "combat.hit.flesh"
			SoundDB.play(hit_key, -4.0)
	if kind == "magic" and is_instance_valid(attacker):
		_apply_vampirism(attacker, final)
	return final


## Vampirism (Drain_Life): part of the magic damage dealt returns to the caster.
static func _apply_vampirism(caster: Node2D, dealt: int) -> void:
	var ratio := StatusEffects.vampirism_ratio(caster)
	if ratio <= 0.0 or dealt <= 0:
		return
	var amount := maxi(1, int(float(dealt) * ratio))
	if caster.has_method("heal_amount"):
		caster.call("heal_amount", amount)


## Deal damage to every target in radius (for area spells/explosions).
static func deal_damage_area(targets: Array, dmg: int, kind: String, sphere: String, attacker: Node2D) -> void:
	for t in targets:
		if is_instance_valid(t):
			deal_damage(t, dmg, kind, sphere, attacker)

static func tick_shields(delta: float) -> void:
	var units: Array = [Game.hero]
	units.append_array(Game.enemies)
	units.append_array(Game.npcs)
	units.append_array(Game.party)
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.has_meta("shield_time"):
			continue
		var t := float(u.get_meta("shield_time", 0.0)) - delta
		if t > 0.0:
			u.set_meta("shield_time", t)
		else:
			u.set_meta("shield_time", 0.0)
			u.set_meta("shield_strength", 0)

## Physical core of a unit. Diablo 2 blocks only the CENTRE cell of a unit — the
## sprites may overlap a neighbour's "wings". A 24 px body (radius 12) turned every
## 32 px corridor into a wall and let two figures wedge; the hero even carried a
## 30 px body from the scene. 20 px matches the figure width and lets a unit slip
## past another one while both still block each other.
const UNIT_CORE_RADIUS := 10.0


static func configure_unit_body(unit: Node2D, radius: float = UNIT_CORE_RADIUS) -> void:
	if not (unit is CharacterBody2D):
		return
	var body := unit as CharacterBody2D
	# Layer 1 = walls/buildings/combat units. Mask 1 = we sense layer 1.
	# Peaceful NPCs (residents, the city mage) move to layer 2 after this call —
	# the hero walks through them, otherwise in a city 30+ NPCs "jam" into a crowd.
	body.collision_layer = 1
	body.collision_mask = 1
	# We do NOT touch motion_mode: in top-down MOTION_MODE_FLOATING feels intuitive,
	# but it was tested and rejected — on the dev map the hero got stuck in a pocket between
	# two obstacles (fuzz_edge: 1 stuck case out of 62 instead of 0), because
	# in GROUNDED the sliding surface is classified as "floor" and pushes
	# the hero out of a narrow spot, while in FLOATING any collision is a blank wall.
	# The real cause of "riding the rails" was not this but damping the velocity
	# entirely — fixed with per-axis sliding in player/enemy.
	var shape_node: CollisionShape2D = null
	for child in body.get_children():
		if child is CollisionShape2D:
			shape_node = child as CollisionShape2D
			break
	if shape_node == null:
		shape_node = CollisionShape2D.new()
		shape_node.name = "Collision"
		body.add_child(shape_node)
	if shape_node.shape == null:
		var shape := CircleShape2D.new()
		shape.radius = radius
		shape_node.shape = shape
	elif shape_node.shape is CircleShape2D:
		# The scene may still carry an older radius (the hero had 15 px): one core
		# size for every unit, otherwise the hero is the widest body on the map.
		(shape_node.shape as CircleShape2D).radius = radius

## Unit separation so they do not stick together. Before, every frame this
## allocated an Array of ALL units and measured the distance to each one —
## with 75 enemies that is O(n²) in physics. Now: an allocation-free buffer,
## an early exit, and peaceful NPCs (layer 2) do not push each other.
const SEP_DIST := 24.0
const SEP_DIST_SQ := SEP_DIST * SEP_DIST
const SEP_SKIP_SQ := 40.0 * 40.0
static var _sep_acc := Vector2.ZERO
## P4: a spatial grid for separation — once per frame we build 64px buckets
## and look only at neighbours. Without it NPC×2 gives O(n²) in physics again.
const SEP_GRID_CELL := 64.0
static var _sep_grid: Dictionary = {}
static var _sep_grid_frame: int = -1


static func _sep_bucket_key(pos: Vector2) -> String:
	return "%d,%d" % [int(floor(pos.x / SEP_GRID_CELL)), int(floor(pos.y / SEP_GRID_CELL))]


static func _sep_insert(unit) -> void:
	# The parameter is UNTYPED on purpose: a typed `unit: Node2D` is checked
	# by the engine BEFORE entering the body, and on a freed node the whole function fails -
	# is_instance_valid inside no longer helps. Player report 09.10:
	# "Invalid type in function '_sep_insert' ... argument 1 (previously freed)".
	# Guard: tests/stale_units_smoke.gd. The source is fixed in Main._ready().
	if unit == null or not is_instance_valid(unit) or not (unit is Node2D):
		return
	var key := _sep_bucket_key(unit.global_position)
	var arr: Array = _sep_grid.get(key, [])
	arr.append(unit)
	_sep_grid[key] = arr


static func _sep_rebuild_grid() -> void:
	var f := Engine.get_physics_frames()
	if f == _sep_grid_frame:
		return
	var t0 := perf_begin()
	_sep_grid_frame = f
	_sep_grid.clear()
	if is_instance_valid(Game.hero):
		_sep_insert(Game.hero)
	for other in Game.enemies:
		_sep_insert(other)
	for other in Game.npcs:
		_sep_insert(other)
	for other in Game.party:
		_sep_insert(other)
	perf_end("sep_grid", t0)


static func _sep_neighbors(pos: Vector2) -> Array:
	var out: Array = []
	var cx := int(floor(pos.x / SEP_GRID_CELL))
	var cy := int(floor(pos.y / SEP_GRID_CELL))
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var key := "%d,%d" % [cx + dx, cy + dy]
			var arr: Array = _sep_grid.get(key, [])
			for u in arr:
				out.append(u)
	return out


## Forward progress we refuse to trade away: a neighbour may bend a step sideways
## but never turn the unit around. Diablo 2 walks AROUND a body; our old
## `desired + separation * 1.5` could flip the vector backwards with two close
## neighbours, which read in game as "I cannot walk in the direction he is stuck to".
const SEP_MIN_FORWARD := 0.5


static func movement_direction(unit: Node2D, desired: Vector2) -> Vector2:
	if desired.length_squared() <= 0.0001:
		return Vector2.ZERO
	_sep_acc = Vector2.ZERO
	var my_pos: Vector2 = unit.global_position
	var my_layer: int = 1
	if unit is CollisionObject2D:
		my_layer = (unit as CollisionObject2D).collision_layer
	_sep_rebuild_grid()
	var found := 0
	for other in _sep_neighbors(my_pos):
		if found >= 6:
			break
		if other == unit or not is_instance_valid(other):
			continue
		found += _sep_push(my_pos, my_layer, other)
	var separation := _sep_acc
	var forward := desired.normalized()
	if separation.length_squared() <= 0.0001:
		return forward
	var result := forward + separation * 1.5
	# Keep at least SEP_MIN_FORWARD of the wish; the rest of the push (sideways
	# and braking) stays. If the push is purely opposite, the unit simply walks on.
	var ahead := result.dot(forward)
	if ahead < SEP_MIN_FORWARD:
		result += forward * (SEP_MIN_FORWARD - ahead)
	if result.length_squared() <= 0.0001:
		return forward
	return result.normalized()


## Cells occupied by living units — for pathing AROUND bodies (Diablo 2 `PathTargetFree`).
## Peaceful NPCs (layer 2) and corpses are skipped: the hero walks through both.
## `exclude` drops the pathing unit itself and, for a chase, the clicked target.
static func occupied_cells(exclude: Array = []) -> Dictionary:
	var out := {}
	for list in [Game.enemies, Game.party, Game.npcs]:
		for u in list:
			if u == null or not is_instance_valid(u) or not (u is Node2D):
				continue
			if exclude.has(u):
				continue
			if u is CollisionObject2D \
					and (u as CollisionObject2D).collision_layer == 2:
				continue
			var st: Variant = u.get("state")
			if st is String and (st == "dying" or st == "decay" or st == "corpse"):
				continue
			var p: Vector2 = (u as Node2D).global_position
			out[Vector2i(int(floor(p.x / 32.0)), int(floor(p.y / 32.0)))] = true
	return out


## One unit: if it is nearby — add its contribution to _sep_acc. Returns 0/1.
static func _sep_push(my_pos: Vector2, my_layer: int, other: Node) -> int:
	if other == null or not is_instance_valid(other) or not (other is Node2D):
		return 0
	if other is CollisionObject2D and my_layer == 2 \
			and (other as CollisionObject2D).collision_layer == 2:
		return 0
	var opos: Vector2 = (other as Node2D).global_position
	var dx := my_pos.x - opos.x
	var dy := my_pos.y - opos.y
	var dist_sq := dx * dx + dy * dy
	if dist_sq > SEP_SKIP_SQ or dist_sq < 0.01:
		return 0
	var distance := sqrt(dist_sq)
	if distance >= SEP_DIST:
		return 0
	var w := (SEP_DIST - distance) / SEP_DIST
	_sep_acc.x += dx / distance * w
	_sep_acc.y += dy / distance * w
	return 1


## The best slide when the full step is blocked.
##
## Why. Before, the same thing was duplicated in three places, and all three
## variants picked the axis IN ORDER (`if can_x ... elif can_y ...`), not by
## closeness to the movement direction. When a diagonal step is blocked (a tree,
## a building corner) the unit went strictly along X, even if Y was the "right" one. Beasts near
## trees twitched like a chess knight: a diagonal step turned into a step along one axis.
## A measurement on 03.10 showed that in free diagonal movement 179 frames
## out of 179 were diagonal (angle 0.998) — that is, it was the SLIDING that broke,
## not the walk itself.
##
## Returns a unit axis (or ZERO if neither way is possible).
static func choose_slide(desired: Vector2, can_x: bool, can_y: bool) -> Vector2:
	if can_x and can_y:
		# Both are free — take the one that contributes the larger part of the movement.
		var wx := absf(desired.x)
		var wy := absf(desired.y)
		var total := wx + wy
		if total <= 0.0:
			return Vector2.ZERO
		return Vector2(signf(desired.x), 0.0) if wx >= wy else Vector2(0.0, signf(desired.y))
	if can_x:
		return Vector2(signf(desired.x), 0.0)
	if can_y:
		return Vector2(0.0, signf(desired.y))
	return Vector2.ZERO

var _select_ring: SelectRing = null       # target highlight (hover/attack)
var _pending_building := ""               # the building the hero is approaching ("entrance")
var _pending_s: Dictionary = {}           # the structure target of a pending entrance
var _pending_herb: HerbNode = null
var _pending_archmage: Node2D = null      # the captain mage we are approaching
var _pending_city_head: Node2D = null     # the city head we are approaching
var _save_menu: SaveMenu = null
## Death sequence (04.11): the actor emits `died`, the game owns the 1 s fall,
## the full-screen title and the load menu. One flag prevents a second lethal
## hit (or a re-entrant signal) from stacking two screens.
var _death_screen: CanvasLayer = null
var _death_sequence_running := false
## The scene gives way to the main menu or the process is closing (_quit_to_menu/
## _quit_app): the autosave is already written, it must not be repeated when the node is freed.
var _leaving_for_quit: bool = false
var _autosave_accum: float = 0.0
## Autosave interval. 60 s is a compromise: more often means extra I/O, less often means
## minutes of progress can be lost in a crash. The first autosave comes
## 60 s after start, not immediately, so a separate "minimum
## time" is not needed.
const AUTOSAVE_INTERVAL := 60.0

## The autosave interval comes from config [autosave] interval. The constant above
## remains as a fallback value and as an override for tests.
static func autosave_interval() -> float:
	var v := GameConfig.getf("autosave", "interval")
	return AUTOSAVE_INTERVAL if v <= 0.0 else v

# --- Hero selection at start (the character_select scene) ---
static var hero_class: String = "warrior"   # warrior | mage
static var hero_gender: String = "male"     # male | female
static var hero_name: String = "Герой"
static var hero_character_id: String = "human_m_war"  # race portrait id
static var hero_portrait: String = ""       # res:// path to the portrait
static var hero_race: String = "human"      # human | necro | druid | ork
static var hero_stats: Dictionary = {}      # starting stats
static var hero_start_book: String = ""     # the book of the simplest spell of the mage school
## The chosen development direction (skill id: blade/axe/.../fire/...). Its
## level drives survivability: life for both classes, mana for a mage,
## defence for a warrior. The auxiliary skill counts at 60% (see [skill_stats]).
static var hero_primary_skill: String = ""
static var hero_aux_skill: String = ""
## Death latch (package 2 will own the screen): set on a lethal hit, reset by a
## new game or a slot load. Kept here now so character creation can clear it.
static var hero_dead: bool = false
## Hero position from a save. Placed by SaveSystem.apply_payload; applied by
## _spawn_player_on_walkable after the scene is rebuilt (otherwise the hero is always at spawn).
static var load_position: Vector2 = Vector2.ZERO
static var load_position_valid: bool = false

## Hero runtime state from a save (gold/inventory/equipped/HP/spells/...).
## change_scene recreates Player, and _ready handed out the starter set —
## gold and inventory were "lost" even though they sat in the file. An empty dictionary =
## a new game (starting gold/starter set).
static var hero_save: Dictionary = {}

static func clear_load_position() -> void:
	load_position = Vector2.ZERO
	load_position_valid = false


static func clear_hero_save() -> void:
	hero_save = {}
	# New game/new map: captured outposts of the previous world must not
	# "leak" into the new one (the key includes the seed, but old keys would pile up).
	outposts.clear()
	outposts_captured.clear()
	pending_outposts_captured.clear()
	shop_stock.clear()
	shop_stock_day = -1

## Portrait path: an explicit hero_portrait or built from character_id (with legacy mapping).
static func hero_portrait_path() -> String:
	if hero_portrait != "" and ResourceLoader.exists(hero_portrait):
		return hero_portrait
	var cid := hero_character_id
	var legacy := {
		"mfighter": "human_m_war", "ffighter": "human_f_war",
		"mmage": "human_m_mage", "fmage": "human_f_mage",
	}
	if legacy.has(cid):
		cid = str(legacy[cid])
	return "res://assets/hero_portraits/%s.png" % cid

# --- Map selection ---
## An explicitly requested .alm path. Non-empty only when the path was set by hand:
## the map editor (F9 "Back to game") or a save load. Takes priority over the seed.
static var pending_map_path: String = ""
## Map seed of a new game. 0 = no map requested, AlmMap takes the fallback path from main.tscn
## (deterministic dev mode and automated tests — a random map would get in their way).
static var map_seed: int = 0
static var map_zone: String = "mid"   # start | mid | hard | faction (sector TIER)
## World seed of the 4x3 world and the current sector ("s41"). map_seed is derived from them.
static var world_seed: int = 0
static var map_sector: String = ""
## A new game was opened through loading.tscn: main must show the overlay
## while settling and warm-up are running, not blink an empty map.
static var startup_loading: bool = false

## Where to return from the map editor on Esc/F9: the main menu or hero selection.
## An empty string means the default behaviour (the main menu).
static var editor_return_scene: String = ""

## New game settings passed from the map editor ("Play this map").
## character_select reads them once in _ready and clears them.
static var start_preset: Dictionary = {}

static func _world_map() -> GDScript:
	return load("res://scripts/world/world_map.gd") as GDScript

## The seed of a specific sector from the world seed.
static func sector_seed(sector_id: String) -> int:
	if sector_id == "":
		return map_seed
	var bus := _world_bus_static()
	var st: Dictionary = {}
	if bus != null and bus.state != null:
		st = bus.state.sector_state(sector_id)
	if not st.is_empty() and int(st.get("seed", 0)) != 0:
		return int(st.get("seed", 0))
	return int(_world_map().seed_of(world_seed, sector_id))


## An autoload by class name does not resolve in a headless script (verified
## 23.10: "Identifier not found: WorldBus"). We take the node from the tree.
static func _world_bus_static() -> Node:
	var loop := Engine.get_main_loop()
	if loop == null or not (loop is SceneTree):
		return null
	var scene := loop as SceneTree
	if scene.root == null:
		return null
	return scene.root.get_node_or_null("WorldBus")


## Hero reputation with a faction (race) — for storefronts: tavern and shop (28.10).
## An empty race (a map without cities) — no reputation, the storefront works as before.
static func hero_reputation(race: String) -> int:
	if race == "":
		return 0
	var bus := _world_bus_static()
	if bus == null or not ("state" in bus) or bus.state == null:
		return 0
	return int(bus.state.hero_rep(race))


# --- Faction outposts (forging rework package B) ---------------------------

## Capture key: a camp id is unique only inside a map, and sectors have their
## own maps. Seed+zone+sector stay the same after saving and loading (the map
## file name changes to save_<slot>, so the name does not suit the key).
static func outpost_key(oid: String) -> String:
	if oid == "":
		return ""
	return "%s|%s|%d|%s" % [str(map_zone), str(map_sector), int(map_seed), oid]


## Re-read the map outposts. Called after the map is built/loaded and BEFORE
## unit spawn: otherwise the guards of already captured camps would have appeared.
static func reload_outposts(map_node = null) -> void:
	outposts = []
	if map_node != null and is_instance_valid(map_node) \
			and map_node.has_method("outposts"):
		var raw: Variant = map_node.call("outposts")
		if raw is Array:
			outposts = (raw as Array).duplicate(true)
	# The captured state came from a save: we import it once, then it lives in the dictionary.
	if not pending_outposts_captured.is_empty():
		for key in pending_outposts_captured:
			outposts_captured[str(key)] = true
		pending_outposts_captured.clear()


## Whether an outpost of the current map is captured.
static func is_outpost_captured(oid: String) -> bool:
	return outposts_captured.has(outpost_key(oid))


## An outpost guard died: faction reputation drops and, if the camp is cleared,
## it is captured. Called by enemy.gd from take_damage (after loot and the died signal).
static func on_outpost_guard_died(unit: Node2D) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var oid := str(unit.get("outpost_id"))
	if oid == "":
		return
	var faction := str(unit.get("faction"))
	if faction != "":
		var bus := _world_bus_static()
		if bus != null and ("state" in bus) and bus.state != null:
			bus.state.add_hero_reputation(faction, -GameConfig.geti("outpost", "rep_penalty"))
	# Any living guards of the same camp? The corpse is already cleaned from Game.enemies.
	for e in enemies:
		if e != null and is_instance_valid(e) and str(e.get("outpost_id")) == oid:
			return
	var key := outpost_key(oid)
	if key == "" or outposts_captured.has(key):
		return
	outposts_captured[key] = true
	var gold := GameConfig.geti("outpost", "capture_gold")
	if hero != null and is_instance_valid(hero) and hero.has_method("add_gold"):
		hero.call("add_gold", gold)
	var name := oid
	for o in outposts:
		if str((o as Dictionary).get("id", "")) == oid:
			name = str((o as Dictionary).get("name", oid))
			break
	var bus2 := _world_bus_static()
	if bus2 != null and ("state" in bus2) and bus2.state != null:
		bus2.state.log_entry("outpost", "%s захвачен" % name)
	# A capture grants blueprints of that faction's sets (package C+D): took the camp —
	# learned how their armour is forged. Shops (package F) will add a second source.
	var scrolls := CraftDB.recipe_ids_of_faction(faction)
	var given := 0
	if hero != null and is_instance_valid(hero) and hero.has_method("add_item"):
		for rid in scrolls:
			var scroll_key := CraftDB.recipe_scroll_key(str(rid))
			if ItemDB.find(scroll_key).is_empty():
				continue
			if not CraftDB.has_recipe_scroll(hero, str(rid)):
				hero.call("add_item", scroll_key)
				given += 1
	var wf = load("res://scripts/world/world_feed.gd")
	if wf != null:
		var tail := "" if given == 0 else ", чертежей: %d" % given
		wf.post("world", "%s захвачен (+%d золота%s)" % [name, gold, tail])
	print("OUTPOST captured: %s (%s), +%d gold, +%d scrolls" % [name, oid, gold, given])


func _world_bus() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("WorldBus")

## A new map with a random seed. Called from character_select before the start.
## zone can be a tier (start/mid/hard/faction) or a sector id ("s41").
static func new_random_map(zone: String = "mid") -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	world_seed = rng.randi()
	if world_seed == 0:
		world_seed = 4242
	var wm := _world_map()
	var sector := zone if wm.has(zone) else str(wm.sector_for_tier(zone))
	map_sector = sector
	map_zone = str(wm.tier_of(sector)) if sector != "" else zone
	map_seed = int(wm.seed_of(world_seed, sector)) if sector != "" else rng.randi()
	pending_map_path = ""
	clear_load_position()
	clear_hero_save()

## A specific map by seed (save load, tests).
static func request_map_by_seed(seed_value: int, zone: String = "mid") -> void:
	map_seed = seed_value
	map_zone = zone
	map_sector = ""
	world_seed = 0
	pending_map_path = ""
	clear_load_position()
	clear_hero_save()

## An explicitly set map file (editor, debug scenes).
static func request_map_by_path(path: String) -> void:
	pending_map_path = path
	map_seed = 0
	map_sector = ""
	clear_load_position()
	clear_hero_save()

const PLAYER_SPEED: float = 120.0

const POSTFX_SHADER := """shader_type canvas_item;
render_mode unshaded, blend_mix;

// Vignette and grain. Godot 4 Environment has no such fields in any version.
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.34;
uniform float vignette_softness : hint_range(0.05, 1.5) = 0.62;
uniform float grain : hint_range(0.0, 0.15) = 0.022;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 c = SCREEN_UV - vec2(0.5);
	// Account for the aspect ratio, otherwise the vignette is oval on a wide window.
	c.x *= 0.62;
	float v = 1.0 - vignette_strength * smoothstep(0.18, 0.72, length(c) * vignette_softness * 2.0);
	vec3 col = textureLod(screen_texture, SCREEN_UV, 0.0).rgb * v;
	col += (hash21(SCREEN_UV * 1024.0 + fract(TIME) * 91.7) - 0.5) * grain;
	COLOR = vec4(col, 1.0);
}"""

# --- 2D lighting and post-processing ---

## Environment dimming. Almost neutral.
## The first version was 0.88 — and the player complained that "all objects, NPCs and
## buildings went dark". The reason is that the relief has its own brightness from the sun
## baked into the vertex colours (`AlmMap._brightness`), while sprites do not have it and
## live in midtones — where AgX drops brightness the hardest.
## Spell light at 0.97 does not fade: it is short-lived and comes with energy
## 1.5–2.2, so there is enough headroom.
const AMBIENT := Color(0.97, 0.98, 1.0, 1.0)

func _setup_rendering() -> void:
	_setup_ambient()
	_setup_environment()
	_setup_post_pass()


## CanvasModulate — the base brightness of the whole canvas. Without it additive
## light sources cannot add anything: the canvas is already drawn at full
## brightness. It affects ONLY its own layer, so UI on its own CanvasLayer
## is untouched.
func _setup_ambient() -> void:
	if get_node_or_null("Ambient") != null:
		return
	var ambient := CanvasModulate.new()
	ambient.name = "Ambient"
	ambient.color = AMBIENT
	add_child(ambient)


## WorldEnvironment: glow + tone mapping for 2D.
##
## background_mode MUST be BG_CANVAS (3). With the default value
## (BG_CLEAR_COLOR) Environment affects ONLY 3D, and in a purely 2D project that
## means "it does nothing" — the most common waste of time when setting it up.
##
## Channel colours > 1.0 in spell shaders give selective glow:
## before, 2D was RGBA8 and values were clipped to 1.0, that is, "brighter than white"
## was impossible in principle. Now hdr_2d works.
func _setup_environment() -> void:
	if get_node_or_null("WorldEnvironment") != null:
		return
	var env := Environment.new()
	env.background_mode = Environment.BG_CANVAS
	env.glow_enabled = true
	env.glow_intensity = 0.45
	env.glow_bloom = 0.08
	env.glow_strength = 1.1
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	# Threshold a bit below 1.0: with hdr_2d there are almost no truly white
	# pixels in the frame, and at 1.0 nothing would glow.
	env.glow_hdr_threshold = 0.92
	# Glow level names contain "/", such properties cannot be accessed
	# by assignment (only through set()) — direct access does not parse.
	env.set("glow_levels/4", 0.2)
	env.set("glow_levels/5", 0.35)
	env.set("glow_levels/6", 0.18)
	# AgX is kept: it gives the "colourful" ground that was liked. But it also
	# drops midtones, and sprites live exactly there — we compensate with
	# exposure and remove the extra shadow contrast.
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.25
	env.tonemap_agx_contrast = 0.85
	# UI on a CanvasLayer with layer > 0 is already excluded from post-processing.
	env.background_canvas_max_layer = 0

	var node := WorldEnvironment.new()
	node.name = "WorldEnvironment"
	node.environment = env
	add_child(node)


## Post pass: vignette + grain. In Godot 4 Environment there is NO vignette in any
## version — it is always done with a custom shader.
##
## Placed as the FIRST child of the UI CanvasLayer: then the HUD is drawn on top and is not
## darkened, and the layer itself (layer 1) does not fall under glow.
func _setup_post_pass() -> void:
	# The UI node in main.tscn is NOT in the "ui" group (there is no groups = [...] line),
	# so it cannot be found by group — we take the already stored `ui` reference.
	var ui_node: Node = ui
	if ui_node == null:
		ui_node = get_tree().get_first_node_in_group("ui")
	if ui_node == null:
		ui_node = find_child("UI", true, false)
	if ui_node == null:
		return
	if ui_node.get_node_or_null("PostFX") != null:
		return
	var layer: CanvasLayer = ui_node as CanvasLayer
	if layer == null:
		return
	var rect := ColorRect.new()
	rect.name = "PostFX"
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = POSTFX_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	rect.material = mat
	rect.color = Color(1, 1, 1, 1)
	layer.add_child(rect)
	# Move it to the top of the child list so the HUD is ABOVE the post-processing.
	layer.move_child(rect, 0)


func _ready():  # World and combat initialisation
	process_mode = PROCESS_MODE_ALWAYS  # Works even when paused
	# Direct main.tscn launch (F6/tests) bypasses the main menu, which is the
	# normal place where saved key bindings are applied.
	Settings.apply_input()
	# A fresh main scene is a fresh life: the death flag is static and could
	# survive a redirect/restart from a dead run.
	Game.hero_dead = false
	_death_sequence_running = false
	MusicDB.start_playlist.call_deferred()

	# Themed animated cursor (normal + reticle, see cursor_layer.gd).
	add_child(load("res://scripts/cursor_layer.gd").new())

	# Since 21.10: the project physics interpolation (physics/common) forces
	# Camera2D to switch to the physics process and print a WARNING if
	# callback = IDLE. The camera already moves in _physics_process (lerp to
	# the hero) — we set PHYSICS explicitly, the warning is not printed, there is no jitter.
	camera.process_callback = Camera2D.CAMERA2D_PROCESS_PHYSICS

	# 2D lighting and post-processing. Without them effects are drawn "as is" and look
	# like stickers: the VFX rule — an effect must emit light and light up the world.
	_setup_rendering()

	# Reset targeting modes (static state survives a scene restart)
	pending_scroll = {}
	pending_spell = {}
	_spell_targeting_frame = -1
	# We do NOT reset auto-cast: the player set it in the book and expects the mage to heal.

	# Safety net: if main.tscn is launched directly (F6, debugging) without choosing
	# a character at start — we go to the hero selection screen.
	if Game.hero_stats.is_empty():
		get_tree().call_deferred("change_scene_to_file", "res://scenes/character_select.tscn")
		return

	# Spawn the player on a walkable tile in the centre of the map
	_ensure_world_state()
	_sync_sim_from_map()
	# A fresh scene starts the feed with a single arrival line: after loading
	# a save nothing from the previous session should remain.
	var wf = load("res://scripts/world/world_feed.gd")
	wf.clear()
	wf.post("world", Loc.f("ui.feed.arrival", [_sector_name(Game.map_sector)]))
	_spawn_player_on_walkable()
	Game.hero = player
	Game.hero_dead = false
	_death_sequence_running = false
	if is_instance_valid(player) and player.has_signal("died") \
			and not player.died.is_connected(_on_hero_died):
		player.died.connect(_on_hero_died)
	Game.party.clear()
	_restore_pending_party()
	# enemies/npcs are static var, they SURVIVE a scene change: the nodes of the previous
	# map are already freed by the engine at this point, but remain in the arrays.
	# Before, only party was cleaned, and a new game hit
	# `_sep_insert(unit: Node2D)`: argument 1 (previously freed) — a crash on a
	# typed parameter happens BEFORE entering the function body, so
	# is_instance_valid inside _sep_insert does not help.
	# This also fixes the tail in _alive_gray_count (it counted dead nodes).
	Game.enemies.clear()
	Game.npcs.clear()
	# Map outposts — BEFORE the unit spawn: guards of captured camps do not appear.
	Game.reload_outposts(alm_map)
	_sep_grid.clear()
	_sep_grid_frame = -1
	# NPCs and monsters from the map (.alm units section or the .npcs.json sidecar)
	if Game.startup_loading:
		Game.startup_loading = false
		_show_loading(Loc.t("ui.loading.assembly"))
		_spawn_map_units(Callable(self, "_on_startup_spawned"))
	else:
		_spawn_map_units()

	# Fog of war + dynamic events (19.10): nodes find the map via group.
	var fog_node := FogOfWar.new()
	fog_node.name = "FogOfWar"
	add_child(fog_node)
	var events_node := EventSystem.new()
	events_node.name = "EventSystem"
	add_child(events_node)
	var quests_node := QuestSystem.new()
	quests_node.name = "QuestSystem"
	add_child(quests_node)

	if camera and player:
		camera.position = player.camera_focus()
		camera.make_current()

	await get_tree().process_frame

	# Collect enemies (the "enemy" group: scene enemies + map spawns)
	enemies.clear()
	for child in get_children():
		if child.is_in_group("enemy"):
			enemies.append(child)
			print("  Враг найден: ", child.name, " HP=", child.max_hp if "max_hp" in child else "?")

	print("Всего врагов: ", enemies.size())

	# Add the player to the "player" group for the enemies
	player.add_to_group("player")

	if ui:
		ui.setup_ui(player)
	_setup_world_feed()

	_select_ring = SelectRing.new()
	_select_ring.name = "SelectRing"
	_select_ring.z_index = 9
	add_child(_select_ring)
	_select_ring.visible = false

	# Saves: autosave throttling. The first autosave is not earlier than
	# AUTOSAVE_MIN_SECONDS after start, otherwise it would fire on an empty run
	# right after entering the game.
	_autosave_accum = 0.0
	set_process_unhandled_input(true)

func _spawn_player_on_walkable():
	var mw: int = int(alm_map.get("map_width"))
	var mh: int = int(alm_map.get("map_height"))
	if not alm_map or mw == 0:
		return
	# 0) Position from a save (one-shot): the hero stands where they were saved.
	if load_position_valid:
		var lp: Vector2 = load_position
		if alm_map.call("is_walkable_world", lp):
			player.global_position = lp
			player.reset_physics_interpolation()
			clear_load_position()
			return
		clear_load_position()
	# 1) The spawn point set in the map (the "Spawn" type)
	var spawn_pos: Vector2 = alm_map.call("get_spawn_pos")
	if alm_map.call("is_walkable_world", spawn_pos):
		player.global_position = spawn_pos
		player.reset_physics_interpolation()
		return
	# 2) Fallback — a walkable tile from the centre
	var cx := int(mw / 2.0)
	var cy := int(mh / 2.0)
	for r in range(0, 20):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var tx := cx + dx
				var ty := cy + dy
				var ts: int = int(alm_map.get("tile_size"))
				var wx := tx * ts + ts / 2.0
				var wy := ty * ts + ts / 2.0
				if alm_map.call("is_walkable_world", Vector2(wx, wy)):
					player.global_position = Vector2(wx, wy)
					player.reset_physics_interpolation()
					return


## Restore the squad from a v2 save. Called after the map is built and the
## hero is placed: the mercenary position from the save is checked for walkability, otherwise
## they stand next to the hero (the cell could be taken by a building after regeneration).
func _restore_pending_party() -> void:
	if Game.pending_party.is_empty():
		return
	var saved: Array = Game.pending_party
	Game.pending_party = []
	for i in range(saved.size()):
		var raw: Variant = saved[i]
		if not (raw is Dictionary):
			continue
		var rec: Dictionary = raw
		var mercenary := Mercenary.new()
		mercenary.anim_set = str(rec.get("set", mercenary.anim_set))
		mercenary.max_hp = maxi(1, int(rec.get("hp_max", mercenary.max_hp)))
		mercenary.damage = maxi(0, int(rec.get("damage", mercenary.damage)))
		mercenary.spirit = maxi(0, int(rec.get("spirit", mercenary.spirit)))
		mercenary.move_speed = maxf(10.0, float(rec.get("speed", mercenary.move_speed)))
		add_child(mercenary)
		var saved_pos := Vector2(float(rec.get("x", 0.0)), float(rec.get("y", 0.0)))
		var on_land := false
		if is_instance_valid(alm_map) and alm_map.has_method("is_walkable_world") \
				and saved_pos != Vector2.ZERO:
			on_land = bool(alm_map.call("is_walkable_world", saved_pos))
		if on_land:
			mercenary.global_position = saved_pos
		elif is_instance_valid(player):
			mercenary.global_position = player.global_position \
				+ Vector2(32.0 * float(i + 1), 0.0)
		mercenary.reset_physics_interpolation()
		mercenary.current_hp = clampi(int(rec.get("hp", mercenary.max_hp)),
			1, mercenary.max_hp)
		Game.party.append(mercenary)


## Remove the live squad before loading a slot: otherwise mercenaries of the previous
## run would stay in the scene, and the mercenaries from the save would join them.
func _clear_party_nodes() -> void:
	for m in Game.party:
		if is_instance_valid(m):
			(m as Node).queue_free()
	Game.party.clear()

## Spawn NPCs/monsters from map data: the .alm units section (type_id) or
## the .npcs.json sidecar (set). Hostility — UnitDB.is_hostile (monsters palette=5).
func _spawn_map_units(done: Callable = Callable()) -> void:
	if alm_map == null or not alm_map.has_method("get_units"):
		if done.is_valid():
			done.call()
		return
	var recs: Array = alm_map.call("get_units")
	var spawned := 0
	for rec in recs:
		var set_name := ""
		if rec.has("set"):
			set_name = str(rec["set"])
		elif rec.has("type_id"):
			set_name = UnitDB.set_name_for_id(int(rec["type_id"]))
		if set_name == "" or not UnitDB.has(set_name):
			continue
		# A captured outpost has no guards: the camp already belongs to the hero.
		var oid := str(rec.get("outpost", ""))
		if oid != "" and is_outpost_captured(oid):
			continue
		var raw_cell := Vector2i(int(rec.get("x", 0)), int(rec.get("y", 0)))
		var open_pos := _find_open_spot(raw_cell, int(alm_map.get("tile_size")))
		if open_pos.x < 0.0:
			continue
		if UnitDB.is_hostile(set_name) or oid != "":
			_spawn_monster(set_name, open_pos, rec)
		else:
			_spawn_npc(set_name, open_pos, rec)
		spawned += 1
		# Batches: 190 NPCs in one frame gave a noticeable spike after a transition.
		# The loading overlay is still up at that time, the bar runs 60..95%.
		if spawned % 24 == 0:
			_on_spawn_batch(spawned, recs.size())
			# The map could be freed right during the spawn (a scene change in
			# tests/a transition between zones): then get_tree() is already null, and
			# await failed with "null instance". The rest of the spawn is pointless.
			if not is_inside_tree():
				return
			await get_tree().process_frame
	print("Карта: спавн юнитов %d" % spawned)
	_on_spawn_batch(recs.size(), recs.size())
	if done.is_valid():
		done.call()


func _on_spawn_batch(spawned: int, total: int) -> void:
	if _loading_view == null or not is_instance_valid(_loading_view):
		return
	var frac := float(spawned) / float(maxi(1, total))
	_loading_view.set_progress(int(60.0 + 35.0 * frac), Loc.t("ui.loading.assembly"))


## After the initial settling: a couple of frames for shaders and removing the overlay.
func _on_startup_spawned() -> void:
	for _i in 3:
		await get_tree().process_frame
	_hide_loading()

func _spawn_monster(set_name: String, pos: Vector2, rec: Dictionary) -> void:
	var e := Enemy.new()
	var oid := str(rec.get("outpost", ""))
	# Node name: outpost guards share the same unit set (city_ork_warrior/t1), and without
	# the camp id in debug output all guards would be "Monster_t1".
	e.name = ("Outpost_%s_%s" % [oid, set_name.get_file()]) if oid != "" \
		else "Monster_" + set_name.get_file()
	e.anim_set = set_name
	var hp := int(rec.get("hp_max", 0))
	if hp > 0:
		e.max_hp = hp
	var dmg := int(rec.get("damage", 0))
	if dmg > 0:
		e.damage = dmg
	# Outpost (package B): the faction and camp id travel in the .npcs.json record.
	e.faction = str(rec.get("faction", ""))
	e.outpost_id = str(rec.get("outpost", ""))
	e.position = pos
	e.home_position = pos
	add_child(e)
	enemies.append(e)
	if alm_map != null and alm_map.has_method("watch_enemy"):
		alm_map.call("watch_enemy", e)

func _spawn_npc(set_name: String, pos: Vector2, rec: Dictionary) -> void:
	var n := Npc.new()
	n.name = "Npc_" + set_name.get_file()
	n.anim_set = set_name
	n.position = pos
	n.home = pos
	var role := str(rec.get("role", "citizen"))
	n.role = role
	n.is_patrol = bool(rec.get("patrol", false))
	n.is_archmage = bool(rec.get("archmage", false))
	n.is_city_head = bool(rec.get("head", false)) or role == "head"
	n.city_id = str(rec.get("city_id", ""))
	var post: Array = rec.get("post", [])
	if post.size() >= 2:
		var post_cell := Vector2i(int(post[0]), int(post[1]))
		var post_pos := _find_open_spot(post_cell, int(alm_map.get("tile_size")))
		n.post = post_pos if post_pos.x >= 0.0 else pos
	var hp := int(rec.get("hp_max", 0))
	if hp > 0:
		n.max_hp = hp
	var dmg := int(rec.get("damage", 0))
	if dmg > 0:
		n.damage = dmg
	add_child(n)
	npcs.append(n)

## Look for a walkable cell near the spawn that has walkable neighbours
## (at least 2 of 4) — so the character does not end up in a dead end. We return the centre
## of the cell in world coordinates or Vector2(-1,-1) if there is no room within radius 6.
func _find_open_spot(start: Vector2i, ts: int) -> Vector2:
	if _is_open_spot(start.x, start.y):
		return Vector2(start.x * ts + ts / 2.0, start.y * ts + ts / 2.0)
	for r in range(1, 7):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if abs(dx) != r and abs(dy) != r:
					continue  # only the ring at distance r
				var tx := start.x + dx
				var ty := start.y + dy
				if _is_open_spot(tx, ty):
					return Vector2(tx * ts + ts / 2.0, ty * ts + ts / 2.0)
	return Vector2(-1, -1)

## The cell is walkable and has >=2 walkable neighbours (not a nook).
func _is_open_spot(tx: int, ty: int) -> bool:
	var ts: int = alm_map.tile_size
	var wx: int = tx * ts + int(ts / 2.0)
	var wy: int = ty * ts + int(ts / 2.0)
	if not alm_map.is_walkable_world(Vector2(wx, wy)):
		return false
	var open_neighbors := 0
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nx: int = tx + d.x
		var ny: int = ty + d.y
		if nx < 0 or ny < 0 or nx >= alm_map.map_width or ny >= alm_map.map_height:
			continue
		if alm_map.is_walkable_world(Vector2(nx * ts + ts / 2.0, ny * ts + ts / 2.0)):
			open_neighbors += 1
	return open_neighbors >= 2

## Hotbar slot 0..8 for this event. cast_1..3 are rebindable InputMap actions;
## keys 4..9 stay fixed until cast_4..9 are added to project.godot.
func _cast_slot_of(event: InputEvent) -> int:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return -1
	for i in range(3):
		if event.is_action_pressed("cast_%d" % (i + 1)):
			return i
	var key := (event as InputEventKey).keycode
	if key >= KEY_4 and key <= KEY_9:
		return key - KEY_1
	return -1


func _input(event):
	# Dead hero: every world command and the normal Esc menu are off. The
	# game-over panel has its own _input and still receives the event; Esc is
	# deliberately ignored there (player decision 04.11).
	if Game.hero_dead:
		return
	# The portal window handles Esc itself (Esc = "Stay").
	if _portal_confirm != null and is_instance_valid(_portal_confirm):
		return
	# Tactical pause: the world is frozen, so orders/magic are unavailable too.
	# Before, _input kept working (the scene root is Always), and a click on the world
	# or a hotkey 1..9 started a spell right during the pause. We block only
	# those: Esc, Space and the panels (I/B/W/M) are interface, they must keep working.
	if is_paused:
		if event is InputEventMouseButton:
			return
		if _cast_slot_of(event) >= 0:
			return
	# Targeting (a scroll or a book spell): RMB or ESC cancels.
	# The scroll is NOT spent, mana/charge are NOT deducted.
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		if not Game.pending_scroll.is_empty() or not Game.pending_spell.is_empty():
			cancel_targeting()
			return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if not Game.pending_scroll.is_empty() or not Game.pending_spell.is_empty():
			cancel_targeting()
			return
		# The open save menu intercepts Esc itself and closes.
		if _save_menu != null and is_instance_valid(_save_menu):
			return
		open_save_menu()
		return

	# Hotkeys (as in the original): Ctrl+1..9 assigns to a number key either the
	# selected magic or the consumable under the cursor; 1..9 (without Ctrl)
	# applies the assignment: a spell — with targeting, a potion — right away,
	# a scroll — with target selection by click.
	if event is InputEventKey and event.pressed and not event.echo:
		var slot := _cast_slot_of(event)
		if slot >= 0:
			if event.ctrl_pressed:
				var sn := str(Game.pending_spell.get("name", ""))
				if sn != "":
					Game.hotbar[slot] = {"kind": "spell", "name": sn}
					print("Быстрая клавиша %d -> %s" % [slot + 1, sn])
					if ui != null and ui.has_method("_notify_hotbar_assigned"):
						ui._notify_hotbar_assigned(slot, sn)
					return
				var iu := hovered_item_key()
				if iu != "":
					var item := ItemDB.find(iu)
					if not item.is_empty():
						Game.hotbar[slot] = {"kind": "item", "key": iu}
						print("Быстрая клавиша %d -> %s" % [slot + 1, iu])
						if ui != null and ui.has_method("_notify_item_assigned"):
							ui._notify_item_assigned(slot, iu)
						return
				return
			if not event.ctrl_pressed:
				var entry: Dictionary = Game.hotbar.get(slot, {})
				match str(entry.get("kind", "")):
					"spell":
						if ui != null and ui.has_method("_quick_cast"):
							ui._quick_cast(str(entry.get("name", "")))
					"item":
						_use_hotbar_item(str(entry.get("key", "")))
				return

	# Both actions are world clicks: attack_click is the second binding for the
	# same contextual action (click an enemy to attack, ground to move).
	if event is InputEventMouseButton and event.pressed \
			and (event.is_action_pressed("move_click") \
				or event.is_action_pressed("attack_click")):
		# UI clicks (the spell book, inventory, panels, shop/tavern)
		# must not move/attack the hero on the map
		if ui != null and ui.has_method("is_editor_open") and ui.is_editor_open():
			return
		if ui != null and ui.has_method("is_pointer_over_ui") and ui.is_pointer_over_ui(event.position):
			return
		var world_position = get_global_mouse_position()
		# Reading a mage scroll: the click selects a target (an enemy or self/an ally)
		if not Game.pending_scroll.is_empty():
			_resolve_scroll_click(world_position)
			return
		# A spell from the book: the click selects a target for the selected magic
		if not Game.pending_spell.is_empty():
			_resolve_spell_click(world_position)
			return
		handle_click(world_position)

	if event is InputEventKey and event.pressed and not event.echo \
			and event.is_action_pressed("pause"):
		is_paused = !is_paused
		get_tree().paused = is_paused
		return

	# Restart with Ctrl+R
	if event is InputEventKey and event.pressed and event.keycode == KEY_R and event.ctrl_pressed:
		get_tree().reload_current_scene()

	# Open the inventory with I
	if event is InputEventKey and event.pressed and event.keycode == KEY_I:
		if ui:
			ui.open_inventory_panel()

	# Toggle magic with B
	if event is InputEventKey and event.pressed and event.keycode == KEY_B:
		if ui:
			ui.toggle_spells()

	# Quest journal with W (as in the original, quest.txt: "press 'W'")
	if event is InputEventKey and event.pressed and event.keycode == KEY_W \
			and not event.ctrl_pressed:
		if ui and not ui.is_editor_open():
			ui.open_quests()

	# World map with M (23.10)
	if event is InputEventKey and event.pressed and event.keycode == KEY_M \
			and not event.ctrl_pressed:
		if ui:
			ui.open_world_map()

func handle_click(world_position: Vector2):
	# Tactical pause: a click on the world is an order to the hero, there is none during a pause.
	if is_paused:
		return
	if Game.hero_dead:
		return
	# The hero is dead (falling/decomposing) — controls do not work
	if is_instance_valid(player) and player.state in ["dead", "decay"]:
		return
	print("Клик в: ", world_position)
	_pending_herb = null
	_pending_building = ""
	_pending_s = {}
	_pending_archmage = null
	_pending_city_head = null

	# A click on a building (functional or decorative): always to the door.
	# Functional — on approach a menu + the hero is "inside"; decorative — approach only.
	var cell := Vector2i(int(int(world_position.x) / 32.0), int(int(world_position.y) / 32.0))
	if alm_map != null and alm_map.has_method("structure_at"):
		var s: Dictionary = alm_map.call("structure_at", cell)
		if not s.is_empty():
			_building_click(_structure_kind(int(s.get("type_id", 0))), s)
			return
	if alm_map != null and alm_map.has_method("herb_at_position"):
		var herb := alm_map.call("herb_at_position", world_position) as HerbNode
		if herb != null:
			_herb_click(herb)
			return
	# A click on the great mage (captain): we approach / open the panel.
	var mage = _archmage_at_position(world_position)
	if mage != null:
		_archmage_click(mage)
		return
	# A click on the city head: we approach / open the city quests.
	var head = _city_head_at_position(world_position)
	if head != null:
		_city_head_click(head)
		return

	var enemy = get_enemy_at_position(world_position)
	if enemy:
		print("Атака врага!")
		player.attack_target = enemy
		player.state = "chase"
	else:
		print("Движение к: ", world_position)
		var blocked := Game.occupied_cells([player])
		var goal := world_position
		# A click on a BODY (a mercenary, a guard, a Gray that is not a click target)
		# leads to the nearest free cell instead of into the body: Diablo 2's
		# PathTargetFree. This is the "cannot walk in the direction he is stuck to" fix.
		var goal_cell := Vector2i(int(int(goal.x) / 32.0), int(int(goal.y) / 32.0))
		if blocked.has(goal_cell) and alm_map != null and alm_map.has_method("free_cell_near"):
			var free_cell: Vector2i = alm_map.call("free_cell_near", goal_cell, blocked, 2)
			if free_cell.x >= 0:
				goal = Vector2(free_cell.x * 32.0 + 16.0, free_cell.y * 32.0 + 16.0)
		player_target = goal
		player.state = "move"
		player.attack_target = null
		# A route avoiding obstacles (cell pathfinding), not "straight line"
		if alm_map != null and alm_map.has_method("find_path"):
			player.begin_path(alm_map.find_path(player.global_position, goal, blocked))

## The functional role of a building (StructureDB).
## The logic moved to StructureDB.kind_of — it was duplicated by a copy in
## tests/alice_buildings_smoke.gd, and a role change in the game and in the test drifted apart
## silently. Now the test calls the real code.
func _structure_kind(type_id: int) -> String:
	return StructureDB.kind_of(type_id)

## A click on a building: we approach the door (the southern edge of the footprint).
## kind != "" — functional (shop/tavern/…): a menu on approach.
## kind == "" — decorative: approach only, the hero stays on the map.
func _building_click(kind: String, s: Dictionary) -> void:
	if ui == null or not is_instance_valid(player):
		return
	var door := _door_point(s)
	if kind != "" and player.global_position.distance_to(door) <= 90.0:
		_pending_building = ""
		_pending_s = {}
		_open_building_kind(kind, s)
		return
	_pending_building = kind
	_pending_s = s
	player.stop_movement()
	player_target = door
	player.state = "move"
	player.attack_target = null
	if alm_map != null and alm_map.has_method("find_path"):
		player.begin_path(alm_map.find_path(player.global_position, door))

func _open_building_kind(kind: String, s: Dictionary = {}) -> void:
	if ui == null:
		return
	# Reputation (28.10): the tavern and the shop work with the hero's reputation with
	# the faction of the CITY. The city race already lives in city_heads() (written by the generator),
	# and the building looks for the nearest head — a building has no separate city_id.
	var race := _city_race_at_world(_door_point(s)) if not s.is_empty() else ""
	match kind:
		"shop": ui.open_shop(race, s)
		"alchemy": ui.open_alchemy()
		"inn": ui.open_inn(race)
		"school": ui.open_school()
		"workshop": ui.open_workshop()


## The race of the city nearest to a world point ("" — the map has no heads/city).
## Needed by the tavern and shop panels: hero reputation is counted by faction.
func _city_race_at_world(p: Vector2) -> String:
	if alm_map == null or not alm_map.has_method("city_heads"):
		return ""
	var heads: Dictionary = alm_map.call("city_heads")
	if heads.is_empty():
		return ""
	var ts := int(alm_map.get("tile_size"))
	var best := ""
	var best_d := INF
	for cid in heads:
		var rec: Dictionary = heads[cid]
		for cell in (rec.get("cells", []) as Array):
			if not (cell is Array) or (cell as Array).size() < 2:
				continue
			var cx := int((cell as Array)[0])
			var cy := int((cell as Array)[1])
			var d := p.distance_to(Vector2(cx * ts + ts / 2.0, cy * ts + ts / 2.0))
			if d < best_d:
				best_d = d
				best = str(rec.get("race", ""))
	return best

func _herb_click(herb: HerbNode) -> void:
	if not is_instance_valid(herb) or not herb.is_available():
		return
	_pending_building = ""
	player.attack_target = null
	if player.global_position.distance_to(herb.global_position) <= 52.0:
		_harvest_herb(herb)
		return
	_pending_herb = herb
	player_target = herb.global_position
	player.state = "move"
	if alm_map != null and alm_map.has_method("find_path"):
		player.begin_path(alm_map.find_path(player.global_position, herb.global_position))

func _process_pending_herb() -> void:
	if _pending_herb == null:
		return
	if not is_instance_valid(_pending_herb) or not _pending_herb.is_available():
		_pending_herb = null
		return
	if player.global_position.distance_to(_pending_herb.global_position) <= 52.0:
		var herb := _pending_herb
		_pending_herb = null
		_harvest_herb(herb)

func _harvest_herb(herb: HerbNode) -> void:
	if not is_instance_valid(herb) or not herb.harvest():
		return
	player.add_item(herb.item_key)
	if is_instance_valid(ui):
		ui.refresh_inventory()
	SoundDB.play("ui.click")
	print("Собрана трава: %s" % herb.item_key)

## The city great mage (captain) under the cursor.
func _archmage_at_position(click_pos: Vector2) -> Node2D:
	for n in npcs:
		if not is_instance_valid(n):
			continue
		if not ("is_archmage" in n) or not bool(n.is_archmage):
			continue
		if unit_hover_hit(n, click_pos, 8.0):
			return n
	return null

## A click on the mage: if close — the panel, otherwise we approach.
func _archmage_click(mage: Node2D) -> void:
	if ui == null or not is_instance_valid(player) or not is_instance_valid(mage):
		return
	_pending_building = ""
	_pending_s = {}
	_pending_herb = null
	player.attack_target = null
	_pending_city_head = null
	if player.global_position.distance_to(mage.global_position) <= 90.0:
		var ctx := _archmage_context(mage)
		ui.open_archmage(str(ctx.get("city_id", "")), str(ctx.get("race", "")))
		return
	_pending_archmage = mage
	player_target = mage.global_position
	player.state = "move"
	if alm_map != null and alm_map.has_method("find_path"):
		player.begin_path(alm_map.find_path(player.global_position, mage.global_position))

func _process_pending_archmage() -> void:
	if _pending_archmage == null:
		return
	if not is_instance_valid(_pending_archmage) or ui == null:
		_pending_archmage = null
		return
	if player.global_position.distance_to(_pending_archmage.global_position) <= 90.0:
		var mage := _pending_archmage
		_pending_archmage = null
		var ctx := _archmage_context(mage)
		ui.open_archmage(str(ctx.get("city_id", "")), str(ctx.get("race", "")))


## Great mage context for the panel: the city and its race. The race comes from
## city_heads() by the NPC city_id; a fallback — by the captain's unit set name
## ("city_druid_mage/t3" -> druid). Empty — the panel falls back to the hero's race.
func _archmage_context(mage: Node) -> Dictionary:
	var city_id := ""
	if "city_id" in mage:
		city_id = str(mage.get("city_id"))
	var race := ""
	if city_id != "" and alm_map != null and alm_map.has_method("city_heads"):
		var heads: Dictionary = alm_map.call("city_heads")
		var rec: Dictionary = heads.get(city_id, {})
		race = str(rec.get("race", ""))
	if race == "" and "anim_set" in mage:
		race = MapGenerator.race_of_set(str(mage.get("anim_set")))
	return {"city_id": city_id, "race": race}


## The city head under the cursor (an NPC with the "head" role).
func _city_head_at_position(click_pos: Vector2) -> Node2D:
	for n in npcs:
		if not is_instance_valid(n):
			continue
		if not ("is_city_head" in n) or not bool(n.is_city_head):
			continue
		if unit_hover_hit(n, click_pos, 8.0):
			return n
	return null


## A click on the head: if close — the quest panel, otherwise we approach (as with the mage).
func _city_head_click(head: Node2D) -> void:
	if ui == null or not is_instance_valid(player) or not is_instance_valid(head):
		return
	_pending_building = ""
	_pending_s = {}
	_pending_herb = null
	_pending_archmage = null
	player.attack_target = null
	if player.global_position.distance_to(head.global_position) <= 90.0:
		ui.open_quests(str(head.get("city_id")))
		return
	_pending_city_head = head
	player_target = head.global_position
	player.state = "move"
	if alm_map != null and alm_map.has_method("find_path"):
		player.begin_path(alm_map.find_path(player.global_position, head.global_position))


func _process_pending_city_head() -> void:
	if _pending_city_head == null:
		return
	if not is_instance_valid(_pending_city_head) or ui == null:
		_pending_city_head = null
		return
	if player.global_position.distance_to(_pending_city_head.global_position) <= 90.0:
		var cid := str(_pending_city_head.get("city_id"))
		_pending_city_head = null
		ui.open_quests(cid)


## The entrance point (door): a walkable cell under the southern edge of the building body.
func _door_point(s: Dictionary) -> Vector2:
	var def := StructureDB.get_by_id(int(s.get("type_id", 0)))
	var fw := int(def.get("tile_width", 1))
	var th := int(def.get("tile_height", 1))
	var x := int(s.get("ax", 0))
	var y := int(s.get("ay", 0))
	var base := Vector2i(x + int(fw / 2.0), y + th)
	for r in range(3):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if abs(dx) != r and abs(dy) != r:
					continue
				var c := base + Vector2i(dx, dy)
				var p := Vector2(c.x * 32.0 + 16.0, c.y * 32.0 + 16.0)
				if alm_map != null and alm_map.has_method("is_walkable_world") \
						and alm_map.is_walkable_world(p):
					return p
	return Vector2(x * 32.0 + fw * 16.0, (y + th) * 32.0)

## When the hero reaches the door — we "enter": a menu (functional) or a stop.
func _process_pending_building() -> void:
	if _pending_s.is_empty() or not is_instance_valid(player):
		return
	var door := _door_point(_pending_s)
	if player.global_position.distance_to(door) > 80.0:
		return
	var k := _pending_building
	var s := _pending_s
	_pending_building = ""
	_pending_s = {}
	player.stop_movement()
	# Decorative (k==""): the hero stays visible by the wall, no menu.
	if k != "":
		_open_building_kind(k, s)

## The unit under the cursor (an enemy OR a peaceful NPC) by the visible area of the body.
func _hover_unit() -> Node2D:
	if not is_instance_valid(player):
		return null
	var mouse := player.get_global_mouse_position()
	# Culling (29.10): before, an exact hit box was computed for EVERY enemy and
	# map NPC every frame (160+28), although only the neighbouring
	# figure can be under the cursor. A cheap centre comparison removes almost all of it.
	var reach_sq := 128.0 * 128.0
	for e in enemies:
		if is_instance_valid(e) and (e as Node2D).global_position.distance_squared_to(mouse) <= reach_sq \
				and unit_hover_hit(e, mouse):
			return e
	for e in npcs:
		if is_instance_valid(e) and (e as Node2D).global_position.distance_squared_to(mouse) <= reach_sq \
				and unit_hover_hit(e, mouse):
			return e
	return null

## The HEIGHT of a unit sprite above its base (px) — how high one has to
## raise an effect so it ends up above the head and not inside the body.
##
## Taken from UnitAnim.visual_height(): that is the real frame height including
## scale. Do not take _unit_metrics() — that is the FOOTPRINT (how many cells
## the unit occupies): for a hero with tile_size 1 that is 32 px, while the sprite is taller, and
## an effect at that height ended up inside the character (player report).
##
## In all four unit types (player/enemy/npc/mercenary) the animation node
## is called "UnitAnim".
##
## Returns the FIGURE height, not the frame height: our frames share one canvas (64×64),
## while the figure inside occupies ~54 px, and an empty field remains above the head.
## Before, the canvas was returned here, and everything counted "from the height" (auras,
## the healing cross, the camera, the cast point) drifted up/down by ~10 px.
static func unit_visual_height(u: Node2D) -> float:
	var r := unit_local_rect(u)
	if r.size.y > 0.0:
		return r.size.y
	return 32.0


## The figure rect in the unit's LOCAL coordinates: feet ≈ 0, the crown is a negative y.
## The source is the real opaque pixels of the current frame.
static func unit_local_rect(u: Node2D) -> Rect2:
	if not is_instance_valid(u):
		return Rect2(Vector2(-12, -40), Vector2(24, 40))
	var anim := u.get_node_or_null("UnitAnim")
	if anim != null and anim.has_method("content_rect"):
		var r: Rect2 = anim.call("content_rect")
		if r.size.x > 0.5 and r.size.y > 0.5:
			return r
	# Stub: 24×40 — the previous approximate figure.
	return Rect2(Vector2(-12, -40), Vector2(24, 40))


## Cache of texture content rects. A 64×64 frame is scanned once.
static var _content_cache: Dictionary = {}


## The rect of the texture's OPAQUE content in its pixels (cached).
## Alpha threshold 0.06: antialiased edges and an almost transparent halo must not
## stretch the rect to the whole canvas.
static func texture_content_rect(tex: Texture2D) -> Rect2:
	if tex == null:
		return Rect2()
	var key := tex.resource_path
	if key == "":
		key = "id:%d" % tex.get_instance_id()
	if _content_cache.has(key):
		return _content_cache[key]
	var img: Image = tex.get_image()
	if img == null:
		_content_cache[key] = Rect2()
		return Rect2()
	if img.is_compressed():
		img.decompress()
	var w := img.get_width()
	var h := img.get_height()
	var min_x := w
	var min_y := h
	var max_x := -1
	var max_y := -1
	for y in range(h):
		for x in range(w):
			if img.get_pixel(x, y).a > 0.06:
				if x < min_x:
					min_x = x
				if x > max_x:
					max_x = x
				if y < min_y:
					min_y = y
				if y > max_y:
					max_y = y
	var out := Rect2()
	if max_x >= min_x and max_y >= min_y:
		out = Rect2(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)
	_content_cache[key] = out
	return out


## How many pixels of gap between BODIES are needed for a hit to reach.
## Spear — 20, staff — 14, sword/axe — 10, mace — 8, fist/claws — 10.
const REACH_BY_WEAPON := {
	"club": 8.0, "axe": 10.0, "sword": 10.0, "pike": 20.0,
	"staff": 14.0, "unarmed": 10.0, "bow": 10.0,
}
const REACH_DEFAULT := 10.0


## How far a fighter must step back before it breaks contact and closes in again.
## 8 px meant "the hero backs off half a pace and the monster is already chasing" —
## in game that reads as the monster being glued to the hero's back.
const REACH_EXIT_PAD := 24.0


## Strike length of a specific unit: the hero's weapon or a monster's standard paw.
static func attack_reach(u: Node2D) -> float:
	if is_instance_valid(u) and u is Player:
		return float(REACH_BY_WEAPON.get(str(u.get("weapon")), REACH_DEFAULT))
	return REACH_DEFAULT


## The gap at which melee contact is considered broken (attack -> chase).
static func attack_exit_reach(u: Node2D) -> float:
	return attack_reach(u) + REACH_EXIT_PAD

## Unit sprite size (w, h). static: computed only from anim_set, it does not read
## its own state — called both from Game and from SpellAura.
##
## WARNING: this is the FOOTPRINT (how many cells the unit occupies), NOT the sprite height.
## For height (where to hang effects above the head) there is unit_visual_height().
static func _unit_metrics(u: Node2D) -> Array:
	var set_name := ""
	if "anim_set" in u:
		set_name = str(u.get("anim_set"))
	if set_name == "" and u is Player:
		set_name = (u as Player).anim_set_name()
	# Unit sprite size in pixels. Before, the "w"/"h" fields were read from units_db.json,
	# but they are NOT there — the 128 stub kicked in, and the selection ring was 144 px wide
	# regardless of the unit (for a gnome — a circle three times wider than the gnome).
	var w := 32
	var h := 32
	if set_name != "":
		var ts: int = maxi(1, UnitDB.tile_size(set_name))
		w = ts * 32
		h = ts * 32
	return [w, h]

## The selection ring point: the centre of the unit body. The sprite is drawn up from the
## "floor" point and rises with the relief — without accounting for it the ring "hangs in the void".
func _target_ring_pos(u: Node2D) -> Vector2:
	var m := _unit_metrics(u)
	var rise := 0.0
	if alm_map != null and alm_map.has_method("relief_at_world"):
		rise = float(alm_map.call("relief_at_world", u.global_position))
	return Vector2(u.global_position.x, u.global_position.y - float(m[1]) * 0.55 - rise)

## Target highlight: the enemy under the cursor / the current attack target (a red ring)
## or a peaceful NPC under the cursor (a yellow ring).
func _update_target_ring() -> void:
	var target: Node2D = null
	var hostile := false
	if is_instance_valid(player) and is_instance_valid(player.attack_target) \
			and player.state in ["chase", "attack"]:
		target = player.attack_target
		hostile = true
	else:
		target = _hover_unit()
		hostile = target != null and enemies.has(target)
	if _select_ring == null:
		return
	if is_instance_valid(target):
		_select_ring.visible = true
		_select_ring.color = Color(1, 0.3, 0.2, 0.9) if hostile else Color(0.95, 0.85, 0.35, 0.9)
		_select_ring.global_position = _target_ring_pos(target)
		var m := _unit_metrics(target)
		_select_ring.radius = maxf(22.0, float(m[0]) / 2.0 + 8.0)
	else:
		_select_ring.visible = false

func get_enemy_at_position(click_pos: Vector2) -> Node2D:
	for enemy in enemies:
		if is_instance_valid(enemy) and unit_hover_hit(enemy, click_pos, 8.0):
			return enemy
	return null

## Mage scroll: the click selected a target. An enemy — for damage/area/wall,
## the hero or an ally (NPC/mercenary) — for healing/defense/buffs.
## The item key under the cursor in the open inventory ("" = the panel is closed or
## the cursor is not over a cell). Needed to assign a consumable to a hotkey.
func hovered_item_key() -> String:
	if ui == null or not is_instance_valid(ui):
		return ""
	var panel = ui.get("_inventory_panel")
	if panel == null or not is_instance_valid(panel):
		return ""
	return str(panel.get("hovered_item_key"))


## Using a consumable from a hotkey. A potion is drunk at once, a scroll enters
## targeting — exactly like clicking it in the inventory.
func _use_hotbar_item(item_key: String) -> void:
	if item_key == "":
		return
	var item := ItemDB.find(item_key)
	if item.is_empty():
		Game.hotbar.erase(_hotbar_slot_of(item_key))
		return
	if not is_instance_valid(player) or not player.has_item(item_key):
		_flash_cast_error("Нет такого расходника в инвентаре.")
		return
	match str(item.get("quality", "")):
		"Potion":
			if player.use_potion(item_key):
				if ui != null and ui.has_method("refresh_inventory"):
					ui.refresh_inventory()
				if ui != null and ui.has_method("refresh_inventory"):
					ui.refresh_inventory()
				if ui != null and ui.has_method("_update_gold") and player != null:
					ui._update_gold(int(player.gold))
		"Scroll", "SuperScroll":
			var spell_name := str(item.get("type", ""))
			Game.pending_scroll = {"spell": spell_name, "item_key": item_key}
			# Reticle cursor + tooltip, as when choosing a scroll from the inventory.
			if ui != null and ui.has_method("_begin_scroll_targeting"):
				ui._begin_scroll_targeting(item_key)
			else:
				_flash_cast_error("Выберите цель для свитка.")
		_:
			_flash_cast_error("Этот предмет нельзя применить с хоткея.")


func _hotbar_slot_of(item_key: String) -> int:
	for slot in Game.hotbar:
		var entry: Dictionary = Game.hotbar.get(slot, {})
		if str(entry.get("kind", "")) == "item" and str(entry.get("key", "")) == item_key:
			return int(slot)
	return -1


func _resolve_scroll_click(world_position: Vector2) -> void:
	if not is_instance_valid(player):
		return
	var spell := str(Game.pending_scroll.get("spell", ""))
	if spell == "":
		return
	var target_kind := SpellDB.target_of(spell)
	var target: Node2D = null
	if target_kind == "enemy":
		target = get_enemy_at_position(world_position)
		if target == null:
			target = player.get_nearest_enemy(world_position, 220.0)
		if target == null:
			_flash_cast_error("Нет врага под курсором — укажите противника.")
			return
	elif target_kind == "point":
		var under := get_enemy_at_position(world_position)
		if under != null:
			world_position = under.global_position
	else:
		target = _ally_at_position(world_position)
		if target == null:
			# Same as with books: a shield/buff is applied to the hero by default
			if SpellDB.kind_of(spell) == "buff":
				target = player
			else:
				_flash_cast_error("Укажите героя или союзника для этого заклинания.")
				return

	# Range from the database (before, it was not checked at all)
	var max_range := SpellDB.range_of(spell)
	if max_range > 0.0 and target_kind != "self" \
			and player.cast_origin().distance_to(world_position) > max_range:
		_flash_cast_error("Слишком далеко: «%s» достаёт на %d м." % [spell, int(max_range / 32.0)])
		return

	# The item is spent ONLY if the effect was applied: before, remove_item
	# was called unconditionally, and "Scroll Fire Wall" scrolls simply vanished.
	# Scroll power (50/100) comes from its effects and replaces the hero's skill.
	var item_key := str(Game.pending_scroll.get("item_key", ""))
	var scroll_power := SpellDB.scroll_power_of(ItemDB.find(item_key))
	var applied := false
	if target != null:
		applied = player.apply_scroll_to_target(spell, target, scroll_power)
	else:
		applied = player.apply_scroll_to_target_point(spell, world_position, scroll_power)
	if not applied:
		_flash_cast_error("Заклинание не сработало — предмет не потрачен.")
		return
	player.remove_item(str(Game.pending_scroll.get("item_key", "")))
	Game.pending_scroll = {}
	if ui != null and ui.has_method("_finish_scroll_targeting"):
		ui._finish_scroll_targeting()


func _flash_cast_error(msg: String) -> void:
	print(msg)
	if ui != null and ui.has_method("_flash_targeting_error"):
		ui._flash_targeting_error(msg)

## A spell from the book: the click selected a target. Attack/area/wall — at an enemy or
## a point, healing/defense/buff — at the hero or an ally. Mana/charge are deducted
## only on a successful cast.
func _resolve_spell_click(world_position: Vector2) -> void:
	if is_paused:
		return
	if not is_instance_valid(player):
		return
	var name := str(Game.pending_spell.get("name", ""))
	if name == "":
		return
	# Protection: do not cast in the same frame as selecting magic from the book
	if Engine.get_process_frames() == Game._spell_targeting_frame:
		return
	var target_kind := SpellDB.target_of(name)
	var target_position := world_position
	var target_node: Node2D = null
	var ok := true
	var enemy := get_enemy_at_position(world_position)

	match target_kind:
		"enemy":
			if enemy != null:
				target_node = enemy
				target_position = enemy.global_position
			else:
				enemy = player.get_nearest_enemy(world_position, 220.0)
				if enemy == null:
					ok = false
				else:
					target_node = enemy
					target_position = enemy.global_position
		"point":
			if enemy != null:
				target_position = enemy.global_position
		"ally":
			var ally := _ally_at_position(world_position)
			if ally == null:
				# Shields/buffs are convenient to apply to yourself without aiming precisely
				if SpellDB.kind_of(name) == "buff":
					ally = player
				else:
					ok = false
			if ally != null:
				target_position = ally.global_position
				target_node = ally
		_:
			target_node = player
			target_position = player.global_position

	if not ok:
		var msg := "Укажите ВРАГА для «%s» (ПКМ/ESC — отмена)." % name \
			if target_kind == "enemy" else "Укажите ГЕРОЯ или СОЮЗНИКА для «%s»." % name
		print(msg)
		if ui != null and ui.has_method("_flash_targeting_error"):
			ui._flash_targeting_error(msg)
		return

	# Range from the database: before, the range field was not read at all, so one could
	# cast across half the map (teleport included).
	var max_range := SpellDB.range_of(name)
	if max_range > 0.0 and target_kind != "self":
		var origin: Vector2 = player.cast_origin()
		if origin.distance_to(target_position) > max_range:
			var rmsg := "Слишком далеко: «%s» достаёт на %d м." % [name, int(max_range / 32.0)]
			if ui != null and ui.has_method("_flash_targeting_error"):
				ui._flash_targeting_error(rmsg)
			return

	if not player.cast_spell(name, target_position, target_node):
		print("Не удалось кастовать: " + name)
	if ui != null and ui.has_method("_finish_spell_targeting"):
		ui._finish_spell_targeting()

## An ally target under the cursor: the hero, a peaceful NPC or a mercenary.
func _ally_at_position(world_position: Vector2) -> Node2D:
	if is_instance_valid(player) and unit_hover_hit(player, world_position, 8.0):
		return player
	for n in npcs:
		if is_instance_valid(n) and unit_hover_hit(n, world_position, 8.0):
			return n
	for m in party:
		if is_instance_valid(m) and unit_hover_hit(m, world_position, 8.0):
			return m
	return null

## Cancel targeting (a scroll or a book spell). Nothing is spent.
func cancel_targeting() -> void:
	Game.pending_scroll = {}
	Game.pending_spell = {}
	Game._spell_targeting_frame = -1
	if ui != null and ui.has_method("_cancel_targeting"):
		ui._cancel_targeting()

## A unit hit box in the world — by the REAL figure.
##
## History: first the box was built from units_db `w/h` (128) + `sel_box`; there
## `sel_box` is almost nowhere, and the 96×96 stub gave "the sword reaches 4–5
## cells". Then a check "sel_box is default when w>=128" was added, but ALL
## our unit sets have w=h=64, the check did not fire, and units kept carrying
## a 96×96 box — and a shifted one at that: `position + (-32,-64) + (16,16)` = from −16 to
## +80 along X, that is 56 px to the right of the centre.
##
## Now: an explicit `sel_box` is taken only if it really lies inside the frame;
## otherwise — the body rect by the idle pose (`UnitAnim.body_rect()`), not by the canvas and not
## by the attack frame (a sword/staff must not inflate the body).
static func unit_hit_rect(u: Node2D) -> Rect2:
	var t0 := perf_begin()
	var out := _unit_hit_rect_impl(u)
	perf_end("hit_rect", t0)
	return out


static func _unit_hit_rect_impl(u: Node2D) -> Rect2:
	if not is_instance_valid(u):
		return Rect2()
	var set_name := ""
	if "anim_set" in u:
		set_name = str(u.get("anim_set"))
	if set_name == "" and u is Player:
		set_name = (u as Player).anim_set_name()
	if set_name != "":
		var o := UnitDB.get_set(set_name)
		var raw: Variant = o.get("sel_box", null)
		if raw is Array and (raw as Array).size() == 4:
			var cw := int(o.get("w", 128))
			var ch := int(o.get("h", 128))
			var sb := UnitDB.sel_box(set_name)
			var inside := sb.position.x >= 0 and sb.position.y >= 0 \
				and sb.position.x + sb.size.x <= cw and sb.position.y + sb.size.y <= ch \
				and sb.size.x > 0 and sb.size.y > 0
			if inside:
				var base := u.global_position + Vector2(-cw / 2.0, -float(ch))
				return Rect2(base + Vector2(sb.position), Vector2(sb.size))
	# The real body: the idle rect in local coordinates + the world position.
	var body := unit_body_rect(u)
	if body.size.x > 0.5 and body.size.y > 0.5:
		return body
	var local := unit_local_rect(u)
	return Rect2(u.global_position + local.position, local.size)


## The BODY rect in the world: by the idle frame, not the current one (the attack frame is wider).
static func unit_body_rect(u: Node2D) -> Rect2:
	var t0 := perf_begin()
	var out := _unit_body_rect_impl(u)
	perf_end("body_rect", t0)
	return out


static func _unit_body_rect_impl(u: Node2D) -> Rect2:
	if not is_instance_valid(u):
		return Rect2()
	var anim := u.get_node_or_null("UnitAnim")
	if anim != null and anim.has_method("body_rect"):
		var r: Rect2 = anim.call("body_rect")
		if r.size.x > 0.5 and r.size.y > 0.5:
			return Rect2(u.global_position + r.position, r.size)
	var local := unit_local_rect(u)
	return Rect2(u.global_position + local.position, local.size)

## Pixel hover: a hit on an opaque pixel of the current frame.
##
## unit_hit_rect is built from the legacy sel_box/approximation and for some unit sets
## does not match the visible silhouette (player report: "you have to aim lower").
## Here is the exact alpha-channel test; the fallback is unit_hit_rect if
## there is no sprite/texture (broken sets, death without frames).
static var _alpha_cache: Dictionary = {}   # Texture2D -> Dictionary{column x -> Dictionary{y: true}}
static func unit_hover_hit(u: Node2D, world_pos: Vector2, slack: float = 6.0) -> bool:
	if not is_instance_valid(u):
		return false
	var anim: Node = u.get_node_or_null("UnitAnim")
	var sprite: Sprite2D = null
	if anim != null:
		sprite = anim.get_node_or_null("Sprite") as Sprite2D
	var tex: Texture2D = null
	if sprite != null and sprite.texture != null and is_instance_valid(sprite.texture):
		tex = sprite.texture
	if tex == null:
		return unit_hit_rect(u).grow(slack).has_point(world_pos)
	# A point in sprite local coordinates (accounts for the relief/node position).
	var lp := sprite.to_local(world_pos)
	var sx := sprite.scale.x
	var sy := sprite.scale.y
	if is_equal_approx(sx, 0.0) or is_equal_approx(sy, 0.0):
		return unit_hit_rect(u).grow(slack).has_point(world_pos)
	var px := int(floor(lp.x / sx))
	var py := int(floor(lp.y / sy))
	var w := tex.get_width()
	var h := tex.get_height()
	if sprite.flip_h:
		px = w - 1 - px
	# Outside the frame — the previous rect with a tolerance (play, shadows, wide tails).
	if px < -int(slack) or py < -int(slack) or px >= w + int(slack) or py >= h + int(slack):
		return unit_hit_rect(u).grow(slack).has_point(world_pos)
	var img := tex.get_image()
	if img == null:
		return unit_hit_rect(u).grow(slack).has_point(world_pos)
	var mask: Dictionary = _alpha_cache.get(tex, {})
	if mask.is_empty():
		mask = _build_alpha_mask(img)
		_alpha_cache[tex] = mask
	var cx := clampi(px, 0, w - 1)
	var cy := clampi(py, 0, h - 1)
	var col: Dictionary = mask.get(cx, {})
	if col.has(cy):
		return true
	# The opaque pixel is not under the cursor: slack tolerance in 4 directions.
	var s := int(ceil(slack))
	for off in [[s, 0], [-s, 0], [0, s], [0, -s]]:
		var nx: int = cx + int(off[0])
		var ny: int = cy + int(off[1])
		if nx >= 0 and nx < w and ny >= 0 and ny < h:
			if (mask.get(nx, {}) as Dictionary).has(ny):
				return true
	return false

## Opaque pixel mask: column x -> set of y (alpha threshold 8/255).
static func _build_alpha_mask(img: Image) -> Dictionary:
	var mask := {}
	for x in range(img.get_width()):
		var col := {}
		for y in range(img.get_height()):
			if img.get_pixel(x, y).a8 > 8:
				col[y] = true
		if not col.is_empty():
			mask[x] = col
	return mask

## Distance between unit BODIES (hit box to hit box; 0 when they intersect).
## For combat: units stand body to body and attack, not "from afar at the centre".
static func units_range(a: Node2D, b: Node2D) -> float:
	perf_count("units_range_calls")
	var ra := unit_hit_rect(a)
	var rb := unit_hit_rect(b)
	if ra.intersects(rb):
		return 0.0
	var dx := maxf(0.0, maxf(ra.position.x - (rb.position.x + rb.size.x),
		rb.position.x - (ra.position.x + ra.size.x)))
	var dy := maxf(0.0, maxf(ra.position.y - (rb.position.y + rb.size.y),
		rb.position.y - (ra.position.y + ra.size.y)))
	return sqrt(dx * dx + dy * dy)

## Add camera trauma (screen shake). amount: 0.0–1.0.
static func camera_trauma(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)

func _physics_process(delta):
	# The camera in the same tick as the hero: otherwise on high-refresh
	# lerp in _process "jerks" the picture relative to the physics-interpolated
	# unit position (player report 07.10).
	if is_instance_valid(player) and camera:
		# We move the camera explicitly in the physics process — so it has to process its
		# position in the same tick too. process_callback = PHYSICS is set
		# in _ready above/in the scene; enabling the project physics interpolation
		# makes the engine "override" the camera to physics mode itself —
		# this is normal and prints a WARNING. We silence the warning on this node.
		camera.position = camera.position.lerp(player.camera_focus(), 8.0 * delta)
		if _trauma > 0.0:
			_trauma = maxf(_trauma - 1.2 * delta, 0.0)
			var shake := _trauma * _trauma
			_trauma_t += delta * 30.0
			camera.offset = Vector2(
				8.0 * shake * sin(_trauma_t * 1.7),
				6.0 * shake * sin(_trauma_t * 2.3)
			)
		else:
			camera.offset = Vector2.ZERO


func _process(delta):
	if not Game.perf_enabled:
		_process_impl(delta)
		return
	var t0 := Time.get_ticks_usec()
	_process_impl(delta)
	Game.perf_end("game", t0)
	Game.perf_frame()


func _process_impl(delta):
	if is_paused:
		return
	_gray_respawn_tick(delta)
	if is_instance_valid(player) and camera:
		_autosave_tick(delta)
		# The camera is already in _physics_process — here only UI/regen/timers.
	if is_instance_valid(ui) and is_instance_valid(player):
		ui.update_ui(player, delta)
	
	# Hero regeneration: HP and mana by stats, not a hardcoded "+1 mana/s".
	# Before, mana ticked 1/s regardless of Spirit, and HP did not regenerate.
	_regen_hero(delta)
	
	# Handling of behaviour modes
	_process_action_mode()
	if Game.perf_enabled:
		var th := Time.get_ticks_usec()
		_update_target_ring()
		Game.perf_end("hover", th)
	else:
		_update_target_ring()
	_process_pending_building()
	_process_pending_herb()
	_process_pending_archmage()
	_process_pending_city_head()
	Game.tick_shields(delta)
	StatusEffects.tick(delta)
	_check_portal()
	_tick_world_clock(delta)


## The world calendar (28.10). Lives here, not in WorldBus._process: the pause is already
## checked above (`is_paused`), and the headless sim_runner does not raise autoloads.
func _tick_world_clock(delta: float) -> void:
	var bus := _world_bus()
	if bus == null or not bus.has_method("tick_day"):
		return
	bus.call("tick_day", delta)


## F3 world feed: sector/owner/FPS, SIM events, NPC chatter. F3
## adds the technical numbers. Sizes are viewport fractions.
func _setup_world_feed() -> void:
	if _world_feed_panel != null and is_instance_valid(_world_feed_panel):
		return
	var script: GDScript = load("res://scripts/world_feed_panel.gd")
	_world_feed_panel = script.new()
	_world_feed_panel.setup()
	add_child(_world_feed_panel)


## Hero regeneration once per second: HP = 1 + Body/5, mana = 1 + Spirit/10.
func _regen_hero(delta: float) -> void:
	if not is_instance_valid(player):
		return
	if Game.hero_dead or player.state == "dead" or player.state == "decay":
		return
	mana_regen_accum += delta
	if mana_regen_accum < 1.0:
		return
	mana_regen_accum -= 1.0
	# Passive regeneration is background bookkeeping: no floating number, no sound.
	# Floating text belongs to hits, spells and bottles (player report 06.11).
	if player.current_hp < player.max_hp:
		player.heal_amount(player._calc_hp_regen(), false)
	if player.has_mana and player.current_mana < player.max_mana:
		var gain: int = player._calc_mana_regen()
		player.current_mana = mini(player.max_mana, player.current_mana + gain)

func _check_portal() -> void:
	if not is_instance_valid(player) or not is_instance_valid(alm_map):
		return
	if _travelling or (_portal_confirm != null and is_instance_valid(_portal_confirm)):
		return
	var TILE: int = 32
	var cell := Vector2i(int(int(player.global_position.x) / float(TILE)), int(int(player.global_position.y) / float(TILE)))
	var portal := _portal_at(cell)
	if portal.is_empty():
		# Stepped off the portal — it can be asked again.
		_portal_armed = true
		_portal_prompt_cell = Vector2i(-1, -1)
		return
	if not _portal_armed:
		return
	if _portal_prompt_cell == cell:
		return
	_portal_prompt_cell = cell
	_show_portal_confirm(portal)


## The portal under the cell: the new format with an address or the old sidecar without one.
func _portal_at(cell: Vector2i) -> Dictionary:
	var portals: Array = alm_map.call("get_portals") if alm_map.has_method("get_portals") else []
	for raw in portals:
		if raw is Dictionary and Vector2i((raw as Dictionary).get("cell", Vector2i(-1, -1))) == cell:
			return raw as Dictionary
	var cells: Array = alm_map.call("get_portal_cells")
	for pc in cells:
		if cell == pc:
			return {"cell": cell, "to": "", "dir": ""}
	return {}


## The world position of the portal that leads back to from_sector. Arriving
## through a portal puts the hero here, not at the spawn near the city.
func _arrival_portal_pos(from_sector: String) -> Vector2:
	if from_sector == "" or not is_instance_valid(alm_map):
		return Vector2(-1, -1)
	var portals: Array = alm_map.call("get_portals") if alm_map.has_method("get_portals") else []
	var ts: int = int(alm_map.get("tile_size"))
	for raw in portals:
		if not (raw is Dictionary):
			continue
		var rec: Dictionary = raw as Dictionary
		if str(rec.get("to", "")) != from_sector:
			continue
		var cell: Vector2i = rec.get("cell", Vector2i(-1, -1))
		if cell.x < 0:
			continue
		return Vector2(cell.x * ts + ts / 2.0, cell.y * ts + ts / 2.0)
	return Vector2(-1, -1)


func _sector_name(sector_id: String) -> String:
	if sector_id == "":
		return Loc.t("ui.portal.unknown")
	var wm := Game._world_map()
	var info: Dictionary = wm.sector(sector_id)
	if info.is_empty():
		return sector_id
	var key := str(info.get("name_key", ""))
	if key == "":
		return sector_id
	var text := Loc.t(key)
	return sector_id if text == key else text


func _show_portal_confirm(portal: Dictionary) -> void:
	if _portal_confirm != null and is_instance_valid(_portal_confirm):
		return
	_portal_pause_before = get_tree().paused
	get_tree().paused = true
	var script: GDScript = load("res://scripts/portal_confirm.gd")
	_portal_confirm = script.new()
	_portal_confirm.setup(_sector_name(Game.map_sector), _sector_name(str(portal.get("to", ""))))
	_portal_confirm.answered.connect(_on_portal_answer.bind(portal))
	add_child(_portal_confirm)


func _on_portal_answer(travel: bool, portal: Dictionary) -> void:
	_portal_confirm = null
	get_tree().paused = _portal_pause_before
	if not travel:
		return
	_portal_prompt_cell = Vector2i(-1, -1)
	_on_portal_enter(str(portal.get("to", "")))

func _on_portal_enter(target_sector: String = "") -> void:
	if target_sector != "":
		# Autosave BEFORE the sector change: otherwise the "before the portal" point is lost after teleporting.
		autosave_now()
		travel_to_sector(target_sector)
		return
	# An old map without an address: the chain start -> mid -> hard.
	var next_zone := str(PORTAL_CHAIN.get(Game.map_zone, ""))
	if next_zone == "":
		print("Портал из зоны '%s' ведёт в никуда — конец маршрута" % Game.map_zone)
		return
	autosave_now()
	travel_to_zone(next_zone)


## Where the portal leads: start -> mid -> hard. In hard/faction there is no portal,
## it is the end of the route (as intended by the player).
const PORTAL_CHAIN := {"start": "mid", "mid": "hard"}

var _travelling := false
var _world_feed_panel = null
## Portal: after arriving it does not fire until the hero steps off the cell.
var _portal_armed := true
## The cell where we already asked: standing on it, we do not ask again.
var _portal_prompt_cell := Vector2i(-1, -1)
var _portal_confirm = null
var _portal_pause_before := false

# --- Transition loading screen (23.10) ---------------------------------------
var _loading_layer: CanvasLayer = null
var _loading_view: Control = null
var _loading_job = null
var _loading_thread: Thread = null
var _loading_start_ms := 0


func _show_loading(title: String) -> void:
	if _loading_layer != null and is_instance_valid(_loading_layer):
		return
	_loading_layer = CanvasLayer.new()
	_loading_layer.name = "LoadOverlay"
	_loading_layer.layer = 60
	add_child(_loading_layer)
	var view_script: GDScript = load("res://scripts/loading_view.gd")
	_loading_view = view_script.new()
	_loading_view.setup(title)
	_loading_view.back_requested.connect(_hide_loading)
	_loading_layer.add_child(_loading_view)
	_loading_start_ms = Time.get_ticks_msec()


func _hide_loading() -> void:
	if _loading_layer != null and is_instance_valid(_loading_layer):
		_loading_layer.queue_free()
	_loading_layer = null
	_loading_view = null
	_loading_job = null
	_loading_thread = null


func _tick_loading() -> void:
	if _loading_job == null or _loading_view == null or not is_instance_valid(_loading_view):
		return
	var snap: Dictionary = _loading_job.snapshot()
	_loading_view.set_progress(int(snap.get("percent", 0)),
		Loc.t("ui.loading.phase.%d" % clampi(int(snap.get("phase", 0)), 0, 12)))


func _thread_generate_sector(seed_value: int, tier: String, sector: String, size: int,
		ns: Array, relief: String, race: String, job) -> String:
	return MapGenerator.ensure_map(seed_value, tier, MapGenerator.MAPS_DIR, race,
		sector, size, ns, relief, job)


## Transition by tier — a compatibility wrapper (tests, old calls).
func travel_to_zone(zone: String) -> void:
	var wm := Game._world_map()
	if wm.has(zone):
		travel_to_sector(zone)
		return
	var sector := str(wm.sector_for_tier(zone))
	if sector == "":
		push_error("Переход: нет сектора для тира '%s'" % zone)
		return
	travel_to_sector(sector)


## Transition to a neighbouring sector by portal address (the 4x3 world).
func travel_to_sector(sector_id: String) -> void:
	if _travelling or sector_id == "":
		return
	if not is_instance_valid(player):
		return
	var wm := Game._world_map()
	if not wm.has(sector_id):
		push_error("Переход: неизвестный сектор '%s'" % sector_id)
		return
	_travelling = true
	_ensure_world_state()
	var was_paused := get_tree().paused
	get_tree().paused = true
	var info: Dictionary = wm.sector(sector_id)
	var tier := str(info.get("tier", "hard"))
	var seed_value := Game.sector_seed(sector_id)
	var from_sector := Game.map_sector
	_save_sector_fog(from_sector)

	# Generation runs in the background with a progress bar. A 192x192 map after the BFS fix
	# takes ~1.5 s, but even that must not look like a freeze.
	_show_loading(Loc.t("ui.loading.travel"))
	GameConfig.load_all()
	UnitDB.ensure_loaded()
	StructureDB.ensure_loaded()
	var job = load("res://scripts/world/map_load_job.gd").new()
	_loading_job = job
	var race := MapGenerator.city_race_for_hero(Game.hero_race)
	var ns: Array = wm.neighbors(sector_id)
	var size := int(info.get("size", 192))
	var relief := str(info.get("relief", ""))
	var new_path := ""
	# A visited sector is taken from the slot folder: the map already has a built world and
	# must not be regenerated from the seed.
	if loaded_slot != "":
		new_path = SaveSystem.restore_zone_map(loaded_slot, sector_id)
		if new_path != "":
			_loading_view.set_progress(100, 12)
	if new_path == "":
		_loading_thread = Thread.new()
		var err := _loading_thread.start(_thread_generate_sector.bind(seed_value, tier,
			sector_id, size, ns, relief, race, job))
		if err != OK:
			_loading_view.set_error(Loc.t("ui.loading.error_start"))
			_travelling = false
			get_tree().paused = was_paused
			return
		while _loading_thread.is_alive():
			_tick_loading()
			await get_tree().process_frame
		new_path = str(_loading_thread.wait_to_finish())
	if new_path == "" or not FileAccess.file_exists(new_path):
		_loading_view.set_error(Loc.t("ui.loading.error_travel"))
		_travelling = false
		get_tree().paused = was_paused
		return

	await _swap_map(new_path, tier, false, sector_id, from_sector, seed_value)
	Game.map_sector = sector_id
	Game.map_zone = tier
	Game.map_seed = seed_value
	var wf = load("res://scripts/world/world_feed.gd")
	wf.post("you", Loc.f("ui.feed.travel", [_sector_name(from_sector), _sector_name(sector_id)]))
	var bus := _world_bus()
	if bus != null and bus.state != null and not bus.state.sectors.is_empty():
		bus.state.discover_sector(sector_id)
	_apply_sector_fog(sector_id)
	# The slot folder keeps the maps of ALL visited sectors (22.10): after a restart
	# the game runs from the slot, and going back must not give birth to a map with an empty world.
	if loaded_slot != "":
		var store_err := SaveSystem.store_zone_map(loaded_slot, new_path)
		if store_err != "":
			push_warning("SaveSystem: карта сектора '%s' не легла в слот %s: %s" % [sector_id, loaded_slot, store_err])

	# Warm-up: shaders and the first map frames compile/draw under the overlay.
	while Time.get_ticks_msec() - _loading_start_ms < 600:
		await get_tree().process_frame
	for _i in 3:
		await get_tree().process_frame
	_hide_loading()
	get_tree().paused = was_paused
	_travelling = false
	print("Переход: сектор '%s' (%s), карта %s" % [sector_id, tier, new_path])


## Prepare the current 4x3 world if it does not exist yet (a new game / dev map).
func _ensure_world_state() -> void:
	var bus := _world_bus()
	if bus == null or bus.state == null:
		return
	if bus.state.sectors.is_empty() or int(bus.state.world_seed) != int(Game.world_seed):
		var start_owner := MapGenerator.city_race_for_hero(Game.hero_race)
		bus.state.init_world(Game.world_seed, start_owner)
	# Four factions are mandatory (28.10): the undead and the druids must have
	# a great mage. Old saves come with two — we add them here without touching the world.
	if bus.state.has_method("ensure_race_factions"):
		bus.state.ensure_race_factions()
	# The calendar starts over: entering the game and moving to another sector must not
	# "wind up" the day accumulated by the previous scene/session.
	if bus.has_method("reset_day_timer"):
		bus.call("reset_day_timer")


## Build the SIM from the live map's cities (04.11). The first real map replaces
## the hardcoded sandbox; a loaded save keeps its economy because
## WorldBus.sync_sector_map is a no-op once the sector already has cities.
func _sync_sim_from_map() -> void:
	var bus := _world_bus()
	if bus == null or bus.state == null or alm_map == null:
		return
	if not alm_map.has_method("get_cities"):
		return
	var cities: Array = alm_map.call("get_cities")
	if cities.is_empty():
		return
	var sector := Game.map_sector
	if sector == "":
		sector = "zone:" + Game.map_zone
	var region_name := Game.map_zone
	if Game.map_sector != "":
		region_name = _sector_name(Game.map_sector)
	bus.call("sync_sector_map", sector, cities, region_name)


## Sector map for a transition: first from the slot (a visited sector), then from
## The fog of the current sector goes into the world state before the map change.
func _save_sector_fog(sector_id: String) -> void:
	var bus := _world_bus()
	if sector_id == "" or Game.fog == null or bus == null or bus.state == null:
		return
	if not bus.state.sectors.has(sector_id):
		return
	var rle := Game.fog.mask_rle()
	var s: Dictionary = bus.state.sectors[sector_id]
	s["fog"] = rle
	bus.state.sectors[sector_id] = s


## Fog of the new sector: rebuild the mask for the map size and apply it.
func _apply_sector_fog(sector_id: String) -> void:
	var bus := _world_bus()
	if sector_id == "" or Game.fog == null or bus == null or bus.state == null:
		return
	var s: Dictionary = bus.state.sector_state(sector_id)
	Game.fog._setup()
	var rle := str(s.get("fog", ""))
	if rle != "":
		Game.fog.apply_rle(rle)
	else:
		Game.pending_fog_rle = ""


## The zone map for a transition. If the slot the game runs from keeps this
## zone next to the old world state (22.10: the map is whole files in
## the save folder), it comes back from there instead of breeding a map from the seed with
## a new world state.
func _zone_map_path(zone: String, seed_value: int) -> String:
	if loaded_slot != "":
		var from_slot := SaveSystem.restore_zone_map(loaded_slot, zone)
		if from_slot != "":
			return from_slot
	return MapGenerator.ensure_map(seed_value, zone, MapGenerator.MAPS_DIR)


## Recreate the Map node and move the hero and the party onto it.
## from_slot — the map came from this slot's folder (a game load): then the entry
## point is the hero position from the save, not the spawn of a new map.
## map_seed_value — the seed of the NEW map (a transition between sectors): it must
## be applied BEFORE spawning the outpost guards, otherwise the capture key is computed from
## the previous map's seed.
func _swap_map(new_path: String, zone: String, from_slot: bool = false,
		sector: String = "", arrival_from: String = "",
		map_seed_value: int = 0) -> void:
	_clear_world_units()
	# The zone changes BEFORE the map is created: AlmMap._ready and the spawn use
	# Game.map_zone, and it must already match the new map.
	Game.map_zone = zone
	if sector != "":
		Game.map_sector = sector
	if map_seed_value != 0:
		Game.map_seed = map_seed_value
	Game.pending_map_path = new_path
	if is_instance_valid(alm_map):
		remove_child(alm_map)
		alm_map.queue_free()
	var fresh := Node2D.new()
	fresh.name = "Map"
	fresh.set_script(load("res://scripts/alm_map.gd"))
	fresh.set("tile_size", 32)
	fresh.set("alm_path", new_path)
	add_child(fresh)
	move_child(fresh, 0)
	alm_map = fresh
	# The Map node is new while the UI survives the swap: without rebinding, the minimap
	# kept drawing the cache of the previous map.
	if is_instance_valid(ui) and ui.has_method("rebind_map"):
		ui.rebind_map()
	if from_slot and load_position_valid:
		# The position from the save already sits in Game — here only a flag is needed:
		# if it is not found during the loading frame, the hero stands at spawn
		# (the previous behaviour).
		pass
	await get_tree().process_frame
	await get_tree().process_frame
	_portal_armed = true
	_portal_prompt_cell = Vector2i(-1, -1)
	# Slot load: the hero stands where they were saved (if the cell is walkable).
	if from_slot and load_position_valid:
		_portal_armed = false
		var saved_pos: Vector2 = load_position
		if alm_map.call("is_walkable_world", saved_pos):
			player.global_position = saved_pos
		else:
			# The saved cell is not walkable (under a building/water): we look for
			# the nearest open one around it instead of giving the hero to the map spawn.
			var ts: int = int(alm_map.get("tile_size"))
			var start := Vector2i(int(saved_pos.x / float(ts)), int(saved_pos.y / float(ts)))
			var spot: Vector2 = _find_open_spot(start, ts)
			if spot.x >= 0.0:
				player.global_position = spot
			else:
				var fallback: Vector2 = alm_map.call("get_spawn_pos")
				if fallback != Vector2.ZERO:
					player.global_position = fallback
		player.reset_physics_interpolation()
		player.stop_movement()
		Game.clear_load_position()
	else:
		var arrival := _arrival_portal_pos(arrival_from)
		if arrival.x >= 0.0:
			player.global_position = arrival
			_portal_armed = false
			_portal_prompt_cell = Vector2i(-1, -1)
		else:
			var sp: Vector2 = alm_map.call("get_spawn_pos")
			if sp != Vector2.ZERO:
				player.global_position = sp
		player.reset_physics_interpolation()
		player.stop_movement()
	for m in Game.party:
		var unit: Node2D = m as Node2D
		if is_instance_valid(unit):
			unit.global_position = player.global_position + Vector2(32, 0)
			unit.reset_physics_interpolation()
	Game.reload_outposts(alm_map)
	await _spawn_map_units()
	if camera != null and is_instance_valid(player):
		camera.position = player.camera_focus()
		camera.make_current()


## Tear down everything belonging to the previous map: enemies, NPCs and their loot bags.
## Without it, units of the previous zone would stay on the map after a transition, and
## Game.enemies/npcs would pile up pointlessly.
func _clear_world_units() -> void:
	for u in Game.enemies:
		var e: Node = u as Node
		if is_instance_valid(e):
			e.queue_free()
	Game.enemies.clear()
	for n in Game.npcs:
		var node: Node = n as Node
		if is_instance_valid(node):
			node.queue_free()
	Game.npcs.clear()
	# Loot bags lie as separate nodes next to the units.
	for child in get_children():
		# Loot bags were renamed to LootDrop (03.10), but the group kept its
		# old name — the cleanup on zone transitions is tied to it.
		if child.is_in_group("loot_bag") or child.name.begins_with("LootDrop"):
			child.queue_free()
	if is_instance_valid(player):
		player.stop_movement()

## --- Greys respawn (03.10) --------------------------------------------------
##
## Measurement: there was NO respawn at all. Killed everyone in the zone — the zone is empty forever,
## and "the map is boring" only got more boring over time. Now we keep a
## limit: if the living count is below the target, every N seconds one beast appears
## far from the hero.
var _gray_respawn_accum := 0.0

func _alive_gray_count() -> int:
	var n := 0
	for e in Game.enemies:
		var unit: Node = e as Node
		if not is_instance_valid(unit):
			continue
		if UnitDB.has(str(unit.get("anim_set"))) and UnitDB.is_hostile(str(unit.get("anim_set"))):
			n += 1
	return n

func _gray_respawn_tick(delta: float) -> void:
	var period := GameConfig.getf("spawn", "gray_respawn_seconds")
	if period <= 0.0:
		return
	var target := GameConfig.geti("spawn", "gray_target")
	if target <= 0:
		target = maxi(GameConfig.designi(Game.map_zone, "gray_count_min"),
			GameConfig.designi(Game.map_zone, "gray_count_max"))
	if not is_instance_valid(player) or not is_instance_valid(alm_map):
		return
	_gray_respawn_accum += delta
	if _gray_respawn_accum < period:
		return
	_gray_respawn_accum = 0.0
	if _alive_gray_count() >= target:
		return
	var cell := _gray_respawn_cell()
	if cell.x < 0:
		return
	# The pool comes from the SAME tier band as at map generation. If
	# the respawn took the pool directly, tiers 4-5 would appear in the starting zone.
	var pool: Array = MapGenerator.gray_pool_for_zone(Game.map_zone)
	if pool.is_empty():
		return
	var set_name: String = str(pool[randi() % pool.size()])
	var spot := _find_open_spot(cell, int(alm_map.get("tile_size")))
	if spot.x < 0.0:
		return
	var e2 := Enemy.new()
	e2.name = "Monster_" + set_name.get_file()
	e2.anim_set = set_name
	# The tier strengthens a respawned beast the same way as at map generation.
	var mults: Array = MapGenerator.gray_tier_mults(set_name)
	e2.max_hp = int(round(float(randi_range(GameConfig.geti("grey", "hp_min"),
		GameConfig.geti("grey", "hp_max"))) * float(mults[0])))
	e2.damage = int(round(float(randi_range(GameConfig.geti("grey", "damage_min"),
		GameConfig.geti("grey", "damage_max"))) * float(mults[1])))
	e2.position = spot
	e2.home_position = spot
	add_child(e2)
	Game.enemies.append(e2)

## A random walkable cell not closer than gray_respawn_min_dist to the hero.
func _gray_respawn_cell() -> Vector2i:
	var min_d := maxi(4, GameConfig.geti("spawn", "gray_respawn_min_dist"))
	var mw: int = int(alm_map.get("map_width"))
	var mh: int = int(alm_map.get("map_height"))
	if mw <= 0 or mh <= 0:
		return Vector2i(-1, -1)
	var px := int(player.global_position.x / 32.0)
	var py := int(player.global_position.y / 32.0)
	for _i in range(80):
		var c := Vector2i(randi_range(2, mw - 3), randi_range(2, mh - 3))
		if absi(c.x - px) < min_d or absi(c.y - py) < min_d:
			continue
		if not alm_map.call("is_walkable_world", Vector2(c.x * 32 + 16, c.y * 32 + 16)):
			continue
		return c
	return Vector2i(-1, -1)


func _process_action_mode():
	if action_mode == "none" or action_mode == "stop" or not is_instance_valid(player):
		return
	
	match action_mode:
		"follow":
			# Go to the nearest ally (for now the nearest NPC)
			if action_target and is_instance_valid(action_target):
				player.attack_target = action_target
				player.state = "chase"
		"attack":
			# Attack the nearest enemy
			if enemies.size() > 0:
				var nearest = null
				var min_dist = 9999.0
				for e in enemies:
					if is_instance_valid(e):
						var d = e.global_position.distance_to(player.global_position)
						if d < min_dist:
							min_dist = d
							nearest = e
				if nearest:
					player.attack_target = nearest
					player.state = "chase"
		"guard":
			# Stand still and attack enemies in radius
			if player.state == "idle":
				for e in enemies:
					if is_instance_valid(e) and e.global_position.distance_to(player.global_position) < 150:
						player.attack_target = e
						player.state = "chase"
						break

# === Saves ===
#
# The menu saves nothing itself: it only reports a press. All
# saving and loading is here, because only game.gd has a live
# player, a WorldBus with the world state and the scene to rebuild.

## The hero has fallen. The world keeps rendering for one second so the fall
## is readable, but the hero is already no target and every command is blocked
## by Game.hero_dead. Then the black title, then the compact load menu.
const DEATH_TO_TITLE := 1.0
const DEATH_TO_MENU := 1.0

func _on_hero_died() -> void:
	if _death_sequence_running:
		return
	_death_sequence_running = true
	Game.hero_dead = true
	await get_tree().create_timer(DEATH_TO_TITLE).timeout
	if not is_instance_valid(player) or not player.is_dead:
		_death_sequence_running = false
		return
	_death_screen = DeathScreen.new()
	add_child(_death_screen)
	await get_tree().create_timer(DEATH_TO_MENU).timeout
	if not is_instance_valid(player) or not player.is_dead:
		return
	# Freeze the world with the REAL flag: the root Main is PROCESS_MODE_ALWAYS,
	# so SceneTree.paused alone never stopped enemies or the hero (the old
	# death only paused the tree and the corpse kept getting hit).
	Game.is_paused = true
	get_tree().paused = true
	if is_instance_valid(_death_screen):
		_death_screen.queue_free()
		_death_screen = null
	_open_game_over()

## Load-only save menu under a black screen. No Save/Delete, no Esc close,
## only «Загрузить» and «В главное меню» (player decision 04.11).
func _open_game_over() -> void:
	if _save_menu != null and is_instance_valid(_save_menu):
		return
	_save_menu = SaveMenu.new()
	_save_menu.setup("load_only", Loc.t("ui.gameover.title"),
		Loc.t("ui.gameover.hint"))
	_save_menu.load_requested.connect(_load_from_slot)
	_save_menu.quit_requested.connect(_quit_to_menu)
	_save_menu.quit_app_requested.connect(_quit_app)
	_save_menu.closed.connect(func() -> void:
		_save_menu = null)
	add_child(_save_menu)

## Reset every death-owned flag before a slot rebuild. Must run BEFORE
## _restart_scene: _set_menu_pause() refuses to unpause a corpse.
func _close_game_over() -> void:
	_death_sequence_running = false
	if is_instance_valid(_death_screen):
		_death_screen.queue_free()
		_death_screen = null
	if _save_menu != null and is_instance_valid(_save_menu):
		var menu := _save_menu
		_save_menu = null
		menu.queue_free()
	Game.hero_dead = false
	Game.is_paused = false
	get_tree().paused = false
	if is_instance_valid(player) and player.has_method("reset_death_state"):
		player.call("reset_death_state")

## Open the save menu (Esc). A repeated call is ignored.
##
## While the menu is open the world is paused (player report 22.10: "opened the save
## menu, saved — and the character keeps running"). The pause is set and
## removed here, not in SaveMenu: the menu can be closed with Esc, "To the main menu"
## or by terminating the process, and in every path the removal must be in one place.
func open_save_menu() -> void:
	if _save_menu != null and is_instance_valid(_save_menu):
		return
	_set_menu_pause(true)
	_save_menu = SaveMenu.new()
	_save_menu.setup()
	_save_menu.save_requested.connect(_save_to_slot)
	_save_menu.load_requested.connect(_load_from_slot)
	_save_menu.delete_requested.connect(_delete_slot)
	_save_menu.quit_requested.connect(_quit_to_menu)
	_save_menu.quit_app_requested.connect(_quit_app)
	_save_menu.closed.connect(func() -> void:
		_save_menu = null
		_set_menu_pause(false))
	add_child(_save_menu)


## The world is paused while the save menu is open. The hero is dead — the pause is held
## by the death screen (_on_hero_died), and it must not be lifted the usual way.
func _set_menu_pause(on: bool) -> void:
	if Game.hero_dead:
		return
	if is_instance_valid(player) and player.state in ["dead", "decay", "corpse"]:
		return
	Game.is_paused = on
	get_tree().paused = on


## Remove the menu pause on paths where SaveMenu does not emit closed: "To the main
## menu", quitting the game, a scene reload when loading a slot. A paused
## tree does not create nodes (instantiate in SAFE mode returns null), so
## without it loading from the menu would not rebuild the world.
func _menu_release_pause() -> void:
	_set_menu_pause(false)


## Build the payload from the live state. world comes from outside so the
## test can substitute its own WorldState without raising the scene.
func _build_save_payload() -> Dictionary:
	var world_dict: Dictionary = {}
	# WorldBus is an AUTOLOAD, not a GDExtension singleton, so
	# Engine.has_singleton() does not see it: we take the node from the scene tree.
	if is_inside_tree():
		var bus = get_node_or_null("/root/WorldBus")
		if bus != null and "state" in bus and bus.state != null:
			world_dict = bus.state.to_dict()
	return SaveSystem.build_payload(player, world_dict)


func _save_to_slot(slot: String) -> void:
	# Never write a corpse: the autosave on quit/interior must not destroy the
	# last living save after a game over.
	if Game.hero_dead:
		return
	var err := SaveSystem.save(slot, _build_save_payload())
	if err != "":
		if _save_menu != null and is_instance_valid(_save_menu):
			_save_menu.set_status(tr("Не удалось сохранить: %s") % err)
		else:
			push_error("SaveSystem: " + err)
		return
	if _save_menu != null and is_instance_valid(_save_menu):
		_save_menu.set_status(tr("Сохранено в слот."))
		_save_menu._refresh()


func _load_from_slot(slot: String) -> void:
	var res := SaveSystem.load_slot(slot)
	var err_kind := str(res.get("error", ""))
	if err_kind == "version":
		_set_menu_status(tr("Сохранение сделано более новой версией игры (файл v%d, игра v%d) — загрузка отменена.")
			% [int(res.get("file_version", 0)), SaveSystem.VERSION])
		return
	if err_kind == "corrupt":
		_set_menu_status(tr("Файл сохранения повреждён и резервной копии нет."))
		return
	if res.is_empty():
		_set_menu_status(tr("Слот пуст."))
		return
	# A game-over load must release the corpse/pause/menu BEFORE _restart_scene:
	# _set_menu_pause() refuses to unpause while player.state is dead, and the
	# old menu would stay on top of the rebuilt world.
	_close_game_over()
	# First we apply the hero and the slot map, then rebuild the scene:
	# AlmMap reads Game.pending_map_path/map_seed/map_zone in _ready.
	SaveSystem.apply_payload(res.get("data", {}), player, slot)
	loaded_slot = slot
	_restart_scene(slot)


## Deleting a slot: the slot folder becomes empty (player decision 22.10),
## not gone: hero/map/process remain in it without data.
func _delete_slot(slot: String) -> void:
	SaveSystem.clear_slot(slot)
	if _save_menu != null and is_instance_valid(_save_menu):
		_save_menu.set_status(tr("Слот удалён."))
		_save_menu._refresh()


func _quit_to_menu() -> void:
	# Autosave first: while the hero is dead _save_to_slot is a no-op, so the
	# last living save survives "To the main menu" from the game-over screen.
	_save_to_slot(SaveSystem.AUTOSAVE_SLOT)
	_close_game_over()
	# The pause must be removed: otherwise the main menu opens in a stopped
	# tree — with no background animation and no reaction to input. The save menu sets
	# the pause when opening (22.10), and "To the main menu" does not emit closed.
	_menu_release_pause()
	is_paused = false
	get_tree().paused = false
	_set_leaving_scene(true)
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


## Full exit from the process (the "Quit game" button in the Esc menu).
func _quit_app() -> void:
	# Same order as «В главное меню»: save (skipped while dead), release the
	# death screen, then let the process go.
	_save_to_slot(SaveSystem.AUTOSAVE_SLOT)
	_close_game_over()
	_menu_release_pause()
	_set_leaving_scene(true)
	get_tree().quit()


## The scene gives way to the menu or the process is closing: an autosave on node removal
## is no longer needed. Without this flag the main menu received TWO autosave
## writes in a row — it writes one itself when loading a slot (`main_menu.gd:_on_load_slot`)
## and it rebuilds the hero only when starting a new game: the second write
## overwrote what the menu had just written with the old scene state.
func _set_leaving_scene(on: bool) -> void:
	_leaving_for_quit = on


## Rebuild the game from the saved state: the world goes into WorldBus,
## the map comes from the slot folder and is swapped into the live scene.
##
## change_scene_to_file does NOT fit here: a new Main._ready resets
## the party, and more importantly an orphaned coroutine of the old scene crashed on the very first
## frame of the new one (`data.tree is null`) and the entry point from the save was lost.
## Hot-swapping the map (_swap_map) preserves the hero and the party.
func _restart_scene(slot: String) -> void:
	# A paused tree does not create nodes: the save menu sets the pause.
	_menu_release_pause()
	_restore_world_from_slot(slot)
	_clear_party_nodes()
	if not is_instance_valid(player) or not is_instance_valid(alm_map):
		get_tree().change_scene_to_file("res://scenes/main.tscn")
		return
	# The slot could have been written by ANOTHER character (class/sex/race/portrait):
	# the Player node lives in this scene and is not rebuilt by itself, so
	# we re-read its class-dependent state before spawning the map units:
	# then even the city is built with the new hero's race.
	if player.has_method("reload_hero_state"):
		player.reload_hero_state()
	var map_path := SaveSystem.world_map_path(slot)
	if map_path == "":
		map_path = _zone_map_path(Game.map_zone, Game.map_seed)
	if map_path == "" or not FileAccess.file_exists(map_path):
		push_error("SaveSystem: карта слота '%s' не найдена" % slot)
		get_tree().change_scene_to_file("res://scenes/main.tscn")
		return
	await _swap_map(map_path, Game.map_zone, true, Game.map_sector)
	_apply_sector_fog(Game.map_sector)
	_restore_pending_party()
	# HUD after the hero swap: the magic book (warrior/mage have different panels),
	# gold and the visibility of the bottom panel.
	_refresh_ui_after_hero_swap()


## Refresh the HUD after loading a slot of another character. The panels (inventory,
## shop etc.) are created anew on every open and read Game.*,
## but the ones open at load time would show a hero of another class —
## we close them (the save menu already pauses the game anyway).
func _refresh_ui_after_hero_swap() -> void:
	if is_instance_valid(player):
		Game.hero = player
	# ui — an @onready-typed reference to the UI node.
	if not is_instance_valid(ui):
		return
	ui.close_all_panels()
	ui.rebind_map()
	ui.refresh_spell_book()
	ui._update_gold(int(player.gold) if is_instance_valid(player) else 0)
	ui._update_bottom_panel_visibility()
	ui.refresh_inventory()


## The world (SIM state) from the slot → WorldBus. The simulator holds a reference to the
## OLD WorldState, otherwise after loading it would keep ticking the
## previous world instead of the loaded one.
func _restore_world_from_slot(slot: String) -> void:
	var res := SaveSystem.load_slot(slot)
	var data: Dictionary = res.get("data", {})
	var world_text := JsonSafe.dump(data.get("world", {}))
	var ws_script: GDScript = load("res://scripts/world/world_state.gd")
	var restored = ws_script.from_json_text(world_text)
	var bus = get_node_or_null("/root/WorldBus")
	if bus == null or not ("state" in bus) or restored == null:
		return
	bus.state = restored
	if "sim" in bus and bus.sim != null and "state" in bus.sim:
		bus.sim.state = restored
	# An old save might not know about the undead/druid factions (28.10).
	if bus.state.has_method("ensure_race_factions"):
		bus.state.ensure_race_factions()
	if bus.has_method("reset_day_timer"):
		bus.call("reset_day_timer")


func _set_menu_status(text: String) -> void:
	if _save_menu != null and is_instance_valid(_save_menu):
		_save_menu.set_status(text)


## One-off autosave (portal, leaving an interior). The same slot as the timer.
func autosave_now() -> void:
	if Game.hero_dead:
		return
	if not is_instance_valid(player):
		return
	if _save_menu != null and is_instance_valid(_save_menu):
		return
	var err := SaveSystem.save(SaveSystem.AUTOSAVE_SLOT, _build_save_payload())
	if err != "":
		push_error("SaveSystem autosave: " + err)


## Timer autosave. Skipped if the save menu is open (otherwise
## the player presses "Save" and immediately gets an autosave on top).
func _autosave_tick(delta: float) -> void:
	if Game.hero_dead:
		return
	_autosave_accum += delta
	if _autosave_accum < autosave_interval():
		return
	_autosave_accum = 0.0
	if _save_menu != null and is_instance_valid(_save_menu):
		return
	if not is_instance_valid(player):
		return
	SaveSystem.save(SaveSystem.AUTOSAVE_SLOT, _build_save_payload())


## Save on window close and on quitting the game. Called from
## project.godot (autoload-free), so the subscription is made here.
## NOTIFICATION_PREDELETE is deliberately NOT used: that signal arrives
## on EVERY scene load and restart (_restart_scene), where the state already
## belongs to the new scene while the old player has already yielded it to the save.
## Skipped if the scene saved itself and is giving way to the menu
## (see _set_leaving_scene): otherwise the autosave would be written twice.
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_CLOSE_REQUEST:
		return
	if _leaving_for_quit or not is_inside_tree():
		return
	if Game.hero_dead:
		return
	if is_instance_valid(player):
		SaveSystem.save(SaveSystem.AUTOSAVE_SLOT, _build_save_payload())
