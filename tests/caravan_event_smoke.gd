extends SceneTree
## Караван на карте (19.11).
##
## Что проверяется:
## 1. Караван спавнится: торговец (Npc, роль victim) + тележка со слитками.
## 2. Стая Серых целится в торговца, а не в героя (как в «спасти путника»).
## 3. Маркер события — BATTLE.
## 4. Спасён: герой получает слитки (2–5 по конфигу), журнал растёт, тележка
##    убрана из мира.
## 5. Провал: торговец погиб — слитков нет, тележка тоже убрана.
## 6. Сейв: to_payload/apply_payload возвращают караван с тележкой.
##
## Запуск: godot --headless --path . --script res://tests/caravan_event_smoke.gd

var _checks := 0
var _fails: Array[String] = []
var _done := false
var _es: EventSystem = null
var _map: Node = null
var _hero: Player = null
var _cell := Vector2i.ZERO


func _init() -> void:
	var watchdog := create_timer(150.0)
	watchdog.timeout.connect(_force_quit)
	call_deferred("_run")


func _force_quit() -> void:
	if _done:
		return
	_done = true
	print("  FAIL тест не завершился за 150 с")
	print("RESULT: FAIL caravan_event_smoke (таймаут)")
	quit(1)


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
	print(("  OK  " if ok else "  FAIL") + " " + msg)


func _victims() -> Array:
	var out: Array = []
	for n in Game.npcs:
		if n != null and is_instance_valid(n) and n is Npc \
				and str((n as Npc).role) == "victim":
			out.append(n)
	return out


func _tagged_mobs() -> Array:
	var out: Array = []
	for e in Game.enemies:
		if e != null and is_instance_valid(e) and e is Enemy \
				and str((e as Enemy).event_tag) != "":
			out.append(e)
	return out


func _ingots() -> int:
	var n := 0
	for k in _hero.inventory:
		var it := ItemDB.find(str(k))
		if str(it.get("type", "")) == "Ingot":
			n += 1
	return n


func _events() -> Array:
	return _es.get("_events") as Array


func _cart_of(ev: Dictionary) -> Variant:
	return ev.get("cart")


func _cart_texture() -> Texture2D:
	return load(EventSystem.CART_TEXTURE) as Texture2D


func _run() -> void:
	print("-- caravan_event_smoke --")
	_map = load("res://scripts/alm_map.gd").new()
	_map.alm_path = "res://assets/maps/gen/gen_smart_01.alm"
	root.add_child(_map)
	_check(int(_map.get("map_width")) > 0, "карта загрузилась")
	if MinimapMarkers.instance == null:
		MinimapMarkers.new()
	_es = load("res://scripts/event_system.gd").new()
	root.add_child(_es)
	_hero = Player.new()
	Game.hero = _hero
	Game.map_seed = 135792
	Game.map_zone = "start"
	Game.map_sector = ""
	Game.enemies.clear()
	Game.npcs.clear()
	_cell = Vector2i(int(_map.get("map_width")) / 2, int(_map.get("map_height")) / 2)
	await process_frame

	await _test_spawn()
	await _test_saved()
	await _test_failed()
	await _test_payload()
	_report()


func _test_spawn() -> void:
	var id := _es.spawn_caravan_at(_cell)
	_check(id > 0, "караван заспавнился (id=%d)" % id)
	_check(_es.event_count() == 1, "одно активное событие")
	var victims := _victims()
	_check(victims.size() == 1, "торговец в мире (%d)" % victims.size())
	if victims.is_empty():
		return
	var v: Npc = victims[0]
	_check(v.anim_set == EventSystem.VICTIM_SET, "набор торговца = %s" % v.anim_set)
	var list := _events()
	if list.is_empty():
		_check(false, "событие в списке")
		return
	var cart = _cart_of(list[0] as Dictionary)
	_check(cart != null and is_instance_valid(cart), "тележка создана")
	if cart != null and is_instance_valid(cart):
		var spr := cart as Sprite2D
		_check(spr.texture == _cart_texture(), "у тележки текстура prop_cart")
		_check(spr.texture.get_width() == 64 and spr.texture.get_height() == 56,
			"тележка 64x56 (как в object_db)")
	var mobs := _tagged_mobs()
	_check(mobs.size() >= 2, "стая Серых заспавнилась (%d)" % mobs.size())
	var same := true
	for m in mobs:
		if str((m as Enemy).foe_group) != v.event_tag:
			same = false
	_check(same, "стая целится в торговца")
	if mobs.size() > 0:
		_check(_es.foe_for(mobs[0]) == v, "foe_for находит торговца")
	var marker_ok := false
	for m in MinimapMarkers.instance.all_for(Game.map_seed, Game.map_zone, Game.map_sector):
		if int(m["kind"]) == MinimapMarkers.Kind.BATTLE:
			marker_ok = true
	_check(marker_ok, "маркер каравана — BATTLE")


