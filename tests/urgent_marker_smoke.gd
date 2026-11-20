extends SceneTree
## URGENT quest: what the code really does with the hunt marker and the pack.
##
## Written after the player's report "не видно на карте и у города никого нет".
## It pins the mechanism instead of guessing: an URGENT quest is counted by the
## killed enemy's anim_set (notify_killed -> _counts_kill), and its map mark is
## the den of a LIVE matching enemy (_nearest_den_cell). No matching pack on the
## map - no mark: that is the behaviour, and it is not caused by the panel or the
## icon work, which never touches these two functions.
##
## Run: godot --headless --path . --script res://tests/urgent_marker_smoke.gd

var _fails: Array[String] = []
var _checks := 0
var _ran := false


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
		print("URGENT: FAIL %s" % what)
	else:
		print("URGENT: ok   %s" % what)


func _initialize() -> void:
	pass


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_run()
	return true


func _run() -> void:
	var qs := QuestSystem.new()
	qs.name = "UrgentSmoke"
	root.add_child(qs)
	Game.enemies.clear()
	Game.hero = null

	var set_name := "monsters/troll_t2"
	var q := {
		"id": "urgent_smoke",
		"type": "URGENT",
		"set": set_name,
		"species": "troll",
		"need": 3,
		"progress": 0,
		"state": QuestSystem.STATE_ACTIVE,
		"city_id": "c0t0",
		"sector": Game.map_sector,
	}
	qs.active.append(q)

	# 1. No pack on the map - no mark at all. This is the reported symptom, and
	#    it comes from the den lookup, which existed before the minimap work.
	_check(qs.objective_cell(q) == Vector2i(-1, -1),
		"без стаи на карте метки нет (возврат -1,-1)")

	# 2. A live pack of exactly the quest's set gives the mark at its den.
	var pack := _make_enemy(set_name, Vector2(320, 416))
	Game.enemies.append(pack)
	var cell := qs.objective_cell(q)
	_check(cell == Vector2i(10, 13),
		"стая в клетке (10,13) даёт метку именно там (%s)" % str(cell))

	# 3. A beast of another set must not move the mark.
	var other := _make_enemy("monsters/wolf_t1", Vector2(64, 64))
	Game.enemies.append(other)
	_check(qs.objective_cell(q) == Vector2i(10, 13),
		"чужая стая метку не перетягивает (%s)" % str(qs.objective_cell(q)))

	# 4. A dead beast does not count.
	pack.set("state", "dying")
	_check(qs.objective_cell(q) == Vector2i(-1, -1),
		"умирающая стая метку не держит")

	# 5. Kills count by the set of the killed beast, whatever its state.
	Game.enemies.clear()
	pack.free()
	other.free()
	qs.notify_killed(set_name)
	_check(int(q.get("progress", 0)) == 1,
		"убийство нужного набора идёт в прогресс (%d)" % int(q.get("progress", 0)))
	qs.notify_killed("monsters/wolf_t1")
	_check(int(q.get("progress", 0)) == 1,
		"убийство чужого набора прогресс не двигает (%d)" % int(q.get("progress", 0)))

	# 6. The species lives in the quest and in the title placeholders: the
	#    template text says "%s are already at the gates".
	_check(str(q.get("species", "")) == "troll", "вид записан в квест")
	var tpl := QuestDB.template("urgent_hunt")
	_check(not tpl.is_empty() and str(tpl.get("type", "")) == "URGENT",
		"шаблон urgent_hunt на месте")

	# 7. The pack promised by the text: with a map and a town, taking the quest
	#    puts beasts at the gates, and the top-up only fills the gap.
	_run_pack_check(qs)

	print("")
	if _fails.is_empty():
		print("RESULT: OK urgent_marker_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL urgent_marker_smoke (%d checks, %d fails)"
			% [_checks, _fails.size()])
	quit(0 if _fails.is_empty() else 1)


