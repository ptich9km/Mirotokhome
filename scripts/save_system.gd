class_name SaveSystem
extends RefCounted
## Saves: slots, autosave, versioning, atomic writing.
##
## A static class, DELIBERATELY without an autoload — adding an autoload to
## project.godot is an approval gate (AGENTS §9.4), and it is not needed here:
## all methods are static, the class has no state.
##
## Format (player decision 22.10): EVERY slot is its own folder
## `user://saves/<slot>/` with three progress elements:
##   hero.json    — the hero: class, stats, HP/mana, gold, inventory, equipment,
##                  skills, position;
##   map.json     — the map: zone, seed, fog, plus the world files of the current map
##                  (`*.alm`, `.npcs.json`, `.structures.json`, `.herbs.json`,
##                  `.portal.json`, `.spawn.json`, `.nowalk.json`,
##                  `.allowwalk.json`) — the map goes into the save byte for byte,
##                  so after a game restart it is the very same map;
##   process.json — progress: the SIM world, events, quests, slot metadata
##                  (name, class, level, day, time of writing).
## Every element is written atomically (.tmp → flush → rename), previous versions
## of the files go to `.bak`. When the player deletes a slot the folder becomes empty:
## only these three files remain, empty in content.
##
## The version lives in `version` inside every element; an element newer than the current
## one is rejected as a whole rather than "read as is" — otherwise corrupt/foreign data
## silently spoils the game state.
##
## v2 (28.10): `party` (mercenaries) and `hotbar` (keys 1..9) appeared in hero.
## Both fields are optional: a v1 save is read without migration — an empty party and an empty
## hotbar are exactly what v1 had, where they were not saved at all.

const DIR := "user://saves/"
const VERSION := 2
## Where saves live. This directory must NOT be touched by any test run
## or tool: all scenarios (headless tests, `--path` on the same
## installation, project copies) use the same `user://`
## (`%APPDATA%/Godot/app_userdata/<config/name>`), so a test that touched
## slots wiped the player's live saves (report 22.10: "the saves are visible
## until you close the game" — the test overwrote them when the window closed).
## Tests and tools write only to `TEST_DIR` (see `use_test_dir()`).
static var _dir := DIR

## Save elements inside the slot folder.
const HERO_FILE := "hero.json"
const MAP_FILE := "map.json"
const PROCESS_FILE := "process.json"
const PARTS := [HERO_FILE, MAP_FILE, PROCESS_FILE]
## A snapshot of the PREVIOUS save of the slot, taken BEFORE the overwrite: a full document
## of the same shape `load_slot()` returns (`{version, meta, data: {hero,
## map, world, events, quests}}`). The per-element `.bak` files hold the previous versions
## of individual files, and the world is torn across three elements — restoring
## "the previous save" from them is only possible by gluing. The snapshot is whole and
## written as a file so that both a test and the player's hand can read it.
const PREV_FILE := "previous.json"
## World files of the current map: `.alm` and the sidecars AlmMap reads
## (structures/NPCs/herbs/portal/spawn/walkability markup).
const WORLD_SUFFIXES := [
	".alm", ".npcs.json", ".structures.json", ".herbs.json",
	".portal.json", ".spawn.json", ".nowalk.json", ".allowwalk.json",
	".outposts.json", ".meta.json",
]


## Switch slot storage to the test directory. Called ONLY
## by tests (`tests/save_sandbox.gd`): live saves stay untouched.
static func use_test_dir(path: String) -> void:
	_dir = path if path.ends_with("/") else path + "/"
	ensure_dir()


## The current slot directory: the game `user://saves/` or the test one.
static func dir() -> String:
	return _dir
## Game slots for the "Load game" menu (player decision 05.10: 6).
const SLOT_COUNT := 6
const AUTOSAVE_SLOT := "autosave"

## The slots shown to the player.
const PLAYER_SLOTS := ["slot_0", "slot_1", "slot_2", "slot_3", "slot_4", "slot_5"]


