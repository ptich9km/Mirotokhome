class_name MapGenerator
extends RefCounted
## Smart .alm generator based on the patterns of the original Nival maps
## (the corpus was removed on 29.10; the patterns are fixed in shapes_db/transition_db).
## Noise → terrain → transitions from transition_db → heights → roads → objects.
##
## Called from the game by seed: `MapGenerator.new().generate(seed, zone, dir)`.
## The CLI wrapper for batch generation is tests/gen_smart_map.gd.
##
## Randomness stream invariant: every stream = `seed + (old constant - BASE_SEED)`.
## The offsets are chosen so the grass and alchemy streams stay ISOLATED from
## the main stream — otherwise changing the herb count would shift the NPC and Grey layout.
## With seed == BASE_SEED the generator must produce the old gen_smart_01.alm byte for byte.

const DB_PATH := "res://assets/maps/transition_db.json"
const SHAPES_PATH := "res://assets/maps/shapes_db.json"
## Directory of generated maps in user:// — res:// is read-only in an exported game.
const MAPS_DIR := "user://maps/"
## Default map size. In stress mode ([stress] enabled=1)
## it is overridden by stress.map_size (player 07.10: 1000×1000).
var W := 192
var H := 192
## The seed the generator was called with before parameterisation appeared. It is the anchor for
## the stream offsets and the reference for the map identity regression check.
const BASE_SEED := 4242
## RNG stream offsets relative to the main one. IMPORTANT: this is the DIFFERENCE between the old
## constant and BASE_SEED, not the constant itself: stream_seed = seed + offset.
const STREAM_HERBS := 4400       ## 8642 - 4242
const STREAM_ALCHEMY := 3058     ## 7300 - 4242 (+ city_index)
const STREAM_OBJECTS := -3465    ## 777 - 4242 (_obj_noise.seed)
const STREAM_TERRAIN := -4200    ## 42 - 4242 (rng.seed and elev_noise.seed)
const STREAM_JITTER := 5757      ## 9999 - 4242 (jitter_noise.seed)
const STREAM_INTERIOR := -4235   ## 7 - 4242 (_interior_noise.seed)
const STREAM_INTERIOR_HI := -4143 ## 99 - 4242 (_interior_hi.seed)
const STREAM_POI := -3042        ## 1200 - 4242 (points of interest, 03.10)

## Where to write the result (set in generate()).
var _out_dir: String = ""
## Base file name without extension: <basename>.alm + sidecars with the same prefix.
var _basename: String = "gen_smart_01"
## The map name written INSIDE the .alm header (the name field, offset 68). Not to be confused
## with the file name: reproducing the old gen_smart_01.alm needs both = "gen_smart_01".
var _map_name: String = "gen_smart_01"
## Seed of the current generation.
var _seed: int = BASE_SEED
## Zone profile: start | mid | hard | faction.
var _zone: String = "mid"
## World 4x3 (23.10): sector id ("s41"), its neighbours (ids) and the relief.
var _sector: String = ""
var _neighbors: Array = []
var _relief: String = "plains"
var _portals_out: Array = []
## Background loading (23.10): progress for the loading screen, may be null.
var _job = null
## Statistics of the last generation for the F3 panel (ms per phase, source).
static var last_stats: Dictionary = {}
const STAT_PHASES := ["start", "terrain", "cities", "roads", "relief", "portals",
	"city", "objects", "herbs", "greys", "tiles", "heights", "save"]
var _stats_t0 := 0
var _stats_last := 0
var _stats_phases: Dictionary = {}
## Hero race passed explicitly (the stream must not depend on Game.hero_race).
var _race_hint: String = ""
## Type A -> tile file for .alm (sand/mud/soil — their own BMP files)
const TERRAIN_FILE := {0: 1, 1: 2, 2: 3, 3: 4, 4: 5, 5: 6, 6: 7}
## 8-bit peer mask bit order — must match tests/analyze_shapes.gd
const SHAPE_DIRS := [
	Vector2i(0, -1), Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1),
	Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(-1, -1),
]

var _tiles := PackedInt32Array()
var _heights := PackedByteArray()
var _obstacles := PackedByteArray()
var _terrain := PackedByteArray()
var _field := PackedFloat32Array()
var _water_thr: float = 0.0
var _mountain_thr: float = 0.0

# Spawn (structures/npc via sidecars): reserved cells and output records.
var _reserved := {}           # Vector2i -> true (buildings, spawn, portal)
var _structures_out: Array = []   # {x, y, type_id}
var _npcs_out: Array = []         # {x, y, set, role, patrol, post, hp_max, damage}
var _herbs_out: Array = []        # {x, y, item, icon}
var _gray_cells := {}             # "x,y" -> true, cells taken by Greys (03.10)
var _interest_out: Array = []     # {x, y, kind, label, members} — points-of-interest anchors
var _obj_noise: FastNoiseLite
var _clutter_noise: FastNoiseLite
## Cells with undergrowth: written to the .allowwalk.json sidecar, so a unit
## walks through a fern instead of going around it.
var _allowwalk_out: Array = []

# Transition DB
var _rules: Dictionary = {}
var _interior: Dictionary = {}
# Shape table: "type:maskstr" -> {tiles: [{file,variant,row,w}...], total}
var _shapes: Dictionary = {}
# Interior base textures per type: "0" -> {tiles: [{file,variant,row,w}...], total}
var _base_int: Dictionary = {}
# Universal "edge" row per type (the most frequent one among border masks).
var _edge_rows := {}
# Noise for the interior (per-cell, without hard worley chunks).
var _interior_noise: FastNoiseLite
var _interior_hi: FastNoiseLite
# Noise domain shift per type so the types do not copy each other.
const _NOISE_OFFSETS := {0: 1234, 1: 5678, 2: 9012, 3: 3456, 4: 7890, 5: 2345, 6: 6789}
var _stat_exact := 0
var _stat_subset := 0
var _stat_rules := 0
var _stat_transition := 0

## Transition direction order. Must match directions.order
## in assets/maps/terrain_tiles_db.json and gen_transition_tiles.py:
## file_n = 8 + index in this array.
const _TRANSITION_DIR_ORDER := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

## Base map file name: map_<seed>_<sector>[_<race>] for world sectors,
## map_<seed>_<zone>[_<race>] for old calls/tests.
static func map_basename(seed_value: int, zone: String, race: String = "",
		sector: String = "") -> String:
	var tail: String = ("_" + race) if race != "" else ""
	var tag: String = sector if sector != "" else zone
	return "map_%d_%s%s" % [seed_value, tag, tail]

## Generator version. Written into .npcs.json and checked on load.
##
## WHY. Measurement 03.10: Grey density was raised from 15 to 71 per map, but in game
## it stayed at 15. Reason: `ensure_map` reused an ALREADY GENERATED map
## from user://maps/, and its .npcs.json was dated 28.09 — that is, created before
## the settings change. The settings only affected new maps, and 58 old files
## lay in user://maps/.
##
## Now, on a version mismatch, the map regenerates itself. You change
## city_gap, the Grey density or the spacing rules — you bump GEN_VERSION.
## 05.10: v7 — one-way transition t < n (double shore).
## v8 — smoothing of orphaned 1×1/1×2 cells + blending of adjacent biomes.
## v9 — city buildings from the Alice art (structure_id 200..206).
## v10 — Alice 3×3 footprint (4×3 did not fit the oval, inn/house were not placed).
##
## v26 (15.10) — the Greys got real art: monsters/wolf, monsters/bee,
## monsters/dragon. Before that the pool held the stand-in monsters/hero_dummy (the
## hero art, so there was something to test combat on). The bump is mandatory: a sidecar of the old
## version lies on disk and `ensure_map` would return it as fresh.
##
## v25 (14.10) — history: the Grey pools temporarily held `monsters/hero_dummy`
## (hero art, palette=5) so combat could be tested before real monster art.
## Removed in v26; kept here because old sidecars still name that version.
##
## v24 (11.10) — EMPTY GREY POOLS. All Allods II art was removed, and with it
## 41 `monsters/*` sets were deleted. Without this bump already generated maps
## keep pointing at removed sets: the sidecar sits on disk and `ensure_map`
## would return it as fresh. Same class as any other meaningful bump here:
## the map cache silently outlives deleted data.
# 27: grey tiers - bands per zone, respawn reads the same band.
# 28: cannibal and troll added (9 species instead of 7). Without the bump old
# maps in user:// would be left without them.
# 29: succubus added (10 species). She has `attack: 0` - no attack phase by the
# player's decision, while damage is dealt like everyone else.
# 30: fog of war + terrain chunks (19.10).
# 31 (23.10): 4x3 world - a sector map with its own size (96..192) and portals
# on every border with a neighbour. Old maps without a sector stay compatible.
# 32 (28.10): faction outposts (package B) - 3 camps per map outside the start
# zone, .outposts.json sidecar and guards with tags.
# 33 (29.10): Allods art removed from the game - ids 1..179 dropped, outposts
# stand from our seedream buildings, a prop instead of the campfire. Without the
# bump old maps in user:// would point at removed folders (buildings would
# silently disappear).
# 34 (30.10): edge variation and interior texture choice are taken from our own
# `_cell_hash` instead of `hash(Vector2i)` - maps are the same in meaning but
# different in bytes; without the bump `ensure_map` would return old .alm files.
# 35 (09.11): alchemy rework - herbs are picked from the ZONE pool (tiers 1..4)
# instead of a flat round-robin over eight herbs, and tier 3..4 grow only in the
# wild (12 cells from a city). Positions do not move, only the item in the cell:
# without the bump every cached map would keep the old uniform herbs.
# 36 (13.11): undergrowth - mushrooms/ferns/dry scrub/aloe on cells the tree pass
# left free, passable via the new .allowwalk.json sidecar. Cached maps have no
# clutter and no sidecar; without the bump the poor biomes stay poor.
const GEN_VERSION := 36

## Path to the map by seed. If the map is already generated by the same generator version —
## we reuse it, otherwise we generate anew. An empty string on error.
##
## The presence of .npcs.json is checked not just "for tidiness": if the write was cut
## in the middle, .alm may exist while the sidecars do not, and the map would load
## without buildings, NPCs and herbs.
static func ensure_map(seed_value: int, zone: String = "mid", dir: String = MAPS_DIR,
		race: String = "", sector: String = "", size: int = 0,
		neighbors: Array = [], relief: String = "", job = null) -> String:
	# race empty -> take the hero race: city races depend on it (10.10).
	if race == "":
		race = _hero_faction()
	var base: String = map_basename(seed_value, zone, race, sector)
	var path: String = dir + base + ".alm"
	var npcs_path: String = dir + base + ".npcs.json"
	if FileAccess.file_exists(path) and FileAccess.file_exists(npcs_path):
		if _saved_gen_version(npcs_path) == GEN_VERSION:
			if job != null:
				job.set_progress(100, 12)
			last_stats = {
				"source": "cache", "total_ms": 0, "phases": {},
				"size": size, "sector": sector, "gen_version": GEN_VERSION,
			}
			return path
		print("MapGenerator: версия генератора изменилась (%d -> %d), карта %s перегенерируется"
				% [_saved_gen_version(npcs_path), GEN_VERSION, base])
	return MapGenerator.new().generate(seed_value, zone, dir, "", "", race,
		sector, size, neighbors, relief, job)


## Hero race -> faction id for the city. Empty if there is no CITY_POPULATION for it
## (a safeguard for the future: a race may appear in hero_race before its art).
static func _hero_faction() -> String:
	return city_race_for_hero(Game.hero_race)

## Version recorded in the sidecar (-1 = no file or the field is unreadable).
static func _saved_gen_version(npcs_path: String) -> int:
	var f := FileAccess.open(npcs_path, FileAccess.READ)
	if f == null:
		return -1
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		return -1
	return int((parsed as Dictionary).get("gen_version", -1))

## Generate a map by seed. Returns the path to .alm (an empty string on error).
## dir — a directory with a trailing slash (usually "user://maps/").
## basename_override — file name without extension; empty = "map_<seed>_<zone>".
## map_name_override — the map name inside the .alm header; empty = basename.
##   The overrides are needed by the identity regression test to reproduce
##   the old gen_smart_01.alm byte for byte (see BASE_SEED).
func generate(seed_value: int, zone: String = "mid", dir: String = "res://assets/maps/gen/",
		basename_override: String = "", map_name_override: String = "",
		race: String = "", sector: String = "", size: int = 0,
		neighbors: Array = [], relief: String = "", job = null) -> String:
	_seed = seed_value
	_zone = zone
	_sector = sector
	_neighbors = neighbors.duplicate()
	_relief = relief if relief != "" else "plains"
	_race_hint = race
	_job = job
	_stats_t0 = Time.get_ticks_msec()
	_stats_last = _stats_t0
	_stats_phases = {}
	_report(1, 0)
	_out_dir = dir
	_basename = basename_override
	if _basename == "":
		_basename = map_basename(_seed, _zone, race, _sector)
	_map_name = map_name_override
	if _map_name == "":
		_map_name = _basename
	_apply_stress_overrides()
	if size > 0 and GameConfig.geti("stress", "enabled") == 0:
		W = clampi(size, 64, 2000)
		H = W
	_load_db()
	_generate()
	_save()
	last_stats = {
		"source": "generated", "total_ms": Time.get_ticks_msec() - _stats_t0,
		"phases": _stats_phases.duplicate(), "size": W, "sector": _sector,
		"gen_version": GEN_VERSION,
	}
	return _out_dir + _basename + ".alm"


## Engine stress mode: map size and content counters from [stress].
## In a normal game enabled=0 — the behaviour does not change.
func _apply_stress_overrides() -> void:
	var enabled := GameConfig.geti("stress", "enabled") != 0
	if not enabled:
		W = 192
		H = 192
		return
	var size := GameConfig.geti("stress", "map_size")
	W = clampi(size, 64, 2000)
	H = W
	print("STRESS: карта %dx%d, деревья=%d, Серые=%d, стражи=%d, жители=%d" % [
		W, H,
		GameConfig.geti("stress", "tree_count"),
		GameConfig.geti("stress", "gray_count"),
		GameConfig.geti("stress", "city_guard_count"),
		GameConfig.geti("stress", "city_citizen_count"),
	])

func _load_db() -> void:
	var f := FileAccess.open(DB_PATH, FileAccess.READ)
	if f == null:
		return
	var json: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if json is Dictionary:
		_rules = json.get("rules", {})
		_interior = json.get("interior", {})
	print("DB: %d rules, %d interior" % [_rules.size(), _interior.size()])
	var sf := FileAccess.open(SHAPES_PATH, FileAccess.READ)
	if sf != null:
		var sjson: Variant = JSON.parse_string(sf.get_as_text())
		sf.close()
		if sjson is Dictionary:
			_shapes = sjson.get("shapes", {})
			_base_int = sjson.get("interior", {})
	print("SHAPES: %d entries, base textures for %d types" % [_shapes.size(), _base_int.size()])
	_compute_edge_rows()

## "Edge" row per type: the most frequent row among shapes with >=1 cardinal
## bit (N/E/S/W) and >= MIN_CELLS cells. For grass/mountains this is the "universal
## edge" (row 4 in the pvm map analysis), for water/road — their own edge rows.
func _compute_edge_rows() -> void:
	const MIN_CELLS := 20
	var cardinal_bits := 0x55  # bits N, E, S, W (0,2,4,6)
	var rows_by_type := {}  # t -> {row: total_weight}
	for key in _shapes:
		var parts: Array = String(key).split(":")
		if parts.size() < 2:
			continue
		var t: int = int(parts[0])
		if t < 0 or t > 6:
			continue
		var mask := _mask_from_str(parts[1])
		if mask == 0 or mask & cardinal_bits == 0:
			continue
		var entry: Dictionary = _shapes[key]
		var total: int = int(entry.get("total", 0))
		if total < MIN_CELLS:
			continue
		for ti in entry.get("tiles", []):
			var r: int = int(ti.get("row", -1))
			var w: int = int(ti.get("w", 0))
			if r < 0:
				continue
			if not rows_by_type.has(t):
				rows_by_type[t] = {}
			rows_by_type[t][r] = int(rows_by_type[t].get(r, 0)) + w
	_edge_rows.clear()
	for t in rows_by_type:
		var best_row := -1
		var best_w := 0
		for r in rows_by_type[t]:
			if int(rows_by_type[t][r]) > best_w:
				best_w = int(rows_by_type[t][r])
				best_row = int(r)
		if best_row >= 0:
			_edge_rows[t] = best_row
	print("EDGE_ROWS: %s" % str(_edge_rows))

func _get_rule(type_a: int, dir: String, type_b: int) -> Dictionary:
	# Try with sub numbers first (NW1, NW2, N1, N2 etc)
	for sub in ["1", "2"]:
		var key: String = "%d:%s%s:%d" % [type_a, dir, sub, type_b]
		var spec: Dictionary = _rules.get(key, {})
		if not spec.is_empty():
			return spec
	# Fallback to base direction
	return _rules.get("%d:%s:%d" % [type_a, dir, type_b], {})

# === Generation ===

## Progress for the loading screen. job may be null (tests, dev).
func _report(percent: int, phase: int) -> void:
	var now := Time.get_ticks_msec()
	_stats_phases[str(phase)] = now - _stats_last
	_stats_last = now
	if _job != null:
		_job.set_progress(percent, phase)


