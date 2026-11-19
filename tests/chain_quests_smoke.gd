extends SceneTree
## Quest chains: the engine (20.11) and the first story line "The count after
## the shift" (humans).
##
## CHECKS:
##   1. data: one chain with four stages, every stage is a valid template, the
##      next graph is a1 -> a2 -> {a3, a4} -> end;
##   2. a chain stage never enters the rotation (pick_template skips it);
##   3. the story card is offered beside the three rotation offers, only in the
##      right zone and only at a head of its race, and it never eats _next_id;
##   4. a taken stage hides itself, an abandoned one comes back with the same
##      deterministic id and is not parked in the rotation;
##   5. the SAME_TEMPLATE_LIMIT rule does not block an ordinary hunt next to a
##      chain stage;
##   6. the whole line: kills, a found item, a delivery and an elite; the chain
##      state moves on, effects are paid ONCE, the totals are the designed ones;
##   7. save: chains travel inside "quests"; an old payload without them starts
##      the line from the first stage;
##   8. panel: the story card carries the badge and the step, and the offers
##      column shows rotation + story.
##
## Run: godot --headless --path . --script res://tests/chain_quests_smoke.gd

const CITY := "c0t0"       # humans: the chain's race
const CITY2 := "c1t0"      # ork: a different race, no story line
const CHAIN := "count_after_shift"
const WorldBusClass := preload("res://scripts/world/world_bus.gd")
const WorldFeedClass := preload("res://scripts/world/world_feed.gd")
const SMOKE_SEED := 424242

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
	_test_offer(qs)
	_test_panel(qs)
	_test_template_limit(qs)
	_test_flow(qs)
	_test_save(qs)
	_report()


# --- Fixture -----------------------------------------------------------------

func _make_system() -> QuestSystem:
	var qs := QuestSystem.new()
	qs.name = "QuestSystemChain"
	root.add_child(qs)
	return qs


func _seed_world() -> void:
	var bus = _bus_ref()
	bus.state.day = 0
	Game.map_seed = SMOKE_SEED
	Game.map_zone = "start"
	Game.map_sector = ""
	Game.hero_race = "human"
	Game.pending_quests = {}
	Game.pending_quests_applied = true


func _make_fakes() -> Node:
	root.add_child(_bus())
	var node := Node.new()
	node.name = "ChainSmokeFakes"
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
	return root.get_node("WorldBus")


func _hero_script() -> GDScript:
	var gd := GDScript.new()
	gd.source_code = """
extends Node2D
var gold: int = 0
var inventory: Array = []
var free_cell: Vector2i = Vector2i.ZERO
var tile_size: int = 32
signal inventory_changed

func tile_at_cell(_cell: Vector2i) -> int:
	return 0

func is_walkable_world(_pos: Vector2) -> bool:
	return true

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
	}

func is_walkable_world(_pos: Vector2) -> bool:
	return true

func watch_enemy(_e) -> void:
	pass
"""
	gd.reload()
	return gd


func _archmage_power(race: String) -> float:
	var st = _bus_ref().state
	for fid in st.factions:
		var f: Dictionary = st.factions[fid]
		if str(f.get("race", "")) != race:
			continue
		return float((f.get("archmage", {}) as Dictionary).get("power", 0.0))
	return 0.0


# --- 1. Data -----------------------------------------------------------------

func _test_data() -> void:
	var c := QuestDB.chain(CHAIN)
	_check(not c.is_empty(), "chain %s is loaded" % CHAIN)
	_check(str(c.get("race", "")) == "humans", "the chain belongs to the humans")
	var stages: Array = c.get("stages", [])
	_check(stages.size() == 4, "the chain has four stages (%d)" % stages.size())
	var order_ok := true
	var adjacent_ok := true
	for raw in stages:
		var tpl := QuestDB.stage(CHAIN, str(raw))
		if tpl.is_empty():
			order_ok = false
			continue
		if int(tpl.get("order", 0)) < 1:
			order_ok = false
		if str(tpl.get("type", "")) == "":
			order_ok = false
	_check(order_ok, "every stage is a loaded template with an order and a type")
	var a1 := QuestDB.stage(CHAIN, "a1")
	var a2 := QuestDB.stage(CHAIN, "a2")
	var a3 := QuestDB.stage(CHAIN, "a3")
	var a4 := QuestDB.stage(CHAIN, "a4")
	adjacent_ok = (a1.get("next", []) as Array).has("a2") \
		and (a2.get("next", []) as Array).has("a3") \
		and (a2.get("next", []) as Array).has("a4") \
		and (a3.get("next", []) as Array).has("a4") \
		and (a4.get("next", []) as Array).is_empty()
	_check(adjacent_ok, "the next graph is a1 -> a2 -> {a3, a4} -> end")
	_check(QuestDB.is_chain_template("chain_cas_a1"),
		"a stage is recognised as a chain template")
	_check(not QuestDB.is_chain_template("kill_species"),
		"a rotating template is not a chain template")
	# The rotation must never hand out a stage: it would show the middle of a
	# story line as an ordinary chore.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var leaked := 0
	for _i in range(300):
		var t := QuestDB.pick_template(rng, "start", 1, 2, [])
		if str(t.get("chain", "")) != "":
			leaked += 1
	_check(leaked == 0, "the rotation never picks a chain stage (%d)" % leaked)


