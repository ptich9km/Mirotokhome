extends Node
class_name EventSystem
## Динамические события на карте героя.
##
## Что это (11.11): на карте появляется **путник, которого бьют Серые**. Пока
## герой не подошёл, стая бьёт жертву; подошёл — вся стая переключается на него
## (правило D2: спасать не нужно попадать первым). Убил всех — золото, репутация
## ближайшего города, запись в журнал и в ленту мира, путник уходит в город и
## исчезает. Не успел — путник погибает, награды нет.
##
## Прежняя «стычка Серых против Серых» (19.10) больше не спавнится: два набора
## из одного пула, дерущиеся между собой, читались как баг (жалоба игрока 11.11).
## Код стычки оставлен ради regression-тестов и debug_spawn_event_at().
##
## Почему реальное время: день мира в живой игре не тикает (world_bus.gd,
## «сим-мир НЕ тикает»), поэтому TTL — секунды.
##
## Вне поля зрения героя бой тикает «дёшево»: раз в ABSTRACT_TICK сек стая
## бьёт путника половинным уроном через Game.deal_damage; он не отвечает.
## В поле зрения — обычный FSM enemy.gd с foe_group.

const ABSTRACT_TICK := 2.0        # сек между «дешёвыми» обменами ударами
const BATTLE_RADIUS_PX := 600.0   # радиус поиска противника в стычке
const GROUP_GAP_CELLS := 4        # клетки между центрами групп
## Traveler set: the rescued NPC. Built by tests/gen_hero_strip.py --class
## traveler and cut by extract_hero_nb.py --tag tv1 --dest npc.
const VICTIM_SET := "npc/traveler_m"
## The world feed is a RefCounted helper script, not an autoload (see game.gd).
const WORLD_FEED := preload("res://scripts/world/world_feed.gd")

static var instance: EventSystem = null

var _events: Array[Dictionary] = []   # активные события текущей карты
## Freed members of a clash. An Enemy is unregistered here the moment it dies
## or leaves the tree: dropping an event on the first dead member would strip
## the tags of the survivors, and every lookup over a freed node is a risk.
var _gone: Array = []
var _spawn_accum := 0.0
var _abstract_accum := 0.0
var _map_key := ""                    # "seed:zone:w:h" текущей карты
var _next_event_id := 1

## Counter of dead enemies. Enemy nodes call it whenever a member leaves the
## fight (takes the killing blow, a corpse rots away, a fleeing one despawns),
## so no signal argument is involved: Godot casts signal arguments to the
## declared types, and a freed Object cannot be cast to Enemy.
static func note_freed() -> void:
	if instance != null and is_instance_valid(instance):
		instance._gone.append(true)
		if instance._gone.size() > 512:
			instance._gone.clear()

func _ready() -> void:
	add_to_group("events")
	instance = self
	if MinimapMarkers.instance == null:
		MinimapMarkers.new()
	tree_exiting.connect(_on_exiting)

func _on_exiting() -> void:
	if instance == self:
		instance = null

func _process(delta: float) -> void:
	if not Game.perf_enabled:
		_process_impl(delta)
		return
	var t0 := Time.get_ticks_usec()
	_process_impl(delta)
	Game.perf_end("events", t0)


func _process_impl(delta: float) -> void:
	if GameConfig.geti("events", "enabled") == 0:
		return
	_check_map_changed()
	if MinimapMarkers.instance != null:
		MinimapMarkers.instance.tick_life(delta)
	# Жизнь событий (TTL в реальных секундах).
	for ev in _events.duplicate():
		ev["ttl_left"] = float(ev["ttl_left"]) - delta
		if float(ev["ttl_left"]) <= 0.0:
			_expire_event(ev)
	_check_rescue_state()
	# Абстрактное разрешение боёв вне видимости героя.
	_abstract_accum += delta
	if _abstract_accum >= ABSTRACT_TICK:
		_abstract_accum = 0.0
		_abstract_tick()
	# Спавн новых событий.
	_spawn_accum += delta
	var period := GameConfig.getf("events", "spawn_period")
	if period <= 0.0 or _spawn_accum < period:
		return
	_spawn_accum = 0.0
	if randi() % 100 >= GameConfig.geti("events", "spawn_chance"):
		return
	_try_spawn_event()

