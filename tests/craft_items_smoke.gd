extends SceneTree

## Инварианты мастерской (пакет 1, 07.10).
##
## ЗАМЕНИЛ blacksmith_smoke, который звал panel.call("_smelt_item", key) по
## имени метода и держал контракт на классе BlacksmithPanel. Класс удалён,
## панель стала WorkshopPanel с вкладками, и проверять надо то, что реально
## защищает петлю «убил НПЦ -> сломанная вещь -> переработка -> рецепт».
##
## ПРАВИЛО ТЕСТОВ ЭТОГО ПРОЕКТА (AGENTS §12, запись 03.10): тест, который
## пересчитывает решение той же формулой, что и код, проверяет себя, а не
## код. Поэтому здесь инварианты берутся ИЗ РЕАЛЬНЫХ АРТЕФАКТОВ:
##   * ключи иконок открываются с диска и сверяются с item_db;
##   * шансы уровней проверяются на СУММУ и на МОНОТОННОСТЬ, а не сравнением
##     с формулой из конфига;
##   * потребление рецепта проверяется через реальный вызов _craft() и
##     сравнение остатков в инвентаре.

# var, а НЕ const: константный Array в Godot 4 read-only, и _fails.append()
# молча падает с "Array is in read-only state" - тест физически не смог бы
# сообщить о провале и всегда печатал бы OK. Все остальные smoke-тесты в
# проекте используют var именно поэтому.
var _fails: Array[String] = []
var _checks := 0


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_fails.append(msg)


func _init() -> void:
	ItemDB.ensure_loaded()
	_test_broken_completeness()
	_test_broken_invariants()
	_test_broken_not_equippable()
	_test_armor_kind()
	_test_smeltable_split()
	_test_resources()
	_test_tier_weights()
	_test_recipes()
	_test_crafted_items()
	_test_recycle_yield()
	_test_atomic_craft()
	_test_skill_curve()
	print("checks=%d fails=%d" % [_checks, _fails.size()])
	if _fails.is_empty():
		print("RESULT: OK craft_items_smoke")
		quit(0)
	else:
		for f in _fails:
			print("FAIL %s" % f)
		print("RESULT: FAIL craft_items_smoke")
		quit(1)


# --- Полнота данных -------------------------------------------------------

## У каждого металла ровно одна сломанная броня и одно сломанное оружие на
## КАЖДОЕ из трёх качеств. Недостающая запись означала бы, что игрок при
## переплавке получит меньше, чем показывает таблица выхода.
func _test_broken_completeness() -> void:
	for metal in ItemDB._SMELTABLE:
		for category in ["Armor", "Weapon"]:
			for quality in ItemDB.BROKEN_QUALITIES:
				var key := ItemDB.broken_key(metal, category, quality)
				_check(key != "", "ключ строится: %s %s %s" % [metal, category, quality])
				if key == "":
					continue
				_check(not ItemDB.find(key).is_empty(), "запись есть: %s" % key)
				_check(ItemDB.has_broken(metal, category),
					"has_broken(%s, %s)" % [metal, category])
	for quality in ItemDB.BROKEN_QUALITIES:
		var k := ItemDB.broken_key("Linen", "Garment", quality)
		_check(not ItemDB.find(k).is_empty(), "сломанная одежда есть: %s" % k)


## Числовые поля сломанной вещи. Каждое значение проверяется по отдельности,
## потому что у них РАЗНЫЕ последствия при нарушении (см. gen_broken_items.py).
func _test_broken_invariants() -> void:
	var seen_icons := {}
	for it in ItemDB.all():
		var d: Dictionary = it
		if not ItemDB.is_broken(d):
			continue
		var key := str(d.get("key", ""))
		var damage_max := int(d.get("damage_max", -1))
		_check(damage_max == 0,
			"%s: damage_max = 0 (иначе попадёт в монотонность metal_stats)" % key)
		for field in ["damage_min", "to_hit", "defence", "absorption", "magcap"]:
			_check(int(d.get(field, -1)) == 0,
				"%s: %s = 0 (иначе меняет статы героя из инвентаря)" % [key, field])
		_check(int(d.get("price", -1)) == 0,
			"%s: price = 0 (иначе лавка продаст за 1 золота)" % key)
		var mat := str(d.get("material", ""))
		_check(mat in d.key or not ItemDB._SMELTABLE.has(mat),
			"%s: сегмент материала в ключе" % key)
		# Иконка обязана существовать на диске - item_icons_smoke проверяет
		# это для всех предметов, но здесь важно именно СВОЁ множество.
		var icon := str(d.get("icon", ""))
		_check(icon != "" and FileAccess.file_exists(icon),
			"%s: иконка есть на диске (%s)" % [key, icon])
		seen_icons[icon] = true
	# Пакет A (28.10): 16 фракционных металлов удалены — иконок сломанного
	# осталось 9 (4 металла x броня/оружие + одежда). Проверка следит, что
	# сломанное НЕ рисуется одной картинкой на всё, а не за конкретное число.
	_check(seen_icons.size() >= 9,
		"иконки сломанных вещей различаются (%d файлов, а не одна на всё)" % seen_icons.size())


