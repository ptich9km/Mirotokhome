class_name ModLoader
extends RefCounted
## Mod loader: `res://mods/<id>/` (bundled packs) and `user://mods/<id>/`
## (player mods). No autoload — plain statics, like SaveSystem.
##
## Why not "the Space Engineers way": there a redefinition is silent (the second
## mod with the same SubtypeId simply disappears) and "field omitted = default
## from code". Here the opposite — a key conflict or a lost asset is an ERROR
## naming the mod and the key, the entry is skipped (the base version stays),
## and inheritance is always explicit: `"extends": "<base key>"`.
##
## Mod layout:
##   mods/<id>/mod.json     — manifest (id, name, version, author, priority, ...)
##   mods/<id>/data/*.json  — entries (array of objects or {"entries": [...]})
##   mods/<id>/assets/*     — own files, referenced as `mod://<id>/assets/x.png`
##   mods/<id>/thumb.png    — preview for the mods panel (optional)
##
## Entry in data:
##   {"into": "unit", "key": "monsters/warden", "extends": "monsters/wolf",
##    "name_ru": "...", "palette": 5}
##   op: "add" (default) | "patch" | "remove" | "append"
## `into` says where to put it (item/unit/spell/structure/rule); `key` is the key
## inside that base. The rest of the entry is the object data itself. The field
## is called `into` and not `kind` because spells already own a `kind` field
## ("attack") — routing used to swallow it.
##
## Load order: depends_on (hard) -> load_after (soft) -> priority (higher = later,
## i.e. wins) -> id alphabetically. One direction only, the same one the UI
## shows: lower in the list = applied later.

const MOD_ROOTS: Array[String] = ["res://mods", "user://mods"]
const MANIFEST_NAME := "mod.json"
const DATA_DIR := "data"
const USER_MODS_DIR := "user://mods"
## Player settings next to the mods: disabled ids and the manual order.
const CONFIG_PATH := "user://mods.cfg"

## Entry "into" -> base id (see overlay()).
const DB_OF_KIND: Dictionary = {
	"item": "items",
	"unit": "units",
	"spell": "spells",
	"structure": "structures",
	"rule": "rules",
}
## Key field for bases stored as arrays. Dictionary bases use the dict key.
const DB_KEY_FIELD: Dictionary = {"items": "key", "rules": "key"}
const DB_IS_ARRAY: Dictionary = {
	"items": true, "units": false, "spells": false, "structures": false, "rules": true,
}
const ENTRY_META := ["op", "into", "key", "extends"]

static var _scanned := false
static var _mods: Array[Dictionary] = []      # enabled mods, in apply order
static var _all: Array[Dictionary] = []       # every found mod (for the panel)
static var _errors: Array[String] = []
static var _warnings: Array[String] = []
static var _disabled: Array[String] = []      # from user://mods.cfg
static var _manual_order: Array[String] = []  # from user://mods.cfg, lower = later
static var _owners: Dictionary = {}     # "db|key" -> id of the mod that added it
static var _patchers: Dictionary = {}   # "db|key" -> Array[String] of patching mods
static var _orphans: Array[String] = []  # folders in mods/ without mod.json
## Are mods on? In headless `--script` runs they are OFF by default: tests check
## base data, while the player has own mods in user://mods (2026-10-29: the
## player's `warden` broke `gray_tier_smoke`). Mod tests opt in with
## `set_active(true)`.
static var _active := true
static var _active_resolved := false


## Drops the cache (tests, rescan after enabling/disabling a mod).
## Settings (disabled ids, manual order) are re-read from `mods.cfg`.
static func reset() -> void:
	_scanned = false
	_mods.clear()
	_all.clear()
	_errors.clear()
	_warnings.clear()
	_disabled.clear()
	_manual_order.clear()
	_owners.clear()
	_patchers.clear()
	_orphans.clear()


## Folders under `mods/` without a `mod.json`. Players (and we) regularly copy a
## folder one level too deep — then "no mods" appears with no explanation.
## The panel lists these folders.
static func orphan_folders() -> Array[String]:
	_scan()
	var out: Array[String] = []
	out.assign(_orphans)
	return out


static func mods() -> Array[Dictionary]:
	_scan()
	var out: Array[Dictionary] = []
	out.assign(_mods)
	return out


## Every found mod (including disabled ones) in apply order — for the panel.
static func all_mods() -> Array[Dictionary]:
	_scan()
	var out: Array[Dictionary] = []
	for m in _all:
		var copy: Dictionary = m.duplicate()
		copy["enabled"] = not _disabled.has(str(m["id"]))
		out.append(copy)
	return out


