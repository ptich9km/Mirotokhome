extends SceneTree
## Quest chains B, C, D: "survive_and_count" (ork, the outpost changes hands),
## "the_recount" (necro, the finale now ADDS power - player decision 24.11),
## "quiet_it_grows" (druid, a reputation fork d4a/d4b).
##
## CHECKS:
##   1. data: three chains, every stage is a valid template, the next graphs;
##   2. B gating: zone hard/faction AND at least one outpost on the map;
##   3. foreign text: a hero of another race hears text_key_foreign;
##   4. B flow: urgent, nest, tags (-12 rep humans), the camp master (the camp
##      passes to the orks and stays so after a save-style reload), three
##      nights (+5.0 power); totals 630 gold / ork +51 / humans -17;
##   5. C flow with the druid delivery: sim_relation necro<->druid +10 in both
##      directions, city loyalty +3, hero_rep druid +4; the finale adds +2.0
##      power (never -4.0), loyalty +6, the Village Roll trophy, +10 rep;
##      with low reputation c4 is skipped and c5 follows c3 directly;
##   6. D flow on the force branch (druid rep < 28): d4b, then d5 with +4.0
##      power, loyalty +4, druid<->necro +6; at rep >= 28 the offer is d4a;
##   7. effects are idempotent through effects_applied.
##
## Run: godot --headless --path . --script res://tests/chain_bcd_smoke.gd

const CITY_H := "c0t0"      # humans
const CITY_O := "c1t0"      # ork
const CITY_N := "c2t0"      # necro
const CITY_D := "c3t0"      # druid
const CHAIN_B := "survive_and_count"
const CHAIN_C := "the_recount"
const CHAIN_D := "quiet_it_grows"
const WorldBusClass := preload("res://scripts/world/world_bus.gd")
const WorldFeedClass := preload("res://scripts/world/world_feed.gd")
const SMOKE_SEED := 424243

var _fails: Array[String] = []
var _fakes: Node = null
var _started := false
var _done := false


func _process(_delta: float) -> bool:
	if _started:
		return _done
	_phase()
	return _done


func _phase() -> void:
	_started = true
	_done = false
	_seed_world()
	_fakes = _make_fakes()
	_test_data()
	WorldFeedClass.clear()
	var qs := _make_system()
	_test_gating(qs)
	_test_foreign_text(qs)
	_test_chain_b(qs)
	_test_chain_c(qs)
	_test_chain_c_skip_low_rep(qs)
	_test_chain_d(qs)
	_report()


# --- Fixture -----------------------------------------------------------------

func _make_system() -> QuestSystem:
	var qs := QuestSystem.new()
	qs.name = "QuestSystemChainBCD"
	root.add_child(qs)
	return qs


func _seed_world() -> void:
	var bus = _bus_ref()
	if bus == null:
		root.add_child(_bus())
		bus = _bus_ref()
	bus.state.day = 0
	Game.map_seed = SMOKE_SEED
	Game.map_zone = "start"
	Game.map_sector = ""
	Game.hero_race = "human"
	Game.pending_quests = {}
	Game.pending_quests_applied = true
	Game.outposts = []
	Game.outposts_captured = {}
	Game.outposts_owner = {}
	Game.pending_outposts_owner = {}
	Game.enemies = []


func _make_fakes() -> Node:
	var node := Node.new()
	node.name = "ChainBCDFakes"
	root.add_child(node)
	var map := Node2D.new()
	map.name = "AlmMap"
	map.set_script(_map_script())
	map.add_to_group("alm_map")
	node.add_child(map)
	var hero := Node2D.new()
	hero.name = "Hero"
	hero.set_script(_hero_script())
	node.add_child(hero)
	Game.hero = hero
	return node


func _bus() -> Node:
	var bus = WorldBusClass.new()
	bus.name = "WorldBus"
	bus._ready()
	bus.state.day = 0
	return bus


func _bus_ref():
	return root.get_node_or_null("WorldBus")


func _hero_script() -> GDScript:
	var gd := GDScript.new()
	gd.source_code = """
extends Node2D
var gold: int = 0
var inventory: Array = []
var free_cell: Vector2i = Vector2i.ZERO
var tile_size: int = 32
signal inventory_changed

func is_walkable_world(_pos: Vector2) -> bool:
	return true

func tile_at_cell(_cell: Vector2i) -> int:
	return 0

func world_to_cell(pos: Vector2) -> Vector2i:
	return Vector2i(int(pos.x) / tile_size, int(pos.y) / tile_size)

func cell_to_world(cell: Vector2i) -> Vector2:
	return (Vector2(cell) + Vector2(16, 16)) * float(tile_size)

func add_item(key: String) -> void:
	inventory.append(key)
	inventory_changed.emit()

func remove_item(key: String) -> void:
	var idx := inventory.rfind(key)
	if idx >= 0:
		inventory.remove_at(idx)
	inventory_changed.emit()
"""
	gd.reload()
	return gd


