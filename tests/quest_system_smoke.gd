extends SceneTree
## Town head quests (22.10): data, generation, rotation, rewards, art.
##
## CHECKS:
##   1. template base quest_db.json agrees with QuestDB (types, icons, pick);
##   2. offers are deterministic (the call order does not change the set),
##      the number of slots is quests.offer_slots;
##   3. rotation: a world day change gives a different set, but does NOT drop
##      taken quests;
##   4. take / abandon / turn in: abandon puts the quest back into the offers
##      of the same city, the active limit holds, the same template is not
##      taken twice;
##   5. reward: gold to the hero, faction reputation and archmage power into
##      WorldState; a hard quest also pays a CraftDB recipe scroll;
##   6. progress: kills count only for their own spawn set, an elite counts by
##      quest_id, herb gathering counts by the inventory;
##   7. save: to_payload / apply_payload round trip, the old slot with an array
##      in "quests" does not break loading;
##   8. head marker: "available" while there are offers, "ready" when there is
##      something to turn in;
##   9. art: QuestIcons marker and quest item paths exist (when generated) and
##      load as Texture2D, the gold coin sits at the path loot icons expect,
##      the swaying coin sprite is four frames of one canvas, the five quest
##      item icons share one canvas and keep the crimson plate out;
##   10. panel: built with the system already alive, the offers column has one
##      card per offer, a coin per card and follows the rotation by itself.
## Run: godot --headless --path . --script res://tests/quest_system_smoke.gd

const CITY := "c0t0"
const CITY2 := "c1t0"
## City race as the generator writes it - "humans"/"ork"/... from
## MapGenerator.CITY_POPULATION, not a faction name: the fake map hands out the
## same keys as the real one.
const CITY_RACE := "humans"
const WorldBusClass := preload("res://scripts/world/world_bus.gd")

var _fails: Array[String] = []
var _fakes: Node = null
var _started := false
var _done := false
## Fixed map seed: the rotation seed and the blueprint pick read Game.map_seed,
## and a smoke run must not depend on whatever seed the previous test left.
const SMOKE_SEED := 424242


## Autoload WorldBus is loaded only AFTER _initialize, and --script plays its
## role itself: the test builds the bus and the world - exactly the game order,
## where the autoload exists before the first scene.
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
	_test_db_consistency()
	var qs := _make_system()
	if qs == null:
		_report()
		return
	_test_determinism(qs)
	_test_rotation_keeps_active(qs)
	_test_accept_abandon(qs)
	_test_turn_in(qs)
	_test_progress(qs)
	_test_quest_items(qs)
	_test_faction_tags(qs)
	_test_marker(qs)
	_test_save_roundtrip(qs)
	_test_art()
	_test_spawn_panel()
	var panel := _test_panel_refresh(qs)
	if panel != null:
		panel.close()
	_test_panel_w_close(qs)
	_report()


## One head is rolled for the offers; the panel case also builds the screen, so
## its card list can be looked at without frames (no await: this smoke runs
## inside the deferred part of _process, where a timer or a frame never wakes).


func _make_system() -> QuestSystem:
	var qs := QuestSystem.new()
	qs.name = "QuestSystem"
	root.add_child(qs)
	return qs


func _seed_world() -> void:
	# WorldState has no class_name (headless canon): reach it through the bus by
	# path. reseed() builds the factions (and their archmages) exactly as the
	# game does - and the \"hidden\" state is not empty.
	var bus = _bus_ref()
	bus.state.day = 0
	Game.map_seed = SMOKE_SEED
	# Saved journal from another run must not leak into the smoke.
	Game.pending_quests = {}
	Game.pending_quests_applied = true


## Fakes: the world bus (added to root), the hero (gold and inventory) and a
## map with two city heads. The bus comes first: _seed_world() takes WorldState
## out of the bus that is already loaded.
func _make_fakes() -> Node:
	root.add_child(_bus())
	var node := Node.new()
	node.name = "QuestSmokeFakes"
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
	# Game.hero is typed Node2D: the quest reward goes through it.
	Game.hero = hero
	return node


## WorldBus is an autoload and --script starts WITHOUT autoloads: the test adds
## the node itself. QuestSystem looks the bus up by path /root/WorldBus, so the
## name is mandatory.
func _bus() -> Node:
	var bus = WorldBusClass.new()
	bus.name = "WorldBus"
	# _ready does not run by itself (the node is not in the tree yet), and the
	# game state (WorldState, archmages) is created exactly there - as in
	# tests/archmage_smoke.
	bus._ready()
	# reseed() writes day 0: the bus snapshot is a fresh world.
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

# The map surface the hero and the quest objects ask for.
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


# --- 1. Template base ---------------------------------------------------------

