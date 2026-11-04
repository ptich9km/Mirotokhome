extends SceneTree
##
## Тиры Серых: полосы по зонам, усиление статов, имена (17.10).
##
## Задача: у Серых не было ни одного тира — пул давал семь видов без градации.
## Тиры сделаны перекраской (`tests/gen_grey_tiers.py`, $0 вызовов API): тир 1 —
## сам зверь, тиры 2..5 — цветовые копии `monsters/<вид>_t<N>`.
##
## Что проверяется и почему именно так:
## - ПОЛОСА по зонам: старт 1-2, mid 2-3, hard 3-4, faction 4-5. Проверка
##   «все тиры в каждой зоне» прошла бы на любом мусоре, поэтому проверяется
##   СОВПАДЕНИЕ пула с эталоном по видам и тирам, а не «пул не пуст».
## - МНОЖИТЕЛИ: hp x1.35 и урон x1.25 за тир (§13, пакет C). Считается по
##   значениям, а не по тому, что функция вернула 1.0.
## - ИМЕНА: у 35 наборов должно быть `name_ru`. Без него тултип показывал
##   английский `desc` вида «Monster wolf, Gemini Nano Banana strips…» —
##   подпись была непустой, поэтому запасной путь `set_name` не срабатывал.
## - ЛЕТАЮЩИЕ: `z` обязан переноситься из базового набора. Без него тирный
##   bat/bee/ghost/dragon перестал бы обходить воду и горы (`fly_z > 0`).

var _checks := 0
var _fails: Array[String] = []


func _initialize() -> void:
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 9, "spirit": 8,
		"blade": 30, "bludgeon": 15, "pike": 10,
		"fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.hero_class = "warrior"
	Game.map_zone = "mid"
	Game.request_map_by_seed(4242, "mid")
	call_deferred("_run")


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
	print(("  OK  " if ok else "  FAIL") + " " + msg)


func _tier_of(set_name: String) -> int:
	return int(UnitDB.get_set(set_name).get("tier", 0))