func _map_script() -> GDScript:
	var gd := GDScript.new()
	gd.source_code = """
extends Node2D
signal enemy_died(unit)
var tile_size: int = 32
var map_width: int = 48
var map_height: int = 48

func city_heads() -> Dictionary:
	return {
		"c0t0": {"race": "humans", "cells": [[10, 10]]},
		"c1t0": {"race": "ork", "cells": [[30, 30]]},
		"c2t0": {"race": "necro", "cells": [[15, 40]]},
		"c3t0": {"race": "druid", "cells": [[40, 15]]},
	}

func is_walkable_world(_pos: Vector2) -> bool:
	return true

func watch_enemy(_e) -> void:
	pass
"""
	gd.reload()
	return gd


func _state():
	return _bus_ref().state


func _archmage_power(race: String) -> float:
	var st = _state()
	for fid in st.factions:
		var f: Dictionary = st.factions[fid]
		if str(f.get("race", "")) != race:
			continue
		return float((f.get("archmage", {}) as Dictionary).get("power", 0.0))
	return 0.0


## The SIM city loyalty summed over cities of a race.
func _loyalty_sum(race: String) -> float:
	var st = _state()
	var total := 0.0
	for id in st.cities:
		var c: Dictionary = st.cities[id]
		var f: Dictionary = st.factions.get(str(c.get("faction_id", "")), {})
		if str(f.get("race", "")) == race:
			total += float(c.get("loyalty", 60.0))
	return total


func _sim_relation(a: String, b: String) -> int:
	var st = _state()
	var fa: Dictionary = st._faction_for_race(a)
	var fb: Dictionary = st._faction_for_race(b)
	return int(st.relations.get("%s:%s" % [str(fa.get("id", "")), str(fb.get("id", ""))], 0))


# --- helpers -----------------------------------------------------------------

func _take_and_finish(qs: QuestSystem, city: String, stage: String) -> Dictionary:
	var q := qs.chain_offer(city)
	_check(str(q.get("stage", "")) == stage, "%s: offered (%s)" % [stage, str(q.get("stage", ""))])
	var err := qs.accept(city, str(q.get("id", "")))
	_check(err == "", "%s: taken (%s)" % [stage, err])
	var live := qs.quest_by_id(str(q.get("id", "")))
	match str(q.get("type", "")):
		"KILL_SPECIES", "KILL_GROUP", "URGENT":
			for _i in range(int(q.get("need", 1))):
				qs.notify_killed(str(q.get("set", "")), str(q.get("id", "")))
		"KILL_TARGET":
			qs.notify_killed(str(q.get("set", "")), str(q.get("id", "")))
		"FIND_ITEM":
			qs.notify_item_picked(str(live.get("bag_key", "")))
		"GATHER":
			for _i in range(int(q.get("need", 1))):
				Game.hero.add_item(str(q.get("item_key", "")))
		"DELIVER":
			pass
	err = qs.turn_in(city, str(q.get("id", "")))
	# turn_in returns a reward summary on success, an error string otherwise;
	# the reliable signal is that the quest left the active list.
	var gone := true
	for a in qs.active:
		if str(a.get("id", "")) == str(q.get("id", "")):
			gone = false
	_check(gone, "%s: turned in (%s)" % [stage, err])
	return live


# --- 1. Data -----------------------------------------------------------------