func _generate() -> void:
	var n: int = W * H
	_terrain.resize(n)
	_tiles.resize(n)
	_heights.resize(n)
	_obstacles.resize(n)
	_obstacles.fill(0)
	_reserved.clear()
	_structures_out.clear()
	_npcs_out.clear()
	_herbs_out.clear()
	_outposts_out.clear()
	_outpost_reach.clear()
	_allowwalk_out.clear()

	# 1. Voronoi soil (the base, without mountains/water/road)
	_place_terrain(n)
	_report(12, 1)

	var rng := rng_from_seed(_seed)

	# 2. Cities: ovals ~11×11 of road (type 3), by the zone profile
	_place_cities(rng)
	_report(28, 2)

	# 3. Roads: MST over the cities + width-2 A* corridors
	_connect_cities(rng)
	_report(42, 3)

	# 4. Mountains/water over the terrain extremes, without overwriting the road (3)
	_place_mountains_water()
	# 4b. Remove "orphaned" 1×1 / 1×2 cells of a foreign biome inside the field.
	_smooth_isolated_terrain()
	_report(50, 4)

	# 5. Portal + Spawn markers (at city #0)
	_place_portal_spawn()
	_report(56, 5)

	# 6. City content: buildings + city NPCs (after spawn/portal are known)
	_place_city_content(rng)
	_report(66, 6)

	# 6b. Small decor around the cities (seedream barrels/boxes/lamps)
	_place_city_props(rng)

	# 6c. Faction outposts (package B): 3 camps outside the cities, in the starting zone 0.
	# Their own RNG stream — trees/herbs/Greys do not shift when camps appear.
	_place_outposts(rng_from_seed(_seed + STREAM_OUTPOSTS))

	# 7. Trees/objects (fill _obstacles, going around cities/roads/spawn)
	_place_objects(rng)
	_report(78, 7)

	# 7b. Undergrowth: mushrooms/ferns/dry scrub/aloe on free cells. A separate
	# pass with its own noise, because putting a mushroom into the tree pool
	# would trade a tree for it and thin the forest. These cells stay WALKABLE:
	# a fern is decor, not a wall.
	_place_clutter(rng)

	# 8. Herbs: separate collectible nodes, not obstacles
	_place_herbs(rng_from_seed(_seed + STREAM_HERBS))
	_report(84, 8)

	# 9. Greys: clusters near roads and in the forest (only on unoccupied cells)
	_place_greys(rng)
	_report(90, 9)

	# 9b. Points of interest outside the cities: static NPC groups. Disabled by
	# default (poi.count = 0), the player enables them.
	# A separate RNG stream so that enabling points of interest does NOT shift
	# trees, herbs and Greys — otherwise an old map would change entirely.
	_place_interest_points(rng_from_seed(_seed + STREAM_POI))

	# 10. Tiles with transitions from DB
	for y in range(H):
		for x in range(W):
			var i: int = y * W + x
			_tiles[i] = _pick_tile(_terrain[i], x, y)
	_report(96, 10)

	# 11. Heights: non-road first, then road interpolation from the completed field
	for y in range(H):
		for x in range(W):
			var i: int = y * W + x
			if _terrain[i] != 3:
				_heights[i] = _pick_height(x, y, _terrain[i], _field[i])
	_smooth_nonroad_heights()
	for y in range(H):
		for x in range(W):
			var i: int = y * W + x
			if _terrain[i] == 3:
				_heights[i] = _pick_height(x, y, _terrain[i], _field[i])
	_report(99, 11)

