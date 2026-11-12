extends SceneTree
## Headless-проверка того, что ЭКИПИРОВКА влияет на бой.
##
## До правки экипировка меняла только набор анимации (armor_kind/weapon/has_shield)
## и не сохраняла предмет, поэтому get_attack/get_defense/get_absorption считали
## чистые формулы по атрибутам: тяжёлая броня с защитой 14 давала ровно столько
## же, сколько её отсутствие, а клинок за 500 золотых не менял урон.
##
## Проверяет:
##  1. надетый предмет меняет урон, атаку, защиту, поглощение и сопротивление;
##  2. стартовое снаряжение надето сразу (новый герой не выходит голым);
##  3. снятие экипировки возвращает статы к базовым;
##  4. формула попадания ОТНОСИТЕЛЬНАЯ: броня реально снижает шанс,
##     и одинаково работает и для слабого, и для сильного атакующего;
##  5. предметы, которые нельзя надеть, остаются непроведёнными.
##
## Запуск:
##   godot --headless --path . --script res://tests/equipment_combat_smoke.gd

## Реальные ключи из item_db.json. ItemDB.all() отдаёт МАССИВ СЛОВАРЕЙ,
## а не ключи, поэтому ключи достаём полями Dictionary.
const LIGHT_ARMOR := "Common Linen Cloak"   # лёгкая ткань, слот cloak (кожа удалена 01.10)
const HEAVY_ARMOR := "Crafted Master gold Cuirass"   # defence 22 — верхняя граница (пакет A: radium удалён)
const BUCKLER := "Common bronze Buckler"

var _fails: Array = []
var _hero: Player = null


func _initialize() -> void:
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 13, "spirit": 12,
		"blade": 10, "bludgeon": 10, "pike": 10, "shooting": 10,
		"fire": 20, "water": 20, "air": 20, "earth": 20, "astral": 20,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.hero_class = "warrior"
	Game.hero_name = "Воин"
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails.append(what)
	print("EQP: %s %s" % ["ok  " if ok else "FAIL", what])


func _run() -> void:
	var err := change_scene_to_file("res://scenes/main.tscn")
	if err != OK:
		_check(false, "загрузка main.tscn: %d" % err)
		_finish()
		return
	await process_frame
	await create_timer(0.6).timeout
	_hero = get_first_node_in_group("player") as Player
	if _hero == null:
		_check(false, "герой не загружен")
		_finish()
		return

	_test_starter_equipped()
	_test_armor_changes_defense()
	_test_weapon_changes_damage()
	_test_unequip_restores()
	_test_not_equippable()
	_test_class_rule()
	_test_hit_chance_relative()
	_finish()


# --- 1. Стартовое снаряжение надето ---------------------------------------

func _test_starter_equipped() -> void:
	_check(not _hero.equipped.is_empty(),
		"стартовое снаряжение надето при создании героя (%s)" % str(_hero.equipped.keys()))
	_check(_hero.equipped.has("weapon"), "надето оружие")
	_check(_hero.equipped.has("shield"), "надет щит (слот shield)")
	_check(not _hero.equipped.has("body"), "стартовой брони нет (слот body пуст)")
	# Модель A: надетое живёт ТОЛЬКО в equipped, из склада ушло.
	for slot in _hero.equipped.keys():
		var ek := str(_hero.equipped[slot])
		_check(not _hero.inventory.has(ek),
			"надетое %s (%s) НЕ в складе (модель A)" % [slot, ek])


# --- 2. Броня меняет защиту -----------------------------------------------