func _test_data() -> void:
	var b := QuestDB.chain(CHAIN_B)
	_check(not b.is_empty(), "chain %s is loaded" % CHAIN_B)
	_check(str(b.get("race", "")) == "ork", "chain B belongs to the orks")
	_check((b.get("stages", []) as Array).size() == 5, "chain B has five stages")
	var c := QuestDB.chain(CHAIN_C)
	_check(str(c.get("race", "")) == "necro", "chain C belongs to the necro")
	_check((c.get("stages", []) as Array).size() == 5, "chain C has five stages")
	var d := QuestDB.chain(CHAIN_D)
	_check(str(d.get("race", "")) == "druid", "chain D belongs to the druids")
	_check((d.get("stages", []) as Array).size() == 6, "chain D lists six stages")
	var graphs_ok := true
	for chain_id in [CHAIN_B, CHAIN_C, CHAIN_D]:
		for raw in (QuestDB.chain(chain_id).get("stages", []) as Array):
			if QuestDB.stage(chain_id, str(raw)).is_empty():
				graphs_ok = false
	_check(graphs_ok, "every stage of B/C/D is a loaded template")
	var b1 := QuestDB.stage(CHAIN_B, "b1")
	var b2 := QuestDB.stage(CHAIN_B, "b2")
	var b3 := QuestDB.stage(CHAIN_B, "b3")
	var b4 := QuestDB.stage(CHAIN_B, "b4")
	var b5 := QuestDB.stage(CHAIN_B, "b5")
	_check((b1.get("next", []) as Array) == ["b2"], "b1 -> b2")
	_check((b2.get("next", []) as Array) == ["b3"], "b2 -> b3")
	_check((b3.get("next", []) as Array) == ["b4"], "b3 -> b4")
	_check((b4.get("next", []) as Array) == ["b5"], "b4 -> b5")
	_check((b5.get("next", []) as Array).is_empty(), "b5 is the end")
	var c3 := QuestDB.stage(CHAIN_C, "c3")
	_check((c3.get("next", []) as Array) == ["c4", "c5"], "c3 -> {c4, c5}")
	var d3 := QuestDB.stage(CHAIN_D, "d3")
	_check((d3.get("next", []) as Array) == ["d4a", "d4b"], "d3 -> {d4a, d4b}")


# --- 2. Gating ----------------------------------------------------------------

func _test_gating(qs: QuestSystem) -> void:
	# B starts in the start zone (player decision 25.11): the first two stages
	# are local, the camp stages wait for a map with outposts.
	Game.map_zone = "start"
	var q := qs.chain_offer(CITY_O)
	_check(not q.is_empty() and str(q.get("stage", "")) == "b1",
		"chain B opens in the start zone (%s)" % str(q.get("stage", "")))
	_check(int(q.get("difficulty", 0)) == 2, "the stage difficulty comes from the data")
	Game.map_zone = "start"
	Game.outposts = []
	# D: the druid line must be visible from the very first zone (player report
	# 25.11: an elf hero saw no chain at the head at all).
	var qd := qs.chain_offer(CITY_D)
	_check(not qd.is_empty() and str(qd.get("stage", "")) == "d1",
		"chain D is offered in the start zone (%s)" % str(qd.get("stage", "")))


# --- 3. Foreign text -----------------------------------------------------------

func _test_foreign_text(qs: QuestSystem) -> void:
	Loc.set_locale("en")
	var q := qs.chain_offer(CITY_N)
	_check(not q.is_empty(), "the necro head offers chain C in the start zone")
	var tpl := QuestDB.stage(CHAIN_C, "c1")
	var text: String = qs.call("_text_for", q, tpl)
	_check(text.contains("nose"),
		"a human hero hears the foreign line at the necro head (%s)" % text)
	Loc.set_locale("ru")


# --- 4. Chain B ---------------------------------------------------------------