## Сломанное нельзя надеть. Барьеров два, и оба проверяются: quality в
## blacklist is_equippable И пустой слот у type.
func _test_broken_not_equippable() -> void:
	for it in ItemDB.all():
		var d: Dictionary = it
		if not ItemDB.is_broken(d):
			continue
		var key := str(d.get("key", ""))
		_check(not ItemDB.is_equippable(d), "%s: is_equippable = false" % key)
		_check(ItemDB.slot_of(d) == "", "%s: слот пустой" % key)


## Сломанная одежда - лёгкая, сломанная металлическая броня - тяжёлая.
## Иначе сломанный плащ в рюкзаке считал быcя лёгкой бронёй.
func _test_armor_kind() -> void:
	for it in ItemDB.all():
		var d: Dictionary = it
		if not ItemDB.is_broken(d):
			continue
		var category := ItemDB.broken_category(d)
		var want := "heavy" if category != "Garment" else "light"
		_check(ItemDB.armor_kind(d) == want,
			"%s: armor_kind = %s" % [str(d.get("key", "")), want])


## Разделение «кузнец берёт / портной берёт»: металл (сломанное + целое
## снаряжение) у кузнеца, одежда у портного. Ресурсы крафта не переплавляются.
func _test_smeltable_split() -> void:
	var smith_ok := 0
	var smith_bad := 0
	for it in ItemDB.all():
		var d: Dictionary = it
		if not CraftDB.can_recycle(CraftDB.SMITH, d):
			continue
		if ItemDB.is_craft_material(d) or ItemDB.broken_category(d) == "Garment":
			smith_bad += 1
			continue
		if not ItemDB.is_broken(d) and ItemDB.armor_kind(d) == "light" \
				and ItemDB.slot_of(d) != "weapon":
			smith_bad += 1
			continue
		smith_ok += 1
	_check(smith_ok > 0, "кузнец принимает броню/оружие сломанное и целое (%d)" % smith_ok)
	_check(smith_bad == 0,
		"кузнец не принимает одежду и ресурсы (%d лишних)" % smith_bad)

	var tailor_ok := 0
	for it in ItemDB.all():
		var d: Dictionary = it
		if CraftDB.can_recycle(CraftDB.TAILOR, d):
			tailor_ok += 1
	_check(tailor_ok > 0, "портной принимает одежду (%d)" % tailor_ok)

	# Целая кираса: выход = 80% ресурсов рецепта iron_cuirass (6 iron + 2 Fabric).
	var cuirass := ItemDB.find("Common iron Cuirass")
	if not cuirass.is_empty():
		var y := CraftDB.recycle_yield(cuirass)
		_check(int(y.get("ingot", 0)) == 4,
			"целая iron Cuirass: 6*0.8=4 слитка (получено %d)" % int(y.get("ingot", 0)))
		_check(int(y.get("fabric", 0)) == 1,
			"целая iron Cuirass: 2*0.8=1 ткань (получено %d)" % int(y.get("fabric", 0)))
		_check(CraftDB.can_recycle(CraftDB.SMITH, cuirass),
			"целая iron Cuirass переплавляется кузнецом")


## Ресурсы крафта: есть, не экипируются, не переплавляются, не продаются за
## золото (price = 0 плюс явная фильтрация в shop_panel).
func _test_resources() -> void:
	for key in [CraftDB.FABRIC_KEY, CraftDB.ESSENCE_KEY]:
		var d := ItemDB.find(key)
		_check(not d.is_empty(), "ресурс есть: %s" % key)
		if d.is_empty():
			continue
		_check(not ItemDB.is_equippable(d), "%s: не экипируется" % key)
		_check(ItemDB.slot_of(d) == "", "%s: слот пустой" % key)
		_check(ItemDB.is_craft_material(d), "%s: is_craft_material" % key)
		_check(not ItemDB.is_smeltable(d), "%s: не переплавляется" % key)
		_check(int(d.get("price", -1)) == 0, "%s: price = 0" % key)


# --- Шансы уровней --------------------------------------------------------

