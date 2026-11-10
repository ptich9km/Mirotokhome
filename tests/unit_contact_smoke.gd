extends SceneTree
## Contact with other units must never "glue" the hero to them.
##
## Player reports (11.11): a Gray attacking you feels glued — you step back and he
## is still on you; a mercenary on "follow" becomes a wall you cannot walk towards.
## Root causes (all fixed here, Diablo 1/2 model):
##  1. the click target could be the BODY of a unit — now it shifts to the nearest
##     free cell (D2 `PathTargetFree`);
##  2. the path knew nothing about units — now the search routes around their cells;
##  3. the order died on the FIRST blocked frame (`state = "idle"` + target wiped),
##     which also disabled _escape_blocking_units — now a stall replans the route;
##  4. separation could flip the wish vector backwards — now it steers sideways
##     and always keeps forward progress;
##  5. bodies were 24 px (hero 30 px) — now one 20 px core for everyone, so a unit
##     blocks only its centre (D2) and two figures can pass in a 32 px corridor;
##  6. a hireling is not a wall for its owner (Diablo 2 pets/hirelings rule);
##  7. melee contact broke after 8 px — now 24 px, so backing off creates a gap.
##
## Run: godot --headless --path . --script res://tests/unit_contact_smoke.gd
## Result: RESULT: OK unit_contact_smoke checks=N

const TILE := 32
const MONSTER_SET := "ork_mage_a52/t0"
const MERC_SET := "ork_mage_a52/t1"

var _checks := 0
var _fails: Array[String] = []
var _game: Node = null
var _hero: Player = null
var _map: Node = null
var _spawned: Array = []


func _initialize() -> void:
	Game.hero_class = "warrior"
	Game.hero_name = "Тест"
	Game.hero_character_id = "mfighter"
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 9, "spirit": 8,
		"blade": 30, "bludgeon": 15, "pike": 10,
		"fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.map_seed = 4242
	Game.action_mode = "stop"
	call_deferred("_run")


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
	print(("  OK  " if ok else "  FAIL ") + msg)


func _run() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	_game = packed.instantiate()
	root.add_child(_game)
	for i in range(4):
		await process_frame
	_hero = _game.get("player")
	_map = _game.get("alm_map")
	_check(_hero != null and _map != null, "сцена загружена")
	if _hero == null or _map == null:
		_report()
		return
	_test_core_and_reach()
	await _test_separation_keeps_forward()
	await _test_path_avoids_units()
	await _test_walk_around_blocker()
	await _test_click_on_mercenary()
	await _test_mercenary_is_not_a_wall()
	_report()


# --- 1. Body size and melee exit ---------------------------------------------

func _test_core_and_reach() -> void:
	print("-- корпус и выход из боя --")
	_check(is_equal_approx(Game.UNIT_CORE_RADIUS, 10.0),
		"корпус юнита 10 px (было 12, у героя 15)")
	var hero_shape := _circle_of(_hero)
	_check(hero_shape != null and is_equal_approx(hero_shape.radius, 10.0),
		"корпус героя приведён к 10 px (сцена хранила 15)")
	var enemy := Enemy.new()
	enemy.anim_set = MONSTER_SET
	enemy.max_hp = 10
	enemy.damage = 0
	_game.add_child(enemy)
	var enemy_shape := _circle_of(enemy)
	_check(enemy_shape != null and is_equal_approx(enemy_shape.radius, 10.0),
		"корпус врага 10 px")
	_untrack(enemy)
	enemy.queue_free()
	_check(is_equal_approx(Game.attack_exit_reach(_hero),
		Game.attack_reach(_hero) + 24.0),
		"выход из атаки = удар + 24 px (было +8): отход создаёт разрыв")


func _circle_of(u: Node) -> CircleShape2D:
	if u == null:
		return null
	for child in u.get_children():
		if child is CollisionShape2D:
			var sh: Shape2D = (child as CollisionShape2D).shape
			if sh is CircleShape2D:
				return sh as CircleShape2D
	return null


# --- 2. Separation keeps forward progress ------------------------------------

