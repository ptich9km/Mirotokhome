# ============================================================================
# СЛОЙ 1 — WorldState. Чистые данные мира, RefCounted, БЕЗ Godot-нод.
#
# Правила архитектуры (см. AGENTS.md, «Слой 1 Data»):
#  * Реестры юнитов/городов/фракций/армий/регионов — Dictionary {id: Dictionary}.
#  * Ссылки между сущностями — ТОЛЬКО по строковому id ("c-1", "f-2"), никогда
#    по указателю на ноду/объект. SIM читает мир по id, Presentation по id же
#    находит своих «наёмных» юнитов.
#  * Мир — чистый RefCounted; можно гонять headless (sim_runner) без сцены.
#  * to_dict()/from_dict() — полная сериализация (сохранения = только этот слой).
# ============================================================================
extends RefCounted
# NOTE (Слой-2.5): NO `class_name` here on purpose — headless autoload parsing
# does not resolve global class symbols before the class cache is built, so a
# `class_name` + `preload` of this script fails with "Could not preload".
# Cross-references live in world_bus.gd as preload-by-path consts instead.
# ============================================================================

# id-суффиксы (стабильные, не случайные) ------------------------------------
var _u := 0  # юниты
var _c := 0  # города
var _f := 0  # фракции
var _a := 0  # армии
var _r := 0  # регионы

# --- Собственно состояние мира ---------------------------------------------
var units: Dictionary = {}      # "u-1" -> {"id","name","faction_id","city_id","sphere","curr_hp","max_hp","attack","defense",...}
var cities: Dictionary = {}     # "c-1" -> {"id","name","faction_id","region_id","pos","economy":{...},"population","loyalty"}
var factions: Dictionary = {}   # "f-1" -> {"id","name","color","relations":{fid:int},...}
var armies: Dictionary = {}     # "a-1" -> {"id","faction_id","unit_ids":[],"pos","target","owner_player":false}
var regions: Dictionary = {}    # "r-1" -> {"id","name","area_px":Vector2,"cities":[],"roads":[],"faction_ids":[]}

# --- Служебные поля тика (чистые данные, сериализуются) --------------------
var day := 0                 # номер дня мира
var global_threat := 0.0     # глобальная угроза 0..1 (растёт со временем)
var relations := {}          # "fA:fB" -> int (>-100..100), матрица отношений
## Репутация ГЕРОЯ у фракций (22.10, квесты): "humans" -> int (-100..100).
## Отличать от relations: там отношения фракций между собой (SIM), здесь —
## как фракция относится к герою. Награда за квест поднимает это число.
var hero_reputation := {}
var hero := {                # «привилегированный» герой: в SIM, но щадится угрозой
	"name": Loc.t("ui.sim.hero_default"), "faction_id": "", "level": 1,
	"curr_hp": 100, "max_hp": 100, "pos": Vector2.ZERO,
}
var journal: Array[Dictionary] = []   # журнал событий мира (день, вид, текст)

# --- Карта мира 4x3 (23.10) ---------------------------------------------------
## Сид мира: из него выводятся сиды всех 12 секторов (WorldMap.seed_of).
var world_seed := 0
## "s41" -> {col,row,tier,base,relief,size,seed,owner,capital_of,discovered,fog,outposts}
var sectors: Dictionary = {}
## "o-s41-0" -> {sector,cell,owner,locked,capture_faction,capture_progress,build_progress,built}
## Механика захвата — следующий этап; поле заведено сразу, чтобы сейв не мигрировать.
var outposts: Dictionary = {}

const WORLD_CAPITAL_FACTIONS: Array = ["humans", "ork", "necro", "druid"]

# --- Служебное ----------------------------------------------------------------

func _id(kind: String) -> String:
	if kind == "u":
		_u += 1
		return "u-%d" % _u
	elif kind == "c":
		_c += 1
		return "c-%d" % _c
	elif kind == "f":
		_f += 1
		return "f-%d" % _f
	elif kind == "a":
		_a += 1
		return "a-%d" % _a
	elif kind == "r":
		_r += 1
		return "r-%d" % _r
	return "%s-?_%d" % [kind, randi()]

func new_unit(faction_id: String = "", sphere: String = "") -> Dictionary:
	var id := _id("u")
	units[id] = {
		"id": id, "name": Loc.f("ui.sim.unit", [id]), "faction_id": faction_id, "city_id": "",
		"sphere": sphere, "curr_hp": 100, "max_hp": 100,
		"attack": 10, "defense": 5, "magic": 0, "level": 1,
	}
	return units[id]

