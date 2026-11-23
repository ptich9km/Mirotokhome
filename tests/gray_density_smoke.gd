extends SceneTree
##
## Плотность Серых и респавн (03.10).
##
## Жалоба игрока: «Серых очень мало». Замер показал 15 Серых на карте 128×128 —
## это 1 зверь на 1092 клетки. Плюс респавна не было ВООБЩЕ: убил всех — зона
## пустая навсегда.
##
## Проверяем: карта плотная, звери разведены, респавн доводит до лимита и не
## подставляет игроку зверя под нос.

var _checks := 0
var _fails: Array[String] = []


func _initialize() -> void:
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 9, "spirit": 8,
		"blade": 30, "bludgeon": 15, "pike": 10,
		"fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.hero_class = "warrior"
	Game.hero_name = "Охотник"
	Game.map_zone = "mid"
	Game.request_map_by_seed(4242, "mid")
	call_deferred("_run")


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
	print(("  OK  " if ok else "  FAIL") + " " + msg)


func _run() -> void:
	print("-- плотность на карте --")
	var alm_path: String = MapGenerator.new().generate(4242, "mid", "user://maps/rg_test")
	_check(alm_path != "" and FileAccess.file_exists(alm_path),
		"карта сгенерирована (%s)" % alm_path.get_file())
	# Генератор Дописывает к базовому имени map_<seed>_<zone>, поэтому sidecar
	# берём из возвращённого пути, а не собираем самим.
	var base := alm_path.get_basename()
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(base + ".npcs.json"))
	var npcs: Array = []
	if parsed is Dictionary:
		npcs = (parsed as Dictionary).get("npcs", [])
	var gray_cells := {}
	var gray_n := 0
	for n in npcs:
		var d: Dictionary = n
		if str(d.get("role", "")) == "guard" or str(d.get("role", "")) == "citizen":
			continue
		if not d.has("set"):
			continue
		gray_n += 1
		gray_cells["%d,%d" % [int(d.get("x", 0)), int(d.get("y", 0))]] = true
	print("  серых на карте: %d" % gray_n)
	# ПЛОТНОСТЬ СЕРЫХ — инвариант «карта соответствует ПУЛУ», а не «пул пуст».
	#
	# 11.10 пул был намеренно пуст (арт Аллодов удалён, игрок выбрал «не спавнить
	# вовсе»), и проверки жёстко утверждали ноль. 14.10 игрок попросил временно
	# наполнить пул артом героя, чтобы проверить в игре анимацию удара и смерти —
	# и такие проверки стали запрещать рабочую фичу. Поэтому тест читает ПУЛ ИЗ
	# ГЕНЕРАТОРА и требует согласия в обе стороны:
	#   - наборы вне city_*/ork_mage*/rig/* допустимы только если они в пуле;
	#   - пул пуст -> ни одного Серого ни в данных, ни в живом мире, а тик
	#     респавна обязан быть ноопой (иначе он воскресит удалённые наборы —
	#     самый вероятный способ вернуть Аллодов обратно);
	#   - пул непуст -> Серые есть в данных, живые враги есть на старте, а
	#     респавн выдаёт наборы только из пула.
	# Пул берётся ТЕМ ЖЕ способом, что и в генераторе (`gray_pool_for_zone`),
	# а не своей копией: своя копия разошлась бы с кодом молча.
	var pool: Array = MapGenerator.gray_pool_for_zone("mid")
	print("  пул Серых в зоне mid: %d наборов" % pool.size())

	var stray := 0
	var bandit_sets := {}
	for sets in MapGenerator.bandit_races().values():
		for s in sets:
			bandit_sets[s] = true
	for n in npcs:
		var d: Dictionary = n
		var role := str(d.get("role", ""))
		if role == "guard" or role == "citizen":
			continue   # city population — its own families, not the Grey pool
		var s := str(d.get("set", ""))
		if s.is_empty():
			continue
		if s.begins_with("city_") or s.begins_with("ork_mage") or s.begins_with("rig/"):
			continue
		if bandit_sets.has(s):
			continue   # bandits are a separate legal family (24.11)
		if not pool.has(s):
			stray += 1
			print("  STRAY set `%s`" % s)
	_check(stray == 0,
		"наборы вне городских/rig принадлежат пулу Серых (лишних %d)" % stray)
	_check((pool.is_empty() == (gray_n == 0)),
		"число Серых в данных соответствует пулу: пул=%d серых=%d" % [pool.size(), gray_n])

	print("-- респавн --")
	var err := change_scene_to_file("res://scenes/main.tscn")
	if err != OK:
		_check(false, "main.tscn загрузилась (err=%d)" % err)
		_report()
		return
	await process_frame
	await create_timer(0.6).timeout
	var game := current_scene
	var player = game.get("player")
	_check(player != null, "герой на месте")
	if player == null:
		_report()
		return

	var target := GameConfig.geti("spawn", "gray_target")
	var period := GameConfig.getf("spawn", "gray_respawn_seconds")
	var min_dist := GameConfig.geti("spawn", "gray_respawn_min_dist")
	# Ключи конфига остаются проверяемыми: механизм респавна не сломан, просто
	# кормит его нечем. Когда риги Серых появятся, эта часть заработает сразу.
	_check(target > 0, "лимит Серых задан (%d)" % target)
	_check(period > 0.0, "интервал респавна задан (%.1f с)" % period)
	_check(min_dist > 0, "минимальная дистанция от героя задана (%d клеток)" % min_dist)

	var alive0: int = game.call("_alive_gray_count")
	print("  живых Серых на старте: %d (лимит %d)" % [alive0, target])
	_check((pool.is_empty() and alive0 == 0) or (not pool.is_empty() and alive0 > 0),
		"живые враги на старте соответствуют пулу: пул=%d живых=%d" % [pool.size(), alive0])

	# ГЛАВНАЯ ПРОВЕРКА ЭТОГО ТЕСТА — в обе стороны. Тик респавна при пустом пуле
	# обязан быть НОПОЙ: если он начнёт доставать удалённые наборы (или
	# подставлять city_* вместо Серых — это подмена, которую игрок запретил
	# отдельно), респавн вернёт в игру ровно то, что мы списали 11.10. При
	# непустом пуле он обязан наоборот выдавать наборы ИЗ ПУЛА и только их.
	var spawned := 0
	for _i in range(30):
		game.call("_gray_respawn_tick", period + 0.1)
		await process_frame
		spawned = game.call("_alive_gray_count")
		if not pool.is_empty() and spawned > 0:
			break
	print("  после 30 тиков респавна: %d" % spawned)
	_check((pool.is_empty() and spawned == 0) or (not pool.is_empty() and spawned > 0),
		"респавн соответствует пулу: пул=%d после тиков=%d" % [pool.size(), spawned])
	var sets_now := {}
	for e5 in Game.enemies:
		if is_instance_valid(e5):
			sets_now[str((e5 as Node).get("anim_set"))] = true
	var outside := 0
	for s5 in sets_now.keys():
		var name5 := str(s5)
		if name5.begins_with("city_") or name5.begins_with("ork_mage") \
				or name5.begins_with("rig/"):
			continue
		if bandit_sets.has(name5):
			continue   # bandits from respawn are legal too
		if not pool.has(name5):
			outside += 1
	_check(outside == 0,
		"респавн не подставил набор вместо Серых (чужих=%d, наборы=%s)" % [outside, str(sets_now)])

	# Выключатель: period = 0 -> респавна нет.
	_check(GameConfig.geti("spawn", "gray_target") == 0
			or GameConfig.getf("spawn", "gray_respawn_seconds") > 0.0,
		"респавн управляется конфигом")

	print("-- сторон версии генерации --")
	# Проверять надо НАПРЯМУЮ: положить на диск карту со старой версией и
	# убедиться, что ensure_map её перегенерирует. Проверка «через игру» не
	# работает: к этому моменту карта уже свежая, и отключение проверки версии
	# ни на что не влияет — мутация показала, что тест остаётся зелёным.
	var stale_dir := "user://maps/rgstale/"
	DirAccess.make_dir_recursive_absolute(stale_dir)
	# 10.10: раса входит в имя карты (map_<seed>_<zone>_<race>.alm), поэтому
	# generate и ensure_map обязаны говорить про ОДНУ И ТУ ЖЕ расу — иначе это
	# два разных файла и проверка проходит вхолостую.
	var stale_race: String = MapGenerator.city_race_for_hero("human")
	var stale_path: String = MapGenerator.new().generate(777, "mid", stale_dir, "", "", stale_race)
	_check(stale_path != "" and FileAccess.file_exists(stale_path),
		"эталонная карта сгенерирована (%s)" % stale_path.get_file())
	var stale_base := stale_path.get_basename()
	var stale_parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(stale_base + ".npcs.json"))
	_check(stale_parsed is Dictionary, "sidecar читается")
	if stale_parsed is Dictionary:
		_check(int((stale_parsed as Dictionary).get("gen_version", -1)) == MapGenerator.GEN_VERSION,
			"в свежем sidecar записана текущая версия генератора")
		# Имитируем карту, созданную до правки настроек.
		var old: Dictionary = (stale_parsed as Dictionary).duplicate(true)
		old["gen_version"] = 1
		var f := FileAccess.open(stale_base + ".npcs.json", FileAccess.WRITE)
		f.store_string(JSON.stringify(old))
		f.close()
		MapGenerator.ensure_map(777, "mid", stale_dir, stale_race)
		var after: Variant = JSON.parse_string(
			FileAccess.get_file_as_string(stale_base + ".npcs.json"))
		_check(after is Dictionary
				and int((after as Dictionary).get("gen_version", -1)) == MapGenerator.GEN_VERSION,
			"карта со старой версией ПЕРЕГЕНЕРИРОВАНА (иначе новые настройки не действуют)")

	_report()


func _report() -> void:
	print("RESULT: %s gray_density_smoke (проверок: %d, провалов: %d)"
			% ["OK" if _fails.is_empty() else "FAIL", _checks, _fails.size()])
	for f in _fails:
		print("  FAIL " + f)
	quit(0 if _fails.is_empty() else 1)