func rng_from_seed(s: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = s
	return r

# === Zone profiles: the number of cities by difficulty ===
# The zone profile is set by the generate() parameter in the _zone field (start | mid | hard | faction).
const ZONE_CITY_COUNTS := {
	"start": [1, 1],
	"mid": [1, 3],
	"hard": [4, 5],
	"faction": [2, 3],
}

# City geometry.
# CITY_RADIUS — half the road oval: 8 gives a 17×17 oval (it was 7 -> 15×15,
# and houses on 4-6 cells did not fit into the ring, buildings were pushed outside).
# CITY_GAP — free cells around every building (it was 1, houses stuck together).
const CITY_RADIUS := 8
const CITY_GAP := 2

## City radius and gap — from config [spawn]. The constants above remain
## a fallback value and an override for tests that substitute their own.
static func city_radius() -> int:
	var v := GameConfig.geti("spawn", "city_radius")
	return CITY_RADIUS if v <= 0 else v

static func city_gap() -> int:
	var v := GameConfig.geti("spawn", "city_gap")
	return CITY_GAP if v <= 0 else v

static func herb_region_grid() -> int:
	var v := GameConfig.geti("spawn", "herb_region_grid")
	return HERB_REGION_GRID if v <= 0 else v

static func herb_min_distance() -> int:
	var v := GameConfig.geti("spawn", "herb_min_distance")
	return HERB_MIN_DISTANCE if v <= 0 else v

## Building protrusion upwards for EVERY footprint being checked (full_height − h).
## Passed into _footprint_fits through a field: GDScript does not allow passing it
## as an argument without polluting the signature of every caller.
var _pending_vis_rows: int = 0

# Greys (palette=5 monsters — UnitDB.is_hostile) by zone: clusters near roads and in forests.
#
# THE POOLS ARE EMPTY — and this is NOT a bug but a consequence of the player's decision on 11.10: all
# Allods II art was removed from the repository, and with it the 41 `monsters/*` sets.
# Substituting city guards (`city_*`) instead is not allowed: those are peaceful
# NPCs, and such a substitution would silently lie that monsters exist.
#
# WHAT WILL HAPPEN when Grey rigs appear: a rig set is wired in the same
# way as any other — by a record in units_db.json and a folder
# assets/units/rig/<set>/. The lists below expect ordinary set keys, the spawn
# code will not need changes, only these paths have to be filled in.
const GRAY_POOL_EMPTY: Array = []

# 15.10: real Grey art. Made with the same pipeline as the hero
# (tests/gen_monster_strip.py + tests/extract_monster_nb.py), model
# google/gemini-nano-banana-2.1 — it is the only one that keeps the same animal
# between calls. seedream-5-0-flash is three times cheaper ($0.018 vs $0.059), but
# in the control run the idle and the run came out as DIFFERENT beasts.
#
# monsters/succubus is NOT included: the `move` and `die` strips were not generated
# in time, the Gemini quota ran out two calls earlier. The set will appear as soon as
# we finish those two strips.
const GRAY_POOL_TEST: Array = [
	"monsters/wolf", "monsters/dino", "monsters/squirrel",
	"monsters/bee", "monsters/bat", "monsters/ghost", "monsters/dragon",
]

# Grey tiers. Every species has 5 sets: tier 1 is the beast itself, without a
# recolour (`monsters/<species>`); tiers 2..5 are recoloured copies
# `monsters/<species>_t<N>`. The recolour is free (zero API calls), the
# generator is tests/gen_grey_tiers.py.
#
# 2026-10-30: the species list moved to data (`spawn.gray_species`) — a mod can
# add its own beast and it starts to appear in the world. Missing sets (for
# example a mod with tier 1 only) are filtered out: the pool must never offer a
# spawn of a set that does not exist.
static func gray_species() -> Array:
	return ContentRules.list("spawn.gray_species")

# Tier band by zone (player's decision): the deeper you go, the more dangerous the species.
#  start   1-2  a beginner meets no elites
#  mid     2-3  ordinary hunting, the first ancients
#  hard    3-4  dangerous, legendary
#  faction 4-5  elites and lords
const GRAY_TIER_BAND := {
	"start": [1, 2],
	"mid": [2, 3],
	"hard": [3, 4],
	"faction": [4, 5],
}

# Boost per tier on top of the Grey base stats ([grey] in game.cfg).
# Tier 1 — x1.0, tier 5 — hp x2.4, damage x2.0. The steps live in [mob_tier], so
# balance is tuned in one place, not in the code. The tier comes from units_db.json,
# not parsed from the name: the name is a string, the database is the source of truth.
static func gray_tier_mults(set_name: String) -> Array:
	var tier := int(UnitDB.get_set(set_name).get("tier", 1))
	var step := float(maxi(tier - 1, 0))
	return [1.0 + GameConfig.getf("mob_tier", "hp_step") * step,
		1.0 + GameConfig.getf("mob_tier", "damage_step") * step]


static func gray_set_name(species: String, tier: int) -> String:
	return "monsters/%s" % species if tier <= 1 else "monsters/%s_t%d" % [species, tier]


## The zone's set pool: all species × the tiers of its band.
static func gray_pool_for_zone(zone: String) -> Array:
	var band: Array = GRAY_TIER_BAND.get(zone, GRAY_TIER_BAND["mid"])
	var out: Array = []
	for sp in gray_species():
		for t in range(int(band[0]), int(band[1]) + 1):
			var set_name := gray_set_name(str(sp), t)
			if UnitDB.has(set_name):
				out.append(set_name)
	return out


# City buildings: functional + housing + decor (folder -> StructureDB).
# 10.10: seedream art (tests/extract_seedream_buildings.py), folders *_sN.
# The old Alice folders (shop3/inn4/...) remained on disk but are not used in the pools.
const SHOP_FOLDERS := ["shop_s1"]
const ALCHEMY_FOLDERS := ["druidshop_s1"]
const INN_FOLDERS := ["inn_s1", "inn_s2"]
const TRAIN_FOLDERS := ["train_s1"]
const BLACKSMITH_FOLDERS := ["blacksmith_s1"]

## Housing and decor by city race (keys = faction id in world.json).
## Every race has its own building style - an orc city does not look human.
## 29.10: moved into data (`map.house_folders` / `map.decor_folders`) —
## a mod with a new building set or a new faction needs no code changes.
static func house_folders() -> Dictionary:
	return ContentRules.dict("map.house_folders")


static func decor_folders() -> Dictionary:
	return ContentRules.dict("map.decor_folders")

## Small map decor (seedream, alm_objects.json ID 193-199).
## Placed around the cities: barrels/boxes/sacks by the buildings, lamps along the roads.
## The list is in data (`map.city_props`); lamp 197 is placed separately along the roads.
const LANTERN_PROP_ID := 197

## Zones where the generator places a portal.
##
## 03.10: it was only ["start"], and the player decided to add "mid" — without that
## the exit from the beginner zone leads nowhere and there is exactly one zone.
## IMPORTANT: `_drop_portal_json()` is called for the zones from this list and wipes
## the old sidecar. If you add a zone to the list and forget to remove the call, the
## generator will erase the portal it has just placed.
const ZONES_WITH_PORTAL := ["start", "mid"]

# City NPCs.
## City race -> sprite sets. Keys = faction ids in assets/lore/world.json
## (label/race/archmage live there too). Tier = role: citizens t0/t1, guards t1/t2,
## captain-great-mage t3.
## Every race has two sets (mage + warrior) - deliberately: a city should have
## both ordinary residents and those who bear arms, not 16 copies of one silhouette.
## 10.10 (later): the undead also got an atlas (city_necro_mage/city_necro_warrior),
## so necro is now a full city instead of a fallback to the first available race.
const CITY_POPULATION := {
	"humans": {
		"guards": ["city_human_mage/t1", "city_human_warrior/t2"],
		"citizens": ["city_human_mage/t0", "city_human_warrior/t1"],
		"captain": "city_human_mage/t3",
		"head": "city_human_head/t0",
	},
	"ork": {
		"guards": ["city_ork_mage/t1", "city_ork_warrior/t2"],
		"citizens": ["city_ork_mage/t0", "city_ork_warrior/t1"],
		"captain": "city_ork_mage/t3",
		"head": "city_ork_head/t0",
	},
	"druid": {
		"guards": ["city_druid_mage/t1", "city_druid_warrior/t2"],
		"citizens": ["city_druid_mage/t0", "city_druid_warrior/t1"],
		"captain": "city_druid_mage/t3",
		"head": "city_druid_head/t0",
	},
	"necro": {
		"guards": ["city_necro_mage/t1", "city_necro_warrior/t2"],
		"citizens": ["city_necro_mage/t0", "city_necro_warrior/t1"],
		"captain": "city_necro_mage/t3",
		"head": "city_necro_head/t0",
	},
}
## Races that cities are dealt to in a circle. necro is excluded while there is no
## art (see CITY_POPULATION). The starting zone gets the first race, not "hero":
## with "hero" there would be no NPC at all in the beginner city.
const CITY_RACES := ["humans", "ork", "druid", "necro"]

# Objects by biome: seedream sprites (alm_objects.json ID 200-211).
# The old Allods IDs 1-192 were removed from the pools (the folders were deleted from disk).
const TREE_GRASS := [200, 201, 202, 205, 210, 211]   # oak, oak2, pine, bush_berry, rock, rock2
const TREE_SOIL := [203, 204, 205, 210, 211]         # birch, willow, bush_berry, rock, rock2
const TREE_SAND := [206, 207, 210]                   # palm, cactus, rock
const TREE_MUD := [208, 209, 204, 210]               # dead, thorn, willow, rock
# Undergrowth (13.11): small props placed by their own rarer pass, so the
# forests keep their density. IDs 212-215 from alm_objects.json.
const CLUTTER_GRASS := [212, 213]                    # mushroom cluster, fern
const CLUTTER_SOIL := [212, 213]                     # mushroom cluster, fern
const CLUTTER_SAND := [214, 215]                     # dry bush, aloe
const CLUTTER_MUD := [212, 213, 214]                 # mushroom, fern, dry bush
const CLUTTER_CHANCE := 0.16                         # per free cell, after the noise gate
const HERB_TARGET_COUNTS := {"start": 70, "mid": 90, "hard": 110, "faction": 100}
const HERB_REGION_GRID := 4
const HERB_MIN_DISTANCE := 4
## Herb tiers and zone pools live in HerbDB (assets/professions/herbalism/
## herbs_db.json): the alchemy panel needs the same table, and a second copy in
## code drifted the moment recipes started caring about tiers.
## Herbs of `wild_tier_min` and above grow only this far (cells) from a city
## centre - the rare ingredients are found in the dangerous wild, not by the inn.

## Grey spacing across the map (03.10). GRAY_MIN_DISTANCE — the minimum
## distance between any two Greys, otherwise clusters bunch up in a corner.
## GRAY_REGION_GRID — how many parts we split the map into for the coverage report.
const GRAY_MIN_DISTANCE := 4
const GRAY_REGION_GRID := 3
const GRAY_MIN_SPAWN_DISTANCE := 14   # do not poke a beast right into a beginner's face

## Thematic encounters (package D, 07.10): hive, lair, pack — as in Allods.
##
## THE LIST IS EMPTY, like the GRAY_ZONE pools: all `monsters/*` sets were removed with
## the Allods II art (11.10). The placement logic and the encounter kinds themselves are untouched —
## they will come alive as soon as Grey rigs appear, and for that it is enough to put
## the records back here. Until then no pack is placed, and this is visible in the generator
## report (`gray_count=0`), not as a crash.
##
## What will come back here (set -> encounter kind):
##   bee  -> bee_hive       wolf  -> wolf_pack     spider -> spider_den
##   squirrel -> squirrel_herd  orc/goblin -> orc_camp
##   ogre -> ogre_lair      troll -> troll_lair    bat    -> bat_swarm
const ENCOUNTER_KINDS: Array = []

## --- Faction outposts (package B of the forging rework, 28.10) -------------------
##
## The player's decision: THREE capturable outposts per map; in the starting zone
## there are no faction warriors at all (only Greys there). An outpost is a small
## camp outside the city: the race's tent, a campfire and 3-6 guards with tags in their loot.
##
## Why their own RNG stream like herbs/POI: adding outposts must not
## shift trees, herbs and Greys — otherwise every old map would change
## entirely. STREAM_OUTPOSTS occupies its own range.
const STREAM_OUTPOSTS := -2718
const OUTPOST_FACTIONS: Array = ["humans", "ork", "necro", "druid"]
## Camp tent/house by race. All names must exist in structure_db.json
## (the generator checks it, otherwise the camp would be left without a building).
## 28.10: the Allods tent/vigvam/necro/druidhouse were removed with ids 1..179 —
## the camps stand from our seedream buildings (the same folders as housing/decor).
const OUTPOST_CAMPS := {
	"humans": ["barracks_s1", "barracks_s2"],
	"ork": ["ork_house_b1", "ork_house_b2"],
	"necro": ["necro_house_b1", "necro_house_b2"],
	"druid": ["druid_house_b1", "druid_house_b2"],
}
## Outpost names for the world journal and capture. Separate from the race: the player sees
## "Horde outpost", not "ork".
const OUTPOST_NAMES := {
	"humans": "Форпост Альянса",
	"ork": "Форпост Орды",
	"necro": "Форпост Пожинателей",
	"druid": "Форпост Круга",
}
const OUTPOST_PROP_ID := 193  ## a barrel by the tent: the camp centre without the Allods campfire
const OUTPOST_MIN_CITY_DISTANCE := 20
const OUTPOST_MIN_SPAWN_DISTANCE := 16
const OUTPOST_MIN_EACH_OTHER := 20
## Camp radius in cells: tent + campfire + guard posts.
const OUTPOST_RADIUS := 4

var _outposts_out: Array = []  # {id, faction, name, x, y, guards}
## Cells reachable from spawn at the moment the camps are placed: a camp in
## a pocket behind the mountains would be unreachable for the player, hence dead content.
var _outpost_reach: Dictionary = {}

var _spawn_pos: Vector2i = Vector2i(-1, -1)
var _portal_pos: Vector2i = Vector2i(-1, -1)
var _cities: Array = []  # [{pos: Vector2i, faction: String}]

## Stage 2: cities. Centres — on base land, spaced apart (min. distance),
## filled with an ~11×11 oval of road (type 3). The count comes from the zone profile.
func _place_cities(rng: RandomNumberGenerator) -> void:
	_cities.clear()
	var range_arr: Array = ZONE_CITY_COUNTS.get(_zone, [1, 3])
	var count: int = rng.randi_range(int(range_arr[0]), int(range_arr[1]))
	var min_city_dist := 20
	var attempts := 0
	while _cities.size() < count and attempts < 500:
		attempts += 1
		var cx: int = rng.randi_range(8, W - 9)
		var cy: int = rng.randi_range(8, H - 9)
		var p := Vector2i(cx, cy)
		# The city centre — only on base land (0/4/5/6), not on water/mountains/road
		var t: int = _terrain[p.y * W + p.x]
		if t == 1 or t == 2 or t == 3:
			continue
		# Spacing: no closer than min_city_dist to already placed cities
		var far_enough := true
		for c in _cities:
			if p.distance_to(c["pos"]) < min_city_dist:
				far_enough = false
				break
		if not far_enough:
			continue
		_cities.append({"pos": p, "faction": _faction_for(_cities.size())})
		_fill_city_oval(p, city_radius(), city_radius())
	print("CITIES: %d/%d (zone=%s)" % [_cities.size(), count, _zone])

## City race (id from CITY_POPULATION / world.json).
##
## 10.10: the FIRST city is the hero's race. Before that the races went in a circle over CITY_RACES from
## zero, that is the first city was always humans, and as an orc/druid the hero ended up
## in a foreign city (player report: "for everyone except humans the NPCs do not match
## the race"). The other cities go in a circle starting from the hero's race, so the order
## stays the same but is rotated around the axis.
##
## necro was excluded while there was no undead atlas. With the art arriving (10.10,
## later) every hero race gives its own city, without a fallback.
func _faction_for(i: int) -> String:
	var order := _race_order()
	if order.is_empty():
		return ""
	return str(order[i % order.size()])


## City races in order of appearance: the hero's race first, then the others.
func _race_order() -> Array:
	var out: Array = []
	var hero := _race_hint if _race_hint != "" else city_race_for_hero(Game.hero_race)
	if hero != "":
		out.append(hero)
	for r in CITY_RACES:
		if not out.has(r):
			out.append(r)
	return out

## A filled oval of road (type 3), diameter (2*rx+1)×(2*ry+1).
func _fill_city_oval(center: Vector2i, rx: int, ry: int) -> void:
	for dy in range(-ry, ry + 1):
		for dx in range(-rx, rx + 1):
			var fx: float = float(dx) / float(rx)
			var fy: float = float(dy) / float(ry)
			if fx * fx + fy * fy > 1.0:
				continue
			var x: int = center.x + dx
			var y: int = center.y + dy
			if x < 1 or y < 1 or x >= W - 1 or y >= H - 1:
				continue
			_terrain[y * W + x] = 3

## Stage 3: roads — an MST over the cities (Prim, nearest neighbour) + width-2 A* corridors.
func _connect_cities(rng: RandomNumberGenerator) -> void:
	if _cities.size() < 2:
		return
	var in_tree := {}
	in_tree[0] = true
	var connected: Array = [0]
	while connected.size() < _cities.size():
		var best_i := -1
		var best_j := -1
		var best_d := 1 << 30
		for i in connected:
			for j in range(_cities.size()):
				if in_tree.has(j):
					continue
				var d: int = _cities[i]["pos"].distance_squared_to(_cities[j]["pos"])
				if d < best_d:
					best_d = d
					best_i = i
					best_j = j
		if best_j < 0:
			break
		_carve_road_between(_cities[best_i]["pos"], _cities[best_j]["pos"], rng)
		in_tree[best_j] = true
		connected.append(best_j)

## A* between two points + a width-2 ribbon (perpendicular to the segment).
func _carve_road_between(a: Vector2i, b: Vector2i, rng: RandomNumberGenerator) -> void:
	var path: Array = _a_star(a, b, rng)
	if path.is_empty():
		path = _a_star(b, a, rng)
	if path.is_empty():
		return
	for i in range(path.size()):
		var p: Vector2i = path[i]
		# Direction of the segment for the perpendicular width-2 stripe
		var seg := Vector2i(0, 0)
		if i + 1 < path.size():
			seg = Vector2i(path[i + 1]) - p
		elif i > 0:
			seg = p - Vector2i(path[i - 1])
		var lane := Vector2i(-seg.y, seg.x) if seg != Vector2i.ZERO else Vector2i(1, 0)
		if lane.x + lane.y < 0:
			lane = -lane
		_set_land_road(p)
		_set_land_road(p + lane)

## Stage 4: mountains/water by the terrain extremes. We never touch the road (3):
## cities and the road network stay walkable — "mountains/water protect the roads".
func _place_mountains_water() -> void:
	for y in range(H):
		for x in range(W):
			var i: int = y * W + x
			if _terrain[i] == 3:
				continue
			var elev: float = _field[i]
			if elev < _water_thr:
				_terrain[i] = 2
			elif elev > _mountain_thr:
				_terrain[i] = 1

## Remove isolated 1×1 / 1×2 blocks of a foreign biome inside the array.
## A cell changes type if among its 8 neighbours there is a type with count >= 5 and its own
## (the same type as itself) <= 2. The edge of a large lake/mountain is not touched
## (there its own neighbours are >= 3). The road (3) is not overwritten.
func _smooth_isolated_terrain() -> void:
	var changed := 0
	for _pass in range(2):
		var marks := {}
		for y in range(1, H - 1):
			for x in range(1, W - 1):
				var i: int = y * W + x
				var t: int = _terrain[i]
				if t == 3:
					continue
				var own := 0
				var counts := {}
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						if dx == 0 and dy == 0:
							continue
						var nt: int = _terrain[(y + dy) * W + (x + dx)]
						if nt == t:
							own += 1
						elif nt >= 0:
							counts[nt] = int(counts.get(nt, 0)) + 1
				if own > 2:
					continue
				var best_t := -1
				var best_c := 0
				for nt in counts:
					if int(counts[nt]) > best_c:
						best_c = int(counts[nt])
						best_t = int(nt)
				if best_t >= 0 and best_c >= 5 and best_t != 3:
					marks[i] = best_t
		for i in marks:
			_terrain[i] = int(marks[i])
			changed += 1
	if changed > 0:
		print("SMOOTH: сглажено осиротевших клеток: %d" % changed)

## Stage 5: spawn near the first city, portal on the opposite edge.
##
## Spawn is seed-dependent (via _find_land_near): a hard centre of the map broke
## gen_seeds_smoke, which requires the sidecars to differ for different
## seeds. The behaviour change is a deliberate rollback of e28fc374.
func _place_portal_spawn() -> void:
	if _cities.is_empty():
		return
	var city0: Vector2i = _cities[0]["pos"]
	_spawn_pos = _find_land_near(city0, 8)
	_save_spawn_json()
	_reserved[_spawn_pos] = true
	if _sector != "" and not _neighbors.is_empty():
		# World 4x3: one portal per border with a neighbour on the side.
		_place_sector_portals(city0)
	elif _zone in ZONES_WITH_PORTAL:
		# Old mode (maps outside the sector world): one portal far away.
		_portal_pos = _find_land_far(city0, 40)
		_save_portal_json()
		_reserved[_portal_pos] = true
	else:
		# Delete a possible old sidecar: the map could have been generated before
		# the portal became zonal, and alm_map.gd reads .portal.json if the
		# file exists. Without this deletion, a zone without a portal would still show
		# a marker from the old generation.
		_drop_portal_json()
	if _spawn_pos.x >= 0:
		print("SPAWN: (%d, %d)" % [_spawn_pos.x, _spawn_pos.y])
	if _portals_out.size() > 0:
		var parts: Array = []
		for p in _portals_out:
			parts.append("%s->%s (%d,%d)" % [p["dir"], p["to"], int(p["x"]), int(p["y"])])
		print("PORTALS: " + ", ".join(parts))
	elif _portal_pos.x >= 0:
		print("PORTAL: (%d, %d)" % [_portal_pos.x, _portal_pos.y])
	else:
		print("PORTAL: нет (zone=%s)" % _zone)


## Portal on the sector border matching the direction to the neighbour.
## The cell must be walkable and reachable from the first city — otherwise
## the player sees a marker they cannot reach.
func _place_sector_portals(city0: Vector2i) -> void:
	_portals_out.clear()
	_portal_pos = Vector2i(-1, -1)
	var wm = load("res://scripts/world/world_map.gd")
	# The walkable area is computed ONCE: before, BFS was run for every
	# cell of the border band, and moving into a 192x192 sector took tens of
	# seconds (measurement 23.10: world_map_smoke 142 s).
	var reach := _reachable_cells(city0)
	for raw_n in _neighbors:
		var nid := str(raw_n)
		var dir := str(wm.dir_of(_sector, nid))
		if dir == "":
			continue
		var cell := _find_edge_land(dir, city0, reach)
		if cell.x < 0:
			push_warning("MapGenerator: нет проходимой клетки у границы %s сектора %s" % [dir, _sector])
			continue
		_portals_out.append({
			"x": cell.x, "y": cell.y, "dir": dir, "to": nid,
		})
		_reserved[cell] = true
	_save_portals_json()


## A cell near the map edge in the direction dir, as far as possible from cities and already
## placed portals, reachable on foot from city0.
func _find_edge_land(dir: String, city0: Vector2i, reach: Dictionary) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_score := -1
	var xs: Array = []
	var ys: Array = []
	match dir:
		"N":
			ys = range(4, mini(14, H - 4))
			xs = range(4, W - 4)
		"S":
			ys = range(maxi(4, H - 14), H - 4)
			xs = range(4, W - 4)
		"W":
			xs = range(4, mini(14, W - 4))
			ys = range(4, H - 4)
		"E":
			xs = range(maxi(4, W - 14), W - 4)
			ys = range(4, H - 4)
		_:
			return best
	for y in ys:
		for x in xs:
			var p := Vector2i(x, y)
			var idx: int = y * W + x
			if not _walkable_terrain(int(_terrain[idx])):
				continue
			if _reserved.has(p):
				continue
			if not reach.has(p):
				continue
			var dcity := 1 << 20
			for c in _cities:
				dcity = mini(dcity, p.distance_squared_to(c["pos"]))
			var dport := 1 << 20
			for pp in _portals_out:
				dport = mini(dport, p.distance_squared_to(Vector2i(int(pp["x"]), int(pp["y"]))))
			if dcity < 12 * 12 or dport < 10 * 10:
				continue
			var edge := mini(mini(x, W - 1 - x), mini(y, H - 1 - y))
			var score := int(sqrt(float(dcity)) * 3.0 + sqrt(float(dport)) * 2.0 - float(edge))
			if score > best_score:
				best_score = score
				best = p
	return best


func _walkable_terrain(t: int) -> bool:
	return t == 0 or t == 3 or t == 4 or t == 5 or t == 6


## All cells reachable on foot from start (water 2 and mountains 1 are impassable).
func _reachable_cells(start: Vector2i) -> Dictionary:
	var out := {}
	if start.x < 0 or start.y < 0:
		return out
	out[start] = true
	var queue: Array = [start]
	while not queue.is_empty():
		var p: Vector2i = queue.pop_front()
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var q: Vector2i = p + d
			if q.x < 1 or q.y < 1 or q.x >= W - 1 or q.y >= H - 1:
				continue
			if out.has(q):
				continue
			if not _walkable_terrain(int(_terrain[q.y * W + q.x])):
				continue
			out[q] = true
			queue.append(q)
	return out


# === Spawn: city buildings + NPCs, trees, Greys ===

## The nearest base land (0 grass, 4 soil, 5 sand, 6 mud) next to origin.
func _find_land_near(origin: Vector2i, radius: int) -> Vector2i:
	for r in range(1, radius + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if abs(dx) != r and abs(dy) != r:
					continue
				var p := Vector2i(origin.x + dx, origin.y + dy)
				if p.x >= 1 and p.y >= 1 and p.x < W - 1 and p.y < H - 1:
					var t: int = _terrain[p.y * W + p.x]
					if t == 0 or t == 4 or t == 5 or t == 6:
						return p
	return Vector2i(-1, -1)

## Base land far from origin, closer to the map edge.
func _find_land_far(origin: Vector2i, min_dist: int) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_score := -1
	for y in range(3, H - 3):
		for x in range(3, W - 3):
			var t: int = _terrain[y * W + x]
			if t != 0 and t != 4 and t != 5 and t != 6:
				continue
			var p := Vector2i(x, y)
			var dist: float = p.distance_to(origin)
			if dist < min_dist:
				continue
			# Score: farther from origin + closer to the map edge
			var edge_dist: float = mini(mini(x, W - 1 - x), mini(y, H - 1 - y))
			var score: int = int(dist * 2.0 - edge_dist * 3.0)
			if score > best_score:
				best_score = score
				best = p
	return best

# === Spawn: city buildings + NPCs, trees, Greys ===

## Building spec by folder: {id, w, h, fh} from structure_db.json or {}.
## `fh` (full_height) is the full SPRITE height, while `h` (tile_height) is only the
## footprint. The difference goes UPWARD from the footprint (roof, tower, sign).
## Before, `fh` was not returned here, which is why vis_rows was always 0: the building
## protrusion was not reserved, and houses visually ran into each other.
## We deliberately do NOT use `sel` from the database: in structure_db.json it is
## self-contradictory (kaarginn3 has [12, 82, 0, 82], x0 > x1), taking the
## footprint from it would mean guessing.
func _structure_spec(folder: String) -> Dictionary:
	if not StructureDB.has(folder):
		return {}
	var def := StructureDB.get_structure(folder)
	var tid := int(def.get("id", 0))
	if tid <= 0:
		return {}
	var tile_h := int(def.get("tile_height", 1))
	return {
		"id": tid,
		"w": int(def.get("tile_width", 1)),
		"h": tile_h,
		"fh": maxi(tile_h, int(def.get("full_height", tile_h))),
	}

## Stage 6: buildings + NPCs for every city. Written into the structures/npcs sidecars.
func _place_city_content(rng: RandomNumberGenerator) -> void:
	for city_index in range(_cities.size()):
		var c: Dictionary = _cities[city_index]
		var center: Vector2i = c["pos"]
		var alchemy_rng := rng_from_seed(_seed + STREAM_ALCHEMY + city_index)
		var alchemy_folder: String = str(_pick(alchemy_rng, ALCHEMY_FOLDERS))
		var plan: Array = [
			_pick(rng, TRAIN_FOLDERS),
			alchemy_folder,
			_pick(rng, BLACKSMITH_FOLDERS),
			_pick(rng, SHOP_FOLDERS),
			_pick(rng, INN_FOLDERS),
		]
		# One dwelling per city - by the player's decision (we are not a city simulator).
		# The race of the house/decor = the race of the city: an orc city builds orc housing.
		var race := str(c.get("faction", "humans"))
		var house_pool: Array = house_folders().get(race, house_folders().get("humans", []))
		var decor_pool: Array = decor_folders().get(race, decor_folders().get("humans", []))
		plan.append(_pick(rng, house_pool))
		plan.append(_pick(rng, decor_pool))
		for folder in plan:
			var spec := _structure_spec(folder)
			if spec.is_empty():
				continue
			_place_city_building(center, spec)
		_place_city_npcs(rng, center, race, city_id_of(city_index))
	print("STRUCTURES_COUNT: %d" % _structures_out.size())

## 6b. Small decor around the cities: barrels/boxes/sacks/lamps (seedream).
## Decor - on grass/soil inside the oval, not right by the buildings.
## Lamps (197) - ONLY on grass adjacent to the road (a lamp post
## at the pavement), with a distance >= 3 cells between lamps so they do not bunch
## into a clump in the middle of the square.
func _place_city_props(rng: RandomNumberGenerator) -> void:
	# The prop pool comes from data (`map.city_props`); the lamp is placed by a separate
	# branch along the road, so it is excluded from the common pool.
	var prop_pool: Array = []
	for p in ContentRules.list("map.city_props"):
		if int(p) != LANTERN_PROP_ID:
			prop_pool.append(int(p))
	if prop_pool.is_empty():
		prop_pool = [193]
	var placed := 0
	var lantern_cells: Array[Vector2i] = []
	for c in _cities:
		var center: Vector2i = c["pos"]
		var cr := city_radius()  # oval +1 cell of "pavement" outside
		var want := rng.randi_range(5, 8)
		var tries := 0
		var got := 0
		while got < want and tries < want * 24:
			tries += 1
			var r := rng.randi_range(2, cr + 1)
			var dx := rng.randi_range(-r, r)
			var dy := rng.randi_range(-r, r)
			if cr > 0:
				var fx := float(dx) / float(cr + 1)
				var fy := float(dy) / float(cr + 1)
				if fx * fx + fy * fy > 1.0:
					continue
			var cell := center + Vector2i(dx, dy)
			if cell.x < 1 or cell.y < 1 or cell.x >= W - 1 or cell.y >= H - 1:
				continue
			var idx := cell.y * W + cell.x
			var t := _terrain[idx]
			# decor only on land off the road: grass/soil
			if t != 0 and t != 4:
				continue
			if _obstacles[idx] != 0 or _reserved.has(cell):
				continue
			# do not climb onto the building overhang
			var touch_bldg := false
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
					Vector2i(1, 1), Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1)]:
				if _reserved.has(cell + d):
					touch_bldg = true
					break
			if touch_bldg:
				continue
			var near_rd := _near_road(cell)
			var prop_id: int
			if near_rd:
				# a lamp by the pavement, but not more often than 1 per 3 cells
				var too_close := false
				for lc in lantern_cells:
					if maxi(abs(lc.x - cell.x), abs(lc.y - cell.y)) < 3:
						too_close = true
						break
				if too_close or rng.randf() > 0.45:
					continue
				prop_id = 197
				lantern_cells.append(cell)
			else:
				prop_id = int(_pick(rng, prop_pool))
			_obstacles[idx] = prop_id
			got += 1
			placed += 1
	print("CITY_PROPS: %d (ламп=%d)" % [placed, lantern_cells.size()])

