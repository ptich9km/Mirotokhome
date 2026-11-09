extends SceneTree
## Alchemy rework (09.11): recipes, tiers, skill gates, elixir effects.
##
## What this guard protects:
##   * every recipe points at a real item and at real herbs;
##   * permanent stat potions (body/mind/reaction/spirit) stay UNCRAFTABLE -
##     they are quest rewards by the player's decision;
##   * the skill gate is monotone by tier and really blocks the bench;
##   * brewing spends exactly the recipe and grants alchemy experience;
##   * the elixirs reach combat through the existing status channels
##     (attack/defense bless, elemental resist, haste);
##   * a potion is always worth more than its herbs, or crafting is pointless.
##
## Run: godot --headless --path . --script res://tests/alchemy_smoke.gd

const RECIPES := "res://assets/professions/alchemy/recipes.json"
const PERMANENT := ["Potion Body", "Potion Mind", "Potion Reaction", "Potion Spirit"]
const ELIXIRS := ["Potion Elixir Rage", "Potion Elixir Stone",
	"Potion Elixir Fire Ward", "Potion Elixir Frost Ward",
	"Potion Elixir Wind", "Potion Elixir Mending", "Potion Elixir Fury"]

var _fails: Array[String] = []
var _checks := 0
var _recipes: Array = []


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print("ALCHEMY: %s %s" % ["ok  " if ok else "FAIL", what])


func _initialize() -> void:
	ItemDB.ensure_loaded()
	HerbDB.ensure_loaded()
	call_deferred("_run")


func _run() -> void:
	_test_data()
	_test_herbs()
	_test_pricing()
	_test_player_buffs()
	await _test_panel()
	_finish()


func _test_data() -> void:
	_recipes = _load_recipes()
	_check(_recipes.size() == 16, "16 рецептов (%d)" % _recipes.size())

	var tiers: Dictionary = {}
	var bad_output: Array[String] = []
	var bad_ingredient: Array[String] = []
	var craftable_permanent: Array[String] = []
	for recipe in _recipes:
		var tier := int(recipe.get("tier", 0))
		tiers[tier] = true
		var output := str(recipe.get("output", ""))
		if ItemDB.find(output).is_empty() or str(ItemDB.find(output).get("quality", "")) != "Potion":
			bad_output.append(output)
		if output in PERMANENT:
			craftable_permanent.append(output)
		# A permanent effect has no "duration" - that is exactly what the player
		# forbade from the bench.
		for raw in ItemDB.find(output).get("effects", []):
			var low := str(raw).to_lower()
			if "duration" in low:
				continue
			if low.begins_with("body=") or low.begins_with("mind=") \
					or low.begins_with("reaction=") or low.begins_with("spirit="):
				craftable_permanent.append(output)
		for ingredient in recipe.get("ingredients", []):
			var key := str((ingredient as Dictionary).get("item", ""))
			var item := ItemDB.find(key)
			if item.is_empty() or str(item.get("quality", "")) != "Herb":
				bad_ingredient.append(key)
	_check(bad_output.is_empty(), "все результаты существуют (%s)" % str(bad_output))
	_check(bad_ingredient.is_empty(), "все ингредиенты — травы (%s)" % str(bad_ingredient))
	_check(craftable_permanent.is_empty(),
		"перманентные зелья НЕ варятся (%s)" % str(craftable_permanent))
	_check(tiers.size() == 4 and tiers.has(1) and tiers.has(2) and tiers.has(3) and tiers.has(4),
		"покрыты все 4 тира")

	# Skill gates grow with the tier: a later tier is never cheaper than an
	# earlier one, otherwise the progression is a lie.
	var gate: Dictionary = {}
	for recipe in _recipes:
		var tier := int(recipe.get("tier", 1))
		gate[tier] = maxi(int(gate.get(tier, 0)), int(recipe.get("skill_min", 0)))
	var monotone := int(gate.get(1, 0)) <= int(gate.get(2, 0)) \
		and int(gate.get(2, 0)) <= int(gate.get(3, 0)) \
		and int(gate.get(3, 0)) <= int(gate.get(4, 0))
	_check(monotone, "пороги навыка растут с тиром %s" % str(gate))
	_check(int(gate.get(1, 0)) == 0, "тир 1 доступен с нуля")
	_check(int(gate.get(4, 0)) >= 15, "тир 4 требует навык не ниже 15")

	# Tier 4 must be reachable only with the rare herbs, tier 1 with the cheap ones.
	var tier1_ok := true
	var tier4_ok := true
	for recipe in _recipes:
		var tier := int(recipe.get("tier", 1))
		var herb_tiers: Array = []
		for ingredient in recipe.get("ingredients", []):
			herb_tiers.append(HerbDB.tier_of(str((ingredient as Dictionary).get("item", ""))))
		if tier == 1 and (herb_tiers.has(3) or herb_tiers.has(4)):
			tier1_ok = false
		if tier == 4 and not herb_tiers.has(4):
			tier4_ok = false
	_check(tier1_ok, "тир 1 не требует редких трав")
	_check(tier4_ok, "тир 4 всегда требует траву тира 4")


