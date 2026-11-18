extends SceneTree
## Засада на карте (19.11).
##
## Что проверяется:
## 1. Засада спавнится одной группой Серых (3–5 по конфигу), без жертвы.
## 2. У стаи пустой foe_group: она ведёт себя как обычные Серые и идёт на героя,
##    а не на участника события (foe_for никого не находит).
## 3. Маркер события — BATTLE (не QUEST_RESCUE).
## 4. Последний Серый ушёл — событие закрыто, теги сняты, маркер удалён.
## 5. Время вышло — стая исчезает без лута и без награды.
## 6. Сейв: to_payload/apply_payload возвращают засаду тем же набором.
##
## Запуск: godot --headless --path . --script res://tests/ambush_event_smoke.gd

var _checks := 0
var _fails: Array[String] = []
var _done := false
var _es: EventSystem = null
var _map: Node = null
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
	print("RESULT: FAIL ambush_event_smoke (таймаут)")
	quit(1)


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
	print(("  OK  " if ok else "  FAIL") + " " + msg)


func _tagged_mobs() -> Array:
	var out: Array = []
	for e in Game.enemies:
		if e != null and is_instance_valid(e) and e is Enemy \
				and str((e as Enemy).event_tag) != "":
			out.append(e)
	return out


func _marker_kinds() -> Array:
	var out: Array = []
	if MinimapMarkers.instance == null:
		return out
	for m in MinimapMarkers.instance.all_for(Game.map_seed, Game.map_zone, Game.map_sector):
		out.append(int(m["kind"]))
	return out


func _events() -> Array:
	return _es.get("_events") as Array


func _run() -> void:
	print("-- ambush_event_smoke --")
	_map = load("res://scripts/alm_map.gd").new()
	_map.alm_path = "res://assets/maps/gen/gen_smart_01.alm"
	root.add_child(_map)
	_check(int(_map.get("map_width")) > 0, "карта загрузилась")
	if MinimapMarkers.instance == null:
		MinimapMarkers.new()
	_es = load("res://scripts/event_system.gd").new()
	root.add_child(_es)
	Game.map_seed = 246813
	Game.map_zone = "start"
	Game.map_sector = ""
	Game.enemies.clear()
	Game.npcs.clear()
	_cell = Vector2i(int(_map.get("map_width")) / 2, int(_map.get("map_height")) / 2)
	# One frame first: the very first _process of EventSystem sets the map key and
	# clears whatever was spawned before it (rescue_event_smoke runs into this).
	await process_frame

	await _test_spawn()
	await _test_close()
	await _test_expire()
	await _test_payload()
	_report()


func _test_spawn() -> void:
	var id := _es.spawn_ambush_at(_cell)
	_check(id > 0, "засада заспавнилась (id=%d)" % id)
	_check(_es.event_count() == 1, "одно активное событие")
	var mobs := _tagged_mobs()
	var lo := GameConfig.geti("events", "ambush_members_min")
	var hi := GameConfig.geti("events", "ambush_members_max")
	_check(mobs.size() >= lo and mobs.size() <= hi,
		"стая по конфигу: %d (ждём %d..%d)" % [mobs.size(), lo, hi])
	var no_foe := true
	for m in mobs:
		if str((m as Enemy).foe_group) != "":
			no_foe = false
	_check(no_foe, "у засады нет foe_group — стая ведёт себя как обычные Серые")
	if mobs.size() > 0:
		_check(_es.foe_for(mobs[0]) == null, "foe_for никого не находит")
	var kinds := _marker_kinds()
	_check(kinds.has(MinimapMarkers.Kind.BATTLE), "маркер засады — BATTLE")
	_check(not kinds.has(MinimapMarkers.Kind.QUEST_RESCUE),
		"маркера спасения у засады нет")


## Последний Серый убит — событие закрывается на ближайшем тике.
func _test_close() -> void:
	var mobs := _tagged_mobs()
	for m in mobs:
		(m as Enemy).call("take_damage", 999999, null)
	await process_frame
	await process_frame
	_es.call("_check_gone")
	_check(_es.event_count() == 0, "стая мертва — событие закрыто")
	_check(_marker_kinds().is_empty(), "маркер засады снят")
	_check(_tagged_mobs().is_empty(), "живых участников с тегом не осталось")


## Время вышло: стая исчезает без лута.
func _test_expire() -> void:
	var id := _es.spawn_ambush_at(_cell)
	_check(id > 0, "вторая засада заспавнилась")
	var list := _events()
	_check(list.size() == 1, "в списке одно событие")
	if list.is_empty():
		return
	(list[0] as Dictionary)["ttl_left"] = 0.05
	await create_timer(0.4).timeout
	_check(_es.event_count() == 0, "по таймеру событие закрыто")
	_check(_tagged_mobs().is_empty(), "по таймеру стая убрана из мира")


## Сейв: засада возвращается тем же набором, а не новой случайной стаей.
func _test_payload() -> void:
	var id := _es.spawn_ambush_at(_cell)
	_check(id > 0, "третья засада заспавнилась")
	var list := _events()
	if list.is_empty():
		_check(false, "нечего сохранять")
		return
	var set_a := str((list[0] as Dictionary)["set_a"])
	var payload: Array = _es.to_payload()
	_check(payload.size() == 1, "в сейве одно событие")
	_check(str((payload[0] as Dictionary).get("kind", "")) == "ambush",
		"в сейве kind = ambush")
	# Drop the live event, then restore it the way a reload does.
	_es.call("_free_event_units", list[0])
	var live := _es.get("_events") as Array
	live.clear()
	_es.apply_payload(payload)
	_check(_es.event_count() == 1, "событие восстановлено из сейва")
	var back := _events()
	if back.size() == 1:
		_check(str((back[0] as Dictionary)["set_a"]) == set_a,
			"набор восстановлен (%s)" % set_a)


func _report() -> void:
	if _done:
		return
	_done = true
	print("")
	if _fails.is_empty():
		print("RESULT: OK ambush_event_smoke (%d проверок)" % _checks)
		quit(0)
		return
	for f in _fails:
		print("  FAILED: " + f)
	print("RESULT: FAIL ambush_event_smoke (%d проверок, %d падений)" % [
		_checks, _fails.size()])
	quit(1)
