class_name UnitDB
## Unit database from assets/units/units_db.json (generated from units.txt).
## Provides move/attack/death phases, timings, size and anchor by unit set name
## ("heroes/swordsman", "monsters/orc", "humans/mage_st").

const DB_PATH := "res://assets/units/units_db.json"
const TICK := 0.05  # timing multiplier (in "tick" units from units.txt)

## Loot families in summary order (tests/package_a_smoke.gd). Data, not a
## constant: a mod with a new family (for example "demon") must appear in the summary.
static func loot_families() -> Array:
	return ContentRules.list("units.loot_families")

## Loot family of a set by SPECIES: a fallback when there is no explicit `loot_family`
## field in units_db.json (the field was added on 22.10 by tests/gen_gray_loot_family.py for all
## 50 `monsters/*` sets and takes priority — see loot_family_of). The species comes from
## the art: img2img copies `monsters/<species>_t<N>` (tests/gen_grey_tiers.py) carry exactly the
## same species as the source `monsters/<species>`. Without this binding an animal
## (`monsters/wolf...`) would land in the `default` financial table and drop
## ARMOR AND WEAPONS, while the player's decision on 07.10 was: beasts carry no gear.
## The key is taken only from the SPECIES segment (`monsters/bee_t3` -> `bee`), not from
## the whole name: the tier suffix is cut BEFORE matching, otherwise tiers 2..5 would not find themselves.
##
## 29.10: the table moved to data (`units.loot_by_species`) — a mod with a new
## beast can say up front what it drops.
static func loot_by_species() -> Dictionary:
	return ContentRules.dict("units.loot_by_species")

static var _db: Dictionary = {}
static var _loaded := false
static var _by_id := {}

static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var f := FileAccess.open(DB_PATH, FileAccess.READ)
	if f == null:
		push_error("UnitDB: не открыть " + DB_PATH)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		_db = parsed
	# Mods: new sets and stat patches — before the index, so ids land in _by_id.
	ModLoader.overlay("units", _db)
	# Index: unit ID (from units.txt) -> set name (for spawning NPCs from .alm)
	_by_id = {}
	for name in _db:
		var ids: Variant = _db[name].get("ids", null)
		if ids is Array:
			for uid in ids:
				_by_id[int(uid)] = name

## Set data by name ("heroes/swordsman") or {}.
static func get_set(name: String) -> Dictionary:
	ensure_loaded()
	return _db.get(name, {})

## Set name by unit ID (type_id from the .alm units section) or "".
static func set_name_for_id(unit_id: int) -> String:
	ensure_loaded()
	return str(_by_id.get(unit_id, ""))

## Set data by unit ID or {} (if the ID is unknown).
static func get_set_by_id(unit_id: int) -> Dictionary:
	return get_set(set_name_for_id(unit_id))

## Is the unit aggressive: monster sets with palette 5 (orcs, goblins, beasts)
## attack the player. Peaceful residents/animals (palette != 5) do not attack.
## Set hostility.
##
## Before, this checked `begins_with("monsters/")` AND `palette == 5`. After
## the Allods II art was removed, the `monsters/` family no longer exists (11.10), and
## hostile units will be Grey rigs with a completely different prefix. So
## the hostility sign is `palette == 5` ITSELF, not the folder name: it survives
## any family change. Today the behavior is the same (palette 5 was only on
## monsters), tomorrow the Grey rig gets palette 5 and becomes hostile by itself.
static func is_hostile(name: String) -> bool:
	return int(get_set(name).get("palette", 0)) == ContentRules.int_value("units.hostile_palette", 5)

## First frame of the set (for a static preview in the editor/palette).
static func preview_frame(name: String) -> Texture2D:
	var o := get_set(name)
	var folder := str(o.get("folder", name))
	var prefix := str(o.get("prefix", "sprites"))
	if prefix == "" or prefix == "null":
		prefix = "sprites"
	return load(frame_path(folder, prefix, 1))

