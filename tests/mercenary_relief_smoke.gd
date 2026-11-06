extends SceneTree
## Mercenary relief (04.11, audit R-P1-1).
##
## The old code took the map from Game.hero (a unit that never belongs to the
## "alm_map" group), so a mercenary stood at height 0 on every hill. The map
## now comes from the group, exactly as NPCs and enemies do.
##
## Run: godot --headless --path . --script res://tests/mercenary_relief_smoke.gd

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
	print("RELIEF: %s %s" % ["ok  " if ok else "FAIL", what])


func _run() -> void:
	var fake := _fake_map(42.0)
	root.add_child(fake)
	var hero := Node2D.new()
	hero.name = "Hero"
	root.add_child(hero)
	Game.hero = hero

	var merc := Mercenary.new()
	merc.anim_set = "ork_mage_a52/t1"
	root.add_child(merc)
	await process_frame
	merc.global_position = Vector2(100, 100)
	merc.call("_apply_relief_stand")
	_check(is_equal_approx(merc._anim.position.y, -42.0),
		"наёмник поднят на высоту рельефа (%.1f)" % merc._anim.position.y)

	# The old bug: an object in Game.hero must not be mistaken for the map.
	_check(not hero.is_in_group("alm_map"), "герой не состоит в группе alm_map")

	fake.queue_free()
	await process_frame
	merc.call("_apply_relief_stand")
	_check(is_equal_approx(merc._anim.position.y, 0.0),
		"без карты высота 0 (%.1f)" % merc._anim.position.y)

	merc.queue_free()
	hero.queue_free()
	Game.hero = null
	_finish()


func _fake_map(height: float) -> Node2D:
	var node := Node2D.new()
	node.name = "FakeMap"
	node.add_to_group("alm_map")
	var gd := GDScript.new()
	gd.source_code = "extends Node2D\nfunc relief_at_world(_p: Vector2) -> float:\n\treturn %.1f\n" % height
	gd.reload()
	node.set_script(gd)
	return node


func _finish() -> void:
	print("")
	if _fails.is_empty():
		print("RESULT: OK mercenary_relief_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL mercenary_relief_smoke (%d checks, %d fails)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)
