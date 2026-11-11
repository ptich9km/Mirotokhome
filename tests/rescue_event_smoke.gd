extends SceneTree
## Событие «спасти путника» (11.11).
##
## Что проверяется:
## 1. Путник появляется как мирный Npc (роль victim), не отвечает на удары.
## 2. Стая Серых берёт его целью, герой рядом переключает стаю на себя.
## 3. Урон по путнику масштабируется ([events] rescue_victim_dmg_scale), иначе
##    три Серых кончают его быстрее, чем герой добежит.
## 4. Стая мертва — награда (репутация ближайшего города + запись в журнал),
##    маркер снят, путник уходит в город (leaving).
## 5. Путник погиб / время вышло — событие провалено, награды нет.
## 6. Сейв: to_payload помнит hp путника, apply_payload возвращает его.
##
## Запуск: godot --headless --path . --script res://tests/rescue_event_smoke.gd

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
	print("RESULT: FAIL rescue_event_smoke (таймаут)")
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


func _journal_size() -> int:
	var bus := root.get_node_or_null("WorldBus")
	if bus == null or not ("state" in bus) or bus.state == null:
		return -1
	return int(bus.state.journal.size())


func _rep(race: String) -> int:
	var bus := root.get_node_or_null("WorldBus")
	if bus == null or not ("state" in bus) or bus.state == null:
		return 0
	return int(bus.state.hero_rep(race))


func _run() -> void:
	print("-- rescue_event_smoke --")
	_map = load("res://scripts/alm_map.gd").new()
	_map.alm_path = "res://assets/maps/gen/gen_smart_01.alm"
	root.add_child(_map)
	_check(int(_map.get("map_width")) > 0, "карта загрузилась")
	if MinimapMarkers.instance == null:
		MinimapMarkers.new()
	_es = load("res://scripts/event_system.gd").new()
	root.add_child(_es)
	Game.map_seed = 987654
	Game.map_zone = "start"
	Game.map_sector = ""
	Game.enemies.clear()
	Game.npcs.clear()
	_cell = Vector2i(int(_map.get("map_width")) / 2, int(_map.get("map_height")) / 2)

	_test_spawn()
	_test_aggro_switch()
	_test_damage_scale()
	await _test_success()
	_test_failure()
	_test_expire()
	_test_payload()
	_report()


func _test_spawn() -> void:
	var id := _es.spawn_rescue_at(_cell)
	_check(id > 0, "событие «спасти путника» заспавнилось (id=%d)" % id)
	_check(_es.event_count() == 1, "одно активное событие")
	var victims := _victims()
	_check(victims.size() == 1, "путник в мире (%d)" % victims.size())
	if victims.size() != 1:
		return
	var v: Npc = victims[0]
	_check(v.anim_set == EventSystem.VICTIM_SET,
		"набор путника = %s" % v.anim_set)
	_check(UnitDB.has(v.anim_set), "набор путника есть в базе")
	_check(v.current_hp == GameConfig.geti("events", "rescue_victim_hp"),
		"жизнь путника по конфигу (%d)" % v.current_hp)
	_check(v.damage == 0, "путник не отвечает ударом (damage=0)")
	var mobs := _tagged_mobs()
	_check(mobs.size() >= 2, "стая Серых заспавнилась (%d)" % mobs.size())
	var same_foe := true
	for m in mobs:
		if str((m as Enemy).foe_group) != v.event_tag:
			same_foe = false
	_check(same_foe, "вся стая целится в путника")
	if mobs.size() > 0:
		_check(_es.foe_for(mobs[0]) == v, "foe_for находит путника")
	var marker_ok := false
	for m in MinimapMarkers.instance.all_for(Game.map_seed, Game.map_zone, Game.map_sector):
		if int(m["kind"]) == MinimapMarkers.Kind.QUEST_RESCUE:
			marker_ok = true
	_check(marker_ok, "маркер события — QUEST_RESCUE")


## Герой подошёл — стая бросает путника без единого удара.
func _test_aggro_switch() -> void:
	var mobs := _tagged_mobs()
	if mobs.is_empty():
		_check(false, "стая для проверки агро")
		return
	var mob: Enemy = mobs[0]
	var fake_hero := Node2D.new()
	fake_hero.add_to_group("player")
	root.add_child(fake_hero)
	Game.hero_dead = false
	fake_hero.global_position = mob.global_position + Vector2(30, 0)
	await process_frame
	var target: Node2D = mob.call("_combat_target")
	_check(target == fake_hero, "герой рядом — стая переключается на него")
	fake_hero.global_position = mob.global_position + Vector2(900, 0)
	await process_frame
	target = mob.call("_combat_target")
	_check(target != fake_hero, "герой ушёл — стая возвращается к путнику")
	fake_hero.queue_free()