# --- 2. Offer ----------------------------------------------------------------

func _test_offer(qs: QuestSystem) -> void:
	var offers := qs.offers_for(CITY)
	_check(offers.size() == GameConfig.geti("quests", "offer_slots"),
		"the rotation keeps exactly offer_slots offers (%d)" % offers.size())
	var q := qs.chain_offer(CITY)
	_check(not q.is_empty(), "the human head offers the story line")
	if q.is_empty():
		return
	_check(str(q.get("id", "")) == "chain_%s_a1" % CHAIN,
		"the stage id is deterministic (%s)" % str(q.get("id", "")))
	_check(int(q.get("order", 0)) == 1, "the first stage is step 1")
	_check(int(q.get("stages_total", 0)) == 4, "the card knows the line length")
	_check(int(q.get("difficulty", 0)) == 1,
		"the stage difficulty comes from the data, not from the zone")
	_check(str(q.get("chain_id", "")) == CHAIN, "the card carries its chain id")
	var head := qs.head_offers(CITY)
	_check(head.size() == offers.size() + 1,
		"the head shows the story beside the rotation (%d + 1)" % offers.size())
	_check(not qs.chain_offer(CITY2).is_empty() == false,
		"a head of another race does not offer the humans' line")
	# The zone gate: the same line must not appear in a deep zone.
	Game.map_zone = "hard"
	_check(qs.chain_offer(CITY).is_empty(), "the line is gated to start/mid zones")
	Game.map_zone = "start"
	# Building the card must not move the quest id counter.
	var before := int(qs.to_payload().get("next_id", 0))
	for _i in range(5):
		qs.head_offers(CITY)
	var after := int(qs.to_payload().get("next_id", 0))
	_check(before == after, "rebuilding the story card does not eat next_id (%d/%d)"
		% [before, after])


# --- 3. Panel ----------------------------------------------------------------

func _test_panel(qs: QuestSystem) -> void:
	Loc.set_locale("en")
	var panel := QuestPanel.new()
	panel.name = "ChainPanelSmoke"
	root.add_child(panel)
	panel.setup(null, CITY)
	panel.call("_refresh")
	var box: Node = panel.get("_offers_box")
	_check(box != null, "the panel built its offers column")
	if box == null:
		panel.close()
		return
	_check(box.get_child_count() == qs.head_offers(CITY).size(),
		"the offers column shows rotation + story (%d cards / %d offers)"
		% [box.get_child_count(), qs.head_offers(CITY).size()])
	var chain_label := _find_label(box, "Chain")
	_check(chain_label != null, "the story card carries a badge")
	if chain_label != null:
		_check(chain_label.text.contains("Story:"),
			"the badge names the scenario (%s)" % chain_label.text.replace("\n", " / "))
		_check(chain_label.text.contains("Step 1 of 4"),
			"the badge shows the step (%s)" % chain_label.text.replace("\n", " / "))
	Loc.set_locale("ru")
	panel.close()


func _find_label(node: Node, label_name: String) -> Label:
	if node is Label and (node as Label).name == label_name:
		return node as Label
	for child in node.get_children():
		var found := _find_label(child, label_name)
		if found != null:
			return found
	return null


# --- 4. Same-template limit --------------------------------------------------

