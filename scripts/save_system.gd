class_name SaveSystem
extends RefCounted
## Сохранения: слоты, автосейв, версионирование, атомарная запись.
##
## Статический класс, НАМЕРЕННО без autoload — добавление autoload в
## project.godot это approval gate (AGENTS §9.4), а оно тут не нужно:
## все методы статические, состояния у класса нет.
##
## Формат (решение игрока 22.10): КАЖДЫЙ слот — своя папка
## `user://saves/<слот>/` с тремя элементами прогресса:
##   hero.json    — герой: класс, статы, HP/мана, золото, склад, экипировка,
##                  навыки, позиция;
##   map.json     — карта: зона, сид, туман, плюс файлы мира текущей карты
##                  (`*.alm`, `.npcs.json`, `.structures.json`, `.herbs.json`,
##                  `.portal.json`, `.spawn.json`, `.nowalk.json`,
##                  `.allowwalk.json`) — карта ложится в сохранение байт-в-байт,
##                  поэтому после перезапуска игры это та же самая карта;
##   process.json — прогресс: мир SIM, события, квесты, метаданные слота
##                  (имя, класс, уровень, день, время записи).
## Каждый элемент пишется атомарно (.tmp → flush → rename), прежние версии
## файлов уходят в `.bak`. При удалении игроком папка становится пустой:
## остаются только эти три файла, пустые по содержимому.
##
## Версия в `version` внутри каждого элемента; элемент новее текущего
## отклоняется целиком, а не «читается как есть» — иначе битые/чужие данные
## молча портят игровое состояние.
##
## v2 (28.10): в hero появились `party` (наёмники) и `hotbar` (клавиши 1..9).
## Оба поля опциональны: сейв v1 читается без миграции — пустой отряд и пустой
## хотбар это ровно то, что было в v1, где их не сохраняли вовсе.

const DIR := "user://saves/"
const VERSION := 2
## Где живут сохранения. Этот каталог НЕ должен трогать ни один прогон тестов
## или инструментов: все сценарии (headless-тесты, `--path` на ту же
## установку, копии проекта) используют один и тот же `user://`
## (`%APPDATA%/Godot/app_userdata/<config/name>`), поэтому тест, трогавший
## слоты, стирал живые сохранения игрока (жалоба 22.10: «сохранения видны,
## пока не закроешь игру» — тест перетирал их при закрытии окна).
## Тесты и инструменты пишут только в `TEST_DIR` (см. `use_test_dir()`).
static var _dir := DIR

## Элементы сохранения внутри папки слота.
const HERO_FILE := "hero.json"
const MAP_FILE := "map.json"
const PROCESS_FILE := "process.json"
const PARTS := [HERO_FILE, MAP_FILE, PROCESS_FILE]
## Снимок ПРЕДЫДУЩЕГО сохранения слота, взятый ДО перезаписи: полный документ
## того же вида, что отдаёт `load_slot()` (`{version, meta, data: {hero,
## map, world, events, quests}}`). Поэлементные `.bak` держат прежние версии
## отдельных файлов и мир в них разорван по трём элементам — восстановить
## «предыдущее сохранение» из них можно только склейкой. Снимок целый и
## пишется файлом, чтобы его мог прочитать и тест, и рука игрока.
const PREV_FILE := "previous.json"
## Файлы мира текущей карты: `.alm` и sidecar-ы, которые читает AlmMap
## (строки/НПЦ/травы/портал/спавн/разметка проходимости).
const WORLD_SUFFIXES := [
	".alm", ".npcs.json", ".structures.json", ".herbs.json",
	".portal.json", ".spawn.json", ".nowalk.json", ".allowwalk.json",
	".outposts.json", ".meta.json",
]


## Переключить хранение слотов на тестовый каталог. Вызывается ТОЛЬКО
## тестами (`tests/save_sandbox.gd`): живые сохранения остаются нетронутыми.
static func use_test_dir(path: String) -> void:
	_dir = path if path.ends_with("/") else path + "/"
	ensure_dir()


## Текущий каталог слотов: игровой `user://saves/` или тестовый.
static func dir() -> String:
	return _dir
## Игровых слотов для меню «Загрузить игру» (решение игрока 05.10: 6).
const SLOT_COUNT := 6
const AUTOSAVE_SLOT := "autosave"

## Слоты, которые показываются игроку.
const PLAYER_SLOTS := ["slot_0", "slot_1", "slot_2", "slot_3", "slot_4", "slot_5"]


static func ensure_dir() -> void:
	DirAccess.make_dir_recursive_absolute(_dir)


## Папка слота: внутри неё лежат hero.json / map.json / process.json и файлы
## мира текущей карты.
static func slot_dir(slot: String) -> String:
	return _dir + slot + "/"


# --- Пути ---

static func part_path(slot: String, part: String) -> String:
	return slot_dir(slot) + part


## Главный файл слота (герой). Прежнее имя одиночного файла сохранения.
static func slot_path(slot: String) -> String:
	return part_path(slot, HERO_FILE)


static func tmp_path(slot: String) -> String:
	return part_path(slot, "hero.json.tmp")


static func bak_path(slot: String) -> String:
	return bak_of(part_path(slot, HERO_FILE))


static func prev_path(slot: String) -> String:
	return part_path(slot, PREV_FILE)


static func bak_of(path: String) -> String:
	return path + ".bak"


# --- Запись ---

