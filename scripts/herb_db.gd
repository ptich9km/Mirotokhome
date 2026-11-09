class_name HerbDB
extends RefCounted
## Herb table: `assets/professions/herbalism/herbs_db.json`.
##
## Single source of truth for herbalism. Before this file the herb list lived in
## map_generator (HERB_ITEMS) and the alchemy panel knew nothing about tiers or
## zones, so the same eight herbs grew in every biome at the same rate.
##
## Who reads what:
##   * map_generator  - `zone_pool()` + `icon_of()` when filling .herbs.json;
##   * herb_node      - `icon_of()`, `frames_of()`, `fps_of()`;
##   * alchemy_panel  - `tier_of()`, `grows_in()` for the "where does it grow" hint.
##
## The item itself (price, quality, name) still lives in item_db; this file is
## only about where the herb grows and how it is drawn.

const PATH := "res://assets/professions/herbalism/herbs_db.json"

static var _herbs: Dictionary = {}
static var _zones: Dictionary = {}
static var _wild_tier_min := 3
static var _wild_distance := 12
static var _loaded := false


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var parsed: Variant = _read_json()
	if not (parsed is Dictionary):
		return
	var doc: Dictionary = parsed
	var herbs: Variant = doc.get("herbs", {})
	if herbs is Dictionary:
		_herbs = herbs
	var zones: Variant = doc.get("zones", {})
	if zones is Dictionary:
		_zones = zones
	_wild_tier_min = int(doc.get("wild_tier_min", _wild_tier_min))
	_wild_distance = int(doc.get("wild_min_city_distance", _wild_distance))


## All herbs: key -> {tier, icon, frame_count, fps}.
static func all() -> Dictionary:
	ensure_loaded()
	return _herbs.duplicate(true)


static func keys() -> Array:
	ensure_loaded()
	return _herbs.keys()


static func has(key: String) -> bool:
	ensure_loaded()
	return _herbs.has(key)


static func tier_of(key: String) -> int:
	ensure_loaded()
	var record: Dictionary = _herbs.get(key, {})
	return int(record.get("tier", 0))


static func icon_of(key: String) -> String:
	ensure_loaded()
	var record: Dictionary = _herbs.get(key, {})
	return str(record.get("icon", ""))


static func frames_of(key: String) -> int:
	ensure_loaded()
	var record: Dictionary = _herbs.get(key, {})
	return maxi(1, int(record.get("frame_count", 1)))


static func fps_of(key: String) -> int:
	ensure_loaded()
	var record: Dictionary = _herbs.get(key, {})
	return int(record.get("fps", 0))


## Weighted pool of a zone: [{item, weight}]. A copy - the caller may re-roll it.
static func zone_pool(zone: String) -> Array:
	ensure_loaded()
	var pool: Variant = _zones.get(zone, [])
	return (pool as Array).duplicate(true) if pool is Array else []


static func zones() -> Array:
	ensure_loaded()
	return _zones.keys()


## Zones where a herb can be found (for the panel hint).
static func grows_in(key: String) -> Array:
	var out: Array = []
	for zone in zones():
		for entry in zone_pool(str(zone)):
			if str((entry as Dictionary).get("item", "")) == key:
				out.append(str(zone))
				break
	return out


static func wild_tier_min() -> int:
	ensure_loaded()
	return _wild_tier_min


static func wild_min_city_distance() -> int:
	ensure_loaded()
	return _wild_distance


## Drops the cache. For tests and for a future "reload data without restart".
static func reload() -> void:
	_loaded = false
	_herbs.clear()
	_zones.clear()


static func _read_json() -> Variant:
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		push_error("HerbDB: cannot open " + PATH)
		return null
	var txt := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(txt) != OK:
		push_error("HerbDB: broken JSON in %s (line %d)" % [PATH, json.get_error_line()])
		return null
	return json.data