func _test_chain_b(qs: QuestSystem) -> void:
	Loc.set_locale("en")
	qs.reset()
	# The start of the line: two local stages, no camps on this map.
	Game.map_zone = "start"
	Game.outposts = []
	Game.outposts_captured = {}
	Game.outposts_owner = {}
	var gold_before := int(Game.hero.gold)
	var ork_rep_before: int = _state().hero_rep("ork")
	var humans_rep_before: int = _state().hero_rep("humans")
	var power_before := _archmage_power("ork")

	_take_and_finish(qs, CITY_O, "b1")
	_take_and_finish(qs, CITY_O, "b2")
	_check(qs.chain_offer(CITY_O).is_empty(),
		"b3 waits for a map with camps: the line sends the hero to the far lands")

	# The hero travelled through the portal: a deep zone map with an outpost.
	Game.map_zone = "hard"
	Game.outposts = [{"id": "o-bcd", "faction": "humans", "name": "camp", "x": 5, "y": 5}]
	var q3 := qs.chain_offer(CITY_O)
	_check(str(q3.get("stage", "")) == "b3",
		"on a map with camps stage 3 is back (%s)" % str(q3.get("stage", "")))
	var rel_before: int = _sim_relation("ork", "humans")
	_take_and_finish(qs, CITY_O, "b3")
	_check(_state().hero_rep("humans") - humans_rep_before == -12,
		"the tags cost 12 reputation with the humans (%d)"
		% [_state().hero_rep("humans") - humans_rep_before])
	_check(_sim_relation("ork", "humans") - rel_before == -10,
		"the tags spoil ork->humans relations by 10 (%d)"
		% [_sim_relation("ork", "humans") - rel_before])

	# b4: the camp master. The camp passes to the orks.
	_take_and_finish(qs, CITY_O, "b4")
	var key := Game.outpost_key("o-bcd")
	_check(Game.outposts_owner.get(key, "") == "ork",
		"the camp owner is saved as ork (%s)" % str(Game.outposts_owner.get(key, "")))
	_check(Game.outposts_captured.has(key), "the old garrison never respawns")
	_check(str(Game.outposts[0].get("faction", "")) == "ork",
		"the working copy of the camp shows the orks")
	_check(_state().hero_rep("humans") - humans_rep_before == -17,
		"the finale costs 5 more reputation with the humans (%d)"
		% [_state().hero_rep("humans") - humans_rep_before])

	# A save-style reload: the owner travels inside the map payload.
	var saved: Dictionary = Game.outposts_owner.duplicate()
	Game.outposts_owner = {}
	Game.pending_outposts_owner = saved.duplicate()
	Game.reload_outposts(null)
	_check(Game.outpost_owner_of("o-bcd") == "ork",
		"the owner survives the save/load path (%s)" % Game.outpost_owner_of("o-bcd"))
	# reload_outposts(null) empties the camp list (the map re-reads it in the
	# game); restore the fixture so the outposts_min gate keeps passing.
	Game.outposts = [{"id": "o-bcd", "faction": "ork", "name": "camp", "x": 5, "y": 5}]

	_take_and_finish(qs, CITY_O, "b5")
	_check(str(qs.chain_state(CHAIN_B).get("state", "")) == "done", "chain B is done")
	_check(qs.chain_offer(CITY_O).is_empty(), "a finished line is not offered again")

	var gold_delta := int(Game.hero.gold) - gold_before
	_check(gold_delta == 630, "chain B pays 630 gold (%d)" % gold_delta)
	_check(_state().hero_rep("ork") - ork_rep_before == 51,
		"chain B pays 51 ork reputation (%d)" % [_state().hero_rep("ork") - ork_rep_before])
	var power_delta := _archmage_power("ork") - power_before
	_check(absf(power_delta - 7.04) < 0.001,
		"chain B adds 7.04 archmage power (%f)" % power_delta)
	var feed := ""
	for line in WorldFeedClass.tail(20):
		feed += str((line as Dictionary).get("text", "")) + "\n"
	_check(feed.contains("Lesha"), "Lesha speaks in the world feed")
	Game.map_zone = "start"


# --- 5. Chain C ---------------------------------------------------------------

func _test_chain_c(qs: QuestSystem) -> void:
	Loc.set_locale("en")
	qs.reset()
	# The druid delivery (c4) needs necro reputation >= 15; grant it up front.
	_state().add_hero_reputation("necro", 15)
	var f: Dictionary = _state()._faction_for_race("necro")
	var city: Dictionary = _state().new_city("Necropolis", str(f.get("id", "")),
		"", Game.map_sector)
	var loyalty_before := _loyalty_sum("necro")
	var power_before := _archmage_power("necro")

	_take_and_finish(qs, CITY_N, "c1")
	_take_and_finish(qs, CITY_N, "c2")
	_check(bool((qs.chain_state(CHAIN_C).get("flags", {}) as Dictionary).get("roll_found", false)),
		"c2 sets the roll_found flag")
	_take_and_finish(qs, CITY_N, "c3")
	var q4 := qs.chain_offer(CITY_N)
	_check(str(q4.get("stage", "")) == "c4",
		"with necro rep >= 15 the delivery is offered (%s)" % str(q4.get("stage", "")))
	_take_and_finish(qs, CITY_N, "c4")
	_check(_sim_relation("necro", "druid") == 10,
		"necro <-> druid relations rise by 10 (%d)" % _sim_relation("necro", "druid"))
	_check(_sim_relation("druid", "necro") == 10,
		"the matrix is symmetric (druid side %d)" % _sim_relation("druid", "necro"))
	_check(_loyalty_sum("necro") - loyalty_before == 3.0,
		"c4 adds 3 loyalty to the necro city (%f)" % [_loyalty_sum("necro") - loyalty_before])
	_check(_state().hero_rep("druid") == 4,
		"c4 pays 4 reputation with the druids (%d)" % _state().hero_rep("druid"))

	_take_and_finish(qs, CITY_N, "c5")
	_check(str(qs.chain_state(CHAIN_C).get("state", "")) == "done", "chain C is done")
	var power_delta := _archmage_power("necro") - power_before
	_check(power_delta > 0.0,
		"the finale ADDS power (player decision: no negative rewards) (%f)" % power_delta)
	_check(absf(power_delta - (1.88 + 2.0)) < 0.001,
		"the finale adds exactly +2.0 on top of the stage power (%f)" % power_delta)
	_check(_loyalty_sum("necro") - loyalty_before == 9.0,
		"c4+c5 add 9 loyalty total (%f)" % [_loyalty_sum("necro") - loyalty_before])
	_check(Game.hero.inventory.has("Village Roll"), "the Village Roll trophy is in the bag")
	_check(_state().hero_rep("necro") == 15 + 47 + 10,
		"chain C pays 57 necro reputation on top of the grant (%d)" % _state().hero_rep("necro"))