static func ensure_dir() -> void:
	DirAccess.make_dir_recursive_absolute(_dir)


## The slot folder: hero.json / map.json / process.json and the world files
## of the current map live inside it.
static func slot_dir(slot: String) -> String:
	return _dir + slot + "/"


# --- Paths ---

static func part_path(slot: String, part: String) -> String:
	return slot_dir(slot) + part


## The main slot file (the hero). The former name of the single save file.
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


# --- Writing ---

## A flat payload of the old format (all progress in one `data` block, without
## `quests`/`world`) — that is how it was written before 22.10 and how tools that
## only need the hero still write it. Such a payload is laid out over the three
## elements the usual way: no separate "old-map" remains in the slot.
static func _is_flat_payload(payload: Dictionary) -> bool:
	return not (payload.get("quests", null) is Dictionary) \
		and not (payload.get("world", null) is Dictionary)


## Write a slot. payload — a v1 dictionary (see build_payload). Returns
## an error message or "" on success.
##
## Order: hero → progress → map. If writing the map fails (no disk
## space), the slot keeps the previous map and fog instead of a half-new state.
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
	# A snapshot of the previous state — BEFORE the first overwrite of the elements.
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


## The map: the description in map.json and the world files next to it (byte for byte).
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


## Copy the world files (`.alm` + sidecars) from the map directory into the slot
## folder under the stable name `<basename>.…`; the basename is recorded in map.json.
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


# --- Reading ---

## Put the current save of the slot (if there is one) into `previous.json`.
## The snapshot is what `load_slot()` returns; if the slot is corrupt or empty,
## we do not touch the snapshot: an old whole one is better than an empty one.
static func _snapshot_previous(slot: String) -> void:
	var current := load_slot(slot)
	if current.is_empty() or current.has("error"):
		return
	# The snapshot must NOT be overwritten if the current save is readable ONLY
	# from `previous.json` (all elements broken): otherwise it would be overwritten
	# by a mirror of the same snapshot and the slot would become unrecoverable.
	if not _parts_readable(slot):
		return
	_write_raw(prev_path(slot), JSON.stringify(JsonSafe.encode({
		"version": int((current.get("data", {}) as Dictionary).get("version", VERSION)),
		"meta": current.get("meta", {}),
		"data": current.get("data", {}),
	})))


## Both main elements of the slot are readable on their own (without the snapshot).
static func _parts_readable(slot: String) -> bool:
	for part in [HERO_FILE, PROCESS_FILE]:
		var doc := _read_doc(part_path(slot, part))
		if doc.is_empty() or not (doc.get("data", null) is Dictionary):
			return false
	return true


## Read a slot. An empty dictionary — nothing to read. "version" — the element
## is newer than the current code. "corrupt" — the file exists but does not read, .bak
## did not help and there is no snapshot of the previous save.
## data — the v1 summary (hero/map/world/events/quests), meta — the slot metadata.
static func load_slot(slot: String) -> Dictionary:
	var hero := _read_part(slot, HERO_FILE)
	if hero.is_empty() and FileAccess.file_exists(part_path(slot, HERO_FILE)):
		# The file exists but there is nothing to read it with: we try the snapshot of the
		# previous save and re-read — after that the path is the same.
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
	# The map is optional: old slots and manual scenarios write only the hero.
	# An empty/corrupt map.json must not bury a working save.
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


## A slot element is written through JsonSafe.encode (Vector2/Color → `__t` tags),
## so when reading, its data must go through the reverse decoding.
## Without that the hero position arrives as a dictionary {"__t": "v2", ...}, and the hero
## stands at the map spawn after loading.
static func _decoded(v: Variant) -> Variant:
	var out: Variant = JsonSafe.decode(v)
	# Double tags: old slots held the encoded block already inside
	# `data` (JsonSafe.encode(payload) as a whole), and decode stopped at the
	# outer layer.
	if out is Dictionary and (out as Dictionary).has(JsonSafe.TAG):
		return JsonSafe.decode(out)
	return out


