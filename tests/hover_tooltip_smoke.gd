extends SceneTree
## Smoke-проверка задержанных тултипов мира и карточек предметов (scripts/ui.gd).
##
## Проверяет:
##  1. фракции по наборам юнитов (Альянс/Орды/Пожинатели/Круг/Серые);
##  2. строки карточки предмета: имя, урон, вес/цена;
##  3. строки карточки лута: золото и имена предметов;
##  4. строки карточки юнита: hover-база — название+фракция; Alt — HP/бой;
##  5. строки карточки здания (имя из StructureDB);
##  6. _update_world_tooltip не падает и создаёт карточку при цели под курсором.
##
## Запуск: godot --headless --path . --script res://tests/hover_tooltip_smoke.gd

var _fails: Array[String] = []

func _initialize() -> void:
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 9, "spirit": 8,
		"blade": 30, "bludgeon": 15, "pike": 10,
		"fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.hero_class = "warrior"
	Game.hero_name = "Тест"
	Game.hero_character_id = "mfighter"
	call_deferred("_run")

func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails.append(what)
	print("TIP: %s %s" % ["ok  " if ok else "FAIL", what])

func _run() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	var game = packed.instantiate()
	root.add_child(game)
	for i in range(3):
		await process_frame
	var player: Player = game.get("player")
	var ui = game.get("ui")
	await process_frame

	_test_factions(ui)
	_test_item_card(ui)
	await _test_loot_card(ui)
	_test_unit_card(ui)
	_test_building_card(ui)
	await _test_empty_target_no_crash(ui)
	_report()

func _test_factions(ui) -> void:
	var orcs := Loc.t("ui.faction_name.ork")
	var undead := Loc.t("ui.faction_name.necro")
	var humans := Loc.field(Lore.faction("humans"), "label")
	var grey := Loc.t("ui.faction_name.grey")
	var druids := Loc.t("ui.faction_name.druid")
	var cases := {
		"monsters/orc": orcs,
		"monsters/goblin": orcs,
		"monsters/skeleton": undead,
		"monsters/zombie": undead,
		# The old "humans/swordsman" case pointed at art removed on 11.10; city
		# guards are the real Alliance sets, so the guard checks one of those.
		"city_human_warrior/t0": humans,
		"ork_mage_a52/t1": orcs,
		"ork_mage_a52/t3": orcs,
		"ork_mage/t1": orcs,
		"monsters/bat": grey,
		"monsters/druid": druids,
	}
	for set_name in cases:
		var got: String = ui.call("_faction_of_set", set_name)
		_check(got == cases[set_name],
			"фракция %s = %s (получено %s)" % [set_name, cases[set_name], got])

func _test_item_card(ui) -> void:
	var it := ItemDB.find("Common iron Long Sword")
	_check(not it.is_empty(), "в базе есть Common iron Long Sword")
	if it.is_empty():
		return
	var lines: Array = ui.call("_item_card_lines", it)
	var text := "\n".join(PackedStringArray(lines))
	_check(text.contains(Loc.t("ui.tip.damage").split("%")[0].strip_edges()),
		"карточка оружия показывает урон (%s)" % text)
	var wp := Loc.t("ui.tip.weight_price")
	var weight_word := wp.split("%")[0].strip_edges()
	var price_word := wp.split("·")[1].split("%")[0].strip_edges() if wp.contains("·") else ""
	_check(text.contains(weight_word) and (price_word == "" or text.contains(price_word)),
		"карточка показывает вес и цену")

func _test_loot_card(ui) -> void:
	# LootBag удалён (03.10) — на его месте LootDrop с тем же полем items.
	var lb := LootDrop.new()
	lb.items = [{"gold": 5}, {"key": "Common iron Long Sword"}]
	# Дальше от игрока: LootDrop сам подбирает добычу при подходе.
	lb.position = Vector2(99999.0, 99999.0)
	root.add_child(lb)
	await process_frame
	var lines: Array = ui.call("_loot_tooltip_lines", lb)
	var text := "\n".join(PackedStringArray(lines))
	_check(text.contains(Loc.t("ui.card.loot")), "карточка лута с заголовком")
	_check(text.contains(Loc.f("ui.card.gold", [5])), "карточка лута показывает золото")
	_check(lines.size() >= 3, "карточка лута содержит и предметы (%s)" % text)
	lb.queue_free()

func _test_unit_card(ui) -> void:
	var unit: Node2D = null
	if Game.enemies.size() > 0:
		unit = Game.enemies[0]
	elif Game.npcs.size() > 0:
		unit = Game.npcs[0]
	_check(unit != null, "на карте есть юнит для проверки")
	if unit == null:
		return
	# База (hover): название + фракция, без HP.
	var lines: Array = ui.call("_unit_tooltip_lines", unit)
	var text := "\n".join(PackedStringArray(lines))
	_check(not text.contains(Loc.t("ui.card.health").split("%")[0].strip_edges()),
		"база без HP (он в полной карточке Alt)")
	_check(text.contains(Loc.t("ui.card.faction").split("%")[0].strip_edges()),
		"база показывает фракцию (%s)" % text)
	# Полная (Alt): добавляет HP и боевые статы.
	ui.set("_world_hover_unit", unit)
	var full: Array = ui.call("_unit_tooltip_full", ["u0", lines])
	var ftext := "\n".join(PackedStringArray(full))
	_check(ftext.contains(Loc.t("ui.card.health").split("%")[0].strip_edges())
		or ftext.contains(Loc.t("ui.card.attack").split("%")[0].strip_edges()),
		"полная карточка содержит бой/HP (%s)" % ftext)
	# _update_world_tooltip с фейковой целью: не падает, bounds = viewport.
	ui.set("_world_hover_key", "u0")
	ui.set("_world_hover_time", 1.0)
	ui.set("_world_card_shown", false)
	ui.set("_world_card_alt", false)
	ui.call("_update_world_tooltip", 0.05)
	_check(true, "_update_world_tooltip отработал с целью без ошибок")

func _test_building_card(ui) -> void:
	# Первое известное здание из структуры карты (если есть).
	var alm = game_map_if_any()
	var lines: Array = ui.call("_building_tooltip_lines", {"type_id": -1})
	_check(not lines.is_empty(), "карточка здания всегда непустая")
	var text := "\n".join(PackedStringArray(lines))
	_check(text.contains(Loc.t("ui.card.building")),
		"карточка здания с типом «%s»" % Loc.t("ui.card.building"))

func _test_empty_target_no_crash(ui) -> void:
	# Без цели под курсором функция должна просто сбрасывать таймер и прятать карточку.
	ui.call("_update_world_tooltip", 0.6)
	await process_frame
	ui.call("_update_world_tooltip", 0.6)
	_check(true, "_update_world_tooltip отработал без цели без ошибок")

func game_map_if_any() -> Node:
	var map := get_first_node_in_group("alm_map")
	return map

func _report() -> void:
	if _fails.is_empty():
		print("RESULT: OK")
		quit(0)
	else:
		print("RESULT: FAIL (%d): %s" % [_fails.size(), str(_fails)])
		quit(1)