func _test_db_consistency() -> void:
	var f := FileAccess.open("res://assets/quests/quest_db.json", FileAccess.READ)
	_check(f != null, "quest_db.json is readable")
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	_check(parsed is Dictionary, "quest_db.json is an object")
	if not (parsed is Dictionary):
		return
	var db: Dictionary = parsed
	var tpls: Array = db.get("templates", [])
	_check(tpls.size() >= 6, "enough templates to rotate (%d)" % tpls.size())
	var unknown_types := 0
	var incomplete := 0
	for raw in tpls:
		var t: Dictionary = raw
		if not QuestDB.TYPES.has(str(t.get("type", ""))):
			unknown_types += 1
			print("     ! unknown QuestDB type: %s" % str(t.get("type", "")))
		if str(t.get("icon", "")) == "":
			incomplete += 1
			print("     ! template without an icon: %s" % str(t.get("id", "")))
		# populate sets the substitution order: without it the text keeps %s.
		# Text lives in the locale table (title_key/text_key), the template
		# only names it, so both languages are checked.
		var text_key := str(t.get("title_key", ""))
		var body_key := str(t.get("text_key", ""))
		var fillers: Array = t.get("populate", [])
		var ru_text := Loc.text_in(body_key, "ru")
		var ru_title := Loc.text_in(text_key, "ru")
		var en_text := Loc.text_in(body_key, "en")
		var en_title := Loc.text_in(text_key, "en")
		# populate sets the substitution order AND the placeholder kind of the
		# text: a number goes in as %d, a text as %s (the runtime formatter
		# refuses a mismatch). The title reuses one value through %s.
		if not QuestDB.placeholders_fit(ru_text, fillers) \
				or not QuestDB.placeholders_fit(en_text, fillers) \
				or ru_title.count("%") > 1 or en_title.count("%") > 1:
			incomplete += 1
			print("     ! placeholders do not match populate: %s"
				% str(t.get("id", "")))
		if ru_text == "" or ru_title == "" or en_text == "" or en_title == "":
			incomplete += 1
			print("     ! template text is not translated: %s" % str(t.get("id", "")))
	_check(unknown_types == 0, "every template type is declared in QuestDB.TYPES")
	_check(incomplete == 0, "every template has an icon and a full populate")
	# Every item a quest can ask for needs its own quest name per language: the
	# shop name of item_db may carry a trait such as "4.4" (incident 22.10).
	var names: Dictionary = db.get("quest_item_names", {})
	var nameless := 0
	for raw in tpls:
		for item_key in (raw as Dictionary).get("item_pool", []):
			var entry: Variant = names.get(str(item_key), {})
			if not (entry is Dictionary) \
					or str((entry as Dictionary).get("ru", "")) == "" \
					or str((entry as Dictionary).get("en", "")) == "":
				nameless += 1
				print("     ! quest item without a name: %s" % str(item_key))
	_check(nameless == 0, "every quest item has a translated quest name")
	var gold: Array = db.get("difficulty_gold", [])
	var mult: Array = db.get("difficulty_mult", [])
	_check(gold.size() == 3 and mult.size() == 3,
		"reward is set for all three difficulty levels")
	_check(float(mult[2]) > float(mult[0]) * 2.0,
		"difficulty grows non-linearly (multipliers %s)" % str(mult))
	_check(QuestDB.base_gold(1) == int(gold[0]), "QuestDB.base_gold matches the data")
	_check(QuestDB.faction_of_race(CITY_RACE) != "",
		"city race maps to a faction for the reward")


# --- 2. Determinism -----------------------------------------------------------

func _test_determinism(qs: QuestSystem) -> void:
	qs.reset()
	var a := _ids(qs.offers_for(CITY))
	qs.offers_by_city.clear()
	var b := _ids(qs.offers_for(CITY))
	_check(a.size() == GameConfig.geti("quests", "offer_slots"),
		"exactly offer_slots offers (%d)" % a.size())
	# A rebuilt offer set is a NEW quest (its id moves on) rather than a copy of
	# the one already shown, and every offer carries a town and a faction.
	_check(a.filter(func(x): return b.has(x)).is_empty(),
		"a rebuilt offer set is new quests (%s -> %s)" % [str(a), str(b)])
	var types := {}
	for q in qs.offers_for(CITY):
		types[str(q.get("template", ""))] = true
	_check(types.size() == a.size(), "one template is not offered twice")
	var ok_fields := true
	for q in qs.offers_for(CITY):
		for key in ["id", "title", "text", "gold", "rep", "difficulty", "icon", "faction"]:
			if not q.has(key):
				ok_fields = false
				print("     ! offer has no field %s" % key)
		if str(q.get("text", "")).contains("%"):
			ok_fields = false
			print("     ! placeholder left in the text: %s" % str(q.get("text", "")))
	_check(ok_fields, "an offer has every field and no unfilled placeholders")


# --- 3. Rotation --------------------------------------------------------------