static func is_enabled(id: String) -> bool:
	_scan()
	return not _disabled.has(id)


## Force mods on/off for the whole process (tests).
static func set_active(on: bool) -> void:
	_active = on
	_active_resolved = true
	reset()


static func is_active() -> bool:
	_scan()
	return _active


## Enable/disable a mod. Takes effect after a game restart (base data is already
## parsed), so the UI must tell the player exactly that.
static func set_enabled(id: String, on: bool) -> void:
	_scan()
	if on:
		_disabled.erase(id)
	elif not _disabled.has(id):
		_disabled.append(id)
	_save_config()
	reset()


## Move a mod in the manual order: delta > 0 — lower in the list (applied later).
static func move(id: String, delta: int) -> void:
	_scan()
	_ensure_order()
	var i := _manual_order.find(id)
	if i < 0:
		return
	var j := clampi(i + delta, 0, _manual_order.size() - 1)
	if i == j:
		return
	_manual_order.remove_at(i)
	_manual_order.insert(j, id)
	_save_config()
	reset()


static func errors() -> Array[String]:
	_scan()
	var out: Array[String] = []
	out.assign(_errors)
	return out


static func warnings() -> Array[String]:
	_scan()
	var out: Array[String] = []
	out.assign(_warnings)
	return out


## Player mods folder (created on first access).
static func user_mods_dir() -> String:
	if DirAccess.open(USER_MODS_DIR) == null:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(USER_MODS_DIR))
	return USER_MODS_DIR


## Mod profile for saves: what was enabled and in which order.
static func save_profile() -> Array:
	_scan()
	var out: Array = []
	for m in _mods:
		out.append({"id": m["id"], "version": m["version"], "priority": m["priority"]})
	return out


## `mod://<id>/<path>` -> real path. Non-mod paths are returned unchanged.
static func resolve(path: String) -> String:
	if not path.begins_with("mod://"):
		return path
	var rest := path.substr(6)
	var slash := rest.find("/")
	if slash <= 0:
		return path
	var id := rest.substr(0, slash)
	var rel := rest.substr(slash + 1)
	var dir := _dir_of(id)
	if dir == "":
		return path
	return dir.path_join(rel)


static func is_mod_path(path: String) -> bool:
	return path.begins_with("mod://")


## Applies mods to a base's data. Called from every base's ensure_loaded() AFTER
## the JSON is parsed and BEFORE indexes are built. `base` is mutated in place.
static func overlay(db: String, base: Variant) -> void:
	_scan()
	if base == null or _mods.is_empty():
		return
	var is_array: bool = DB_IS_ARRAY.get(db, false)
	var applied := 0
	for m in _mods:
		var entries: Array = m.get("entries", [])
		for raw in entries:
			if not (raw is Dictionary):
				continue
			var e: Dictionary = raw
			if str(DB_OF_KIND.get(str(e.get("into", "")), "")) != db:
				continue
			if _apply_entry(m, e, base, is_array, db):
				applied += 1
	if applied > 0:
		print("ModLoader: %s - records from mods: %d (mods: %d)" % [db, applied, _mods.size()])


# --- scanning -----------------------------------------------------------------

## Default mode: mods on in game, off in `--script` runs (those check base data);
## `--with-mods` in the args after `--` turns them on.
static func _resolve_active() -> void:
	if _active_resolved:
		return
	_active_resolved = true
	if OS.get_cmdline_args().has("--script"):
		_active = OS.get_cmdline_user_args().has("--with-mods")