## Плоский payload старого формата (весь прогресс в одном блоке `data`, без
## `quests`/`world`) — так писали до 22.10 и так пишут инструменты, которым
## нужен только герой. Такой payload раскладывается по трём элементам
## обычным путём: отдельного «старое-карта» в слоте не остаётся.
static func _is_flat_payload(payload: Dictionary) -> bool:
	return not (payload.get("quests", null) is Dictionary) \
		and not (payload.get("world", null) is Dictionary)


## Записать слот. payload — словарь v1 (см. build_payload). Возвращает
## сообщение об ошибке или "" при успехе.
##
## Порядок: герой → прогресс → карта. Если запись карты упадёт (нет места на
## диске), в слоте останутся прежние карта и туман, а не полуновое состояние.
static func save(slot: String, payload: Dictionary) -> String:
	if not (payload.get("hero", null) is Dictionary) \
			or not (payload.get("map", null) is Dictionary):
		return "сохранение без блоков hero/map"
	if _is_flat_payload(payload):
		payload = payload.duplicate()
		payload["world"] = {"day": int((payload.get("meta", {}) as Dictionary).get("day", 0))}
		payload["events"] = []
		payload["quests"] = {}
	DirAccess.make_dir_recursive_absolute(slot_dir(slot))
	# Снимок прежнего состояния — ДО первой перезаписи элементов.
	_snapshot_previous(slot)
	var meta: Dictionary = payload.get("meta", {})
	var err := _write_part(slot, HERO_FILE, {"version": VERSION, "meta": meta,
		"data": JsonSafe.encode(payload.get("hero", {}))})
	if err != "":
		return err
	err = _write_part(slot, PROCESS_FILE, {"version": VERSION, "meta": meta,
		"data": JsonSafe.encode({
			"world": payload.get("world", {}),
			"events": payload.get("events", []),
			"quests": payload.get("quests", {}),
			"version": payload.get("version", VERSION),
		})})
	if err != "":
		return err
	return _save_map(slot, payload)


## Карта: описание в map.json и файлы мира рядом с ним (байт-в-байт).
static func _save_map(slot: String, payload: Dictionary) -> String:
	var map_info: Dictionary = payload.get("map", {})
	var err := _write_part(slot, MAP_FILE, {"version": VERSION,
		"meta": payload.get("meta", {}), "data": JsonSafe.encode(map_info)})
	if err != "":
		return err
	var map_path := str(map_info.get("path", ""))
	if map_path == "" or not FileAccess.file_exists(map_path):
		return ""
	return _mirror_world_files(slot, map_path, str(map_info.get("basename", "")))


## Скопировать файлы мира (`.alm` + sidecar-ы) из каталога карты в папку
## слота под стабильным именем `<basename>.…`; basename записан в map.json.
static func _mirror_world_files(slot: String, map_path: String, basename: String) -> String:
	var src_dir := map_path.get_base_dir()
	var src_base := map_path.get_file().get_basename()
	var dst_base := basename if basename != "" else src_base
	var dst_dir := slot_dir(slot)
	var copied := 0
	for raw_suffix in WORLD_SUFFIXES:
		var src: String = src_dir + "/" + src_base + str(raw_suffix)
		if not FileAccess.file_exists(src):
			continue
		var dst: String = dst_dir + dst_base + str(raw_suffix)
		if not _atomic_copy(src, dst):
			return "не удалось записать карту %s" % dst.get_file()
		copied += 1
	if copied == 0:
		return "файлы карты не найдены рядом с .alm (%s)" % src_dir
	return ""


# --- Чтение ---

## Положить текущее сохранение слота (если оно есть) в `previous.json`.
## Снимок — то же, что отдаёт `load_slot()`; если слот битый или пустой,
## снимок не трогаем: лучше старое целое, чем пустое.
static func _snapshot_previous(slot: String) -> void:
	var current := load_slot(slot)
	if current.is_empty() or current.has("error"):
		return
	# Снимок перезаписывать НЕЛЬЗЯ, если текущее сохранение читается ТОЛЬКО
	# из `previous.json` (все элементы сломаны): иначе он перетрётся
	# зеркалом того же снимка и слот станет невосстановимым.
	if not _parts_readable(slot):
		return
	_write_raw(prev_path(slot), JSON.stringify(JsonSafe.encode({
		"version": int((current.get("data", {}) as Dictionary).get("version", VERSION)),
		"meta": current.get("meta", {}),
		"data": current.get("data", {}),
	})))


## Оба главных элемента слота читаются сами по себе (без снимка).
static func _parts_readable(slot: String) -> bool:
	for part in [HERO_FILE, PROCESS_FILE]:
		var doc := _read_doc(part_path(slot, part))
		if doc.is_empty() or not (doc.get("data", null) is Dictionary):
			return false
	return true


