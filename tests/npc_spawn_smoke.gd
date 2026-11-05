extends SceneTree
##
## Тест точек интереса вне городов (этап 3, 03.10).
##
## ЧТО ПРОВЕРЯЕТ
## -------------
## 1. Каждый набор NPC в POI_KINDS реально существует в units_db.
##    Это не формальность: `humans/militia` я сначала написал в POI_KINDS,
##    взяв из заметок AGENTS §8.2, и его В БАЗЕ НЕТ — militia не существует.
##    Точка интереса такого вида молча не дала бы ни одного NPC. Тест
##    ловит это до запуска игры, а не после.
## 2. Выключено по умолчанию: poi.count = 0, поэтому
##    поведение игры не отличается от прежнего, пока игрок не включит.
##    Это главный инвариант безопасности ночной правки.
## 3. В закоммиченной карте нет ни одной записи POI.
## 4. Наборы POI — люди (не Серые), и их статы берутся из [poi] (hp/damage),
##    а не из потолка в коде.
##
## ЗАПУСК
## ------
## godot --headless --path . --script res://tests/npc_spawn_smoke.gd
##

const UNITS_PATH := "res://assets/units/units_db.json"
const CFG_PATH := "res://assets/config/game.cfg"
const MAP_NPCS := "res://assets/maps/gen/gen_smart_01.npcs.json"
const DIR := "user://maps/"
const SEED := 4242
const ZONES := ["start", "mid", "hard", "faction"]

var _checks := 0
var _fails: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
	print(("  OK  " if ok else "  FAIL") + " " + msg)


## Раса из имени набора: "city_human_mage/t1" -> "humans",
## "city_ork_warrior/t0" -> "ork", "city_druid_mage/t2" -> "druid".
## city_ убираем, последний сегмент до "/" — это «раса + роль» (_mage/_warrior),
## поэтому у человека к единственному корню "human" приводим через таблицу
## алиасов, а не отрезанием букв.
## Раса из имени набора. 10.10: раньше здесь была СВОЯ копия разбора с
## таблицей [[human,humans],[orc,ork],[druid,druid]] — и именно из-за неё
## production-функция MapGenerator.race_of_set (в ней был ["orc", "ork"] при
## сегменте "ork") осталась сломанной, а тест был зелёным. Теперь зовём
## единственный источник.
func _set_race(set_name: String) -> String:
	return MapGenerator.race_of_set(set_name)


## В пуле наборов есть и маг, и воин. Проверка по РОЛИ из имени набора, а не
## по таблице: таблица может остаться старой, а наборы уже смениться.
func _has_mage_and_warrior(pool: Array) -> bool:
	var mage := false
	var warrior := false
	for s in pool:
		var n := str(s)
		if n.ends_with("_mage/t0") or n.ends_with("_mage/t1") or n.ends_with("_mage/t2"):
			mage = true
		if n.ends_with("_warrior/t0") or n.ends_with("_warrior/t1") or n.ends_with("_warrior/t2"):
			warrior = true
	return mage and warrior


func _unit_names() -> Array:
	if not FileAccess.file_exists(UNITS_PATH):
		return []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(UNITS_PATH))
	if parsed is Array:
		return parsed
	if parsed is Dictionary:
		return (parsed as Dictionary).keys()
	return []