func _test_template_limit(qs: QuestSystem) -> void:
	var stage := qs.chain_offer(CITY)
	var ok := qs.accept(CITY, str(stage.get("id", "")))
	_check(ok == "", "the story stage is taken (%s)" % ok)
	var hunt := qs.debug_add_offer(CITY, "kill_species")
	var ok2 := qs.accept(CITY, str(hunt.get("id", "")))
	_check(ok2 == "", "an ordinary hunt is taken beside a chain stage (%s)" % ok2)
	qs.reset()


# --- 5. The whole line -------------------------------------------------------

func _test_flow(qs: QuestSystem) -> void:
	Loc.set_locale("en")
	var gold_before := int(Game.hero.gold)
	var rep_before := int(_bus_ref().state.hero_rep("humans"))
	var power_before := _archmage_power("humans")

	# a1: a hunt.
	var q1 := qs.chain_offer(CITY)
	var ok := qs.accept(CITY, str(q1.get("id", "")))
	_check(ok == "", "stage 1 is taken")
	_check(qs.head_offers(CITY).size() == qs.offers_for(CITY).size(),
		"a taken stage hides its card")
	var need1 := int(q1.get("need", 1))
	for _i in range(need1):
		qs.notify_killed(str(q1.get("set", "")), "")
	qs.turn_in(CITY, str(q1.get("id", "")))
	var st1: Dictionary = qs.chain_state(CHAIN)
	_check(str(st1.get("stage", "")) == "a1", "the chain remembers stage 1")
	_check(str(st1.get("state", "")) == "active", "the chain is active after stage 1")
	var q2 := qs.chain_offer(CITY)
	_check(str(q2.get("stage", "")) == "a2", "stage 2 is offered next")

	# The card must point somewhere: a found token with no map mark is an
	# impossible errand (player report 20.11).
	ok = qs.accept(CITY, str(q2.get("id", "")))
	_check(ok == "", "stage 2 is taken")
	var q2_live := qs.quest_by_id(str(q2.get("id", "")))
	var q2_cell := qs.objective_cell(q2_live)
	_check(q2_cell.x >= 0 and q2_cell == qs.json_cell(q2_live.get("target_cell", [])),
		"the found token has a map mark (%s)" % str(q2_cell))
	qs.notify_item_picked(str(q2.get("bag_key", "")))
	qs.turn_in(CITY, str(q2.get("id", "")))
	var st2: Dictionary = qs.chain_state(CHAIN)
	_check(bool((st2.get("flags", {}) as Dictionary).get("ledger_found", false)),
		"stage 2 sets the ledger_found flag")
	var q3 := qs.chain_offer(CITY)
	_check(str(q3.get("stage", "")) == "a3",
		"with two towns stage 3 is the delivery (%s)" % str(q3.get("stage", "")))

	# a3: a delivery (the item is handed out on take and taken back on turn-in).
	ok = qs.accept(CITY, str(q3.get("id", "")))
	_check(ok == "", "stage 3 is taken")
	_check(Game.hero.inventory.has(str(q3.get("issued", ""))),
		"the delivery item is in the bag on take")
	_check(qs.objective_cell(q3) == Vector2i(30, 30),
		"the delivery points at the destination town (%s)" % str(qs.objective_cell(q3)))
	qs.turn_in(CITY, str(q3.get("id", "")))
	_check(not Game.hero.inventory.has(str(q3.get("issued", ""))),
		"the delivery item leaves the bag on turn-in")
	var st3: Dictionary = qs.chain_state(CHAIN)
	_check(bool((st3.get("flags", {}) as Dictionary).get("ledger_delivered", false)),
		"stage 3 sets the ledger_delivered flag")
	var q4 := qs.chain_offer(CITY)
	_check(str(q4.get("stage", "")) == "a4", "stage 4 is the elite")

	# a4: the elite, bound to the quest id.
	ok = qs.accept(CITY, str(q4.get("id", "")))
	_check(ok == "", "stage 4 is taken")
	var q4_live := qs.quest_by_id(str(q4.get("id", "")))
	var q4_cell := qs.objective_cell(q4_live)
	_check(q4_cell.x >= 0, "the elite has a map mark (%s)" % str(q4_cell))
	# A hunt points at the DEN of the nearest pack, never at a live unit: the
	# pack leader spawned by stage 4 stands in for that den here.
	var hunt := {"type": "KILL_SPECIES", "set": str(q4.get("set", ""))}
	var den := qs.objective_cell(hunt)
	_check(den.x >= 0, "a hunt points at the nearest pack den (%s)" % str(den))
	_check(qs.objective_cell({"type": "KILL_SPECIES", "set": "monsters/nothing_t1"})
		== Vector2i(-1, -1), "an empty hunt points nowhere instead of lying")
	# Trophy tags point at an enemy camp of the rival race.
	var saved_outposts: Array = Game.outposts.duplicate()
	var saved_captured: Dictionary = Game.outposts_captured.duplicate()
	Game.outposts = [{"id": "o-chain-smoke", "faction": "ork", "name": "camp",
		"x": 7, "y": 9}]
	Game.outposts_captured = {}
	_check(qs.objective_cell({"type": "GATHER", "rival_race": "ork",
		"item_key": ""}) == Vector2i(7, 9),
		"trophy tags point at the rival camp")
	Game.outposts = saved_outposts
	Game.outposts_captured = saved_captured
	qs.notify_killed(str(q4.get("set", "")), str(q4.get("id", "")))
	qs.turn_in(CITY, str(q4.get("id", "")))
	var st4: Dictionary = qs.chain_state(CHAIN)
	_check(str(st4.get("state", "")) == "done", "the line is finished")
	_check(qs.chain_offer(CITY).is_empty(), "a finished line is not offered again")
	_check(qs.head_offers(CITY).size() == qs.offers_for(CITY).size(),
		"after the finale only the rotation is left")

	# Totals: difficulty 1/2/2/3 pays 25 + 90 + 90 + 270 gold (the reward curve
	# multiplies the base), 5 + 9 + 9 + 15 reputation, 1.52 + 5 power.
	var gold_delta := int(Game.hero.gold) - gold_before
	_check(gold_delta == 475, "the line pays 475 gold (%d)" % gold_delta)
	var rep_delta := int(_bus_ref().state.hero_rep("humans")) - rep_before
	_check(rep_delta == 38, "the line pays 38 reputation (%d)" % rep_delta)
	var power_delta := _archmage_power("humans") - power_before
	_check(absf(power_delta - 6.52) < 0.001,
		"the line adds 6.52 archmage power (%f)" % power_delta)
	_check(Game.hero.inventory.has("Post Ledger"), "the trophy is in the bag")
	var feed := ""
	for line in WorldFeedClass.tail(20):
		feed += str((line as Dictionary).get("text", "")) + "\n"
	_check(feed.contains("Masha"), "the archmage speaks in the world feed")

	# Effects are paid once: a second call must change nothing.
	var history_dict: Dictionary = qs.history[qs.history.size() - 1]
	var gold_mid := int(Game.hero.gold)
	qs._apply_effects(history_dict)
	qs._apply_effects(history_dict)
	_check(int(Game.hero.gold) == gold_mid,
		"a repeated effect pass pays no gold")
	_check(absf(_archmage_power("humans") - (power_before + 6.52)) < 0.001,
		"a repeated effect pass adds no power")