## Прочитать слот. Пустой словарь — читать нечего. "version" — элемент
## новее текущего кода. "corrupt" — файл есть, но не читается, .bak не
## помог и снимка прежнего сохранения нет.
## data — сводка v1 (hero/map/world/events/quests), meta — метаданные слота.
static func load_slot(slot: String) -> Dictionary:
	var hero := _read_part(slot, HERO_FILE)
	if hero.is_empty() and FileAccess.file_exists(part_path(slot, HERO_FILE)):
		# Файл есть, а читать его нечем: пробуем снимок прежнего сохранения
		# и перечитываем — дальше путь один и тот же.
		if restore_from_previous(slot):
			hero = _read_part(slot, HERO_FILE)
	if hero.has("error"):
		return hero
	if hero.is_empty():
		return {"error": "corrupt"} if FileAccess.file_exists(part_path(slot, HERO_FILE)) \
			else {}
	var meta: Dictionary = hero.get("meta", {})
	if meta.is_empty():
		meta = _read_doc(part_path(slot, MAP_FILE)).get("meta", {})
	var map_doc := _read_part(slot, MAP_FILE)
	if map_doc.has("error"):
		return map_doc
	# Карта необязательна: старые слоты и ручные сценарии пишут только героя.
	# Пустой/битый map.json не должен хоронить рабочее сохранение.
	if map_doc.is_empty():
		map_doc = {}
	var proc_doc := _read_part(slot, PROCESS_FILE)
	if proc_doc.has("error"):
		return proc_doc
	var proc: Dictionary = proc_doc.get("data", {})
	var data := {
		"version": int(proc.get("version", VERSION)),
		"map": _decoded(map_doc.get("data", {})),
		"hero": _decoded(hero.get("data", {})),
		"world": _decoded(proc.get("world", {})),
		"events": _decoded(proc.get("events", [])),
		"quests": proc.get("quests", {}),
	}
	return {"meta": meta, "data": data}


## Элемент слота пишется через JsonSafe.encode (Vector2/Color → теги `__t`),
## поэтому при чтении его данные обязаны пройти обратное декодирование.
## Без этого позиция героя приезжает словарём {"__t": "v2", ...}, и герой
## после загрузки встаёт на спавн карты.
static func _decoded(v: Variant) -> Variant:
	var out: Variant = JsonSafe.decode(v)
	# Двойные теги: старые слоты держали закодированный блок уже внутри
	# `data` (JsonSafe.encode(payload) целиком), и decode останавливался на
	# внешнем слое.
	if out is Dictionary and (out as Dictionary).has(JsonSafe.TAG):
		return JsonSafe.decode(out)
	return out


## Записать один элемент атомарно: .tmp → flush → старый в .bak → rename.
static func _write_part(slot: String, part: String, doc: Dictionary) -> String:
	var path := part_path(slot, part)
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return "не удалось открыть %s для записи (код %d)" % [tmp, FileAccess.get_open_error()]
	f.store_string(JSON.stringify(doc))
	f.flush()
	f.close()
	if FileAccess.file_exists(path):
		_recycle_to_bak(path)
	var err := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(path))
	if err != OK:
		return "не удалось переименовать %s.tmp: %d" % [path, err]
	if not _reads_ok(path):
		if _restore_path_from_bak(path):
			return "записанный %s не читается, выполнен откат на .bak" % path.get_file()
		return "%s не читается после записи" % path.get_file()
	return ""


## Текущий файл → .bak; прежний .bak предварительно убирается.
static func _recycle_to_bak(path: String) -> void:
	var bak := bak_of(path)
	if FileAccess.file_exists(bak):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(bak))
	DirAccess.rename_absolute(ProjectSettings.globalize_path(path),
		ProjectSettings.globalize_path(bak))


## Копия файла с тем же порядком (.tmp → flush → старый в .bak → rename).
## Копирование поверх самого себя — no-op: без этой проверки файл уезжал бы
## в `.bak`, а на его месте не оставалось ничего (слот терял карту).
static func _atomic_copy(src: String, dst: String) -> bool:
	if src == dst:
		return FileAccess.file_exists(src)
	var data := FileAccess.get_file_as_bytes(src)
	if data.is_empty():
		return false
	var tmp := dst + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(data)
	f.flush()
	f.close()
	if FileAccess.file_exists(dst):
		_recycle_to_bak(dst)
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp),
		ProjectSettings.globalize_path(dst)) == OK


## Прочитать элемент слота: документ, {} (файла нет) или {"error": …}.
static func _read_part(slot: String, part: String) -> Dictionary:
	var path := part_path(slot, part)
	var doc := _read_doc(path)
	if not doc.is_empty():
		var version := int(doc.get("version", -1))
		if version > VERSION:
			return {"error": "version", "file_version": version, "current": VERSION}
		if not (doc.get("data", null) is Dictionary):
			return {"error": "corrupt"}
		return doc
	if not FileAccess.file_exists(path):
		return {}
	# Основной файл есть, но не читается: если .bak читается — чиним молча.
	var bak := _read_doc(bak_of(path))
	if bak.is_empty():
		return {"error": "corrupt"}
	if int(bak.get("version", -1)) > VERSION:
		return {"error": "version", "file_version": int(bak.get("version", 0)),
			"current": VERSION}
	if not (bak.get("data", null) is Dictionary):
		return {"error": "corrupt"}
	_write_raw(path, JSON.stringify(bak))
	return bak


static func _reads_ok(path: String) -> bool:
	return not _read_doc(path).is_empty()


## Откатить слот на .bak. true, если откат выполнен.
static func restore_from_backup(slot: String) -> bool:
	for part in PARTS:
		if _restore_path_from_bak(part_path(slot, part)):
			return true
	return false


static func _restore_path_from_bak(path: String) -> bool:
	var bak := bak_of(path)
	if not FileAccess.file_exists(bak):
		return false
	var text := FileAccess.get_file_as_string(bak)
	if not _is_json(text):
		return false
	return _write_raw(path, text)