## Смена карты (портал): локальные события и маркеры обнуляются; сейв
## хранит события отдельно и материализует их на нужной карте.
func _check_map_changed() -> void:
	var map: Node = get_tree().get_first_node_in_group("alm_map")
	if map == null:
		return
	var key := "%d:%s:%s:%d:%d" % [Game.map_seed, Game.map_zone, Game.map_sector,
		int(map.get("map_width")), int(map.get("map_height"))]
	if key == _map_key:
		return
	_map_key = key
	for ev in _events:
		_free_event_units(ev)
	_events.clear()
	if MinimapMarkers.instance != null:
		MinimapMarkers.instance.clear_all()
	# События из сейва (19.10): материализуются один раз для этой карты.
	if Game.pending_events.size() > 0:
		if GameConfig.geti("events", "enabled") != 0:
			apply_payload(Game.pending_events)
		Game.pending_events = []

## Попытка заспавнить событие. Возвращает id события или 0.
##
## Спавнится только «спасти путника»: старая стычка двух наборов Серых больше
## не появляется (решение 11.11), её код оставлен для тестов и отладки.
func _try_spawn_event() -> int:
	if _events.size() >= GameConfig.geti("events", "max_active"):
		return 0
	var map: Node = get_tree().get_first_node_in_group("alm_map")
	if map == null or Game.hero == null or not is_instance_valid(Game.hero):
		return 0
	var cell := _event_cell(map)
	if cell.x < 0:
		return 0
	return spawn_rescue_at(cell)


## Заспавнить «спасти путника» в заданной клетке. Возвращает id события или 0.
## Используется и спавном, и smoke-тестом (детерминизм).
func spawn_rescue_at(cell: Vector2i) -> int:
	var map: Node = get_tree().get_first_node_in_group("alm_map")
	if map == null or cell.x < 0:
		return 0
	var pool: Array = MapGenerator.gray_pool_for_zone(Game.map_zone)
	if pool.is_empty():
		return 0
	var set_name := str(pool[randi() % pool.size()])
	var tile := int(map.get("tile_size"))
	# The traveller stands beside the pack, not under it: otherwise the Greys
	# would be spawned inside his body and the first frame would already be a hit.
	var victim_cell := cell + Vector2i(GROUP_GAP_CELLS, 0)
	if not _cell_free(map, victim_cell):
		victim_cell = cell
	var ttl := randf_range(GameConfig.getf("events", "ttl_seconds_min"),
		GameConfig.getf("events", "ttl_seconds_max"))
	var ev := {
		"id": _next_event_id, "kind": "rescue",
		"cell_x": cell.x, "cell_y": cell.y,
		"ttl_left": ttl,
		"tag_a": "ev%d_mob" % _next_event_id,
		"tag_v": "ev%d_victim" % _next_event_id,
		"set_a": set_name, "set_b": "",
		"members_a": [], "members_v": [],
		"victim": null,
	}
	_next_event_id += 1
	_spawn_victim(map, ev, victim_cell)
	if ev["victim"] == null:
		return 0
	_spawn_group(map, ev, "a", set_name, cell, 0, str(ev["tag_v"]))
	if (ev["members_a"] as Array).is_empty():
		_free_event_units(ev)
		return 0
	_events.append(ev)
	_attach_marker(ev, ttl, MinimapMarkers.Kind.QUEST_RESCUE)
	print("EVENT: traveller and %d Grey at (%d,%d), %.0f s" % [
		(ev["members_a"] as Array).size(), cell.x, cell.y, ttl])
	return int(ev["id"])


