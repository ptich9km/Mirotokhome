extends SceneTree
## Смоук панели великого мага (ArchmagePanel) + капитан=маг.
##
## Проверяет:
##  * на карте есть NPC is_archmage (капитан) с набором ork_mage_a52/tN
##  * панель открывается, имя/город из Lore
##  * сдача слитка/золота меняет power и списывает ресурс один раз
##  * power>=100 блокирует кнопки
##
## Запуск: godot --headless --path . --script res://tests/archmage_ui_smoke.gd

const UNITS := "res://assets/units/units_db.json"

var _fails: Array[String] = []
var _checks := 0
var _bus: Node = null
var _power0 := 0.0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
	print(("  OK  " if ok else "  FAIL") + " " + msg)


func _bus_state():
	if _bus == null:
		_bus = root.get_node_or_null("WorldBus")
	if _bus == null:
		return null
	return _bus.state


func _power() -> float:
	var st = _bus_state()
	if st == null:
		return -1.0
	var am = st.get_archmage("human")
	if not (am is Dictionary):
		return -1.0
	return float((am as Dictionary).get("power", 0.0))


func _run() -> void:
	print("-- units --")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(UNITS))
	_check(parsed is Dictionary, "units_db читается")
	for t in range(4):
		var key := "ork_mage_a52/t%d" % t
		_check(parsed is Dictionary and (parsed as Dictionary).has(key), "набор %s есть" % key)

	print("-- карта + капитан-маг --")
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 9, "spirit": 8,
		"blade": 30, "bludgeon": 15, "pike": 10,
		"fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.hero_class = "warrior"
	Game.hero_name = "Тест"
	Game.hero_race = "human"
	Game.map_seed = 4242
	var packed: PackedScene = load("res://scenes/main.tscn")
	var game = packed.instantiate()
	root.add_child(game)
	for i in range(5):
		await process_frame
	var player = game.get("player")
	var ui = game.get("ui")
	await process_frame
	_check(player != null, "игрок загружен")
	_check(ui != null, "UI загружен")
	_bus = root.get_node_or_null("WorldBus")
	_check(_bus != null, "WorldBus autoload есть")

	var captains: Array = []
	for n in Game.npcs:
		if is_instance_valid(n) and "is_archmage" in n and bool(n.is_archmage):
			captains.append(n)
	_check(captains.size() > 0, "на карте есть капитан-маг (%d)" % captains.size())
	if not captains.is_empty():
		var c: Node = captains[0]
		var setn := str(c.anim_set)
		_check(UnitDB.has(setn), "набор капитана есть в units_db (=%s)" % setn)
		# 09.10: капитан = маг СВОЕЙ расы (CITY_POPULATION[...]["captain"]).
		# Прежде здесь стояла проверка begins_with("ork_mage_a52/") — она держала
		# старый контракт и пропустила бы druid-города с орком-магом.
		var cap_race := MapGenerator.race_of_set(setn)
		_check(cap_race != "", "набор капитана городской: %s" % setn)
		if cap_race != "":
			var expect := str((MapGenerator.CITY_POPULATION.get(cap_race, {}) as Dictionary)
				.get("captain", ""))
			_check(setn == expect,
				"капитан расы '%s' = %s (на карте %s)" % [cap_race, expect, setn])
			_check(setn.ends_with("/t3"), "капитан — высший тир t3 (=%s)" % setn)
		# Все капитаны на карте (а не только первый) — своих городов.
		for cap2 in captains:
			var s2 := str((cap2 as Node).get("anim_set"))
			var r2 := MapGenerator.race_of_set(s2)
			if r2 != "" and MapGenerator.CITY_POPULATION.has(r2):
				var e2 := str((MapGenerator.CITY_POPULATION[r2] as Dictionary).get("captain", ""))
				_check(s2 == e2, "капитан[%s] своей расы (ожидали %s)" % [s2, e2])
	var am0 = _bus_state().get_archmage("human")
	_check(am0 is Dictionary and not (am0 as Dictionary).is_empty(), "get_archmage(human) не пуст")
	if am0 is Dictionary:
		_check(str((am0 as Dictionary).get("name", "")) == Loc.field(Lore.faction("humans"), "archmage"),
			"маг людей Маша (=%s)" % (am0 as Dictionary).get("name"))

	print("-- панель --")
	ui.call("open_archmage")
	await process_frame
	await process_frame
	var panel = ui.get("_archmage")
	_check(panel != null and is_instance_valid(panel), "ArchmagePanel создана")
	if panel != null:
		var portrait = panel.get("_portrait")
		_check(portrait != null and is_instance_valid(portrait), "в панели есть Portrait")
		if portrait != null:
			var ptex = portrait.get("texture")
			_check(ptex != null, "у капитана есть спрайт в панели (texture)")
	if panel == null:
		_report()
		return
	_check(panel.has_method("close"), "панель закрывается")
	_power0 = _power()
	var inv0: int = player.inventory.size()
	var gold0: int = player.gold
	_check(_power0 >= 0.0, "power читается (%.2f)" % _power0)

	var ingot := ""
	for raw in ItemDB.all():
		var it: Dictionary = raw
		if str(it.get("type", "")) == "Ingot":
			ingot = str(it.get("key", ""))
			break
	_check(ingot != "", "в базе есть слиток")
	if ingot != "":
		player.inventory.append(ingot)
		panel.call("_refresh")
		panel.call("_on_stake_ingot")
		await process_frame
		var power1 := _power()
		_check(power1 > _power0, "слиток поднял power %.2f -> %.2f" % [_power0, power1])
		_check(player.inventory.size() == inv0,
			"слиток списан один раз (inv %d -> %d)" % [inv0, player.inventory.size()])
	# золото: старт 20 < gold_per_stake=100 — выдаём запас
	player.gold = 1000
	panel.call("_refresh")
	var gold1: int = player.gold
	panel.call("_on_stake_gold")
	await process_frame
	var gold2: int = player.gold
	var power_g := _power()
	_check(gold2 < gold1, "золото списано (%d -> %d)" % [gold1, gold2])
	_check(power_g > _power0, "золото подняло power %.2f -> %.2f" % [_power0, power_g])
	_check(gold1 - gold2 == 100, "списано ровно ставка золота 100 (=%d)" % (gold1 - gold2))

	# power=100 блокирует
	_bus_state().add_archmage_power("human", 100.0)
	panel.call("_refresh")
	var btn = panel.get("_btn_ingot")
	_check(btn != null and bool(btn.disabled), "при power=100 кнопка «Сдать» неактивна")

	# 28.10: панель открывается для ГОРОДА, а не для расы героя. Герой-человек
	# в друидском городе обязан увидеть друидского великого мага.
	panel.call("close")
	await process_frame
	ui.call("open_archmage", "c0t0", "druid")
	await process_frame
	var druid_panel = ui.get("_archmage")
	_check(druid_panel != null and is_instance_valid(druid_panel),
		"панель друидского города создана")
	if druid_panel != null:
		var nm := str((druid_panel.get("_name_label") as Label).text)
		var expect := Lore.faction_archmage("druid")
		_check(expect != "" and nm == expect,
			"друидский маг по городу: %s (ожидали %s)" % [nm, expect])
		var am_d: Variant = _bus_state().get_archmage("druid")
		_check(am_d is Dictionary and not (am_d as Dictionary).is_empty(),
			"у друидов есть великий маг")
		druid_panel.call("close")
		await process_frame

	await process_frame
	var after = ui.get("_archmage")
	_check(after == null or not is_instance_valid(after), "панель закрыта")

	_report()


func _report() -> void:
	print()
	if _fails.is_empty():
		print("RESULT: OK archmage_ui_smoke checks=%d" % _checks)
		quit(0)
	else:
		print("RESULT: FAIL archmage_ui_smoke checks=%d fails=%d" % [_checks, _fails.size()])
		for m in _fails:
			print("  - %s" % m)
		quit(1)