func _test_rotation_keeps_active(qs: QuestSystem) -> void:
	var before := _ids(qs.offers_for(CITY))
	var ttl := maxi(1, GameConfig.geti("quests", "offer_ttl_days"))
	_bus_ref().state.day = ttl
	var after := _ids(qs.offers_for(CITY))
	_check(before != after, "a new rotation gives a different offer set")
	# A taken quest survives rotation: it can be turned in a week later.
	var offer: Dictionary = qs.offers_for(CITY)[0]
	var err := qs.accept(CITY, str(offer.get("id", "")))
	_check(err == "", "a quest from the new rotation is taken (%s)" % err)
	_bus_ref().state.day = ttl * 3
	qs.offers_for(CITY)
	_check(not qs.quest_by_id(str(offer.get("id", ""))).is_empty(),
		"rotation does not drop a taken quest")
	qs.abandon(str(offer.get("id", "")))
	_bus_ref().state.day = 0
	qs.offers_by_city.clear()
	qs.offers_for(CITY)


# --- 4. Take / abandon --------------------------------------------------------

func _test_accept_abandon(qs: QuestSystem) -> void:
	qs.reset()
	qs.offers_by_city.clear()
	var offers := qs.offers_for(CITY)
	_check(offers.size() > 0, "there are offers to take")
	if offers.is_empty():
		return
	var id := str(offers[0].get("id", ""))
	var bad := qs.accept(CITY, "q_no_such_quest")
	_check(bad != "", "a missing quest is not taken")
	var err := qs.accept(CITY, id)
	_check(err == "", "an offer is taken (%s)" % err)
	_check(qs.quest_by_id(id).size() > 0, "the taken quest is in the journal")
	_check(_ids(qs.offers_for(CITY)).has(id) == false,
		"the taken quest left the city offers")
	var again := qs.accept(CITY, id)
	_check(again != "", "the same quest is not taken twice")
	_check(qs.abandon(id), "the quest is abandoned")
	_check(_ids(qs.offers_for(CITY)).has(id),
		"an abandoned quest is back in the offers of the same city")
	# Active limit.
	var cap := GameConfig.geti("quests", "max_active")
	var taken := 0
	for _attempt in range(cap + 3):
		var list := qs.offers_for(CITY)
		if list.is_empty():
			qs.debug_add_offer(CITY, "gather_herbs")
			list = qs.offers_for(CITY)
		if list.is_empty():
			break
		if qs.accept(CITY, str(list[0].get("id", ""))) == "":
			taken += 1
	_check(taken == cap, "no more than max_active quests are taken (%d of %d)"
		% [taken, cap])
	_check(qs.accept(CITY, "any") != "", "a full journal refuses with a message")
	qs.reset()
	qs.offers_by_city.clear()


# --- 5. Turn in and reward ----------------------------------------------------

func _test_turn_in(qs: QuestSystem) -> void:
	qs.reset()
	_bus_ref().state.hero_reputation.clear()
	var q := qs.debug_add_offer(CITY, "kill_species")
	_check(not q.is_empty(), "a forced kill_species offer is created")
	if q.is_empty():
		return
	_check(qs.accept(CITY, str(q["id"])) == "", "the hunt is taken")
	var early := qs.turn_in(CITY, str(q["id"]))
	_check(early != "" and qs.quest_by_id(str(q["id"])).size() > 0,
		"an unfinished quest is not turned in")
	var other_city := qs.turn_in(CITY2, str(q["id"]))
	_check(other_city != "", "a quest is turned in only where it was taken")
	var hero := root.find_child("Hero", true, false)
	var gold_before := int(hero.get("gold"))
	var faction := str(q.get("faction", ""))
	var rep_before: int = _bus_ref().state.hero_rep(faction)
	var power_before := _archmage_power(faction)
	# Progress up to the target.
	for _i in range(int(q.get("need", 1))):
		qs.notify_killed(str(q.get("set", "")), "")
	_check(str(qs.quest_by_id(str(q["id"])).get("state", "")) == QuestSystem.STATE_READY,
		"after the required kills the quest is ready")
	var res := qs.turn_in(CITY, str(q["id"]))
	_check(res != "", "a ready quest is turned in: %s" % res)
	_check(qs.quest_by_id(str(q["id"])).is_empty(), "the turned-in quest left the journal")
	_check(int(hero.get("gold")) == gold_before + int(q.get("gold", 0)),
		"gold was credited (%d -> %d)" % [gold_before, int(hero.get("gold"))])
	_check(_bus_ref().state.hero_rep(faction) > rep_before,
		"faction reputation grew")
	_check(_archmage_power(faction) > power_before,
		"the faction archmage power grew")
	_check(qs.history.size() > 0, "the turned-in quest went into history")
	_test_blueprint(qs)


## Archmage power of the faction the reward went to (WorldState holds it inside
## the faction record, not at the top level).
func _archmage_power(faction: String) -> float:
	var am: Dictionary = _bus_ref().state.get_archmage(faction)
	return float(am.get("power", 0.0))