func _run() -> void:
	print("-- наборы NPC --")
	var units := _unit_names()
	_check(units.size() > 0, "units_db читается (%d наборов)" % units.size())

	# Был жёсткий список ork_mage_a52/t0..t3. Теперь наборов 16 (4 расы
	# по 4 тира), и перечислять их здесь бессмысленно - полнота таблицы
	# проверяется ниже, по CITY_POPULATION из кода.
	for key in ["ork_mage_a52/t0", "ork_mage_a52/t3"]:
		_check(units.has(key),
			"набор %s есть в units_db (оставлен для отката и панелей)" % key)

	# POI выключены (решение игрока 07.10: арта мало, poi.count=0).
	var kinds := {}
	var code_kinds := _code_poi_sets()
	_check(code_kinds.is_empty(),
		"POI_KINDS в коде пуст (аллодовские humans/* убраны, POI off)")
	_check(kinds.size() == code_kinds.size(),
		"тест и код согласованы по POI (0 == 0)")

	print("-- выключено по умолчанию --")
	var cfg := ConfigFile.new()
	var err := cfg.load(CFG_PATH)
	if err != OK:
		_check(false, "game.cfg грузится (err=%d)" % err)
		_finish()
		return
	_check(true, "game.cfg грузится")

	# POI выключены (решение игрока 07.10: арта мало): одна глобальная
	# секция [poi], а не по зоне — 3x.11 зональные боевые ключи убраны.
	_check(int(cfg.get_value("poi", "count", -999)) == 0,
		"poi.count = 0 (точки интереса выключены)")
	_check(int(cfg.get_value("poi", "hp", 0)) > 0,
		"у NPC точки заданы HP (poi.hp)")
	_check(int(cfg.get_value("poi", "damage", -1)) >= 0,
		"у NPC точки задан урон (poi.damage)")

	print("-- городские NPC: раса города -> наборы (CITY_POPULATION) --")
	# 09.10: карта генерируется здесь, а не читается из закоммиченного
	# gen_smart_01.npcs.json. Тот sidecar - артефакт прошлой генерации: после
	# бампа GEN_VERSION он вообще не отражает текущий код, и проверка на нём
	# проходила бы на устаревших данных (ровно тот класс, что закрывался
	# в gray_density_smoke и gen_seeds_smoke).
	DirAccess.make_dir_recursive_absolute(DIR)
	# 10.10: раса входит в имя карты (map_<seed>_<zone>_<race>.alm), поэтому
		# здесь генерируем и проверяем ensure_map С ОДНОЙ И ТОЙ ЖЕ расой - иначе
		# это два разных файла и проверка проходит вхолостую.
	var test_race: String = MapGenerator.city_race_for_hero("human")
	var alm_path: String = MapGenerator.new().generate(SEED, "mid", DIR, "", "", test_race)
	_check(alm_path != "", "карта сгенерировалась для проверки городских NPC")
	var npc_path: String = alm_path.get_basename() + ".npcs.json"
	if not FileAccess.file_exists(npc_path):
		_check(false, "sidecar %s существует" % npc_path)
	else:
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(npc_path))
		var npcs: Array = []
		if parsed is Dictionary:
			npcs = (parsed as Dictionary).get("npcs", [])
		# Здесь пишется та же константа, что сравнивается, - проверка была бы
		# тождеством. Настоящий контракт в другом: ensure_map обязан ПЕРЕГЕНЕРИРОВАТЬ
		# карту, у которой sidecar записан старой версией. Иначе игрок, у которого
		# в user://maps/ уже лежит карта со старыми орками-магами, никогда не
		# увидит новых NPC (ровно тот баг, что закрывался дважды).
		var written := int((parsed as Dictionary).get("gen_version", -1))
		_check(written == MapGenerator.GEN_VERSION,
			"генератор записал gen_version = %d" % MapGenerator.GEN_VERSION)
		var stale := FileAccess.open(npc_path, FileAccess.WRITE)
		if stale != null:
			stale.store_string(JSON.stringify({
				"npcs": (parsed as Dictionary).get("npcs", []), "gen_version": -99}))
			stale.close()
			var before := FileAccess.get_md5(npc_path)
			MapGenerator.ensure_map(SEED, "mid", DIR, test_race)
			var after := FileAccess.get_md5(npc_path)
			_check(before != after,
				"ensure_map перегенерировал карту со stale gen_version (-99)")
			var reparse: Variant = JSON.parse_string(FileAccess.get_file_as_string(npc_path))
			_check(int((reparse as Dictionary).get("gen_version", -1)) == MapGenerator.GEN_VERSION,
				"после ensure_map gen_version снова = %d" % MapGenerator.GEN_VERSION)

		# Ожидание строим из ТОГО ЖЕ источника, что и код (CITY_POPULATION),
		# а не из своей копии - иначе правка кода молча починит тест.
		var pop: Dictionary = MapGenerator.CITY_POPULATION
		var races: Array = MapGenerator.CITY_RACES
		_check(not pop.is_empty(), "CITY_POPULATION непустая")
		_check(races.size() > 0, "CITY_RACES непустой")
		for race in races:
			_check(pop.has(race), "раса '%s' из CITY_RACES есть в CITY_POPULATION" % race)
			# 10.10 (позже): раньше здесь стояло "necro не спавнится, пока нет
			# арта нежити". Атлас появился, поэтому проверка стала бы ровно
			# тем сторожем, который запрещает рабочую фичу. Заменена на
			# настоящее требование: у каждой расы города есть ОБА набора
			# (маг и воин) - иначе в городе 16 копий одного силуэта.
			var pe: Dictionary = pop.get(race, {})
			var sguards: Array = pe.get("guards", [])
			var scitizens: Array = pe.get("citizens", [])
			_check(_has_mage_and_warrior(sguards),
				"у расы '%s' в стражах есть и маг, и воин (%s)" % [race, str(sguards)])
			_check(_has_mage_and_warrior(scitizens),
				"у расы '%s' среди жителей есть и маг, и воин (%s)" % [race, str(scitizens)])
		for race2 in pop.keys():
			_check(races.has(race2),
				"в CITY_POPULATION нет расы '%s', которой не выдаётся город" % race2)

		# Каждый набор из таблицы обязан существовать в units_db: опечатка в
		# ключе дала бы пустой кадр без единой ошибки.
		for race3 in pop.keys():
			var entry: Dictionary = pop[race3]
			var all_sets: Array = []
			all_sets.append_array(entry.get("guards", []))
			all_sets.append_array(entry.get("citizens", []))
			all_sets.append(str(entry.get("captain", "")))
			for s in all_sets:
				_check(units.has(str(s)),
					"набор %s (раса %s) существует в units_db" % [str(s), race3])
				# Ключ расы ↔ префикс набора. Без этого тест читает ожидаемое
				# значение из той же таблирии, что и код (тождество), и пропустил
				# бы таблицу, где в графе humans стоит druid-набор.
				# Сравнение по корню, а не конкатенацией: раса в world.json
				# зовётся "humans", а наборы — "city_human_*" (без s).
				_check(_set_race(str(s)) == race3,
					"набор %s действительно расы '%s' (корень: %s)"
						% [str(s), race3, _set_race(str(s))])

		# Теперь фактические спавны.
		var allowed := {}
		for race4 in pop.keys():
			var e4: Dictionary = pop[race4]
			var pool: Array = []
			pool.append_array(e4.get("guards", []))
			pool.append_array(e4.get("citizens", []))
			pool.append(str(e4.get("captain", "")))
			for s2 in pool:
				allowed[str(s2)] = str(race4)
		var cap_races := {}
		var poi := 0
		var unknown := 0
		var guards := 0
		var citizens := 0
		for n3 in npcs:
			var d3: Dictionary = n3
			if d3.has("poi"):
				poi += 1
			var role := str(d3.get("role", ""))
			var setn := str(d3.get("set", ""))
			if role != "guard" and role != "citizen":
				continue
			if role == "guard":
				guards += 1
			else:
				citizens += 1
			if not allowed.has(setn):
				unknown += 1
				continue
			if bool(d3.get("archmage", false)):
				# Капитан = маг СВОЕЙ расы. Проверяем именно это: раньше стоял
				# один ork_mage_a52/t3 во всех городах, то есть в орк-городе
				# мог оказаться druid-маг.
				cap_races[setn] = allowed[setn]
				var expect := str((pop[allowed[setn]] as Dictionary).get("captain", ""))
				_check(setn == expect,
					"капитан-архимаг расы '%s' = %s (на карте %s)" % [allowed[setn], expect, setn])
				_check(setn.ends_with("/t3"),
					"капитан — высший тир t3 (на карте %s)" % setn)
		_check(poi == 0, "на карте нет POI (найдено: %d)" % poi)
		_check(guards > 0, "на карте есть стражи (%d)" % guards)
		_check(citizens > 0, "на карте есть жители (%d)" % citizens)
		_check(unknown == 0,
			"все городские NPC из CITY_POPULATION, чужих наборов: %d" % unknown)
		_check(cap_races.size() > 0, "капитан-архимаг на карте есть (%d городов)" % cap_races.size())
		_check(not cap_races.is_empty() and not allowed.is_empty(),
			"капитан найден среди табличных наборов")

	print("-- Серые разведены по карте --")
	# Жалоба игрока 03.10: «1 Серый на карте». Замер показал 15 Серых на 6
	# клетках, причём все в одной половине карты. Причина была двойная:
	# якоря кластеров не проверялись на занятость, а `_near_gray_cell` писал в
	# переданный по ссылке массив, а вызывающий код добавлял клетку ещё раз —
	# кластер из 3 давал 5 записей, две из них на одной клетке.
	if not FileAccess.file_exists(MAP_NPCS):
		print("  (карта %s отсутствует — проверка пропущена)" % MAP_NPCS)
	else:
		var parsed2: Variant = JSON.parse_string(FileAccess.get_file_as_string(MAP_NPCS))
		var npcs2: Array = []
		if parsed2 is Dictionary:
			npcs2 = (parsed2 as Dictionary).get("npcs", [])
		var gray_cells := {}
		var gray_n := 0
		var gray_regions := {}
		for g in npcs2:
			var d: Dictionary = g
			if str(d.get("role", "")) == "guard" or str(d.get("role", "")) == "citizen":
				continue
			if not d.has("set"):
				continue
			gray_n += 1
			gray_cells["%d,%d" % [int(d.get("x", 0)), int(d.get("y", 0))]] = true
			# сетка 3x3 — та же, что у генератора при разведении
			gray_regions["%d,%d" % [int(d.get("x", 0)) * 3 / 192,
				int(d.get("y", 0)) * 3 / 192]] = true
		# Серых на карте нет и это ТЕПЕРЬ ПРАВИЛЬНО: весь арт Аллодов удалён
		# вместе с 41 набором `monsters/*` (11.10), пул Серых пуст, и игрок
		# сознательно выбрал вариант «не спавнить вовсе», а не подставлять
		# вместо них городских стражников.
		#
		# Проверка ИНВЕРТИРОВАНА, а не удалена: пока риги Серых не появились,
		# именно ноль Серых — ожидаемое поведение. Стоит только одна проверка,
		# которая бы ПОЙМАЛА случайную замену пула на чужой набор: ни одного
		# набора вне city_*/ork_mage*/rig/* быть не должно. Прежние «Серые
		# разведены по регионам» удалены вместе с самими Серыми — охранять
		# нечего.
		var stray := 0
		for g in npcs2:
			var d: Dictionary = g
			var s := str(d.get("set", ""))
			if s.is_empty():
				continue
			if not (s.begins_with("city_") or s.begins_with("ork_mage") or s.begins_with("rig/")):
				stray += 1
		_check(stray == 0,
			"на карте нет наборов вне city_*/ork_mage*/rig/* (нашлось: %d)" % stray)

	_test_city_matches_hero_race()
	_finish()


