extends SceneTree
## Localization coverage guard (12.11).
##
## `loc_smoke` proves that every key in assets/locale/ui.json has both languages
## and that the main menu follows the switch. It says nothing about the strings
## that never reach `Loc` at all, and those are exactly why the English mode of
## the game still shows Russian: 60+ files carry Russian literals inline.
##
## This guard does not translate anything. It freezes the current debt per file
## (tests/loc_baseline.json) and fails when:
##   1. a file carries MORE Russian literals than its baseline;
##   2. a file that had none starts carrying them.
##
## A shrinking count never fails: that is the work being done. Regenerate the
## baseline after a stage of localization:
##
##   godot --headless --path . --script res://tests/loc_coverage_smoke.gd -- --loc-update
##
## What is counted: string literals (double or single quoted) that contain
## Cyrillic and are NOT debug output. `print`/`push_error`/`push_warning`
## messages are excluded on purpose: they never reach the player, they are their
## own (English-only) convention, and mixing them in would hide the real number
## behind log noise.
##
## What is NOT counted, and cannot be by a static scan: strings that come from
## data (units_db, item_db, spells, cities, journal, lore) and text built at
## runtime. Those are tracked by their own guard once the data layer gets
## `name_en` fields.
##
## Dev tools (map editor and friends) are out of scope by the player's decision:
## the map editor is not shipped.

const BASELINE_PATH := "res://tests/loc_baseline.json"
## Direct reads of the Russian data columns, tracked separately: see _check_data_refs.
const DATA_REF_BASELINE := "res://tests/loc_data_refs_baseline.json"
const DATA_REF_NEEDLES := ['.get("ru"', ".get(\"name_ru\"", '["ru"]', '["name_ru"]']
const SCAN_ROOT := "scripts"
## Player-facing scope only. The map editor is an internal tool and is not
## translated; listing it here keeps its 155 literals out of the report.
const DEV_TOOLS := [
	"map_editor.gd",
	"custom_map.gd",
	"map_validator.gd",
	"texture_settings.gd",
]
## Lines that carry debug output: excluded from the count.
const DEBUG_CALLS := ["push_error", "push_warning", "print", "printerr", "assert"]

## Cyrillic ranges: the main block, plus the two supplement ranges.
const CYRILLIC_RANGES := [[0x0400, 0x04FF], [0x0500, 0x052F], [0x2DE0, 0x2DFF], [0xA640, 0xA69F]]

var _fails: Array[String] = []
var _checks := 0
var _update := false


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--loc-update":
			_update = true
	if _update:
		_write_baseline()
		quit(0)
		return
	_run()


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
		print("LOC: FAIL %s" % what)


func _run() -> void:
	var counts := _scan_all()
	var baseline := _read_baseline()
	_check(baseline.size() > 0, "базовая линия %s не прочитана" % BASELINE_PATH)

	var grown: Array[String] = []
	var appeared: Array[String] = []
	var shrank: Array[String] = []
	var total := 0
	for path in counts:
		var now := int(counts[path])
		total += now
		if not baseline.has(path):
			if now > 0:
				appeared.append("%s (%d)" % [path, now])
			continue
		var was := int(baseline[path])
		if now > was:
			grown.append("%s: %d -> %d" % [path, was, now])
		elif now < was:
			shrank.append("%s: %d -> %d" % [path, was, now])
	for path in baseline:
		if not counts.has(path) and int(baseline[path]) > 0:
			shrank.append("%s: %d -> 0 (file is gone)" % [path, int(baseline[path])])

	_check(grown.is_empty(), "русских литералов стало больше: %s" % str(grown))
	_check(appeared.is_empty(), "появились русские литералы в файлах без долга: %s" % str(appeared))
	if not shrank.is_empty():
		print("LOC: долг сократился: %s" % str(shrank))

	print("LOC: файлов с долгом %d, русских литералов всего %d" % [counts.size(), total])
	_check_data_refs()
	_finish()


## Direct reads of the Russian data columns. `get("ru")` and `get("name_ru")` are
## invisible to the Cyrillic scanner (the field NAME is ASCII), which is exactly
## how the spell book stayed Russian while every string "looked" localized.
## They must go through display_name() helpers; this guard freezes what is left.
func _check_data_refs() -> void:
	var counts := _scan_data_refs()
	var baseline := _read_json_map(DATA_REF_BASELINE)
	_check(baseline.size() > 0, "базовая линия прямых чтений %s" % DATA_REF_BASELINE)
	var grown: Array[String] = []
	var appeared: Array[String] = []
	var total := 0
	for path in counts:
		var now := int(counts[path])
		total += now
		if not baseline.has(path):
			appeared.append("%s (%d)" % [path, now])
			continue
		var was := int(baseline[path])
		if now > was:
			grown.append("%s: %d -> %d" % [path, was, now])
	for path in baseline:
		if not counts.has(path) and int(baseline[path]) > 0:
			pass
	_check(grown.is_empty(), "прямых чтений русских колонок стало больше: %s" % str(grown))
	_check(appeared.is_empty(), "появились прямые чтения name_ru/ru: %s" % str(appeared))
	print("LOC: прямых чтений name_ru/ru %d в %d файлах" % [total, counts.size()])