func _test_armor_changes_defense() -> void:
	var light := ItemDB.find(LIGHT_ARMOR)
	var heavy := ItemDB.find(HEAVY_ARMOR)
	_check(not light.is_empty(), "в базе есть %s" % LIGHT_ARMOR)
	_check(not heavy.is_empty(), "в базе есть %s" % HEAVY_ARMOR)
	if light.is_empty() or heavy.is_empty():
		return
	# Ищем броню, которая действительно тяжелее — сравниваем по числам базы.
	var def_light := int(light.get("defence", 0))
	var def_heavy := int(heavy.get("defence", 0))

	_hero.equipped.erase("body")
	_hero.equipped.erase("shield")
	var naked := _hero.get_defense()
	_hero.equipped["cloak"] = LIGHT_ARMOR
	var in_light := _hero.get_defense()
	# Плащ и кирас сели бы в РАЗНЫЕ слоты и сложились бы вместе. Раньше оба
	# были в "body" и замещали друг друга; с лёгкой тканью в слоте cloak надо
	# снимать cloak перед замером тяжёлой брони, иначе сравнение бессмысленно.
	_hero.equipped.erase("cloak")
	_hero.equipped["body"] = HEAVY_ARMOR
	var in_heavy := _hero.get_defense()

	_check(in_light > naked,
		"лёгкая броня добавляет защиту: %d -> %d (defence в базе %d)"
			% [naked, in_light, def_light])
	_check(in_heavy > in_light,
		"тяжёлая броня добавляет больше защиты: %d -> %d (defence в базе %d)"
			% [in_light, in_heavy, def_heavy])
	# Ключевое: вклад вещей — ПОЛНЫЙ, а не «делённый на 10».
	_check(in_heavy - in_light == def_heavy - def_light,
		"защита берётся из базы без уменьшения (разница %d = разница в базе %d)"
			% [in_heavy - in_light, def_heavy - def_light])

	# Поглощение и сопротивление тоже.
	_hero.equipped.erase("body")
	_hero.equipped["cloak"] = LIGHT_ARMOR
	var abs_light := _hero.get_absorption()
	var prot_light := _hero.get_protection_fire()
	_hero.equipped.erase("cloak")
	_hero.equipped["body"] = HEAVY_ARMOR
	_check(_hero.get_absorption() >= abs_light,
		"поглощение не падает от смены брони (%d -> %d)" % [abs_light, _hero.get_absorption()])
	_check(_hero.get_protection_fire() != prot_light
			or int(heavy.get("magcap", 0)) == int(light.get("magcap", 0)),
		"сопротивление учитывает magcap брони (%d -> %d)"
			% [prot_light, _hero.get_protection_fire()])


# --- 3. Оружие меняет урон и атаку -----------------------------------------

func _test_weapon_changes_damage() -> void:
	_hero.equipped.erase("weapon")
	var bare_min := _hero.get_damage_min()
	var bare_max := _hero.get_damage_max()
	var bare_atk := _hero.get_attack()
	var bare_unarmed_max := _hero.unarmed_damage_max()

	# Ищем в базе оружие с ненулевым уроном. all() — массив словарей.
	var weapon_key := ""
	var weapon_item: Dictionary = {}
	for raw in ItemDB.all():
		var it: Dictionary = raw
		if ItemDB.slot_of(it) == "weapon" and int(it.get("damage_max", 0)) > 0:
			weapon_key = str(it.get("key", ""))
			weapon_item = it
			break
	_check(weapon_key != "", "найдено оружие с уроном в базе")
	if weapon_key == "":
		return
	_hero.equipped["weapon"] = weapon_key

	var w_min := int(weapon_item.get("damage_min", 0))
	var w_max := int(weapon_item.get("damage_max", 0))
	# С оружием урон НЕ равен голому предмету: база масштабируется навыком/атрибутами.
	_check(_hero.get_damage_max() >= w_max,
		"урон с оружием >= базы предмета: %d >= %d (было без оружия %d)"
			% [_hero.get_damage_max(), w_max, bare_max])
	_check(_hero.get_damage_min() >= w_min,
		"мин. урон с оружием >= базы: %d >= %d" % [_hero.get_damage_min(), w_min])
	_check(_hero.get_damage_max() > bare_unarmed_max,
		"с оружием сильнее кулака: %d > %d" % [_hero.get_damage_max(), bare_unarmed_max])
	_check(_hero.get_attack() >= bare_atk + int(weapon_item.get("to_hit", 0)),
		"to_hit оружия входит в атаку: %d -> %d (to_hit=%d)"
			% [bare_atk, _hero.get_attack(), int(weapon_item.get("to_hit", 0))])


# --- 4. Снятие возвращает базовые статы ------------------------------------

func _test_unequip_restores() -> void:
	_hero.equipped["body"] = HEAVY_ARMOR
	_hero.equipped["weapon"] = "Common iron Long Sword"
	var with_gear := _hero.get_defense()
	_hero.equipped.clear()
	var without := _hero.get_defense()
	_check(without < with_gear,
		"без экипировки защита ниже: %d (было %d)" % [without, with_gear])
	# Вернуть стартовое, чтобы следующие проверки были на нормальном герое.
	_hero.equip_item(ItemDB.find("Common iron Long Sword"))
	_hero.equip_item(ItemDB.find(LIGHT_ARMOR))


