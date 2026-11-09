extends SceneTree
## Herbs follow the zone (09.11 alchemy rework).
##
## Before this every map grew the same eight herbs in the same proportions, so
## a rare potion was gated by nothing. Now the generator picks from the zone
## pool of HerbDB, and tier 3-4 herbs appear only in the wild.
##
## Checked on real generated maps (one per zone):
##   1. every herb on the map belongs to that zone's pool;
##   2. start has no tier 3-4, hard has tier 3, faction has tier 4;
##   3. tier 3-4 herbs lie at least `wild_min_city_distance` cells from every
##      city centre (the cities travel in the .herbs.json sidecar);
##   4. the map still has a reasonable amount of herbs.
##
## Run: godot --headless --path . --script res://tests/herb_zones_smoke.gd

const DIR := "user://maps/"
const SIDECAR := ".herbs.json"
const MIN_HERBS := 30

var _fails: Array[String] = []
var _checks := 0


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print("HERBS: %s %s" % ["ok  " if ok else "FAIL", what])


func _initialize() -> void:
	HerbDB.ensure_loaded()
	DirAccess.make_dir_recursive_absolute(DIR)
	call_deferred("_run")


func _run() -> void:
	var wild_limit := HerbDB.wild_min_city_distance()
	var seeds := {"start": 7301, "mid": 7302, "hard": 7303, "faction": 7304}
	for zone in seeds:
		var path: String = MapGenerator.new().generate(int(seeds[zone]), str(zone), DIR)
		_check(path != "", "[%s] карта сгенерирована" % str(zone))
		if path == "":
			continue
		_check_zone(str(zone), path.get_basename() + SIDECAR, wild_limit)
	_finish()


func _check_zone(zone: String, sidecar: String, wild_limit: int) -> void:
	if not FileAccess.file_exists(sidecar):
		_check(false, "[%s] %s существует" % [zone, sidecar.get_file()])
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(sidecar))
	if not (parsed is Dictionary):
		_check(false, "[%s] %s — валидный JSON" % [zone, sidecar.get_file()])
		return
	var doc: Dictionary = parsed
	var herbs: Array = doc.get("herbs", [])
	var cities: Array = doc.get("cities", [])
	_check(herbs.size() >= MIN_HERBS, "[%s] трав не меньше %d (%d)" % [zone, MIN_HERBS, herbs.size()])
	_check(not cities.is_empty(), "[%s] в sidecar есть центры городов" % zone)

	# 1. Only herbs of this zone's pool.
	var pool: Dictionary = {}
	for entry in HerbDB.zone_pool(zone):
		pool[str((entry as Dictionary).get("item", ""))] = true
	var foreign: Array[String] = []
	var tiers: Dictionary = {}
	for raw in herbs:
		var key := str((raw as Dictionary).get("item", ""))
		tiers[HerbDB.tier_of(key)] = int(tiers.get(HerbDB.tier_of(key), 0)) + 1
		if not pool.has(key):
			foreign.append(key)
	_check(foreign.is_empty(), "[%s] все травы из пула зоны (%s)" % [zone, str(foreign)])

	# 2. Tier expectations per zone.
	if zone == "start":
		_check(not tiers.has(3) and not tiers.has(4), "[%s] нет трав тира 3-4 (%s)" % [zone, str(tiers)])
	if zone == "hard":
		_check(int(tiers.get(3, 0)) > 0, "[%s] есть травы тира 3 (%s)" % [zone, str(tiers)])
	if zone == "faction":
		_check(int(tiers.get(4, 0)) > 0, "[%s] есть травы тира 4 (%s)" % [zone, str(tiers)])

	# 3. Rare herbs live in the wild.
	var near_city: Array[String] = []
	for raw in herbs:
		var record: Dictionary = raw
		var key := str(record.get("item", ""))
		if HerbDB.tier_of(key) < HerbDB.wild_tier_min():
			continue
		var cell := Vector2i(int(record.get("x", -1)), int(record.get("y", -1)))
		for raw_city in cities:
			var city: Dictionary = raw_city
			var centre := Vector2i(int(city.get("x", -1)), int(city.get("y", -1)))
			var distance := maxi(absi(cell.x - centre.x), absi(cell.y - centre.y))
			if distance < wild_limit:
				near_city.append("%s@%s d=%d" % [key, str(cell), distance])
				break
	_check(near_city.is_empty(),
		"[%s] редкие травы не ближе %d клеток к городу (%s)" % [zone, wild_limit, str(near_city)])


func _finish() -> void:
	print("")
	if _fails.is_empty():
		print("RESULT: OK herb_zones_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL herb_zones_smoke (%d checks, %d fails)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)
