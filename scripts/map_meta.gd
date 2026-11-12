class_name MapMeta
extends RefCounted
## Паспорт пользовательской карты: `<name>.meta.json` рядом с `.alm`.
##
## Карты, сделанные в редакторе, живут в `user://maps/custom/` и содержат:
##   <name>.alm            — тайлы/высоты/препятствия
##   <name>.meta.json      — заголовок/зона/размер (этот файл)
##   <name>.spawn.json     — точка появления героя
##   <name>.portal.json    — порталы
##   <name>.structures.json, .npcs.json, .nowalk.json, .allowwalk.json
##
## Метаданные нужны экрану выбора героя (список карт, зона старта) и
## сохранениям: `SaveSystem.WORLD_SUFFIXES` копирует их вместе с картой.

const CUSTOM_DIR := "user://maps/custom/"
const SUFFIX := ".meta.json"
const VERSION := 1

const ZONES := ["start", "mid", "hard", "faction"]
# Zone names are not duplicated here: StartSetup.zone_label() owns them and reads
# ui.zone.* from ui.json. This file used to carry a second copy of the Russian
# labels, which is how two sources of the same text drift apart.


static func ensure_dir() -> void:
	var abs_path := ProjectSettings.globalize_path(CUSTOM_DIR)
	if not DirAccess.dir_exists_absolute(abs_path):
		DirAccess.make_dir_recursive_absolute(abs_path)


static func meta_path(alm_path: String) -> String:
	return alm_path.get_basename() + SUFFIX


## Имя файла из заголовка: латиница/цифры/дефис/подчёркивание.
## Заголовок остаётся в мете как есть — файловая система не любит кириллицу
## в путях на части сборок, поэтому имя всегда ASCII.
static func slug(text: String) -> String:
	var out := ""
	for i in range(text.length()):
		var code := String.chr(text.unicode_at(i)).to_lower().unicode_at(0)
		if (code >= 97 and code <= 122) or (code >= 48 and code <= 57):
			out += String.chr(code)
		elif code == 32 or code == 45 or code == 95:  # пробел, '-', '_'
			if out != "" and not out.ends_with("_"):
				out += "_"
	if out == "":
		out = "map"
	if out.length() > 40:
		out = out.substr(0, 40)
	return out


## Свободное имя в user://maps/custom/<slug>.alm (суффикс _2, _3 …).
static func unused_path(title: String) -> String:
	ensure_dir()
	var base := slug(title)
	var candidate := CUSTOM_DIR + base + ".alm"
	var n := 2
	while FileAccess.file_exists(candidate):
		candidate = CUSTOM_DIR + "%s_%d.alm" % [base, n]
		n += 1
	return candidate


static func read(alm_path: String) -> Dictionary:
	var path := meta_path(alm_path)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return {}
	var d: Dictionary = parsed
	d["zone"] = str(d.get("zone", "start"))
	if not ZONES.has(str(d["zone"])):
		d["zone"] = "start"
	return d


static func write(alm_path: String, data: Dictionary) -> bool:
	var d := data.duplicate(true)
	d["version"] = VERSION
	var zone := str(d.get("zone", "start"))
	d["zone"] = zone if ZONES.has(zone) else "start"
	var f := FileAccess.open(meta_path(alm_path), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(d, "  "))
	f.close()
	return true


static func title_of(alm_path: String) -> String:
	var meta := read(alm_path)
	var t := str(meta.get("title", ""))
	if t != "":
		return t
	return alm_path.get_file().get_basename()


static func zone_of(alm_path: String) -> String:
	return str(read(alm_path).get("zone", "start"))


## Все карты пользователя, свежие сверху. Запись:
## {path, title, zone, w, h, modified, has_spawn, has_portal}
static func list() -> Array:
	ensure_dir()
	var dir := DirAccess.open(CUSTOM_DIR)
	if dir == null:
		return []
	var out: Array = []
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.to_lower().ends_with(".alm"):
			var path := CUSTOM_DIR + name
			var meta := read(path)
			var base := path.get_basename()
			out.append({
				"path": path,
				"title": title_of(path),
				"zone": str(meta.get("zone", "start")),
				"w": int(meta.get("w", 0)),
				"h": int(meta.get("h", 0)),
				"modified": FileAccess.get_modified_time(path),
				"has_spawn": FileAccess.file_exists(base + ".spawn.json"),
				"has_portal": FileAccess.file_exists(base + ".portal.json"),
			})
		name = dir.get_next()
	dir.list_dir_end()
	out.sort_custom(func(a, b): return int(a["modified"]) > int(b["modified"]))
	return out