## Place a building (spec) into the ring around the city centre, not on the square.
## The ring was widened to CITY_RADIUS (it was 7) for the 17×17 oval, and the check
## is passed the upward protrusion (fh - h) so buildings do not run into each other.
func _place_city_building(center: Vector2i, spec: Dictionary) -> bool:
	var w := int(spec["w"])
	var h := int(spec["h"])
	var full_h: int = int(spec.get("fh", h))
	var vis_rows: int = maxi(0, full_h - h)  # the visual protrusion of the building above the footprint
	_pending_vis_rows = vis_rows
	for r in range(2, city_radius() + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if abs(dx) != r and abs(dy) != r:
					continue
				var tl := center + Vector2i(dx, dy)
				if not _footprint_fits(tl, w, h, center):
					continue
				_structures_out.append({"x": tl.x, "y": tl.y, "type_id": int(spec["id"])})
				# Reserve the footprint
				for yy in range(h):
					for xx in range(w):
						_reserved[tl + Vector2i(xx, yy)] = true
				# Reserve the visual protrusion upwards (so NPCs do not stand on the roof)
				for vy in range(vis_rows):
					for xx in range(w):
						_reserved[tl + Vector2i(xx, -vy - 1)] = true
				return true
	return false

## The building footprint fits inside the city oval on the road, not on the square,
## without crossing spawn/portal/already occupied cells and leaving a gap.
## A CITY_GAP cell gap on each side (it was 1 — houses stood flush and
## visually stuck together). Both the footprint itself and the upward protrusion of fh - h
## rows are checked: otherwise the roof of one house landed on the neighbour's roof.
func _footprint_fits(tl: Vector2i, w: int, h: int, center: Vector2i) -> bool:
	for yy in range(h):
		for xx in range(w):
			var c := tl + Vector2i(xx, yy)
			if c.x < 1 or c.y < 1 or c.x >= W - 1 or c.y >= H - 1:
				return false
			if _terrain[c.y * W + c.x] != 3:
				return false
	var vis_rows := _pending_vis_rows
	# The gap comes from [spawn] city_gap. Before, a hardcoded 1 stood here, although
	# the CITY_GAP constant and the comment promised 2 — that is, the player's decision
	# of 26.09 ("gap 1 -> 2") was not applied in the code, and city_layout_smoke
	# adapted to the fact (`gap >= CITY_GAP - 1`).
	for yy in range(-city_gap() - vis_rows, h + city_gap()):
		for xx in range(-city_gap(), w + city_gap()):
			var c := tl + Vector2i(xx, yy)
			if c.x < 1 or c.y < 1 or c.x >= W - 1 or c.y >= H - 1:
				return false
			if _reserved.has(c) or c == _spawn_pos or c == _portal_pos:
				return false
			# The ring around the building, CITY_GAP wide, is free of other buildings.
			var d := maxi(abs(c.x - center.x), abs(c.y - center.y))
			if d <= 1 or d > city_radius():
				return false
	return true

## City NPCs: guards (the first 2 patrol, the rest stand at posts — at the edges
## of the city, see _guard_post_cell), the captain, the city head, residents by the square.
## All stand; the patrol is only the first 2 guards.
##
## The head (22.10) — a separate NPC with the role "head": they have quests and a "!" marker
## (scripts/quest_marker.gd). Stands by the square next to the captain, but on the ring
## of residents — in a crowd the captain and the head must not blend together.
func _place_city_npcs(rng: RandomNumberGenerator, center: Vector2i,
		race: String, city_id: String) -> void:
	var pop: Dictionary = CITY_POPULATION.get(race, {})
	if pop.is_empty():
		push_error("MapGenerator: нет CITY_POPULATION для расы '%s' - город останется без NPC" % race)
		return
	var posts_taken := {}
	var guard_rings: Array = [
		Vector2i(city_radius(), city_radius() - 1),
		Vector2i(city_radius() - 1, city_radius()),
	]
	var citizens_offsets: Array = [
		Vector2i(3, 0), Vector2i(-3, 0), Vector2i(0, 3), Vector2i(0, -3),
		Vector2i(3, 3), Vector2i(-3, 3), Vector2i(3, -3), Vector2i(-3, -3),
		Vector2i(4, 0), Vector2i(-4, 0), Vector2i(0, 4), Vector2i(0, -4),
		Vector2i(5, 0), Vector2i(-5, 0), Vector2i(0, 5), Vector2i(0, -5),
		Vector2i(5, 3), Vector2i(-5, 3), Vector2i(5, -3), Vector2i(-5, -3),
		Vector2i(3, 5), Vector2i(-3, 5), Vector2i(3, -5), Vector2i(-3, -5),
	]
	var guards_n := rng.randi_range(
		GameConfig.geti("city", "guard_count_min"), GameConfig.geti("city", "guard_count_max"))
	if GameConfig.geti("stress", "enabled") != 0:
		guards_n = GameConfig.geti("stress", "city_guard_count")
	for i in range(guards_n):
		var post := _guard_post_cell(center, guard_rings, i, guards_n, posts_taken)
		if post.x < 0:
			continue
		var set_name: String = _pick(rng, pop["guards"])
		# City guards are the same in every zone ([city]); zone danger is the
		# Grey tier band, not a per-zone guard stat.
		var hp := rng.randi_range(
			GameConfig.geti("city", "guard_hp_min"), GameConfig.geti("city", "guard_hp_max"))
		var dmg := rng.randi_range(
			GameConfig.geti("city", "guard_damage_min"), GameConfig.geti("city", "guard_damage_max"))
		_npcs_out.append(_npc_rec(post, set_name, "guard", i < 2, hp, dmg, city_id, center))
	# The captain by the square — they are also the city's GREAT MAGE (player decision 07.10),
	# and a mage of THEIR OWN race (09.10): an orc city must not have a druid mage.
	var cap := _post_cell(center, [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)], posts_taken)
	if cap.x >= 0:
		var cap_rec := _npc_rec(cap, str(pop["captain"]), "guard", false,
			GameConfig.geti("city", "captain_hp"), GameConfig.geti("city", "captain_damage"),
			city_id)
		# The captain keeps the square, the edge rule is about the ordinary guards.
		cap_rec.erase("city_x")
		cap_rec.erase("city_y")
		cap_rec["archmage"] = true
		_npcs_out.append(cap_rec)
	# The city head — a quest giver. Stands by the square, a set of their own race.
	var head_set := str(pop.get("head", pop["citizens"][0]))
	var head := _post_cell(center, [Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)], posts_taken)
	if head.x >= 0:
		var head_rec := _npc_rec(head, head_set, "head", false,
			GameConfig.geti("city", "citizen_hp"), 0, city_id)
		head_rec["head"] = true
		_npcs_out.append(head_rec)
	# Residents (standing, not patrolling) — rings 3-4
	var cit_n := rng.randi_range(
		GameConfig.geti("city", "citizen_count_min"), GameConfig.geti("city", "citizen_count_max"))
	if GameConfig.geti("stress", "enabled") != 0:
		cit_n = GameConfig.geti("stress", "city_citizen_count")
	for i in range(cit_n):
		var post := _post_cell(center, citizens_offsets, posts_taken)
		if post.x < 0:
			continue
		var set_name: String = _pick(rng, pop["citizens"])
		_npcs_out.append(_npc_rec(post, set_name, "citizen", false,
			GameConfig.geti("city", "citizen_hp"), 0, city_id, center))

## city id for quests: "c<index>t<race-in-the-list>". The index is the order of the
## city in the generator; the t0.. suffix repeats the race from CITY_RACES.
## For cities from a military .alm (without the generator) the indices are given by AlmMap.
func _city_race(city_index: int) -> String:
	var order := _race_order()
	if order.is_empty():
		return ""
	return str(order[city_index % order.size()])


static func city_id_of(city_index: int) -> String:
	return "c%dt%d" % [city_index, city_index % maxi(1, CITY_RACES.size())]

## Race by set name: "city_human_mage/t1" -> "humans", "city_ork_warrior/t0"
## -> "ork", "city_druid_mage/t2" -> "druid", "city_human_head/t0" -> "humans".
## The sets are named by the root without the trailing "s" (human, not humans) and
## with a role suffix (_mage/_warrior/_head), so the comparison goes by the root
## rather than by concatenation. Empty if the set is not ours.
static func race_of_set(set_name: String) -> String:
	if not set_name.begins_with("city_"):
		return ""
	var seg := set_name.trim_prefix("city_").get_slice("/", 0)
	for suffix in ["_head", "_mage", "_warrior"]:
		seg = seg.trim_suffix(suffix)
	# Segment = race id from world.json. IMPORTANT: for orcs this is "ork", not
	# "orc" — on 10.10 ["orc", "ork"] stood here, and because of that the city orc mage
	# returned "" (the faction label "Passer-by", the city race test failed).
	# The test was green at the same time because it checked ITS OWN copy of the parsing
	# rather than this function.
	for race in CITY_RACES:
		if seg == race or seg + "s" == race:
			return race
	return ""


## Hero race -> faction id (human -> humans). An unknown race gives "" —
## the calling code must account for that instead of silently getting the first in the list.
static func race_of_hero(hero_race: String) -> String:
	match hero_race:
		"human": return "humans"
		"ork": return "ork"
		"druid": return "druid"
		# 10.10 (later): it was "" — the undead had no atlas, and a city for the undead
		# fell back to the first available race. Now the atlas exists.
		"necro": return "necro"
		_: return ""


## The hero's faction id, but only if there is CITY_POPULATION for it.
## The check stays meaningful: it guards against a race without art if one is
## added to hero_race before a sprite set appears.
static func city_race_for_hero(hero_race: String) -> String:
	var race := race_of_hero(hero_race)
	if race != "" and CITY_POPULATION.has(race):
		return race
	return ""


## A free post: a road cell in the city, not on the square, not occupied.
func _post_cell(center: Vector2i, offsets: Array, taken: Dictionary) -> Vector2i:
	for off in offsets:
		var c: Vector2i = center + off
		if c.x < 1 or c.y < 1 or c.x >= W - 1 or c.y >= H - 1:
			continue
		if _terrain[c.y * W + c.x] != 3:
			continue
		if _reserved.has(c) or taken.has(c):
			continue
		if c == _spawn_pos or c == _portal_pos:
			continue
		taken[c] = true
		return c
	return Vector2i(-1, -1)

## A guard post on the OUTER ring of the city. The guards stand at the edge (the player's
## decision 22.10: there were too many in the centre and they got underfoot),
## while the square is left to the captain, the head and the residents. Candidates are cells
## of the inner and outer ring of the oval in circular traversal order with an offset,
## evenly around the perimeter; the first taken is the one nearest to an exit (the N/S/E/W axes).
func _guard_post_cell(center: Vector2i, rings: Array, index: int, total: int,
		taken: Dictionary) -> Vector2i:
	var cands: Array[Vector2i] = []
	for ring in rings:
		var rx := int((ring as Vector2i).x)
		var ry := int((ring as Vector2i).y)
		for dy in range(-ry, ry + 1):
			for dx in range(-rx, rx + 1):
				var fx := float(dx) / float(maxi(1, rx))
				var fy := float(dy) / float(maxi(1, ry))
				if fx * fx + fy * fy > 1.0:
					continue
				if absi(dx) < rx - 1 and absi(dy) < ry - 1:
					continue
				var c := center + Vector2i(dx, dy)
				if cands.has(c):
					continue
				cands.append(c)
	if cands.is_empty():
		return _post_cell(center, [Vector2i(2, 0), Vector2i(-2, 0)], taken)
	var step := maxi(1, cands.size() / maxi(1, total))
	for i in range(cands.size()):
		var c: Vector2i = cands[(index * step + i) % cands.size()]
		if _guard_post_free(c, center, taken):
			taken[c] = true
			return c
	for c2 in cands:
		var cc: Vector2i = c2
		if _guard_post_free(cc, center, taken):
			taken[cc] = true
			return cc
	return Vector2i(-1, -1)


## A cell is suitable for a guard post: a city road, free of buildings/decor,
## not spawn and not portal, not taken by another NPC and not on the square.
func _guard_post_free(c: Vector2i, center: Vector2i, taken: Dictionary) -> bool:
	if c.x < 1 or c.y < 1 or c.x >= W - 1 or c.y >= H - 1:
		return false
	if _terrain[c.y * W + c.x] != 3:
		return false
	if _reserved.has(c) or taken.has(c):
		return false
	if c == _spawn_pos or c == _portal_pos:
		return false
	return maxi(absi(c.x - center.x), absi(c.y - center.y)) > 2


func _npc_rec(post: Vector2i, set_name: String, role: String, patrol: bool,
		hp: int, dmg: int, city_id: String = "",
		center: Vector2i = Vector2i(-1, -1)) -> Dictionary:
	var rec := {
		"x": post.x, "y": post.y, "set": set_name,
		"role": role, "patrol": patrol,
		"post": [post.x, post.y],
		"hp_max": hp, "damage": dmg,
		"city_id": city_id,
	}
	if center.x >= 0 and center.y >= 0:
		# Town centre: lets the town tests place the guards by distance to it.
		rec["city_x"] = center.x
		rec["city_y"] = center.y
	return rec

## Stage 8: points of interest OUTSIDE the cities.
##
## What this is and why. The player's decision (03.10): "scale by zones + points
## of interest, without wandering NPCs". That is, the world outside the cities must not be
## empty (right now only Greys and trees are there), but the player does not want
## wandering NPCs that cannot be found anywhere. So a point of interest is a small
## STATIC group of NPCs in one place: they stand, do not patrol, do not meddle
## in any business.
##
## Why NOT their own sidecar. The first thought was to introduce .interest.json and
## a new loader in alm_map.gd. Deliberately rejected: a point of interest is
## simply an NPC, and NPCs already know how to load from .npcs.json. A new file +
## a new load path + new spawn code = three times more places to make a
## mistake, for a feature that is off by default. So POI are written as
## ordinary records in .npcs.json with an added "poi" field.
##
## Off by default: poi.count = 0 ([poi]).
## Until the player raises the number, the game behaves as before.
const POI_KINDS := [
	# The Allods humans/* were removed (07.10). While there is little art — the points are off
	# (poi.count=0). We will bring them back under ork_mage when there are enough tiers.
]

## Minimum POI distances (cells). Separate from herbs: a point of interest
## must be visible from afar, a herb — must not.
const POI_MIN_CITY_DISTANCE := 18     # far from the city (player's decision 03.10)
const POI_MIN_SPAWN_DISTANCE := 14    # no closer than spawn/portal
const POI_MIN_EACH_OTHER := 16         # spaced out among themselves


func _place_interest_points(rng: RandomNumberGenerator) -> void:
	var target := GameConfig.geti("poi", "count")
	if target <= 0:
		print("POI: выключено (poi.count=0)")
		return
	var placed := 0
	var tries := 0
	while placed < target and tries < 600:
		tries += 1
		var anchor := Vector2i(rng.randi_range(3, W - 4), rng.randi_range(3, H - 4))
		if not _poi_cell_ok(anchor):
			continue
		var kind: Dictionary = POI_KINDS[rng.randi() % POI_KINDS.size()]
		# a small group around the anchor: 2-3 NPCs standing next to each other
		var members := rng.randi_range(2, 3)
		var hp := GameConfig.geti("poi", "hp")
		var dmg := GameConfig.geti("poi", "damage")
		var taken := 0
		for i in range(members):
			var spot := anchor + Vector2i(rng.randi_range(-2, 2), rng.randi_range(-2, 2))
			if not _poi_spot_ok(spot):
				continue
			var set_name: String = str(kind["sets"][i % (kind["sets"] as Array).size()])
			var rec := _npc_rec(spot, set_name, "guard", false, hp, dmg)
			rec["poi"] = str(kind["kind"])
			rec["poi_label"] = str(kind["label"])
			_npcs_out.append(rec)
			taken += 1
		if taken > 0:
			_interest_out.append({
				"x": anchor.x, "y": anchor.y,
				"kind": str(kind["kind"]), "label": str(kind["label"]),
				"members": taken,
			})
			placed += 1
	print("POI: %d/%d kind=%s" % [placed, target,
		", ".join(POI_KINDS.map(func(k: Dictionary) -> String: return str(k["kind"])))])