func new_city(name: String, faction_id: String = "", region_id: String = "",
		sector_id: String = "") -> Dictionary:
	var id := _id("c")
	cities[id] = {
		"id": id, "name": name, "faction_id": faction_id, "region_id": region_id,
		"sector_id": sector_id,
		"pos": Vector2.ZERO, "population": 100, "loyalty": 60.0,
		"economy": { "gold": 50, "food": 100, "prod": 5, "price_base": {} },
	}
	return cities[id]


## Economy block of a city — the ONE place that owns the schema.
##
## `new_city` has always kept gold/food/prod inside `economy`, while the first
## version of `TickSettlements` read them as flat city keys. Flat keys loaded
## from such saves are folded back into `economy` once and removed, so old saves
## keep their numbers and there is no second source of truth afterwards.
func city_economy(c: Dictionary) -> Dictionary:
	var raw: Variant = c.get("economy", null)
	var eco: Dictionary = raw if raw is Dictionary else {}
	for key in ["gold", "food", "prod"]:
		if c.has(key):
			if not eco.has(key):
				eco[key] = c[key]
			c.erase(key)
	if not eco.has("gold"):
		eco["gold"] = 50.0
	if not eco.has("food"):
		eco["food"] = 100.0
	if not eco.has("prod"):
		eco["prod"] = 5.0
	c["economy"] = eco
	return eco

func new_faction(name: String, race: String = "") -> Dictionary:
	var id := _id("f")
	var f: Dictionary = {
		"id": id, "name": name, "color": Color(1, 1, 1),
		"relations": {}, "race": race,
	}
	f["archmage"] = _seed_archmage(race)
	factions[id] = f
	return f


## Добить фракции четырёх рас (28.10).
##
## Генератор городов знает все четыре (MapGenerator.CITY_POPULATION), а
## WorldState создавал только «Люди» и «Орки»: у нежити и друидов не было
## великого мага, и ArchmagePanel честно писал «в этом городе великого мага
## нет». Старые сейвы приходят с тем же набором из двух фракций.
##
## Возвращает, сколько фракций добавлено. Идемпотентна.
func ensure_race_factions() -> int:
	var added := 0
	var lore = load("res://scripts/lore.gd")
	for race in WORLD_CAPITAL_FACTIONS:
		if _has_faction_for_race(str(race)):
			continue
		var label := str(race)
		if lore != null:
			label = str(lore.faction_label(str(race)))
		new_faction(label, str(race))
		added += 1
	return added


## Фракция этой расы уже есть? Старые миры писали "human", новые — "humans".
func _has_faction_for_race(race: String) -> bool:
	var aliases: Array = [race, race.trim_suffix("s")]
	if race == "ork":
		aliases.append("orc")
	for fid in factions:
		var f: Dictionary = factions[fid]
		var fr := str(f.get("race", ""))
		if fr == "":
			var am: Dictionary = f.get("archmage", {}) as Dictionary
			fr = str(am.get("race", ""))
		if aliases.has(fr):
			return true
	return false


## Великий маг фракции. Данные — из Lore + GameConfig через load-by-path:
## world_state без class_name (headless-canon), ссылки по имени класса запрещены.
static func _seed_archmage(race: String) -> Dictionary:
	var seed_d: Dictionary = {}
	var lore = load("res://scripts/lore.gd")
	if lore != null and race != "":
		seed_d = lore.archmage_seed(race) as Dictionary
	var power := 60.0
	var tier := 1
	var stance := "offensive"
	var cfg = load("res://scripts/game_config.gd")
	if cfg != null:
		power = cfg.getf("archmage", "power_start")
		tier = _tier_of_loaded(power, cfg)
		stance = _stance_of_loaded(power, cfg)
	var out: Dictionary = {
		"name": str(seed_d.get("name", "")),
		"race": race,
		"city": str(seed_d.get("city", "")),
		"power": power,
		"tier": tier,
		"stance": stance,
		"speak_to": str(seed_d.get("speak_to", race)),
	}
	return out


static func _cfg() -> Variant:
	return load("res://scripts/game_config.gd")