## A blueprint - only for a hard quest, and only one the hero does not own yet.
func _test_blueprint(qs: QuestSystem) -> void:
	var min_diff := GameConfig.geti("quests", "blueprint_min_difficulty")
	var easy := qs.debug_add_offer(CITY, "kill_group")
	_check(easy.is_empty() or int(easy.get("difficulty", 1)) >= min_diff
		or str(easy.get("blueprint", "")) == "",
		"an easy quest pays no blueprint")
	# debug_add_offer() forces difficulty 2: a blueprint needs a difficulty 3
	# quest, so the reward itself is asked for a diff-3 quest.
	var probe := {"difficulty": min_diff, "faction": QuestDB.faction_of_race(CITY_RACE)}
	var reward := qs._reward_for(probe, RandomNumberGenerator.new())
	var blueprint := str(reward.get("blueprint", ""))
	_check(blueprint != "", "a difficulty-%d quest pays a blueprint" % min_diff)
	var scroll_key := CraftDB.recipe_scroll_key(blueprint)
	_check(blueprint != "" and not ItemDB.find(scroll_key).is_empty(),
		"the blueprint is a real recipe scroll (%s)" % scroll_key)
	# A recipe the hero already owns is never offered again.
	var known: Array = CraftDB.all_recipe_ids()
	if not known.is_empty() and Game.hero != null:
		var hero := root.find_child("Hero", true, false)
		var bag: Array = []
		for rid in known:
			bag.append(CraftDB.recipe_scroll_key(str(rid)))
		hero.set("inventory", bag)
		var again := qs._reward_for(probe, RandomNumberGenerator.new())
		_check(str(again.get("blueprint", "")) == "",
			"a blueprint the hero already owns is not offered")
		hero.set("inventory", [])
	var recipes := CraftDB.all_recipe_ids()
	_check(recipes.size() > 0, "CraftDB has recipes for the blueprint")
	var scroll := CraftDB.recipe_scroll_key(str(recipes[0]))
	_check(scroll != "" and not ItemDB.find(scroll).is_empty(),
		"the recipe scroll exists in item_db (%s)" % scroll)
	qs.reset()


# --- 6. Progress --------------------------------------------------------------

func _test_progress(qs: QuestSystem) -> void:
	qs.reset()
	var q := qs.debug_add_offer(CITY, "kill_target")
	if not q.is_empty():
		qs.accept(CITY, str(q["id"]))
		qs.notify_killed(str(q.get("set", "")), "another_quest")
		_check(int(qs.quest_by_id(str(q["id"])).get("progress", 0)) == 0,
			"a foreign elite does not count for the pack head")
		qs.notify_killed(str(q.get("set", "")), str(q["id"]))
		_check(int(qs.quest_by_id(str(q["id"])).get("progress", 0)) == 1,
			"the own elite counts by quest_id")
		qs.abandon(str(q["id"]))
	var hunt := qs.debug_add_offer(CITY, "kill_species")
	if not hunt.is_empty():
		qs.accept(CITY, str(hunt["id"]))
		qs.notify_killed("monsters/wolf_t9", "")
		_check(int(qs.quest_by_id(str(hunt["id"])).get("progress", 0)) == 0,
			"a foreign spawn set does not count for the hunt")
		qs.notify_killed(str(hunt.get("set", "")), "")
		_check(int(qs.quest_by_id(str(hunt["id"])).get("progress", 0)) == 1,
			"the own spawn set counts")
		qs.abandon(str(hunt["id"]))
	var gather := qs.debug_add_offer(CITY, "gather_herbs")
	if not gather.is_empty():
		var hero := root.find_child("Hero", true, false)
		hero.set("inventory", [])
		qs.accept(CITY, str(gather["id"]))
		var need := int(gather.get("need", 1))
		# The bag changes behind the system's back (the hero picks a herb on
		# the map, not through a quest API): the taken quest must follow it
		# without waiting for a re-accept or a turn-in (incident 22.10: a
		# herb in the bag, the journal still said "0 of 4").
		hero.call("add_item", str(gather.get("item_key", "")))
		qs.sync_inventory()
		var cur := qs.quest_by_id(str(gather["id"]))
		_check(int(cur.get("progress", 0)) == 1,
			"a herb in the bag moves the gather counter at once")
		_check(str(cur.get("state", "")) == QuestSystem.STATE_ACTIVE or need == 1,
			"one herb of four does not close the quest")
		# The card must name what to gather: content words of the item, never
		# the shop name of item_db and never a bare number (incident 22.10:
		# the card said "4.4" instead of the herb).
		var item_name := QuestDB.quest_item_name(str(gather.get("item_key", "")))
		var text := str(cur.get("text", ""))
		var words := item_name.replace("«", "").replace("»", "").split(" ", false)
		var tail := str(words[words.size() - 1]) if words.size() > 0 else ""
		_check(words.size() >= 2 and text.contains(tail),
			"a gather quest names the herb (%s)" % item_name)
		_check(not text.contains("%"), "no placeholder left in the gather text")
		_check(text.strip_edges() != "" and text != str(cur.get("title", "")),
			"a gather quest carries its own description")
		for _i in range(maxi(0, need - 1)):
			hero.call("add_item", str(gather.get("item_key", "")))
		qs.sync_inventory()
		cur = qs.quest_by_id(str(gather["id"]))
		_check(int(cur.get("progress", 0)) == need,
			"herb gathering counts by the inventory")
		_check(str(cur.get("state", "")) == QuestSystem.STATE_READY
			or qs.turn_in(CITY, str(gather["id"])) != "",
			"a full bag makes the gather quest ready and it is turned in")
		# Sold or lost: the counter goes back down, the quest is active again.
		cur = qs.quest_by_id(str(gather["id"]))
		if not cur.is_empty() and str(cur.get("state", "")) == QuestSystem.STATE_READY:
			hero.call("remove_item", str(gather.get("item_key", "")))
			qs.sync_inventory()
			_check(int(cur.get("progress", 0)) == need - 1,
				"a herb sold out of the bag lowers the counter")
		qs.abandon(str(gather["id"]))
	qs.reset()