static func _scan() -> void:
	if _scanned:
		return
	_scanned = true   # set first: resolve() may call _dir_of -> _scan
	_resolve_active()
	if not _active:
		return
	_load_config()
	var found: Array[Dictionary] = []
	var seen: Dictionary = {}
	for root in MOD_ROOTS:
		var da := DirAccess.open(root)
		if da == null:
			continue
		da.list_dir_begin()
		var folder := da.get_next()
		while folder != "":
			if da.current_is_dir() and not folder.begins_with("."):
				var mod_dir := root.path_join(folder)
				if not FileAccess.file_exists(mod_dir.path_join(MANIFEST_NAME)):
					_orphans.append(mod_dir)
					folder = da.get_next()
					continue
				var m := _read_mod(mod_dir, folder)
				if not m.is_empty():
					if seen.has(m["id"]):
						_errors.append("mod '%s' is declared twice: %s and %s" % [m["id"], seen[m["id"]], m["dir"]])
					else:
						seen[m["id"]] = m["dir"]
						found.append(m)
			folder = da.get_next()
		da.list_dir_end()

	# Hard dependencies: missing — the mod is not loaded (otherwise we would
	# silently get a mod reading data of a neighbour that does not exist).
	var ids: Dictionary = {}
	for m in found:
		ids[m["id"]] = true
	var good: Array[Dictionary] = []
	for m in found:
		var ok := true
		for dep in m.get("depends_on", []):
			if not ids.has(str(dep)):
				_errors.append("mod '%s': missing dependency '%s'" % [m["id"], dep])
				ok = false
		if ok:
			good.append(m)
	_all = _sort_mods(good)
	_mods.clear()
	for m in _all:
		if _disabled.has(str(m["id"])):
			continue
		# A disabled dependency means the mod must not load "half-way".
		var off := ""
		for dep in m.get("depends_on", []):
			if _disabled.has(str(dep)):
				off = str(dep)
				break
		if off != "":
			_errors.append("mod '%s' is not loaded: dependency '%s' is disabled" % [m["id"], off])
			continue
		_mods.append(m)
	if not _all.is_empty() or not _errors.is_empty():
		print("ModLoader: found %d, enabled %d, errors %d, warnings %d" %
			[_all.size(), _mods.size(), _errors.size(), _warnings.size()])


## Player settings: what is disabled and the manual order (`user://mods.cfg`).
static func _load_config() -> void:
	_disabled.clear()
	_manual_order.clear()
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	for v in _as_array(cfg.get_value("mods", "disabled", [])):
		_disabled.append(v)
	for v in _as_array(cfg.get_value("mods", "order", [])):
		_manual_order.append(v)


static func _save_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("mods", "disabled", _disabled)
	cfg.set_value("mods", "order", _manual_order)
	var err := cfg.save(CONFIG_PATH)
	if err != OK:
		push_warning("ModLoader: cannot write %s (%d)" % [CONFIG_PATH, err])


static func _as_array(value: Variant) -> Array[String]:
	var out: Array[String] = []
	if value is Array:
		for v in value:
			out.append(str(v))
	return out


## Manual order: new mods are appended to the end, nothing is lost.
static func _ensure_order() -> void:
	for m in _all:
		var id := str(m["id"])
		if not _manual_order.has(id):
			_manual_order.append(id)


## Position in the manual order. Mods missing from it go last.
static func _rank_of(id: String) -> int:
	var i := _manual_order.find(id)
	return i if i >= 0 else 100000


static func _read_mod(dir: String, folder: String) -> Dictionary:
	var man_path := dir.path_join(MANIFEST_NAME)
	if not FileAccess.file_exists(man_path):
		return {}
	var parsed: Variant = _parse_json(man_path)
	if not (parsed is Dictionary):
		_errors.append("mod '%s': broken %s" % [folder, MANIFEST_NAME])
		return {}
	var man: Dictionary = parsed
	var id := str(man.get("id", "")).strip_edges()
	if id == "":
		_errors.append("mod '%s': %s has no id field" % [folder, MANIFEST_NAME])
		return {}
	if id != folder:
		_warnings.append("mod '%s': id '%s' does not match the folder name" % [folder, id])
	var m: Dictionary = {
		"id": id,
		"dir": dir,
		"name": str(man.get("name", id)),
		"version": str(man.get("version", "0.0.0")),
		"author": str(man.get("author", "")),
		"description": str(man.get("description", "")),
		"priority": int(man.get("priority", 0)),
		"affects_save": bool(man.get("affects_save", true)),
		"depends_on": _str_array(man.get("depends_on", [])),
		"load_after": _str_array(man.get("load_after", [])),
		"entries": _read_entries(dir, id),
	}
	var thumb := dir.path_join(str(man.get("thumb", "thumb.png")))
	m["thumb"] = thumb if FileAccess.file_exists(thumb) else ""
	return m


static func _read_entries(dir: String, mod_id: String) -> Array:
	var out: Array = []
	var data_dir := dir.path_join(DATA_DIR)
	if DirAccess.open(data_dir) == null:
		return out
	var files := _json_files(data_dir)
	files.sort()
	for path in files:
		var parsed: Variant = _parse_json(path)
		if parsed is Array:
			for e in parsed:
				if e is Dictionary:
					out.append(e)
				else:
					_errors.append("mod '%s': an entry in %s is not an object" % [mod_id, path])
		elif parsed is Dictionary and parsed.get("entries", null) is Array:
			for e in parsed["entries"]:
				if e is Dictionary:
					out.append(e)
		else:
			_errors.append("mod '%s': broken JSON in %s (an array of entries is required)" % [mod_id, path])
	return out