static func _tier_of_loaded(power: float, cfg: Variant) -> int:
	if cfg == null:
		if power >= 90.0:
			return 3
		if power >= 65.0:
			return 2
		if power >= 35.0:
			return 1
		return 0
	if power >= cfg.getf("archmage", "tier_3"):
		return 3
	if power >= cfg.getf("archmage", "tier_2"):
		return 2
	if power >= cfg.getf("archmage", "tier_1"):
		return 1
	return 0


static func _stance_of_loaded(power: float, cfg: Variant) -> String:
	var thr := 35.0
	if cfg != null:
		thr = cfg.getf("archmage", "tier_1")
	return "offensive" if power >= thr else "defensive"


## Ступень по power (0..3). Пороги из [archmage], дефолты как в GDD.
static func archmage_tier(power: float) -> int:
	return _tier_of_loaded(power, _cfg())


static func archmage_stance(power: float) -> String:
	return _stance_of_loaded(power, _cfg())


## Ставка платы из [archmage]. kind: ingot | gold | potion.
## Литералы ключей обязаны быть в коде — сторож config_dead_keys_smoke.
const ARCHMAGE_STAKE_KEYS := {
	"ingot": "stake_ingot",
	"gold": "stake_gold",
	"potion": "stake_potion",
}


static func archmage_stake(kind: String) -> float:
	var key := str(ARCHMAGE_STAKE_KEYS.get(kind, ""))
	if key == "":
		return 0.0
	var cfg = _cfg()
	if cfg == null:
		return 0.0
	return cfg.getf("archmage", key)


## Сколько золота даёт одна единица платы (100 = 1.0 от золота).
static func archmage_gold_per_stake() -> int:
	var cfg = _cfg()
	if cfg == null:
		return 100
	return cfg.geti("archmage", "gold_per_stake")


## Маг фракции по id фракции ИЛИ по Game.hero_race (human/ork/necro/druid).
## Старый сейв без archmage -> {} (без падения).
func get_archmage(faction_or_race: String) -> Dictionary:
	if faction_or_race == "":
		return {}
	if factions.has(faction_or_race):
		var f0: Dictionary = factions[faction_or_race]
		return f0.get("archmage", {}) as Dictionary
	var want := faction_or_race
	# human -> humans (ключ world.json), если ищем по расе героя
	var lore = load("res://scripts/lore.gd")
	if lore != null:
		want = lore.hero_race_to_faction(faction_or_race) as String
	for fid in factions:
		var f: Dictionary = factions[fid]
		if str(f.get("race", "")) == faction_or_race:
			return f.get("archmage", {}) as Dictionary
		if str(f.get("race", "")) == want:
			return f.get("archmage", {}) as Dictionary
		var am0: Dictionary = f.get("archmage", {}) as Dictionary
		if str(am0.get("speak_to", "")) == want or str(am0.get("speak_to", "")) == faction_or_race:
			return am0
	return {}


## Сдать ресурс: power += amount. Возвращает сколько tier'ов изменилось
## (может быть отрицательным, если сдача мала и power не пересекает порог —
## прирост всегда >= 0, знак нужен для журнала).
func add_archmage_power(faction_or_race: String, amount: float) -> int:
	var f := _faction_for_archmage(faction_or_race)
	if f.is_empty():
		return 0
	var am: Dictionary = f.get("archmage", {}) as Dictionary
	if am.is_empty():
		return 0
	var cfg = _cfg()
	var power_max := 100.0
	if cfg != null:
		power_max = cfg.getf("archmage", "power_max")
	var old_power := float(am.get("power", 0.0))
	var old_tier := int(am.get("tier", archmage_tier(old_power)))
	var new_power := clampf(old_power + amount, 0.0, power_max)
	var new_tier := archmage_tier(new_power)
	am["power"] = new_power
	am["tier"] = new_tier
	am["stance"] = archmage_stance(new_power)
	f["archmage"] = am
	return new_tier - old_tier


func _faction_for_archmage(faction_or_race: String) -> Dictionary:
	if factions.has(faction_or_race):
		return factions[faction_or_race]
	var want := faction_or_race
	var lore = load("res://scripts/lore.gd")
	if lore != null:
		want = lore.hero_race_to_faction(faction_or_race) as String
	for fid in factions:
		var f: Dictionary = factions[fid]
		if str(f.get("race", "")) == faction_or_race:
			return f
		if str(f.get("race", "")) == want:
			return f
		var am: Dictionary = f.get("archmage", {}) as Dictionary
		if str(am.get("speak_to", "")) == want:
			return f
	return {}

