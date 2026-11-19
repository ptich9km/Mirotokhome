extends SceneTree
## Undergrowth smoke test (14.11): the four small props that fill the poor
## biomes must exist as data, be placed by the generator by biome, be written
## into the .allowwalk.json sidecar, and stay passable - a fern is decor, not a
## wall. Trees, by contrast, must still block.
##
## Run: godot --headless --path . --script res://tests/undergrowth_smoke.gd

const SEED := 5150
const ZONE := "mid"
const OUT_DIR := "user://maps/undergrowth_smoke/"
const DET_DIR := "user://maps/undergrowth_smoke/det/"
## IDs 212..215 and the folders they point at (alm_objects.json).
const CLUTTER_IDS := [212, 213, 214, 215]
const CLUTTER_FOLDERS := ["mushroom_cluster", "fern", "dry_bush", "aloe"]
## Terrain the undergrowth may stand on: grass, soil, sand, mud.
const LAND := [0, 4, 5, 6]
const TREE_ID_MIN := 200
const TREE_ID_MAX := 211

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print("CLUTTER: %s %s" % ["ok  " if ok else "FAIL", what])


func _run() -> void:
	_test_data()
	var path: String = MapGenerator.new().generate(SEED, ZONE, OUT_DIR)
	if path == "" or not FileAccess.file_exists(path):
		_check(false, "map generated")
		_finish()
		return
	_check(true, "map generated")
	var base := path.get_basename()
	_test_placement(path, base)
	await _test_walkability(path, base)
	_test_determinism()
	_finish()


## 1. Data: id -> folder -> sprite -> canvas -> HP. A prop without any of these
## is an invisible or unbreakable hole in the map.
func _test_data() -> void:
	var alm := _json("res://assets/map-objects/alm_objects.json")
	var odb := _json("res://assets/map-objects/object_db.json")
	var hp := _json("res://assets/map-objects/destructibles.json")
	for i in range(CLUTTER_IDS.size()):
		var id := int(CLUTTER_IDS[i])
		var folder := str(CLUTTER_FOLDERS[i])
		var rec: Dictionary = alm.get(str(id), {})
		_check(not rec.is_empty(), "alm_objects has %s (id %d)" % [folder, id])
		_check(str(rec.get("folder", "")) == folder,
			"id %d points at %s (got %s)" % [id, folder, str(rec.get("folder", ""))])
		var sprite := "res://assets/map-objects/%s/sprites-001.png" % folder
		_check(FileAccess.file_exists(sprite), "%s has a sprite" % folder)
		var o: Dictionary = odb.get(folder, {})
		_check(not o.is_empty(), "object_db has %s" % folder)
		_check(int(o.get("w", 0)) == int(rec.get("w", -1)),
			"%s canvas width matches alm_objects" % folder)
		_check(int(o.get("h", 0)) == int(rec.get("h", -1)),
			"%s canvas height matches alm_objects" % folder)
		_check(int(o.get("cy", 0)) == int(rec.get("h", 0)),
			"%s is anchored to the bottom of its canvas" % folder)
		_check(int(hp.get(folder, 0)) > 0, "%s has HP in destructibles.json" % folder)
	# Mushrooms are drawn at half size (player report 20.11): three 48 px caps
	# read as a bush, not as undergrowth. The canvas stays 48 so the anchor,
	# the .alm footprint and the sidecars do not move.
	var mushrooms: Dictionary = odb.get("mushroom_cluster", {})
	_check(is_equal_approx(float(mushrooms.get("scale", 1.0)), 0.5),
		"mushroom_cluster is drawn at half size (scale=%s)"
			% str(mushrooms.get("scale", 1.0)))


## 2. Placement: the sidecar lists exactly the clutter cells, all of them on
## land, and more than one kind of undergrowth reaches the map.
func _test_placement(path: String, base: String) -> void:
	var data := AlmLoader.load_map(path)
	var obstacles: PackedByteArray = data.get("obstacles", PackedByteArray())
	var tiles: PackedInt32Array = data.get("tiles", PackedInt32Array())
	var w := int(data.get("width", 0))
	var allow := _read_allow(base)
	_check(allow.size() > 0, "the .allowwalk.json sidecar is written (%d cells)" % allow.size())
	var by_id := {}
	var bad_id := 0
	var bad_land := 0
	for pair in allow:
		var i := int(pair[1]) * w + int(pair[0])
		if i < 0 or i >= obstacles.size():
			bad_id += 1
			continue
		var oid := int(obstacles[i])
		if not CLUTTER_IDS.has(oid):
			bad_id += 1
			continue
		by_id[oid] = int(by_id.get(oid, 0)) + 1
		if not LAND.has(_terrain_of(int(tiles[i]))):
			bad_land += 1
	_check(bad_id == 0, "every sidecar cell holds a clutter id (%d bad)" % bad_id)
	_check(bad_land == 0, "every clutter cell stands on land (%d bad)" % bad_land)
	_check(by_id.size() >= 2, "more than one kind of undergrowth is placed (%s)" % str(by_id))
	var trees := 0
	for o in obstacles:
		if int(o) >= TREE_ID_MIN and int(o) <= TREE_ID_MAX:
			trees += 1
	# A separate pass must not eat the forest: trees stay the bulk of the map.
	_check(trees > allow.size(),
		"trees outnumber undergrowth (%d vs %d)" % [trees, allow.size()])


