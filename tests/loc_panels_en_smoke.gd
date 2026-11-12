extends SceneTree
## English mode must not print Russian anywhere in the shop or the workshop.
##
## `loc_coverage_smoke` counts Russian literals in the source, but it cannot see
## two real failure modes: a panel reading `name_ru` directly (item and recipe
## names) and a `Loc` key that is missing at runtime (the key itself is shown).
## This test builds both panels with the locale set to English and walks every
## Label/Button text and tooltip, so a Russian word is a failure wherever it
## comes from.
##
## Run: godot --headless --path . --script res://tests/loc_panels_en_smoke.gd
## Result: RESULT: OK loc_panels_en_smoke checks=N

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 13, "spirit": 12,
		"blade": 10, "bludgeon": 10, "pike": 10, "shooting": 10,
		"fire": 20, "water": 20, "air": 20, "earth": 20, "astral": 20,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.hero_class = "warrior"
	Game.hero_name = "Buyer"
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print("%s %s" % ["  OK  " if ok else "  FAIL", what])


func _has_cyrillic(s: String) -> bool:
	for i in s.length():
		var c := s.unicode_at(i)
		if (c >= 0x0400 and c <= 0x04FF) or c == 0x0451 or c == 0x0401:
			return true
	return false


## Every visible string under `node`: Label/Button/LineEdit text and tooltips.
func _collect_texts(node: Node, out: Array[String]) -> void:
	if node is Label or node is Button or node is LineEdit:
		var text := str(node.get("text"))
		if text != "":
			out.append(text)
		var tip := str(node.get("tooltip_text"))
		if tip != "":
			out.append(tip)
	if node is Node:
		for child in node.get_children():
			_collect_texts(child, out)


func _scan(panel: Node, what: String) -> void:
	var texts: Array[String] = []
	_collect_texts(panel, texts)
	var bad: Array[String] = []
	for t in texts:
		if _has_cyrillic(t):
			bad.append(t)
	_check(bad.is_empty(), "%s: все %d подписей по-английски (русских: %d)"
		% [what, texts.size(), bad.size()])
	for i in mini(3, bad.size()):
		print("      русское: %s" % bad[i])
	# A missing key shows the key itself, which is not Cyrillic but is still
	# unreadable: catch "ui." leaks as well.
	var leaked: Array[String] = []
	for t in texts:
		if t.begins_with("ui.") or t.contains("ui.shop.") or t.contains("ui.craft."):
			leaked.append(t)
	_check(leaked.is_empty(), "%s: ключи локализации не просочились в текст (%d)"
		% [what, leaked.size()])
	for i in mini(3, leaked.size()):
		print("      ключ в тексте: %s" % leaked[i])
	# `str(null)` is the literal "<null>": potions and scrolls carry
	# `material: null`, and that used to be printed under the item name.
	var nulls: Array[String] = []
	for t in texts:
		if t.contains("<null>"):
			nulls.append(t)
	_check(nulls.is_empty(), "%s: нигде не показан <null> (%d)" % [what, nulls.size()])
	for i in mini(3, nulls.size()):
		print("      <null> в тексте: %s" % nulls[i])


