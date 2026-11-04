extends SceneTree
## Мягкая смесь всех пар биомов + блок гор для пеших (05.10).
##
## BlendMesh: COLOR = (primary/6, secondary/6, mix, brightness).
## Дорога (3) — жёстко (m=0). Все клетки террейна на BlendMesh.
## WalkTable: file 2 (горы) и file 3 (вода) непроходимы для пеших.
## Летающие (fly_z>0) обходят землю в enemy.gd.
##
## Запуск: godot --headless --path . --script res://tests/blend_water_sand_smoke.gd

const SEED := 4242

var _fails: Array[String] = []
var _checks := 0

func _initialize() -> void:
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 9, "spirit": 8,
		"blade": 30, "bludgeon": 15, "pike": 10,
		"fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.hero_class = "warrior"
	Game.hero_name = "Герой"
	call_deferred("_run")

func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
	print(("  OK  " if ok else "  FAIL") + " " + msg)

func _run() -> void:
	# --- WalkTable: горы/вода блок для пеших ---
	_check(WalkTable.walkable(WalkTable.MOUNTAIN_FILE, 0) == false,
		"горы (file 2) непроходимы для пеших")
	_check(WalkTable.walkable(WalkTable.WATER_FILE, 0) == false,
		"вода (file 3) непроходима для пеших")
	_check(WalkTable.walkable(1, 0) == true, "трава проходима")
	_check(WalkTable.walkable(4, 0) == true, "дорога проходима")
	_check(WalkTable.walkable_at(1, 0) == false,
		"walkable_at для hf гор (hf=1=file2-1) — false")

	# Flying units. The check was INVERTED on 11.10: after the Allods art
	# purge the DB had no set with z>0, so the test guarded against fliers
	# returning. On 17.10 fliers came back with real art (bat/bee/ghost/
	# dragon/succubus plus tiers), the check went red and lied for weeks.
	# Now it asserts what must hold: fliers exist and have z>0, infantry
	# stays on the ground.
	var flying := 0
	for name in UnitDB.all_names(""):
		if UnitDB.fly_z(str(name)) > 0:
			flying += 1
	_check(flying > 0,
		"летающие наборы есть (fly_z > 0), найдено: %d" % flying)
	_check(UnitDB.fly_z("monsters/bat") > 0, "битый набор летает (bat)")
	_check(UnitDB.fly_z("monsters/succubus") > 0, "суккуб летает")
	_check(UnitDB.fly_z("monsters/wolf") == 0, "волк — пехота без fly_z")
	_check(UnitDB.fly_z("seed/sw_seed") == 0, "набор-заглушка без fly_z")

	# --- Карта: BlendMesh ---
	Game.request_map_by_seed(SEED, "mid")
	var err := change_scene_to_file("res://scenes/main.tscn")
	_check(err == OK, "main.tscn сменилась")
	await process_frame
	await create_timer(0.5).timeout

	var am = get_first_node_in_group("alm_map")
	_check(am != null, "AlmMap в дереве")
	if am == null:
		_report()
		return

	var bm = am.get("blend_mesh")
	_check(bm != null, "BlendMesh создан")
	_check(int(am.get("_blend_cells")) > 0, "бленд-клетки есть (%d)" % int(am.get("_blend_cells")))
	_check(int(am.get("_blend_strips").size()) == 7, "7 полос биомов")

	if bm != null:
		_check(bm.mesh != null and bm.mesh.get_surface_count() >= 1, "у BlendMesh есть меш")
		var mat: Material = bm.material
		_check(mat is ShaderMaterial, "BlendMesh — ShaderMaterial")
		if mat is ShaderMaterial:
			var sh: Shader = (mat as ShaderMaterial).shader
			if sh != null:
				_check(sh.code.contains("u_border") and sh.code.contains("sample_biome"),
					"шейдер: u_border + sample_biome")
				_check(sh.code.contains("0.38") and sh.code.contains("0.55"),
					"шейдер: smoothstep границы + cap primary")
	_check(am.get("_blend_primary") != null, "u_primary создан")
	_check(am.get("_blend_secondary") != null, "u_secondary создан")
	_check(am.get("_blend_border") != null, "u_border создан")

	# Спавн героя не в горах/воде
	if am != null and am.has_method("is_walkable_world"):
		var sp: Vector2 = am.call("get_spawn_pos")
		_check(am.is_walkable_world(sp), "спавн на проходимой клетке")

	_report()

func _report() -> void:
	if _fails.is_empty():
		print("RESULT: OK blend_water_sand_smoke (%d)" % _checks)
		quit(0)
	else:
		print("RESULT: FAIL (%d): %s" % [_fails.size(), str(_fails)])
		quit(1)