# --- 6. Save -----------------------------------------------------------------

func _test_save(qs: QuestSystem) -> void:
	var payload := qs.to_payload()
	var saved: Variant = payload.get("chains", null)
	_check(saved is Dictionary and not (saved as Dictionary).is_empty(),
		"chains travel inside the quests payload")
	qs.reset()
	_check(qs.chain_state(CHAIN).is_empty(), "reset clears the chains")
	qs.apply_payload(payload)
	_check(str(qs.chain_state(CHAIN).get("state", "")) == "done",
		"a finished line stays finished after a load")
	_check(qs.chain_offer(CITY).is_empty(), "a loaded finished line is not reoffered")

	# An old slot: no "chains" key at all. The line starts from stage 1.
	qs.reset()
	qs.apply_payload({"seed": SMOKE_SEED, "zone": "start", "sector": "",
		"offers": {}, "active": [], "history": [], "next_id": 1})
	_check(qs.chain_state(CHAIN).is_empty(), "an old payload leaves no chain state")
	var q := qs.chain_offer(CITY)
	_check(str(q.get("stage", "")) == "a1",
		"an old payload starts the line from stage 1")


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
		print("RESULT: OK chain_quests_smoke")
	else:
		print("RESULT: FAIL chain_quests_smoke (%d)" % _fails.size())
		for f in _fails:
			print("  - ", f)
	_done = true
	quit(0 if _fails.is_empty() else 1)