## Write one element atomically: .tmp → flush → old to .bak → rename.
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


## The current file → .bak; the previous .bak is removed beforehand.
static func _recycle_to_bak(path: String) -> void:
	var bak := bak_of(path)
	if FileAccess.file_exists(bak):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(bak))
	DirAccess.rename_absolute(ProjectSettings.globalize_path(path),
		ProjectSettings.globalize_path(bak))


## A copy of the file with the same order (.tmp → flush → old to .bak → rename).
## Copying over itself is a no-op: without this check the file would go
## to `.bak` and nothing would remain in its place (the slot lost the map).
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


## Read a slot element: a document, {} (no file) or {"error": …}.
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
	# The main file exists but does not read: if .bak reads — we repair silently.
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


## Roll the slot back to .bak. true if the rollback was performed.
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


## A broken slot → the snapshot of the previous save.
##
## The per-element rollback via `.bak` does not help when the file is corrupted for the first
## time (no `.bak`) or all three elements are corrupted (a foreign process wrote the folder).
## `previous.json` is atomic and self-sufficient, so if it exists and
## reads — we put its content back into all three elements.
## true — the slot was restored.
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
	# The snapshot must NOT be overwritten: `previous.json` is the last version
	# that was not corrupted; otherwise the next failure would overwrite it with a mirror
	# of the broken slot.
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


# --- Slot list for the screen ---

## Metadata of all slots for the UI. Does not load heavy data: the metadata lives
## in every slot element.
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


## The slot is empty: either there are no elements or they hold no data (a deleted slot).
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


## The newest record among all slots. "" — nothing to save.
## Compared by meta.stamp: the file order in the directory says nothing
## about the save order, and relying on it is not allowed.
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


# --- Slot world files ---

## The main map file inside the slot folder, "" — there is no map in the slot.
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


## The slot was deleted by the player: the folder becomes empty — three elements without data,
## the world files, `.bak` and the snapshot of the previous state are removed. The folder
## itself stays: it IS the slot.
static func clear_slot(slot: String) -> void:
	var dir_path := slot_dir(slot)
	if not DirAccess.dir_exists_absolute(dir_path):
		return
	_remove_files_where(dir_path, func(fn: String) -> bool: return PARTS.has(fn))
	var empty := {"version": VERSION, "meta": {}, "data": {}}
	for part in PARTS:
		_write_raw(part_path(slot, part), JSON.stringify(empty))


## Removes from the folder all FILES (not subdirectories) for which keep returned false.
## `.tmp` files are always removed: after deleting a slot they leave junk behind.
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


# --- Save composition (v1) ---

## Build a payload from the live game state.
##
## The party (Game.party) is deliberately NOT saved in v1: mercenaries are described
## in hero.party, and without restoring them from mercenary_db they would be
## garbage in the party. We will bring them back together with the roster in v2.
##
## systems — event/quest blocks collected by the caller: {"events": Array,
## "quests": Dictionary}. Without them they are taken from the singleton nodes if those exist.
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
		"known_recipes": player.known_recipes.duplicate(),
		"sphere_books": player.sphere_books.duplicate(true),
		"position": player.global_position,
		# v2: party and hotbar. Summoned creatures (lifespan > 0) are not saved: they
		# are temporary and tied to the cast lifetime, not to the hero walk.
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
			# The map is stored as whole files in the slot folder (decision 22.10), so
			# we save the path to the current .alm and its stable name.
			"path": str(map_files.get("path", "")),
			"basename": str(map_files.get("basename", "")),
			# Captured outposts (package B): the key includes zone/sector/seed,
			# so the dictionary is shared by all world maps, like Game.hotbar.
			"outposts": Game.outposts_captured.duplicate(),
			# Shop stock (09.11): limited regeneration bottles. The keys carry
			# the map seed, so the whole dictionary travels like the hotbar.
			"shop_stock": Game.shop_stock.duplicate(),
			"shop_stock_day": int(Game.shop_stock_day),
		},
		"hero": hero,
		"world": world_dict,
		"events": events,
		"quests": quests,
		# Mod profile: what was enabled at the moment of saving. From it, on
		# load, you can see which mods are missing (see _check_mods).
		"mods": ModLoader.save_profile(),
	}
	var meta := {
		"hero_name": Game.hero_name,
		"hero_class": Game.hero_class,
		"level": _hero_level(player),
		"day": int(world_dict.get("day", 0)),
		"zone": str(Game.map_zone),
		"seed": int(Game.map_seed),
		# Unix time of writing: the "Continue" screen must be able to pick the freshest
		# slot, and the order in the list is defined only by it.
		"stamp": int(Time.get_unix_time_from_system()),
	}
	meta.merge(world_meta, true)
	payload["meta"] = meta
	return payload


