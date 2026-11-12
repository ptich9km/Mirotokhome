class_name QuestSystem
extends Node
## Town head quests (22.10).
##
## WHAT THIS IS. Every town has a head (an NPC with role "head", a "!" burns
## above it - quest_marker.gd). The head holds up to [quests] offer_slots
## offers generated from assets/quests/quest_db.json (data, not code). The
## player may take up to [quests] max_active and turn them in at the head of
## the town they were taken in. Abandoning returns the quest to that town's
## offers instead of throwing it away: a player who changed their mind should
## not wait a whole rotation.
##
## ROTATION. An offer lives [quests] offer_ttl_days world days
## (WorldBus.state.day, ticked by world_bus.gd). A new set is keyed by the
## rotation number, not by a call counter: refresh is idempotent and returns
## THE SAME set on repeated calls, while the set seed
## (map_seed|zone|city|rotation) is deterministic - save/load and a map
## regenerated from the same seed give the same quests.
##
## REWARD (player decision 22.10): gold + faction reputation of the town
## (WorldState.hero_reputation is the HERO axis, not the SIM relations
## matrix) + a small archmage power gain of that faction + a blueprint for a
## hard quest.
##
## PROGRESS. Kills come from the Enemy.died signal (enemy.gd), found items
## from QuestTarget, gathering is counted straight from the inventory on
## turn-in. An URGENT quest ticks in real seconds: a world day is far too
## coarse for a two-minute timer.

signal offers_changed(city_id: String)
signal active_changed()
signal quest_taken(quest_id: String)
signal quest_abandoned(quest_id: String)
signal quest_completed(quest_id: String)
signal quest_failed(quest_id: String)

const STATE_ACTIVE := "active"
const STATE_READY := "ready"
const STATE_DONE := "done"
const STATE_FAILED := "failed"

## How many active quests of one template we hold at once: three "hunt the
## wolves" in the journal is not a choice, it is copy-paste.
const SAME_TEMPLATE_LIMIT := 1

static var instance: QuestSystem = null

var offers_by_city: Dictionary = {}   # city_id -> Array[Dictionary]
var active: Array[Dictionary] = []    # taken quests (STATE_ACTIVE/READY)
var history: Array[Dictionary] = []   # closed: feed the journal and save
var targets: Array[Dictionary] = []   # material targets lying on the map
var _rotation_seed := -1              # map the current offers belong to
var _rotation_sector := ""            # sector the current offers belong to
var _bus: Node = null
var _next_id := 1
var _map: Node = null                 # map we listen to for enemy deaths


func _ready() -> void:
	add_to_group("quests")
	instance = self
	quest_taken.connect(_on_state_signals)
	quest_abandoned.connect(_on_state_signals)
	quest_completed.connect(_on_state_signals)
	quest_failed.connect(_on_state_signals)
	tree_exiting.connect(_on_exiting)


func _on_exiting() -> void:
	_disconnect_map()
	if instance == self:
		instance = null


## Enemy deaths - bound ONCE per map. The map is rebuilt (portal/load), so the
## held node is re-checked on every tick: the old one may be freed already.
func _bind_map(map: Node) -> void:
	if map == _map and is_instance_valid(_map):
		return
	_disconnect_map()
	if map == null or not map.has_signal("enemy_died"):
		return
	_map = map
	if not map.is_connected("enemy_died", Callable(self, "_on_enemy_died")):
		map.connect("enemy_died", _on_enemy_died)


func _process(delta: float) -> void:
	if not Game.perf_enabled:
		_process_impl(delta)
		return
	var t0 := Time.get_ticks_usec()
	_process_impl(delta)
	Game.perf_end("quests", t0)


func _process_impl(delta: float) -> void:
	if GameConfig.geti("quests", "enabled") == 0:
		return
	_tick_urgent(delta)
	_tick_rotation()
	_tick_inventory()


func _state():
	if _bus == null:
		_bus = get_node_or_null("/root/WorldBus")
	if _bus == null or _bus.state == null:
		return null
	return _bus.state


func _day() -> int:
	var st = _state()
	return 0 if st == null else int(st.day)


## --- Rotation and offers -----------------------------------------------------

## Re-roll every town when the world day (rotation) or the map changed.
func _tick_rotation() -> void:
	var map: Node = get_tree().get_first_node_in_group("alm_map")
	_bind_map(map)
	if Game.map_seed != _rotation_seed or Game.map_sector != _rotation_sector:
		_refresh_all_cities()
		return
	for city_id in offers_by_city.keys():
		ensure_city(_city_from_key(str(city_id)))


func _disconnect_map() -> void:
	if _map != null and is_instance_valid(_map) \
			and _map.is_connected("enemy_died", Callable(self, "_on_enemy_died")):
		_map.disconnect("enemy_died", _on_enemy_died)
	_map = null


func _on_enemy_died(unit: Enemy) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	notify_killed(str(unit.anim_set), str(unit.quest_id))


## Full reset and rebuild of the offers of every town on the current map.
func _refresh_all_cities() -> void:
	_rotation_seed = Game.map_seed
	_rotation_sector = Game.map_sector
	# A saved journal is applied ONCE: after that the rotation lives on its own.
	# Applied BEFORE the generic clear - apply_payload() brings back the offers
	# and the taken quests of the save.
	if not Game.pending_quests_applied and not Game.pending_quests.is_empty():
		Game.pending_quests_applied = true
		var saved: Dictionary = Game.pending_quests
		Game.pending_quests = {}
		apply_payload(saved)
		return
	offers_by_city.clear()
	targets.clear()
	var map: Node = get_tree().get_first_node_in_group("alm_map")
	if map == null or not map.has_method("city_heads"):
		return
	for city_id in map.call("city_heads").keys():
		ensure_city(str(city_id))