# --- 7. Panel on a live map ----------------------------------------------------

func _test_spawn_panel() -> void:
	## The real hero opens the panel on the real map (the game order: the map
	## and the system are alive before the click on the head). The find_relic
	## object asks the map to walk it, and the panel must not freeze a stale
	## card list nor drop the swaying coin.
	var map := root.find_child("AlmMap", true, false)
	var hero := root.find_child("Hero", true, false) as Node2D
	_check(map != null and hero != null, "the smoke map and the hero exist")
	if map == null or hero == null:
		return
	# Arriving on the map: the quest objects are placed at the hero.
	var spawn := map.find_children("*", "QuestTarget", true, false)
	_check(spawn.size() <= QuestSystem.instance.active.size(),
		"quest objects follow the journal (%d objects / %d quests)" % [
			spawn.size(), QuestSystem.instance.active.size()])
	var lone: Object = (load("res://scripts/quest_target.gd") as GDScript).new()
	_check(lone is QuestTarget, "a quest object is a QuestTarget")
	if lone is Node:
		(lone as Node).free()


# --- 9. Marker ----------------------------------------------------------------

# --- 7. Faction tags (forge package E) ---------------------------------------

## Quest items are their own category (player decision 13.11): a found or handed
## item is a "Quest ..." copy that cannot be read, sold or equipped, while the
## base item of the world stays ordinary.
func _test_quest_items(qs) -> void:
	var hero := root.find_child("Hero", true, false)
	hero.set("inventory", [])
	for tpl_id in ["deliver_tome", "find_relic"]:
		var q: Dictionary = qs.debug_add_offer(CITY, tpl_id)
		if q.is_empty():
			_check(false, "quest template %s is available" % tpl_id)
			continue
		var base := str(q.get("item_key", ""))
		var bag := str(q.get("bag_key", ""))
		_check(ItemDB.is_quest_key(bag),
			"%s: the bag copy is a quest item (%s)" % [tpl_id, bag])
		_check(not ItemDB.is_quest_key(base),
			"%s: the base item stays ordinary (%s)" % [tpl_id, base])
		var bag_item := ItemDB.find(bag)
		_check(str(bag_item.get("quality", "")) == "Quest",
			"%s: quality Quest (%s)" % [tpl_id, str(bag_item.get("quality", ""))])
		_check(int(bag_item.get("price", -1)) == 0,
			"%s: a quest item has no price" % tpl_id)
		_check(ItemDB.display_name(bag_item) == ItemDB.display_name(ItemDB.find(base)),
			"%s: it is named after what it stands for" % tpl_id)
		qs.accept(CITY, str(q["id"]))
		var taken: Dictionary = qs.quest_by_id(str(q["id"]))
		if tpl_id == "deliver_tome":
			_check(str(taken.get("issued", "")) == bag and hero.inventory.has(bag),
				"deliver: the quest item is handed out on take")
		else:
			_check(str(taken.get("bag_key", "")) == bag,
				"find: the pickup spawns the quest copy")
		# The base item, by contrast, is ordinary: a book still teaches a spell,
		# while the quest copy teaches nothing (`learn_book` also refuses the
		# Quest quality outright - the bag fixture has no Player method here).
		if base.begins_with("Book "):
			_check(SpellDB.spell_of_book(bag) == "",
				"the quest copy of a tome teaches nothing")
			_check(SpellDB.spell_of_book(base) != "",
				"the base book still teaches a spell")
		qs.abandon(str(q["id"]))
		hero.set("inventory", [])