func _run() -> void:
	print("-- полосы тиров по зонам --")
	var expected := {
		"start": [1, 2], "mid": [2, 3], "hard": [3, 4], "faction": [4, 5],
	}
	for zone in expected:
		var band: Array = MapGenerator.GRAY_TIER_BAND[zone]
		var pool: Array = MapGenerator.gray_pool_for_zone(zone)
		var species: int = MapGenerator.gray_species().size()
		# Пул = все виды × тиры полосы, без дублей и без лишнего.
		var want: int = species * (int(band[1]) - int(band[0]) + 1)
		var uniq: Dictionary = {}
		for s in pool:
			uniq[str(s)] = true
		_check(pool.size() == want and uniq.size() == want,
			"зона %s: пул %d наборов (виды %d × тиры %d..%d, дублей нет)"
				% [zone, pool.size(), species, int(band[0]), int(band[1])])
		# Каждый набор пула обязан быть в базе с ТЕМ ЖЕ тиром, что и в имени.
		var wrong_tier := 0
		var missing := 0
		for s2 in pool:
			var sn := str(s2)
			if not sn.begins_with("monsters/"):
				wrong_tier += 1
				continue
			if _tier_of(sn) <= 0:
				missing += 1
				continue
			var tail := sn.get_slice("/", 1)
			var named_tier := 1
			if tail.contains("_t"):
				named_tier = int(tail.get_slice("_t", 1))
			if named_tier != _tier_of(sn):
				wrong_tier += 1
		_check(missing == 0, "зона %s: все наборы пула есть в units_db (нет %d)"
			% [zone, missing])
		_check(wrong_tier == 0,
			"зона %s: тир в имени совпадает с тиром в базе (расхождений %d)"
				% [zone, wrong_tier])
		# Полоса не должна быть пустой и обязана содержать тир 1 только в старте.
		var has_t1 := false
		for s3 in pool:
			if _tier_of(str(s3)) == 1:
				has_t1 = true
		_check(has_t1 == (zone == "start"),
			"зона %s: тир 1 %s" % [zone,
				"есть" if has_t1 else "не появляется"])

	print("-- усиление за тир --")
	# Множители считаются по числам, а не «функция что-то вернула».
	# Шаги берём из [mob_tier]: с 3x.11 формула живёт в конфиге, и тест не
	# должен держать вторую копию 0.35/0.25.
	var hp_step := GameConfig.getf("mob_tier", "hp_step")
	var dmg_step := GameConfig.getf("mob_tier", "damage_step")
	for t in range(1, 6):
		var sn4 := MapGenerator.gray_set_name("wolf", t)
		var m: Array = MapGenerator.gray_tier_mults(sn4)
		var want_hp: float = 1.0 + hp_step * float(t - 1)
		var want_dmg: float = 1.0 + dmg_step * float(t - 1)
		_check(absf(float(m[0]) - want_hp) < 0.001 and absf(float(m[1]) - want_dmg) < 0.001,
			"тир %d: hp x%.2f, урон x%.2f" % [t, float(m[0]), float(m[1])])
	_check(MapGenerator.gray_tier_mults(MapGenerator.gray_set_name("wolf", 5))[0] > 2.0,
		"тир 5 сильнее тира 1 более чем вдвое по hp")

	print("-- имена --")
	var no_name := 0
	var latin := 0
	for sp in MapGenerator.gray_species():
		for t2 in range(1, 6):
			var sn5 := MapGenerator.gray_set_name(str(sp), t2)
			var nm := str(UnitDB.get_set(sn5).get("name_ru", ""))
			if nm.is_empty():
				no_name += 1
			elif nm.to_lower().find("monster") >= 0 or nm.to_lower().find("gemini") >= 0:
				latin += 1
	var total_sets := MapGenerator.gray_species().size() * 5
	_check(no_name == 0, "у всех %d наборов есть name_ru (нет %d)" % [total_sets, no_name])
	_check(latin == 0, "в именах нет английского служебного desc (%d)" % latin)
	_check(str(UnitDB.get_set("monsters/wolf_t5").get("name_ru", "")) == "Владыка волков",
		"тир 5 в родительном падеже: «Владыка волков»")

	print("-- летающие --")
	var z_bad := 0
	for sp2 in MapGenerator.gray_species():
		var base := "monsters/%s" % str(sp2)
		var bz := int(UnitDB.get_set(base).get("z", 0))
		for t3 in range(2, 6):
			var sn6 := MapGenerator.gray_set_name(str(sp2), t3)
			if int(UnitDB.get_set(sn6).get("z", 0)) != bz:
				z_bad += 1
	_check(z_bad == 0, "поле z тирных копий совпадает с базовым набором (%d расхождений)"
		% z_bad)

	print("-- карта по зонам --")
	for zone2 in expected:
		var dir := "user://maps/gt_%s" % zone2
		var alm: String = MapGenerator.new().generate(9001 + int(zone2.length()), zone2, dir)
		# Sidecar — ОБЪЕКТ `{"npcs": [...]}`, а не массив. Присваивание его в
		# `Array` роняет корутину ДО quit(), и headless-процесс живёт вечно —
		# выглядит как «завис», а не как «упало».
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(
			alm.get_basename() + ".npcs.json"))
		var npcs: Array = []
		if parsed is Dictionary:
			npcs = (parsed as Dictionary).get("npcs", [])
		var pool2: Array = MapGenerator.gray_pool_for_zone(zone2)
		var stray := 0
		var lowest := 9
		var highest := 0
		for n in npcs:
			var d: Dictionary = n
			var s7 := str(d.get("set", ""))
			if not s7.begins_with("monsters/"):
				continue
			if not pool2.has(s7):
				stray += 1
			var tt := _tier_of(s7)
			lowest = mini(lowest, tt)
			highest = maxi(highest, tt)
		_check(stray == 0, "зона %s: на карте только наборы своей полосы (чужих %d)"
			% [zone2, stray])
		_check(highest <= int(expected[zone2][1]) and lowest >= int(expected[zone2][0]),
			"зона %s: тиры на карте %d..%d внутри полосы %d..%d"
				% [zone2, lowest, highest,
					int(expected[zone2][0]), int(expected[zone2][1])])

	print("-- каждый вид реально появляется на картах --")
	# Список видов задан ЗДЕСЬ, а не читается из `MapGenerator.gray_species()`.
	# Первая версия проверки перебирала сам список кода — и потому проходила на
	# сломанном коде: убрать `troll` из `GRAY_SPECIES` означало убрать его и из
	# проверки (проверено мутацией: 0 провалов). Ожидание живёт отдельно от
	# реализации, иначе проверка не проверяет ничего.
	var species_expected := ["bat", "bee", "cannibal", "dino", "dragon", "ghost",
		"squirrel", "succubus", "troll", "wolf"]
	var in_code: Array = []
	for sp4 in MapGenerator.gray_species():
		in_code.append(str(sp4))
	var code_missing: Array = []
	var code_extra: Array = []
	for s9 in species_expected:
		if not in_code.has(s9):
			code_missing.append(s9)
	for s10 in in_code:
		if not species_expected.has(s10):
			code_extra.append(s10)
	_check(code_missing.is_empty(),
		"все ожидаемые виды есть в GRAY_SPECIES (нет: %s)" % str(code_missing))
	_check(code_extra.is_empty(),
		"в GRAY_SPECIES нет лишних видов (лишние: %s)" % str(code_extra))

	var seen_species := {}
	for zone3 in expected:
		var dir2 := "user://maps/gt_sp_%s" % zone3
		var alm2: String = MapGenerator.new().generate(7000 + int(zone3.length()), zone3, dir2)
		var parsed2: Variant = JSON.parse_string(FileAccess.get_file_as_string(
			alm2.get_basename() + ".npcs.json"))
		var npcs2: Array = []
		if parsed2 is Dictionary:
			npcs2 = (parsed2 as Dictionary).get("npcs", [])
		for n2 in npcs2:
			var d2: Dictionary = n2
			var s8 := str(d2.get("set", ""))
			if not s8.begins_with("monsters/"):
				continue
			var sp2 := s8.get_slice("/", 1)
			if sp2.contains("_t"):
				sp2 = sp2.get_slice("_t", 0)
			seen_species[sp2] = true
	var absent: Array = []
	for sp3 in species_expected:
		if not seen_species.has(str(sp3)):
			absent.append(str(sp3))
	_check(absent.is_empty(),
		"все %d видов встречаются на картах четырёх зон (нет: %s)"
			% [MapGenerator.gray_species().size(), str(absent)])

	print("RESULT: %s gray_tier_smoke (проверок: %d, провалов: %d)"
		% ["OK" if _fails.is_empty() else "FAIL", _checks, _fails.size()])
	for f in _fails:
		print("  FAIL " + f)
	quit(0)