## A stand-in world: a map in the "alm_map" group (open grass everywhere, a
## town at (10,10)), a hero with a parent to hold the beasts.
func _run_pack_check(qs: QuestSystem) -> void:
	Game.enemies.clear()
	var world := Node2D.new()
	world.name = "PackWorld"
	root.add_child(world)
	var map := Node2D.new()
	map.name = "PackMap"
	map.set_script(_map_script())
	map.add_to_group("alm_map")
	world.add_child(map)
	var hero := Node2D.new()
	hero.name = "Hero"
	hero.position = Vector2(320, 320)
	world.add_child(hero)
	Game.hero = hero

	var q := {
		"id": "urgent_pack", "type": "URGENT", "state": QuestSystem.STATE_ACTIVE,
		"set": "monsters/troll_t2", "species": "troll", "need": 6,
		"city_id": "c0t0", "sector": Game.map_sector,
	}
	qs.active.append(q)
	var spawned := qs._ensure_urgent_pack(q)
	_check(spawned == 6, "у ворот появляется стая по числу целей (%d из 6)" % spawned)
	_check(Game.enemies.size() == 6, "стая зарегистрирована в Game.enemies (%d)"
		% Game.enemies.size())
	var den := qs.objective_cell(q)
	_check(den != Vector2i(-1, -1), "после спавна метка на карте есть (%s)" % str(den))
	_check(qs._ensure_urgent_pack(q) == 0, "повторный топ-ап лишних не плодит")
	# One beast falls: the pack is topped back to the target.
	for e in Game.enemies:
		e.set("state", "dying")
		break
	_check(qs._ensure_urgent_pack(q) == 1, "выбывшую тварь стая добирает")
	# A raid kill must reach the journal: the map is what forwards Enemy.died.
	qs._bind_map(map)
	var victim: Enemy = null
	for e in Game.enemies:
		if is_instance_valid(e) and (e as Enemy).assault_to != Vector2.INF:
			victim = e
			break
	_check(victim != null, "есть тварь рейда для проверки убийства")
	if victim != null:
		var before_progress := int(q.get("progress", 0))
		victim.died.emit(victim)
		_check(int(q.get("progress", 0)) == before_progress + 1,
			"убийство твари рейда идёт в прогресс (%d -> %d)"
			% [before_progress, int(q.get("progress", 0))])
	# Defence, not a hunt in a field: the pack is ordered ONTO the town and looks
	# further around so it engages the guards it meets.
	# Centre of the town (centroid of its heads), not the first head's cell.
	var town_world := Vector2(12 * 32 + 16, 10 * 32 + 16)
	var ordered := 0
	var watching := 0
	var marching := 0
	for e in Game.enemies:
		if not is_instance_valid(e):
			continue
		var order: Vector2 = e.get("assault_to")
		if order != Vector2.INF and order.distance_to(town_world) < 1.0:
			ordered += 1
		if float(e.get("aggro_radius")) >= 260.0:
			watching += 1
		if e.global_position.distance_to(town_world) > 48.0:
			e.call("_march_to", 0.1)
			if (e as CharacterBody2D).velocity.length() > 1.0:
				marching += 1
	_check(ordered == Game.enemies.size(),
		"вся стая получила приказ идти на город (%d из %d)" % [ordered, Game.enemies.size()])
	_check(watching == Game.enemies.size(),
		"стая замечает стражу на подходе (радиус ≥ 260 у %d)" % watching)
	_check(marching > 0, "стая реально шагает к городу (%d тварей в движении)" % marching)
	# Outside the walls, but still around the town: not on the doorstep (they
	# climbed out of the houses) and not across the map.
	var near_town := 0
	var too_close := 0
	for e in Game.enemies:
		if not is_instance_valid(e):
			continue
		var d: float = (e as Node2D).global_position.distance_to(town_world) / 32.0
		if d >= 8.0 and d <= 16.0:
			near_town += 1
		if d < 8.0:
			too_close += 1
	_check(near_town == Game.enemies.size(),
		"стая стоит у стен города, а не в поле и не в доме (%d из %d)"
		% [near_town, Game.enemies.size()])
	_check(too_close == 0, "никто не спавнится ближе восьми клеток от центра (%d)"
		% too_close)
	# The top-up is not an endless sink: a raid refills at most once over target.
	for e in Game.enemies:
		if is_instance_valid(e):
			e.set("state", "dying")
	q["spawned"] = 12
	_check(qs._ensure_urgent_pack(q) == 0, "бюджет спавна кончился — новых нет")
	q.erase("spawned")

	# Raid rarity: on a four-town map only 1-2 towns carry the raid, and the
	# answer is stable for the same rotation (no re-roll on panel refresh).
	var rotation := qs._rotation_index("c0t0")
	var carriers := 0
	var stable := true
	for i in range(4):
		var cid := "c%d t0" % i
		cid = cid.replace(" ", "")
		var first: bool = qs._urgent_allowed(cid, rotation)
		var second: bool = qs._urgent_allowed(cid, rotation)
		if first != second:
			stable = false
		if first:
			carriers += 1
	_check(carriers >= 1 and carriers <= qs.URGENT_OFFERS_MAX,
		"рейд получают 1-2 города из четырёх (%d)" % carriers)
	_check(stable, "набор городов с рейдом не меняется при пересчёте")
	# The raid is 4-6 beasts even at the easiest difficulty: the generic +-1
	# jitter gave three and the player called it out (20.11).
	var tpl := QuestDB.template("urgent_hunt")
	var small := false
	var big := false
	var rng := RandomNumberGenerator.new()
	for seed_value in range(1, 41):
		rng.seed = seed_value
		var n := QuestDB.urgent_count(tpl, 1, rng)
		if n < 4:
			small = true
		if n > 6:
			big = true
	_check(not small, "рейд не бывает меньше четырёх")
	_check(not big, "рейд не бывает больше шести")
	Game.enemies.clear()
	qs.active.erase(q)
	world.queue_free()
	Game.hero = null


func _map_script() -> GDScript:
	var gd := GDScript.new()
	gd.source_code = """
extends Node2D
var tile_size: int = 32
var map_width: int = 64
var map_height: int = 64

func cell_type_at(_x: int, _y: int) -> int:
	# A town is mostly roads (3): the pack must be able to stand on them.
	return 3

func city_heads() -> Dictionary:
	return {
		"c0t0": {"cells": [[10, 10], [14, 10]]},
		"c1t0": {"cells": [[30, 10]]},
		"c2t0": {"cells": [[10, 30]]},
		"c3t0": {"cells": [[30, 30]]},
	}

signal enemy_died(unit)

func watch_enemy(unit) -> void:
	unit.died.connect(func(u): enemy_died.emit(u))

func get_cities() -> Array:
	return [
		{"id": "c0t0", "x": 12, "y": 10},
		{"id": "c1t0", "x": 30, "y": 10},
		{"id": "c2t0", "x": 10, "y": 30},
		{"id": "c3t0", "x": 30, "y": 30},
	]
"""
	gd.reload()
	return gd


## A stand-in beast: only the properties the quest code reads.
func _make_enemy(set_name: String, at: Vector2) -> Node2D:
	var gd := GDScript.new()
	gd.source_code = """
extends Node2D
var anim_set: String = ""
var home_position: Vector2 = Vector2.ZERO
var state: String = "idle"
"""
	gd.reload()
	var e := Node2D.new()
	e.set_script(gd)
	e.set("anim_set", set_name)
	e.set("home_position", at)
	e.position = at
	root.add_child(e)
	return e