## The traveller: a peaceful Npc that takes damage and dies, but never answers.
func _spawn_victim(map: Node, ev: Dictionary, cell: Vector2i) -> void:
	var tile := int(map.get("tile_size"))
	var pos := Vector2(float((cell.x + 0.5) * tile), float((cell.y + 0.5) * tile))
	if not bool(map.call("is_walkable_world", pos)):
		return
	var n := Npc.new()
	n.name = "EventVictim"
	n.anim_set = VICTIM_SET
	n.role = "victim"
	n.max_hp = maxi(1, GameConfig.geti("events", "rescue_victim_hp"))
	n.damage = 0
	n.is_patrol = false
	n.position = pos
	n.home = pos
	n.event_tag = str(ev["tag_v"])
	var host := get_parent()
	if host == null:
		host = get_tree().current_scene
	if host == null:
		n.queue_free()
		return
	host.add_child(n)
	Game.npcs.append(n)
	ev["victim"] = n
	ev["members_v"].append(n)
	if not n.tree_exited.is_connected(_note_tree_exited):
		n.tree_exited.connect(_note_tree_exited)

func _new_event(cell: Vector2i, set_a: String, set_b: String, ttl: float) -> Dictionary:
	var ev := {
		"id": _next_event_id, "kind": "battle",
		"cell_x": cell.x, "cell_y": cell.y,
		"ttl_left": ttl,
		"tag_a": "ev%d_a" % _next_event_id,
		"tag_b": "ev%d_b" % _next_event_id,
		"set_a": set_a, "set_b": set_b,
		"members_a": [], "members_b": [],
	}
	_next_event_id += 1
	return ev

func _attach_marker(ev: Dictionary, ttl: float,
		kind: int = MinimapMarkers.Kind.BATTLE) -> void:
	if MinimapMarkers.instance == null:
		return
	var cell := Vector2i(int(ev["cell_x"]), int(ev["cell_y"]))
	ev["marker_id"] = MinimapMarkers.instance.add(kind,
		cell, ttl, Game.map_seed, Game.map_zone, Game.map_sector)

## Клетка события: проходимая, 400-900 px от героя, вне городов (структур).
func _event_cell(map: Node) -> Vector2i:
	var tile := int(map.get("tile_size"))
	var mw := int(map.get("map_width"))
	var mh := int(map.get("map_height"))
	if mw <= 0 or mh <= 0:
		return Vector2i(-1, -1)
	var hero_cell := Vector2i(
		int(int(Game.hero.global_position.x) / float(tile)),
		int(int(Game.hero.global_position.y) / float(tile)))
	var dmin := int(GameConfig.geti("events", "spawn_min_dist") / float(tile))
	var dmax := int(GameConfig.geti("events", "spawn_max_dist") / float(tile))
	for _attempt in range(120):
		var ang := randf() * TAU
		var dist := float(randi_range(dmin, dmax))
		var cell := hero_cell + Vector2i(int(cos(ang) * dist), int(sin(ang) * dist))
		if cell.x < 2 or cell.y < 2 or cell.x >= mw - 2 or cell.y >= mh - 2:
			continue
		if not _cell_free(map, cell):
			continue
		return cell
	return Vector2i(-1, -1)

## Клетка свободна: проходима и в радиусе 2 клеток нет зданий (не город).
func _cell_free(map: Node, cell: Vector2i) -> bool:
	var tile := int(map.get("tile_size"))
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			var c := cell + Vector2i(dx, dy)
			var pos := Vector2(float((c.x + 0.5) * tile), float((c.y + 0.5) * tile))
			if not bool(map.call("is_walkable_world", pos)):
				return false
			if map.has_method("structure_at") \
					and not (map.call("structure_at", c) as Dictionary).is_empty():
				return false
	return true
## Пара наборов для стычки: сначала разные семейства (loot_family), затем
## разные виды (имя без "_tN"), иначе любые два разных набора пула.
func _pick_event_sets(pool: Array) -> Array:
	var by_family := {}
	var by_species := {}
	for s in pool:
		var nm := str(s)
		if not UnitDB.has(nm):
			continue
		var fam := UnitDB.loot_family(nm)
		if fam == "":
			fam = "default"
		if not by_family.has(fam):
			by_family[fam] = nm
		var species := nm
		var idx := nm.rfind("_t")
		if idx > 0:
			var tail := nm.substr(idx + 2)
			var digits := true
			for ch in tail:
				if not (ch >= "0" and ch <= "9"):
					digits = false
					break
			if digits:
				species = nm.substr(0, idx)
		if not by_species.has(species):
			by_species[species] = nm
	if by_family.size() >= 2:
		var keys: Array = by_family.keys()
		return [str(by_family[keys[0]]), str(by_family[keys[1]])]
	if by_species.size() >= 2:
		var keys2: Array = by_species.keys()
		return [str(by_species[keys2[0]]), str(by_species[keys2[1]])]
	if pool.size() >= 2:
		return [str(pool[0]), str(pool[1])]
	return []