## Point-of-interest anchor: land, not in a city, not by spawn/portal, not on the road,
## not taken by an object. Like _herb_cell_ok, but with different distances.
func _poi_cell_ok(cell: Vector2i) -> bool:
	if cell.x < 3 or cell.y < 3 or cell.x >= W - 3 or cell.y >= H - 3:
		return false
	var terrain := _terrain[cell.y * W + cell.x]
	if terrain != 0 and terrain != 4:      # grass or soil; water/mountains/sand/mud — no
		return false
	if _obstacles[cell.y * W + cell.x] != 0:
		return false
	if _reserved.has(cell) or _near_road(cell):
		return false
	if _near_city(cell, POI_MIN_CITY_DISTANCE):
		return false
	if _near_point(cell, _spawn_pos, POI_MIN_SPAWN_DISTANCE):
		return false
	if _near_point(cell, _portal_pos, POI_MIN_SPAWN_DISTANCE):
		return false
	for record in _interest_out:
		var dx := absi(cell.x - int(record.get("x", -1)))
		var dy := absi(cell.y - int(record.get("y", -1)))
		if dx < POI_MIN_EACH_OTHER and dy < POI_MIN_EACH_OTHER:
			return false
	return true


func _poi_spot_ok(cell: Vector2i) -> bool:
	if cell.x < 2 or cell.y < 2 or cell.x >= W - 2 or cell.y >= H - 2:
		return false
	if _obstacles[cell.y * W + cell.x] != 0 or _reserved.has(cell):
		return false
	for record in _npcs_out:
		if int(record.get("x", -1)) == cell.x and int(record.get("y", -1)) == cell.y:
			return false
	return true


# --- Faction outposts (package B of the forging rework) --------------------------

## Stage 6c: outposts. Placed AFTER the cities/decor and BEFORE the trees: the camp
## reserves cells, and the forest/herbs/Greys go around it by themselves.
##
## The starting zone is deliberately empty (player's decision 28.10): "in the starting one there are
## no faction warriors at all, only Greys". So there are 0 outposts there, and this is
## not a generator bug but a rule.
func _place_outposts(rng: RandomNumberGenerator) -> void:
	_outposts_out.clear()
	var target := GameConfig.geti("outpost", "per_map")
	if _zone == "start":
		target = 0
	if target <= 0:
		print("OUTPOSTS: 0 (зона %s)" % _zone)
		return
	# Factions do not repeat while there are enough of them: three camps of the same race
	# on one map would read as one camp multiplied by copy-paste.
	var factions: Array = OUTPOST_FACTIONS.duplicate()
	_shuffle(rng, factions)
	# Reachability from spawn: a pocket behind the mountains must not eat the camp.
	_outpost_reach = _reachable_cells(_spawn_pos)
	var placed := 0
	var tries := 0
	while placed < target and tries < 500:
		tries += 1
		var anchor := Vector2i(rng.randi_range(3, W - 4), rng.randi_range(3, H - 4))
		if not _outpost_cell_ok(anchor):
			continue
		var faction := str(factions[placed % factions.size()])
		if _build_outpost(placed, faction, anchor, rng):
			placed += 1
	var names: Array = []
	for o in _outposts_out:
		names.append(str((o as Dictionary)["faction"]))
	print("OUTPOSTS: %d/%d (%s)" % [placed, target, ", ".join(names)])


## Camp anchor: land off the road, not by a city/spawn/portal and not near
## another camp. Terrain — any walkable (grass/soil/sand/mud).
func _outpost_cell_ok(cell: Vector2i) -> bool:
	if cell.x < OUTPOST_RADIUS + 2 or cell.y < OUTPOST_RADIUS + 2 \
			or cell.x >= W - OUTPOST_RADIUS - 2 or cell.y >= H - OUTPOST_RADIUS - 2:
		return false
	if not _outpost_terrain_ok(cell):
		return false
	if _obstacles[cell.y * W + cell.x] != 0 or _reserved.has(cell):
		return false
	if not _outpost_reach.is_empty() and not _outpost_reach.has(cell):
		return false
	if _near_road(cell) or _near_city(cell, OUTPOST_MIN_CITY_DISTANCE):
		return false
	if _near_point(cell, _spawn_pos, OUTPOST_MIN_SPAWN_DISTANCE):
		return false
	if _near_point(cell, _portal_pos, OUTPOST_MIN_SPAWN_DISTANCE):
		return false
	for o in _outposts_out:
		var d: Dictionary = o
		if absi(cell.x - int(d["x"])) < OUTPOST_MIN_EACH_OTHER \
				and absi(cell.y - int(d["y"])) < OUTPOST_MIN_EACH_OTHER:
			return false
	return true


## A walkable biome for the camp. Mountains/water will not do: the tent would stand in a lake.
func _outpost_terrain_ok(cell: Vector2i) -> bool:
	if cell.x < 0 or cell.y < 0 or cell.x >= W or cell.y >= H:
		return false
	var t := _terrain[cell.y * W + cell.x]
	return t == 0 or t == 4 or t == 5 or t == 6


## Build one camp. false — no room was found for the tent (the anchor is dropped).
func _build_outpost(index: int, faction: String, anchor: Vector2i,
		rng: RandomNumberGenerator) -> bool:
	var camps: Array = OUTPOST_CAMPS.get(faction, [])
	if camps.is_empty():
		return false
	var spec := _structure_spec(str(_pick(rng, camps)))
	if spec.is_empty():
		push_error("MapGenerator: нет постройки лагеря для '%s'" % faction)
		return false
	var camp_cell := _place_camp_building(anchor, spec)
	if camp_cell.x < 0:
		return false
	# Camp marker: a prop by the tent (a barrel), not the Allods campfire.
	# The prop lives in the obstacle field, like the small city decor (`_place_city_props`),
	# and does not take the structure footprint.
	var prop_cell := _free_camp_cell(anchor, {}, 1)
	if prop_cell.x >= 0:
		_obstacles[prop_cell.y * W + prop_cell.x] = OUTPOST_PROP_ID
		_reserved[prop_cell] = true
	# Guards: the zone tier sets both the set and the strength (as with the city guards).
	var tier := _outpost_tier()
	var token := "human" if faction == "humans" else faction
	var count := GameConfig.geti("outpost", "guards_min") \
		+ rng.randi_range(0, maxi(0, GameConfig.geti("outpost", "guards_max")
			- GameConfig.geti("outpost", "guards_min")))
	var hp := rng.randi_range(GameConfig.geti("city", "guard_hp_min"),
		GameConfig.geti("city", "guard_hp_max"))
	var dmg := rng.randi_range(GameConfig.geti("city", "guard_damage_min"),
		GameConfig.geti("city", "guard_damage_max"))
	var oid := "op%d" % index
	var taken := {}
	for i in range(count):
		var slot := anchor + Vector2i(rng.randi_range(-2, 2), rng.randi_range(-2, 2))
		var spot := _free_camp_cell(slot, taken, 2)
		if spot.x < 0:
			continue
		taken[spot] = true
		_reserved[spot] = true
		var role := "mage" if i == 1 and count >= 3 else "warrior"
		var set_name := "city_%s_%s/t%d" % [token, role, tier]
		if not UnitDB.has(set_name):
			set_name = "city_%s_warrior/t%d" % [token, tier]
		if not UnitDB.has(set_name):
			continue
		var rec := _npc_rec(spot, set_name, "guard", false, hp, dmg)
		rec["faction"] = faction
		rec["outpost"] = oid
		_npcs_out.append(rec)
	_outposts_out.append({
		"id": oid,
		"faction": faction,
		"name": str(OUTPOST_NAMES.get(faction, "Форпост")),
		"x": anchor.x, "y": anchor.y,
	})
	return true


## Place the camp tent: a free footprint within the camp radius. Unlike a
## city, no road is needed — the camp stands on the ground.
func _place_camp_building(anchor: Vector2i, spec: Dictionary) -> Vector2i:
	var w := int(spec["w"])
	var h := int(spec["h"])
	var vis_rows: int = maxi(0, int(spec.get("fh", h)) - h)
	for r in range(0, OUTPOST_RADIUS):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if r > 0 and abs(dx) != r and abs(dy) != r:
					continue
				var tl := anchor + Vector2i(dx, dy) - Vector2i(w >> 1, h - 1)
				if not _camp_footprint_fits(tl, w, h, anchor, vis_rows):
					continue
				_structures_out.append({"x": tl.x, "y": tl.y, "type_id": int(spec["id"])})
				for yy in range(h):
					for xx in range(w):
						_reserved[tl + Vector2i(xx, yy)] = true
				for vy in range(vis_rows):
					for xx in range(w):
						_reserved[tl + Vector2i(xx, -vy - 1)] = true
				_reserved[anchor] = true
				return anchor
	return Vector2i(-1, -1)


func _camp_footprint_fits(tl: Vector2i, w: int, h: int, anchor: Vector2i,
		vis_rows: int) -> bool:
	for yy in range(h):
		for xx in range(w):
			var c := tl + Vector2i(xx, yy)
			if not _outpost_terrain_ok(c):
				return false
			if _obstacles[c.y * W + c.x] != 0 or _reserved.has(c):
				return false
			if not _outpost_reach.is_empty() and not _outpost_reach.has(c):
				return false
			if c == _spawn_pos or c == _portal_pos:
				return false
			if maxi(absi(c.x - anchor.x), absi(c.y - anchor.y)) > OUTPOST_RADIUS:
				return false
	for vy in range(vis_rows):
		var roof := tl + Vector2i(0, -vy - 1)
		if roof.y < 1:
			return false
	return true