## Сломанный слот → снимок прежнего сохранения.
##
## Поэлементный откат по `.bak` не спасает, когда файл испорчен впервые (нет
## `.bak`) или испорчены все три элемента (чужой процесс писал папку).
## `previous.json` атомарен и самодостаточен, поэтому если он есть и
## читается — кладём его содержимое обратно во все три элемента.
## true — слот восстановлен.
static func restore_from_previous(slot: String) -> bool:
	var prev := _read_doc(prev_path(slot))
	var data: Variant = prev.get("data", null)
	if not (data is Dictionary) or (data as Dictionary).is_empty():
		return false
	var d := data as Dictionary
	var meta: Dictionary = prev.get("meta", {})
	var hero_written := _write_part(slot, HERO_FILE, {"version": VERSION, "meta": meta,
		"data": JsonSafe.encode(d.get("hero", {}))})
	if hero_written != "":
		return false
	_write_part(slot, MAP_FILE, {"version": VERSION, "meta": meta,
		"data": JsonSafe.encode(d.get("map", {}))})
	_write_part(slot, PROCESS_FILE, {"version": VERSION, "meta": meta,
		"data": JsonSafe.encode({
			"world": d.get("world", {}),
			"events": d.get("events", []),
			"quests": d.get("quests", {}),
			"version": int(d.get("version", VERSION)),
		})})
	# Снимок перезаписывать НЕЛЬЗЯ: `previous.json` — последняя версия,
	# которую не испортили; иначе следующий сбой перетрёт её зеркалом
	# сломанного слота.
	return true


static func _read_doc(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var j := JSON.new()
	if j.parse(text) != OK:
		return {}
	if not (j.data is Dictionary):
		return {}
	return j.data as Dictionary


static func _is_json(text: String) -> bool:
	var j := JSON.new()
	return j.parse(text) == OK


static func _write_raw(path: String, text: String) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.flush()
	f.close()
	return true


# --- Список слотов для экрана ---

## Метаданные всех слотов для UI. Не грузит тяжёлые данные: метаданные лежат
## в каждом элементе слота.
static func list_slots() -> Array:
	ensure_dir()
	var out: Array = []
	for slot in PLAYER_SLOTS:
		out.append(_slot_entry(slot))
	var auto := _slot_entry(AUTOSAVE_SLOT)
	auto["auto"] = true
	out.append(auto)
	return out


static func _slot_entry(slot: String) -> Dictionary:
	var hero := _read_doc(part_path(slot, HERO_FILE))
	var proc := _read_doc(part_path(slot, PROCESS_FILE))
	var exists := (not hero.is_empty() or not proc.is_empty()) and not is_empty_slot(slot)
	var version := VERSION
	if not hero.is_empty():
		version = int(hero.get("version", -1))
	elif not proc.is_empty():
		version = int(proc.get("version", -1))
	return {
		"slot": slot,
		"exists": exists,
		"version": version,
		"meta": _slot_meta(slot, hero, proc),
		"path": slot_dir(slot),
	}


static func _slot_meta(slot: String, hero: Dictionary, proc: Dictionary) -> Dictionary:
	for doc in [hero, proc, _read_doc(part_path(slot, MAP_FILE))]:
		var meta: Variant = doc.get("meta", {})
		if meta is Dictionary and not (meta as Dictionary).is_empty():
			return meta
	return {"hero_name": slot}


## Слот пуст: либо элементов нет, либо в них нет данных (удалённый слот).
static func is_empty_slot(slot: String) -> bool:
	for part in PARTS:
		var path := part_path(slot, part)
		if not FileAccess.file_exists(path) and not FileAccess.file_exists(bak_of(path)):
			continue
		var doc := _read_doc(path)
		if doc.is_empty():
			continue
		var data: Variant = doc.get("data", null)
		if data is Dictionary and not (data as Dictionary).is_empty():
			return false
	return true


static func has_autosave() -> bool:
	return not is_empty_slot(AUTOSAVE_SLOT)


## Самая свежая запись среди всех слотов. "" — сохранять нечего.
## Сравнение по meta.stamp: порядок файлов в каталоге о порядке сохранений
## ничего не говорит, а полагаться на него нельзя.
static func newest_slot() -> String:
	var best := ""
	var best_stamp := -1
	for entry in list_slots():
		if not bool(entry.get("exists", false)):
			continue
		var stamp := int((entry.get("meta", {}) as Dictionary).get("stamp", 0))
		if stamp > best_stamp:
			best_stamp = stamp
			best = str(entry.get("slot", ""))
	return best


# --- Файлы мира слота ---

## Главный файл карты внутри папки слота, "" — карты в слоте нет.
static func world_map_path(slot: String) -> String:
	var dir_path := slot_dir(slot)
	var d := DirAccess.open(dir_path)
	if d == null:
		return ""
	var names: Array = []
	d.list_dir_begin()
	var fn := d.get_next()
	while fn != "":
		if not d.current_is_dir() and fn.ends_with(".alm") and not fn.ends_with(".bak"):
			names.append(fn)
		fn = d.get_next()
	d.list_dir_end()
	if names.is_empty():
		return ""
	names.sort()
	var map_doc := _read_doc(part_path(slot, MAP_FILE))
	var base := _basename_of(map_doc.get("data", {}))
	if base != "" and names.has(base + ".alm"):
		return dir_path + base + ".alm"
	return dir_path + str(names[0])


## Слот удалён игроком: папка становится пустой — три элемента без данных,
## файлы мира, `.bak` и снимок прежнего состояния убраны. Сама папка
## остаётся: она и есть слот.
static func clear_slot(slot: String) -> void:
	var dir_path := slot_dir(slot)
	if not DirAccess.dir_exists_absolute(dir_path):
		return
	_remove_files_where(dir_path, func(fn: String) -> bool: return PARTS.has(fn))
	var empty := {"version": VERSION, "meta": {}, "data": {}}
	for part in PARTS:
		_write_raw(part_path(slot, part), JSON.stringify(empty))


## Убирает из папки все ФАЙЛЫ (не подкаталоги), для которых keep вернул false.
## `.tmp` удаляются всегда: после удаления слота от них остаётся мусор.
static func _remove_files_where(dir_path: String, keep: Callable) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	var names: Array = []
	d.list_dir_begin()
	var fn := d.get_next()
	while fn != "":
		if not d.current_is_dir():
			names.append(fn)
		fn = d.get_next()
	d.list_dir_end()
	for raw in names:
		var n := str(raw)
		if not n.ends_with(".tmp") and keep.call(n):
			continue
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path + n))


