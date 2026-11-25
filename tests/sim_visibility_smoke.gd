# ============================================================================
# TEST: SIM visibility bridge (26.11).
#
# Covers the data the world map reads and the hero -> SIM damage path:
#   1. frontier tension creates a real SIM clash between garrisons in one sector;
#   2. the temporary relation is restored on the next tick (no permanent war);
#   3. killing faction soldiers in the tactical map weakens their SIM army;
#   4. world-map helpers report the same clash and contested state.
#
# Run: godot --headless --path . --script res://tests/sim_visibility_smoke.gd
# ============================================================================
extends SceneTree

const WorldStateSc := preload("res://scripts/world/world_state.gd")
const WorldSimSc := preload("res://scripts/world/world_sim.gd")

var _checks := 0
var _fails: Array[String] = []


func _initialize() -> void:
	_test_frontier_clash()
	_test_temporary_relation()
	_test_hero_damages_army()
	_test_world_map_helpers()
	_test_teleport_filter()
	_report()


func _new_world_with_sector() -> Dictionary:
	var w = WorldStateSc.new()
	var a = w.new_faction("Alliance", "humans")
	var b = w.new_faction("Horde", "ork")
	w.sectors["s41"] = {"col": 0, "row": 0, "owner": "humans"}
	var x = w.new_army(a.id, Vector2(1, 1))
	var y = w.new_army(b.id, Vector2(2, 2))
	x["sector_id"] = "s41"
	y["sector_id"] = "s41"
	x["power"] = 10
	y["power"] = 10
	return {"state": w, "a": a, "b": b, "x": x, "y": y}


func _has_journal_kind(w, kind: String) -> bool:
	for entry in w.journal:
		if str((entry as Dictionary).get("kind", "")) == kind:
			return true
	return false


func _test_frontier_clash() -> void:
	var pack := _new_world_with_sector()
	var w = pack["state"]
	w.day = 3
	var sim = WorldSimSc.new(w)
	var ticks := 0
	while w.armies.size() > 0 and ticks < 40:
		sim.TickArmies()
		ticks += 1
	_check(w.armies.is_empty(), "frontier garrisons actually fight (%d ticks)" % ticks)
	_check(_has_journal_kind(w, "battle"), "frontier clash is written to the world journal")


func _test_temporary_relation() -> void:
	var pack := _new_world_with_sector()
	var w = pack["state"]
	var a: Dictionary = pack["a"]
	var b: Dictionary = pack["b"]
	var key := "%s:%s" % [a.id, b.id]
	var back := "%s:%s" % [b.id, a.id]
	w.day = 3
	var sim = WorldSimSc.new(w)
	sim.TickArmies()
	_check(int(w.relations.get(key, 0)) < 0, "frontier relation is hostile during the clash")
	w.day = 4
	sim.TickArmies()
	_check(int(w.relations.get(key, 0)) == 0 and int(w.relations.get(back, 0)) == 0,
		"frontier relation is restored on the next day")


func _test_hero_damages_army() -> void:
	var w = WorldStateSc.new()
	var f = w.new_faction("Circle", "druid")
	var army = w.new_army(f.id, Vector2(3, 3))
	army["sector_id"] = "s41"
	army["power"] = 5
	var sim = WorldSimSc.new(w)
	_check(sim.damage_army("druid", "s41", 2), "druid army found by hero race")
	_check(int(army.get("power", -1)) == 3, "hero kill removes army power (5 -> 3)")
	_check(sim.damage_army("druid", "s41", 9), "second attack accepted")
	_check(w.armies.is_empty(), "army with zero power is erased")
	_check(_has_journal_kind(w, "battle"), "hero attack is visible in the world journal")
	_check(not sim.damage_army("necro", "s41", 1), "unknown faction is rejected")


func _test_world_map_helpers() -> void:
	var script: GDScript = load("res://scripts/world_map_panel.gd")
	var pack := _new_world_with_sector()
	var w = pack["state"]
	var x: Dictionary = pack["x"]
	var y: Dictionary = pack["y"]
	x["enemy_id"] = y.id
	y["enemy_id"] = x.id
	var info: Dictionary = script.clash_info(w, "s41")
	_check(info.size() == 2, "world map sees both sides of the clash")
	_check(script.is_contested(w, "s41"), "clashing sector reads as contested")
	_check(script.territory_color(w, "s41") == Lore.faction_color("humans"),
		"territory colour comes from the sector owner")
	var w2 = WorldStateSc.new()
	w2.sectors["s11"] = {"owner": ""}
	_check(script.is_contested(w2, "s11"), "sector without an owner reads as contested")
	w2.sectors["s11"]["owner"] = "druid"
	_check(not script.is_contested(w2, "s11"), "settled sector without outposts is calm")


func _test_teleport_filter() -> void:
	var script: GDScript = load("res://scripts/teleport_panel.gd")
	var rec := {"sector": "s21", "name": "North"}
	_check(script.city_in_sector(rec, "s21"), "city of the requested sector is kept")
	_check(not script.city_in_sector(rec, "s41"), "city of another sector is hidden")
	_check(script.city_in_sector(rec, ""), "empty filter keeps every city")


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if ok:
		print("  OK   ", label)
	else:
		_fails.append(label)
		print("  FAIL ", label)


func _report() -> void:
	print("---")
	if _fails.is_empty():
		print("RESULT: OK sim_visibility_smoke (%d checks)" % _checks)
		quit(0)
	else:
		print("RESULT: FAIL sim_visibility_smoke (%d checks, %d fails)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - ", f)
		quit(1)