func _test_herbs() -> void:
	var herbs := HerbDB.all()
	_check(herbs.size() == 12, "12 трав в HerbDB (%d)" % herbs.size())
	var missing_icon: Array[String] = []
	var tiers: Dictionary = {}
	for key in herbs:
		tiers[int(HerbDB.tier_of(str(key)))] = true
		var path := HerbDB.icon_of(str(key))
		if path == "" or not ResourceLoader.exists(path):
			missing_icon.append(str(key))
	_check(missing_icon.is_empty(), "у всех трав есть иконка (%s)" % str(missing_icon))
	_check(tiers.has(1) and tiers.has(2) and tiers.has(3) and tiers.has(4),
		"травы покрывают тиры 1..4")
	_check(HerbDB.wild_tier_min() == 3, "редкие травы начинаются с тира 3")

	var zones: Array = HerbDB.zones()
	_check(zones.size() == 4, "четыре зоны в таблице трав (%d)" % zones.size())
	for zone in zones:
		var pool := HerbDB.zone_pool(str(zone))
		_check(not pool.is_empty(), "пул зоны %s не пуст" % str(zone))
		var broken: Array[String] = []
		for entry in pool:
			var key := str((entry as Dictionary).get("item", ""))
			if not HerbDB.has(key) or ItemDB.find(key).is_empty():
				broken.append(key)
		_check(broken.is_empty(), "пул %s ссылается на существующие травы (%s)" % [str(zone), str(broken)])
	var start_pool := HerbDB.zone_pool("start")
	var start_has_rare := false
	for entry in start_pool:
		if HerbDB.tier_of(str((entry as Dictionary).get("item", ""))) >= 3:
			start_has_rare = true
	_check(not start_has_rare, "в стартовой зоне нет редких трав")
	var faction_has_t4 := false
	for entry in HerbDB.zone_pool("faction"):
		if HerbDB.tier_of(str((entry as Dictionary).get("item", ""))) == 4:
			faction_has_t4 = true
	_check(faction_has_t4, "в зоне фракций есть травы тира 4")


func _test_pricing() -> void:
	var bad: Array[String] = []
	for recipe in _recipes:
		var output := ItemDB.find(str(recipe.get("output", "")))
		var price := int(output.get("price", 0))
		var herbs := 0
		for ingredient in recipe.get("ingredients", []):
			var key := str((ingredient as Dictionary).get("item", ""))
			herbs += int(ItemDB.find(key).get("price", 0)) * int((ingredient as Dictionary).get("count", 1))
		if price <= herbs:
			bad.append("%s %d<=%d" % [str(recipe.get("output", "")), price, herbs])
	_check(bad.is_empty(), "зелье дороже своих трав (%s)" % str(bad))


func _test_player_buffs() -> void:
	var p := Player.new()
	root.add_child(p)
	await process_frame
	Game.hero = p
	p.max_hp = 200
	p.current_hp = 50
	p.max_mana = 100
	p.current_mana = 10

	# Rage: a flat attack bonus that combat already reads.
	p.inventory = ["Potion Elixir Rage"]
	var base_attack := p.get_attack()
	p.use_potion("Potion Elixir Rage")
	_check(StatusEffects.stat_flat(p, "attack") == 12,
		"ярость даёт +12 к атаке (%d)" % StatusEffects.stat_flat(p, "attack"))
	_check(p.get_attack() == base_attack + 12, "атака героя выросла")
	_check(not p.inventory.has("Potion Elixir Rage"), "эликсир потрачен")

	# Stone: defense.
	p.inventory = ["Potion Elixir Stone"]
	p.use_potion("Potion Elixir Stone")
	_check(StatusEffects.stat_flat(p, "defense") == 15,
		"камень даёт +15 к защите (%d)" % StatusEffects.stat_flat(p, "defense"))

	# Fire ward: an elemental resistance, spheres are capitalised in this project.
	p.inventory = ["Potion Elixir Fire Ward"]
	var before := p.get_protection_fire()
	p.use_potion("Potion Elixir Fire Ward")
	_check(p.get_protection_fire() == before + 25,
		"огненная защита +25 (%d -> %d)" % [before, p.get_protection_fire()])
	_check(StatusEffects.resist_bonus(p, "Water") == 0, "вода не получила огненную защиту")

	# Wind: haste through speed_mult.
	p.inventory = ["Potion Elixir Wind"]
	p.use_potion("Potion Elixir Wind")
	_check(StatusEffects.speed_mult(p) > 1.2,
		"ветер ускоряет (x%.2f)" % StatusEffects.speed_mult(p))

	# Mending: fast regeneration.
	p.inventory = ["Potion Elixir Mending"]
	p.current_hp = 10
	p.use_potion("Potion Elixir Mending")
	_check(StatusEffects.has_effect(p, "regen"), "исцеление даёт регенерацию")
	for i in 20:
		StatusEffects.tick(1.0)
	_check(p.current_hp > 100, "за 20 с регенерировало больше половины (HP=%d)" % p.current_hp)

	# The old potions still work: the parser did not swallow them.
	p.inventory = ["Potion Small Healing"]
	p.current_hp = 10
	p.use_potion("Potion Small Healing")
	_check(p.current_hp == 22, "малое лечение по-прежнему +12")

	p.queue_free()
	Game.hero = null