static func _json_files(dir: String) -> Array[String]:
	var out: Array[String] = []
	var da := DirAccess.open(dir)
	if da == null:
		return out
	da.list_dir_begin()
	var name := da.get_next()
	while name != "":
		if name.begins_with("."):
			name = da.get_next()
			continue
		var path := dir.path_join(name)
		if da.current_is_dir():
			out.append_array(_json_files(path))
		elif name.to_lower().ends_with(".json"):
			out.append(path)
		name = da.get_next()
	da.list_dir_end()
	return out


## JSON through a parser instance: `JSON.parse_string` prints an engine ERROR to
## stderr on failure, and a broken mod would look like a game crash in the log.
static func _parse_json(path: String) -> Variant:
	var txt := FileAccess.get_file_as_string(path)
	if txt.is_empty():
		return null
	var json := JSON.new()
	if json.parse(txt) != OK:
		return null
	return json.data


static func _str_array(value: Variant) -> Array[String]:
	var out: Array[String] = []
	if value is Array:
		for v in value:
			out.append(str(v))
	return out


## Topological sort: depends_on -> load_after -> priority -> id.
static func _sort_mods(list: Array[Dictionary]) -> Array[Dictionary]:
	var by_id: Dictionary = {}
	for m in list:
		by_id[m["id"]] = m
	var pending: Array[Dictionary] = []
	pending.assign(list)
	pending.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ra := _rank_of(str(a["id"]))
		var rb := _rank_of(str(b["id"]))
		if ra != rb:
			return ra < rb
		var pa := int(a.get("priority", 0))
		var pb := int(b.get("priority", 0))
		if pa != pb:
			return pa < pb
		return str(a["id"]) < str(b["id"]))

	var out: Array[Dictionary] = []
	var done: Dictionary = {}
	while not pending.is_empty():
		var moved := false
		for i in range(pending.size()):
			var m: Dictionary = pending[i]
			if _deps_ready(m, by_id, done):
				out.append(m)
				done[m["id"]] = true
				pending.remove_at(i)
				moved = true
				break
		if not moved:
			var names: Array[String] = []
			for m in pending:
				names.append(str(m["id"]))
			_errors.append("dependency cycle, not loaded: %s" % ", ".join(names))
			break
	return out


static func _deps_ready(m: Dictionary, by_id: Dictionary, done: Dictionary) -> bool:
	for dep in m.get("depends_on", []):
		if not done.has(str(dep)):
			return false
	for after in m.get("load_after", []):
		# load_after is soft: wait only if such a mod exists at all.
		if by_id.has(str(after)) and not done.has(str(after)):
			return false
	return true


static func _dir_of(id: String) -> String:
	_scan()
	for m in _mods:
		if str(m["id"]) == id:
			return str(m["dir"])
	return ""


# --- applying entries ---------------------------------------------------------

static func _apply_entry(m: Dictionary, e: Dictionary, base: Variant, is_array: bool, db: String) -> bool:
	var mod_id := str(m.get("id", ""))
	var key := str(e.get("key", "")).strip_edges()
	var op := str(e.get("op", "add")).to_lower()
	if key == "":
		_errors.append("mod '%s': entry without key (into=%s)" % [mod_id, str(e.get("into", "?"))])
		return false
	if op != "add" and op != "patch" and op != "remove" and op != "append":
		_errors.append("mod '%s': unknown op '%s' at '%s'" % [mod_id, op, key])
		return false

	if op == "remove":
		if not _has_def(base, key, is_array, db):
			_warnings.append("mod '%s': remove '%s' - no such key" % [mod_id, key])
			return false
		_erase_def(base, key, is_array, db)
		return true

	var missing: Array[String] = []
	var fields: Dictionary = {}
	for k in e:
		if str(k) in ENTRY_META:
			continue
		fields[str(k)] = _expand(e[k], missing)
	if not missing.is_empty():
		# A lost asset is not a "pink square in game" but a refused entry.
		_errors.append("mod '%s': '%s' - files not found: %s" % [mod_id, key, ", ".join(missing)])
		return false

	var existing: Variant = _get_def(base, key, is_array, db)
	var exists: bool = existing is Dictionary

	# append: adds items to a list inside a rules record — that is how a mod adds
	# a new magic sphere or armor type without rewriting the whole list
	# (a rewrite easily loses a neighbouring mod's change).
	if op == "append":
		if not exists:
			_errors.append("mod '%s': append '%s' - no such key" % [mod_id, key])
			return false
		var cur: Variant = (existing as Dictionary).get("value", null)
		var add: Variant = fields.get("value", null)
		if not (cur is Array) or not (add is Array):
			_errors.append("mod '%s': append '%s' - the value is not a list" % [mod_id, key])
			return false
		var merged: Dictionary = (existing as Dictionary).duplicate(true)
		var merged_list: Array = (cur as Array).duplicate()
		merged_list.append_array(add as Array)
		merged["value"] = merged_list
		_put_def(base, key, merged, is_array, db)
		_note_patch(db, key, mod_id)
		return true

	if op == "patch":
		if not exists:
			_errors.append("mod '%s': patch '%s' - no such key (use add for a new one)" % [mod_id, key])
			return false
		_put_def(base, key, _deep_merge(existing, fields), is_array, db)
		_note_patch(db, key, mod_id)
		return true

	# op == "add"
	if exists:
		_errors.append("mod '%s': key '%s' is already taken (%s) - op \"patch\" is required" % [mod_id, key, _owner_of(db, key)])
		return false
	var ext := str(e.get("extends", "")).strip_edges()
	var def: Dictionary = {}
	if ext != "":
		var parent: Variant = _get_def(base, ext, is_array, db)
		if not (parent is Dictionary):
			_errors.append("mod '%s': '%s' - extends '%s' not found in %s" % [mod_id, key, ext, db])
			return false
		def = _deep_merge(parent, fields)
	else:
		def = fields
	_put_def(base, key, def, is_array, db)
	_owners[db + "|" + key] = mod_id
	return true


