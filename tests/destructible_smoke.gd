extends SceneTree
## Destructible world objects (04.11).
##
## A fireball must actually break the tree it lands on: the sprite goes away,
## the cell stops blocking movement and pathfinding sees the hole. Indestructible
## props (lanterns) must survive any damage.
##
## Run: godot --headless --path . --script res://tests/destructible_smoke.gd

const SEED := 4242
const ZONE := "mid"
const OUT_DIR := "user://maps/destructible_smoke/"

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 9, "spirit": 8,
		"blade": 20, "axe": 0, "bludgeon": 0, "pike": 0, "shooting": 10,
		"fire": 0, "water": 0, "air": 0, "earth": 0, "astral": 0,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.hero_class = "warrior"
	Game.hero_name = "Тест"
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print("DESTRUCT: %s %s" % ["ok  " if ok else "FAIL", what])


func _run() -> void:
	# 1) Data: every tree/rock/prop has HP, the lantern is indestructible.
	var hp: Dictionary = _read_json("res://assets/map-objects/destructibles.json")
	_check(hp.get("tree_oak", 0) > 0, "tree_oak разрушаем")
	_check(hp.get("rock", 0) > 0, "rock разрушаем")
	_check(hp.get("prop_barrel", 0) > 0, "prop_barrel разрушаем")
	_check(not hp.has("prop_lantern"), "prop_lantern НЕ разрушаем (фонарь)")

	# 2) A node with HP 0 ignores damage.
	var lantern := AlmObstacle.new()
	lantern.setup("prop_lantern", 1, 40, 40, 20, 40, 0, 0)
	root.add_child(lantern)
	_check(not lantern.destructible, "у фонаря destructible = false")
	_check(not lantern.take_damage(9999), "фонарь не получает урон")
	_check(not lantern.broken, "фонарь не сломан")
	lantern.queue_free()

	# 3) Live map: find a destructible obstacle on walkable ground.
	var path: String = MapGenerator.new().generate(SEED, ZONE, OUT_DIR)
	if path == "" or not FileAccess.file_exists(path):
		_check(false, "карта сгенерирована")
		_finish()
		return
	var alm := AlmMap.new()
	alm.alm_path = path
	root.add_child(alm)
	await process_frame
	await process_frame

	var target := _find_destructible(alm, true)
	var second := _find_destructible(alm, true, target)
	_check(target.x >= 0, "на карте есть разрушаемое препятствие")
	_check(second.x >= 0, "на карте есть второе разрушаемое препятствие")
	if target.x < 0 or second.x < 0:
		alm.queue_free()
		_finish()
		return

	var target_ground := _ground(target)
	var before_reason := alm.blocked_reason(target)
	_check(before_reason == "дерево/камень",
		"до удара клетка занята объектом (%s)" % before_reason)
	_check(not alm.is_walkable_world(target_ground), "до удара клетка непроходима")

	# 4) Partial damage keeps the object alive.
	var second_ground := _ground(second)
	var second_node: AlmObstacle = alm._obstacle_nodes.get(second)
	var second_hp := second_node.hp
	alm.damage_area(second_ground, 4.0, 1)
	_check(second_node.hp == second_hp - 1, "частичный урон снял 1 HP (%d -> %d)"
		% [second_hp, second_node.hp])
	_check(alm.blocked_reason(second) == "дерево/камень",
		"после частичного урона объект ещё стоит")

	# 5) Lethal damage removes the node and opens the cell.
	alm.damage_area(target_ground, 8.0, 9999)
	await process_frame
	var i := target.y * alm.map_width + target.x
	_check(int(alm._obstacles[i]) == 0, "клетка очищена в _obstacles")
	_check(not alm._obstacle_nodes.has(target), "узел убран из реестра")
	_check(alm.blocked_reason(target) != "дерево/камень",
		"клетка больше не занята объектом (%s)" % alm.blocked_reason(target))
	_check(alm.is_walkable_world(target_ground), "клетка стала проходимой")

	# 6) Indestructible lantern is not affected by the area call.
	var lantern_cell := _find_lantern(alm)
	if lantern_cell.x >= 0:
		var li := lantern_cell.y * alm.map_width + lantern_cell.x
		alm.damage_area(_ground(lantern_cell), 8.0, 9999)
		_check(int(alm._obstacles[li]) != 0, "фонарь пережил урон по площади")
	else:
		_check(true, "фонарей на карте нет — проверка пропущена")

	# 7) Outside the radius nothing is touched.
	if not second_node.broken and is_instance_valid(second_node):
		var far := second_ground + Vector2(400, 400)
		var hp_before := second_node.hp
		alm.damage_area(far, 8.0, 9999)
		_check(second_node.hp == hp_before, "вне радиуса объект не повреждён")

	alm.queue_free()
	await process_frame
	_finish()


func _find_destructible(alm: AlmMap, need_walkable: bool, skip: Vector2i = Vector2i(-1, -1)) -> Vector2i:
	for y in range(alm.map_height):
		for x in range(alm.map_width):
			var cell := Vector2i(x, y)
			if cell == skip:
				continue
			var i := y * alm.map_width + x
			var oid := int(alm._obstacles[i])
			if oid == 0:
				continue
			var spec: Dictionary = alm._obstacle_db.get(str(oid), {})
			if not alm._destructible_hp.has(str(spec.get("folder", ""))):
				continue
			# The obstacle itself makes the cell unwalkable, so check WHY:
			# "дерево/камень" means the ground under it is walkable.
			if need_walkable and alm.blocked_reason(cell) != "дерево/камень":
				continue
			return cell
	return Vector2i(-1, -1)


func _find_lantern(alm: AlmMap) -> Vector2i:
	for y in range(alm.map_height):
		for x in range(alm.map_width):
			var oid := int(alm._obstacles[y * alm.map_width + x])
			if oid == 0:
				continue
			var spec: Dictionary = alm._obstacle_db.get(str(oid), {})
			if str(spec.get("folder", "")) == "prop_lantern":
				return Vector2i(x, y)
	return Vector2i(-1, -1)


func _ground(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * 32 + 16, cell.y * 32 + 16)


func _read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


func _finish() -> void:
	print("")
	if _fails.is_empty():
		print("RESULT: OK destructible_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL destructible_smoke (%d checks, %d fails)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)
