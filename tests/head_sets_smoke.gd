extends SceneTree
## City-head sprite sets (quest givers), 11.11.
##
## WHAT THIS IS. Every town has a head: the NPC with the "head" role that holds
## the quests and carries the "!" marker. Since 11.11 the heads have their own art
## (city_<race>_head/t0) built from the saved mage idle drawing by
## tests/gen_head_sets.py: one static frame per world octant, three extra races as
## palette swaps (orc / necro / druid).
##
## WHAT IT CHECKS.
## 1. The four sets are in units_db with the static 8-direction contract.
## 2. MapGenerator.race_of_set() still reads the race out of the set name -- the
##    head set is named ..._head, and before 11.11 only _mage/_warrior were stripped,
##    so a head set returned an empty race (tooltip "Passer-by", race tests blind).
## 3. Every frame loads, is 64x64, has a 52-60 px figure standing on the ground,
##    does not touch the canvas edge and carries no magenta leftovers.
## 4. The races really differ: the face colours of the four down-facing frames are
##    pairwise distinct.
##
## Run:
##   godot --headless --path . --script res://tests/head_sets_smoke.gd

const RACES := {
	"city_human_head/t0": "humans",
	"city_ork_head/t0": "ork",
	"city_necro_head/t0": "necro",
	"city_druid_head/t0": "druid",
}
const FRAMES := 8
const CELL_W := 52
const CELL_H := 64
## Face box of the down-facing frame: rows 6..24, columns 18..34.
const FACE := Rect2i(18, 6, 16, 18)

var _checks := 0
var _fails: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print("HEADSET: %s %s" % ["ok  " if ok else "FAIL", what])


func _run() -> void:
	for set_name in RACES:
		_entry_checks(set_name)
		_frames_checks(set_name)
	_race_checks()
	_distinct_checks()
	_report()


func _entry_checks(set_name: String) -> void:
	_check(UnitDB.has(set_name), "%s is in units_db" % set_name)
	if not UnitDB.has(set_name):
		return
	var want := {
		"frames": FRAMES, "dirs": 8, "idle_phases": 0, "move": 1,
		"attack": 0, "dying": 0, "decay": 0, "blocks": 1,
		"w": CELL_W, "h": CELL_H, "cx": 26, "cy": 62,
	}
	var bad: Array[String] = []
	for k in want:
		var got: Variant = UnitDB.get_set(set_name).get(k, null)
		if int(got) != int(want[k]):
			bad.append("%s=%s (want %d)" % [k, str(got), int(want[k])])
	_check(bad.is_empty(), "%s contract: %s" % [
		set_name, "ok" if bad.is_empty() else ", ".join(bad)])


func _frames_checks(set_name: String) -> void:
	if not UnitDB.has(set_name):
		return
	var count := UnitDB.frame_count(set_name)
	_check(count == FRAMES, "%s: %d frames (want %d)" % [set_name, count, FRAMES])
	var folder := str(UnitDB.get_set(set_name).get("folder", set_name))
	var prefix := UnitDB.frame_prefix(set_name)
	var sizes_ok := true
	var figure_ok := true
	var ground_ok := true
	var edge_ok := true
	var magenta_ok := true
	var heights: Array[int] = []
	for i in range(FRAMES):
		var path := UnitDB.frame_path(folder, prefix, i + 1)
		var tex: Texture2D = load(path)
		if tex == null:
			_check(false, "%s frame %d does not load (%s)" % [set_name, i + 1, path])
			return
		if tex.get_width() != CELL_W or tex.get_height() != CELL_H:
			sizes_ok = false
		var img: Image = tex.get_image()
		var r := _content_rect(img)
		if r.size.y < 52.0 or r.size.y > 60.0:
			figure_ok = false
		heights.append(int(r.size.y))
		if r.position.y + r.size.y < 58.0:
			ground_ok = false
		if r.position.x <= 0.0 or r.position.x + r.size.x >= CELL_W or r.position.y <= 0.0:
			edge_ok = false
		if _has_magenta(img):
			magenta_ok = false
	_check(sizes_ok, "%s: every frame is %dx%d" % [set_name, CELL_W, CELL_H])
	_check(figure_ok, "%s: figure is 52-60 px tall (%s)" % [set_name, str(heights)])
	_check(ground_ok, "%s: feet stand on the ground of the cell" % set_name)
	_check(edge_ok, "%s: nothing is cut by the canvas edge" % set_name)
	_check(magenta_ok, "%s: no magenta leftovers in the alpha" % set_name)


## Opaque content of a frame (alpha > 40), the same threshold the cutter uses.
func _content_rect(img: Image) -> Rect2i:
	var x0 := CELL_W
	var y0 := CELL_H
	var x1 := -1
	var y1 := -1
	for y in range(CELL_H):
		for x in range(CELL_W):
			if img.get_pixel(x, y).a8 > 40:
				x0 = mini(x0, x)
				y0 = mini(y0, y)
				x1 = maxi(x1, x)
				y1 = maxi(y1, y)
	if x1 < 0:
		return Rect2i()
	return Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1)


## A leftover keying fringe: strongly "magenta" (min(R,B) - G) on a visible pixel.
func _has_magenta(img: Image) -> bool:
	for y in range(CELL_H):
		for x in range(CELL_W):
			var c := img.get_pixel(x, y)
			if c.a8 <= 40:
				continue
			var m: float = minf(c.r8, c.b8) - c.g8
			if m > 90.0:
				return true
	return false