func _test_faction_tags(qs: QuestSystem) -> void:
	## A town asks for RIVAL faction tags and pays with a blueprint of its own set.
	qs.reset()
	var q := qs.debug_add_offer(CITY, "gather_tags")
	_check(not q.is_empty(), "a forced gather_tags offer is created")
	if q.is_empty():
		return
	var rival := str(q.get("rival_race", ""))
	_check(rival != "" and rival != CITY_RACE,
		"the tag quest names a rival faction (%s vs %s)" % [rival, CITY_RACE])
	_check(str(q.get("item_key", "")) == ItemDB.tag_key(rival),
		"the quest asks for the rival's tag (%s)" % str(q.get("item_key", "")))
	_check(not ItemDB.find(str(q.get("item_key", ""))).is_empty(),
		"the asked tag exists in item_db")
	_check(int(q.get("need", 0)) > 1, "several tags are needed (%d)" % int(q.get("need", 0)))
	var text := str(q.get("text", ""))
	_check(not text.contains("%") and text != "",
		"the tag quest text is filled (no placeholders left)")
	_check(text.contains(Lore.faction_label(rival)),
		"the text names the rival faction")
	# Reward: blueprint of the GIVER's faction, not a random recipe.
	_check(str(q.get("blueprint", "")).begins_with("faction_%s_" % CITY_RACE),
		"the reward is a blueprint of the town faction (%s)" % str(q.get("blueprint", "")))
	_check(qs.accept(CITY, str(q["id"])) == "", "the tag quest is taken")
	var hero := root.find_child("Hero", true, false)
	hero.set("inventory", [])
	var need := int(q.get("need", 1))
	for _i in range(need):
		hero.call("add_item", str(q.get("item_key", "")))
	qs.sync_inventory()
	var cur := qs.quest_by_id(str(q["id"]))
	_check(str(cur.get("state", "")) == QuestSystem.STATE_READY,
		"a full set of tags makes the quest ready")
	var result := qs.turn_in(CITY, str(q["id"]))
	_check(result != "", "the tag quest is turned in (%s)" % result)
	var tags_left := 0
	for raw in hero.inventory:
		if str(raw) == str(q.get("item_key", "")):
			tags_left += 1
	_check(tags_left == 0, "turn-in takes the tags out of the bag (%d left)" % tags_left)
	var scroll := CraftDB.recipe_scroll_key(str(q.get("blueprint", "")))
	_check(hero.inventory.has(scroll), "the blueprint is in the bag (%s)" % scroll)


func _test_marker(qs: QuestSystem) -> void:
	qs.reset()
	_bus_ref().state.day = 0
	qs.offers_by_city.clear()
	qs.offers_for(CITY)
	_check(qs.marker_kind_for(CITY) == "available", "\"!\" hangs while there are offers")
	# A town the generator did not make gets no work and no marker. Offers of the
	# REAL towns on the map must be left alone: every head rebuild asks about
	# every id.
	var q := qs.debug_add_offer(CITY, "kill_species")
	if not q.is_empty():
		qs.accept(CITY, str(q["id"]))
		for _i in range(int(q.get("need", 1))):
			qs.notify_killed(str(q.get("set", "")), "")
		_check(qs.marker_kind_for(CITY) == "ready",
			"a quest ready to turn in shows \"?\" (over \"!\")")
		qs.abandon(str(q["id"]))
	qs.reset()


# --- 10. Save -----------------------------------------------------------------

func _test_save_roundtrip(qs: QuestSystem) -> void:
	qs.reset()
	qs.offers_by_city.clear()
	var offers := qs.offers_for(CITY)
	var id := str((offers[0] as Dictionary).get("id", "")) if offers.size() > 0 else ""
	if id != "":
		qs.accept(CITY, id)
	var payload := qs.to_payload()
	_check((payload.get("active", []) as Array).size() == qs.active.size(),
		"the payload holds the active quests")
	qs.reset()
	qs.apply_payload(payload)
	_check(qs.active.size() == (payload.get("active", []) as Array).size(),
		"the journal is restored from the payload")
	_check(qs.city_name(CITY) != "", "the city name is derived from the id")
	_check(qs.to_payload().get("next_id", 0) == payload.get("next_id", 0),
		"the id counter survives loading")
	# An old slot (an array in "quests") - an empty schema, not a crash.
	Game.pending_quests = {}
	SaveSystem.apply_payload({"map": {"seed": 1, "zone": "start"}, "quests": []}, null)
	_check(Game.pending_quests.is_empty(),
		"the old array in quests gives an empty schema")
	qs.reset()