## Спавн группы стычки: центр группы = cell со сдвигом side_dir клеток.
## foe_tag_override задаёт противника (в «спасти путника» это жертва, а не
## вторая группа).
func _spawn_group(map: Node, ev: Dictionary, side: String, set_name: String,
		center: Vector2i, side_dir: int, foe_tag_override: String = "") -> void:
	var tile := int(map.get("tile_size"))
	var my_tag := str(ev["tag_" + side])
	var other := "b" if side == "a" else "a"
	var foe_tag := foe_tag_override
	if foe_tag == "":
		foe_tag = str(ev["tag_" + other])
	var placed: Array = ev["members_" + side]
	var count := randi_range(GameConfig.geti("events", "members_min"),
		GameConfig.geti("events", "members_max"))
	var mults: Array = MapGenerator.gray_tier_mults(set_name)
	for _k in range(count):
		# Several attempts per member: the first version took exactly one offset and
		# silently dropped the member when that cell was water/mountain. An
		# encounter with one Grey instead of three was unlosable, and with zero it
		# never appeared at all (found by rescue_event_smoke).
		var pos := Vector2.ZERO
		var found := false
		for _attempt in range(16):
			var off := Vector2i(randi_range(-2, 2), randi_range(-2, 2))
			if _attempt < 8 and side_dir != 0:
				off = Vector2i(side_dir * randi_range(1, 2), randi_range(-2, 2))
			var c := center + off
			var p := Vector2(float((c.x + 0.5) * tile), float((c.y + 0.5) * tile))
			if bool(map.call("is_walkable_world", p)):
				pos = p
				found = true
				break
		if not found:
			continue
		var e := Enemy.new()
		e.name = "EventMonster_%s" % set_name.get_file()
		e.anim_set = set_name
		e.max_hp = int(round(float(randi_range(
			GameConfig.geti("grey", "hp_min"),
			GameConfig.geti("grey", "hp_max"))) * float(mults[0])))
		e.damage = int(round(float(randi_range(
			GameConfig.geti("grey", "damage_min"),
			GameConfig.geti("grey", "damage_max"))) * float(mults[1])))
		e.position = pos
		e.home_position = pos
		e.event_tag = my_tag
		e.foe_group = foe_tag
		var host := get_parent()
		if host == null:
			host = get_tree().current_scene
		if host == null:
			e.queue_free()
			continue
		host.add_child(e)
		# As close to the enemy as possible: one that leaves the tree by another
		# path must report it too, or a clash with him never closes.
		if not e.tree_exited.is_connected(_note_tree_exited):
			e.tree_exited.connect(_note_tree_exited)
		Game.enemies.append(e)
		placed.append(e)

func _note_tree_exited() -> void:
	note_freed()

## Clash foes (called from Enemy._combat_target).
static func foe_for(e: Node2D) -> Node2D:
	if instance == null:
		return null
	return instance._foe_for(e)

## Ищет среди участников всех событий того, чей event_tag равен foe_group
## спрашивающего. Так работает и стычка (две группы), и спасение (стая + путник).
func _foe_for(e: Node2D) -> Node2D:
	var want := str(e.get("foe_group"))
	if want == "":
		return null
	var best: Node2D = null
	var bd := BATTLE_RADIUS_PX
	for ev in _events:
		for key in ["members_a", "members_b", "members_v"]:
			for o in _alive_in(ev, key):
				if str(o.get("event_tag")) != want:
					continue
				if o.state == "dying" or o.state == "decay" or o.state == "corpse":
					continue
				var d := Game.units_range(e, o)
				if d < bd:
					bd = d
					best = o
	return best