## Репутация героя у фракции: "humans" (раса) или "f-1" (id фракции).
func hero_rep(faction_or_race: String) -> int:
	if faction_or_race == "":
		return 0
	return int(hero_reputation.get(faction_or_race, 0))


## Одна запись журнала мира. Журнал уезжает в сейв целиком, поэтому он
## ограничен: живой календарь (28.10) пишет строки каждый игровой день, и без
## предела файл сохранения рос бы без остановки. Старые записи уходят первыми.
const JOURNAL_MAX := 400

func log_entry(kind: String, text: String) -> void:
	journal.append({ "day": day, "kind": kind, "text": text })
	while journal.size() > JOURNAL_MAX:
		journal.remove_at(0)


## Сдвинуть репутацию героя. Возвращает фактический сдвиг (с учётом клампа).
## Запись в журнал — только для заметных изменений, иначе журнал SIM тонет
## в строчках «+5 репутации» после каждого квеста.
func add_hero_reputation(faction_or_race: String, amount: int) -> int:
	if faction_or_race == "" or amount == 0:
		return 0
	var old := hero_rep(faction_or_race)
	var now := clampi(old + amount, -100, 100)
	hero_reputation[faction_or_race] = now
	var delta := now - old
	if delta != 0 and (absi(delta) >= 10 or now == -100 or now == 100):
		log_entry("reputation",
			"Reputation with %s: %d (%+d)" % [faction_or_race, now, delta])
	return delta


## `power` is a combat-power cache. 0 means "not computed yet" and
## WorldSim._army_power derives it from `unit_ids` on the first fight. The field
## always exists because without it losses were computed from 1 and armies
## fought forever (audit 30.09).
func new_army(faction_id: String, pos: Vector2 = Vector2.ZERO) -> Dictionary:
	var id := _id("a")
	armies[id] = { "id": id, "faction_id": faction_id, "unit_ids": [], "pos": pos, "target": Vector2.ZERO, "owner_player": false, "power": 0 }
	return armies[id]

func new_region(name: String) -> Dictionary:
	var id := _id("r")
	regions[id] = { "id": id, "name": name, "area_px": Vector2(1024, 768), "cities": [], "roads": [], "faction_ids": [] }
	return regions[id]


## True when the live map of this sector already fed the SIM. Loading a save
## must not re-seed the sector and wipe its economy/loyalty.
func has_sector_cities(sector_id: String) -> bool:
	if sector_id == "":
		return false
	for id in cities:
		if str(cities[id].get("sector_id", "")) == sector_id:
			return true
	return false


## Build SIM cities/armies from the city list of the CURRENT map (04.11).
## Fixture records from WorldBus.reseed() are removed on the first real map,
## so the sandbox world no longer survives into a normal game.
func apply_map_cities(sector_id: String, map_cities: Array, region_name: String = "") -> int:
	if sector_id == "" or map_cities.is_empty():
		return 0
	_clear_map_records(sector_id)
	ensure_race_factions()
	var region: Dictionary = _region_for_sector(sector_id, region_name)
	var ordinal := {}
	var added := 0
	var lore = load("res://scripts/lore.gd")
	for raw in map_cities:
		if not (raw is Dictionary):
			continue
		var rec: Dictionary = raw
		var race := str(rec.get("race", ""))
		if race == "":
			continue
		var f: Dictionary = _faction_for_race(race)
		if f.is_empty():
			continue
		var n := int(ordinal.get(race, 0)) + 1
		ordinal[race] = n
		var base := Loc.t("ui.sim.city_default")
		if lore != null:
			base = str(lore.faction_city(race))
		var cname := str(base) if n == 1 else "%s %d" % [str(base), n]
		var c: Dictionary = new_city(cname, str(f.get("id", "")),
			str(region.get("id", "")), sector_id)
		c["pos"] = Vector2(float(rec.get("x", 0)), float(rec.get("y", 0)))
		c["population"] = maxi(1, int(rec.get("population", 100)))
		c["loyalty"] = 60.0
		var a: Dictionary = new_army(str(f.get("id", "")), c["pos"])
		a["sector_id"] = sector_id
		a["power"] = clampf(10.0 + float(c["population"]), 10.0, 100.0)
		added += 1
	return added


