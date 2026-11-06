extends SceneTree
## Forge MVP (04.11/06.11): learned recipes and the master's +1..+7.
##
## Run: godot --headless --path . --script res://tests/forge_smoke.gd

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 9, "spirit": 8,
		"blade": 20, "axe": 0, "bludgeon": 0, "pike": 0, "shooting": 10,
		"fire": 0, "water": 0, "air": 0, "earth": 0, "astral": 0,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.hero_class = "warrior"
	Game.hero_name = "Тест"
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print("FORGE: %s %s" % ["ok  " if ok else "FAIL", what])


func _run() -> void:
	var p := Player.new()
	root.add_child(p)
	await process_frame

	# 1. Common recipes are learned forever; the scroll is consumed.
	p.inventory = ["Recipe iron_sword"]
	p.known_recipes.clear()
	_check(CraftDB.learn_recipe(p, "iron_sword"), "обычный рецепт изучен")
	_check(p.known_recipes.has("iron_sword"), "рецепт записан в героя")
	_check(not p.inventory.has("Recipe iron_sword"), "свиток израсходован")
	_check(CraftDB.has_recipe(p, "iron_sword"), "рецепт доступен без свитка")
	_check(not CraftDB.learn_recipe(p, "iron_sword"), "повторно не учится")

	# 2. Rare faction recipes are single-run and are not learned.
	p.inventory = ["Recipe faction_humans_heavy_head"]
	_check(not CraftDB.learn_recipe(p, "faction_humans_heavy_head"),
		"редкий рецепт не учится")
	_check(p.inventory.has("Recipe faction_humans_heavy_head"),
		"редкий свиток остаётся до ковки")
	_check(CraftDB.is_rare_recipe_id("faction_humans_heavy_head"),
		"фракционный рецепт помечен редким")

	# 2a. A rare scroll is spent by the craft itself.
	p.smithing_skill = 20
	p.inventory = ["Recipe faction_humans_heavy_head",
		"steel Ingot", "steel Ingot", "steel Ingot", "steel Ingot",
		"steel Ingot", "steel Ingot", "Fabric", "Alliance Tag"]
	var craft_tab := CraftTab.new()
	craft_tab.setup(p, CraftDB.SMITH)
	var made := str(craft_tab.call("_craft",
		CraftDB.recipe_by_id("faction_humans_heavy_head")))
	_check(made.begins_with("Создано"), "редкий рецепт скрафчен (%s)" % made)
	_check(not p.inventory.has("Recipe faction_humans_heavy_head"),
		"редкий свиток израсходован крафтом")
	craft_tab.free()

	# 2b. The senior catalyst has its own readable name and icon: it used to
	# share the essence icon and show "???? ?????" in the master tab.
	var core := ItemDB.find("Boss Core")
	_check(not str(core.get("name_ru", "")).contains("?"),
		"у Boss Core читаемое имя (%s)" % str(core.get("name_ru", "")))
	_check(not str(core.get("icon", "")).ends_with("magic_essence.png"),
		"у Boss Core своя иконка, не эссенция")

	# 3. A plus item is synthesized from its key and keeps its own stats.
	var base_key := "Crafted iron Long Sword"
	var base := ItemDB.find(base_key)
	var plus_key := ItemDB.plus_key(base_key, 3, "a7")
	var plus_item := ItemDB.find(plus_key)
	_check(ItemDB.plus_of(plus_key) == 3, "плюс читается из ключа")
	_check(ItemDB.base_key(plus_key) == base_key, "база читается из ключа")
	_check(str(plus_item.get("name_ru", "")).ends_with(" +3"), "имя содержит +3")
	_check(int(plus_item.get("damage_max", 0)) > int(base.get("damage_max", 0)),
		"урон +3 выше базы")
	_check(int(plus_item.get("price", 0)) > int(base.get("price", 0)),
		"цена +3 выше базы")

	# 4. Caps: quality and mastering skill.
	var master_base := ItemDB.find("Crafted Master iron Long Sword")
	p.mastering_skill = 0
	_check(ForgeDB.cap_for(base, p) == 3, "Crafted без навыка — потолок +3")
	p.mastering_skill = 20
	_check(ForgeDB.cap_for(master_base, p) == 5, "Master, навык 20 — потолок +5")
	p.mastering_skill = 60
	_check(ForgeDB.cap_for(master_base, p) == 7, "Master, навык 60 — потолок +7")

	# Starter/loot gear is not masterwork material: the master must reject it
	# and the list must not show it.
	var starter := ItemDB.find("Common bronze Long Sword")
	p.mastering_skill = 60
	_check(not ForgeDB.is_forgeable(starter), "Common-меч не улучшается")
	_check(ForgeDB.can_upgrade(starter, p) != "",
		"мастер объясняет, почему Common нельзя улучшать")
	var tab := CraftMasterTab.new()
	tab.setup(p, CraftDB.MASTER)
	p.inventory = [str(starter.get("key", "")), "Crafted Master iron Long Sword"]
	var listed: Array = tab.call("_items")
	var starter_listed := false
	for e in listed:
		if str(e.get("key", "")) == str(starter.get("key", "")):
			starter_listed = true
	_check(not starter_listed, "стартовый меч скрыт из списка мастера")
	tab.free()

	# 5. +1 is guaranteed, replaces the key and follows the equipped slot.
	p.inventory = [base_key, "Magic Essence", "Magic Essence", "iron Ingot",
		"iron Ingot", "iron Ingot"]
	p.equipped = {"weapon": base_key}
	var up := ForgeDB.upgrade(p, base_key)
	_check(bool(up.get("ok", false)), "улучшение +1 прошло")
	var new_key := str(up.get("new_key", ""))
	_check(ItemDB.plus_of(new_key) == 1, "новая вещь +1")
	_check(not p.inventory.has(base_key) and p.inventory.has(new_key),
		"ключ заменён в инвентаре")
	_check(str(p.equipped.get("weapon", "")) == new_key,
		"экипировка перешла на новый ключ")

	# 6. +6 failure keeps the item (soft fail) and consumes the catalyst.
	var master_key := "Crafted Master iron Long Sword"
	var p5 := ItemDB.plus_key(master_key, 5, "b1")
	p.inventory = [p5, "Magic Essence", "Magic Essence", "Magic Essence",
		"Magic Essence", "iron Ingot", "iron Ingot", "iron Ingot",
		"iron Ingot", "iron Ingot", "iron Ingot", "iron Ingot", "iron Ingot",
		"Boss Core"]
	var fail6 := ForgeDB.upgrade(p, p5, null, 99)
	_check(not bool(fail6.get("ok", true)), "+6 с провалом не улучшился")
	_check(str(fail6.get("new_key", "")) == p5, "после провала +6 вещь та же")
	_check(p.inventory.has(p5), "вещь не потеряна")
	_check(not p.inventory.has("Boss Core"), "катализатор сгорел")

	# 7. +7 failure from +6 falls back to +5.
	var p6 := ItemDB.plus_key(master_key, 6, "c1")
	p.inventory = [p6, "Magic Essence", "Magic Essence", "Magic Essence",
		"Magic Essence", "Magic Essence", "iron Ingot", "iron Ingot",
		"iron Ingot", "iron Ingot", "iron Ingot", "iron Ingot", "iron Ingot",
		"iron Ingot", "iron Ingot", "Boss Core", "Boss Core"]
	p.inventory.append("iron Ingot")
	var fail7 := ForgeDB.upgrade(p, p6, null, 99)
	_check(not bool(fail7.get("ok", true)), "+7 с провалом не улучшился")
	_check(ItemDB.plus_of(str(fail7.get("new_key", ""))) == 5,
		"после провала +7 откат на +5")

	# 8. Success at +7 works with a lucky roll.
	var p6b := ItemDB.plus_key(master_key, 6, "c2")
	p.inventory = [p6b, "Magic Essence", "Magic Essence", "Magic Essence",
		"Magic Essence", "Magic Essence", "iron Ingot", "iron Ingot",
		"iron Ingot", "iron Ingot", "iron Ingot", "iron Ingot", "iron Ingot",
		"iron Ingot", "iron Ingot", "Boss Core", "Boss Core"]
	p.inventory.append("iron Ingot")
	var ok7 := ForgeDB.upgrade(p, p6b, null, 0)
	_check(bool(ok7.get("ok", false)), "+7 с удачей прошёл")
	_check(ItemDB.plus_of(str(ok7.get("new_key", ""))) == 7, "новая вещь +7")

	p.queue_free()
	_finish()


func _finish() -> void:
	print("")
	if _fails.is_empty():
		print("RESULT: OK forge_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL forge_smoke (%d checks, %d fails)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)
