extends SceneTree
##
## СТОРОЖ: ни одного мёртвого ключа в game.cfg (03.10).
##
## ЗАЧЕМ
## -----
## Замер 03.10: из 132 ключей `GameConfig.DEFAULTS` 12 не читался НИ ОДНИМ
## файлом — ни `.gd`, ни `.py`. Ключ выглядел как рабочая настройка, но
## подкрутка ничего не меняла. Хуже всего: игрок настраивает скорость или
## интервал автосейва, ничего не происходит, и это выглядит как баг движка.
##
## ЭТО НЕ ГРЕП «ключ где-то используется», а проверка СВЯЗАННОСТИ: ключ
## обязан быть назван в коде. Ключи дизайна зон лежат в одной секции
## (`zone_design.start.gray_count_min`) и читаются по КОРОТКОМУ имени через
## `GameConfig.designi(zone, "gray_count_min")`. Первый замер этого теста считал
## по полным именам и выдал «94 мёртвых ключа» — это была ложь, полные имена
## в коде просто не встречаются.
##
## ЗАПУСК
## ------
## godot --headless --path . --script res://tests/config_dead_keys_smoke.gd
##

const CFG_SRC := "res://scripts/game_config.gd"

## Ключи, которые разрешено не читать из кода: заготовки под будущие фичи.
## Для них обязателен комментарий-обоснование в game_config.gd.
const ALLOWED_DEAD := {
	"metal.absorption_min": "ссылается только тест game_config_smoke",
	"metal.absorption_max": "ссылается только тест game_config_smoke",
	"loot.enemy_potion_chance": "шансы зверей/гуманоидов в loot_tables.json (пакет A)",
	"loot.enemy_gear_chance": "шансы зверей/гуманоидов в loot_tables.json (пакет A)",
}

const SKIP_DIRS := ["addons/", ".godot/", ".git/"]

var _checks := 0
var _fails: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
	print(("  OK  " if ok else "  FAIL") + " " + msg)


## Все .gd и .py проекта, кроме самого game_config.gd (он и есть источник ключей).
func _code_corpus() -> Dictionary:
	var out := {}
	_walk("res://", out)
	out.erase(CFG_SRC)
	return out


func _walk(dir_path: String, out: Dictionary) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := dir_path.path_join(name)
		if dir.current_is_dir():
			var skip := false
			for s in SKIP_DIRS:
				if (full + "/").contains(s):
					skip = true
					break
			if not skip:
				_walk(full, out)
		elif name.ends_with(".gd") or name.ends_with(".py"):
			var f := FileAccess.open(full, FileAccess.READ)
			if f != null:
				out[full] = f.get_as_text()
				f.close()
		name = dir.get_next()
	dir.list_dir_end()


func _run() -> void:
	print("-- ключи из DEFAULTS --")
	if not FileAccess.file_exists(CFG_SRC):
		_check(false, "game_config.gd на месте")
		_report()
		return
	var src := FileAccess.get_file_as_string(CFG_SRC)
	# Ключи достаём построчно, но по ВСЕМ совпадениям в строке: строка вида
	#   "start.gray_count_min": 6,     "start.gray_count_max": 10,
	# содержит ДВА ключа, и первый вариант теста брал только один — 93 вместо 140.
	# Регулярку с отступом сознательно не используем: "\t" в строке GDScript
	# экранируется так, что класс [\\t] становится «обратный слэш или буква t».
	var keys := PackedStringArray()
	var section := ""
	var rx := RegEx.new()
	rx.compile('"([a-z_][a-z_0-9.]*)"\\s*:')
	var sec_rx := RegEx.new()
	sec_rx.compile('"([a-z_]+)"\\s*:\\s*\\{')
	for line in src.split("\n"):
		var sm := sec_rx.search(line)
		if sm != null:
			section = str(sm.get_string(1))
			continue
		for r in rx.search_all(line):
			var name := str(r.get_string(1))
			# Ключи зон уже несут свою зону в имени ("start.gray_count_min"),
			# префикс секции им не нужен — иначе было бы "zone.start.xxx".
			var full := name if name.contains(".") else "%s.%s" % [section, name]
			if not keys.has(full):
				keys.append(full)
	_check(keys.size() > 100, "ключи найдены в DEFAULTS (%d)" % keys.size())

	var corpus := _code_corpus()
	print("  просканировано файлов: %d" % corpus.size())
	_check(corpus.size() > 20, "код просканирован достаточно широко")

	print("-- мёртвые ключи --")
	var dead: Array[String] = []
	for k in keys:
		# Зональные ключи читаются по короткому имени (designi/_zone, "gray_count_min"),
		# поэтому ищем именно короткое имя, а не полное "mid.gray_count_min".
		var short := k.split(".")[-1]
		var found := false
		for path in corpus:
			if (corpus[path] as String).contains('"%s"' % short):
				found = true
				break
		if found:
			continue
		if ALLOWED_DEAD.has(k):
			continue
		dead.append(k)
	if dead.is_empty():
		_check(true, "мёртвых ключей нет (кроме %d разрешённых заготовок)"
				% ALLOWED_DEAD.size())
	else:
		for k in dead:
			_check(false, "ключ %s не читается кодом" % k)
		_check(false, "всего мёртвых ключей: %d — добавь потребителя или ALLOWED_DEAD" % dead.size())

	_report()


func _report() -> void:
	print("RESULT: %s config_dead_keys_smoke (проверок: %d, провалов: %d)"
			% ["OK" if _fails.is_empty() else "FAIL", _checks, _fails.size()])
	for f in _fails:
		print("  FAIL " + f)
	quit(0 if _fails.is_empty() else 1)