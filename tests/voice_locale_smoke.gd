extends SceneTree
## English voice-over and dialogue subtitles.
##
## Player's rule: the English build must not answer in Russian. Two halves are
## checked here — the takes (voice.en.* keys, files on disk, a real different
## recording, not a copy of the Russian one) and the subtitles (ui.talk.* keys
## with both languages), plus the runtime switch `SoundDB.localized_key`.
##
## Run: godot --headless --path . --script res://tests/voice_locale_smoke.gd
## Result: RESULT: OK voice_locale_smoke checks=N

const LINES := "res://assets/audio/voice_lines.json"
const DB := "res://assets/audio/sound_db.json"
const UI := "res://assets/locale/ui.json"
const SFX := "res://assets/audio/sfx/"
const MERCHANT_KEYS := 4
const INN_KEYS := 6

var _checks := 0
var _fails: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
	print(("  OK   " if ok else "  FAIL ") + msg)


func _json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed


func _run() -> void:
	await process_frame
	_data()
	_keys()
	_files()
	_runtime_switch()
	_subtitles()
	_report()


func _data() -> void:
	print("-- данные --")
	var cfg: Variant = _json(LINES)
	_check(cfg is Dictionary, "voice_lines.json читается")
	if not (cfg is Dictionary):
		return
	var d := cfg as Dictionary
	_check(int(d.get("version", 0)) >= 3, "voice_lines версии 3 (двуязычная)")
	var lines: Array = d.get("lines", [])
	var no_en := 0
	for line in lines:
		if str((line as Dictionary).get("text_en", "")) == "":
			no_en += 1
	_check(lines.size() == 22 and no_en == 0,
		"у всех %d реплик есть text_en (без перевода: %d)" % [lines.size(), no_en])
	var cast: Dictionary = d.get("cast", {})
	var no_speaker := 0
	for role in cast:
		var sp := str((cast[role] as Dictionary).get("speaker_en", ""))
		if not sp.begins_with("en_"):
			no_speaker += 1
	_check(no_speaker == 0, "у всех %d ролей есть английский голос en_*" % cast.size())


func _keys() -> void:
	print("-- ключи --")
	var db: Variant = _json(DB)
	if not (db is Dictionary):
		_check(false, "sound_db.json читается")
		return
	var keys: Dictionary = (db as Dictionary).get("keys", {})
	var ru: Array[String] = []
	var en: Array[String] = []
	for k in keys:
		var key := str(k)
		if key.begins_with("voice.en."):
			en.append(key)
		elif key.begins_with("voice."):
			ru.append(key)
	_check(ru.size() == 52, "русских голосовых ключей 52 (сейчас %d)" % ru.size())
	_check(en.size() == ru.size(),
		"английских ключей столько же (сейчас %d)" % en.size())
	var missing: Array[String] = []
	for key in ru:
		var want := "voice.en." + key.substr("voice.".length())
		if not keys.has(want):
			missing.append(want)
	_check(missing.is_empty(), "у каждого русского ключа есть английский (%d нет)"
		% missing.size())


func _files() -> void:
	print("-- файлы --")
	var db: Variant = _json(DB)
	var keys: Dictionary = (db as Dictionary).get("keys", {})
	var absent := 0
	var same_as_ru := 0
	var en_count := 0
	var total := 0
	for k in keys:
		var key := str(k)
		if not key.begins_with("voice.en."):
			continue
		en_count += 1
		var entry: Dictionary = keys[key]
		var files: Array = entry.get("files", [])
		var ru_entry: Dictionary = keys.get("voice." + key.substr("voice.en.".length()), {})
		var ru_files: Array = ru_entry.get("files", [])
		for rel in files:
			total += 1
			if not ResourceLoader.exists(SFX + str(rel)):
				absent += 1
			if ru_files.has(rel):
				same_as_ru += 1
	_check(en_count > 0, "английские ключи есть: %d" % en_count)
	_check(absent == 0, "все %d английских файлов на месте (нет: %d)" % [total, absent])
	_check(same_as_ru == 0, "английские дубли — отдельные записи, не русские")


func _runtime_switch() -> void:
	print("-- переключение языка --")
	var saved := Loc.locale()
	Loc.set_locale("ru")
	_check(SoundDB.localized_key("voice.npc.inn.3") == "voice.npc.inn.3",
		"по-русски берётся русский ключ")
	Loc.set_locale("en")
	_check(SoundDB.localized_key("voice.npc.inn.3") == "voice.en.npc.inn.3",
		"по-английски — английский ключ")
	_check(SoundDB.localized_key("voice.npc.inn.ork.3") == "voice.en.npc.inn.ork.3",
		"расовый дубль тоже переключается")
	_check(SoundDB.localized_key("voice.hero.female.attack.2")
		== "voice.en.hero.female.attack.2", "реплики героини переключаются")
	_check(SoundDB.localized_key("voice.en.npc.inn.3") == "voice.en.npc.inn.3",
		"уже английский ключ не префиксуется дважды")
	_check(SoundDB.localized_key("combat.weapon.sword") == "combat.weapon.sword",
		"не голосовые ключи не трогаются")
	_check(SoundDB.localized_key("voice.nope.missing") == "voice.nope.missing",
		"неизвестный ключ остаётся собой (без падения)")
	Loc.set_locale(saved)


func _subtitles() -> void:
	print("-- субтитры --")
	var ui: Variant = _json(UI)
	if not (ui is Dictionary):
		_check(false, "ui.json читается")
		return
	var table := ui as Dictionary
	var cyr := 0
	for i in range(1, MERCHANT_KEYS + 1):
		var key := "ui.talk.merchant.%d" % i
		_check(Loc.has_key(key) and Loc.entry_complete(key), "ключ %s полный" % key)
		if _has_cyrillic(Loc.text_in(key, "en")):
			cyr += 1
	for i in range(1, INN_KEYS + 1):
		var key := "ui.talk.inn.%d" % i
		_check(Loc.has_key(key) and Loc.entry_complete(key), "ключ %s полный" % key)
		if _has_cyrillic(Loc.text_in(key, "en")):
			cyr += 1
	for key in ["ui.talk.merchant.line", "ui.talk.inn.line",
			"ui.talk.inn.party_full", "ui.talk.inn.no_gold", "ui.talk.inn.hired"]:
		_check(Loc.has_key(key) and Loc.entry_complete(key), "ключ %s полный" % key)
	_check(cyr == 0, "в английских субтитрах нет кириллицы (%d)" % cyr)
	# The line shown must be English when the UI is English.
	Loc.set_locale("en")
	var shown := Loc.f("ui.talk.inn.line", [Loc.t("ui.talk.inn.1")])
	Loc.set_locale("ru")
	_check(shown.contains("gate watch"), "английский субтитр собирается (%s)" % shown)
	_check(not _has_cyrillic(shown), "в собранном английском субтитре нет кириллицы")
	_check(table.size() > 300, "таблица ui.json не пустая (%d ключей)" % table.size())


func _has_cyrillic(s: String) -> bool:
	for i in s.length():
		var c := s.unicode_at(i)
		if (c >= 0x0400 and c <= 0x04FF) or c == 0x0451 or c == 0x0401:
			return true
	return false


func _report() -> void:
	print()
	if _fails.is_empty():
		print("RESULT: OK voice_locale_smoke checks=%d" % _checks)
		quit(0)
	else:
		print("RESULT: FAIL voice_locale_smoke checks=%d fails=%d"
			% [_checks, _fails.size()])
		for m in _fails:
			print("  - %s" % m)
		quit(1)