## All set names with the given prefix ("humans/", "monsters/"), alphabetically.
static func all_names(prefix: String = "") -> Array:
	ensure_loaded()
	var out: Array = []
	for name in _db:
		if prefix == "" or str(name).begins_with(prefix):
			out.append(name)
	out.sort()
	return out

static func has(name: String) -> bool:
	ensure_loaded()
	return _db.has(name)

## Number of frames in the set (sprites-00N.png).
static func frame_count(name: String) -> int:
	return int(get_set(name).get("frames", 0))

## Path to a frame (1-based): res://assets/units/<folder>/<prefix>-NNN.png
## Some sets have a different file-name part (sprites | swordsman | ...).
## A `folder` like `mod://<id>/assets/...` resolves into the mod folder — so a mod can
## bring its own frame strip without copying it into res://.
static func frame_path(folder: String, prefix: String, frame: int) -> String:
	if ModLoader.is_mod_path(folder):
		return "%s/%s-%03d.png" % [ModLoader.resolve(folder), prefix, frame]
	return "res://assets/units/%s/%s-%03d.png" % [folder, prefix, frame]

## Frame prefix of the set ("sprites" | "swordsman" | ...) from the database.
static func frame_prefix(name: String) -> String:
	var o := get_set(name)
	var p := str(o.get("prefix", ""))
	if p != "" and p != "null":
		return p
	return "sprites"

## Phases (number of directions x phases in a block), with a fallback to defaults.
static func move_phases(name: String) -> int:
	return int(get_set(name).get("move", 8))

static func attack_phases(name: String) -> int:
	return int(get_set(name).get("attack", 4))

static func dying_phases(name: String) -> int:
	return int(get_set(name).get("dying", 4))

static func cast_phases(name: String) -> int:
	return int(get_set(name).get("cast", 0))

static func idle_phases(name: String) -> int:
	return int(get_set(name).get("idle_phases", 0))

static func decay_phases(name: String) -> int:
	return int(get_set(name).get("decay", 0))

## Number of directions drawn in the file (5 for the hero with mirrored right ones).
static func dirs(name: String) -> int:
	return int(get_set(name).get("dirs", 8))

## Timings (seconds) per block phase. Without a schedule — a uniform default.
static func block_times(name: String, key: String, phases: int) -> Array:
	var o := get_set(name)
	var raw: Variant = o.get(key, null)
	if raw is Array and not raw.is_empty():
		var out: Array = []
		for t in raw:
			out.append(float(t) * TICK)
		return out
	var def: Array = []
	for i in range(phases):
		def.append(0.15)
	return def

## Frame order in the block (phase numbers). If empty — 0..phases-1 in order.
static func block_frames(name: String, key: String, phases: int) -> Array:
	var o := get_set(name)
	var raw: Variant = o.get(key, null)
	if raw is Array and not raw.is_empty():
		return raw
	var seq: Array = []
	for i in range(phases):
		seq.append(i)
	return seq

# --- Fields moved from units.txt (full port) ---

## Unit selection hitbox [x1,y1,x2,y2] (for click/selection).
static func sel_box(name: String) -> Rect2i:
	var o := get_set(name)
	var raw: Variant = o.get("sel_box", null)
	if raw is Array and raw.size() == 4:
		return Rect2i(int(raw[0]), int(raw[1]), int(raw[2]) - int(raw[0]), int(raw[3]) - int(raw[1]))
	# default: almost the whole sprite
	return Rect2i(16, 16, 96, 96)

## Attack delay in ticks (from units.txt AttackDelay).
static func attack_delay(name: String) -> float:
	return float(get_set(name).get("attack_delay", 4)) * TICK

## Sprite palette number (0..7; monsters 5, skeletons 1-2, humans 0).
static func palette(name: String) -> int:
	return int(get_set(name).get("palette", 0))

## Unit portrait (name from units.txt InfoPicture).
static func info_picture(name: String) -> String:
	return str(get_set(name).get("info_picture", ""))

## Unit size in cells (1 = normal, 2 = troll/ogre/catapult, 3 = dragon).
static func tile_size(name: String) -> int:
	return int(get_set(name).get("tile_size", 1))