## The town's offers are in place and fresh? Then do nothing. An offer lives
## until the END of its rotation: an offer made in the middle of a rotation
## must not expire before the balance of offers the other towns hold, or an
## abandoned quest could be thrown away.
func ensure_city(city_id: String) -> void:
	if city_id == "" or GameConfig.geti("quests", "enabled") == 0:
		return
	var key := _key(city_id)
	var day := _day()
	var rotation := _rotation_index(city_id)
	var cur: Array = offers_by_city.get(key, [])
	var stale := cur.is_empty()
	for off in cur:
		if day >= int(off.get("expires_day", day)) and int(off.get("rotation", "-1")) != rotation:
			stale = true
			break
	if not stale:
		return
	_regenerate(city_id)


func _regenerate(city_id: String) -> void:
	var key := _key(city_id)
	var rotation := _rotation_index(city_id)
	var rng := _city_rng(city_id, rotation)
	var difficulty := _city_difficulty(city_id)
	var race := _city_race(city_id)
	var city_count := _city_count()
	var excluded := _held_template_ids(city_id)
	var slots := maxi(1, GameConfig.geti("quests", "offer_slots"))
	var out: Array[Dictionary] = []
	# Offers of the CURRENT rotation survive the re-roll (an abandoned quest
	# comes back to them); they are not excluded either.
	for old in offers_by_city.get(key, []):
		if int(old.get("rotation", -1)) == rotation:
			out.append(old)
			excluded.erase(str(old.get("template", "")))
	while out.size() < slots:
		var tpl := QuestDB.pick_template(rng, Game.map_zone, difficulty,
			city_count, excluded)
		if tpl.is_empty():
			break
		var q := _make_quest(tpl, rng, city_id, race, difficulty, rotation)
		if q.is_empty():
			break
		out.append(q)
		excluded.append(str(tpl.get("id", "")))
	offers_by_city[key] = out
	offers_changed.emit(city_id)
	# Ротация по дню мира меняет «!»/«?» над главами, но панель об этом
	# узнаёт сигналом, а маркер — только вызовом. Без этого после смены дня
	# «!» висел над городом, где офферов уже нет.
	refresh_markers()


## Rotation number of a town by world day: offers live exactly offer_ttl_days
## days no matter how often the map was opened.
func _rotation_index(city_id: String) -> int:
	var ttl := maxi(1, GameConfig.geti("quests", "offer_ttl_days"))
	return int(floor(float(_day()) / float(ttl)))


## First world day AFTER the current rotation of a town: every offer of the
## set expires at it, whenever in the rotation the offer was made.
func _rotation_end_day(city_id: String) -> int:
	var ttl := maxi(1, GameConfig.geti("quests", "offer_ttl_days"))
	return (_rotation_index(city_id) + 1) * ttl


## Offers are stored per sector: city ids ("c0t0") repeat on every map, so the
## bare id would mix two towns of different maps.
func _key(city_id: String) -> String:
	if Game.map_sector == "":
		return city_id
	return "%s|%s" % [Game.map_sector, city_id]


func _city_from_key(key: String) -> String:
	var pos := key.find("|")
	return key.substr(pos + 1) if pos >= 0 else key


## То же, что _city_rng, но с сектором: две карты одного тира не должны
## выдавать одинаковый набор офферов.
func _city_rng(city_id: String, rotation: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%d|%s|%s|%s|%d" % [Game.map_seed, Game.map_zone,
		Game.map_sector, city_id, rotation])
	return rng


## Templates the player already holds or that are already offered by the town.
func _held_template_ids(city_id: String) -> Array:
	var out: Array = []
	for a in active:
		if str(a.get("sector", "")) != Game.map_sector:
			continue
		out.append(str(a.get("template", "")))
	for old in offers_by_city.get(_key(city_id), []):
		out.append(str(old.get("template", "")))
	return out


## --- One quest ---------------------------------------------------------------

