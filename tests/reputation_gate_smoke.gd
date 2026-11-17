extends SceneTree
##
## Репутация как пропуск к товарам (28.10): таверна и магазин.
##
## ЗАЧЕМ
## -----
## Репутация начислялась квестами главы города (`WorldState.hero_reputation`),
## но никуда не влияла: наёмники в таверне были одни и те же, а магазин продавал
## всё подряд независимо от отношения фракции. Теперь пороги `[reputation]`
## открывают тиры наёмников и товары, а скидка считается от той же репутации.
##
## ЧТО ПРОВЕРЯЕМ
## -------------
##   1. `Game.hero_reputation` читает WorldState (ось — раса города);
##   2. тир наёмников и число кандидатов растут по порогам 15/40/80;
##   3. цена найма растёт с тиром;
##   4. магазин: чертежи — с 15, эльфийские свитки — с 40;
##   5. скидка покупки: 0/5/10/15 % и она же в цене слота;
##   6. карта без города — репутации нет, витрина работает как раньше.
##
## Запуск: godot --headless --path . --script res://tests/reputation_gate_smoke.gd

const WorldBusClass := preload("res://scripts/world/world_bus.gd")
const RACE := "humans"

var _checks := 0
var _fails: Array[String] = []
var _bus: Node = null


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print(("  OK  " if ok else "  FAIL") + " " + what)


func _initialize() -> void:
	_run.call_deferred()


func _make_bus() -> void:
	# Autoload WorldBus может существовать и в --script: тогда репутацию надо
	# писать в него (Game.hero_reputation ищет узел по имени /root/WorldBus).
	_bus = root.get_node_or_null("WorldBus")
	if _bus != null:
		return
	_bus = WorldBusClass.new()
	_bus.name = "WorldBus"
	_bus._ready()
	root.add_child(_bus)


func _set_rep(value: int) -> void:
	_bus.state.hero_reputation[RACE] = value


func _inn(race: String) -> InnPanel:
	var panel := InnPanel.new()
	panel.setup(null, race)
	panel.call("_generate_candidates")
	return panel


func _shop(race: String) -> ShopPanel:
	var panel := ShopPanel.new()
	panel.setup(null, race)
	return panel


func _cat_index(id: String) -> int:
	for i in range(ShopPanel.CATEGORIES.size()):
		if str(ShopPanel.CATEGORIES[i]["id"]) == id:
			return i
	return -1


func _has_quality(items: Array, quality: String) -> bool:
	for raw in items:
		if str((raw as Dictionary).get("quality", "")) == quality:
			return true
	return false


func _run() -> void:
	_make_bus()
	_check(Game.hero_reputation(RACE) == 0, "стартовая репутация 0")

	print("-- репутация читается из мира --")
	_set_rep(37)
	_check(Game.hero_reputation(RACE) == 37, "Game.hero_reputation = 37")
	_check(Game.hero_reputation("ork") == 0, "чужая фракция не затронута")
	_check(Game.hero_reputation("") == 0, "пустая раса = 0")

	print("-- таверна: тиры по репутации --")
	var t1 := GameConfig.geti("reputation", "tier_1")
	var t2 := GameConfig.geti("reputation", "tier_2")
	var t3 := GameConfig.geti("reputation", "tier_3")
	_check(t1 < t2 and t2 < t3, "пороги растут: %d < %d < %d" % [t1, t2, t3])

	var cases := [[0, 0], [t1, 1], [t2, 2], [t3, 3]]
	var pool: Array = ContentRules.list("inn.candidates.%s" % RACE)
	## 15.11: the pool is a per-race gear ladder and its length is not fixed any
	## more (humans have three grades, orcs four). The rule is "reputation opens
	## one more candidate, never more than the pool holds", so the expectation is
	## capped by the pool instead of the old hard-coded four.
	_check(pool.size() >= 3, "пул %s не короче трёх ступеней (%d)" % [RACE, pool.size()])
	var costs: Array[int] = []
	for c in cases:
		_set_rep(int(c[0]))
		var inn := _inn(RACE)
		var tier: int = inn.call("_tier")
		var cands: Array = inn.get("_candidates")
		_check(tier == int(c[1]), "репутация %d -> тир %d (сейчас %d)"
			% [int(c[0]), int(c[1]), tier])
		var expect := mini(int(c[1]) + 1, pool.size())
		_check(cands.size() == expect,
			"тир %d: кандидатов %d (ожидалось %d)"
				% [tier, cands.size(), expect])
		costs.append(int(cands[0].get("cost", 0)))
		inn.free()
	_check(costs[0] < costs[3], "цена найма растёт с тиром (%d -> %d)"
		% [costs[0], costs[3]])

	print("-- магазин: гейты рецептов и эльфийских свитков --")
	var elven := GameConfig.geti("reputation", "elven_rep")
	_check(elven >= t2, "эльфийские свитки — не раньше третьего тира")

	print("-- магазин: чертежи доступны всем, эльфы за репутацией --")
	_set_rep(0)
	var shop0 := _shop(RACE)
	var books0: Array = shop0.call("_category_items", _cat_index("books"))
	var recipes0: Array = shop0.call("_category_items", _cat_index("recipes_weapon"))
	_check(not books0.is_empty(), "обычные свитки есть и без репутации (%d)" % books0.size())
	_check(not _has_quality(books0, "SuperScroll"),
		"эльфийских свитков нет без репутации")
	_check(not recipes0.is_empty(),
		"чертежи продаются и без репутации (%d) — вкладки не пустые" % recipes0.size())
	var price0: int = shop0.call("_buy_price", 100)
	shop0.free()

	_set_rep(elven)
	var shop2 := _shop(RACE)
	var books2: Array = shop2.call("_category_items", _cat_index("books"))
	_check(_has_quality(books2, "SuperScroll"),
		"эльфийские свитки открылись на %d" % elven)
	var price2: int = shop2.call("_buy_price", 100)
	shop2.free()

	_set_rep(t3)
	var shop3 := _shop(RACE)
	var price3: int = shop3.call("_buy_price", 100)
	var discount3: int = shop3.call("_discount_percent")
	shop3.free()
	_check(discount3 == GameConfig.geti("reputation", "discount_3"),
		"максимальная скидка %d%%" % discount3)
	_check(price0 == 100 and price2 < price0 and price3 < price2,
		"цена падает по порогам: %d -> %d -> %d" % [price0, price2, price3])

	print("-- таверна: пустые тиры объявлены замками --")
	_set_rep(0)
	var inn0 := _inn(RACE)
	var lock1: Dictionary = inn0.call("_locked_entry", 1)
	var lock0: Dictionary = inn0.call("_locked_entry", 0)
	_check(lock0.is_empty(), "текущий тир не запирается")
	_check(not lock1.is_empty() and int(lock1.get("need", 0)) == t1,
		"тир 1 заперт до %d репутации (нужно %d)" % [t1, int(lock1.get("need", 0))])
	_check(int(inn0.call("_next_tier_need")) == t1,
		"подсказка называет порог следующего тира")
	inn0.free()

	print("-- карта без города --")
	_set_rep(t3)
	var nowhere := _inn("")
	_check(int(nowhere.call("_tier")) == 0, "без города тир 0")
	_check((nowhere.get("_candidates") as Array).size() == 1,
		"без города один кандидат — как раньше")
	nowhere.free()

	_bus.queue_free()
	print("")
	if _fails.is_empty():
		print("RESULT: OK reputation_gate_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL reputation_gate_smoke (%d checks, %d fails)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)