# --- Состав сохранения (v1) ---

## Собрать payload из живого состояния игры.
##
## Отряд (Game.party) в v1 НЕ сохраняется намеренно: наёмники описаны
## в hero.party, и без их восстановления из mercenary_db они были бы
## мусором в партии. Вернём вместе с ними состав в v2.
##
## systems — блоки событий/квестов, собранные вызывающим: {"events": Array,
## "quests": Dictionary}. Без них берутся из узлов-синглтонов, если они есть.
static func build_payload(player, world_dict: Dictionary, world_meta: Dictionary = {},
		systems: Dictionary = {}) -> Dictionary:
	var hero := {
		"class": Game.hero_class,
		"gender": Game.hero_gender,
		"name": Game.hero_name,
		"character_id": Game.hero_character_id,
		"portrait": Game.hero_portrait,
		"race": Game.hero_race,
		"stats": Game.hero_stats.duplicate(true),
		"start_book": Game.hero_start_book,
		"primary_skill": Game.hero_primary_skill,
		"aux_skill": Game.hero_aux_skill,
		"max_hp": int(player.max_hp),
		"max_mana": int(player.max_mana),
		"current_hp": int(player.current_hp),
		"current_mana": int(player.current_mana),
		"gold": int(player.gold),
		"inventory": player.inventory.duplicate(),
		"equipped": player.equipped.duplicate(true),
		"experience": player.experience.duplicate(true),
		"known_spells": player.known_spells.duplicate(true),
		"sphere_books": player.sphere_books.duplicate(true),
		"position": player.global_position,
		# v2: отряд и хотбар. Призванные (lifespan > 0) не сохраняются: они
		# временные и привязаны к жизни каста, а не к прогулке героя.
		"party": _party_snapshot(),
		"hotbar": Game.hotbar.duplicate(true),
	}
	var map_files := world_files()
	var events: Variant = systems.get("events", null)
	if events == null:
		events = EventSystem.instance.to_payload() if EventSystem.instance != null else []
	var quests: Variant = systems.get("quests", null)
	if quests == null:
		quests = QuestSystem.instance.to_payload() if QuestSystem.instance != null else {}
	var payload := {
		"version": VERSION,
		"map": {
			"seed": int(Game.map_seed), "zone": str(Game.map_zone),
			"world_seed": int(Game.world_seed), "sector": str(Game.map_sector),
			"fog": Game.fog.mask_rle() if Game.fog != null else "",
			# Карта — целыми файлами в папке слота (решение 22.10), поэтому
			# сохраняется путь к текущему .alm и его стабильное имя.
			"path": str(map_files.get("path", "")),
			"basename": str(map_files.get("basename", "")),
			# Захваченные форпосты (пакет B): ключ включает зону/сектор/сид,
			# поэтому словарь общий для всех карт мира, как Game.hotbar.
			"outposts": Game.outposts_captured.duplicate(),
		},
		"hero": hero,
		"world": world_dict,
		"events": events,
		"quests": quests,
		# Mod profile: what was enabled at save time. On load it shows which mods
		# are missing (see _check_mods).
		"mods": ModLoader.save_profile(),
	}
	var meta := {
		"hero_name": Game.hero_name,
		"hero_class": Game.hero_class,
		"level": _hero_level(player),
		"day": int(world_dict.get("day", 0)),
		"zone": str(Game.map_zone),
		"seed": int(Game.map_seed),
		# Unix-время записи: экран «Продолжить» обязан уметь выбрать самый
		# свежий слот, а порядок в списке определяется только им.
		"stamp": int(Time.get_unix_time_from_system()),
	}
	meta.merge(world_meta, true)
	payload["meta"] = meta
	return payload


## Отряд в сейв: чистые данные, без ссылок на узлы (save-systems: сохраняем
## состояние, а не объекты сцены). Призванные существа (lifespan > 0) —
## временные, они не часть прогулки героя.
static func _party_snapshot() -> Array:
	var out: Array = []
	for m in Game.party:
		if not is_instance_valid(m):
			continue
		var unit: Node2D = m as Node2D
		if unit == null:
			continue
		if "lifespan" in m and float(m.get("lifespan")) > 0.0:
			continue
		out.append({
			"set": str(m.get("anim_set")),
			"hp_max": int(m.get("max_hp")),
			"hp": int(m.get("current_hp")),
			"damage": int(m.get("damage")),
			"spirit": int(m.get("spirit")),
			"speed": float(m.get("move_speed")),
			"x": unit.global_position.x,
			"y": unit.global_position.y,
		})
	return out