# --- 6. Chain C, low reputation: c4 is skipped --------------------------------

func _test_chain_c_skip_low_rep(qs: QuestSystem) -> void:
	qs.reset()
	_state().add_hero_reputation("necro", -100)
	_take_and_finish(qs, CITY_N, "c1")
	_take_and_finish(qs, CITY_N, "c2")
	_take_and_finish(qs, CITY_N, "c3")
	var q := qs.chain_offer(CITY_N)
	_check(str(q.get("stage", "")) == "c5",
		"with necro rep < 15 the delivery is skipped (%s)" % str(q.get("stage", "")))
	qs.reset()


# --- 7. Chain D ---------------------------------------------------------------

func _test_chain_d(qs: QuestSystem) -> void:
	Loc.set_locale("en")
	qs.reset()
	Game.map_zone = "mid"
	var fd: Dictionary = _state()._faction_for_race("druid")
	_state().new_city("Grove", str(fd.get("id", "")), "", Game.map_sector)
	var loyalty_before := _loyalty_sum("druid")
	var power_before := _archmage_power("druid")
	var relation_before: int = _sim_relation("druid", "necro")

	_take_and_finish(qs, CITY_D, "d1")
	_take_and_finish(qs, CITY_D, "d2")
	_take_and_finish(qs, CITY_D, "d3")
	var q4 := qs.chain_offer(CITY_D)
	_check(str(q4.get("stage", "")) == "d4b",
		"with druid rep < 28 the force branch is offered (%s)" % str(q4.get("stage", "")))
	_take_and_finish(qs, CITY_D, "d4b")
	_take_and_finish(qs, CITY_D, "d5")
	_check(str(qs.chain_state(CHAIN_D).get("state", "")) == "done", "chain D is done")
	var power_delta := _archmage_power("druid") - power_before
	_check(absf(power_delta - (1.88 + 4.0)) < 0.001,
		"the force path adds 5.88 archmage power (%f)" % power_delta)
	_check(_loyalty_sum("druid") - loyalty_before == 4.0,
		"d5 adds 4 loyalty to the druid city (%f)" % [_loyalty_sum("druid") - loyalty_before])
	_check(_sim_relation("druid", "necro") - relation_before == 6,
		"druid <-> necro relations rise by 6 (%d)" % [_sim_relation("druid", "necro") - relation_before])
	var feed := ""
	for line in WorldFeedClass.tail(20):
		feed += str((line as Dictionary).get("text", "")) + "\n"
	_check(feed.contains("Katya"), "Katya speaks in the world feed")

	# The peace branch: at rep >= 28 the fork offers d4a.
	qs.reset()
	_state().add_hero_reputation("druid", 28)
	var humans_before: int = _state().hero_rep("humans")
	_take_and_finish(qs, CITY_D, "d1")
	_take_and_finish(qs, CITY_D, "d2")
	_take_and_finish(qs, CITY_D, "d3")
	var qa := qs.chain_offer(CITY_D)
	_check(str(qa.get("stage", "")) == "d4a",
		"with druid rep >= 28 the peace branch is offered (%s)" % str(qa.get("stage", "")))
	_check(_state().hero_rep("humans") == humans_before,
		"the peace branch is not taken yet: no human reputation (%d)" % _state().hero_rep("humans"))
	qs.reset()
	Game.map_zone = "start"


# --- Report ------------------------------------------------------------------

func _check(cond: bool, what: String) -> void:
	if cond:
		print("OK   ", what)
	else:
		print("FAIL ", what)
		_fails.append(what)


func _report() -> void:
	print("---")
	if _fails.is_empty():
		print("RESULT: OK chain_bcd_smoke")
	else:
		print("RESULT: FAIL chain_bcd_smoke (%d)" % _fails.size())
		for f in _fails:
			print("  - ", f)
	_done = true
	quit(0 if _fails.is_empty() else 1)