func _test_panel() -> void:
	var p := Player.new()
	root.add_child(p)
	await process_frame
	Game.hero = p
	p.alchemy_skill = 0
	p.inventory = _all_herbs(30)

	var panel := AlchemyPanel.new()
	panel.setup(p)
	root.add_child(panel)
	await process_frame

	var low := _recipe_index(panel, "small_healing")
	var high := _recipe_index(panel, "elixir_fury")
	_check(low >= 0 and high >= 0, "панель нашла рецепты по id")
	_check(not panel._is_locked(panel._recipes[low]), "малое лечение доступно без навыка")
	_check(panel._is_locked(panel._recipes[high]), "неистовство закрыто без навыка")

	# Crafting the tier-1 potion: exact spend + experience.
	var before_herbs := p.inventory.size()
	var before_exp := int(p.experience.get("alchemy", 0))
	panel._select_recipe(low)
	await process_frame
	panel._create_selected()
	await process_frame
	_check(p.inventory.has("Potion Small Healing"), "варка положила зелье в сумку")
	_check(int(p.experience.get("alchemy", 0)) == before_exp + 60,
		"варка дала 60 опыта (%d)" % int(p.experience.get("alchemy", 0)))
	_check(p.inventory.size() == before_herbs - 2,
		"списано ровно 3 травы и добавлено зелье (%d -> %d)" % [before_herbs, p.inventory.size()])

	# Locked recipe refuses even with full bags.
	var before_fury := _count(p, "Potion Elixir Fury")
	panel._select_recipe(high)
	await process_frame
	panel._create_selected()
	await process_frame
	_check(_count(p, "Potion Elixir Fury") == before_fury, "закрытый рецепт не варится")

	# Enough skill -> the same recipe opens.
	p.alchemy_skill = 20
	panel._refresh()
	await process_frame
	_check(not panel._is_locked(panel._recipes[high]), "с навыком 20 неистовство открыто")
	var before := _count(p, "Potion Elixir Fury")
	panel._select_recipe(high)
	await process_frame
	panel._create_selected()
	await process_frame
	_check(_count(p, "Potion Elixir Fury") == before + 1, "с навыком 20 неистовство варится")

	# No ingredients -> nothing happens.
	p.inventory = []
	panel._refresh()
	await process_frame
	_check(not panel._can_craft(panel._recipes[low]), "без трав кнопка варки закрыта")
	panel._select_recipe(low)
	await process_frame
	panel._create_selected()
	await process_frame
	_check(not p.inventory.has("Potion Small Healing"), "без трав ничего не сварилось")

	panel.close()
	await process_frame
	p.queue_free()
	Game.hero = null


func _all_herbs(count: int) -> Array:
	var out: Array = []
	for key in HerbDB.keys():
		for i in count:
			out.append(str(key))
	return out


func _count(p: Player, key: String) -> int:
	var n := 0
	for item_key in p.inventory:
		if str(item_key) == key:
			n += 1
	return n


func _recipe_index(panel: AlchemyPanel, id: String) -> int:
	for index in range(panel._recipes.size()):
		if str((panel._recipes[index] as Dictionary).get("id", "")) == id:
			return index
	return -1


func _load_recipes() -> Array:
	var file := FileAccess.open(RECIPES, FileAccess.READ)
	if file == null:
		_check(false, "recipes.json открывается")
		return []
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		_check(false, "recipes.json — словарь")
		return []
	return (parsed as Dictionary).get("recipes", [])


func _finish() -> void:
	print("")
	if _fails.is_empty():
		print("RESULT: OK alchemy_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL alchemy_smoke (%d checks, %d fails)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)
