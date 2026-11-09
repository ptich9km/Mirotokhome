extends SceneTree
## Source encoding guard (09.11).
##
## The alchemy panel came back from a PowerShell round-trip double-encoded: the
## file was read as CP1251 and written back as UTF-8, so every Russian label
## turned into "РђР›РҐР?РњР?РЇ" on screen. Nothing failed: the file was valid
## UTF-8, the scripts parsed and every test passed - the damage was visible only
## in the game. This guard exists so that cannot happen again silently.
##
## Two HARD signatures (a failure):
##   1. the file is not valid UTF-8 (the byte round-trip must return the same
##      size; a UTF-8 BOM is dropped by the engine, so it is discounted);
##   2. it contains U+0098 - CP1251 has no glyph for byte 0x98, so a CP1251
##      misread leaves exactly this control character behind.
##
## One SOFT signature (printed, not a failure): U+FFFD. The repository already
## carries 14 of them from earlier bad saves (see the 2026-10 journal entry about
## `Set-Content -Encoding UTF8`), and they cannot be restored without guessing
## the lost letters. New ones will show up in the report.
##
## Scope: code, data and docs; binary art is skipped. This is a guard against an
## editor/tool breaking a file, not a validator of strings built at runtime.
##
## Run: godot --headless --path . --script res://tests/source_encoding_smoke.gd

const ROOTS := ["scripts", "tests", "ui", "assets", "docs", "addons"]
const TRACKED_EXTENSIONS := ["gd", "json", "cfg", "md", "txt", "tscn", "tres", "shader", "gdshader", "py", "ps1"]
const ROOT_FILES := ["AGENTS.md", "README.md", "README.dev.md", "MODDING.md"]
## Known U+FFFD count in the repository. A larger number means a NEW loss and
## deserves a look; the number only ever goes down when someone repairs a file.
const KNOWN_REPLACEMENT := 14

var _fails: Array[String] = []
var _checks := 0


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
		print("ENCODING: FAIL %s" % what)


func _initialize() -> void:
	var files: Array[String] = []
	for root in ROOTS:
		_collect(root, files)
	for name in ROOT_FILES:
		if FileAccess.file_exists(name):
			files.append(name)
	var bad_utf8: Array[String] = []
	var bad_chars: Array[String] = []
	var replacements := 0
	for path in files:
		var result := _scan(path)
		if result.get("utf8", false):
			bad_utf8.append(path)
		if int(result.get("u0098", -1)) >= 0:
			bad_chars.append("%s (позиция %d)" % [path, int(result["u0098"])])
		replacements += int(result.get("fffd_count", 0))
	_check(files.size() > 300, "проверено файлов: %d" % files.size())
	_check(bad_utf8.is_empty(), "невалидный UTF-8: %s" % str(bad_utf8))
	_check(bad_chars.is_empty(),
		"следы двойной перекодировки CP1251 -> UTF-8 (U+0098): %s" % str(bad_chars))
	_check(replacements <= KNOWN_REPLACEMENT,
		"потерянных символов U+FFFD: %d (было известно %d)" % [replacements, KNOWN_REPLACEMENT])
	if replacements != KNOWN_REPLACEMENT:
		print("ENCODING: note: U+FFFD = %d, ожидалось %d" % [replacements, KNOWN_REPLACEMENT])
	_finish()


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
		elif TRACKED_EXTENSIONS.has(name.get_extension().to_lower()):
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()


func _scan(path: String) -> Dictionary:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return {}
	var text := bytes.get_string_from_utf8()
	var expected := bytes.size()
	if bytes.size() >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF:
		expected -= 3      # the engine drops the BOM when decoding
	var result := {}
	if text.to_utf8_buffer().size() != expected:
		result["utf8"] = true
	var index := text.find(String.chr(0x98))
	if index >= 0:
		result["u0098"] = index
	result["fffd_count"] = _count_char(text, 0xFFFD)
	return result


func _count_char(text: String, code: int) -> int:
	var total := 0
	var index := text.find(String.chr(code))
	while index >= 0:
		total += 1
		index = text.find(String.chr(code), index + 1)
	return total


func _finish() -> void:
	print("")
	if _fails.is_empty():
		print("RESULT: OK source_encoding_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL source_encoding_smoke (%d checks, %d fails)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)
