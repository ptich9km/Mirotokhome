extends SceneTree
## SIM built from the live map (04.11).
##
## Before this the SIM always started as a hardcoded sandbox (4 factions,
## 2 cities, 2 armies) that had nothing to do with the map the player sees.
## Now the city list of the current sector feeds WorldState: factions, cities
## and armies are derived from the generated map, while a loaded save keeps its
## economy (sync is a no-op once the sector has cities).
##
## Run: godot --headless --path . --script res://tests/sim_from_map_smoke.gd

const WorldBusClass := preload("res://scripts/world/world_bus.gd")
const WorldStateClass := preload("res://scripts/world/world_state.gd")
const SEED := 4242
const ZONE := "mid"
const OUT_DIR := "user://maps/sim_map_smoke/"

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 9, "spirit": 8,
		"blade": 20, "axe": 0, "bludgeon": 0, "pike": 0, "shooting": 10,
		"fire": 0, "water": 0, "air": 0, "earth": 0, "astral": 0,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.hero_class = "warrior"
	Game.hero_name = "Тест"
	Game.hero_race = "human"
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print("SIM: %s %s" % ["ok  " if ok else "FAIL", what])


func _run() -> void:
	var bus = WorldBusClass.new()
	bus.name = "WorldBus"
	bus._ready()   # autoload's _ready does not run outside the tree
	_check(bus.state != null, "WorldState создан")
	_check(bus.state.cities.size() == 2, "до карты SIM — фикстура из 2 городов (%d)"
		% bus.state.cities.size())

	var map_cities := [
		{"id": "c0t0", "race": "humans", "x": 67, "y": 67, "population": 21},
		{"id": "c1t1", "race": "ork", "x": 141, "y": 96, "population": 18},
	]
	var added: int = bus.sync_sector_map("s41", map_cities, "Сектор 41")
	_check(added == 2, "SIM принял 2 города карты (%d)" % added)
	_check(bus.state.has_sector_cities("s41"), "у сектора s41 есть города")
	_check(not _has_fixture(bus.state.cities), "фикстурные города убраны")
	_check(not _has_fixture(bus.state.armies), "фикстурные армии убраны")
	_check(bus.state.cities.size() == 2, "городов ровно 2, без дублей (%d)"
		% bus.state.cities.size())
	_check(bus.state.armies.size() == 2, "армий ровно 2 (%d)" % bus.state.armies.size())

	var races := {}
	var powers_ok := true
	for id in bus.state.cities:
		var c: Dictionary = bus.state.cities[id]
		_check(str(c.get("sector_id", "")) == "s41",
			"город %s привязан к сектору" % str(c.get("name", "?")))
		_check(str(c.get("name", "")) != "", "у города есть имя")
		var f: Dictionary = bus.state.get_faction(str(c.get("faction_id", "")))
		var race := str(f.get("race", ""))
		races[race] = true
		_check(race != "", "у города есть раса фракции (%s)" % race)
	for id in bus.state.armies:
		var a: Dictionary = bus.state.armies[id]
		if float(a.get("power", 0.0)) <= 0.0:
			powers_ok = false
	_check(powers_ok, "у армий карты положительный power")
	_check(races.has("humans") and races.has("ork"),
		"расы городов дошли до фракций (%s)" % str(races.keys()))

	# Loading / second visit: economy must survive.
	var first := str(bus.state.cities.keys()[0])
	var eco: Dictionary = bus.state.city_economy(bus.state.cities[first])
	eco["gold"] = 777.0
	var again: int = bus.sync_sector_map("s41", map_cities, "Сектор 41")
	_check(again == 0, "повторная синхронизация ничего не добавляет (%d)" % again)
	_check(float(bus.state.city_economy(bus.state.cities[first]).get("gold", 0.0)) == 777.0,
		"экономика загруженного сектора не сброшена")

	# Save round-trip keeps the sector link.
	var restored = WorldStateClass.from_dict(bus.state.to_dict())
	_check(restored.has_sector_cities("s41"),
		"после сохранения/загрузки сектор помнит свои города")

	# New game must start a clean world, not inherit this sector.
	bus.state.reset_for_new_game()
	_check(bus.state.cities.is_empty() and bus.state.sectors.is_empty(),
		"reset_for_new_game очищает города и сектора")
	_check(bus.state.day == 0 and bus.state.journal.is_empty(),
		"reset_for_new_game обнуляет день и журнал")

	# Live map -> city list.
	var path: String = MapGenerator.new().generate(SEED, ZONE, OUT_DIR)
	_check(path != "" and FileAccess.file_exists(path), "карта сгенерирована")
	if path != "" and FileAccess.file_exists(path):
		var alm := AlmMap.new()
		alm.alm_path = path
		root.add_child(alm)
		await process_frame
		await process_frame
		var cities: Array = alm.call("get_cities")
		_check(cities.size() >= 1, "AlmMap отдаёт города карты (%d)" % cities.size())
		var valid := true
		for rec in cities:
			if not (rec is Dictionary):
				valid = false
				continue
			var d: Dictionary = rec
			if str(d.get("race", "")) == "":
				valid = false
			if int(d.get("population", 0)) <= 0:
				valid = false
			if int(d.get("x", -1)) < 0 or int(d.get("y", -1)) < 0:
				valid = false
		_check(valid, "у городов карты есть раса, население и координаты")

		# The same map list feeds a fresh SIM for another sector.
		var bus2 = WorldBusClass.new()
		bus2.name = "WorldBus2"
		bus2._ready()
		var added2: int = bus2.sync_sector_map("s42", cities, "Сектор 42")
		_check(added2 == cities.size(),
			"SIM другого сектора принял все города карты (%d/%d)"
				% [added2, cities.size()])
		_check(bus2.state.cities.size() == cities.size(),
			"городов в SIM столько же, сколько на карте")
		bus2.free()
		alm.queue_free()
		await process_frame

	bus.free()
	_finish()


func _has_fixture(d: Dictionary) -> bool:
	for id in d:
		if bool(d[id].get("fixture", false)):
			return true
	return false


func _finish() -> void:
	print("")
	if _fails.is_empty():
		print("RESULT: OK sim_from_map_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL sim_from_map_smoke (%d checks, %d fails)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)