## Family for loot: beast | insect | humanoid | undead | monstrous.
## Empty = family unknown (enemy.gd uses the `default` table).
static func loot_family(name: String) -> String:
	return str(get_set(name).get("loot_family", ""))

## Loot table for the victim `name` (family key from loot_tables.json).
##
## Sources by priority: an explicit `loot_family` field in the database (written into all
## `monsters/*` by tests/gen_gray_loot_family.py), then the species from LOOT_BY_SPECIES
## (a safety net for new sets without the field). The tier suffix is cut before
## matching (`monsters/bee_t3` -> `bee`). City sets, heroes and an empty name -> "".
static func loot_family_of(name: String) -> String:
	var explicit := str(get_set(name).get("loot_family", ""))
	if explicit != "":
		return explicit
	if name.begins_with("city_") or not name.contains("/"):
		return ""
	var short := name.get_file()
	var tier_at := short.rfind("_t")
	if tier_at > 0 and short.substr(tier_at + 2).is_valid_int():
		short = short.substr(0, tier_at)
	return str(loot_by_species().get(short, ""))

## Set tier (1..5), 0 if there is no tier. Grey tiers are written by
## tests/gen_grey_tiers_db.py; tests/gray_tier_smoke compares the field with the `_tN`
## suffix in the set name. Broken item drops choose the metal BY TIER
## (enemy.gd:_broken_gear -> ItemDB.broken_materials), so the tier is read
## here, not parsed from the name string in every consumer.
static func tier(name: String) -> int:
	return int(get_set(name).get("tier", 0))

## Boss or dragon? Only they drop an INTACT item instead of a broken one.
## ([craft] boss_intact_chance).
##
## The `boss: 1` field was added on 07.10. Before it, the boss sign did not exist
## AT ALL, and a tempting candidate was tile_size (dragon 3, troll 2) — but that is
## the sprite size, not "boss": humans/catapult1 also has tile_size 2. Building
## on the unit size would have planted a mine that fires when a large
## regular mob appears.
static func is_boss(name: String) -> bool:
	return int(get_set(name).get("boss", 0)) != 0

## Whether to mirror the unit sprite (Flip=1 — trolls, dragon, flyers).
static func flip(name: String) -> bool:
	return int(get_set(name).get("flip", 0)) != 0

## Flight height in pixels (Z — bat/dragon/succubus hover above the ground).
static func fly_z(name: String) -> int:
	return int(get_set(name).get("z", 0))

## Bone animation phases after death (BonePhases — for undead).
static func bone_phases(name: String) -> int:
	return int(get_set(name).get("bone", 0))

## Ranged unit projectile type (-1 = does not shoot; 1.. = projectile from the project).
static func projectile(name: String) -> int:
	return int(get_set(name).get("projectile", -1))

## Shot delay (ShootDelay in ticks).
static func shoot_delay(name: String) -> float:
	return float(get_set(name).get("shoot_delay", 8)) * TICK

## Projectile launch point [x0,y0,x1,y1,...] — 8 pairs per direction.
static func shoot_offset(name: String) -> Array:
	var o := get_set(name)
	var raw: Variant = o.get("shoot_offset", null)
	if raw is Array:
		return raw
	return []

## Unit sounds [attack, ?, pain1, pain2, death] — sound_db.json keys
## (for example "voice.monster.wolf.attack"). An empty array = the unit is silent.
static func unit_sound(name: String) -> Array:
	var o := get_set(name)
	var raw: Variant = o.get("sound", null)
	if raw is Array:
		return raw
	return []

## Set resistance to an element (subtracted from magic damage). 0 = none.
## The table is filled by tests/gen_unit_resists.py in assets/units/units_db.json.
static func resist_of(name: String, sphere: String) -> int:
	var o := get_set(name)
	var r: Variant = o.get("resist", null)
	if r is Dictionary:
		return int((r as Dictionary).get(str(sphere).to_lower(), 0))
	return 0

func _unused() -> void:
	pass