func _scan_data_refs() -> Dictionary:
	var files: Array[String] = []
	_collect(SCAN_ROOT, files)
	var counts := {}
	for path in files:
		if DEV_TOOLS.has(path.get_file()):
			continue
		var text := FileAccess.get_file_as_bytes(path).get_string_from_utf8()
		var found := 0
		for needle in DATA_REF_NEEDLES:
			found += text.count(needle)
		if found > 0:
			counts[path] = found
	return counts


func _finish() -> void:
	print("")
	if _fails.is_empty():
		print("RESULT: OK loc_coverage_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL loc_coverage_smoke (%d checks, %d fails)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)


func _scan_all() -> Dictionary:
	var files: Array[String] = []
	_collect(SCAN_ROOT, files)
	var counts := {}
	for path in files:
		var name := path.get_file()
		if DEV_TOOLS.has(name):
			continue
		var found := _count_literals(path)
		if found > 0:
			counts[path] = found
	return counts


func _collect(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full: String = dir_path.path_join(name)
		if dir.current_is_dir():
			_collect(full, out)
		elif name.get_extension().to_lower() == "gd":
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()


## Walks the source character by character, so that a `#` inside a string is not
## mistaken for a comment and a quote inside a comment does not open a string.
func _count_literals(path: String) -> int:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return 0
	var text := bytes.get_string_from_utf8()
	var total := 0
	var i := 0
	var n := text.length()
	var in_string := false
	var in_comment := false
	var in_block := false
	var quote := ""
	var buffer := ""
	var line_prefix := ""

	while i < n:
		var c := text[i]
		if c == "\n":
			in_comment = false
			line_prefix = ""
			i += 1
			continue
		if in_block:
			# Raw shader blocks: "..." -"..." hold no player text, but skipping
			# them keeps quotes inside the shader code from desynchronising us.
			if text.substr(i, 3) == '"""':
				in_block = false
				i += 3
			else:
				i += 1
			continue
		if not in_string:
			if in_comment:
				i += 1
				continue
			if c == "#":
				in_comment = true
				i += 1
				continue
			if text.substr(i, 3) == '"""':
				in_block = true
				i += 3
				continue
			if c == '"' or c == "'":
				in_string = true
				quote = c
				buffer = ""
				i += 1
				continue
			line_prefix += c
			i += 1
			continue
		# inside a string
		if c == "\\":
			buffer += c
			if i + 1 < n:
				buffer += text[i + 1]
			i += 2
			continue
		if c == quote:
			in_string = false
			if _has_cyrillic(buffer) and not _is_debug(line_prefix):
				total += 1
			i += 1
			continue
		buffer += c
		i += 1
	return total


func _is_debug(prefix: String) -> bool:
	for token in DEBUG_CALLS:
		if prefix.contains(token):
			return true
	return false


func _has_cyrillic(text: String) -> bool:
	for index in text.length():
		var code := text.unicode_at(index)
		for span in CYRILLIC_RANGES:
			if code >= int(span[0]) and code <= int(span[1]):
				return true
	return false


func _read_baseline() -> Dictionary:
	return _read_json_map(BASELINE_PATH)


func _read_json_map(path: String) -> Dictionary:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return {}
	var parsed = JSON.parse_string(bytes.get_string_from_utf8())
	if parsed is Dictionary:
		return parsed
	return {}


func _write_json_map(path: String, counts: Dictionary) -> void:
	var keys := counts.keys()
	keys.sort()
	var ordered := {}
	for key in keys:
		ordered[key] = counts[key]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("loc_coverage_smoke: не удалось записать %s" % path)
		return
	file.store_string(JSON.stringify(ordered, "\t", false, true) + "\n")
	file.close()


func _write_baseline() -> void:
	var counts := _scan_all()
	_write_json_map(BASELINE_PATH, counts)
	print("LOC: базовая линия обновлена, файлов %d" % counts.size())
	var refs := _scan_data_refs()
	_write_json_map(DATA_REF_BASELINE, refs)
	print("LOC: базовая линия прямых чтений обновлена, файлов %d" % refs.size())