## Спасение: герой получает слитки, журнал растёт, тележка убрана.
func _test_saved() -> void:
	var before := _ingots()
	var journal0 := _journal_size()
	var list := _events()
	var cart = _cart_of(list[0] as Dictionary) if not list.is_empty() else null
	for m in _tagged_mobs():
		(m as Enemy).call("take_damage", 999999, null)
	await process_frame
	await process_frame
	await process_frame
	var lo := GameConfig.geti("events", "caravan_ingots_min")
	var hi := GameConfig.geti("events", "caravan_ingots_max")
	var got := _ingots() - before
	_check(got >= lo and got <= hi, "герой получил слитки: %d (ждём %d..%d)" % [got, lo, hi])
	_check(_journal_size() > journal0, "караван записан в журнал мира")
	_check(_es.event_count() == 0, "событие закрыто")
	_check(cart == null or not is_instance_valid(cart) or _freed(cart),
		"тележка убрана из мира")


## Провал: торговец погиб — награды нет, тележка убрана.
func _test_failed() -> void:
	var id := _es.spawn_caravan_at(_cell)
	_check(id > 0, "второй караван заспавнился")
	var before := _ingots()
	var list := _events()
	var cart = _cart_of(list[0] as Dictionary) if not list.is_empty() else null
	var victims := _victims()
	if victims.is_empty():
		_check(false, "торговец для провала")
		return
	(victims[0] as Npc).call("take_damage", 999999, null)
	await process_frame
	await process_frame
	await process_frame
	_check(_es.event_count() == 0, "провал закрыт")
	_check(_ingots() == before, "за провал слитков не дали")
	_check(cart == null or not is_instance_valid(cart), "тележка убрана и при провале")


## Сейв: караван возвращается вместе с тележкой.
func _test_payload() -> void:
	var id := _es.spawn_caravan_at(_cell)
	_check(id > 0, "третий караван заспавнился")
	var list := _events()
	if list.is_empty():
		_check(false, "нечего сохранять")
		return
	var payload: Array = _es.to_payload()
	_check(payload.size() == 1, "в сейве одно событие")
	_check(str((payload[0] as Dictionary).get("kind", "")) == "caravan",
		"в сейве kind = caravan")
	_es.call("_free_event_units", list[0])
	var live := _es.get("_events") as Array
	live.clear()
	_es.apply_payload(payload)
	_check(_es.event_count() == 1, "караван восстановлен из сейва")
	var back := _events()
	if back.size() == 1:
		var cart = _cart_of(back[0] as Dictionary)
		_check(cart != null and is_instance_valid(cart), "тележка вернулась вместе с караваном")


func _freed(node: Variant) -> bool:
	return node is Object and not is_instance_valid(node)


func _journal_size() -> int:
	var bus := root.get_node_or_null("WorldBus")
	if bus == null or not ("state" in bus) or bus.state == null:
		return -1
	return int(bus.state.journal.size())


func _report() -> void:
	if _done:
		return
	_done = true
	print("")
	if _fails.is_empty():
		print("RESULT: OK caravan_event_smoke (%d проверок)" % _checks)
		quit(0)
		return
	for f in _fails:
		print("  FAILED: " + f)
	print("RESULT: FAIL caravan_event_smoke (%d проверок, %d падений)" % [
		_checks, _fails.size()])
	quit(1)