func _race_checks() -> void:
	for set_name in RACES:
		var want := str(RACES[set_name])
		var got := MapGenerator.race_of_set(set_name)
		_check(got == want, "race_of_set(%s) = %s (want %s)" % [set_name, got, want])
	# Regression: the old role suffixes must keep working.
	_check(MapGenerator.race_of_set("city_human_mage/t1") == "humans",
		"race_of_set(city_human_mage/t1) still humans")
	_check(MapGenerator.race_of_set("city_ork_warrior/t0") == "ork",
		"race_of_set(city_ork_warrior/t0) still ork")
	_check(MapGenerator.race_of_set("city_necro_mage/t3") == "necro",
		"race_of_set(city_necro_mage/t3) still necro")
	_check(MapGenerator.race_of_set("monsters/wolf") == "",
		"a non-city set has no city race")
	# The generator must spawn exactly these sets as heads.
	var heads: Array[String] = []
	for race in MapGenerator.CITY_POPULATION:
		heads.append(str(MapGenerator.CITY_POPULATION[race].get("head", "")))
	var missing: Array[String] = []
	for set_name in heads:
		if not UnitDB.has(set_name):
			missing.append(set_name)
	_check(missing.is_empty(), "CITY_POPULATION heads exist in units_db (missing: %s)"
		% (str(missing) if not missing.is_empty() else "none"))
	_check(heads.size() == RACES.size(), "four races have four heads (%d)" % heads.size())


## Face colour per race, measured on the down-facing frame: the palette swaps must
## be visible, not just present in the database. Only the brighter 60% of the face
## box is averaged: otherwise the hair fringe and the robe collar, which are not
## recoloured per race, flatten the difference (human vs necro fell to 0.09).
func _distinct_checks() -> void:
	var faces := {}
	for set_name in RACES:
		faces[set_name] = _face_color(set_name)
	var keys: Array = faces.keys()
	for i in range(keys.size()):
		for j in range(i + 1, keys.size()):
			var a: Color = faces[keys[i]]
			var b: Color = faces[keys[j]]
			var dist: float = Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()
			_check(dist > 0.08, "faces differ: %s vs %s (%.2f)" % [keys[i], keys[j], dist])
	# The in-game report was "the orc's face is only half green": the skin mask left
	# a band of the face untouched. A per-pixel comparison against the human set is
	# the honest guard -- an average colour can look different while half the face
	# is still peach.
	var human := "city_human_head/t0"
	for set_name in RACES:
		if set_name == human:
			continue
		var same := _same_face_fraction(human, set_name)
		_check(same < 0.25, "%s: only %.0f%% of the face kept the human colour"
			% [set_name, same * 100.0])


## Fraction of the face box that is pixel-identical to the reference set: the skin
## ramp did not touch those pixels at all.
func _same_face_fraction(reference: String, set_name: String) -> float:
	var a := _face_image(reference)
	var b := _face_image(set_name)
	if a == null or b == null:
		return 1.0
	var same := 0
	var total := 0
	for y in range(FACE.position.y, FACE.position.y + FACE.size.y):
		for x in range(FACE.position.x, FACE.position.x + FACE.size.x):
			var ca: Color = a.get_pixel(x, y)
			var cb: Color = b.get_pixel(x, y)
			if ca.a8 <= 40:
				continue
			total += 1
			if absf(ca.r - cb.r) <= 0.024 and absf(ca.g - cb.g) <= 0.024 \
					and absf(ca.b - cb.b) <= 0.024:
				same += 1
	if total == 0:
		return 1.0
	return float(same) / float(total)


## Down-facing frame of a set as an Image, or null.
func _face_image(set_name: String) -> Image:
	if not UnitDB.has(set_name):
		return null
	var folder := str(UnitDB.get_set(set_name).get("folder", set_name))
	var tex: Texture2D = load(UnitDB.frame_path(folder, UnitDB.frame_prefix(set_name), 1))
	return tex.get_image() if tex != null else null


func _face_color(set_name: String) -> Color:
	if not UnitDB.has(set_name):
		return Color(0, 0, 0, 0)
	var folder := str(UnitDB.get_set(set_name).get("folder", set_name))
	var tex: Texture2D = load(UnitDB.frame_path(folder, UnitDB.frame_prefix(set_name), 1))
	if tex == null:
		return Color(0, 0, 0, 0)
	var img: Image = tex.get_image()
	var pixels: Array[Color] = []
	var lums: Array[float] = []
	for y in range(FACE.position.y, FACE.position.y + FACE.size.y):
		for x in range(FACE.position.x, FACE.position.x + FACE.size.x):
			var c := img.get_pixel(x, y)
			if c.a8 <= 40:
				continue
			pixels.append(c)
			lums.append(0.299 * c.r + 0.587 * c.g + 0.114 * c.b)
	if pixels.is_empty():
		return Color(0, 0, 0, 0)
	var sorted_lums := lums.duplicate()
	sorted_lums.sort()
	var cut: float = sorted_lums[int(sorted_lums.size() * 0.4)]
	var acc := Color(0, 0, 0, 0)
	var n := 0
	for i in range(pixels.size()):
		if lums[i] < cut:
			continue
		acc.r += pixels[i].r
		acc.g += pixels[i].g
		acc.b += pixels[i].b
		n += 1
	if n == 0:
		return Color(0, 0, 0, 0)
	return Color(acc.r / n, acc.g / n, acc.b / n, 1.0)


func _report() -> void:
	print("HEADSET: RESULT: %s (%d checks, %d failed)"
		% ["OK" if _fails.is_empty() else "FAIL", _checks, _fails.size()])
	quit(0)