## Вне видимости бой идёт «дёшево», но урон по путнику масштабируется.
## Один тик может промахнуться (промах считается в Game.is_miss), поэтому
## копим потерю за 12 тиков и сравниваем с суммой ожидаемых попаданий.
func _test_damage_scale() -> void:
	var victims := _victims()
	var mobs := _tagged_mobs()
	if victims.is_empty() or mobs.is_empty():
		_check(false, "путник и стая для проверки урона")
		return
	var v: Npc = victims[0]
	var before := v.current_hp
	var per_tick := 0.0
	for m in mobs:
		per_tick += float((m as Enemy).damage) * 0.5 \
			* GameConfig.getf("events", "rescue_victim_dmg_scale")
	per_tick = maxf(1.0, per_tick)
	for i in range(12):
		_es._abstract_tick()
	var lost := before - v.current_hp
	_check(lost > 0, "вне видимости стая бьёт путника (−%d за 12 тиков)" % lost)
	_check(float(lost) <= per_tick * 12.0 + 6.0,
		"урон масштабирован (потеря %d, потолок ~%.1f)" % [lost, per_tick * 12.0])
	var raw := 0.0
	for m in mobs:
		raw += float((m as Enemy).damage) * 0.5
	_check(float(lost) < raw * 6.0,
		"без масштаба потеря была бы в разы больше (сырой потолок ~%.1f)" % (raw * 12.0))


func _test_success() -> void:
	var victims := _victims()
	if victims.is_empty():
		return
	var v: Npc = victims[0]
	var rep_before := _rep(_city_race())
	var journal_before := _journal_size()
	for m in _tagged_mobs():
		Game.deal_damage(m, 99999, "physical", "", v)
	_es._check_rescue_state()
	_check(_es.event_count() == 0, "стая мертва — событие закрыто")
	_check(v.current_hp > 0 and v.state == "idle", "путник жив")
	_check(v.leaving, "спасённый уходит в город (leaving)")
	_check(_journal_size() > journal_before, "запись в журнале мира появилась")
	var race := _city_race()
	if race != "":
		_check(_rep(race) >= rep_before + GameConfig.geti("events", "rescue_rep"),
			"репутация города выросла (%d -> %d)" % [rep_before, _rep(race)])
	else:
		print("  --   на тестовой карте нет городов: репутация не проверяется")
	_check(MinimapMarkers.instance.item_count() == 0, "маркер снят после спасения")
	_check(_tagged_mobs().is_empty(), "теги сняты с уцелевших")
	# Регрессия 11.11: анимация MOVE играла, а тело стояло — _move_checked задаёт
	# velocity, но move_and_slide() в _leave_tick не вызывался.
	if is_instance_valid(v):
		var start := v.global_position
		for _i in range(20):
			await physics_frame
		if is_instance_valid(v):
			var moved := start.distance_to(v.global_position)
			_check(moved > 4.0, "спасённый реально идёт к городу (%.1f px за 20 кадров)" % moved)
		else:
			_check(true, "спасённый дошёл и исчез (20 кадров)")
	v.queue_free()
	Game.npcs.erase(v)


func _test_failure() -> void:
	_check(_es.spawn_rescue_at(_cell) > 0, "второе событие заспавнилось")
	var victims := _victims()
	if victims.is_empty():
		_check(false, "путник второго события")
		return
	var v: Npc = victims[0]
	var rep_before := _rep(_city_race())
	Game.deal_damage(v, 99999, "physical", "", null)
	_es._check_rescue_state()
	_check(_es.event_count() == 0, "путник погиб — событие закрыто")
	_check(v.state == "dying" or v.state == "decay" or v.state == "corpse",
		"путник упал (state=%s)" % v.state)
	_check(not v.leaving, "мёртвый никуда не уходит")
	_check(_rep(_city_race()) == rep_before, "за провал репутации не дают")
	_check(MinimapMarkers.instance.item_count() == 0, "маркер снят после провала")


func _test_expire() -> void:
	_check(_es.spawn_rescue_at(_cell) > 0, "третье событие заспавнилось")
	var rep_before := _rep(_city_race())
	_es.debug_expire_all()
	var v: Npc = null
	for n in _victims():
		v = n
		break
	_check(_es.event_count() == 0, "TTL закрывает событие")
	if v != null:
		_check(v.state == "dying" or v.state == "decay" or v.state == "corpse",
			"по TTL путник погибает (state=%s)" % v.state)
	_check(_rep(_city_race()) == rep_before, "за TTL награды нет")


func _test_payload() -> void:
	_check(_es.spawn_rescue_at(_cell) > 0, "четвёртое событие заспавнилось")
	var victims := _victims()
	if victims.is_empty():
		_check(false, "путник четвёртого события")
		return
	var v: Npc = victims[0]
	v.current_hp = 77
	var payload: Array = _es.to_payload()
	var found := {}
	for rec in payload:
		if str(rec.get("kind", "")) == "rescue":
			found = rec
	_check(not found.is_empty(), "в payload есть событие-спасение")
	_check(int(found.get("victim_hp", 0)) == 77, "payload помнит hp путника (77)")
	_es.debug_expire_all()
	for n in _victims():
		n.queue_free()
	Game.npcs.clear()
	_es.apply_payload(payload)
	_check(_es.event_count() == 1, "apply_payload возвращает событие")
	var restored := _victims()
	_check(restored.size() == 1, "путник восстановлен")
	if restored.size() == 1:
		_check((restored[0] as Npc).current_hp == 77,
			"жизнь восстановлена (%d)" % (restored[0] as Npc).current_hp)
	_es.debug_expire_all()


## Раса ближайшего к событию города (её репутация и должна расти).
func _city_race() -> String:
	if _map == null or not _map.has_method("get_cities"):
		return ""
	var cities: Array = _map.call("get_cities")
	if cities.is_empty():
		return ""
	return str(cities[0].get("race", ""))


func _report() -> void:
	_done = true
	print("RESULT: %s rescue_event_smoke (проверок: %d, провалов: %d)"
		% ["OK" if _fails.is_empty() else "FAIL", _checks, _fails.size()])
	quit(0)