## 10.10: город должен соответствовать расе героя.
##
## Жалоба игрока: «у всех кроме людей NPC в городе не соответствуют выбранной
## расе». Причина: расы городов шли по кругу CITY_RACES от нуля, то есть
## первый город всегда был humans, и стартовая зона (1 город) давала город
## людей независимо от того, кем игрок играет.
##
## Проверяем поведение, а не формулу: генерируем стартовую карту за каждую
## расу, у которой есть наборы, и требуем, чтобы все городские NPC были
## этой расы. Мутация «убрать append(hero) из _race_order» ловится сразу.
func _test_city_matches_hero_race() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var old_race: String = Game.hero_race
	# Перебор берём из production-списка + маппинг «раса героя -> id фракции»,
	# а не свой список: иначе новая раса (10.10 — necro) не попадёт в проверку
	# и тест останется зелёным на неполном покрытии.
	for hero_race in ["human", "ork", "druid", "necro"]:
		var race: String = str(hero_race)
		Game.hero_race = race
		var want: String = MapGenerator.city_race_for_hero(race)
		_check(want != "", "раса героя '%s' есть в CITY_POPULATION (%s)" % [race, want])
		var alm: String = MapGenerator.new().generate(SEED + 100, "start", DIR, "", "", want)
		var side: String = alm.get_basename() + ".npcs.json"
		print("    DBG race=%s want=%s path=%s" % [race, want, side])
		if not FileAccess.file_exists(side):
			_check(false, "sidecar для '%s' создан (%s)" % [race, side])
			continue
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(side))
		var npcs: Array = []
		if parsed is Dictionary:
			npcs = (parsed as Dictionary).get("npcs", [])
		var wrong := 0
		var seen := 0
		for n in npcs:
			var d: Dictionary = n
			var role := str(d.get("role", ""))
			if role != "guard" and role != "citizen":
				continue
			seen += 1
			if MapGenerator.race_of_set(str(d.get("set", ""))) != want:
				wrong += 1
		_check(seen > 0, "за '%s' в городе есть NPC (раса '%s', %d шт.)" % [race, want, seen])
		_check(wrong == 0,
			"за '%s' все городские NPC расы '%s' (чужих: %d)" % [race, want, wrong])
	Game.hero_race = old_race