## Сумма трёх шансов тождественно 100 при ЛЮБОМ навыке, и каждый уровень
## монотонно растёт. Проверка на сумму, а не сравнение с формулой: если бы
## кто-то сломал сложение коэффициентов, тест это поймал бы, а сравнение с
## продублированной формулой - нет.
func _test_tier_weights() -> void:
	for skill in [0, 1, 5, 10, 20, 40, 60, 100, 200]:
		var w := CraftDB.tier_weights(skill)
		var total := 0.0
		for v in w:
			total += v
		_check(absf(total - 100.0) < 0.01,
			"навык %d: сумма шансов = 100 (получено %.3f)" % [skill, total])
		_check(w[0] >= GameConfig.getf("craft", "floor_ordinary") - 0.001,
			"навык %d: обычная не ниже порога" % skill)
		_check(w[1] > 0.0 and w[2] > 0.0,
			"навык %d: улучшенная и мастерская возможны" % skill)
	var prev := CraftDB.tier_weights(0)
	for skill in [5, 10, 20, 40, 80]:
		var cur := CraftDB.tier_weights(skill)
		_check(cur[1] > prev[1], "улучшенная растёт с навыком (%d: %.1f > %.1f)"
			% [skill, cur[1], prev[1]])
		_check(cur[2] > prev[2], "мастерская растёт с навыком (%d: %.1f > %.1f)"
			% [skill, cur[2], prev[2]])
	# На навыке 0 - ровно те 80/15/5, которые задал игрок.
	var w0 := CraftDB.tier_weights(0)
	_check(absf(w0[0] - 80.0) < 0.01, "навык 0: обычная 80 (%.1f)" % w0[0])
	_check(absf(w0[1] - 15.0) < 0.01, "навык 0: улучшенная 15 (%.1f)" % w0[1])
	_check(absf(w0[2] - 5.0) < 0.01, "навык 0: мастерская 5 (%.1f)" % w0[2])


# --- Рецепты --------------------------------------------------------------

## Каждый рецепт валиден, все три выхода существуют и реально различаются по
## характеристикам - иначе «улучшенная вещь» была бы тем же предметом.
func _test_recipes() -> void:
	var total := 0
	for kind in [CraftDB.SMITH, CraftDB.TAILOR]:
		for r in CraftDB.recipes(kind):
			total += 1
			var rid := str(r.get("id", ""))
			var outs: Array = r.get("outputs", [])
			_check(outs.size() == 3,
				"%s: три уровня выхода (%d)" % [rid, outs.size()])
			var stats := []
			for tier in outs.size():
				var okey := str((outs[tier] as Dictionary).get("key", ""))
				var o := ItemDB.find(okey)
				_check(not o.is_empty(), "%s: выход %d есть (%s)" % [rid, tier, okey])
				if o.is_empty():
					continue
				_check(CraftVFX.tier_of_item(o) == tier,
					"%s: уровень %d читается из quality (%s -> %d)"
					% [rid, tier, okey, CraftVFX.tier_of_item(o)])
				# Сумма ВСЕХ боевых полей, а не трёх выбранных. magcap обязателен:
			 # у одежды (плащ/накидка/колпак) defense = 2..3, и сумма только
			 # по damage+defence+absorption у Cloak равна 2 на всех трёх
			 # уровнях - тест ругался бы на нормальные данные. magcap
			 # кормит player._sphere_protection (player.gd:650-656), то
			 # есть это настоящая боевая величина, а не украшение.
				stats.append(int(o.get("damage_min", 0)) + int(o.get("damage_max", 0))
					+ int(o.get("to_hit", 0)) + int(o.get("defence", 0))
					+ int(o.get("absorption", 0)) + int(o.get("magcap", 0)))
			# Характеристики должны расти. Сравниваем СУММУ боевых полей,
			# потому что у брони ненулевая защита, а у оружия - урон, и по
			# отдельности одна из них всегда нулевая.
			if stats.size() == 3:
				_check(stats[1] > stats[0],
					"%s: улучшенная сильнее обычной (%d > %d)" % [rid, stats[1], stats[0]])
				_check(stats[2] > stats[1],
					"%s: мастерская сильнее улучшенной (%d > %d)" % [rid, stats[2], stats[1]])
	_check(total > 0, "рецепты загружены (%d)" % total)