# --- 5. Нельзя надеть то, что не экипируется -------------------------------

func _test_not_equippable() -> void:
	# Слиток — сырьё: он проходил как броня и кузнец переплавлял бы его в себя.
	var ingot_key := ""
	for raw in ItemDB.all():
		var it: Dictionary = raw
		if str(it.get("type", "")) == "Ingot":
			ingot_key = str(it.get("key", ""))
			break
	_check(ingot_key != "", "в базе есть слиток")
	if ingot_key == "":
		return
	var ingot := ItemDB.find(ingot_key)
	_check(not _hero.equip_item(ingot), "слиток %s не надевается" % ingot_key)
	_check(not _hero.equipped.values().has(ingot_key), "слиток не попал в слоты")

	# Трава — ингредиент, не одежда.
	var herb_key := ""
	for raw2 in ItemDB.all():
		var it2: Dictionary = raw2
		if str(it2.get("quality", "")) == "Herb":
			herb_key = str(it2.get("key", ""))
			break
	if herb_key != "":
		_check(not _hero.equip_item(ItemDB.find(herb_key)),
			"трава %s не надевается" % herb_key)

	# Щит нельзя в двухручник.
	_hero.equip_item(ItemDB.find("Common iron Long Sword"))
	var two_handed := ItemDB.is_two_handed(ItemDB.find("Common iron Long Sword"))
	if two_handed:
		_check(not _hero.equip_item(ItemDB.find(BUCKLER)),
			"щит не надевается на двуручное оружие")
		_check(not _hero.equipped.has("shield"), "щит не занял слот на двуручнике")
	# Вернуть одноручное, чтобы герой остался с оружием.
	_hero.equip_item(ItemDB.find("Common iron Long Sword"))


# --- 5b. Правило класса (решение игрока 22.10) --------------------------

## Воин носит металл и оружие (но не посох), маг — только ткань и посохи;
## амулет, кольца и плащ подходят обоим, лук и арбалет — только воину.
func _test_class_rule() -> void:
	const SWORD := "Common iron Long Sword"
	const BOW := "Common iron Short Bow"
	const XBOW := "Uncommon steel Crossbow"
	const STAFF := "Common Wood Staff"
	const AMULET := "Common bronze Amulet"
	const CLOAK := "Common Linen Cloak"
	var ring_key := ""
	for raw in ItemDB.all():
		if str((raw as Dictionary).get("type", "")) == "Ring":
			ring_key = str((raw as Dictionary).get("key", ""))
			break
	var keys := [SWORD, BOW, XBOW, STAFF, AMULET, CLOAK, HEAVY_ARMOR, ring_key]
	for k in keys:
		_check(not ItemDB.find(str(k)).is_empty(), "в базе есть %s" % k)

	Game.hero_class = "warrior"
	_check(_hero.equip_item(ItemDB.find(SWORD)), "воин надевает меч")
	_check(_hero.equip_item(ItemDB.find(BOW)), "воин надевает лук")
	_check(_hero.equip_item(ItemDB.find(XBOW)), "воин надевает арбалет")
	_check(_hero.equip_item(ItemDB.find(HEAVY_ARMOR)), "воин надевает металлическую броню")
	_check(not _hero.equip_item(ItemDB.find("Common Linen Robe")), "воин НЕ надевает тканевую робу")
	_check(_hero.equip_item(ItemDB.find(AMULET)), "воин надевает амулет")
	_check(_hero.equip_item(ItemDB.find(CLOAK)), "воин надевает плащ")
	if ring_key != "":
		_check(_hero.equip_item(ItemDB.find(ring_key)), "воин надевает кольцо")
	_check(not _hero.equip_item(ItemDB.find(STAFF)),
		"воин НЕ надевает посох (раньше надевал)")
	_check(str(_hero.equipped.get("weapon", "")) != STAFF, "посох не занял слот оружия у воина")

	Game.hero_class = "mage"
	_hero.equipped.erase("weapon")
	_hero.equipped.erase("shield")
	_hero.equipped.erase("body")
	_check(_hero.equip_item(ItemDB.find(STAFF)), "маг надевает посох")
	_check(_hero.equip_item(ItemDB.find("Common Linen Robe")), "маг надевает тканевую одежду")
	_check(_hero.equip_item(ItemDB.find(CLOAK)), "маг надевает плащ")
	_check(_hero.equip_item(ItemDB.find(AMULET)), "маг надевает амулет")
	if ring_key != "":
		_check(_hero.equip_item(ItemDB.find(ring_key)), "маг надевает кольцо")
	_check(not _hero.equip_item(ItemDB.find(SWORD)), "маг НЕ надевает меч")
	_check(not _hero.equip_item(ItemDB.find(BOW)), "маг НЕ надевает лук")
	_check(not _hero.equip_item(ItemDB.find(XBOW)), "маг НЕ надевает арбалет")
	_check(not _hero.equip_item(ItemDB.find(HEAVY_ARMOR)), "маг НЕ надевает металлическую броню")
	_check(not _hero.equip_item(ItemDB.find(BUCKLER)), "маг НЕ надевает щит")
	_check(str(_hero.equipped.get("weapon", "")) == STAFF,
		"отказы не сбили посох из слота оружия (в слоте %s)" % str(_hero.equipped.get("weapon", "")))

	_check(ItemDB.class_block_text(ItemDB.find(STAFF), "warrior") != "",
		"подсказка объясняет отказ воину от посоха")
	_check(ItemDB.class_block_text(ItemDB.find(HEAVY_ARMOR), "mage") != "",
		"подсказка объясняет отказ магу от металла")
	_check(ItemDB.allows_class(ItemDB.find("Common Linen Cloak"), "mage"),
		"плащ подходит магу")
	_check(ItemDB.class_block_text(ItemDB.find(AMULET), "mage") == "",
		"амулет — без объяснения отказа (подходит обоим)")
	_check(ItemDB.slot_fits_text("weapon", "mage") == Loc.t("ui.slot.fits.staff"),
		"пустой слот оружия мага рассказывает про посох")

	# Вернуть воина: дальнейшие проверки — про его экипировку.
	Game.hero_class = "warrior"
	_hero.equipped.erase("body")
	_hero.equipped.erase("cloak")
	_hero.unequip_slot("weapon")


