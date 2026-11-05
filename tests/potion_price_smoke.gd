extends SceneTree
## Headless check of consumable prices (player report 06.11).
##
## A Small Healing bottle used to cost 250 and sold for 125, while the hero starts
## with 20 gold and a grey wolf drops about 10: every sip was a financial event.
## Healing bottles are means of survival, not loot; permanent elixirs stay luxury.
##
## Run:
##   godot --headless --path . --script res://tests/potion_price_smoke.gd

## The approved table: price in the shop.
const EXPECTED := {
	"Potion Small Healing": 30,
	"Potion Small Mana": 30,
	"Potion Health Regeneration": 40,
	"Potion Mana Regeneration": 40,
	"Potion Antipoison": 50,
	"Potion Medium Healing": 80,
	"Potion Medium Mana": 80,
	"Potion Big Healing": 200,
	"Potion Big Mana": 200,
}

## Attribute elixirs are permanent upgrades and keep their deliberate price.
const ELIXIRS := ["Potion Body", "Potion Mind", "Potion Reaction", "Potion Spirit"]
const ELIXIR_PRICE := 1000000

## Recipes that must stay worth their herbs.
const RECIPES := [
	["Potion Medium Healing", ["Herb Green Leaf", "Herb White Flower"]],
	["Potion Medium Mana", ["Herb Lavender", "Herb Mint"]],
]

var _fails: Array = []


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails.append(what)
	print("POTIONPRICE: %s %s" % ["ok  " if ok else "FAIL", what])


func _price(key: String) -> int:
	var item := ItemDB.find(key)
	if item.is_empty():
		return -1
	return int(item.get("price", 0))


func _sell(price: int) -> int:
	return maxi(1, int(price / float(maxi(1, GameConfig.geti("economy", "sell_price_div")))))


func _initialize() -> void:
	var div := GameConfig.geti("economy", "sell_price_div")
	_check(div == 2, "делитель продажи остался 2 (сейчас %d)" % div)

	for key in EXPECTED:
		var price := _price(str(key))
		_check(price == int(EXPECTED[key]),
			"%s стоит %d (сейчас %d)" % [key, int(EXPECTED[key]), price])

	for key in ELIXIRS:
		var price := _price(str(key))
		_check(price == ELIXIR_PRICE,
			"%s не тронут: %d (сейчас %d)" % [key, ELIXIR_PRICE, price])

	# Every consumable stays affordable: a hundred sips must not cost a fortune.
	var worst := 0
	for key in EXPECTED:
		worst = maxi(worst, _sell(_price(str(key))))
	_check(worst <= 100, "самая дорогая бутылка продаётся не дороже 100 з (%d)" % worst)

	# The ladder is readable: small < medium < big, for both lines.
	_check(_price("Potion Small Healing") < _price("Potion Medium Healing")
			and _price("Potion Medium Healing") < _price("Potion Big Healing"),
		"лечение: малый < средний < большой")
	_check(_price("Potion Small Mana") < _price("Potion Medium Mana")
			and _price("Potion Medium Mana") < _price("Potion Big Mana"),
		"мана: малый < средний < большой")
	_check(_sell(_price("Potion Medium Healing")) == 40,
		"средняя бутылка лечения продаётся за 40 (%d)" % _sell(_price("Potion Medium Healing")))

	# Crafting must stay profitable: a potion is worth more than its herbs.
	for rec in RECIPES:
		var out_key := str(rec[0])
		var ingredients: Array = rec[1]
		var cost := 0
		for h in ingredients:
			cost += _price(str(h))
		_check(_price(out_key) >= cost * 3,
			"варка %s (%d з) окупает травы (%d з)" % [out_key, _price(out_key), cost])

	# A potion dropped by a monster must not be worth more than the purse of a new hero.
	_check(_sell(_price("Potion Mana Regeneration")) <= 25,
		"регенерация маны продаётся не дороже 25 з")

	if _fails.is_empty():
		print("POTIONPRICE: RESULT: OK")
	else:
		print("POTIONPRICE: RESULT: FAIL (%d): %s" % [_fails.size(), str(_fails)])
	quit(0 if _fails.is_empty() else 1)
