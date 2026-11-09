extends SceneTree
##
## Смок звуковой библиотеки: индекс `assets/audio/sound_db.json` против кода.
##
## Проверяет:
##   1. индекс читается, ключи и файлы на месте;
##   2. каждый файл грузится как AudioStream и имеет ненулевую длину;
##   3. каждый ключ из `SoundDB.play("...")` и `spells_db.json` есть в индексе;
##   4. числовых ID Аллодов в коде не осталось;
##   5. шины из индекса входят в разрешённый набор.
##
## Запуск: godot --headless --path . --script res://tests/audio_smoke.gd
## Результат: RESULT: OK audio_smoke (N проверок)

const DB_PATH := "res://assets/audio/sound_db.json"
const SFX_ROOT := "res://assets/audio/sfx/"
const BUSES := ["Music", "SFX", "UI", "Voice", "Ambient"]
const SPELLS_DB := "res://assets/spells/spells_db.json"

var _checks := 0
var _fails: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
	print(("  OK  " if ok else "  FAIL") + " " + msg)


func _run() -> void:
	print("-- audio_smoke --")
	var keys := _load_db()
	_check(keys.size() >= 50, "ключей в индексе: %d" % keys.size())

	var used: Array[String] = []
	used.append_array(_keys_from_scripts())
	used.append_array(_keys_from_spells())
	_check(used.size() >= 40, "ключей используется в коде/базе: %d" % used.size())
	for key in used:
		_check(keys.has(key), "ключ используется и существует: " + key)

	var total := 0
	for key in keys:
		var entry: Dictionary = keys[key]
		var bus := str(entry.get("bus", ""))
		_check(bus in BUSES, "%s: шина %s" % [key, bus])
		var files: Array = entry.get("files", [])
		_check(not files.is_empty(), "%s: есть файлы" % key)
		for rel in files:
			total += 1
			var path := SFX_ROOT + str(rel)
			_check(FileAccess.file_exists(path), "%s: файл на месте (%s)" % [key, rel])
			var stream: Variant = load(path)
			_check(stream is AudioStream, "%s: грузится как AudioStream" % key)
			if stream is AudioStream:
				var length := (stream as AudioStream).get_length()
				_check(length > 0.03, "%s: длина %.3f с" % [key, length])
				if key.begins_with("ui."):
					_check(length < 4.0, "%s: UI короче 4 с" % key)
	_check(total >= 150, "файлов в индексе: %d" % total)

	# Числовые ID Аллодов не должны остаться ни в одном скрипте.
	var numeric := _numeric_plays()
	_check(numeric.is_empty(), "числовых SoundDB.play(...): %d" % numeric.size())
	for n in numeric:
		print("      " + n)

	_check_music()

	_check_voice_cast()

	# Живая проверка очереди: старт с первого, повторный старт не сбрасывает,
	# next_track() двигает индекс.
	_check(MusicDB.start_playlist(), "MusicDB: плейлист запущен")
	await create_timer(0.2).timeout
	_check(MusicDB.current_index() == 0, "MusicDB: старт с трека 0")
	_check(MusicDB.current_file() == "menu_main.ogg", "MusicDB: первый файл — menu_main")
	_check(MusicDB.start_playlist(), "MusicDB: повторный старт — ok")
	await create_timer(0.2).timeout
	_check(MusicDB.current_index() == 0, "MusicDB: повторный старт не сбросил очередь")
	_check(MusicDB.next_track(), "MusicDB: next_track() ok")
	await create_timer(0.2).timeout
	_check(MusicDB.current_index() == 1, "MusicDB: next_track() дал трек 1")
	_check(MusicDB.current_file() == "town_rest_1.ogg", "MusicDB: второй файл — town_rest_1")
	MusicDB.stop(0.1)
	await create_timer(0.2).timeout

	if _fails.is_empty():
		print("RESULT: OK audio_smoke (%d проверок)" % _checks)
		quit(0)
	else:
		print("RESULT: FAIL audio_smoke (%d проверок, %d провалов)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
		quit(1)


func _load_db() -> Dictionary:
	var f := FileAccess.open(DB_PATH, FileAccess.READ)
	if f == null:
		_check(false, "не открыть " + DB_PATH)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		_check(false, "индекс не JSON-объект")
		return {}
	var k: Variant = (parsed as Dictionary).get("keys", {})
	if not (k is Dictionary):
		_check(false, "в индексе нет keys")
		return {}
	_check(true, "индекс прочитан")
	return k


func _gd_files(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full := dir_path.path_join(name)
		if dir.current_is_dir():
			out.append_array(_gd_files(full))
		elif name.ends_with(".gd"):
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()
	return out


func _keys_from_scripts() -> Array[String]:
	var out: Array[String] = []
	var re := RegEx.new()
	re.compile('SoundDB\\.play\\("([^"]+)"')
	for path in _gd_files("res://scripts"):
		var text := FileAccess.get_file_as_string(path)
		for m in re.search_all(text):
			var key := m.get_string(1)
			if "%" in key:  # формат-строка вида "voice.%s.1" проверяется по индексу
				continue
			if not out.has(key):
				out.append(key)
	out.sort()
	return out


func _keys_from_spells() -> Array[String]:
	var out: Array[String] = []
	var f := FileAccess.open(SPELLS_DB, FileAccess.READ)
	if f == null:
		return out
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return out
	for name in parsed:
		var entry: Variant = (parsed as Dictionary)[name]
		if entry is Dictionary:
			var key := str((entry as Dictionary).get("sound", ""))
			_check(key != "" and key.begins_with("magic."), "%s: звук задан ключом" % name)
			if key != "" and not out.has(key):
				out.append(key)
	out.sort()
	return out


func _numeric_plays() -> Array[String]:
	var out: Array[String] = []
	var re := RegEx.new()
	re.compile('SoundDB\\.play\\(\\s*[0-9]')
	for path in _gd_files("res://scripts"):
		var text := FileAccess.get_file_as_string(path)
		for m in re.search_all(text):
			out.append(path + ": " + m.get_string(0))
	return out


## Voice cast: every race has its own takes and unknown races fall back to the
## base key, so a new race can never silence an inn or a shop.
func _check_voice_cast() -> void:
	var keys := _load_db()
	var npc := 0
	for key in keys:
		if str(key).begins_with("voice.npc."):
			npc += 1
	_check(npc == 40, "голосов НПЦ по расам: %d" % npc)
	for race in ["ork", "necro", "druid"]:
		_check(SoundDB.raced_key("voice.npc.merchant", race, 1)
			== "voice.npc.merchant.%s.1" % race, "торговец %s: свой ключ" % race)
		_check(SoundDB.raced_key("voice.npc.inn", race, 2)
			== "voice.npc.inn.%s.2" % race, "трактирщик %s: свой ключ" % race)
	_check(SoundDB.raced_key("voice.npc.inn", "human", 1) == "voice.npc.inn.1",
		"люди: базовый ключ")
	_check(SoundDB.raced_key("voice.npc.inn", "", 1) == "voice.npc.inn.1",
		"без расы: базовый ключ")
	_check(SoundDB.raced_key("voice.npc.inn", "dwarf", 1) == "voice.npc.inn.1",
		"неизвестная раса: базовый ключ")
	var attack: Dictionary = keys.get("voice.hero.male.attack.1", {})
	var takes: Array = attack.get("files", [])
	_check(takes.size() == 3, "у удара героя дублей: %d" % takes.size())
	var jitter := float(attack.get("pitch_jitter", 0.0))
	_check(jitter > 0.0, "у героя есть pitch_jitter: %.2f" % jitter)
	var npc_jitter := float((keys.get("voice.npc.inn.ork.1", {}) as Dictionary)
		.get("pitch_jitter", 0.0))
	_check(npc_jitter == 0.0, "у НПЦ без дрожания тона: %.2f" % npc_jitter)


## Музыка: непрерывный плейлист. Файлы существуют, грузятся, длинные,
## без лупа (иначе очередь не пойдёт дальше), порядок начинается с темы меню.
func _check_music() -> void:
	var f := FileAccess.open("res://assets/audio/music_db.json", FileAccess.READ)
	if f == null:
		_check(false, "не открыть music_db.json")
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		_check(false, "music_db.json не JSON-объект")
		return
	var db := parsed as Dictionary
	_check(int(db.get("version", 0)) == 2, "music_db.json: версия 2")
	_check(str(db.get("bus", "")) == "Music", "music_db.json: шина Music")
	_check(float(db.get("crossfade", 0.0)) > 0.0, "music_db.json: кроссфейд задан")
	var playlist: Variant = db.get("playlist", [])
	if not (playlist is Array) or (playlist as Array).is_empty():
		_check(false, "в music_db.json нет playlist")
		return
	var list := playlist as Array
	_check(list.size() == 8, "в плейлисте 8 треков (сейчас %d)" % list.size())
	_check(str(list[0]) == "menu_main.ogg", "плейлист начинается с menu_main.ogg")
	var seen: Dictionary = {}
	for rel in list:
		var name := str(rel)
		_check(not seen.has(name), "%s: без дублей" % name)
		seen[name] = true
		var path := "res://assets/audio/music/" + name
		_check(FileAccess.file_exists(path), "%s: файл на месте" % name)
		var stream: Variant = load(path)
		_check(stream is AudioStream, "%s: грузится" % name)
		if stream is AudioStream:
			_check((stream as AudioStream).get_length() > 150.0,
				"%s: длиннее 150 с" % name)
		if stream is AudioStreamOggVorbis:
			# MusicDB выключает луп при запуске; проверяем, что он не включён
			# и в самом импортированном ресурсе.
			_check(not (stream as AudioStreamOggVorbis).loop, "%s: луп выключен" % name)

	# Старого механизма «ключ на ситуацию» в коде быть не должно.
	var re := RegEx.new()
	re.compile('MusicDB\\.play\\(')
	for path in _gd_files("res://scripts"):
		var text := FileAccess.get_file_as_string(path)
		_check(re.search(text) == null, "нет MusicDB.play в " + path.get_file())