# --- 6. Формула попадания относительная -----------------------------------

func _test_hit_chance_relative() -> void:
	# Равные статы -> BASE.
	_check(Game.hit_chance(10, 10) == GameConfig.geti("combat", "hit_base"),
		"равные статы дают базовый шанс %d (получено %d)"
			% [GameConfig.geti("combat", "hit_base"), Game.hit_chance(10, 10)])

	# Броня РЕАЛЬНО снижает шанс — это и было главным требованием.
	var naked := Game.hit_chance(10, 5)
	var armored := Game.hit_chance(10, 23)
	_check(naked > armored,
		"броня снижает шанс попадания: без брони %d %%, в тяжёлой %d %%"
			% [naked, armored])
	_check(naked <= GameConfig.geti("combat", "hit_max"), "без брони шанс не выше максимума")

	# Относительность: та же броня одинаково мешает и слабому, и сильному врагу.
	var vs_weak := Game.hit_chance(4, 23)      # гоблин
	var vs_weak_naked := Game.hit_chance(4, 5)
	var vs_strong := Game.hit_chance(30, 23)   # тролль
	var vs_strong_naked := Game.hit_chance(30, 5)
	_check(vs_weak < vs_weak_naked and vs_strong < vs_strong_naked,
		"броня снижает шанс и против слабого (%d->%d), и против сильного (%d->%d)"
			% [vs_weak_naked, vs_weak, vs_strong_naked, vs_strong])
	_check(vs_strong_naked <= GameConfig.geti("combat", "hit_max") and vs_strong <= GameConfig.geti("combat", "hit_max"),
		"сильный атакующий не выходит за максимум ни голым, ни в броне")

	# Границы соблюдаются на краях.
	_check(Game.hit_chance(0, 999) == GameConfig.geti("combat", "hit_min"), " нижний кламп %d" % GameConfig.geti("combat", "hit_min"))
	_check(Game.hit_chance(999, 0) == GameConfig.geti("combat", "hit_max"), "верхний кламп %d" % GameConfig.geti("combat", "hit_max"))
	_check(Game.hit_chance(0, 0) == GameConfig.geti("combat", "hit_base"), "нулевые статы не дают деления на ноль")


func _finish() -> void:
	if _fails.is_empty():
		print("EQP: RESULT: OK")
	else:
		print("EQP: RESULT: FAIL (%d): %s" % [_fails.size(), str(_fails)])
	quit(0 if _fails.is_empty() else 1)
