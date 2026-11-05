extends SceneTree
## City NPCs: a citizen stands still, and the guard pathfinding budget holds
## (23.10). Run: godot --headless --path . --script res://tests/city_npc_smoke.gd

var _checks := 0
var _fails: Array[String] = []


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print(("  OK  " if ok else "  FAIL") + " " + what)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	GameConfig.load_all()
	UnitDB.ensure_loaded()

	# Citizen count is the same in every zone (3x.11): the numbers live in
	# [city] instead of four identical per-zone blocks.
	var mn := GameConfig.geti("city", "citizen_count_min")
	var mx := GameConfig.geti("city", "citizen_count_max")
	_check(mn == 6 and mx == 9, "citizens 6..9 (got %d..%d)" % [mn, mx])

	var set_name := "city_human_mage/t1"
	if not UnitDB.has(set_name):
		UnitDB.ensure_loaded()
		for k in UnitDB.all_names():
			if str(k).begins_with("city_"):
				set_name = str(k)
				break
	var npc_script: GDScript = load("res://scripts/npc.gd")
	var citizen = npc_script.new()
	citizen.anim_set = set_name
	citizen.role = "citizen"
	citizen.city_id = "c0t0"
	root.add_child(citizen)
	await process_frame
	_check(citizen.is_physics_processing() == false, "a citizen does not simulate physics")
	_check(citizen.velocity == Vector2.ZERO, "a citizen stands still")

	var budget = npc_script.new()
	budget.anim_set = set_name
	budget.role = "guard"
	budget.is_patrol = true
	root.add_child(budget)
	await process_frame
	npc_script._path_frame = -1
	npc_script._path_calls = 0
	var a: bool = budget._can_pathfind()
	var b: bool = budget._can_pathfind()
	var c: bool = budget._can_pathfind()
	_check(a and b and not c, "A* budget: two searches per frame, the third is denied")
	_check(budget.is_physics_processing(), "a patrolling guard simulates physics")

	citizen.queue_free()
	budget.queue_free()
	print("")
	if _fails.is_empty():
		print("RESULT: OK city_npc_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL city_npc_smoke (%d checks, %d fails)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)