func _run() -> void:
	# The language is chosen at the main menu, BEFORE the world is built: the SIM
	# state bakes mage and city names into its records at creation, so switching
	# to English after the map loaded would leave those names Russian.
	var saved := Loc.locale()
	Loc.set_locale("en")
	# The autoload builds its fixture at startup, before this test switches the
	# language: rebuild it so the mage, city and faction names are created in the
	# language the player is going to see.
	var bus := root.get_node_or_null("WorldBus")
	if bus != null and bus.state != null:
		bus.state = load("res://scripts/world/world_state.gd").new()
		bus.reseed()
	var err := change_scene_to_file("res://scenes/main.tscn")
	if err != OK:
		_check(false, "main.tscn: %d" % err)
		Loc.set_locale(saved)
		_finish()
		return
	await process_frame
	await create_timer(0.6).timeout
	var hero = get_first_node_in_group("player")
	if hero == null:
		_check(false, "герой не загружен")
		Loc.set_locale(saved)
		_finish()
		return
	for key in ["Common iron Long Sword", "Common Leather Mail",
			"Potion Medium Healing", "Crafted iron Cuirass", "bronze Ingot"]:
		hero.call("add_item", key)
	hero.gold = 100000

	var shop := ShopPanel.new()
	shop.setup(hero, "humans")
	current_scene.add_child(shop)
	await process_frame
	await create_timer(0.3).timeout
	_scan(shop, "магазин")
	# The merchant line is the one the player reads most: it must be English too.
	shop.call("_talk")
	await process_frame
	_scan(shop, "магазин (после «Поговорить»)")
	shop.queue_free()
	await process_frame

	var workshop := WorkshopPanel.new()
	workshop.setup(hero)
	current_scene.add_child(workshop)
	await process_frame
	await create_timer(0.3).timeout
	_scan(workshop, "мастерская")
	workshop.queue_free()
	await process_frame

	var inn := InnPanel.new()
	inn.setup(hero, "humans")
	current_scene.add_child(inn)
	await process_frame
	await create_timer(0.3).timeout
	_scan(inn, "таверна")
	# The mercenary cards are named from units_db (`desc_en`), so check the data
	# directly: a missing column would silently fall back to Russian.
	var ta_ru: Array[String] = []
	for entry in ContentRules.list("inn.candidates"):
		var data := UnitDB.get_set(str(entry))
		if str(data.get("desc_en", "")) == "":
			ta_ru.append(str(entry))
	_check(ta_ru.is_empty(), "у наёмников таверны есть desc_en (%d без перевода)"
		% ta_ru.size())
	inn.queue_free()
	await process_frame

	var alchemy := AlchemyPanel.new()
	alchemy.setup(hero)
	current_scene.add_child(alchemy)
	await process_frame
	await create_timer(0.3).timeout
	_scan(alchemy, "алхимия")
	alchemy.queue_free()
	await process_frame

	var school := SchoolPanel.new()
	school.setup(hero)
	current_scene.add_child(school)
	await process_frame
	await create_timer(0.3).timeout
	_scan(school, "школа")
	school.queue_free()
	await process_frame

	var mage_panel := ArchmagePanel.new()
	mage_panel.setup(hero, "", "humans")
	current_scene.add_child(mage_panel)
	await process_frame
	await create_timer(0.3).timeout
	_scan(mage_panel, "великий маг")
	mage_panel.queue_free()
	await process_frame

	# The mage's name, city and speech come from lore data (`*_en` columns).
	var lore_ru: Array[String] = []
	for race in ["humans", "ork", "necro", "druid"]:
		for text in [Lore.faction_city(race), Lore.faction_archmage(race)]:
			if _has_cyrillic(str(text)):
				lore_ru.append(str(text))
		for kind in ["greet", "idle"]:
			for line in Lore.archmage_speech(race, kind):
				if _has_cyrillic(str(line)):
					lore_ru.append(str(line))
	_check(lore_ru.is_empty(), "имена, города и речи магов по-английски (%d русских)"
		% lore_ru.size())
	for i in mini(3, lore_ru.size()):
		print("      русское: %s" % lore_ru[i])

	# Recipe names come from data (`name_en`), not from the UI table: a missing
	# English column would fall back to Russian, so check the data directly.
	var ru_names: Array[String] = []
	for kind in CraftDB.CRAFT_KINDS:
		for recipe in CraftDB.recipes(kind):
			if str(recipe.get("name_en", "")) == "":
				ru_names.append(str(recipe.get("id", "")))
	_check(ru_names.is_empty(), "у всех рецептов есть name_en (%d без перевода)"
		% ru_names.size())

	var items_ru: Array[String] = []
	for item in ItemDB.all():
		if str(item.get("name_en", "")) == "":
			items_ru.append(str(item.get("key", "")))
	_check(items_ru.is_empty(), "у всех %d предметов есть name_en (%d без перевода)"
		% [ItemDB.all().size(), items_ru.size()])

	var nulls: Array[String] = []
	for item in ItemDB.all():
		var shown := ItemDB.display_name(item)
		if shown.contains("<null>") or shown == "":
			nulls.append(str(item.get("key", "")))
	_check(nulls.is_empty(), "названия предметов без <null> и пустых (%d)" % nulls.size())

	Loc.set_locale(saved)
	_finish()


func _finish() -> void:
	print()
	if _fails.is_empty():
		print("RESULT: OK loc_panels_en_smoke checks=%d" % _checks)
		quit(0)
	else:
		print("RESULT: FAIL loc_panels_en_smoke checks=%d fails=%d"
			% [_checks, _fails.size()])
		for m in _fails:
			print("  - %s" % m)
		quit(1)