func _test_separation_keeps_forward() -> void:
	print("-- расталкивание не разворачивает --")
	var spot := _find_field_spot()
	if spot.x < 0:
		_check(false, "найдено открытое поле")
		return
	await _place_hero(spot)
	var foe := await _spawn_enemy(spot + Vector2i(0, 0))
	_hero.global_position = _cell_center(spot)
	foe.global_position = _hero.global_position + Vector2(2.0, 0.0)
	Game._sep_grid_frame = -1
	var ahead: Vector2 = Game.movement_direction(_hero, Vector2.RIGHT)
	_check(ahead.dot(Vector2.RIGHT) >= 0.5,
		"сосед ровно впереди: направление не развернулось (dot=%.2f)" % ahead.dot(Vector2.RIGHT))
	foe.global_position = _hero.global_position + Vector2(2.0, 2.0)
	Game._sep_grid_frame = -1
	var side: Vector2 = Game.movement_direction(_hero, Vector2.RIGHT)
	_check(side.x > 0.0 and side.y < -0.05,
		"сосед сбоку: обходим, а не стоим (dir=%.2f,%.2f)" % [side.x, side.y])
	await _clear_spawned()


# --- 3. Path knows about unit cells ------------------------------------------

func _test_path_avoids_units() -> void:
	print("-- путь обходит тела --")
	var spot := _find_field_spot()
	if spot.x < 0:
		_check(false, "найдено открытое поле")
		return
	await _place_hero(spot)
	var cells := [spot + Vector2i(2, -1), spot + Vector2i(2, 0), spot + Vector2i(2, 1)]
	for c in cells:
		await _spawn_enemy(c)
	var blocked := Game.occupied_cells([_hero])
	var goal := _cell_center(spot + Vector2i(5, 0))
	var path: Array = _map.find_path(_hero.global_position, goal, blocked)
	_check(path.size() > 0, "путь вокруг трёх тел найден (точек: %d)" % path.size())
	var hits := 0
	for p in path:
		if blocked.has(_cell_of(p)):
			hits += 1
	_check(hits == 0, "ни одна точка пути не лежит в занятой клетке (%d)" % hits)
	var blind: Array = _map.find_path(_hero.global_position, goal)
	_check(blind.size() > 0, "путь без учёта тел по-прежнему работает (откат)")
	await _clear_spawned()


# --- 4. The hero walks around a body instead of stalling ---------------------

func _test_walk_around_blocker() -> void:
	print("-- обход тела без застоя --")
	var spot := _find_field_spot()
	if spot.x < 0:
		_check(false, "найдено открытое поле")
		return
	await _place_hero(spot)
	await _spawn_enemy(spot + Vector2i(2, 0))
	var goal := _cell_center(spot + Vector2i(5, 0))
	var blocked := Game.occupied_cells([_hero])
	Game.player_target = goal
	_hero.state = "move"
	_hero.begin_path(_map.find_path(_hero.global_position, goal, blocked))
	var from: Vector2 = _hero.global_position
	var max_still: int = await _drive(240)
	var moved: float = _hero.global_position.distance_to(from)
	_check(moved > 80.0, "герой прошёл сквозь линию с телом (%.0f px)" % moved)
	_check(max_still < 30, "нет длинного застоя (макс %d кадров)" % max_still)
	_check(_hero.state != "idle" or moved > 80.0, "приказ не отменён на первом же кадре")
	await _clear_spawned()


# --- 5. Click on a body leads to a free cell ---------------------------------

func _test_click_on_mercenary() -> void:
	print("-- клик в наёмника ведёт на свободную клетку --")
	var spot := _find_field_spot()
	if spot.x < 0:
		_check(false, "найдено открытое поле")
		return
	await _place_hero(spot)
	var merc_cell := spot + Vector2i(2, 0)
	var merc := Mercenary.new()
	merc.anim_set = MERC_SET
	merc.max_hp = 70
	merc.position = _cell_center(merc_cell)
	_game.add_child(merc)
	Game.party.append(merc)
	_track(merc)
	await process_frame
	await process_frame
	Game.action_mode = "stop"

	var click := _cell_center(merc_cell)
	_game.handle_click(click)
	_check(_cell_of(Game.player_target) != merc_cell,
		"цель клика сдвинута из занятой клетки (%s -> %s)"
			% [str(merc_cell), str(_cell_of(Game.player_target))])
	_check(_hero.state == "move", "приказ на движение принят")
	var from: Vector2 = _hero.global_position
	var max_still: int = await _drive(240)
	var moved: float = _hero.global_position.distance_to(from)
	_check(moved > 40.0, "герой пошёл в сторону наёмника (%.0f px)" % moved)
	_check(max_still < 30, "без длинного застоя (макс %d кадров)" % max_still)
	await _clear_spawned()


# --- 6. A follower is not a wall for the hero --------------------------------