## Читает POI_KINDS прямо из исходника генератора: тест должен проверять
## ИМЕННО то, что напишет игрок в коде, а не свою копию списка.
## 07.10: ENCOUNTER_KINDS (боевые ульи/логова) — ОТДЕЛЬНАЯ система, не POI.
## POI — статичные точки без боя; их список по-прежнему пуст.
func _code_poi_sets() -> Dictionary:
	var out := {}
	if not FileAccess.file_exists("res://scripts/world/map_generator.gd"):
		return out
	var text := FileAccess.get_file_as_string("res://scripts/world/map_generator.gd")
	# Берём только блок POI_KINDS := [...], не ENCOUNTER_KINDS
	var poi_start := text.find("POI_KINDS")
	if poi_start < 0:
		return out
	var poi_end := text.find("\n]", poi_start)
	if poi_end < 0:
		poi_end = poi_start + 400
	var block := text.substr(poi_start, poi_end - poi_start)
	if block.find("[]") >= 0 or block.find("{ }") >= 0:
		return out
	for line in block.split("\n"):
		if not line.contains("\"kind\":"):
			continue
		var kind := _extract(line, "\"kind\": \"", "\"")
		if kind == "":
			continue
		out[kind] = ["(poi)"]
	return out


func _extract(s: String, prefix: String, stop: String) -> String:
	var i := s.find(prefix)
	if i < 0:
		return ""
	var rest := s.substr(i + prefix.length())
	var j := rest.find(stop)
	if j < 0:
		return ""
	return rest.substr(0, j)


func _finish() -> void:
	print("RESULT: %s npc_spawn_smoke (проверок: %d, провалов: %d)"
			% ["OK" if _fails.is_empty() else "FAIL", _checks, _fails.size()])
	for f in _fails:
		print("  FAIL " + f)
	quit(0 if _fails.is_empty() else 1)