## «Дешёвое» разрешение боёв вне поля зрения героя.
func _abstract_tick() -> void:
	_check_gone()
	var fog: Node = get_tree().get_first_node_in_group("fog")
	for ev in _events.duplicate():
		var pos := Vector2(float(int(ev["cell_x"]) + 1) * 16.0,
			float(int(ev["cell_y"]) + 1) * 16.0)
		var visible_now := false
		if fog != null and bool(fog.get("enabled")) \
				and int(fog.call("state_at_world", pos)) == FogOfWar.STATE_VISIBLE:
			visible_now = true
		if visible_now:
			continue   # бой на глазах у игрока — рулит настоящий FSM
		if str(ev.get("kind", "")) == "rescue":
			# Off screen the pack keeps beating the traveller; he never answers.
			var mob: Node2D = _first_alive(ev, "members_a")
			var victim: Node2D = _first_alive(ev, "members_v")
			if mob == null or victim == null:
				continue    # _check_rescue_state closes it on the next frame
			var per_hit := float(int(mob.get("damage"))) * 0.5
			per_hit *= GameConfig.getf("events", "rescue_victim_dmg_scale")
			Game.deal_damage(victim, maxi(1, int(round(per_hit))), "physical", "", mob)
			continue
		var a: Enemy = _first_alive(ev, "members_a") as Enemy
		var b: Enemy = _first_alive(ev, "members_b") as Enemy
		if a == null or b == null:
			_finish_event(ev)
			continue
		var dmg_a := maxi(1, int(round(float(a.damage) * 0.5)))
		var dmg_b := maxi(1, int(round(float(b.damage) * 0.5)))
		Game.deal_damage(b, dmg_a, "physical", "", a)
		Game.deal_damage(a, dmg_b, "physical", "", b)
		if _first_alive(ev, "members_a") == null or _first_alive(ev, "members_b") == null:
			_finish_event(ev)

## Судьба путника решается здесь: стая мертва — спасён; путник упал или исчез —
## событие провалено. Одна проверка на кадр на активное событие.
func _check_rescue_state() -> void:
	for ev in _events.duplicate():
		if str(ev.get("kind", "")) != "rescue":
			continue
		var victim: Node2D = _first_alive(ev, "members_v")
		if victim == null:
			_finish_rescue(ev, false)
			continue
		if _first_alive(ev, "members_a") == null:
			_finish_rescue(ev, true)

## Clash participants that have left the fight since the previous tick. The
## counter is cleared here, not after resolving a clash: frees of the current
## frame count too.
func _check_gone() -> void:
	var n := _gone.size()
	_gone.clear()
	if n <= 0:
		return
	for ev in _events.duplicate():
		# The same rule as in _abstract_tick: a standing corpse looks for no foe,
		# so the tags come off the survivors and the clash is closed. Rescue
		# events have a single mob side and are closed by _check_rescue_state.
		if str(ev.get("kind", "")) == "rescue":
			continue
		if _first_alive(ev, "members_a") == null or _first_alive(ev, "members_b") == null:
			_finish_event(ev)

func _first_alive(ev: Dictionary, key: String) -> Node2D:
	var best: Node2D = null
	for e in _alive_in(ev, key):
		if e.state != "dying" and e.state != "decay" and e.state != "corpse":
			best = e
			break
	return best

## Members of a side that have not been freed. A cast of a freed instance
## raises, so is_instance_valid() runs first: it takes a Variant and is safe
## for freed nodes. Both Enemy and Npc live here (the traveller is an Npc).
func _alive_in(ev: Dictionary, key: String) -> Array:
	var out: Array = []
	if not ev.has(key):
		return out
	for u in ev[key]:
		if not is_instance_valid(u):
			continue
		var n: Node2D = u as Node2D
		if n != null:
			out.append(n)
	return out

## A clash is over: the survivors go back to being ordinary Greys.
func _finish_event(ev: Dictionary) -> void:
	_clear_tags(ev)
	_remove_marker(ev)
	_events.erase(ev)
	print("EVENT: encounter %d finished" % int(ev["id"]))

func _clear_tags(ev: Dictionary) -> void:
	for key in ["members_a", "members_b", "members_v"]:
		for e in _alive_in(ev, key):
			e.set("event_tag", "")
			e.set("foe_group", "")

