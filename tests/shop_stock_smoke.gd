extends SceneTree
## Shop stock (09.11): only the temporary regeneration potions, two per city
## per day.
##
## Why: the shop used to sell every potion the alchemist can brew, so crafting
## was a discount, not a profession. Now the shelf holds two regeneration
## bottles, refills on a new world day, and the rest is brewed or dropped.
##
## Run: godot --headless --path . --script res://tests/shop_stock_smoke.gd

const KEY_HEALTH := "Potion Health Regeneration"
const KEY_MANA := "Potion Mana Regeneration"
const SHOP_A := "4242|10|20"
const SHOP_B := "4242|40|70"

var _fails: Array[String] = []
var _checks := 0


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print("STOCK: %s %s" % ["ok  " if ok else "FAIL", what])


func _initialize() -> void:
	ItemDB.ensure_loaded()
	Game.shop_stock.clear()
	Game.shop_stock_day = -1

	# 1. The shelf starts full on a fresh day.
	_check(Game.shop_stock_left(SHOP_A, KEY_HEALTH, 2, 5) == 2,
		"на новый день на полке 2 бутылки")
	_check(Game.shop_stock_left(SHOP_A, KEY_MANA, 2, 5) == 2,
		"у маны свой запас")

	# 2. Buying takes one; running dry is refused.
	_check(Game.shop_stock_take(SHOP_A, KEY_HEALTH, 2, 5), "первая бутылка продана")
	_check(Game.shop_stock_take(SHOP_A, KEY_HEALTH, 2, 5), "вторая бутылка продана")
	_check(not Game.shop_stock_take(SHOP_A, KEY_HEALTH, 2, 5), "третья НЕ продаётся")
	_check(Game.shop_stock_left(SHOP_A, KEY_HEALTH, 2, 5) == 0, "полка пуста (0)")

	# 3. Another shop in the same city keeps its own shelf.
	_check(Game.shop_stock_left(SHOP_B, KEY_HEALTH, 2, 5) == 2,
		"вторая лавка полная независимо от первой")

	# 4. A new world day refills everything.
	_check(Game.shop_stock_left(SHOP_A, KEY_HEALTH, 2, 6) == 2,
		"на следующий день полка снова полная")
	_check(Game.shop_stock_left(SHOP_B, KEY_HEALTH, 2, 6) == 2,
		"и у второй лавки тоже")

	# 5. Reopening the same day does not refill (closing a panel is not a trick).
	Game.shop_stock_take(SHOP_A, KEY_HEALTH, 2, 6)
	_check(Game.shop_stock_left(SHOP_A, KEY_HEALTH, 2, 6) == 1,
		"в тот же день запас не восстанавливается")

	# 6. Only the regeneration potions are on the shelf.
	var allowed: Array = Game.SHOP_STOCK_LIMITS.keys()
	_check(allowed.size() == 2, "в лавке ровно два зелья (%d)" % allowed.size())
	_check(KEY_HEALTH in allowed and KEY_MANA in allowed,
		"это зелья восстановления жизни и маны")
	for key in allowed:
		_check(int(Game.SHOP_STOCK_LIMITS[key]) == 2, "%s: 2 штуки в день" % str(key))
	var other_potions: Array[String] = []
	for item in ItemDB.all():
		var quality := str((item as Dictionary).get("quality", ""))
		var key := str((item as Dictionary).get("key", ""))
		if quality == "Potion" and not Game.SHOP_STOCK_LIMITS.has(key) \
				and not Game.SHOP_STOCK_LIMITS.has(key) and key not in ["Potion Body", "Potion Mind", "Potion Reaction", "Potion Spirit"]:
			other_potions.append(key)
	_check(other_potions.size() >= 10,
		"остальные зелья (лечение/эликсиры) в лавке не продаются (%d)" % other_potions.size())

	# 7. The shop panel really shows only those two.
	ShopPanel._all_cache = ItemDB.all()
	var panel := ShopPanel.new()
	var potions := panel._category_items(3)
	panel.free()
	_check(potions.size() == 2, "вкладка «Зелья» отдаёт 2 позиции (%d)" % potions.size())
	var shown: Array[String] = []
	for item in potions:
		shown.append(str((item as Dictionary).get("key", "")))
	_check(KEY_HEALTH in shown and KEY_MANA in shown,
		"вкладка «Зелья» — только восстановление (%s)" % str(shown))

	_finish()


func _finish() -> void:
	print("")
	if _fails.is_empty():
		print("RESULT: OK shop_stock_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL shop_stock_smoke (%d checks, %d fails)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)