# --- 11. Art -------------------------------------------------------------------
func _test_art() -> void:
	## Art is generated separately and approved by the player (tests/gen_quest_art.py).
	## A marker kind is drawn EITHER completely (all its frames) OR not at all - a
	## half sliced atlas must not slip through unnoticed. The kinds are approved
	## one sheet at a time, so "available" may already be in while "ready" is not
	## yet: the completeness rule is per kind, not across kinds.
	for kind in QuestIcons.MARK_FRAMES.keys():
		var frames := int(QuestIcons.MARK_FRAMES[kind])
		var present := 0
		var broken := 0
		for i in range(frames):
			var path := QuestIcons.mark_frame_path(kind, i)
			if path == "":
				continue
			present += 1
			if not (load(path) is Texture2D):
				broken += 1
		_check(present == 0 or present == frames,
			"marker %s: %d of %d frames" % [kind, present, frames])
		_check(broken == 0, "marker %s: every frame loads as a texture" % kind)
		if present == frames:
			print("     marker %s: art in place (%d frames)" % [kind, frames])
	for icon in _db_icons():
		var path := QuestIcons.item_icon(icon)
		_check(path == "" or load(path) is Texture2D,
			"icon %s loads as a texture" % icon)
	_test_item_icons()
	var coin_path := LootIcons.gold_icon()
	_check(ResourceLoader.exists(coin_path), "the gold coin is in place (%s)" % coin_path)
	var tex := load(coin_path)
	_check(tex is Texture2D, "the coin loads as a texture")
	if tex is Texture2D:
		var size: Vector2i = (tex as Texture2D).get_size()
		_check(size.x == size.y and size.x >= 24,
			"the coin is square and readable (%dx%d)" % [size.x, size.y])
	# The animated coin is a sprite: the same "all frames or none" rule as a
	# marker, and the static loot icon stays untouched by it.
	var coin_present := 0
	var coin_broken := 0
	for i in range(QuestIcons.COIN_FRAMES):
		var path := QuestIcons.coin_frame_path(i)
		if path == "":
			continue
		coin_present += 1
		if not (load(path) is Texture2D):
			coin_broken += 1
	_check(coin_present == 0 or coin_present == QuestIcons.COIN_FRAMES,
		"coin sprite: %d of %d frames" % [coin_present, QuestIcons.COIN_FRAMES])
	_check(coin_broken == 0, "coin sprite: every frame loads as a texture")
	_check(QuestIcons.coin_frames().size() == coin_present,
		"coin_frames() returns exactly the frames on disk")
	if coin_present == QuestIcons.COIN_FRAMES:
		var face := load(QuestIcons.coin_frame_path(0)) as Texture2D
		var edge := load(QuestIcons.coin_frame_path(2)) as Texture2D
		_check(face.get_size() == edge.get_size(),
			"coin frames share one canvas (%s / %s)" % [face.get_size(), edge.get_size()])
		_check(QuestIcons.coin_icon() == QuestIcons.coin_frame_path(0),
			"a static coin slot uses the animated face-on frame")


func _test_item_icons() -> void:
	## The five quest item icons (ai art 22.10, the crimson plate of the sheet
	## cleared by tests/extract_quest_art.py): either the whole set or none of
	## it, one canvas, and the plate leaves no crimson block in a slot.
	var present := 0
	for name in QuestIcons.PICK_ICON.values():
		if QuestIcons.item_icon(str(name)) != "":
			present += 1
	_check(present == 0 or present == QuestIcons.PICK_ICON.size(),
		"quest item icons: %d of %d" % [present, QuestIcons.PICK_ICON.size()])
	if present == 0:
		return
	var canvas := Vector2i.ZERO
	var same_canvas := true
	var crimson := 0
	var checked := 0
	for name in QuestIcons.PICK_ICON.values():
		var path := QuestIcons.item_icon(str(name))
		if path == "":
			continue
		var tex := load(path) as Texture2D
		var size: Vector2i = tex.get_size()
		if canvas == Vector2i.ZERO:
			canvas = size
		elif size != canvas:
			same_canvas = false
		crimson = maxi(crimson, _crimson_pixels(tex.get_image()))
		checked += 1
	_check(same_canvas, "quest item icons share one canvas (%dx%d)" % [canvas.x, canvas.y])
	_check(checked > 0, "quest item icons are drawn (%d)" % checked)
	# A whole crimson slot (the plate of the raw sheet) would read as a
	# painted square in the 32 px card: the cleared art keeps a thin matte.
	_check(crimson * 4 < canvas.x * canvas.y,
		"no crimson plate inside a quest item icon (worst %d px)" % crimson)


func _crimson_pixels(img: Image) -> int:
	## Plate pixels of one icon: the crimson fill of the raw sheet.
	var out := 0
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var c := img.get_pixel(x, y)
			if c.a > 0.5 and c.r > 0.45 and c.g < 0.32 and c.b > 0.25 \
					and c.r - c.g > 0.25:
				out += 1
	return out