## Time ran out: survivors despawn without loot. For a rescue this is a failure:
## the traveller is killed off screen and the reward is lost.
func _expire_event(ev: Dictionary) -> void:
	if str(ev.get("kind", "")) == "rescue":
		_finish_rescue(ev, false, "time ran out")
		return
	_free_event_units(ev)
	_remove_marker(ev)
	_events.erase(ev)
	print("EVENT: encounter %d expired by time" % int(ev["id"]))

func _free_event_units(ev: Dictionary) -> void:
	for key in ["members_a", "members_b"]:
		for e in _alive_in(ev, key):
			Game.enemies.erase(e)
			e.queue_free()
	for v in _alive_in(ev, "members_v"):
		Game.npcs.erase(v)
		v.queue_free()

## Конец спасения: награда или провал, маркер снят, теги сняты с уцелевших.
func _finish_rescue(ev: Dictionary, saved: bool, reason: String = "") -> void:
	if _events.has(ev) == false:
		return
	var victim: Node2D = _first_alive(ev, "members_v")
	# The Greys left standing are ordinary Greys again (they just stop being part
	# of the event); the dead ones are already corpses.
	_clear_tags(ev)
	_remove_marker(ev)
	_events.erase(ev)
	if saved:
		_reward_rescue(ev, victim)
		if victim != null:
			_leave_for_city(victim, ev)
		print("EVENT: traveller saved")
		return
	# Failure: the traveller dies where he stands. A live one is finished off by
	# the event itself (the mobs may already be gone).
	if victim != null:
		_clear_tags(ev)
		victim.call("take_damage", int(victim.get("current_hp")) + 1, null)
	print("EVENT: traveller died (%s)" % (reason if reason != "" else "too late"))

## Золото, репутация ближайшего города и запись в журнал/ленту мира.
func _reward_rescue(ev: Dictionary, victim: Node2D) -> void:
	var gold := randi_range(GameConfig.geti("events", "rescue_gold_min"),
		GameConfig.geti("events", "rescue_gold_max"))
	if Game.hero != null and is_instance_valid(Game.hero) and Game.hero.has_method("add_gold"):
		Game.hero.call("add_gold", gold)
	var city := _nearest_city(ev)
	var race := str(city.get("race", ""))
	var rep := GameConfig.geti("events", "rescue_rep")
	var st = _world_state()
	if st != null:
		if race != "" and rep != 0:
			st.add_hero_reputation(race, rep)
		st.log_entry("event", "Traveller saved near %s: +%d gold" % [
			str(city.get("name", city.get("id", "the road"))), gold])
	WORLD_FEED.post("world", Loc.f("ui.feed.rescue", [gold]))
	SoundDB.play("ui.click")

## Ближайший к событию город (для репутации и ухода путника).
func _nearest_city(ev: Dictionary) -> Dictionary:
	var map: Node = get_tree().get_first_node_in_group("alm_map")
	if map == null or not map.has_method("get_cities"):
		return {}
	var cities: Array = map.call("get_cities")
	var best: Dictionary = {}
	var bd := INF
	var here := Vector2i(int(ev["cell_x"]), int(ev["cell_y"]))
	for c in cities:
		var d := float((Vector2i(int(c.get("x", 0)), int(c.get("y", 0))) - here).length_squared())
		if d < bd:
			bd = d
			best = c
	return best

## Спасённый уходит в ближайший город и исчезает (решение игрока 11.11).
func _leave_for_city(victim: Node2D, ev: Dictionary) -> void:
	var map: Node = get_tree().get_first_node_in_group("alm_map")
	if map == null or not victim.has_method("leave_to"):
		return
	var tile := int(map.get("tile_size"))
	var city := _nearest_city(ev)
	var cell := Vector2i(int(city.get("x", ev["cell_x"])), int(city.get("y", ev["cell_y"])))
	var pos := Vector2(float((cell.x + 0.5) * tile), float((cell.y + 0.5) * tile))
	victim.call("leave_to", pos)

func _world_state():
	var bus := get_node_or_null("/root/WorldBus")
	if bus == null or not ("state" in bus):
		return null
	return bus.state