func _clear_map_records(sector_id: String) -> void:
	# Legacy saves and the sandbox have cities without a sector link. The first
	# real map replaces them wholesale; later sectors only replace their own.
	var any_sector := false
	for id in cities:
		if str(cities[id].get("sector_id", "")) != "":
			any_sector = true
			break
	if not any_sector:
		cities.clear()
		armies.clear()
		units.clear()
		return
	for id in cities.keys():
		var c: Dictionary = cities[id]
		if bool(c.get("fixture", false)) or str(c.get("sector_id", "")) == sector_id:
			cities.erase(id)
	for id in armies.keys():
		var a: Dictionary = armies[id]
		if bool(a.get("fixture", false)) or str(a.get("sector_id", "")) == sector_id:
			armies.erase(id)
	for id in units.keys():
		var u: Dictionary = units[id]
		if bool(u.get("fixture", false)):
			units.erase(id)


func _faction_for_race(race: String) -> Dictionary:
	for id in factions:
		var f: Dictionary = factions[id]
		if str(f.get("race", "")) == race:
			return f
	var label := str(race)
	var lore = load("res://scripts/lore.gd")
	if lore != null:
		label = str(lore.faction_label(str(race)))
	return new_faction(label, race)


func _region_for_sector(sector_id: String, region_name: String) -> Dictionary:
	for id in regions:
		var r: Dictionary = regions[id]
		if str(r.get("sector_id", "")) == sector_id:
			return r
	var r: Dictionary = new_region(region_name if region_name != ""
		else Loc.f("ui.sim.sector", [sector_id]))
	r["sector_id"] = sector_id
	return r

func get_unit(u: String) -> Dictionary:
	return units.get(u, {})

func get_city(c: String) -> Dictionary:
	return cities.get(c, {})

func get_faction(f: String) -> Dictionary:
	return factions.get(f, {})

func get_army(a: String) -> Dictionary:
	return armies.get(a, {})

func get_region(r: String) -> Dictionary:
	return regions.get(r, {})

# --- Мир 4x3: инициализация и доступ -----------------------------------------

## Fresh run (04.11): a new game must not inherit the SIM of the previous one.
## Loaded saves never go through this path.
func reset_for_new_game() -> void:
	units.clear()
	cities.clear()
	factions.clear()
	armies.clear()
	regions.clear()
	sectors.clear()
	outposts.clear()
	relations.clear()
	hero_reputation.clear()
	journal.clear()
	day = 0
	global_threat = 0.0
	_u = 0
	_c = 0
	_f = 0
	_a = 0
	_r = 0


## Собрать состояние 12 секторов по сиду мира. Вызывается один раз для новой
## игры; загруженный сейв приходит уже готовым через from_dict().
## start_owner — фракция расы героя (city-раса), владелец стартового сектора.
func init_world(seed_value: int, start_owner: String = "") -> void:
	world_seed = seed_value
	sectors.clear()
	outposts.clear()
	var wm = load("res://scripts/world/world_map.gd")
	var ids: Array = wm.ids()
	var caps: Array = wm.capital_ids()
	var factions: Array = WORLD_CAPITAL_FACTIONS.duplicate()
	_shuffle_with_seed(factions, seed_value ^ 0x5F3759DF)
	var cap_faction := {}
	for i in range(caps.size()):
		if i < factions.size():
			cap_faction[str(caps[i])] = str(factions[i])
	var start_id := str(wm.start_id())
	var start_neighbors: Array = wm.neighbors(start_id)
	for raw_id in ids:
		var id := str(raw_id)
		var s: Dictionary = wm.sector(id)
		var owner := ""
		var capital_of := ""
		if cap_faction.has(id):
			owner = str(cap_faction[id])
			capital_of = owner
		elif id == start_id:
			owner = start_owner
		var discovered := 0
		if id == start_id:
			discovered = 2
		elif start_neighbors.has(id):
			discovered = 1
		sectors[id] = {
			"col": int(s.get("col", 0)),
			"row": int(s.get("row", 0)),
			"tier": str(s.get("tier", "hard")),
			"base": str(s.get("base", "soil")),
			"relief": str(s.get("relief", "plains")),
			"size": int(s.get("size", 192)),
			"seed": int(wm.seed_of(seed_value, id)),
			"owner": owner,
			"capital_of": capital_of,
			"discovered": discovered,
			"fog": "",
			"outposts": [],
		}