## The party into the save: clean data, no node references (save-systems: we save
## state, not scene objects). Summoned creatures (lifespan > 0) are
## temporary, they are not part of the hero walk.
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


## Read the party from the save: the set must exist in units_db, otherwise
## the record is dropped (a save of an old version / an edit of the data must not give birth to
## a "ghost mercenary" without animation).
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


## Hotbar from the save: slots 0..8, only existing spells and items.
## We drop an unknown record — otherwise the key silently does nothing.
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


## The current game map: {"path": user:// path to .alm, "basename": name}.
## There is no map in the file (a map from main.tscn/dev) — empty strings.
static func world_files() -> Dictionary:
	var out := {"path": "", "basename": ""}
	if Game.pending_map_path != "" and FileAccess.file_exists(Game.pending_map_path):
		if not Game.pending_map_path.begins_with("res://"):
			out["path"] = Game.pending_map_path
			# Zone/sector — part of the name, as in the generator maps
			# (`map_<seed>_<sector>_<race>`). Without it `restore_zone_map` did not
			# find the ready-made map after exit and return: the name had no
			# sector token, and the map was generated anew at start.
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


## Prepare the slot world for loading BEFORE the scene change: the map files from the
## slot folder are laid out into user://maps/ under a stable name, the path goes
## to Game.pending_map_path (it takes priority over the seed). There is no map in the
## slot — the seed path stays, as before.
static func restore_map(slot: String) -> void:
	Game.pending_map_path = ""
	var src := world_map_path(slot)
	if src == "":
		return
	if not _stage_world_files(slot, src, "save_%s" % slot):
		push_warning("SaveSystem: карта слота %s не разложена" % slot)
		return
	Game.pending_map_path = MapGenerator.MAPS_DIR + "save_%s.alm" % slot


## A map of ANOTHER zone from the slot folder (a portal transition after loading).
## Returns the path to the laid-out `.alm` in user://maps/ or "" — there is no such zone in
## the slot, we build the map by seed.
##
## We look for `<slot basename>_<zone>*.alm`: MapGenerator puts the city
## race into the name too (`map_<seed>_<zone>_<race>.alm`), so we compare by prefix.
static func restore_zone_map(slot: String, zone: String) -> String:
	var dir_path := slot_dir(slot)
	var d := DirAccess.open(dir_path)
	if d == null:
		return ""
	var slot_base := _basename_of(_read_doc(part_path(slot, MAP_FILE)).get("data", {}))
	if slot_base == "":
		return world_map_path(slot)
	# The current map of the slot already belongs to this zone (the name has the sector
	# token) — we take exactly it and prepare it in user://maps/ under a stable
	# name. Without that, returning to the starting (ready-made) map generated
	# a new map by seed.
	if slot_base.split("_").has(zone):
		if _stage_world_files(slot, slot_dir(slot) + slot_base + ".alm", "save_%s" % slot):
			return MapGenerator.MAPS_DIR + "save_%s.alm" % slot
	# The map name is `map_<seed>_<sector>_<race>` (or the old `_<zone>_`).
	# Sector/zone is a separate name token: neighbouring sectors have their own seed, so
	# "seed and race" cannot be compared, and what is unique here is the sector.
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
	# The freshest map of the zone — the one edited last. Before we took the
	# alphabetically first one: after returning to a ready-made map that was an old
	# `custom_<sector>` snapshot rather than the current `save_<slot>_<sector>`.
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