## Прочитать отряд из сейва: набор обязан существовать в units_db, иначе
## запись отбрасывается (сейв старой версии/правка данных не должны рождать
## «наёмника-призрака» без анимации).
static func _party_saved(v: Variant) -> Array:
	var out: Array = []
	if not (v is Array):
		return out
	for raw in (v as Array):
		if not (raw is Dictionary):
			continue
		var rec: Dictionary = raw
		var set_name := str(rec.get("set", ""))
		if set_name == "" or UnitDB.get_set(set_name).is_empty():
			continue
		var hp_max := maxi(1, int(rec.get("hp_max", 70)))
		out.append({
			"set": set_name,
			"hp_max": hp_max,
			"hp": clampi(int(rec.get("hp", hp_max)), 1, hp_max),
			"damage": maxi(0, int(rec.get("damage", 6))),
			"spirit": maxi(0, int(rec.get("spirit", 5))),
			"speed": maxf(10.0, float(rec.get("speed", 90.0))),
			"x": float(rec.get("x", 0.0)),
			"y": float(rec.get("y", 0.0)),
		})
	return out


## Хотбар из сейва: слоты 0..8, только существующие заклинания и предметы.
## Неизвестную запись выбрасываем — иначе клавиша молча не делает ничего.
static func _hotbar_saved(v: Variant) -> Dictionary:
	var out: Dictionary = {}
	if not (v is Dictionary):
		return out
	var spells: Array = SpellDB.catalog_spells()
	for raw_slot in (v as Dictionary):
		var slot := int(str(raw_slot))
		if slot < 0 or slot > 8:
			continue
		var entry: Variant = (v as Dictionary)[raw_slot]
		if not (entry is Dictionary):
			continue
		var kind := str((entry as Dictionary).get("kind", ""))
		if kind == "spell":
			var name := str((entry as Dictionary).get("name", ""))
			if name == "" or not spells.has(name):
				continue
			out[slot] = {"kind": "spell", "name": name}
		elif kind == "item":
			var key := str((entry as Dictionary).get("key", ""))
			if key == "" or ItemDB.find(key).is_empty():
				continue
			out[slot] = {"kind": "item", "key": key}
	return out


## Текущая карта игры: {"path": user:// путь к .alm, "basename": имя}.
## Карты в файле нет (карта из main.tscn/dev) — пустые строки.
static func world_files() -> Dictionary:
	var out := {"path": "", "basename": ""}
	if Game.pending_map_path != "" and FileAccess.file_exists(Game.pending_map_path):
		if not Game.pending_map_path.begins_with("res://"):
			out["path"] = Game.pending_map_path
			# Зона/сектор — часть имени, как у карт генератора
			# (`map_<сид>_<сектор>_<раса>`). Без этого `restore_zone_map` не
			# находил готовая-карту после выхода и возврата: имя не содержало
			# токена сектора, и карта на старте генерировалась заново.
			var base := Game.pending_map_path.get_file().get_basename()
			if Game.map_sector != "" and not base.contains(Game.map_sector):
				base += "_" + Game.map_sector
			out["basename"] = base
		return out
	if Game.map_seed == 0:
		return out
	var race := MapGenerator.city_race_for_hero(Game.hero_race)
	var base := MapGenerator.map_basename(Game.map_seed, Game.map_zone, race,
		Game.map_sector)
	var path := MapGenerator.MAPS_DIR + base + ".alm"
	if FileAccess.file_exists(path):
		out["path"] = path
		out["basename"] = base
	return out


static func _hero_level(player) -> int:
	var t := 0
	if player.experience is Dictionary:
		for key in player.experience:
			t += int(player.experience[key])
	return player.exp_to_skill(t)


## Подготовить мир слота к загрузке ДО смены сцены: файлы карты из папки
## слота раскладываются в user://maps/ под стабильным именем, путь кладётся
## в Game.pending_map_path (он имеет приоритет над сидом). Карты в слоте
## нет — остаётся путь по сиду, как и было.
static func restore_map(slot: String) -> void:
	Game.pending_map_path = ""
	var src := world_map_path(slot)
	if src == "":
		return
	if not _stage_world_files(slot, src, "save_%s" % slot):
		push_warning("SaveSystem: карта слота %s не разложена" % slot)
		return
	Game.pending_map_path = MapGenerator.MAPS_DIR + "save_%s.alm" % slot