static func _owner_of(db: String, key: String) -> String:
	return str(_owners.get(db + "|" + key, "game base"))


static func _note_patch(db: String, key: String, mod_id: String) -> void:
	var k := db + "|" + key
	if not _patchers.has(k):
		_patchers[k] = []
	var list: Array = _patchers[k]
	if mod_id in list:
		return
	list.append(mod_id)
	if list.size() == 2:
		_warnings.append("'%s' (%s) is edited by two mods: %s - the last one wins" % [key, db, ", ".join(list)])


static func _get_def(base: Variant, key: String, is_array: bool, db: String) -> Variant:
	if is_array:
		var field := str(DB_KEY_FIELD.get(db, "key"))
		for raw in (base as Array):
			if raw is Dictionary and str((raw as Dictionary).get(field, "")) == key:
				return raw
		return null
	return (base as Dictionary).get(key, null)


static func _has_def(base: Variant, key: String, is_array: bool, db: String) -> bool:
	return _get_def(base, key, is_array, db) is Dictionary


static func _put_def(base: Variant, key: String, def: Dictionary, is_array: bool, db: String) -> void:
	var copy: Dictionary = def.duplicate(true)
	if is_array:
		var arr: Array = base
		var field := str(DB_KEY_FIELD.get(db, "key"))
		for i in range(arr.size()):
			var raw: Variant = arr[i]
			if raw is Dictionary and str((raw as Dictionary).get(field, "")) == key:
				arr[i] = copy
				return
		if not copy.has(field):
			copy[field] = key
		arr.append(copy)
		return
	(base as Dictionary)[key] = copy


static func _erase_def(base: Variant, key: String, is_array: bool, db: String) -> void:
	if is_array:
		var arr: Array = base
		var field := str(DB_KEY_FIELD.get(db, "key"))
		for i in range(arr.size() - 1, -1, -1):
			var raw: Variant = arr[i]
			if raw is Dictionary and str((raw as Dictionary).get(field, "")) == key:
				arr.remove_at(i)
		return
	(base as Dictionary).erase(key)


static func _deep_merge(base: Dictionary, over: Dictionary) -> Dictionary:
	var out: Dictionary = base.duplicate(true)
	for k in over:
		var v: Variant = over[k]
		if out.has(k) and out[k] is Dictionary and v is Dictionary:
			out[k] = _deep_merge(out[k], v)
		else:
			out[k] = v.duplicate(true) if (v is Dictionary or v is Array) else v
	return out


## Expands `mod://<id>/...` into a real path; collects files that are missing.
static func _expand(value: Variant, missing: Array[String]) -> Variant:
	match typeof(value):
		TYPE_STRING:
			var s: String = value
			if not s.begins_with("mod://"):
				return s
			var resolved := resolve(s)
			if resolved == s or not FileAccess.file_exists(resolved):
				missing.append(s)
			return resolved
		TYPE_DICTIONARY:
			var d: Dictionary = value
			var out: Dictionary = {}
			for k in d:
				out[k] = _expand(d[k], missing)
			return out
		TYPE_ARRAY:
			var arr: Array = []
			for v in (value as Array):
				arr.append(_expand(v, missing))
			return arr
	return value
