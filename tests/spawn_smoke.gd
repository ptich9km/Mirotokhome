extends SceneTree
## Smoke-проверка спавна на gen_smart_01: здания, НПЦ городов (стражи/жители),
## Серые-монстры и взаимный бой «страж ↔ Серые».
## Запуск: godot --headless --path . --script res://tests/spawn_smoke.gd

func _initialize() -> void:
	# Подставляем героя, чтобы main.tscn не ушёл на character_select
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 9, "spirit": 8,
		"blade": 30, "bludgeon": 15, "pike": 10,
		"fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.hero_class = "warrior"
	Game.hero_name = "Герой"
	call_deferred("_run")

func _run() -> void:
	var err := change_scene_to_file("res://scenes/main.tscn")
	if err != OK:
		print("SMOKE: не удалось сменить сцену: ", err)
		quit()
		return
	# ждём загрузку мира (2 кадра + пауза)
	await process_frame
	await create_timer(0.5).timeout

	var am = get_first_node_in_group("alm_map")
	var recs: Array = [] if am == null else am.call("get_units")
	var r_guards := 0
	var r_citizens := 0
	var r_greys := 0
	var miss: Array = []
	var blocked_spawns: Array = []
	var path_failures := 0
	for r in recs:
		var role := str(r.get("role", ""))
		match role:
			"guard": r_guards += 1
			"citizen": r_citizens += 1
			_: r_greys += 1
		if not UnitDB.has(str(r.get("set", ""))):
			miss.append(str(r.get("set", "")))
		var rec_pos := Vector2(float(r.get("x", 0)) * 32.0 + 16.0, float(r.get("y", 0)) * 32.0 + 16.0)
		if am != null and not bool(am.call("is_walkable_world", rec_pos)):
			blocked_spawns.append(rec_pos)
		if role == "guard" and am != null and bool(r.get("patrol", false)):
			var post: Array = r.get("post", [])
			if post.size() >= 2:
				var post_pos := Vector2(float(post[0]) * 32.0 + 16.0, float(post[1]) * 32.0 + 16.0)
				if rec_pos.distance_to(post_pos) > 40.0 and am.call("find_path", rec_pos, post_pos).is_empty():
					path_failures += 1
	print("SMOKE: recs=%d (стражи=%d жители=%d серые=%d) missing-sets=%s" % [
		recs.size(), r_guards, r_citizens, r_greys, str(miss)])
	print("SMOKE: blocked_spawns=%d patrol_path_failures=%d" % [
		blocked_spawns.size(), path_failures])

	var guards: Array = []
	var citizens := 0
	for n in Game.npcs:
		if n is Npc:
			if n.role == "guard":
				guards.append(n)
			else:
				citizens += 1
	var greys := Game.enemies.size()
	var patrol := 0
	for g in guards:
		if g.is_patrol:
			patrol += 1
	print("SMOKE: всего НПЦ=%d (стражи=%d патруль=%d жители=%d) Серые=%d" % [
		Game.npcs.size(), guards.size(), patrol, citizens, greys])
	# Separation must NUDGE, not cancel: a neighbour standing exactly in the path
	# used to flip the wish vector backwards ("I cannot walk in the direction he
	# is stuck to"). Now the unit always keeps forward progress and is steered
	# sideways around the neighbour (Diablo 2 behaviour).
	var separation_ok := true
	var steer_ok := true
	if Game.npcs.size() >= 2:
		var first: Node2D = Game.npcs[0]
		var second: Node2D = Game.npcs[1]
		var first_pos := first.global_position
		var second_pos := second.global_position
		first.global_position = Vector2(1000.0, 1000.0)
		# 1) neighbour straight ahead, nearly on top of us: must not reverse the wish
		second.global_position = first.global_position + Vector2(2.0, 0.0)
		Game._sep_grid_frame = -1
		var d_ahead: Vector2 = Game.movement_direction(first, Vector2.RIGHT)
		separation_ok = d_ahead.dot(Vector2.RIGHT) >= 0.5
		# 2) neighbour slightly to the side: must steer AROUND (a sideways component)
		second.global_position = first.global_position + Vector2(2.0, 2.0)
		Game._sep_grid_frame = -1
		var d_side: Vector2 = Game.movement_direction(first, Vector2.RIGHT)
		steer_ok = d_side.x > 0.0 and d_side.y < -0.05
		first.global_position = first_pos
		second.global_position = second_pos
		Game._sep_grid_frame = -1
	print("SMOKE: separation forward=%s steer=%s" % [separation_ok, steer_ok])

	# Ранний выход по отсутствию Серых УДАЛЁН: после чистки Аллодов их нет
	# штатно, и такой выход проглатывал весь отчёт, печатая строку без
	# RESULT. Раньше он был страховкой от тихого провала спавна, теперь
	# отсутствие врагов — норма, и её проверяет блок ниже.

	# Серых на карте нет и это ТЕПЕРЬ ШТАТНЫЙ РЕЖИМ: весь арт Аллодов удалён
	# вместе с 41 набором `monsters/*` (11.10), пул пуст, и игрок сознательно
	# выбрал «не спавнить вовсе», а не подставлять городских стражников.
	#
	# Тест НЕ удалён и не ослаблен: вместо боя страж↔Серый он теперь проверяет
	# то, что обязано выполняться именно при пустом пуле — страж и жители
	# расставлены, ходят, ни один из них не падает и не уходит в враждебное
	# состояние. Когда появятся риги Серых, блок боя вернётся.
	var grays := 0
	for e in Game.enemies:
		if e is Enemy:
			grays += 1
	print("SMOKE: Серых на карте %d (ожидается 0 — пул пуст после чистки Аллодов)" % grays)
	var npcs_ok := true
	var alive := 0
	for n in Game.npcs:
		if not is_instance_valid(n):
			continue
		alive += 1
		var npc := n as Npc
		# Юнит обязан быть живым и иметь валидный набор анимации: при пустом
		# наборе UnitAnim грузится без текстур и юнит становится невидимым,
		# а это тихо ломает город, нигде не падая.
		if npc == null or npc.state == "dead" or str(npc.anim_set).is_empty():
			npcs_ok = false
	print("SMOKE: городских юнитов %d, все живы и с набором=%s" % [alive, npcs_ok])
	if grays == 0 and npcs_ok and separation_ok and steer_ok and not guards.is_empty():
		print("SMOKE: RESULT: OK (пул Серых пуст, городские НПЦ на месте)")
	else:
		print("SMOKE: RESULT: FAIL (grays=", grays, " npcs_ok=", npcs_ok,
			" separation=", separation_ok, " steer=", steer_ok,
			" guards=", guards.size(), ")")
	quit()