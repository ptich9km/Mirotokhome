# ============================================================================
# LAYER-2.5 WorldBus (Autoload Node, headless-canon).
#
# HEADLESS CANON (шаг-3 AGENTS.md, «Ш2-вариант-1»; проверено на боли в
# sim_runner.gd): при global-кеше классов headless НЕ имеет резолва, поэтому
# в автолоаде ЗАПРЕЩЕНЫ `const X := preload(...)` и любые `:=` — каждый
# cross-layer доступ — ТОЛЬКО untyped + load-по-пути в _ready.
#
# Роль: тонкий бус-раннер, держит WorldState(ДАННЫЕ)+WorldSim(СИМ), умеет
# `advance(days)` и `snapshot()`. Вся логика — в RefCounted-слоях, НИКОГДА тут.
# ============================================================================
extends Node

## День мира сменился (живой календарь). Слушают лента мира и тесты;
## квесты ротацию видят сами — она сверяет WorldBus.state.day каждый кадр.
signal day_changed(day: int)

var state   # WorldState  — слой-1 ДАННЫЕ (RefCounted)
var sim     # WorldSim    — слой-2 СИМ (RefCounted)

## Аккумулятор тика великого мага (реальное время, сек).
var _archmage_acc := 0.0
## Аккумулятор календаря живой игры (реальное время, сек).
var _day_acc := 0.0


func _ready() -> void:
	var st_script: GDScript = load("res://scripts/world/world_state.gd")
	var sim_script: GDScript = load("res://scripts/world/world_sim.gd")
	state = st_script.new()
	sim = sim_script.new(state)
	reseed()


func reseed() -> void:
	# Все четыре расы, а не две (28.10): города бывают у каждой
	# (MapGenerator.CITY_POPULATION), а фракция нужна ради великого мага —
	# иначе у нежити и друидов панель писала «в этом городе мага нет».
	# Ключи рас — как в world.json: humans/ork/necro/druid.
	var lore: GDScript = load("res://scripts/lore.gd")
	var races: Array = ["humans", "ork", "necro", "druid"]
	var f_h: Dictionary = {}
	var f_e: Dictionary = {}
	for race in races:
		var label: String = str(race)
		if lore != null:
			var fd: Dictionary = lore.faction(str(race)) as Dictionary
			if str(fd.get("label", "")) != "":
				label = str(fd.get("label"))
		var f: Dictionary = state.new_faction(label, str(race))
		if str(race) == "humans":
			f_h = f
		elif str(race) == "ork":
			f_e = f
	var r: Dictionary = state.new_region("Черноземье")
	var _c_h: Dictionary = state.new_city("Речной Пост", f_h.id, r.id)
	var c_e: Dictionary = state.new_city("Кровавый Бор", f_e.id, r.id)
	var u1: Dictionary = state.new_unit(f_h.id, "fire")
	var u2: Dictionary = state.new_unit(f_e.id, "fire")
	var a_h: Dictionary = state.new_army(f_h.id, Vector2(300, 400))
	var a_e: Dictionary = state.new_army(f_e.id, Vector2(700, 400))
	a_h["unit_ids"] = [u1.id]
	a_e["unit_ids"] = [u2.id]
	# Fixture marker: apply_map_cities() removes these when the first real map
	# arrives, while headless tests keep the sandbox exactly as before.
	_c_h["fixture"] = true
	c_e["fixture"] = true
	u1["fixture"] = true
	u2["fixture"] = true
	a_h["fixture"] = true
	a_e["fixture"] = true
	state.relations["%s:%s" % [f_h.id, f_e.id]] = -40
	state.relations["%s:%s" % [f_e.id, f_h.id]] = -40


## Feed the SIM from the live map's cities (04.11). Idempotent: a sector that
## already has cities (loaded save or a second visit) keeps its economy.
func sync_sector_map(sector_id: String, map_cities: Array,
		region_name: String = "") -> int:
	if state == null or sector_id == "" or map_cities.is_empty():
		return 0
	if state.has_sector_cities(sector_id):
		return 0
	return int(state.apply_map_cities(sector_id, map_cities, region_name))


func advance(days: int) -> void:
	for _i in days:
		sim.tick()


## Календарь ЖИВОЙ игры (28.10). Зовёт game.gd из _process и только когда мир
## не на паузе: тактическая пауза и меню сохранений не должны двигать дни,
## иначе ротация квестов идёт, пока игрок читает меню.
##
## Не _process у автолоада специально: headless sim_runner крутит дни сам через
## advance(), а `--script` не поднимает автолоады. Возвращает число прошедших
## дней (0 — ещё не день).
func tick_day(delta: float) -> int:
	if state == null or sim == null:
		return 0
	var cfg: GDScript = load("res://scripts/game_config.gd")
	var seconds := 300.0
	if cfg != null:
		seconds = cfg.getf("world", "day_seconds")
	if seconds <= 0.0:
		return 0
	_day_acc += delta
	var n := 0
	while _day_acc >= seconds:
		_day_acc -= seconds
		sim.tick(true)
		n += 1
		day_changed.emit(int(state.day))
	return n


## Сброс календаря: загрузка слота/новая карта не должны «докручивать» день,
## накопленный прошлой сессией.
func reset_day_timer() -> void:
	_day_acc = 0.0


func snapshot() -> Dictionary:
	return {
		"day": state.day, "global_threat": state.global_threat,
		"cities": state.cities.size(), "armies": state.armies.size(),
		"units": state.units.size(), "journal": state.journal.size(),
	}


func _process(delta: float) -> void:
	archmage_tick(delta)


## Тик могущества великих магов по реальному времени.
## Сим-мир НЕ тикает (решение игрока) — только маги.
## Возвращает, сколько тиков прошло.
func archmage_tick(delta: float) -> int:
	if state == null or sim == null:
		return 0
	var interval := 20.0
	var cfg: GDScript = load("res://scripts/game_config.gd")
	if cfg != null:
		interval = cfg.getf("archmage", "sim_interval")
	if interval <= 0.0:
		return 0
	_archmage_acc += delta
	var n := 0
	while _archmage_acc >= interval:
		_archmage_acc -= interval
		sim.tick_archmages()
		n += 1
	return n


## Сброс аккумулятора (тесты, reload мира).
func reset_archmage_timer() -> void:
	_archmage_acc = 0.0