func _make_quest(tpl: Dictionary, rng: RandomNumberGenerator, city_id: String,
		race: String, difficulty: int, rotation: int) -> Dictionary:
	var type := str(tpl.get("type", ""))
	var count := QuestDB.count_for(tpl, difficulty, rng)
	var q := {
		"city_race": race,
		"faction": QuestDB.faction_of_race(race),
		"difficulty": difficulty,
		"rotation": rotation,
		"expires_day": _rotation_end_day(city_id),
		"need": count,
		"progress": 0,
		"state": "offer",
		"icon": str(tpl.get("icon", "")),
		"item_key": "",
		"species": "",
		"set": "",
		"deliver_city": "",
		"rival_race": "",
		"target_cell": [],
		"elite": false,
		"pick": str(tpl.get("pick", "")),
	}
	q["id"] = "q%d" % _next_id
	q["template"] = str(tpl.get("id", ""))
	q["type"] = type
	q["city_id"] = city_id
	q["sector"] = Game.map_sector
	var reward := _reward_for(q, rng)
	q["gold"] = int(reward.get("gold", 0))
	q["rep"] = int(reward.get("rep", 0))
	q["power"] = float(reward.get("power", 0.0))
	q["blueprint"] = str(reward.get("blueprint", ""))
	match type:
		"KILL_SPECIES", "KILL_GROUP":
			var species := _pick_species(rng, difficulty)
			if species == "":
				return {}
			q["species"] = species
			q["set"] = QuestDB.gray_set_for_species(species, difficulty, Game.map_zone, rng)
		"KILL_TARGET":
			var species_t := _pick_species(rng, difficulty)
			if species_t == "":
				return {}
			q["species"] = species_t
			q["set"] = QuestDB.target_set_for_species(species_t, Game.map_zone)
			q["elite"] = true
			q["need"] = 1
		"URGENT":
			var species_u := _pick_species(rng, difficulty)
			if species_u == "":
				return {}
			q["species"] = species_u
			q["set"] = QuestDB.gray_set_for_species(species_u, difficulty, Game.map_zone, rng)
			q["seconds_left"] = float(GameConfig.getf("quests", "urgent_seconds"))
			q["seconds_total"] = float(GameConfig.getf("quests", "urgent_seconds"))
		"GATHER", "FIND_ITEM", "DELIVER":
			if bool(tpl.get("tags_of_rival", false)):
				# Пакет E: бирки СОПЕРНИКА. Город просит трофеи чужой фракции,
				# свои же бирки у него не в цене (и это же делает квест
				# осмысленным: бей форпосты не той фракции, что кормит город).
				var rival := _rival_race(race, rng)
				if rival == "":
					return {}
				q["rival_race"] = rival
				q["item_key"] = ItemDB.tag_key(rival)
				q["need"] = count
			else:
				var pool: Array = tpl.get("item_pool", [])
				if pool.is_empty():
					return {}
				q["item_key"] = str(pool[rng.randi_range(0, pool.size() - 1)])
				q["need"] = 1 if type != "GATHER" else count
				# A quest item is its own category (player decision 13.11): the bag
				# copy is a "Quest ..." key, while item_key stays the base item for
				# names, icons and pools. Gathering keeps real goods (herbs).
				if type in ["FIND_ITEM", "DELIVER"]:
					q["bag_key"] = ItemDB.quest_key(str(q.get("item_key", "")))
			if type == "DELIVER":
				var other := _other_city(city_id, rng)
				if other == "":
					return {}
				q["deliver_city"] = other
				# The letter is handed out ON TAKE (player decision): a delivery
				# without the item in hand would ask for nothing.
				q["issued"] = _bag_key(q)
			if type == "FIND_ITEM":
				q["target_cell"] = _quest_cell(rng, tpl)
		_:
			return {}
	_next_id += 1
	q["title"] = _title_for(q, tpl)
	q["text"] = _text_for(q, tpl)
	return q


## Item the quest itself hands to the player on take.
func _give_issue_item(q: Dictionary) -> void:
	var key := str(q.get("issued", ""))
	if key == "" or Game.hero == null or not is_instance_valid(Game.hero):
		return
	Game.hero.add_item(key)


## Take the issued item back on abandon/fail: an abandoned delivery must not
## leave someone else's letter in the bag forever.
func _take_issue_item(q: Dictionary) -> void:
	var key := str(q.get("issued", ""))
	if key == "" or Game.hero == null or not is_instance_valid(Game.hero):
		return
	Game.hero.remove_item(key)


## Species that has a set in the database: otherwise the quest is undoable.
func _pick_species(rng: RandomNumberGenerator, difficulty: int) -> String:
	var list := QuestDB.species_for_quest(Game.map_zone, difficulty, rng)
	if list.is_empty():
		return ""
	return str(list[rng.randi_range(0, list.size() - 1)])


## Search spot for a found item (FIND_ITEM): a walkable cell away from the hero.
func _quest_cell(rng: RandomNumberGenerator, tpl: Dictionary) -> Array:
	var map: Node = get_tree().get_first_node_in_group("alm_map")
	if map == null:
		return []
	var tile := maxi(1, int(map.get("tile_size")))
	var mw := maxi(0, int(map.get("map_width")))
	var mh := maxi(0, int(map.get("map_height")))
	if mw <= 0 or mh <= 0:
		return []
	var band: Array = tpl.get("cell_dist", [GameConfig.geti("quests", "prep_min_dist"),
		GameConfig.geti("quests", "prep_max_dist")])
	var origin := Vector2i(mw / 2, mh / 2)
	if Game.hero != null and is_instance_valid(Game.hero):
		origin = Vector2i(int(Game.hero.global_position.x) / tile,
			int(Game.hero.global_position.y) / tile)
	for _attempt in range(160):
		var ang := rng.randf() * TAU
		var dist := float(rng.randi_range(int(band[0]), int(band[1])))
		var cell := origin + Vector2i(int(cos(ang) * dist), int(sin(ang) * dist))
		if cell.x < 2 or cell.y < 2 or cell.x >= mw - 2 or cell.y >= mh - 2:
			continue
		var pos := Vector2(float((cell.x + 0.5) * tile), float((cell.y + 0.5) * tile))
		if map != null and map.has_method("is_walkable_world"):
			if not bool(map.call("is_walkable_world", pos)):
				continue
		return [cell.x, cell.y]
	return []


func _other_city(city_id: String, rng: RandomNumberGenerator) -> String:
	var map: Node = get_tree().get_first_node_in_group("alm_map")
	if map == null or not map.has_method("city_heads"):
		return ""
	var ids: Array = []
	for cid in (map.call("city_heads") as Dictionary).keys():
		if str(cid) != city_id:
			ids.append(str(cid))
	if ids.is_empty():
		return ""
	return str(ids[rng.randi_range(0, ids.size() - 1)])


## --- Texts and rewards -------------------------------------------------------