func _test_mercenary_is_not_a_wall() -> void:
	print("-- наёмник не стена герою --")
	var spot := _find_field_spot()
	if spot.x < 0:
		_check(false, "найдено открытое поле")
		return
	await _place_hero(spot)
	var merc_cell := spot + Vector2i(1, 0)
	var merc := Mercenary.new()
	merc.anim_set = MERC_SET
	merc.max_hp = 70
	merc.position = _cell_center(merc_cell)
	_game.add_child(merc)
	Game.party.append(merc)
	_track(merc)
	await process_frame
	await process_frame
	Game.action_mode = "stop"
	var hero_body := _hero as CollisionObject2D
	var merc_body := merc as CollisionObject2D
	_check(hero_body.get_collision_exceptions().has(merc),
		"герой игнорирует наёмника (исключение коллизии)")
	_check(merc_body.get_collision_exceptions().has(_hero),
		"наёмник игнорирует героя (исключение коллизии)")
	# Walk straight THROUGH the follower's cell.
	var goal := _cell_center(spot + Vector2i(3, 0))
	Game.player_target = goal
	_hero.state = "move"
	_hero.begin_path([goal])
	var from: Vector2 = _hero.global_position
	var max_still: int = await _drive(240)
	var moved: float = _hero.global_position.distance_to(from)
	_check(moved > 60.0, "герой прошёл сквозь наёмника (%.0f px)" % moved)
	_check(max_still < 20, "наёмник не держит героя (макс застой %d кадров)" % max_still)
	await _clear_spawned()


# --- Helpers ----------------------------------------------------------------

func _drive(frames: int) -> int:
	var still := 0
	var max_still := 0
	var last: Vector2 = _hero.global_position
	for f in range(frames):
		await physics_frame
		var d: float = _hero.global_position.distance_to(last)
		last = _hero.global_position
		if d < 0.3:
			still += 1
			if still > max_still:
				max_still = still
		else:
			still = 0
		if _hero.state == "idle" and still > 10:
			break
	return max_still


func _cell_of(p: Vector2) -> Vector2i:
	return Vector2i(int(floor(p.x / float(TILE))), int(floor(p.y / float(TILE))))


func _cell_center(c: Vector2i) -> Vector2:
	return Vector2(c.x * TILE + TILE / 2.0, c.y * TILE + TILE / 2.0)


func _place_hero(cell: Vector2i) -> void:
	_hero.global_position = _cell_center(cell)
	_hero.reset_physics_interpolation()
	_hero.stop_movement()
	await physics_frame


func _spawn_enemy(cell: Vector2i) -> Enemy:
	var e := Enemy.new()
	e.name = "ContactProbe_%d" % _spawned.size()
	e.anim_set = MONSTER_SET
	e.max_hp = 200
	e.damage = 0
	e.aggro_radius = 0.0
	e.deaggro_radius = 0.0
	e.state = "idle"
	e.position = _cell_center(cell)
	_game.add_child(e)
	Game.enemies.append(e)
	_track(e)
	await process_frame
	return e


## A field cell with free walkable space around it and no herbs/structures on the
## cells the scenarios use (a click on a herb or a building is a different action).
func _find_field_spot() -> Vector2i:
	var w := int(_map.map_width)
	var h := int(_map.map_height)
	var attempts := 0
	for y in range(4, h - 4, 2):
		for x in range(4, w - 7, 2):
			attempts += 1
			if attempts > 4000:
				return Vector2i(-1, -1)
			var ok := true
			for dy in range(-2, 3):
				for dx in range(-2, 6):
					var c := Vector2i(x + dx, y + dy)
					var p := _cell_center(c)
					if not bool(_map.call("is_walkable_world", p)):
						ok = false
						break
					if _map.has_method("herb_at_position") \
							and _map.call("herb_at_position", p) != null:
						ok = false
						break
					if _map.has_method("structure_at") \
							and not (_map.call("structure_at", c) as Dictionary).is_empty():
						ok = false
						break
				if not ok:
					break
			if ok:
				return Vector2i(x, y)
	return Vector2i(-1, -1)


func _track(u: Node) -> void:
	_spawned.append(u)


func _untrack(u: Node) -> void:
	_spawned.erase(u)


func _clear_spawned() -> void:
	for u in _spawned:
		if is_instance_valid(u):
			Game.enemies.erase(u)
			Game.party.erase(u)
			Game.npcs.erase(u)
			u.queue_free()
	_spawned.clear()
	await process_frame


func _report() -> void:
	print()
	if _fails.is_empty():
		print("RESULT: OK unit_contact_smoke checks=%d" % _checks)
		quit(0)
	else:
		print("RESULT: FAIL unit_contact_smoke checks=%d fails=%d" % [_checks, _fails.size()])
		for m in _fails:
			print("  - %s" % m)
		quit(1)