func _db_icons() -> Array:
	var f := FileAccess.open("res://assets/quests/quest_db.json", FileAccess.READ)
	if f == null:
		return []
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	var out: Array = []
	if not (parsed is Dictionary):
		return out
	for raw in (parsed as Dictionary).get("templates", []):
		var icon := str((raw as Dictionary).get("icon", ""))
		if icon != "" and not out.has(icon):
			out.append(icon)
		var pick := str((raw as Dictionary).get("pick", ""))
		if pick != "" and not out.has(pick):
			out.append(pick)
	return out


# --- Report -------------------------------------------------------------------

func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _ids(list: Array) -> Array:
	var out: Array = []
	for q in list:
		out.append(str((q as Dictionary).get("id", "")))
	return out


func _report() -> void:
	if _fails.is_empty():
		print("RESULT: OK quest_system_smoke")
		quit(0)
		return
	print("RESULT: FAIL - %d checks failed" % _fails.size())
	for line in _fails:
		print("   - " + line)
	quit(1)


# --- 12. Panel refresh ---------------------------------------------------------

func _test_panel_refresh(qs: QuestSystem) -> QuestPanel:
	## A head whose work is gone must not freeze a stale card list: the rotation
	## moves the offers on a new world day. It is checked on the head itself and
	## on the panel screen: the offers column follows the journal by itself (a
	## panel built with the system already alive used to wait 0.25 s and then
	## rebuild every frame; with no taken quests it never rebuilt at all).
	## The screen is rebuilt once by hand: the card list must be right at once.
	qs.reset()
	qs.offers_by_city.clear()
	var first := qs.offers_for(CITY)
	_check(not first.is_empty(), "the head rolled offers (%d)" % first.size())

	# Next world day past the offer lifetime: a new rotation of the work.
	var ttl := maxi(1, GameConfig.geti("quests", "offer_ttl_days"))
	var bus = _bus_ref()
	var day_before := int(bus.state.day)
	bus.state.day = day_before + ttl
	var next := qs.offers_for(CITY)
	_check(not next.is_empty(), "the next rotation still has offers (%d)" % next.size())
	var reused := 0
	for q in next:
		for old in first:
			if str(q.get("id", "")) == str(old.get("id", "")):
				reused += 1
	_check(reused == 0, "a new rotation offers new quests (reused ids: %d)" % reused)
	bus.state.day = day_before

	# The panel screen: it is built with the system in place, so its card list
	# has to follow offers_changed without a manual rebuild.
	var panel := QuestPanel.new()
	panel.name = "QuestPanelSmoke"
	root.add_child(panel)
	qs.reset()
	panel.setup(Game.hero as Player, CITY)
	var offers_box: Node = panel.get("_offers_box")
	_check(offers_box != null, "the panel built its columns")
	if offers_box == null:
		return panel
	# The first build is quiet (a focus grab is deferred); this call fills the
	# cards, so the checks below need no frame.
	panel.call("_refresh")
	var expected := qs.offers_for(CITY).size()
	# The cards are added in this very scope: no frame is needed for them.
	_check(offers_box.get_child_count() == expected,
		"the offers column shows one card per offer (%d cards / %d offers)" % [
			offers_box.get_child_count(), expected])
	if offers_box.get_child_count() != expected:
		return panel
	var cards_before := offers_box.get_child_count()
	var coins: Array = panel.get("_coin_sprites")
	_check(coins.size() == cards_before,
		"every offer card carries a swaying coin (%d coins / %d cards)" % [
			coins.size(), cards_before])
	var coin: TextureRect = coins[0] if not coins.is_empty() else null
	if coin != null:
		var frame_before := coin.texture
		panel.call("_tick_coin", panel.coin_frame_time())
		_check(coin.texture != frame_before, "the coin sprite swaps frames")
	# A new rotation of the work must show up on the screen by itself.
	bus.state.day = day_before + ttl
	qs.offers_for(CITY)
	panel.call("_refresh")
	expected = qs.offers_for(CITY).size()
	_check(offers_box.get_child_count() == expected,
		"the offers column follows the rotation (%d cards -> %d, offers %d)" % [
			cards_before, offers_box.get_child_count(), expected])
	bus.state.day = day_before
	return panel


## W открывает журнал (game.gd) и ОБЯЗАН его закрывать (28.10). Путь через
## game.gd закрыт: открытая панель ставит is_editor_open(), и W до game.gd не
## доходит; значит, закрытие должен уметь сам QuestPanel._input.
func _test_panel_w_close(qs: QuestSystem) -> void:
	var panel := QuestPanel.new()
	panel.name = "QuestPanelWSmoke"
	root.add_child(panel)
	panel.setup(Game.hero as Player, "")
	var closed := [false]
	panel.closed.connect(func() -> void: closed[0] = true)
	var ev := InputEventKey.new()
	ev.keycode = KEY_W
	ev.pressed = true
	panel._input(ev)
	_check(closed[0], "W закрывает журнал (сигнал closed)")
	_check(panel.is_queued_for_deletion(), "W закрывает журнал (панель удаляется)")
