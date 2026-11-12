class_name Lore
extends RefCounted
## Ленивая загрузка канона мира: assets/lore/world.json + npcs.json.
##
## Паттерн — как Loc/ItemDB: JSON на диске, кэш в static, ошибка файла
## не фатальна (пустые словари, warning). Имена магов и городов НЕ дублируются
## в коде игры — их читает только этот класс.
##
## Раса героя в Game.hero_race: human | necro | druid | ork.
## Ключи фракций в world.json: humans | necro | druid | ork.
## Маппинг — hero_race_to_faction() / faction_to_hero_race().

const WORLD_PATH := "res://assets/lore/world.json"
const NPCS_PATH := "res://assets/lore/npcs.json"

## Game.hero_race -> ключ фракции в world.json / npcs.json.
const RACE_TO_FACTION := {
	"human": "humans",
	"necro": "necro",
	"druid": "druid",
	"ork": "ork",
}

## Человекочитаемое имя фракции для витрин (таверна/магазин). Это подпись
## интерфейса, а не лор: канон имён живёт в assets/lore/world.json.
## Имя берётся из ui.json по ключу `ui.faction.<race>`, чтобы вкладка «Отношения»
## не оставалась русской в EN-режиме.
const FACTION_KEY := {
	"humans": "ui.faction.humans",
	"ork": "ui.faction.ork",
	"necro": "ui.faction.necro",
	"druid": "ui.faction.druid",
}


static func faction_label(race: String) -> String:
	if race == "":
		return ""
	if FACTION_KEY.has(race):
		return Loc.t(str(FACTION_KEY[race]))
	return race

static var _world: Dictionary = {}
static var _npcs: Dictionary = {}
static var _loaded := false


static func hero_race_to_faction(race: String) -> String:
	return str(RACE_TO_FACTION.get(race, race))


static func faction_to_hero_race(faction_id: String) -> String:
	for race in RACE_TO_FACTION:
		if str(RACE_TO_FACTION[race]) == faction_id:
			return str(race)
	return faction_id


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_world = {}
	_npcs = {}
	_world = _load_json(WORLD_PATH)
	_npcs = _load_json(NPCS_PATH)


static func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("Lore: не читается %s — канон пуст" % path)
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		return parsed
	push_warning("Lore: %s не JSON-объект" % path)
	return {}


static func clear_cache() -> void:
	_loaded = false
	_world = {}
	_npcs = {}


static func world() -> Dictionary:
	_ensure_loaded()
	return _world


static func npcs() -> Dictionary:
	_ensure_loaded()
	return _npcs


static func npc(id: String) -> Dictionary:
	_ensure_loaded()
	var n: Variant = _npcs.get("npcs", {}).get(id, null)
	return n if n is Dictionary else {}


static func faction(id: String) -> Dictionary:
	_ensure_loaded()
	var f: Variant = world().get("factions", {}).get(id, null)
	return f if f is Dictionary else {}


## Имя города фракции. Принимает и Game.hero_race, и ключ world.json.
static func faction_city(race: String) -> String:
	var fid := hero_race_to_faction(race)
	return str(faction(fid).get("city", ""))


## Имя великого мага фракции из world.json («Маша» и т.д.).
static func faction_archmage(race: String) -> String:
	var fid := hero_race_to_faction(race)
	return str(faction(fid).get("archmage", ""))


## Словарь NPC-мага (speech/personality) или {}.
static func archmage_npc(race: String) -> Dictionary:
	_ensure_loaded()
	var fid := hero_race_to_faction(race)
	var all: Dictionary = _npcs.get("npcs", {})
	for id in all:
		var n: Dictionary = all[id]
		if bool(n.get("archmage", false)) and str(n.get("faction", "")) == fid:
			return n
	return {}


## Реплики мага по типу: greet | idle | refuse.
static func archmage_speech(race: String, kind: String) -> Array:
	var n := archmage_npc(race)
	var speech: Variant = n.get("speech", {})
	if not (speech is Dictionary):
		return []
	var lines: Variant = (speech as Dictionary).get(kind, [])
	if lines is Array:
		return lines
	return []


## Стартовый словарь archmage для фракции (для WorldState.new_faction).
static func archmage_seed(race: String) -> Dictionary:
	var fid := hero_race_to_faction(race)
	var mname := faction_archmage(race)
	var city := faction_city(race)
	if mname == "":
		var n := archmage_npc(race)
		mname = str(n.get("label", ""))
		if city == "":
			city = str(n.get("city", ""))
	return {
		"name": mname,
		"race": race,
		"city": city,
		"power": 60.0,
		"tier": 1,
		"stance": "offensive",
		"speak_to": fid,
	}
