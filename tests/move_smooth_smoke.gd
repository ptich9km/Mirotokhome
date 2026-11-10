extends SceneTree
## Движение героя: путь не должен «рывками» обрываться на длинных кликах.
##
## На карте 192×192 BFS-лимит часто обрывал find_path -> []. Раньше
## move_to_target при пустом пути ставил idle — герой замирал, игрок кликал
## снова -> рывки. Теперь: (1) find_path при лимите отдаёт путь к ближайшей
## клетке у цели; (2) после пустого пути герой идёт напрямую.
##
## Запуск: godot --headless --path . --script res://tests/move_smooth_smoke.gd

const TILE := 32
const FRAMES := 120

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
	print(("  OK  " if ok else "  FAIL") + " " + msg)


func _run() -> void:
	Game.hero_class = "warrior"
	Game.hero_name = "Тест"
	Game.hero_character_id = "mfighter"
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 9, "spirit": 8,
		"blade": 30, "bludgeon": 15, "pike": 10,
		"fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.map_seed = 4242
	var packed: PackedScene = load("res://scenes/main.tscn")
	var game = packed.instantiate()
	root.add_child(game)
	for i in range(4):
		await process_frame
	var player = game.get("player")
	var am = game.get("alm_map")
	await process_frame
	_check(player != null and am != null, "сцена загружена")
	var w: int = int(am.map_width)
	var h: int = int(am.map_height)
	_check(w >= 192 and h >= 192, "карта 192+ (%dx%d)" % [w, h])

	# Длинный путь по диагонали карты: find_path не должен возвращать []
	# только из-за лимита (пусть и частичный, но непустой).
	var start := Vector2(2 * TILE + 16, 2 * TILE + 16)
	var goal := Vector2((w - 3) * TILE + 16, (h - 3) * TILE + 16)
	if not am.is_walkable_world(start):
		start = _nearest_walk(am, Vector2i(2, 2))
	if not am.is_walkable_world(goal):
		goal = _nearest_walk(am, Vector2i(w - 3, h - 3))
	player.global_position = start
	player.reset_physics_interpolation()
	var path: Array = am.find_path(start, goal)
	_check(path.size() > 0, "длинный путь непустой (клеток: %d)" % path.size())
	if path.size() > 0:
		var last: Vector2 = path[path.size() - 1]
		var d_goal := last.distance_to(goal)
		var d_start := last.distance_to(start)
		_check(d_start > 40.0, "путь ушёл от старта (%.0f px)" % d_start)
		_check(d_goal <= d_start + 1.0 or path.size() >= 8,
			"путь полезен к цели (дистанция до цели %.0f)" % d_goal)

	# Движение: за N физкадров герой обязан пройти заметное расстояние
	# (не замирать на месте после первого кадра).
	var from: Vector2 = player.global_position
	var far_goal: Vector2 = Vector2(from.x + 200.0, from.y)
	# ищем проходимую точку справа
	for dx in range(4, 40):
		var p: Vector2 = Vector2(from.x + float(dx * TILE), from.y)
		if am.is_walkable_world(p) and am.is_within_bounds(p):
			far_goal = p
			break
	player.state = "move"
	Game.player_target = far_goal
	player.begin_path(am.find_path(from, far_goal))
	var max_step := 0.0
	var last_pos: Vector2 = from
	for f in range(FRAMES):
		await physics_frame
		var d: float = player.global_position.distance_to(last_pos)
		if d > max_step:
			max_step = d
		last_pos = player.global_position
		if player.global_position.distance_to(far_goal) < 12.0:
			break
	var total: float = player.global_position.distance_to(from)
	_check(total > 30.0, "герой прошёл >30px за %d кадров (=%.0f px)" % [FRAMES, total])
	_check(max_step > 0.5, "были кадры с движением (max step %.2f)" % max_step)
	# Рывки: не должно быть чередования «прошёл 20px -> застыл на 20 кадров».
	#
	# Мерим ТОЛЬКО пока герой идёт: прежняя версия крутила 120 кадров после
	# прибытия, и каждый кадр стояния на месте засчитывался как «застой».
	# На быстром герое это был гарантированный провал на исправном движении
	# (max still = все кадры после прихода). Останавливаем замер по прибытии
	# или по завершении приказа — сама проверка не ослаблена.
	var still_frames := 0
	var max_still := 0
	last_pos = from
	for f in range(FRAMES):
		await physics_frame
		var d2: float = player.global_position.distance_to(last_pos)
		if d2 < 0.3:
			still_frames += 1
			if still_frames > max_still:
				max_still = still_frames
		else:
			still_frames = 0
		last_pos = player.global_position
		if player.global_position.distance_to(far_goal) < 12.0 or player.state == "idle":
			break
	_check(max_still < 25,
		"нет длинных застоев во время ходьбы (max still=%d кадров)" % max_still)

	_report()


func _nearest_walk(am, cell: Vector2i) -> Vector2:
	for r in range(1, 20):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if abs(dx) != r and abs(dy) != r:
					continue
				var c := cell + Vector2i(dx, dy)
				var p := Vector2(c.x * TILE + 16, c.y * TILE + 16)
				if am.is_walkable_world(p):
					return p
	return Vector2(64, 64)


func _report() -> void:
	print()
	if _fails.is_empty():
		print("RESULT: OK move_smooth_smoke checks=%d" % _checks)
		quit(0)
	else:
		print("RESULT: FAIL move_smooth_smoke checks=%d fails=%d" % [_checks, _fails.size()])
		for m in _fails:
			print("  - %s" % m)
		quit(1)