## Put the zone map (and its sidecars) into the slot folder. Called when
## moving between zones: the slot accumulates the maps of all visited zones so that
## `restore_zone_map` finds them after a restart. The name is the map own name
## (`map_<seed>_<zone>_<race>`) so that the search by zone works.
static func store_zone_map(slot: String, map_path: String) -> String:
	if map_path == "" or not FileAccess.file_exists(map_path):
		return "карты нет: %s" % map_path
	return _mirror_world_files(slot, map_path, map_path.get_file().get_basename())


## The map name from map.json. Comparing it with file names head-on is not allowed:
## `data` is encoded by JsonSafe, while some old slots wrote a live dictionary.
static func _basename_of(map_data: Variant) -> String:
	var d: Variant = _decoded(map_data)
	if d is Dictionary:
		return str((d as Dictionary).get("basename", ""))
	return ""


## Lay out the `.alm` and sidecars from the slot folder into user://maps/ under the name
## `dst_base`. true — at least one file was copied.
##
## Copying over itself (the zone map already lies in user://maps/ and the slot
## took it from there) is not an error: the file is in place and reads.
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


## Apply the payload to the game. Call BEFORE loading the map scene: first
## we set the map (pending_map_path or seed), then create the world.
##
## player may be null - then only Game.* are applied (the hero choice on
## the character_select screen applies them BEFORE the transition to the game scene, where
## there is no player yet). Before, the player == null check stood above the
## Game.hero_* block, and the whole hero was silently lost.
##
## slot — the slot we read from: the game entry takes the map files from
## the save folder. Without slot the map is taken by seed.
## The save mod profile against the current set: missing and updated mods are
## a warning in the log, not a refusal to load the world. A lesson from Space Engineers,
## where deleting a mod breaks the world: our keys are strings, the items simply will not be
## found, and the game must still open.
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
	# Fog and events (19.10): applied by the nodes after the map is built.
	Game.pending_fog_rle = str(map_d.get("fog", ""))
	Game.pending_outposts_captured = {}
	# The save is the source of truth: the captures of the previous hero must not "leak" into
	# the slot being loaded (even if the maps share a seed).
	Game.outposts_captured.clear()
	var cap: Variant = map_d.get("outposts", {})
	if cap is Dictionary:
		for key in cap:
			if bool((cap as Dictionary)[key]):
				Game.pending_outposts_captured[str(key)] = true
	# Shop stock (09.11): without restoring it, loading a save would refill every
	# shelf. An older save simply has none - the stock is created on first use.
	Game.shop_stock.clear()
	var stock: Variant = map_d.get("shop_stock", {})
	if stock is Dictionary:
		for key in stock:
			Game.shop_stock[str(key)] = int((stock as Dictionary)[key])
	Game.shop_stock_day = int(map_d.get("shop_stock_day", -1))
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
	# Migration of the old Allods ids → race portraits.
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
	# Hero position: always put it into Game (for player==null and for apply before
	# the scene is rebuilt). Before, the field was written to the file but never applied —
	# the hero always stood at spawn after "Continue".
	var pos_v: Variant = h.get("position", null)
	if pos_v is Vector2:
		Game.load_position = pos_v as Vector2
		Game.load_position_valid = true
	else:
		Game.clear_load_position()
	# Runtime state for the new Player after change_scene: gold/inventory/
	# equipment/HP/skills. Without it the player _ready handed out the starter
	# set again, and the save "lost" the inventory although the file was intact.
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
	# v2: party and hotbar are put into Game statics — the nodes are created by game.gd when
	# the map is already built (a mercenary needs a walkable tile, not an empty scene).
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
	player.known_recipes.clear()
	for raw in _str_array(h.get("known_recipes", [])):
		player.known_recipes.append(str(raw))
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