func _shuffle_with_seed(arr: Array, seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


func sector_state(id: String) -> Dictionary:
	return sectors.get(id, {}) as Dictionary


## Отметить сектор посещённым и открыть его прямых соседей до «разведан».
func discover_sector(id: String) -> void:
	if not sectors.has(id):
		return
	var s: Dictionary = sectors[id]
	s["discovered"] = 2
	sectors[id] = s
	var wm = load("res://scripts/world/world_map.gd")
	for n in wm.neighbors(id):
		var nid := str(n)
		if not sectors.has(nid):
			continue
		var ns: Dictionary = sectors[nid]
		if int(ns.get("discovered", 0)) < 1:
			ns["discovered"] = 1
			sectors[nid] = ns

# --- Сериализация -------------------------------------------------------------
##
## ВНИМАНИЕ: результат to_dict() обязан быть JSON-безопасным, потому что
## именно он уходит в файл сохранения. В данных мира лежат Vector2
## (cities[].pos, armies[].pos/target, regions[].area_px, hero.pos) и Color
## (factions[].color), а JSON.stringify на них не возвращает исходный тип.
## Раньше encode не делался вовсе, и баг был не виден: сравнение словарей
## в памяти проходило, а файл на диске оказывался битым.
##
## from_dict() тоже был неполным: из 13 полей восстанавливал 8, молча теряя
## day, global_threat, relations, hero и journal. «Продолжить» обнулило бы
## день мира и угрозу.

func to_dict() -> Dictionary:
	return {
		"counters": { "u": _u, "c": _c, "f": _f, "a": _a, "r": _r },
		"units": units, "cities": cities, "factions": factions,
		"armies": armies, "regions": regions,
		"day": day, "global_threat": global_threat,
		"relations": relations, "hero": hero, "journal": journal,
		"hero_reputation": hero_reputation,
		"world_seed": world_seed, "sectors": sectors, "outposts": outposts,
	}

## Полная сериализация в JSON-безопасную форму. Для записи в файл.
func to_json_dict() -> Dictionary:
	return JsonSafe.encode(to_dict()) as Dictionary

## Текст для файла сохранения. Путь, которым реально пишет SaveSystem.
func to_json_text() -> String:
	return JSON.stringify(to_json_dict())

static func from_dict(d: Dictionary):
	# NOTE (headless-canon): без class_name мы НЕ можем вызвать WorldState.new() —
	# берём сам-файл через load-по-пути (единственный «глобальный» доступ).
	var ws = (load("res://scripts/world/world_state.gd") as GDScript).new()
	var counters: Dictionary = d.get("counters", {})
	ws._u = int(counters.get("u", 0)); ws._c = int(counters.get("c", 0))
	ws._f = int(counters.get("f", 0)); ws._a = int(counters.get("a", 0))
	ws._r = int(counters.get("r", 0))
	ws.units = d.get("units", {}); ws.cities = d.get("cities", {})
	ws.factions = d.get("factions", {}); ws.armies = d.get("armies", {})
	ws.regions = d.get("regions", {})
	# --- эти пять полей раньше НЕ восстанавливались ---
	ws.day = int(d.get("day", 0))
	ws.global_threat = float(d.get("global_threat", 0.0))
	ws.relations = d.get("relations", {})
	ws.hero_reputation = d.get("hero_reputation", {})
	ws.hero = d.get("hero", {})
	ws.world_seed = int(d.get("world_seed", 0))
	ws.sectors = d.get("sectors", {})
	ws.outposts = d.get("outposts", {})
	# journal объявлен как Array[Dictionary]; после JSON это обычный Array,
	# поэтому пересобираем типизированный, иначе присвоение падает.
	var raw_journal: Array = d.get("journal", [])
	var j: Array[Dictionary] = []
	for entry in raw_journal:
		j.append(entry as Dictionary)
	ws.journal = j
	return ws

## Восстановление из JSON-текста (с декодированием типов).
static func from_json_text(s: String):
	# JSON.new().parse(), а не JSON.parse_string(): тот при битом файле печатает
	# в консоль красную ошибку движка, а повреждённое сохранение должно
	# откатываться на .bak тихо.
	var j := JSON.new()
	if j.parse(s) != OK:
		return null
	return from_json_dict(j.data as Dictionary)

static func from_json_dict(d: Dictionary):
	return from_dict(JsonSafe.decode(d) as Dictionary)

## Хелпер для ортодоксального Vector2 в JSON/словарь (сериализуемо без нод).
static func vec2_to(v: Vector2) -> Dictionary:
	return { "x": v.x, "y": v.y }

static func vec2_from(d: Dictionary) -> Vector2:
	return Vector2(float(d.get("x", 0)), float(d.get("y", 0)))