## Все крафтовые записи делят текстуру с обычной вещью того же типа.
## Требование игрока: «текстура та же, только добавь эффект».
func _test_crafted_items() -> void:
	var crafted := 0
	var shared := 0
	var faction_set_items := 0
	for it in ItemDB.all():
		var d: Dictionary = it
		if CraftVFX.tier_of_item(d) == CraftVFX.TIER_ORDINARY \
				and not str(d.get("quality", "")).begins_with("Crafted"):
			continue
		crafted += 1
		if ItemDB.is_faction_set(d):
			# Фракционный набор (пакет C+D): у него нет «обычной вещи того же
			# металла и типа», текстура своя. Требование «три уровня = одна
			# текстура» проверяется отдельным проходом ниже.
			faction_set_items += 1
			continue
		var base_icon := ""
		for other in ItemDB.all():
			var o: Dictionary = other
			if str(o.get("quality", "")) == "Common" \
					and str(o.get("material", "")) == str(d.get("material", "")) \
					and str(o.get("type", "")) == str(d.get("type", "")):
				base_icon = str(o.get("icon", ""))
				break
		_check(base_icon != "" and str(d.get("icon", "")) == base_icon,
			"%s: та же текстура, что у обычной вещи того же типа и металла"
			% str(d.get("key", "")))
		shared += 1
	_check(crafted > 0, "крафтовые вещи есть (%d)" % crafted)
	_check(shared + faction_set_items == crafted,
		"у всех одна текстура с базовой вещью или своя у набора (%d + %d = %d)"
			% [shared, faction_set_items, crafted])
	# Фракционный набор: три уровня одного слота обязаны делить ОДНУ текстуру.
	# Группировка по иконке: у набора своя картинка на слот, и уровней ровно 3.
	var by_icon := {}
	for it2 in ItemDB.all():
		var d2: Dictionary = it2
		if not ItemDB.is_faction_set(d2):
			continue
		var icon2 := str(d2.get("icon", ""))
		by_icon[icon2] = int(by_icon.get(icon2, 0)) + 1
	var bad_sets := 0
	for icon3 in by_icon:
		if int(by_icon[icon3]) != 3:
			bad_sets += 1
	_check(by_icon.size() > 0, "фракционные наборы есть (%d слотов)" % by_icon.size())
	_check(bad_sets == 0,
		"у каждого слота набора ровно 3 уровня на одной текстуре (плохих: %d)" % bad_sets)


## Выход переработки: качество решает, металл больше ткани.
func _test_recycle_yield() -> void:
	var armor := ItemDB.find(ItemDB.broken_key("iron", "Armor", "Broken"))
	var armor_fine := ItemDB.find(ItemDB.broken_key("iron", "Armor", "Broken Fine"))
	var armor_rare := ItemDB.find(ItemDB.broken_key("iron", "Armor", "Broken Rare"))
	if armor.is_empty() or armor_fine.is_empty() or armor_rare.is_empty():
		_check(false, "есть сломанная броня трёх качеств")
		return
	var y0 := CraftDB.recycle_yield(armor)
	var y1 := CraftDB.recycle_yield(armor_fine)
	var y2 := CraftDB.recycle_yield(armor_rare)
	_check(y0["ingot"] >= 1, "минимальный выход не меньше 1 слитка (%d)" % int(y0["ingot"]))
	_check(y1["ingot"] > y0["ingot"],
		"добротная даёт больше (%d > %d)" % [int(y1["ingot"]), int(y0["ingot"])])
	_check(y2["ingot"] > y1["ingot"],
		"редкая даёт больше (%d > %d)" % [int(y2["ingot"]), int(y1["ingot"])])

	var garment := ItemDB.find(ItemDB.broken_key("Linen", "Garment", "Broken Fine"))
	if not garment.is_empty():
		var yg := CraftDB.recycle_yield(garment)
		_check(int(yg.get("fabric", 0)) > 0, "из одежды выходит ткань")
		_check(int(yg.get("essence", 0)) > 0, "из одежды выходит эссенция")
		_check(int(yg.get("ingot", 0)) == 0, "из одежды НЕ выходят слитки")

	var plain := ItemDB.find("Common iron Cuirass")
	# Целая кираса перерабатывается: 80% ресурсов рецепта (проверено в
	# _test_smeltable_split). Здесь только инвариант монотонности не трогаем.


# --- Потребление рецепта ---------------------------------------------------