## Карта ДРУГОЙ зоны из папки слота (переход через портал после загрузки).
## Возвращает путь к разложенному `.alm` в user://maps/ или "" — такой зоны в
## слоте нет, карту строим по сиду.
##
## Ищем `<basename слота>_<зона>*.alm`: MapGenerator кладёт в имя и расу
## города (`map_<сид>_<зона>_<раса>.alm`), поэтому сравниваем по префиксу.
static func restore_zone_map(slot: String, zone: String) -> String:
	var dir_path := slot_dir(slot)
	var d := DirAccess.open(dir_path)
	if d == null:
		return ""
	var slot_base := _basename_of(_read_doc(part_path(slot, MAP_FILE)).get("data", {}))
	if slot_base == "":
		return world_map_path(slot)
	# Текущая карта слота уже принадлежит этой зоне (в имени есть токен
	# сектора) — берём именно её и готовим в user://maps/ под стабильным
	# именем. Без этого возврат на стартовую (готовую) карту генерировал
	# новую карту по сиду.
	if slot_base.split("_").has(zone):
		if _stage_world_files(slot, slot_dir(slot) + slot_base + ".alm", "save_%s" % slot):
			return MapGenerator.MAPS_DIR + "save_%s.alm" % slot
	# Имя карты — `map_<сид>_<сектор>_<раса>` (или старый `_<зона>_`).
	# Сектор/зона — отдельный токен имени: сид у соседних секторов свой, поэтому
	# сравнивать «сид и расу» нельзя, а уникален здесь именно сектор.
	var names: Array = []
	d.list_dir_begin()
	var fn := d.get_next()
	while fn != "":
		var file_base := fn.get_basename()
		var parts := file_base.split("_")
		var right_zone := parts.has(zone)
		if not d.current_is_dir() and not fn.ends_with(".bak") \
				and fn.ends_with(".alm") and right_zone:
			names.append(fn)
		fn = d.get_next()
	d.list_dir_end()
	if names.is_empty():
		return ""
	# Свежая карта зоны — та, что правили последней. Раньше брали
	# алфавитно первую: после возврата на готовую карту это был старый
	# снимок `custom_<сектор>`, а не актуальный `save_<slot>_<сектор>`.
	names.sort_custom(func(a, b):
		var ta := FileAccess.get_modified_time(dir_path + str(a))
		var tb := FileAccess.get_modified_time(dir_path + str(b))
		if ta == tb:
			return str(a) < str(b)
		return ta > tb)
	var src := dir_path + str(names[0])
	var dst_base := src.get_file().get_basename()
	if dst_base == slot_base:
		dst_base = "save_%s" % slot
	if not _stage_world_files(slot, src, dst_base):
		return ""
	return MapGenerator.MAPS_DIR + dst_base + ".alm"


## Положить карту зоны (и её sidecar-ы) в папку слота. Вызывается при
## переходе между зонами: слот копит карты всех посещённых зон, чтобы
## `restore_zone_map` нашёл их после перезапуска. Имя — имя самого карты
## (`map_<сид>_<зона>_<раса>`), чтобы поиск по зоне работал.
static func store_zone_map(slot: String, map_path: String) -> String:
	if map_path == "" or not FileAccess.file_exists(map_path):
		return "карты нет: %s" % map_path
	return _mirror_world_files(slot, map_path, map_path.get_file().get_basename())


## Имя карты из map.json. Сравнивать с именами файлов нельзя в лоб:
## `data` закодирован JsonSafe, а часть старых слотов писала живой словарь.
static func _basename_of(map_data: Variant) -> String:
	var d: Variant = _decoded(map_data)
	if d is Dictionary:
		return str((d as Dictionary).get("basename", ""))
	return ""


## Разложить `.alm` и sidecar-ы из папки слота в user://maps/ под именем
## `dst_base`. true — хотя бы один файл скопирован.
##
## Копирование поверх самого себя (карта зоны уже лежит в user://maps/, а слот
## брал её оттуда) — не ошибка: файл на месте и читается.
static func _stage_world_files(slot: String, src: String, dst_base: String) -> bool:
	var dst_dir := MapGenerator.MAPS_DIR
	DirAccess.make_dir_recursive_absolute(dst_dir)
	var src_base := src.get_file().get_basename()
	var copied := 0
	for raw_suffix in WORLD_SUFFIXES:
		var from: String = slot_dir(slot) + src_base + str(raw_suffix)
		if not FileAccess.file_exists(from):
			continue
		if _atomic_copy(from, dst_dir + dst_base + str(raw_suffix)):
			copied += 1
	return copied > 0


## Применить payload к игре. Вызывать ДО загрузки сцены карты: сначала
## ставим карту (pending_map_path или сид), потом создаём мир.
##
## player может быть null - тогда применяются только Game.* (выбор героя на
## экране character_select применяет их ДО перехода на игровую сцену, где
## игрока ещё нет). Раньше проверка player == null стояла выше блока
## Game.hero_*, и весь герой молча терялся.
##
## slot — слот, из которого читаем: по нему вход в игру берёт файлы карты из
## папки сохранения. Без slot карта берётся по сиду.
## Mod profile of the save against the current set: missing and updated mods are
## a log warning, not a refusal to load the world. Lesson from Space Engineers,
## where removing a mod breaks the world: our keys are strings, missing items
## simply are not found, and the game must still open.
static func _check_mods(saved: Variant) -> void:
	if not (saved is Array) or (saved as Array).is_empty():
		return
	var now: Dictionary = {}
	for m in ModLoader.save_profile():
		now[str(m.get("id", ""))] = str(m.get("version", ""))
	var missing: Array[String] = []
	for raw in (saved as Array):
		if not (raw is Dictionary):
			continue
		var id := str((raw as Dictionary).get("id", ""))
		if id == "":
			continue
		var ver := str((raw as Dictionary).get("version", ""))
		if not now.has(id):
			missing.append(id)
		elif now[id] != ver:
			push_warning("Сейв: мод '%s' другой версии (%s -> %s)" % [id, ver, str(now[id])])
	if not missing.is_empty():
		push_warning("Сейв: моды не загружены (%s) — часть предметов и монстров будет недоступна" %
			", ".join(missing))


