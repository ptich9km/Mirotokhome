extends SceneTree
## Teleport network (25.11): discovery record, reputation gate, price ladder,
## save round-trip, and the master panel states (here / reachable / locked).
##
## Player decision 25.11: fast travel WoW-style between visited cities through a
## teleport master NPC; a destination whose race hates the hero
## (reputation < Game.TELEPORT_REP_MIN) is shown but refused.
##
## Run: godot --headless --path . --script res://tests/teleport_smoke.gd

var _fails: Array[String] = []
var _checks := 0
var _ran := false
var _done := false


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
		print("TELEPORT: FAIL %s" % what)
	else:
		print("TELEPORT: ok   %s" % what)


## Returning true ends the SceneTree main loop — but _run awaits frames (panel
## build), so the loop must stay alive until _finish sets _done.
func _process(_delta: float) -> bool:
	if _done:
		return true
	if _ran:
		return false
	_ran = true
	_run()
	return false


func _bus():
	var bus = root.get_node_or_null("WorldBus")
	if bus != null and bus.state == null and bus.has_method("reseed"):
		bus.reseed()
	return bus


func _run() -> void:
	var wm = load("res://scripts/world/world_map.gd")
	var ids: Array = wm.ids()
	if ids.size() < 2:
		print("TELEPORT: SKIP (world map has <2 sectors)")
		_finish()
		return
	var sec_a := str(ids[0])
	var sec_b := str(ids[ids.size() - 1])
	# Adjacent pair for the price ladder.
	var sec_n := ""
	for sid in ids:
		var ns: Array = wm.neighbors(str(sid))
		if not ns.is_empty():
			sec_a = str(sid)
			sec_n = str(ns[0])
			break

	# 1. Key scheme matches the outpost one: zone|sector|seed|id.
	var key := Game.city_visit_key("start", sec_a, 4242, "c0t0")
	_check(key == "start|%s|4242|c0t0" % sec_a, "ключ города zone|sector|seed|city_id")

	# 2. Price ladder: same sector < neighbour < far sector, all positive.
	var cost_same := Game.teleport_cost_between(sec_a, sec_a)
	var cost_near := Game.teleport_cost_between(sec_a, sec_n)
	var cost_far := Game.teleport_cost_between(sec_a, sec_b)
	_check(cost_same == Game.TELEPORT_COST_SAME, "цена в свой же сектор = %d" % cost_same)
	_check(cost_near == Game.TELEPORT_COST_BASE + Game.TELEPORT_COST_STEP,
		"цена соседнему сектору = база+шаг (%d)" % cost_near)
	_check(cost_far > cost_near, "далёкий сектор дороже соседнего (%d > %d)" % [cost_far, cost_near])

	# 3. Discovery record: idempotent, fields travel intact.
	Game.visited_cities.clear()
	var rec := {
		"city_id": "c0t0", "name": "Ветреный", "race": "ork",
		"sector": sec_a, "tier": "start", "seed": 4242, "world_seed": 777,
		"cell": [10, 12],
	}
	_check(Game.discover_city_record(rec), "первый визит записывает город")
	_check(not Game.discover_city_record(rec), "повторный визит не дублирует запись")
	_check(Game.visited_cities.has(key), "запись лежит под вычисленным ключом")
	_check(str(Game.visited_cities[key].get("name", "")) == "Ветреный",
		"имя города хранится в записи")

	# 4. Reputation gate: -15 and above is passable, below is locked;
	#    the current city always answers "here" regardless of reputation.
	var bus = _bus()
	if bus == null or bus.state == null:
		print("TELEPORT: SKIP (no WorldBus)")
	else:
		bus.state.hero_reputation["ork"] = Game.TELEPORT_REP_MIN
		_check(Game.teleport_gate(rec, "") == "", "репутация ровно -15 пропускает")
		bus.state.hero_reputation["ork"] = Game.TELEPORT_REP_MIN - 1
		_check(Game.teleport_gate(rec, "") == "rep",
			"репутация ниже -15 блокирует (причина 'rep')")
		_check(Game.teleport_gate(rec, key) == "here",
			"текущий город отвечает 'here' даже при низкой репутации")
		bus.state.hero_reputation["ork"] = 0

	# 5. Save round-trip: the network travels in the map payload.
	var player = Player.new()
	Game.map_seed = 4242
	Game.map_zone = "start"
	Game.map_sector = sec_a
	var payload := SaveSystem.build_payload(player, {})
	var saved: Variant = payload.get("map", {}).get("visited_cities", {})
	_check(saved is Dictionary and (saved as Dictionary).has(key),
		"build_payload кладёт visited_cities в map-секцию")
	Game.visited_cities.clear()
	SaveSystem.apply_payload(payload, player)
	_check(Game.visited_cities.has(key)
		and str(Game.visited_cities[key].get("name", "")) == "Ветреный",
		"apply_payload восстанавливает сеть телепортации")
	player.free()

	# 6. Panel: three rows — current (disabled), reachable (priced), locked (rep).
	Game.visited_cities.clear()
	Game.discover_city_record(rec)                       # current city (same key)
	var far := rec.duplicate()
	far["city_id"] = "c1t0"
	far["sector"] = sec_n
	far["name"] = "Каменный"
	Game.discover_city_record(far)
	var locked := rec.duplicate()
	locked["city_id"] = "c2t0"
	locked["sector"] = sec_b
	locked["race"] = "necro"
	Game.discover_city_record(locked)
	if bus != null and bus.state != null:
		bus.state.hero_reputation["necro"] = Game.TELEPORT_REP_MIN - 5
	var panel := TeleportPanel.new()
	panel.setup(null, "c0t0")
	root.add_child(panel)
	await process_frame
	await process_frame
	var list := panel._list
	_check(list.get_child_count() == 3, "в списке три записанных города (%d)" % list.get_child_count())
	var row0: PanelContainer = list.get_node_or_null("Row0") as PanelContainer
	if row0 != null:
		_check((row0.get_node("Row/Go") as Button).disabled
			and (row0.get_node("Row/Texts/Status") as Label).text == Loc.t("ui.teleport.here"),
			"текущий город: кнопка выключена, статус 'Вы здесь'")
	var row2: PanelContainer = list.get_node_or_null("Row2") as PanelContainer
	if row2 != null:
		_check((row2.get_node("Row/Go") as Button).disabled
			and (row2.get_node("Row/Texts/Status") as Label).text == Loc.t("ui.teleport.locked_rep"),
			"враждебный город: кнопка выключена, статус про репутацию")
	panel.close()
	panel.queue_free()

	# 7. Master art: the set is in the base, on disk, and follows the city
	#    NPC contract (8 frames, 52x64, cx 26 cy 62, no attack/die blocks).
	UnitDB.ensure_loaded()
	_check(UnitDB.has("city_teleport_master/t0"),
		"набор city_teleport_master/t0 есть в базе юнитов")
	if UnitDB.has("city_teleport_master/t0"):
		var info := UnitDB.get_set("city_teleport_master/t0")
		_check(int(info.get("frames", 0)) == 8 and int(info.get("dirs", 0)) == 8,
			"контракт 8 кадров / 8 направлений")
		_check(int(info.get("w", 0)) == 52 and int(info.get("h", 0)) == 64
			and int(info.get("cx", 0)) == 26 and int(info.get("cy", 0)) == 62,
			"геометрия городского набора 52x64, пивот 26/62")
		_check(UnitDB.attack_phases("city_teleport_master/t0") == 0
			and UnitDB.dying_phases("city_teleport_master/t0") == 0,
			"у мастера нет блоков удара и смерти")
		var frames_ok := true
		for i in range(1, 9):
			if not FileAccess.file_exists("res://assets/units/city_teleport_master/t0/sprites-%03d.png" % i):
				frames_ok = false
		_check(frames_ok, "все 8 кадров на диске")

	_finish()


func _finish() -> void:
	_done = true
	Game.visited_cities.clear()
	if _fails.is_empty():
		print("RESULT: OK (%d checks)" % _checks)
	else:
		print("RESULT: FAIL (%d/%d failed)" % [_fails.size(), _checks])
		for f in _fails:
			print("  - %s" % f)
	quit(0 if _fails.is_empty() else 1)