func _remove_marker(ev: Dictionary) -> void:
	if MinimapMarkers.instance != null and ev.has("marker_id"):
		MinimapMarkers.instance.remove(int(ev["marker_id"]))

## --- Сериализация (save_system.gd, payload.events) ------------------------

## Активные события в JSON-виде. Узлы не сериализуемы — только данные.
func to_payload() -> Array:
	var out: Array = []
	for ev in _events:
		var victim = ev.get("victim")
		var hp := 0
		if victim != null and is_instance_valid(victim):
			hp = int(victim.get("current_hp"))
		out.append({
			"kind": str(ev["kind"]),
			"cell_x": int(ev["cell_x"]), "cell_y": int(ev["cell_y"]),
			"ttl_left": float(ev["ttl_left"]),
			"set_a": str(ev["set_a"]), "set_b": str(ev["set_b"]),
			"victim_hp": hp,
			"seed": int(Game.map_seed), "zone": str(Game.map_zone),
			"sector": str(Game.map_sector),
		})
	return out

## Материализовать события из сейва (только те, что для текущей карты).
func apply_payload(list: Array) -> void:
	for d in list:
		var rec: Dictionary = d as Dictionary
		if int(rec.get("seed", -1)) != Game.map_seed \
				or str(rec.get("zone", "")) != Game.map_zone \
				or str(rec.get("sector", "")) != Game.map_sector:
			continue
		_respawn_event(rec)

func _respawn_event(rec: Dictionary) -> void:
	var map: Node = get_tree().get_first_node_in_group("alm_map")
	if map == null:
		return
	var cell := Vector2i(int(rec.get("cell_x", -1)), int(rec.get("cell_y", -1)))
	var set_a := str(rec.get("set_a", ""))
	var set_b := str(rec.get("set_b", ""))
	if cell.x < 0:
		return
	if str(rec.get("kind", "")) == "rescue":
		# The traveller keeps the health he had when the game was saved: a reload
		# must not heal him back to full.
		var id := spawn_rescue_at(cell)
		if id == 0:
			return
		var ev: Dictionary = _events[_events.size() - 1]
		var victim = ev.get("victim")
		if victim != null and is_instance_valid(victim):
			var hp := int(rec.get("victim_hp", 0))
			if hp > 0:
				victim.set("current_hp", mini(hp, int(victim.get("max_hp"))))
		ev["ttl_left"] = maxf(10.0, float(rec.get("ttl_left", 90.0)))
		return
	if set_a == "" or set_b == "" or not UnitDB.has(set_a) or not UnitDB.has(set_b):
		return
	var ttl := maxf(10.0, float(rec.get("ttl_left", 90.0)))
	var ev2 := _new_event(cell, set_a, set_b, ttl)
	_spawn_group(map, ev2, "a", set_a, cell, -1)
	_spawn_group(map, ev2, "b", set_b, cell, 1)
	if (ev2["members_a"] as Array).is_empty() or (ev2["members_b"] as Array).is_empty():
		_free_event_units(ev2)
		return
	_events.append(ev2)
	_attach_marker(ev2, ttl)

## --- Тесты -----------------------------------------------------------------

## Форс-спавн события в заданной клетке (детерминизм в смоке). Возвращает id.
func debug_spawn_event_at(cell: Vector2i, set_a: String, set_b: String) -> int:
	var map: Node = get_tree().get_first_node_in_group("alm_map")
	if map == null or set_a == "" or set_b == "" \
			or not UnitDB.has(set_a) or not UnitDB.has(set_b):
		return 0
	var ttl := GameConfig.getf("events", "ttl_seconds_max")
	var ev := _new_event(cell, set_a, set_b, ttl)
	_spawn_group(map, ev, "a", set_a, cell, -1)
	_spawn_group(map, ev, "b", set_b, cell, 1)
	if (ev["members_a"] as Array).is_empty() or (ev["members_b"] as Array).is_empty():
		_free_event_units(ev)
		return 0
	_events.append(ev)
	_attach_marker(ev, ttl)
	return int(ev["id"])

## Тестовый хук: немедленно истечить все события.
func debug_expire_all() -> void:
	for ev in _events.duplicate():
		_expire_event(ev)

func event_count() -> int:
	return _events.size()