static func apply_payload(d: Dictionary, player, slot: String = "") -> void:
	var map_d: Dictionary = d.get("map", {})
	Game.map_seed = int(map_d.get("seed", 0))
	Game.map_zone = str(map_d.get("zone", "mid"))
	Game.world_seed = int(map_d.get("world_seed", 0))
	Game.map_sector = str(map_d.get("sector", ""))
	# Туман и события (19.10): применяются узлами после сборки карты.
	Game.pending_fog_rle = str(map_d.get("fog", ""))
	Game.pending_outposts_captured = {}
	# Сейв — источник правды: захваты прежнего героя не должны «протечь» в
	# загружаемый слот (даже если у карт совпал сид).
	Game.outposts_captured.clear()
	var cap: Variant = map_d.get("outposts", {})
	if cap is Dictionary:
		for key in cap:
			if bool((cap as Dictionary)[key]):
				Game.pending_outposts_captured[str(key)] = true
	Game.pending_events = (d.get("events", []) as Array).duplicate(true)
	_check_mods(d.get("mods", []))
	# Older saves (before 22.10) kept an empty ARRAY here, meaning "no quests".
	# That is not a corruption: fall back to the empty schema silently.
	var qd: Variant = d.get("quests", {})
	Game.pending_quests = (qd as Dictionary).duplicate(true) if qd is Dictionary else {}
	Game.pending_quests_applied = false
	if slot != "":
		restore_map(slot)
	var h: Dictionary = d.get("hero", {})
	Game.hero_class = str(h.get("class", Game.hero_class))
	Game.hero_gender = str(h.get("gender", Game.hero_gender))
	Game.hero_name = str(h.get("name", Game.hero_name))
	var cid := str(h.get("character_id", Game.hero_character_id))
	# Миграция старых Аллодовских id → портреты рас.
	var legacy := {
		"mfighter": "human_m_war", "ffighter": "human_f_war",
		"mmage": "human_m_mage", "fmage": "human_f_mage",
	}
	if legacy.has(cid):
		cid = str(legacy[cid])
	Game.hero_character_id = cid
	Game.hero_portrait = str(h.get("portrait", Game.hero_portrait))
	if Game.hero_portrait == "":
		Game.hero_portrait = "res://assets/hero_portraits/%s.png" % cid
	Game.hero_race = str(h.get("race", Game.hero_race))
	var st: Variant = h.get("stats", null)
	if st is Dictionary:
		Game.hero_stats = (st as Dictionary).duplicate(true)
	Game.hero_start_book = str(h.get("start_book", ""))
	Game.hero_primary_skill = str(h.get("primary_skill", ""))
	Game.hero_aux_skill = str(h.get("aux_skill", ""))
	# Позиция героя: всегда кладём в Game (для player==null и для apply до
	# пересборки сцены). Раньше поле писалось в файл, но не применялось —
	# герой после «Продолжить» всегда вставал на спавн.
	var pos_v: Variant = h.get("position", null)
	if pos_v is Vector2:
		Game.load_position = pos_v as Vector2
		Game.load_position_valid = true
	else:
		Game.clear_load_position()
	# Runtime-состояние для нового Player после change_scene: золото/склад/
	# экипировка/HP/навыки. Без этого _ready игрока снова выдавал стартовый
	# набор, и сейв «терял» инвентарь, хотя файл был цел.
	Game.hero_save = {
		"max_hp": int(h.get("max_hp", 100)),
		"max_mana": int(h.get("max_mana", 50)),
		"current_hp": int(h.get("current_hp", int(h.get("max_hp", 100)))),
		"current_mana": int(h.get("current_mana", int(h.get("max_mana", 50)))),
		"gold": int(h.get("gold", 0)),
		"inventory": _str_array(h.get("inventory", [])),
		"equipped": _dict(h.get("equipped", {})),
		"experience": _dict(h.get("experience", {})),
		"known_spells": _dict(h.get("known_spells", {})),
		"sphere_books": _dict(h.get("sphere_books", {})),
	}
	# v2: отряд и хотбар кладутся в статики Game — узлы создаёт game.gd, когда
	# карта уже собрана (наёмнику нужен проходимый тайл, а не пустая сцена).
	Game.pending_party = _party_saved(h.get("party", []))
	Game.hotbar = _hotbar_saved(h.get("hotbar", {}))
	if player == null:
		return
	player.max_hp = int(h.get("max_hp", 100))
	player.max_mana = int(h.get("max_mana", 50))
	player.current_hp = int(h.get("current_hp", player.max_hp))
	player.current_mana = int(h.get("current_mana", player.max_mana))
	player.gold = int(h.get("gold", 0))
	player.inventory = _str_array(h.get("inventory", []))
	player.equipped = _dict(h.get("equipped", {}))
	player.experience = _dict(h.get("experience", {}))
	player.known_spells = _dict(h.get("known_spells", {}))
	player.sphere_books = _dict(h.get("sphere_books", {}))
	player._recall_speed()
	if Game.load_position_valid:
		player.global_position = Game.load_position
		if player.has_method("reset_physics_interpolation"):
			player.reset_physics_interpolation()


static func _str_array(v: Variant) -> Array:
	var out: Array = []
	if v is Array:
		for item in v:
			out.append(str(item))
	return out


static func _dict(v: Variant) -> Dictionary:
	return (v as Dictionary).duplicate(true) if v is Dictionary else {}