## 3. Passability on a live AlmMap: through a fern, not through an oak.
func _test_walkability(path: String, base: String) -> void:
	var alm := AlmMap.new()
	alm.alm_path = path
	root.add_child(alm)
	await process_frame
	await process_frame
	var allow := _read_allow(base)
	var walked := 0
	var blocked := 0
	for pair in allow:
		var pos := Vector2((int(pair[0]) + 0.5) * alm.TILE, (int(pair[1]) + 0.5) * alm.TILE)
		if alm.is_walkable_world(pos):
			walked += 1
		else:
			blocked += 1
	_check(blocked == 0 and walked > 0,
		"a unit walks through undergrowth (%d walkable, %d blocked)" % [walked, blocked])

	# The same check in the other direction: a tree cell is still a wall.
	var data := AlmLoader.load_map(path)
	var obstacles: PackedByteArray = data.get("obstacles", PackedByteArray())
	var w := int(data.get("width", 0))
	var allow_set := {}
	for pair in allow:
		allow_set[Vector2i(int(pair[0]), int(pair[1]))] = true
	var tree_cell := Vector2i(-1, -1)
	for i in range(obstacles.size()):
		var oid := int(obstacles[i])
		if oid >= TREE_ID_MIN and oid <= TREE_ID_MAX:
			var cell := Vector2i(i % w, i / w)
			if allow_set.has(cell):
				continue
			tree_cell = cell
			break
	_check(tree_cell.x >= 0, "a tree cell was found for the control check")
	# The mushrooms are drawn at half size in the LIVE scene (player report
	# 20.11): the data says 0.5 and the sprite on the map must actually scale.
	var mushroom_id := int(CLUTTER_IDS[0])
	var mushroom_cell := Vector2i(-1, -1)
	for i in range(obstacles.size()):
		if int(obstacles[i]) == mushroom_id:
			mushroom_cell = Vector2i(i % w, i / w)
			break
	_check(mushroom_cell.x >= 0, "a mushroom cluster is on the map")
	if mushroom_cell.x >= 0:
		var ob: Node = alm._obstacle_nodes.get(mushroom_cell)
		_check(ob != null and is_equal_approx(float(ob.get("draw_scale")), 0.5),
			"the mushroom obstacle carries the draw scale 0.5")
		var spr: Node = ob.get_node_or_null("Sprite") if ob != null else null
		_check(spr != null and is_equal_approx((spr as Sprite2D).scale.x, 0.5),
			"the mushroom sprite is drawn at half size")
	if tree_cell.x >= 0:
		var pos := Vector2((tree_cell.x + 0.5) * alm.TILE, (tree_cell.y + 0.5) * alm.TILE)
		_check(not alm.is_walkable_world(pos), "a tree cell stays impassable")
	alm.queue_free()
	await process_frame


## 4. Determinism: the sidecar is part of the map, so the same seed must give
## the same undergrowth. Otherwise players with the same seed see different maps.
func _test_determinism() -> void:
	DirAccess.make_dir_recursive_absolute(DET_DIR)
	var a: String = MapGenerator.new().generate(SEED, ZONE, DET_DIR)
	var b: String = MapGenerator.new().generate(SEED, ZONE, DET_DIR)
	_check(a != "" and b != "", "both determinism maps generated")
	if a == "" or b == "":
		return
	var sa := JSON.stringify(_read_allow(a.get_basename()))
	var sb := JSON.stringify(_read_allow(b.get_basename()))
	_check(sa != "[]" and sa == sb, "the same seed gives the same undergrowth")


## Terrain type of a .alm tile. Biome tiles store it in the file nibble, while a
## transition tile keeps the OWNER biome in bits 12..15 (`terrain_type` expects an
## hflags byte, not a tile code - that mix-up cost one red run).
func _terrain_of(tile: int) -> int:
	if AlmLoader.is_transition_tile(tile):
		return (tile >> 12) & 0xF
	return AlmLoader.tile_type(tile)


func _read_allow(base: String) -> Array:
	var p := base + ".allowwalk.json"
	if not FileAccess.file_exists(p):
		return []
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return []
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Array else []


func _json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


func _finish() -> void:
	print("")
	if _fails.is_empty():
		print("RESULT: OK undergrowth_smoke (%d checks)" % _checks)
	else:
		for f in _fails:
			print("  - %s" % f)
		print("RESULT: FAIL undergrowth_smoke (%d checks, %d fails)"
			% [_checks, _fails.size()])
	quit(0 if _fails.is_empty() else 1)