func _reward_for(q: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var diff := int(q.get("difficulty", 1))
	var mult := QuestDB.difficulty_mult(diff)
	var faction := str(q.get("faction", ""))
	var out := {
		"gold": int(round(float(QuestDB.base_gold(diff)) * mult)),
		"rep": int(round(float(GameConfig.geti("quests", "rep_base")) * mult)),
		"power": float(GameConfig.getf("quests", "power_base")) * mult,
		"blueprint": "",
	}
	var tpl := QuestDB.template(str(q.get("template", "")))
	if str(tpl.get("reward_recipe", "")) == "giver":
		# Пакет E: квест на бирки платит чертежом набора СВОЕЙ фракции, а не
		# случайным рецептом: игрок понимает, за что бьёт чужие форпосты.
		out["blueprint"] = _pick_recipe_of_faction(faction, rng)
	elif diff >= GameConfig.geti("quests", "blueprint_min_difficulty"):
		# The quest's own rng: a hard quest without recipes left costs no draw,
		# so the rest of its content stays stable from seed to seed.
		out["blueprint"] = _pick_blueprint(faction, rng)
	return out


## Соперник для квеста на бирки: любая фракция, КРОМЕ фракции города.
func _rival_race(race: String, rng: RandomNumberGenerator) -> String:
	var pool: Array = []
	for r in MapGenerator.CITY_RACES:
		if str(r) != race:
			pool.append(str(r))
	if pool.is_empty():
		return ""
	return str(pool[rng.randi_range(0, pool.size() - 1)])


## Рецепт набора фракции, которого у героя ещё нет ("" — все известны).
func _pick_recipe_of_faction(race: String, rng: RandomNumberGenerator) -> String:
	var known: Dictionary = {}
	if Game.hero != null and is_instance_valid(Game.hero) and "inventory" in Game.hero:
		for raw in Game.hero.inventory:
			known[str(raw)] = true
	var pool: Array = []
	for rid in CraftDB.recipe_ids_of_faction(race):
		if known.has(CraftDB.recipe_scroll_key(str(rid))):
			continue
		pool.append(str(rid))
	if pool.is_empty():
		return ""
	return str(pool[rng.randi_range(0, pool.size() - 1)])


## Blueprint for a hard quest: a CraftDB recipe scroll the hero most likely
## does not have yet. Empty when no recipes are left.
func _pick_blueprint(faction: String, rng: RandomNumberGenerator) -> String:
	var known: Array = []
	if Game.hero != null and is_instance_valid(Game.hero) and "inventory" in Game.hero:
		for raw in Game.hero.inventory:
			var key := str(raw)
			if key.begins_with(CraftDB.RECIPE_SCROLL_PREFIX):
				known.append(key.substr(CraftDB.RECIPE_SCROLL_PREFIX.length()))
	var pool: Array = []
	for rid in CraftDB.all_recipe_ids():
		if known.has(rid):
			continue
		pool.append(str(rid))
	if pool.is_empty():
		return ""
	return str(pool[rng.randi_range(0, pool.size() - 1)])


func _title_for(q: Dictionary, tpl: Dictionary) -> String:
	return _populate_for(str(tpl.get("title_key", "")), q, "title")


func _text_for(q: Dictionary, tpl: Dictionary) -> String:
	return _populate_for(str(tpl.get("text_key", "")), q, "text")


## The key in the first language version whose placeholders fit `populate`
## (the current language first, then Russian): a card must never show another
## language nor a raw %s from a translation with a different structure.
func _populate_for(key: String, q: Dictionary, mode: String) -> String:
	var tpl := QuestDB.template(str(q.get("template", "")))
	var order: Array = tpl.get("populate", [])
	for version in QuestDB.text_versions(key):
		if QuestDB.placeholders_fit(str(version), order, mode == "title"):
			return _fill(str(version), q, mode)
	return Loc.t(key)


## A fresh copy of a quest: filling a title must not depend on the text that
## was filled before it.
func _fill_quest(q: Dictionary) -> Dictionary:
	return q.duplicate(true)


## Fills the slots of one template text. The template id fixes the species
## case and the title/text form (see QuestDB.species_form): a hunt title names
## the beasts as an object ("Hunt for wolves"), while the sentence inside the
## text may need the subject form ("wolves at the gates").
##
## `mode` says what the text is: a "title" reuses ONE value through %s and
## takes it in the shortest form (the item alone, no article), a "text" is a
## sentence and takes the running forms.
func _fill(raw: String, q: Dictionary, mode: String = "text") -> String:
	var tpl := QuestDB.template(str(q.get("template", "")))
	var order: Array = tpl.get("populate", [])
	var out := raw
	var from := 0
	for key in order:
		var slot := "%d" if QuestDB.NUMERIC_POPULATE.has(str(key)) else "%s"
		# Nothing left to fill: the title has one slot, the populate order may
		# be longer. A missing slot must not shift the search window.
		if out.find(slot, from) < 0:
			continue
		var value := ""
		if str(key) == "species_plural":
			value = _species_plural_form(str(q.get("species", "")), str(tpl.get("id", "")),
				mode)
		elif mode == "title" and not QuestDB.NUMERIC_POPULATE.has(str(key)):
			value = str(_text_arg(str(key), q, true))
		else:
			value = str(_text_arg(str(key), q, false))
		value = value.replace("%", "%%")
		out = _substitute(out, slot, value, from)
		from += value.length()
	return out


## The plural form has to agree with the words around it, and the title and the
## sentence of one template may need different forms: "Hunt for wolves" is an
## object, "wolves at the gates!" a subject. QuestDB.species_form holds the
## pair per template; a template that is not listed keeps `default` in both.
func _species_plural_form(species: String, template_id: String, mode: String) -> String:
	if species == "":
		return ""
	return QuestDB.species_plural(species, QuestDB.species_form(template_id, mode))


## The number as a word when the words around it need one: "put down five
## wolves" is correct Russian, "%s at the gates" is not ("5 wolves at the
## gates!"). The word itself comes from the locale table.
func _count_word(n: int) -> String:
	var key := "ui.quest.num.%d" % n
	if Loc.has_key(key):
		return Loc.t(key)
	return str(n)


## Replaces the FIRST `slot` at or after `from` in `text`. Done by hand instead
## of the formatter: one value of the wrong kind (a number into %s) must not
## blow up the whole quest, and a literal % inside a value must stay a literal %.
## `from` keeps a later slot from landing inside a value already placed.
func _substitute(text: String, slot: String, value: String, from := 0) -> String:
	var at := text.find(slot, from)
	if at < 0:
		return text
	return text.substr(0, at) + value + text.substr(at + slot.length())


func _text_arg(key: String, q: Dictionary, short := false) -> String:
	match key:
		"count":
			return str(int(q.get("need", 1)))
		"count_word":
			return _count_word(int(q.get("need", 1)))
		"species":
			return QuestDB.species_title(str(q.get("species", "")))
		"species_plural":
			return QuestDB.species_plural_acc(str(q.get("species", "")))
		"item":
			# Quest name of the item, not the shop name (item_db "name_ru" can
			# carry a shop trait such as "4.4"): a quest card says what to bring.
			# A title keeps the bare name: the template already carries the
			# surrounding words ("Search for ..."), no article belongs there.
			var item_key := str(q.get("item_key", ""))
			var named := QuestDB.quest_item_name(item_key, short)
			return named if named != "" else item_key
		"city":
			return city_name(str(q.get("deliver_city", "")))
		"rival":
			# Пакет E: имя фракции-соперника словами ("Орда", "Пожинатели").
			var race := str(q.get("rival_race", ""))
			return Lore.faction_label(race) if race != "" else ""
		"minutes":
			return str(int(round(float(q.get("seconds_total", 0.0)) / 60.0)))
	return ""


## Town name by id ("c0t0"). The generator's _cities records have no names, so
## the number matches the one the player sees next to the head's marker.
func city_name(city_id: String) -> String:
	if city_id == "":
		return Loc.t("ui.quest.town")
	var idx := 0
	if city_id.begins_with("c"):
		idx = int(city_id.trim_prefix("c").get_slice("t", 0))
	return Loc.f("ui.quest.town_number", [idx + 1])


func _city_race(city_id: String) -> String:
	var map: Node = get_tree().get_first_node_in_group("alm_map")
	if map == null or not map.has_method("city_heads"):
		return MapGenerator.city_race_for_hero(Game.hero_race)
	var rec: Dictionary = map.call("city_heads").get(city_id, {})
	return str(rec.get("race", MapGenerator.city_race_for_hero(Game.hero_race)))


func _city_count() -> int:
	var map: Node = get_tree().get_first_node_in_group("alm_map")
	if map == null or not map.has_method("city_heads"):
		return 1
	return maxi(1, (map.call("city_heads") as Dictionary).size())


## Offer difficulty grows with zone depth and shifts from rotation to rotation:
## the starting zone is easy/normal, deeper zones lean to hard.
func _city_difficulty(city_id: String) -> int:
	var base := 1
	match Game.map_zone:
		"start": base = 1
		"mid": base = 1
		"hard": base = 2
		_: base = 2
	var rng := _city_rng("difficulty|" + city_id, _rotation_index(city_id))
	return clampi(base + rng.randi_range(0, 1), 1, 3)


## --- Player journal ----------------------------------------------------------

func offers_for(city_id: String) -> Array[Dictionary]:
	ensure_city(city_id)
	var out: Array[Dictionary] = []
	for o in offers_by_city.get(_key(city_id), []):
		out.append(o)
	return out


func active_for_city(city_id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for a in active:
		if str(a.get("city_id", "")) == city_id \
				and str(a.get("sector", "")) == Game.map_sector:
			out.append(a)
	return out


func has_work(city_id: String) -> bool:
	## Is the "!" lit: there are offers or something to turn in.
	if not offers_for(city_id).is_empty():
		return true
	for a in active_for_city(city_id):
		if str(a.get("state", "")) == STATE_READY:
			return true
	return false


## Marker to show above the head: "ready" (nothing to hand in), "available"
## (offers on the table), "" - none.
func marker_kind_for(city_id: String) -> String:
	if city_id == "":
		return ""
	for a in active_for_city(city_id):
		if str(a.get("state", "")) == STATE_READY:
			return "ready"
	if not offers_for(city_id).is_empty():
		return "available"
	return ""


## Refresh every head marker on the map (after take/turn-in).
func refresh_markers() -> void:
	for n in Game.npcs:
		if is_instance_valid(n) and n.has_method("refresh_quest_marker"):
			n.call("refresh_quest_marker")


func _on_state_signals(_city_id: String = "") -> void:
	refresh_markers()


func quest_by_id(quest_id: String) -> Dictionary:
	for a in active:
		if str(a.get("id", "")) == quest_id:
			return a
	return {}


func find_active_for_city(city_id: String) -> Array[Dictionary]:
	return active_for_city(city_id)


## --- Player actions ----------------------------------------------------------

## Take an offer. Returns "" on success or the reason it was refused.
func accept(city_id: String, quest_id: String) -> String:
	if GameConfig.geti("quests", "enabled") == 0:
		return Loc.t("ui.quest.disabled")
	ensure_city(city_id)
	if active.size() >= GameConfig.geti("quests", "max_active"):
		return Loc.t("ui.quest.err_full")
	var idx := -1
	var list: Array = offers_by_city.get(_key(city_id), [])
	for i in range(list.size()):
		if str((list[i] as Dictionary).get("id", "")) == quest_id:
			idx = i
			break
	if idx < 0:
		return Loc.t("ui.quest.err_gone")
	var q: Dictionary = list[idx]
	var tpl := str(q.get("template", ""))
	var same := 0
	for a in active:
		if str(a.get("template", "")) == tpl:
			same += 1
	if same >= SAME_TEMPLATE_LIMIT:
		return Loc.t("ui.quest.err_taken")
	list.remove_at(idx)
	q["state"] = STATE_ACTIVE
	q["progress"] = 0
	if str(q.get("type", "")) == "GATHER":
		q["progress"] = count_item(str(q.get("item_key", "")))
	_give_issue_item(q)
	active.append(q)
	_materialize(q)
	_update_state(q)
	active_changed.emit()
	quest_taken.emit(str(q.get("id", "")))
	return ""


## Abandon: the quest goes back to the town's offers while the rotation holds.
func abandon(quest_id: String) -> bool:
	for i in range(active.size()):
		var q: Dictionary = active[i]
		if str(q.get("id", "")) != quest_id:
			continue
		active.remove_at(i)
		_dematerialize(q)
		_take_issue_item(q)
		_return_to_offers(q)
		active_changed.emit()
		quest_abandoned.emit(quest_id)
		return true
	return false


func _return_to_offers(q: Dictionary) -> void:
	var city_id := str(q.get("city_id", ""))
	if city_id == "":
		return
	# The rotation moved on while the quest was held: the old set is gone. Park
	# the quest in the CURRENT set (its rotation number and end of rotation as
	# the expiry) and re-run the generator, so the town does not quietly lose
	# an offer the player has just seen.
	var rotation := _rotation_index(city_id)
	q["rotation"] = rotation
	q["expires_day"] = _rotation_end_day(city_id)
	var list: Array = offers_by_city.get(_key(city_id), [])
	q["state"] = "offer"
	q["progress"] = 0
	list.append(q)
	offers_by_city[_key(city_id)] = list
	_regenerate(city_id)


## Turn in a finished quest. Returns the result text for the panel: a reward
## summary on success, or the reason the quest was not taken (see is_error).
func turn_in(city_id: String, quest_id: String) -> String:
	var q := quest_by_id(quest_id)
	if q.is_empty():
		return Loc.t("ui.quest.not_found")
	if str(q.get("city_id", "")) != city_id:
		return Loc.t("ui.quest.err_elsewhere")
	_sync_progress(q)
	_update_state(q)
	if str(q.get("state", "")) != STATE_READY:
		return Loc.t("ui.quest.err_not_ready")
	# Turn-in takes the item out of the bag: handing over a letter and keeping
	# it is not an option.
	var hero = Game.hero if Game.hero != null and is_instance_valid(Game.hero) else null
	_take_issue_item(q)
	if hero != null and str(q.get("type", "")) == "GATHER":
		var n := int(q.get("need", 1))
		for _i in range(n):
			hero.remove_item(str(q.get("item_key", "")))
	if hero != null and str(q.get("type", "")) == "FIND_ITEM":
		hero.remove_item(_bag_key(q))
	var gained := _grant(q)
	q["state"] = STATE_DONE
	q["closed_day"] = _day()
	active.erase(q)
	history.append(q)
	_dematerialize(q)
	active_changed.emit()
	quest_completed.emit(quest_id)
	offers_changed.emit(city_id)
	return gained


## Reward: gold, faction reputation, archmage power, blueprint.
func _grant(q: Dictionary) -> String:
	var parts: Array = []
	if Game.hero != null and is_instance_valid(Game.hero) and "gold" in Game.hero:
		Game.hero.gold += int(q.get("gold", 0))
		parts.append("%d %s" % [int(q.get("gold", 0)), Loc.t("ui.quest.gold_unit")])
	var faction := str(q.get("faction", ""))
	if faction != "":
		var st = _state()
		if st != null:
			st.add_hero_reputation(faction, int(q.get("rep", 0)))
			st.add_archmage_power(faction, float(q.get("power", 0.0)))
			parts.append("%+d %s %s" % [int(q.get("rep", 0)),
				Loc.t("ui.quest.reputation_unit"), str(faction)])
	var blueprint := str(q.get("blueprint", ""))
	if blueprint != "":
		var scroll := CraftDB.recipe_scroll_key(blueprint)
		if scroll != "" and Game.hero != null and is_instance_valid(Game.hero):
			Game.hero.add_item(scroll)
			var item := ItemDB.find(scroll)
			parts.append(str(item.get("name_ru", scroll)))
	SoundDB.play("ui.error")
	return ", ".join(parts)


## --- Progress ----------------------------------------------------------------

## A Gray died. Quests only count THEIR OWN set: a wolf hunt must not be
## closed by trolls. quest_id is passed by Enemy for target kills.
func notify_killed(set_name: String, quest_id: String = "") -> void:
	for q in active:
		var type := str(q.get("type", ""))
		if type not in ["KILL_SPECIES", "KILL_GROUP", "KILL_TARGET", "URGENT"]:
			continue
		if type == "KILL_TARGET" and quest_id != "":
			if quest_id != str(q.get("id", "")):
				continue
		elif not _counts_kill(q, set_name):
			continue
		q["progress"] = int(q.get("progress", 0)) + 1
		_update_state(q)
	active_changed.emit()


func _counts_kill(q: Dictionary, set_name: String) -> bool:
	var type := str(q.get("type", ""))
	var want := str(q.get("set", ""))
	if want == "":
		return false
	if type == "KILL_GROUP":
		# A group is any part of the same loot family: a wolf pack and a troll
		# pack are different groups, but both are "Grays".
		var fam_q := UnitDB.loot_family_of(want)
		var fam_k := UnitDB.loot_family_of(set_name)
		if fam_q == "" or fam_k == "":
			return set_name == want
		var sp_q := _species_of_set(want)
		var sp_k := _species_of_set(set_name)
		return fam_q == fam_k and sp_q == sp_k
	return set_name == want


## Set species without the tier tail: "monsters/wolf_t3" -> "wolf".
func _species_of_set(set_name: String) -> String:
	var short := set_name.get_file()
	var idx := short.rfind("_t")
	if idx > 0 and short.substr(idx + 2).is_valid_int():
		short = short.substr(0, idx)
	return short


## A quest target was picked up. Returns the quest id it belonged to, or "".
func notify_item_picked(item_key: String) -> String:
	for q in active:
		if str(q.get("type", "")) != "FIND_ITEM":
			continue
		if _bag_key(q) != item_key:
			continue
		var qid := str(q.get("id", ""))
		q["progress"] = maxi(int(q.get("progress", 0)), 1)
		_update_state(q)
		active_changed.emit()
		return qid
	return ""


## Sync progress with the inventory: gathering and delivery count what the
## hero actually holds (taken and then sold is not done).
## Meter progress of a found item follows the bag too: a relic sold instead of
## handed over is not found.
func _sync_progress(q: Dictionary) -> void:
	match str(q.get("type", "")):
		"GATHER":
			q["progress"] = count_item(str(q.get("item_key", "")))
		"DELIVER":
			q["progress"] = 1 if count_item(_bag_key(q)) > 0 else 0
		"FIND_ITEM":
			var found := count_item(_bag_key(q)) > 0 \
				or int(q.get("progress", 0)) > 0
			q["progress"] = 1 if found else 0


## The bag changes outside the quest system (a herb picked up, a herb sold),
## so gathering and delivery progress follows it every tick. The journal card
## must show what the hero really carries, not the count taken at accept time.
func _tick_inventory() -> void:
	sync_inventory()


## Brings every taken quest in line with the bag. The panel calls it before it
## builds the cards, so a count never waits for the next frame.
func sync_inventory() -> void:
	if Game.hero == null or not is_instance_valid(Game.hero):
		return
	var moved := false
	for q in active:
		var before := int(q.get("progress", 0))
		_sync_progress(q)
		if int(q.get("progress", 0)) != before:
			_update_state(q)
			moved = true
	if moved:
		active_changed.emit()


## The key the quest item lives under in the bag: a "Quest ..." copy for quests
## that hand or hide an item, the base key otherwise (gathering real herbs).
func _bag_key(q: Dictionary) -> String:
	var bag := str(q.get("bag_key", ""))
	return bag if bag != "" else str(q.get("item_key", ""))


func count_item(item_key: String) -> int:
	if item_key == "" or Game.hero == null or not is_instance_valid(Game.hero):
		return 0
	var n := 0
	for raw in Game.hero.inventory:
		if str(raw) == item_key:
			n += 1
	return n


func _update_state(q: Dictionary) -> void:
	if str(q.get("state", STATE_ACTIVE)) != STATE_ACTIVE:
		return
	if int(q.get("progress", 0)) >= int(q.get("need", 1)):
		q["state"] = STATE_READY
		refresh_markers()


## --- Map targets -------------------------------------------------------------

## Materialize a taken quest: a target elite walks onto the map, a found item
## becomes a pickup.
func _materialize(q: Dictionary) -> void:
	match str(q.get("type", "")):
		"KILL_TARGET":
			var cell := _spawn_cell(json_cell(q.get("target_cell", [])))
			if cell.x >= 0:
				q["target_cell"] = [cell.x, cell.y]
				_spawn_elite(q, cell)
		"FIND_ITEM":
			_spawn_pickup(q)


## The target leaves the map on turn-in/abandon: a pack leader must not stay
## behind as an ownerless elite.
func _dematerialize(q: Dictionary) -> void:
	var qid := str(q.get("id", ""))
	for e in Game.enemies.duplicate():
		if is_instance_valid(e) and str(e.get("quest_id")) == qid:
			Game.enemies.erase(e)
			e.queue_free()
	for t in targets.duplicate():
		if str(t.get("quest_id", "")) == qid:
			targets.erase(t)
			var node = t.get("node")
			if node != null and is_instance_valid(node):
				node.queue_free()


func json_cell(raw: Variant) -> Vector2i:
	if raw is Array and (raw as Array).size() >= 2:
		return Vector2i(int((raw as Array)[0]), int((raw as Array)[1]))
	return Vector2i(-1, -1)


## Cell for a target near the hero (within prep_min..prep_max cells).
func _spawn_cell(hint: Vector2i) -> Vector2i:
	var map: Node = get_tree().get_first_node_in_group("alm_map")
	if map == null or Game.hero == null or not is_instance_valid(Game.hero):
		return hint
	var tile := int(map.get("tile_size"))
	var mw := int(map.get("map_width"))
	var mh := int(map.get("map_height"))
	var hero_cell := Vector2i(int(Game.hero.global_position.x) / tile,
		int(Game.hero.global_position.y) / tile)
	var dmin := GameConfig.geti("quests", "prep_min_dist")
	var dmax := GameConfig.geti("quests", "prep_max_dist")
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%d|%s|prep" % [Game.map_seed, Game.map_zone])
	for _attempt in range(160):
		var ang := rng.randf() * TAU
		var dist := float(rng.randi_range(dmin, dmax))
		var cell := hero_cell + Vector2i(int(cos(ang) * dist), int(sin(ang) * dist))
		if cell.x < 2 or cell.y < 2 or cell.x >= mw - 2 or cell.y >= mh - 2:
			continue
		var pos := Vector2(float((cell.x + 0.5) * tile), float((cell.y + 0.5) * tile))
		if map != null and map.has_method("is_walkable_world"):
			if not bool(map.call("is_walkable_world", pos)):
				continue
		return cell
	return hint


## Target elite: a regular Gray of the set with the config boosts, bound to the
## quest (quest_id) so notify_killed counts it.
func _spawn_elite(q: Dictionary, cell: Vector2i) -> void:
	var map: Node = get_tree().get_first_node_in_group("alm_map")
	if map == null or not is_instance_valid(Game.hero):
		return
	var set_name := str(q.get("set", ""))
	if not UnitDB.has(set_name):
		return
	var tile := int(map.get("tile_size"))
	var pos := Vector2(float((cell.x + 0.5) * tile), float((cell.y + 0.5) * tile))
	var scene := get_parent()
	if scene == null:
		return
	var e := Enemy.new()
	e.name = "QuestElite_" + str(q.get("id", ""))
	e.anim_set = set_name
	e.position = pos
	e.home_position = pos
	e.max_hp = maxi(1, int(round(float(e.max_hp)
		* GameConfig.getf("quests", "kill_elite_hp_mult"))))
	e.damage = maxi(1, int(round(float(e.damage)
		* GameConfig.getf("quests", "kill_elite_dmg_mult"))))
	e.quest_id = str(q.get("id", ""))
	scene.add_child(e)
	Game.enemies.append(e)
	if map == null:
		return
	if map.has_method("watch_enemy"):
		map.call("watch_enemy", e)


## Search spot: a pickup on the map, counted when picked up.
func _spawn_pickup(q: Dictionary) -> void:
	var cell := json_cell(q.get("target_cell", []))
	if cell.x < 0:
		return
	var map: Node = get_tree().get_first_node_in_group("alm_map")
	if map == null:
		return
	var tile := int(map.get("tile_size"))
	var root: Node = get_parent()
	if root == null:
		return
	var node := QuestTarget.new()
	node.name = "QuestTarget_" + str(q.get("id", ""))
	node.item_key = _bag_key(q)
	node.icon = str(q.get("pick", ""))
	node.quest_id = str(q.get("id", ""))
	node.position = Vector2(float((cell.x + 0.5) * tile), float((cell.y + 0.5) * tile))
	root.add_child(node)
	node.picked.connect(_on_target_picked)
	targets.append({"quest_id": str(q.get("id", "")), "node": node, "cell": [cell.x, cell.y]})


func _on_target_picked(node: Node2D, item_key: String) -> void:
	for t in targets.duplicate():
		if t.get("node") == node:
			targets.erase(t)
	notify_item_picked(item_key)


## --- Urgent quest ------------------------------------------------------------

func _tick_urgent(delta: float) -> void:
	for q in active.duplicate():
		if str(q.get("type", "")) != "URGENT":
			continue
		if str(q.get("state", "")) == STATE_READY:
			continue
		q["seconds_left"] = float(q.get("seconds_left", 0.0)) - delta
		if float(q["seconds_left"]) > 0.0:
			continue
		q["state"] = STATE_FAILED
		active.erase(q)
		history.append(q)
		_take_issue_item(q)
		_dematerialize(q)
		active_changed.emit()
		quest_failed.emit(str(q.get("id", "")))


## --- Serialization -----------------------------------------------------------

func to_payload() -> Dictionary:
	var offs := {}
	for city_id in offers_by_city.keys():
		offs[str(city_id)] = (offers_by_city[city_id] as Array).duplicate(true)
	return {
		"seed": int(Game.map_seed), "zone": str(Game.map_zone),
		"sector": str(Game.map_sector),
		"offers": offs,
		"active": active.duplicate(true),
		"history": history.duplicate(true),
		"next_id": _next_id,
	}


func apply_payload(p: Dictionary) -> void:
	if p.is_empty():
		return
	offers_by_city.clear()
	active.clear()
	history.clear()
	targets.clear()
	var offs: Variant = p.get("offers", {})
	if offs is Dictionary:
		for city_id in (offs as Dictionary).keys():
			var list: Array[Dictionary] = []
			for raw in (offs[city_id] as Array):
				list.append((raw as Dictionary).duplicate(true))
			offers_by_city[str(city_id)] = list
	for raw in p.get("active", []):
		active.append((raw as Dictionary).duplicate(true))
	for raw in p.get("history", []):
		history.append((raw as Dictionary).duplicate(true))
	_next_id = maxi(1, int(p.get("next_id", 1)))
	_rotation_seed = int(p.get("seed", Game.map_seed))
	_rotation_sector = str(p.get("sector", Game.map_sector))
	# Elites and pickups are nodes, not data: rebuild them from the records.
	for q in active:
		_materialize(q)
	refresh_markers()


## Free the map nodes and return to the initial state (new game).
func reset() -> void:
	for q in active.duplicate():
		_dematerialize(q)
	offers_by_city.clear()
	active.clear()
	history.clear()
	targets.clear()
	_rotation_seed = -1
	_next_id = 1


## --- Tests -------------------------------------------------------------------

## Force an offer of a given template: deterministic smoke helper, not a game
## path.
func debug_add_offer(city_id: String, template_id: String) -> Dictionary:
	var tpl := QuestDB.template(template_id)
	if tpl.is_empty() or city_id == "":
		return {}
	var rev := _rotation_index(city_id)
	var rng := RandomNumberGenerator.new()
	# The id counter is part of the seed: the same forced offer asked again
	# (after an abandon) is a new quest, not a copy of the closed one.
	rng.seed = hash("%s|%s|%d|%d" % [city_id, template_id, rev, _next_id])
	var race := _city_race(city_id)
	var q := _make_quest(tpl, rng, city_id, race, 2, rev)
	if q.is_empty():
		return {}
	var list: Array = offers_by_city.get(_key(city_id), [])
	list.append(q)
	offers_by_city[_key(city_id)] = list
	offers_changed.emit(city_id)
	return q


## Force a rotation: next world day (data only, the world does not tick here).
func debug_rotate() -> void:
	for city_id in offers_by_city.keys():
		_regenerate(str(city_id))