## АТОМНОСТЬ ПОТРЕБЛЕНИЯ. Старый код (alchemy_panel.gd:291-309) проверял
## наличие, потом снимал по одному и возвращался на первой неудаче - остаток
## ингредиентов оказывался снят наполовину. Здесь проверяется именно остаток.
func _test_atomic_craft() -> void:
	var player := Player.new()
	player.add_item("iron Ingot")
	player.add_item("iron Ingot")
	player.add_item("Fabric")

	var recipe := {
		"id": "atomic", "inputs": [
			{"item": "iron Ingot", "count": 2}, {"item": "Fabric", "count": 1}],
		"outputs": [
			{"key": "Crafted iron Cuirass"},
			{"key": "Crafted Fine iron Cuirass"},
			{"key": "Crafted Master iron Cuirass"}],
	}
	var before_ingots := _count(player, "iron Ingot")
	var before_fabric := _count(player, "Fabric")

	# Не хватает одного слитка из двух - НИЧЕГО не должно списываться.
	var short := recipe.duplicate(true)
	(short["inputs"] as Array)[0]["count"] = 3
	_player_craft(player, short)
	_check(_count(player, "iron Ingot") == before_ingots,
		"при нехватке слитки НЕ списаны (%d)" % _count(player, "iron Ingot"))
	_check(_count(player, "Fabric") == before_fabric,
		"при нехватке ткань НЕ списана (%d)" % _count(player, "Fabric"))

	# Успешный крафт списывает ровно требуемое.
	var made := _player_craft(player, recipe)
	_check(made != "", "крафт удался (%s)" % made)
	_check(_count(player, "iron Ingot") == before_ingots - 2,
		"списано ровно 2 слитка (%d)" % _count(player, "iron Ingot"))
	_check(_count(player, "Fabric") == before_fabric - 1,
		"списана ровно 1 ткань (%d)" % _count(player, "Fabric"))
	player.free()


## Формула роста навыка крафта - та же, что у боевых, и она замедляется.
##
## Проверяется МОНОТОННОСТЬ и СУПЕРЛИНЕЙНОСТЬ, а не точное обращение
## exp_to_skill(skill_to_exp(n)) == n: формула оригинала
## ((1.1^n - 1) * 1000) округляется вниз до целого опыта, поэтому на ровно
## skill_to_exp(5) = 610 очков уровень ещё 4, а не 5. Это свойство исходной
## формулы Аллодов, а не дефект крафта, и «чинить» её здесь нельзя - её
## переняли боевые навыки, и сдвиг менял бы весь баланс. Ловится другое:
## если бы кто-то заменил кривую на линейную, рост перестал бы ускоряться.
func _test_skill_curve() -> void:
	var e5 := Player.skill_to_exp(5)
	var e10 := Player.skill_to_exp(10)
	var e20 := Player.skill_to_exp(20)
	_check(e5 > 0 and e10 > e5, "опыт растёт с уровнем (%d < %d)" % [e5, e10])
	_check(e10 > e5 * 2, "кривая суперлинейна 5->10 (%d > %d)" % [e10, e5 * 2])
	_check(e20 > e10 * 2, "кривая суперлинейна 10->20 (%d > %d)" % [e20, e10 * 2])
	# Обратная формула не должна терять больше одного уровня: на точно нужном
	# опыте игрок получает n-1, но не n-2.
	for lvl in [5, 10, 20, 40]:
		var e := Player.skill_to_exp(lvl)
		var back := Player.exp_to_skill(e)
		_check(back >= lvl - 1 and back <= lvl,
			"обращение на уровне %d: получено %d" % [lvl, back])
		_check(Player.exp_to_skill(e + 1) >= lvl,
			"на %d очках уровень %d уже достигнут" % [lvl + 1, lvl])
	_check(CraftDB.xp_for_craft(CraftDB.TIER_IMPROVED) > CraftDB.xp_for_craft(CraftDB.TIER_ORDINARY),
		"улучшенная вещь даёт больше опыта")
	_check(CraftDB.xp_for_craft(CraftDB.TIER_MASTER) > CraftDB.xp_for_craft(CraftDB.TIER_IMPROVED),
		"мастерская вещь даёт больше опыта")
	_check(CraftDB.xp_for_recycle() > 0, "переработка даёт опыт")


# --- Хелперы --------------------------------------------------------------

func _count(player: Player, key: String) -> int:
	var n := 0
	for raw in player.inventory:
		if str(raw) == key:
			n += 1
	return n


## Вызов CraftTab._craft напрямую: панель требует дерева сцены, а здесь нужен
## только сам алгоритм потребления.
func _player_craft(player: Player, recipe: Dictionary) -> String:
	# Crafting now requires knowledge: the test checks the craft itself, so it
	# learns the recipe first (learning has its own forge_smoke).
	if not player.known_recipes.has(str(recipe.get("id", ""))):
		player.known_recipes.append(str(recipe.get("id", "")))
	var tab := CraftTab.new()
	tab.setup(player, CraftDB.SMITH)
	return tab.call("_craft", recipe)