## A free camp cell next to the desired one (radius radius, not occupied).
func _free_camp_cell(want: Vector2i, taken: Dictionary, radius: int) -> Vector2i:
	if _camp_cell_free(want, taken):
		return want
	for r in range(1, radius + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if abs(dx) != r and abs(dy) != r:
					continue
				var c := want + Vector2i(dx, dy)
				if _camp_cell_free(c, taken):
					return c
	return Vector2i(-1, -1)


func _camp_cell_free(c: Vector2i, taken: Dictionary) -> bool:
	if not _outpost_terrain_ok(c):
		return false
	if _obstacles[c.y * W + c.x] != 0:
		return false
	if taken.has(c) or _reserved.has(c):
		return false
	if c == _spawn_pos or c == _portal_pos:
		return false
	if not _outpost_reach.is_empty() and not _outpost_reach.has(c):
		return false
	return true


## Guard tier by zone: the start is empty, further on the set and the strength grow. t0..t3 exist for
## all four city sets (units_db.json, city_*_warrior/tN).
func _outpost_tier() -> int:
	match _zone:
		"mid": return 1
		"hard": return 2
		"faction": return 3
	return 0


## Stage 7: trees/objects in _obstacles (ID from alm_objects.json). Clustered
## noise by biome; we do not place on the road, near roads, in cities or by spawn/portal.
# Tree density per zone lives in [zone_design] (map design, not combat rates).
func _zone_tree_density() -> float:
	var v := GameConfig.designf(_zone, "tree_density")
	return 0.08 if v < 0.0 else v


func _place_objects(rng: RandomNumberGenerator) -> void:
	if _obj_noise == null:
		_obj_noise = FastNoiseLite.new()
		_obj_noise.seed = _seed + STREAM_OBJECTS
		_obj_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_obj_noise.frequency = 1.0 / 16.0
		_obj_noise.fractal_octaves = 2
	var density: float = _zone_tree_density()
	for y in range(H):
		for x in range(W):
			var t := _terrain[y * W + x]
			if t != 0 and t != 4 and t != 5 and t != 6:
				continue
			var cell := Vector2i(x, y)
			if _reserved.has(cell) or _near_road(cell) or _near_city(cell, 6):
				continue
			if _near_point(cell, _spawn_pos, 3) or _near_point(cell, _portal_pos, 3):
				continue
			if _obj_noise.get_noise_2d(x, y) > 0.0 and rng.randf() < density:
				_obstacles[y * W + x] = _tree_id(rng, t)
	# Stress: top the trees up to the absolute counter [stress] tree_count.
	if GameConfig.geti("stress", "enabled") != 0:
		_fill_stress_trees(rng)


## Undergrowth pass (13.11): mushrooms, ferns, dry scrub and aloe on the cells
## the tree pass left free. A separate pass, not more entries of the tree pool:
## a mushroom picked instead of an oak thins the forest, this does not touch it.
## The cells go to the .allowwalk.json sidecar — a fern is decor, not a wall.
func _place_clutter(rng: RandomNumberGenerator) -> void:
	if _clutter_noise == null:
		_clutter_noise = FastNoiseLite.new()
		_clutter_noise.seed = _seed + STREAM_OBJECTS + 11
		_clutter_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_clutter_noise.frequency = 1.0 / 9.0
		_clutter_noise.fractal_octaves = 2
	for y in range(H):
		for x in range(W):
			var idx := y * W + x
			if _obstacles[idx] != 0:
				continue
			var t := _terrain[idx]
			var pool: Array = []
			if t == 0:
				pool = CLUTTER_GRASS
			elif t == 4:
				pool = CLUTTER_SOIL
			elif t == 5:
				pool = CLUTTER_SAND
			elif t == 6:
				pool = CLUTTER_MUD
			if pool.is_empty():
				continue
			var cell := Vector2i(x, y)
			# Closer to a city than the tree pass: undergrowth belongs by the
			# walls, only the spawn point and the road stay clear.
			if _reserved.has(cell) or _near_road(cell) or _near_city(cell, 3):
				continue
			if _near_point(cell, _spawn_pos, 3) or _near_point(cell, _portal_pos, 3):
				continue
			if _clutter_noise.get_noise_2d(x, y) > 0.2 and rng.randf() < CLUTTER_CHANCE:
				_obstacles[idx] = int(_pick(rng, pool))
				_allowwalk_out.append([x, y])


func _fill_stress_trees(rng: RandomNumberGenerator) -> void:
	var want := GameConfig.geti("stress", "tree_count")
	if want <= 0:
		return
	var placed := 0
	for i in range(W * H):
		if _obstacles[i] != 0:
			placed += 1
	var tries := 0
	var max_tries := want * 6
	while placed < want and tries < max_tries:
		tries += 1
		var x := rng.randi_range(2, W - 3)
		var y := rng.randi_range(2, H - 3)
		var idx := y * W + x
		if _obstacles[idx] != 0:
			continue
		var t := _terrain[idx]
		if t != 0 and t != 4 and t != 5 and t != 6:
			continue
		var cell := Vector2i(x, y)
		if _reserved.has(cell) or _near_road(cell) or _near_city(cell, 4):
			continue
		if _near_point(cell, _spawn_pos, 2) or _near_point(cell, _portal_pos, 2):
			continue
		_obstacles[idx] = _tree_id(rng, t)
		placed += 1
	print("STRESS trees: %d (tries=%d)" % [placed, tries])

## Is there a road neighbour? (clearance: a tree does not touch the road)
func _near_road(cell: Vector2i) -> bool:
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n: Vector2i = cell + d
		if n.x < 0 or n.y < 0 or n.x >= W or n.y >= H:
			continue
		if _terrain[n.y * W + n.x] == 3:
			return true
	return false

func _near_city(cell: Vector2i, r: int) -> bool:
	for c in _cities:
		var cc: Vector2i = c["pos"]
		if maxi(abs(cell.x - cc.x), abs(cell.y - cc.y)) <= r:
			return true
	return false

func _near_point(cell: Vector2i, p: Vector2i, r: int) -> bool:
	if p.x < 0:
		return false
	return maxi(abs(cell.x - p.x), abs(cell.y - p.y)) <= r

func _tree_id(rng: RandomNumberGenerator, t: int) -> int:
	var pool: Array
	match t:
		4: pool = TREE_SOIL
		5: pool = TREE_SAND
		6: pool = TREE_MUD
		_: pool = TREE_GRASS
	return int(_pick(rng, pool))

func _place_herbs(rng: RandomNumberGenerator) -> void:
	var target_count: int = int(HERB_TARGET_COUNTS.get(_zone, 26))
	var regions_filled := 0
	var region_width := int(W / float(herb_region_grid()))
	var region_height := int(H / float(herb_region_grid()))
	for region_y in range(herb_region_grid()):
		for region_x in range(herb_region_grid()):
			var min_x := region_x * region_width + 2
			var max_x := mini((region_x + 1) * region_width - 3, W - 3)
			var min_y := region_y * region_height + 2
			var max_y := mini((region_y + 1) * region_height - 3, H - 3)
			for attempt in range(80):
				var cell := Vector2i(rng.randi_range(min_x, max_x), rng.randi_range(min_y, max_y))
				var herb := _pick_herb(rng)
				if not _herb_placement_ok(cell, herb):
					continue
				_append_herb(cell, herb)
				regions_filled += 1
				break
	var tries := 0
	while _herbs_out.size() < target_count and tries < 1200:
		tries += 1
		var cell := Vector2i(rng.randi_range(2, W - 3), rng.randi_range(2, H - 3))
		var herb := _pick_herb(rng)
		if not _herb_placement_ok(cell, herb):
			continue
		_append_herb(cell, herb)
	print("HERBS: %d/%d regions=%d/%d min_distance=%d wild_tier>=%d" % [
		_herbs_out.size(), target_count, regions_filled,
		herb_region_grid() * herb_region_grid(), herb_min_distance(),
		HerbDB.wild_tier_min()])

## Weighted pick from the zone pool. The tier decides the recipe tier: a start
## map gives the herbs of the small potions, a faction map the rare ones.
func _pick_herb(rng: RandomNumberGenerator) -> Dictionary:
	var pool: Array = HerbDB.zone_pool(_zone)
	if pool.is_empty():
		pool = HerbDB.zone_pool("mid")
	if pool.is_empty():
		return {}
	var total := 0.0
	for raw in pool:
		total += maxf(0.01, float((raw as Dictionary).get("weight", 1)))
	var roll := rng.randf() * total
	for raw in pool:
		roll -= maxf(0.01, float((raw as Dictionary).get("weight", 1)))
		if roll <= 0.0:
			return raw as Dictionary
	return pool[-1] as Dictionary

## Cell rules plus the wild rule: a rare herb must be found away from the cities
## (the player's decision 09.11) - that is what makes the walk dangerous.
func _herb_placement_ok(cell: Vector2i, herb: Dictionary) -> bool:
	if herb.is_empty():
		return false
	if not _herb_cell_ok(cell) or not _herb_spacing_ok(cell):
		return false
	var item := str(herb.get("item", ""))
	if HerbDB.tier_of(item) < HerbDB.wild_tier_min():
		return true
	return _in_wild(cell)

func _in_wild(cell: Vector2i) -> bool:
	var limit: int = HerbDB.wild_min_city_distance()
	for city in _cities:
		var pos: Vector2i = city.get("pos", Vector2i.ZERO)
		if maxi(absi(cell.x - pos.x), absi(cell.y - pos.y)) < limit:
			return false
	if _spawn_pos.x >= 0 and maxi(absi(cell.x - _spawn_pos.x), absi(cell.y - _spawn_pos.y)) < limit:
		return false
	return true

func _append_herb(cell: Vector2i, herb: Dictionary) -> void:
	var item := str(herb.get("item", ""))
	_herbs_out.append({
		"x": cell.x, "y": cell.y,
		"item": item, "icon": HerbDB.icon_of(item),
	})

func _herb_spacing_ok(cell: Vector2i) -> bool:
	for record in _herbs_out:
		var dx := absi(cell.x - int(record.get("x", -1)))
		var dy := absi(cell.y - int(record.get("y", -1)))
		if dx < herb_min_distance() and dy < herb_min_distance():
			return false
	return true

func _herb_cell_ok(cell: Vector2i) -> bool:
	if cell.x < 2 or cell.y < 2 or cell.x >= W - 2 or cell.y >= H - 2:
		return false
	var terrain := _terrain[cell.y * W + cell.x]
	if terrain != 0 and terrain != 4:
		return false
	if _obstacles[cell.y * W + cell.x] != 0:
		return false
	if _reserved.has(cell) or _near_road(cell) or _near_city(cell, 6):
		return false
	if _near_point(cell, _spawn_pos, 8) or _near_point(cell, _portal_pos, 8):
		return false
	for record in _herbs_out:
		if int(record.get("x", -1)) == cell.x and int(record.get("y", -1)) == cell.y:
			return false
	return true

## Stage 9: Greys — clusters near roads (to the side) and in forest tracts. Only on
## free cells, outside cities and no closer than 20 cells to spawn.
##
## Measurement 03.10 (player report "1 Grey on the map"): with 15 Greys, 2-3 enemies
## sat on 6 cells, and they all huddled in one half of the map (y=74..118).
## Two reasons: the cluster anchor was not checked for occupancy, and the anchors were picked
## independently, so all came from the same random corner.
## Now we first walk the REGIONS in turn and one cluster in each, and only
## then top up randomly — that way map coverage is guaranteed.
func _place_greys(rng: RandomNumberGenerator) -> void:
	var count: int = rng.randi_range(
		GameConfig.designi(_zone, "gray_count_min"), GameConfig.designi(_zone, "gray_count_max"))
	if GameConfig.geti("stress", "enabled") != 0:
		count = GameConfig.geti("stress", "gray_count")
	var placed := 0
	var encounter_seq := 0

	# The list of regions in shuffled order — so that "earlier" zones are not always
	# chosen the same way and the map is not predictable.
	var regions: Array = []
	for ry in range(GRAY_REGION_GRID):
		for rx in range(GRAY_REGION_GRID):
			regions.append(Vector2i(rx, ry))
	_shuffle(rng, regions)

	# Package D: thematic encounters first (hive/lair/pack), ~35% of the quota.
	var encounter_budget := int(ceil(float(count) * 0.35))
	var kinds: Array = ENCOUNTER_KINDS.duplicate()
	_shuffle(rng, kinds)
	var kinds_used := 0
	var tries_e := 0
	while placed < encounter_budget and kinds_used < kinds.size() and tries_e < 200:
		tries_e += 1
		var ed: Dictionary = kinds[kinds_used % kinds.size()]
		kinds_used += 1
		var anchor := _encounter_anchor(rng, str(ed.get("near", "any")))
		if anchor.x < 0:
			continue
		placed += _spawn_encounter(rng, anchor, ed, encounter_seq)
		encounter_seq += 1

	for reg in regions:
		if placed >= count:
			break
		var anchor := _gray_anchor_in_region(rng, reg)
		if anchor.x < 0:
			continue
		placed += _gray_cluster(rng, anchor)

	# Top-up: if the regions did not yield the needed amount (few roads/forest in part
	# of the map), we take any suitable anchors.
	var tries := 0
	while placed < count and tries < 800:
		tries += 1
		var anchor := Vector2i(-1, -1)
		if rng.randf() < 0.5:
			var road := _road_anchor(rng)
			if road.x >= 0:
				anchor = _side_road_cell(rng, road)
		else:
			anchor = _forest_anchor(rng)
		if anchor.x < 0 or not _gray_anchor_ok(anchor):
			continue
		placed += _gray_cluster(rng, anchor)

	var regions_used := {}
	for k in _gray_cells.keys():
		var p := str(k).split(",")
		regions_used["%d,%d" % [int(int(p[0]) * GRAY_REGION_GRID / float(W)),
			int(int(p[1]) * GRAY_REGION_GRID / float(H))]] = true
	print("GRAY: %d/%d клеток=%d регионов=%d/%d" % [
		placed, count, _gray_cells.size(), regions_used.size(),
		GRAY_REGION_GRID * GRAY_REGION_GRID])


## Grey anchor inside a specific map region (the GRAY_REGION_GRID grid).
## Two attempts: first we look for a cell near a road or forest (beasts look
## like beasts), and if there is none in the region — we take any free land.
## Without the second attempt, regions without roads and forest stayed empty: the measurement
## of 03.10 gave 3 regions out of 9.
func _gray_anchor_in_region(rng: RandomNumberGenerator, reg: Vector2i) -> Vector2i:
	var rw := int(W / float(GRAY_REGION_GRID))
	var rh := int(H / float(GRAY_REGION_GRID))
	var x0 := reg.x * rw
	var y0 := reg.y * rh
	var fallback := Vector2i(-1, -1)
	for attempt in range(60):
		var c := Vector2i(rng.randi_range(x0 + 2, x0 + rw - 3),
			rng.randi_range(y0 + 2, y0 + rh - 3))
		if not _gray_cell_ok(c):
			continue
		if _near_point(c, _spawn_pos, GRAY_MIN_SPAWN_DISTANCE):
			continue
		if not _gray_anchor_ok(c):
			continue
		if _near_road(c) or _forest_anchor_ok(c):
			return c
		if fallback.x < 0:
			fallback = c
	return fallback


## Are there at least two trees (objects) around the cell — a sign of forest terrain.
func _forest_anchor_ok(c: Vector2i) -> bool:
	var trees := 0
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n: Vector2i = c + d
		if n.x < 0 or n.y < 0 or n.x >= W or n.y >= H:
			continue
		if _obstacles[n.y * W + n.x] > 0:
			trees += 1
	return trees >= 2


## Shuffle an array with the generator rng (we do not use the global random.* —
## otherwise generation stops being deterministic by seed).
func _shuffle(rng: RandomNumberGenerator, arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


## A cluster anchor must not coincide with an occupied one and must be separated from
## other anchors, otherwise all Greys stick together in one corner of the map.
func _gray_anchor_ok(anchor: Vector2i) -> bool:
	if _gray_cells.has("%d,%d" % [anchor.x, anchor.y]):
		return false
	for k in _gray_cells.keys():
		var p := str(k).split(",")
		var dx := absi(anchor.x - int(p[0]))
		var dy := absi(anchor.y - int(p[1]))
		if dx < GRAY_MIN_DISTANCE and dy < GRAY_MIN_DISTANCE:
			return false
	return true

## A random road cell outside the cities and farther from spawn.
func _road_anchor(rng: RandomNumberGenerator) -> Vector2i:
	var tries := 0
	while tries < 400:
		tries += 1
		var x := rng.randi_range(2, W - 3)
		var y := rng.randi_range(2, H - 3)
		if _terrain[y * W + x] != 3:
			continue
		var c := Vector2i(x, y)
		if _near_city(c, 6) or _near_point(c, _spawn_pos, 24):
			continue
		return c
	return Vector2i(-1, -1)

## To the side of the road (1-2 cells aside, walkable land only).
func _side_road_cell(rng: RandomNumberGenerator, road: Vector2i) -> Vector2i:
	var dirs: Array = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for step in range(1, 3):
		for attempt in range(8):
			var dir: Vector2i = dirs[rng.randi() % dirs.size()]
			var c: Vector2i = road + dir * step
			if _gray_cell_ok(c):
				return c
	return road

## A forest point: >=2 trees around (obstacles), the cell is free.
func _forest_anchor(rng: RandomNumberGenerator) -> Vector2i:
	var tries := 0
	while tries < 500:
		tries += 1
		var x := rng.randi_range(2, W - 3)
		var y := rng.randi_range(2, H - 3)
		var c := Vector2i(x, y)
		if not _gray_cell_ok(c) or _near_point(c, _spawn_pos, 20):
			continue
		var trees := 0
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			if n.x < 0 or n.y < 0 or n.x >= W or n.y >= H:
				continue
			if _obstacles[n.y * W + n.x] > 0:
				trees += 1
		if trees >= 2:
			return c
	return Vector2i(-1, -1)

## A cell is suitable for a Grey: land, without an object/building/spawn/portal, outside cities.
func _gray_cell_ok(c: Vector2i) -> bool:
	if c.x < 2 or c.y < 2 or c.x >= W - 2 or c.y >= H - 2:
		return false
	var t := _terrain[c.y * W + c.x]
	if t != 0 and t != 4 and t != 5 and t != 6:
		return false
	if _obstacles[c.y * W + c.x] > 0:
		return false
	if _reserved.has(c) or c == _spawn_pos or c == _portal_pos:
		return false
	if _near_city(c, 6):
		return false
	# The cell is already taken by another Grey. Without this check the clusters overlapped:
	# their anchors were picked independently, and 2-3 enemies sat on 6 cells.
	if _gray_cells.has("%d,%d" % [c.x, c.y]):
		return false
	return true

## A cluster of 2-4 Greys around anchor (the cells are spaced out).
##
## AN EMPTY POOL = NO GREYS. All monster sets were removed with the Allods art
## (11.10), and without this check `_pick(rng, [])` returned null, which
## was assigned to `String` — a SCRIPT ERROR inside the map generator itself. Before,
## an empty pool was impossible, which is why the branch was not written.
func _gray_cluster(rng: RandomNumberGenerator, anchor: Vector2i) -> int:
	var pool: Array = gray_pool_for_zone(_zone)
	if pool.is_empty():
		return 0
	var cells: Array = [anchor]
	for i in range(1, 3):
		var c := _near_gray_cell(rng, anchor, cells)
		if c.x < 0:
			break
		cells.append(c)
	for i in range(cells.size()):
		var cc: Vector2i = cells[i]
		_gray_cells["%d,%d" % [cc.x, cc.y]] = true
		var set_name: String = str(_pick(rng, pool))
		# The tier scales the global [grey] base (see gray_tier_mults), so the
		# zone band, not a per-zone DPS table, decides how hard a map hits.
		var mults: Array = gray_tier_mults(set_name)
		var hp := int(round(float(rng.randi_range(
			GameConfig.geti("grey", "hp_min"), GameConfig.geti("grey", "hp_max")))
			* float(mults[0])))
		var dmg := int(round(float(rng.randi_range(
			GameConfig.geti("grey", "damage_min"), GameConfig.geti("grey", "damage_max")))
			* float(mults[1])))
		_npcs_out.append({
			"x": int(cc.x), "y": int(cc.y), "set": set_name,
			"hp_max": hp, "damage": dmg,
		})
	return cells.size()


## Thematic encounter anchor: forest/road/any.
func _encounter_anchor(rng: RandomNumberGenerator, near: String) -> Vector2i:
	match near:
		"forest":
			var f := _forest_anchor(rng)
			if f.x >= 0 and _gray_anchor_ok(f):
				return f
			return Vector2i(-1, -1)
		"road":
			var road := _road_anchor(rng)
			if road.x >= 0:
				var c := _side_road_cell(rng, road)
				if c.x >= 0 and _gray_anchor_ok(c):
					return c
			return Vector2i(-1, -1)
		_:
			for attempt in range(20):
				var c := Vector2i(rng.randi_range(4, W - 5), rng.randi_range(4, H - 5))
				if _gray_cell_ok(c) and _gray_anchor_ok(c):
					return c
			return Vector2i(-1, -1)


## Place an encounter: 1 "core" (stronger) + members-1 ordinary ones around.
func _spawn_encounter(rng: RandomNumberGenerator, anchor: Vector2i, ed: Dictionary, eid: int) -> int:
	var sets: Array = ed.get("sets", [])
	if sets.is_empty():
		return 0   # no sets — the pack is not placed (see ENCOUNTER_KINDS)
	var members: Array = ed.get("members", [2, 3])
	var n := rng.randi_range(int(members[0]), int(members[1]))
	var hp_mult := float(ed.get("hp_mult", 1.0))
	var dmg_mult := float(ed.get("dmg_mult", 1.0))
	var kind := str(ed.get("kind", "wild"))
	var cells: Array = [anchor]
	for i in range(1, n):
		var c := _near_gray_cell(rng, anchor, cells)
		if c.x < 0:
			break
		cells.append(c)
	for i in range(cells.size()):
		var cc: Vector2i = cells[i]
		_gray_cells["%d,%d" % [cc.x, cc.y]] = true
		var set_name: String = str(sets[i % sets.size()])
		var is_core := i == 0
		var hp := int(round(float(rng.randi_range(
			GameConfig.geti("grey", "hp_min"), GameConfig.geti("grey", "hp_max"))) * hp_mult * (1.25 if is_core else 1.0)))
		var dmg := int(round(float(rng.randi_range(
			GameConfig.geti("grey", "damage_min"), GameConfig.geti("grey", "damage_max"))) * dmg_mult))
		var rec := {
			"x": int(cc.x), "y": int(cc.y), "set": set_name,
			"hp_max": hp, "damage": dmg,
			"encounter_kind": kind,
			"encounter_id": eid,
			"home_x": int(anchor.x), "home_y": int(anchor.y),
		}
		if is_core:
			rec["encounter_core"] = true
		_npcs_out.append(rec)
	print("ENCOUNTER %s id=%d members=%d core=%s" % [kind, eid, cells.size(), str(ed.get("label", ""))])
	return cells.size()

## A neighbouring cell for the cluster. IMPORTANT: the `taken` array is only READ here.
## Before, `taken.append(c)` was written here, and then the calling code did
## `cells.append(c)` — and the array is passed BY REFERENCE, so the cell landed in the
## list twice. A cluster of 3 turned into 5 records, two of them on the same
## cell: the measurement of 03.10 gave 15 Greys on 9 cells, and the player saw "1 Grey".
func _near_gray_cell(rng: RandomNumberGenerator, anchor: Vector2i, taken: Array) -> Vector2i:
	for attempt in range(12):
		var off := Vector2i(rng.randi_range(-2, 2), rng.randi_range(-2, 2))
		if off == Vector2i.ZERO:
			continue
		var c: Vector2i = anchor + off
		if taken.has(c) or not _gray_cell_ok(c):
			continue
		return c
	return Vector2i(-1, -1)

func _pick(rng: RandomNumberGenerator, arr: Array) -> Variant:
	if arr.is_empty():
		return null
	return arr[rng.randi() % arr.size()]

func _save_spawn_json() -> void:
	if _spawn_pos.x < 0:
		return
	var path: String = _out_dir + _basename + ".spawn.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"x": _spawn_pos.x, "y": _spawn_pos.y}))
	f.close()

func _save_portal_json() -> void:
	if _portal_pos.x < 0:
		return
	var path: String = _out_dir + _basename + ".portal.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"x": _portal_pos.x, "y": _portal_pos.y}))
	f.close()

## New sidecar format: an array of portals by sector border.
func _save_portals_json() -> void:
	var path: String = _out_dir + _basename + ".portal.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"portals": _portals_out}))
	f.close()

## Delete the portal sidecar if the map is regenerated in a zone without a portal.
func _drop_portal_json() -> void:
	var path: String = _out_dir + _basename + ".portal.json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		print("PORTAL: старый sidecar удалён (%s)" % path)

func _a_star(start: Vector2i, goal: Vector2i, rng: RandomNumberGenerator) -> Array:
	var came: Dictionary = {}
	var gscore: Dictionary = {}
	var fscore: Dictionary = {}
	var gk := start.y * W + start.x
	var gk2 := goal.y * W + goal.x
	gscore[gk] = 0
	fscore[gk] = _astar_h(start, goal)
	var open: Array = [gk]
	while not open.is_empty():
		# pick the minimum fscore
		var best_i := 0
		var best_f := -1
		for i in range(open.size()):
			var f := int(fscore.get(open[i], 1 << 30))
			if best_f < 0 or f < best_f:
				best_f = f
				best_i = i
		var cur: int = open[best_i]
		open.remove_at(best_i)
		if cur == gk2:
			# reconstruct the path
			var out: Array = []
			var c := cur
			while c != gk:
				var cc: Vector2i = Vector2i(c % W, int(c / float(W)))
				out.push_front(cc)
				c = int(came.get(c, gk))
			out.push_front(start)
			return out
		var cp: Vector2i = Vector2i(cur % W, int(cur / float(W)))
		# The direction we came from (for the turn penalty)
		var dir_from_prev := Vector2i(0, 0)
		if came.has(cur):
			var prev_p: Vector2i = Vector2i(int(came[cur]) % W, int(int(came[cur]) / float(W)))
			dir_from_prev = cp - prev_p
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var np: Vector2i = cp + d
			if not _is_road_cell(np.x, np.y):
				continue
			var nk: int = np.y * W + np.x
			# Base step cost + mountain penalty (the road prefers grass)
			var stepcost := 10
			if _terrain[nk] == 1:
				stepcost = 18
			# Slight repulsion from water: in the originals the road almost never touches
			# water (adj 0-9%), we keep a distance of 1 cell.
			var near_water_cost := 0
			for wd in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var wn: Vector2i = np + wd
				if wn.x >= 0 and wn.y >= 0 and wn.x < W and wn.y < H and _terrain[wn.y * W + wn.x] == 2:
					near_water_cost = 3
					break
			var penalty := 0
			if dir_from_prev != Vector2i.ZERO and dir_from_prev != d:
				penalty = 6
			# deterministic cell noise for the winding of the route
			var jitter: int = (abs(cp.x * 7919 + cp.y * 104729) % 9) - 4
			var tentative: int = int(gscore.get(cur, 1 << 30)) + stepcost + penalty + near_water_cost + jitter
			if tentative < int(gscore.get(nk, 1 << 30)):
				came[nk] = cur
				gscore[nk] = tentative
				fscore[nk] = tentative + _astar_h(np, goal)
				if not open.has(nk):
					open.append(nk)
	return []

func _astar_h(p: Vector2i, goal: Vector2i) -> int:
	return absi(goal.x - p.x) + absi(goal.y - p.y)

func _is_road_cell(x: int, y: int) -> bool:
	if x < 1 or y < 1 or x >= W - 1 or y >= H - 1:
		return false
	var t: int = _terrain[y * W + x]
	return t != 2  # Everything except water is passable for the road

func _set_land_road(p: Vector2i) -> void:
	if p.x < 0 or p.y < 0 or p.x >= W or p.y >= H:
		return
	var idx: int = p.y * W + p.x
	var t: int = _terrain[idx]
	if t == 2:
		return
	_terrain[idx] = 3

func _place_terrain(n: int) -> void:
	# === Stage 1: Voronoi soil (the base). Mountains/water/road are added later ===
	# Base types only: 0 grass, 4 soil, 5 sand, 6 mud.
	# Anchor points: type -> count
	var seed_counts := {0: 3, 4: 2, 5: 2, 6: 1}

	var rng := RandomNumberGenerator.new()
	rng.seed = _seed + STREAM_TERRAIN

	# Noise for deforming the borders (creates winding shores/biome borders)
	var jitter_noise := FastNoiseLite.new()
	jitter_noise.seed = _seed + STREAM_JITTER
	jitter_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	jitter_noise.frequency = 1.0 / 20.0
	jitter_noise.fractal_octaves = 3

	# Height field: used by mountains/water in stage 4 and by the heights (step 7)
	var elev_noise := FastNoiseLite.new()
	elev_noise.seed = _seed + STREAM_TERRAIN
	elev_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	elev_noise.frequency = 1.0 / 40.0
	elev_noise.fractal_octaves = 4
	elev_noise.fractal_gain = 0.5

	# Generate the anchor points
	var seeds: Array = []
	for t in seed_counts:
		for i in range(seed_counts[t]):
			var sx: float = rng.randf_range(5.0, W - 6.0)
			var sy: float = rng.randf_range(5.0, H - 6.0)
			seeds.append({"pos": Vector2(sx, sy), "type": t})

	var field := PackedFloat32Array()
	field.resize(n)

	# For every cell — the nearest anchor point
	for i in range(n):
		var x: float = float(i % W)
		var y: float = float(int(i / float(W)))
		var elev: float = (elev_noise.get_noise_2d(x, y) + 1.0) * 0.5
		field[i] = elev

		# Look for the nearest anchor point with noise offset
		var best_type: int = 0
		var best_dist: float = 1e30
		for s in seeds:
			var sp: Vector2 = s["pos"]
			# Base distance
			var dx: float = x - sp.x
			var dy: float = y - sp.y
			var dist: float = dx * dx + dy * dy
			# Noise offset for organic borders (~10% of the distance)
			var jx: float = jitter_noise.get_noise_2d(x * 3.0, y * 3.0)
			var jy: float = jitter_noise.get_noise_2d(x * 3.0 + 100, y * 3.0 + 100)
			dist += (jx * dx + jy * dy) * 3.0
			if dist < best_dist:
				best_dist = dist
				best_type = s["type"]

		_terrain[i] = best_type

	# Store field and thresholds for the heights.
	# The sector relief (23.10) changes the SHARE of impassable terrain, but not the base: mountains/water
	# remain barriers at the edges and between areas, not a biome.
	_field = field
	var sorted := field.duplicate()
	sorted.sort()
	var water_pct := 0.10
	var mountain_pct := 0.90
	match _relief:
		"coast":
			water_pct = 0.14
		"marsh":
			water_pct = 0.16
		"hills":
			mountain_pct = 0.88
		"ridges":
			mountain_pct = 0.82
		"plains":
			mountain_pct = 0.94
	_water_thr = sorted[clampi(int(water_pct * n), 0, n - 1)]
	_mountain_thr = sorted[clampi(int(mountain_pct * n), 0, n - 1)]

func _pick_tile(t: int, x: int, y: int) -> int:
	var s: Dictionary = _sides(x, y)
	# The transition edge has priority over shape/rules: the tile1..7 files
	# are seamless and contain no edges, so the exact shapes from the .alm audit
	# give nothing on them — only a seam. See terrain_tiles_db.json.
	var trans: int = _transition_tile(t, s, x, y)
	if trans >= 0:
		_stat_transition += 1
		return trans
	var mask := _mask_from_sides(s, t)
	if mask == 0:
		return _interior_tile(t, x, y)
	# 1. Exact shape from real-map audit (weighted top tiles)
	var spec := _shape_lookup(t, mask, x, y)
	if not spec.is_empty():
		_stat_exact += 1
		return AlmLoader.tile_from_spec(spec)
	# 2. Fallback: old directional rules (first matching direction)
	_stat_rules += 1
	return _edge_tile(t, s, x, y)

## Transition direction for a cell: -1 if there is no transition.
## The order matches directions.order in terrain_tiles_db.json and the keys of
## _sides(): N, NE, E, SE, S, SW, W, NW. Cardinals are taken before
## diagonals — that is how the original transition_db behaved too.
##
## 05.10 (two rules):
## 1) One-way transition: we blend only if t < n (my type is less than
##    the neighbour's type). A neighbour with a greater type stays a clean interior.
##    Otherwise both sides of the border cut towards each other: at the edge of the A tile there is pure B,
##    at the edge of the B tile pure A → at the seam a hard B|A in the middle of the blend,
##    a "double shore" (player report, 05.10: water-sand from both sides).
## 2) A diagonal is skipped if the seam to n is already at the corner's
##    cardinal neighbours (_diag_covered). See the comment on _diag_covered.
func _transition_dir(s: Dictionary, t: int, x: int, y: int) -> int:
	for d in _TRANSITION_DIR_ORDER:
		var n: int = s[d]
		if n < 0 or n == t:
			continue
		# The higher type does not blend into the lower one — the neighbour will place the transition.
		if t > n:
			continue
		if d == "NE" or d == "SE" or d == "SW" or d == "NW":
			if _diag_covered(x, y, t, n, d):
				continue
		return _TRANSITION_DIR_ORDER.find(d)
	return -1

## Cardinal neighbours at the corner of diagonal d (_sides() keys).
const _DIAG_CARDINALS := {
	"NE": ["N", "E"],
	"SE": ["S", "E"],
	"SW": ["S", "W"],
	"NW": ["N", "W"],
}
const _CARDINAL_OFFSET := {
	"N": Vector2i(0, -1),
	"S": Vector2i(0, 1),
	"E": Vector2i(1, 0),
	"W": Vector2i(-1, 0),
}

## The terrain value outside the map = -1.
func _terrain_at(x: int, y: int) -> int:
	if x < 0 or y < 0 or x >= W or y >= H:
		return -1
	return _terrain[y * W + x]

## A diagonal to type n is "covered" if the cardinal neighbour at that corner has
## type t (its own) and that cardinal neighbour has a cardinal neighbour of type n.
##
## GEOMETRY: for a clean diagonal (both cardinals == t) the diagonal neighbour
## is ALWAYS cardinal for both corner cells (the NW of a cell = the W of the N neighbour).
## So clean diagonal transitions are effectively disabled — by the player's
## decision (05.10): an extra corner cut on top of already trimmed neighbours is not needed.
## The border is held by the cardinal transitions on the cells touching n.
func _diag_covered(x: int, y: int, t: int, n: int, d: String) -> bool:
	var cards: Array = _DIAG_CARDINALS.get(d, [])
	for cdir in cards:
		var off: Vector2i = _CARDINAL_OFFSET[cdir]
		var cx: int = x + int(off.x)
		var cy: int = y + int(off.y)
		if _terrain_at(cx, cy) != t:
			continue
		for aoff in _CARDINAL_OFFSET.values():
			var a: Vector2i = aoff
			if _terrain_at(cx + int(a.x), cy + int(a.y)) == n:
				return true
	return false

## Stable per-cell hash.
##
## `hash(Vector2i)` is engine-defined and Godot may change it between versions,
## which would silently reshuffle generated maps while the seed stayed the same.
## This mixing formula is ours (same constants as `_interior_tile`), so a cell
## keeps its value across engine upgrades. No player data depends on the exact
## numbers, only determinism does.
func _cell_hash(x: int, y: int) -> int:
	return absi(x * 19349663 ^ y * 83492791)

## Transition tile A -> B for the direction dir_index. -1 when there is no transition.
##
## Known limitation: a corner cell with two differing neighbours
## gets a blend only in one (the first) direction. Blending along two
## edges at once would require separate corner tiles — that is 4 files per pair
## of types, and the .alm format has no room for them.
func _transition_tile(t: int, s: Dictionary, x: int, y: int) -> int:
	var dir_index: int = _transition_dir(s, t, x, y)
	if dir_index < 0:
		return -1
	var b: int = s[_TRANSITION_DIR_ORDER[dir_index]]
	if b < 0 or b > 6:
		return -1
	var file_n: int = AlmLoader.TRANSITION_FILE_MIN + dir_index
	# row = B * 2 + variation. The variation comes from the cell coordinate so that
	# neighbouring edges are not identical but stay deterministic.
	var variation: int = _cell_hash(x, y) % 2
	var row: int = b * 2 + variation
	return AlmLoader.tile_encode_transition(file_n, t, row)

## Bit layout must match tests/analyze_shapes.gd: [N, NE, E, SE, S, SW, W, NW]
const CARDINAL_BITS := 0x55  # bits N(0), E(2), S(4), W(6)
## Grass edge variants that are visually almost identical (L1 4-20 thousand).
## v0/v2/v3 — the "soil" ones (L1 26-46 thousand): on a flat edge they look
## like inset squares, the level designers did not use them for simple borders.
const GRASS_EDGE_VARIANTS := [1, 5, 9, 12, 13, 14]
func _mask_from_sides(s: Dictionary, t: int) -> int:
	var mask := 0
	var dirs := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	for d in range(8):
		var n: int = s[dirs[d]]
		if n != -1 and n != t:
			mask |= (1 << d)
	return mask

func _mask_str(mask: int) -> String:
	var out := ""
	for d in range(8):
		out += "1" if (mask & (1 << (7 - d))) != 0 else "0"
	return out

## Exact shape -> hybrid (types 4-6 borrow grass topology) -> nearest mask.
## Returns {file, variant, row} or {} if nothing found.
func _shape_lookup(t: int, mask: int, x: int, y: int) -> Dictionary:
	var key := "%d:%s" % [t, _mask_str(mask)]
	if _shapes.has(key):
		return _shape_tile(t, _shapes[key], x, y, mask)
	# Hybrid: soil/sand/mud have no real art — borrow grass(0) shapes,
	# re-render into their own tile file via TERRAIN_FILE.
	if t >= 4:
		var tkey := "0:%s" % _mask_str(mask)
		if _shapes.has(tkey):
			return _shape_tile(t, _shapes[tkey], x, y, mask)
	# Nearest mask by Hamming distance for this type (or grass for 4-6)
	_stat_subset += 1
	var best_key := ""
	var best_dist := 99
	var best_total := -1
	var types: Array = [t] if t <= 3 else [t, 0]
	for tt in types:
		var prefix := "%d:" % tt
		for k in _shapes:
			var ks: String = str(k)
			if not ks.begins_with(prefix):
				continue
			var sm := _mask_from_str(ks.substr(prefix.length()))
			var dist := _popcount(sm ^ mask)
			var total: int = _shapes[k].get("total", 0)
			if dist < best_dist or (dist == best_dist and total > best_total):
				best_dist = dist
				best_key = ks
				best_total = total
	if best_key.is_empty():
		return {}
	return _shape_tile(t, _shapes[best_key], x, y, mask)

## Weighted choice from the shape. For border cells with a cardinal mask
## we narrow the candidates down to the type's "edge" row — otherwise the top tile may be an
## interior texture and tear the flat edge line.
func _shape_tile(t: int, entry: Dictionary, x: int, y: int, mask: int) -> Dictionary:
	var tiles: Array = entry.get("tiles", [])
	if tiles.is_empty():
		return {}
	var candidates: Array = tiles
	if mask & CARDINAL_BITS != 0:
		var art_t := t if t <= 3 else 0
		# A universal "edge" exists only for grass (0) and mountains (1) — one row for
		# any cardinal transition. Water is animated (rows 0..7), the road has its
		# own edge rows by neighbour — you cannot force a single row on them.
		if (art_t == 0 or art_t == 1) and _edge_rows.has(art_t):
			var er: int = _edge_rows[art_t]
			var filtered: Array = []
			for ti in tiles:
				if int(ti.get("row", -1)) == er:
					# Grass edge: "green" variants only. v0/v2/v3 are darker,
					# they look like "squares of soil" on a flat line, the level designers
					# did not use them on simple edges. The family v1/v5/v9/v12/v13/v14
					# is pixel-wise almost identical (L1 4-20 thousand vs 26-46 thousand for v0/2/3).
					if art_t == 0 and int(ti.get("variant", -1)) in GRASS_EDGE_VARIANTS:
						filtered.append(ti)
					elif art_t != 0:
						filtered.append(ti)
			if filtered.is_empty():
				# No edge candidates — let _pick_tile fall into the rules fallback
				# (a flat edge by the neighbour type) instead of taking interior textures.
				return {}
			candidates = filtered
	var total := 0
	for ti in candidates:
		total += int(ti.get("w", 0))
	if total <= 0:
		return {}
	var h: int = _cell_hash(x, y)
	var r: int = h % total
	var acc := 0
	var picked: Dictionary = candidates[candidates.size() - 1]
	for ti in candidates:
		acc += int(ti.get("w", 0))
		if r < acc:
			picked = ti
			break
	var out := {
		"file": int(picked.get("file", 1)),
		"variant": int(picked.get("variant", 0)),
		"row": int(picked.get("row", 0)),
	}
	if t >= 4:
		out["file"] = int(TERRAIN_FILE.get(t, out["file"]))
	return out

func _mask_from_str(s: String) -> int:
	var m := 0
	for i in range(mini(8, s.length())):
		if s[i] == "1":
			m |= 1 << (7 - i)
	return m

func _popcount(v: int) -> int:
	var c := 0
	for i in range(8):
		if v & (1 << i):
			c += 1
	return c

func _sides(x: int, y: int) -> Dictionary:
	var t: int = _terrain[y * W + x]
	var r := {"N": -1, "S": -1, "E": -1, "W": -1,
			  "NE": -1, "NW": -1, "SE": -1, "SW": -1}
	if y > 0:     r["N"]  = _terrain[(y - 1) * W + x]
	if y < H - 1: r["S"]  = _terrain[(y + 1) * W + x]
	if x < W - 1: r["E"]  = _terrain[y * W + x + 1]
	if x > 0:     r["W"]  = _terrain[y * W + x - 1]
	if y > 0 and x < W - 1: r["NE"] = _terrain[(y - 1) * W + x + 1]
	if y > 0 and x > 0:     r["NW"] = _terrain[(y - 1) * W + x - 1]
	if y < H - 1 and x < W - 1: r["SE"] = _terrain[(y + 1) * W + x + 1]
	if y < H - 1 and x > 0:     r["SW"] = _terrain[(y + 1) * W + x - 1]
	return r

func _interior_tile(t: int, x: int, y: int = -1) -> int:
	# 1. Base textures from real maps: low-frequency noise per cell -> one of
	#    top-6 tiles. A smooth field gives connected "fields" without hard worley chunks.
	var base: Dictionary = _base_int.get(str(t), {})
	var tiles: Array = base.get("tiles", [])
	if not tiles.is_empty():
		var total := 0
		for ti in tiles:
			total += int(ti.get("w", 0))
		var val := _interior_value(x, y, t, total)
		var pick: Dictionary = tiles[tiles.size() - 1]
		if total > 0:
			var r: int = val
			var acc := 0
			for ti in tiles:
				acc += int(ti.get("w", 0))
				if r < acc:
					pick = ti
					break
		var spec := {
			"file": int(pick.get("file", 1)),
			"variant": int(pick.get("variant", 0)),
			"row": int(pick.get("row", 0)),
		}
		if t >= 4:
			spec["file"] = int(TERRAIN_FILE.get(t, spec["file"]))
		return AlmLoader.tile_from_spec(spec)

	# 2. A1-A6 interior variants from rules
	var a_variants: Array = []
	for iv in range(1, 7):
		var key: String = "%d:A%d:%d" % [t, iv, t]
		var spec: Dictionary = _rules.get(key, {})
		if not spec.is_empty():
			a_variants.append(spec)
	if a_variants.size() > 0:
		# Vary across cells via coordinates (constant hash was a bug:
		# same variant for the whole map).
		var hseed: int = 17
		if x >= 0 and y >= 0:
			hseed = abs(t * 73856093 + x * 19349663 + y * 83492791)
		var idx: int = hseed % a_variants.size()
		var spec: Dictionary = a_variants[idx]
		return AlmLoader.tile_from_spec(_spec_for_type(t, spec))

	# 3. Fallback to interior dict
	var key := str(t)
	if _interior.has(key):
		return AlmLoader.tile_from_spec(_spec_for_type(t, _interior[key]))
	match t:
		0: return AlmLoader.tile_from_spec({"file": 1, "variant": 1, "row": 1})
		1: return AlmLoader.tile_from_spec({"file": 2, "variant": 15, "row": 3})
		2: return AlmLoader.tile_from_spec({"file": 3, "variant": 3, "row": 0})
		3: return AlmLoader.tile_from_spec({"file": 4, "variant": 3, "row": 0})
	return 0

## Smooth low-frequency noise (frequency ~1/14) + a light local component.
	## Returns an index in the range [0, total): neighbouring cells correlate —
	## connected "fields" without hard 8x8 chunks and without a "checkerboard".
func _interior_value(x: int, y: int, t: int, total: int) -> int:
	if _interior_noise == null:
		_interior_noise = FastNoiseLite.new()
		_interior_noise.seed = _seed + STREAM_INTERIOR
		_interior_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_interior_noise.frequency = 1.0 / 14.0
	if _interior_hi == null:
		_interior_hi = FastNoiseLite.new()
		_interior_hi.seed = _seed + STREAM_INTERIOR_HI
		_interior_hi.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_interior_hi.frequency = 1.0 / 60.0
	# Domain shift per type: base seed + type step (7 + t*131 / 99 + t*271).
	_interior_noise.seed = _seed + STREAM_INTERIOR + t * 131
	_interior_hi.seed = _seed + STREAM_INTERIOR_HI + t * 271
	var off: int = _NOISE_OFFSETS.get(t, 0)
	var f1: float = (_interior_noise.get_noise_2d(float(x) + off, float(y)) + 1.0) * 0.5
	var f2: float = (_interior_hi.get_noise_2d(float(x) * 2.0 + off, float(y) * 2.0) + 1.0) * 0.5
	var f: float = clampf(f1 * 0.8 + f2 * 0.2, 0.0, 1.0)
	return clampi(int(f * float(total)) % maxi(1, total), 0, maxi(0, total - 1))

func _edge_tile(t: int, s: Dictionary, x: int, y: int) -> int:
	# Collect all directions where neighbor differs
	var cardinal_diff: Array = []
	var diagonal_diff: Array = []
	for d in ["N", "S", "E", "W"]:
		if s[d] != -1 and s[d] != t:
			cardinal_diff.append(d)
	for d in ["NE", "NW", "SE", "SW"]:
		if s[d] != -1 and s[d] != t:
			diagonal_diff.append(d)

	# Try cardinal rules first
	for d in cardinal_diff:
		var neighbor: int = s[d]
		var spec: Dictionary = _get_rule(t, d, neighbor)
		if not spec.is_empty():
			# The grass rules give v0r4 ("soil"). On a grass edge that is an
			# "inset square" — we normalise the variant to the green family.
			if t == 0 and int(spec.get("variant", -1)) in [0, 2, 3]:
				spec = {"file": 1, "variant": 13, "row": int(spec.get("row", 4))}
			return AlmLoader.tile_from_spec(_spec_for_type(t, spec))

	# Try diagonal rules
	for d in diagonal_diff:
		var neighbor: int = s[d]
		var spec: Dictionary = _get_rule(t, d, neighbor)
		if not spec.is_empty():
			return AlmLoader.tile_from_spec(_spec_for_type(t, spec))

	# No rule found — use interior
	return _interior_tile(t, x, y)

## file from a rule -> file for type A encoding (.alm)
## Now palette stores the correct file, no remap is needed.
func _spec_for_type(type_a: int, spec: Dictionary) -> Dictionary:
	var out := spec.duplicate(true)
	out["variant"] = int(spec.get("variant", 0))
	out["row"] = int(spec.get("row", 0))
	# For types >=4: overwrite file through TERRAIN_FILE
	if type_a >= 4:
		out["file"] = int(TERRAIN_FILE.get(type_a, out["file"]))
	return out

func _pick_height(x: int, y: int, t: int, field_value: float) -> int:
	# Pseudo-height: the noise field defines BOTH the terrain AND the height.
	# Water is always low, mountains high, the rest — medium with variation.
	match t:
		2: # Water: 0-15 (always low)
			return int(round(clampf(field_value * 15.0, 0.0, 15.0)))
		1: # Mountains: 40-127 (high peaks)
			var lo: float = _water_thr
			var hi: float = 1.0
			var span: float = maxf(0.0001, hi - lo)
			var u: float = clampf((field_value - lo) / span, 0.0, 1.0)
			return int(round(clampf(40.0 + u * 87.0, 40.0, 127.0)))
		0: # Grass: 10-60 (hills)
			var lo: float = _water_thr
			var hi: float = _mountain_thr
			var span: float = maxf(0.0001, hi - lo)
			var u: float = clampf((field_value - lo) / span, 0.0, 1.0)
			return int(round(clampf(10.0 + u * 50.0, 10.0, 60.0)))
		4: # Soil: 10-50 (medium)
			var lo: float = _water_thr
			var hi: float = _mountain_thr
			var span: float = maxf(0.0001, hi - lo)
			var u: float = clampf((field_value - lo) / span, 0.0, 1.0)
			return int(round(clampf(10.0 + u * 40.0, 10.0, 50.0)))
		5: # Sand: 5-35 (lowland)
			var lo: float = _water_thr
			var hi: float = _mountain_thr
			var span: float = maxf(0.0001, hi - lo)
			var u: float = clampf((field_value - lo) / span, 0.0, 1.0)
			return int(round(clampf(5.0 + u * 30.0, 5.0, 35.0)))
		6: # Mud: 8-33 (swamp)
			var lo: float = _water_thr
			var hi: float = _mountain_thr
			var span: float = maxf(0.0001, hi - lo)
			var u: float = clampf((field_value - lo) / span, 0.0, 1.0)
			return int(round(clampf(8.0 + u * 25.0, 8.0, 33.0)))
		3: # Road: interpolation from the neighbours
			return _interpolate_road_height(x, y)
		_: # The rest: medium
			return int(round(clampf(field_value * 60.0, 10.0, 60.0)))

func _interpolate_road_height(x: int, y: int) -> int:
	# Road: the average of the neighbouring non-road cells.
	var sum := 0.0
	var cnt := 0
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nx: int = x + d.x
		var ny: int = y + d.y
		if nx < 0 or ny < 0 or nx >= W or ny >= H:
			continue
		var nt: int = _terrain[ny * W + nx]
		if nt != 3:
			sum += float(_heights[ny * W + nx])
			cnt += 1
	if cnt > 0:
		return int(round(sum / float(cnt)))
	# No neighbours — take it from field
	return int(round(clampf(_field[y * W + x] * 40.0, 10.0, 40.0)))

func _smooth_nonroad_heights() -> void:
	var source := _heights.duplicate()
	for y in range(H):
		for x in range(W):
			var i: int = y * W + x
			if _terrain[i] == 3:
				continue
			var sum := 0.0
			var count := 0
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var nx: int = x + dx
					var ny: int = y + dy
					if nx < 0 or ny < 0 or nx >= W or ny >= H:
						continue
					var ni: int = ny * W + nx
					if _terrain[ni] == 3:
						continue
					sum += float(source[ni])
					count += 1
			if count > 0:
				_heights[i] = clampi(int(round(sum / float(count))), 0, 127)

func _box_blur(field: PackedFloat32Array) -> PackedFloat32Array:
	# Light smoothing (3×3): keeps the winding of the shore, removing only
	# single noise pixel artefacts.
	var out: PackedFloat32Array = field.duplicate()
	for y in range(H):
		for x in range(W):
			var sum := 0.0
			var cnt := 0
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var nx: int = x + dx
					var ny: int = y + dy
					if nx < 0 or ny < 0 or nx >= W or ny >= H:
						continue
					sum += field[ny * W + nx]
					cnt += 1
			out[y * W + x] = sum / float(cnt)
	return out

# === Saving ===

func _save() -> void:
	DirAccess.make_dir_recursive_absolute(_out_dir)
	var path: String = _out_dir + _basename + ".alm"
	var data: PackedByteArray = _write_alm()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("ERROR: " + path)
		return
	f.store_buffer(data)
	f.close()
	var m: Dictionary = AlmLoader.load_map(path)
	if not m.is_empty():
		print("OK: %dx%d, tiles=%d, heights=%d" % [
			int(m["width"]), int(m["height"]),
			int(m["tiles"].size()), int(m["heights"].size()),
		])
		# Statistics
		var tc := {}
		for i in range(W * H):
			var tt: int = _terrain[i]
			tc[tt] = tc.get(tt, 0) + 1
		var total: float = W * H
		var terrain_parts: Array = []
		var terrain_names := {0: "трава", 1: "горы", 2: "вода", 3: "дорога", 4: "почва", 5: "песок", 6: "грязь"}
		for tt in terrain_names:
			var cnt: int = tc.get(tt, 0)
			if cnt > 0:
				terrain_parts.append("%s=%.1f%%" % [terrain_names[tt], cnt * 100.0 / total])
		print("Terrain: " + ", ".join(terrain_parts))
		print("Shapes: exact=%d subset=%d rules-fallback=%d transitions=%d" % [
			_stat_exact, _stat_subset, _stat_rules, _stat_transition])
		_road_stats(tc.get(3, 0))
		var obj_count := 0
		for v in _obstacles:
			if v > 0:
				obj_count += 1
		print("Объектов: %d (%.1f%%)" % [obj_count, obj_count * 100.0 / total])
		# Spawn via sidecars (buildings + NPC)
		_save_sidecars()
		_validate_city_content()
		var guards := 0
		var citizens := 0
		var greys := 0
		for n in _npcs_out:
			match str(n.get("role", "")):
				"guard": guards += 1
				"citizen": citizens += 1
				_: greys += 1
		print("Спавн: зданий=%d НПЦ=%d (стражи=%d жители=%d серые=%d) трав=%d" % [
			_structures_out.size(), _npcs_out.size(), guards, citizens, greys, _herbs_out.size()])
	else:
		print("ERROR load_map")
	print("Сохранено: " + path)
	_report(100, 12)

## Spawn sidecars: structures and NPCs (loaded by alm_map.gd/_load_sidecars).
func _save_sidecars() -> void:
	var f := FileAccess.open(_out_dir + _basename + ".structures.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"structures": _structures_out}))
		f.close()
	var n := FileAccess.open(_out_dir + _basename + ".npcs.json", FileAccess.WRITE)
	if n:
		# gen_version — so ensure_map regenerates the map after a change
		# to the generation settings (density, gaps, spacing). See GEN_VERSION.
		n.store_string(JSON.stringify({"npcs": _npcs_out, "gen_version": GEN_VERSION}))
		n.close()
	var h := FileAccess.open(_out_dir + _basename + ".herbs.json", FileAccess.WRITE)
	if h:
		# City centres travel with the herbs so the wild rule can be verified
		# without re-reading the .alm tiles: a tier 3-4 herb must lie away from
		# every city (see _in_wild / herb_zones_smoke).
		var centers: Array = []
		for city in _cities:
			var pos: Vector2i = city.get("pos", Vector2i.ZERO)
			centers.append({"x": pos.x, "y": pos.y})
		h.store_string(JSON.stringify({"herbs": _herbs_out, "cities": centers}))
		h.close()
	# Outposts (package B): a separate sidecar so the game knows WHOSE camps are on
	# the map and how many guards are left before capture.
	var o := FileAccess.open(_out_dir + _basename + ".outposts.json", FileAccess.WRITE)
	if o:
		o.store_string(JSON.stringify({"outposts": _outposts_out}))
		o.close()
	# Undergrowth cells stay passable; the map editor writes the same sidecar by
	# hand ("Allow passage"), so the loader already understands it.
	if not _allowwalk_out.is_empty():
		var w := FileAccess.open(_out_dir + _basename + ".allowwalk.json", FileAccess.WRITE)
		if w:
			w.store_string(JSON.stringify(_allowwalk_out))
			w.close()

func _validate_city_content() -> void:
	var required := ["shop", "inn", "blacksmith", "train", "druidshop"]
	var missing: Array = []
	for prefix in required:
		var count := 0
		for structure in _structures_out:
			var folder := str(StructureDB.get_by_id(int(structure.get("type_id", 0))).get("folder", ""))
			if folder.begins_with(prefix):
				count += 1
		if count < _cities.size():
			missing.append("%s=%d/%d" % [prefix, count, _cities.size()])
	print("CITY_CONTENT: missing=%s" % str(missing))

func _road_stats(road_cells: int) -> void:
	# Road connectivity components (4-neighbour)
	var seen := {}
	var comps: Array = []
	for y in range(H):
		for x in range(W):
			var idx: int = y * W + x
			if seen.has(idx) or _terrain[idx] != 3:
				continue
			var size := 0
			var st: Array = [Vector2i(x, y)]
			seen[idx] = true
			while not st.is_empty():
				var p: Vector2i = st.pop_back()
				size += 1
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var n: Vector2i = p + d
					if n.x < 0 or n.y < 0 or n.x >= W or n.y >= H:
						continue
					var nk: int = n.y * W + n.x
					if seen.has(nk) or _terrain[nk] != 3:
						continue
					seen[nk] = true
					st.push_back(n)
			comps.append(size)
	comps.sort()
	comps.reverse()
	# bbox of the main component and the road width
	var main_bbox := Rect2i()
	var main_flat := 0
	var width_cnt := {}
	var adj_cnt := {}
	if not comps.is_empty():
		var ms := 0
		for y in range(H):
			for x in range(W):
				var idx: int = y * W + x
				if _terrain[idx] != 3:
					continue
				if ms == 0:
					main_bbox = Rect2i(Vector2i(x, y), Vector2i(1, 1))
					ms = 1
				else:
					if x < main_bbox.position.x:
						main_bbox.position.x = x
					if y < main_bbox.position.y:
						main_bbox.position.y = y
					if x - main_bbox.position.x + 1 > main_bbox.size.x:
						main_bbox.size.x = x - main_bbox.position.x + 1
					if y - main_bbox.position.y + 1 > main_bbox.size.y:
						main_bbox.size.y = y - main_bbox.position.y + 1
		# width: how many road cells in a bbox column (horizontal route) or row
		for y in range(main_bbox.position.y, main_bbox.position.y + main_bbox.size.y):
			var cnt := 0
			for x in range(main_bbox.position.x, main_bbox.position.x + main_bbox.size.x):
				if _terrain[y * W + x] == 3:
					cnt += 1
			if cnt > 0:
				width_cnt[cnt] = width_cnt.get(cnt, 0) + 1
				main_flat += cnt
		# adjacency: the share of road neighbours by terrain
		for y in range(H):
			for x in range(W):
				var idx: int = y * W + x
				if _terrain[idx] != 3:
					continue
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var n: Vector2i = Vector2i(x, y) + d
					if n.x < 0 or n.y < 0 or n.x >= W or n.y >= H:
						continue
					var nt: int = _terrain[n.y * W + n.x]
					if nt != 3 and nt != -1:
						adj_cnt[nt] = adj_cnt.get(nt, 0) + 1
	print("ROAD: cells=%d comps=%s bbox=%s widths=%s adj=%s" % [
		road_cells, str(comps), str(main_bbox), str(width_cnt), str(adj_cnt)])

func _write_alm() -> PackedByteArray:
	# The full writer is now a single one — in AlmLoader (the map editor calls it too).
	return AlmLoader.build_map_bytes(W, H, _tiles, _heights, _obstacles, _map_name)
