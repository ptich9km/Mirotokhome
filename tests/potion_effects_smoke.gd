extends SceneTree
## Potion effects from data (04.11, audit R-P1-4).
##
## Before this the heal/mana values were hardcoded by key substring, so a new
## or modded potion silently healed 0. Values now come from the item: explicit
## "heal"/"mana" fields first, then the original effect strings
## ("health=+30", "mana=+30", "healthRegeneration=100: duration 60").
##
## Run: godot --headless --path . --script res://tests/potion_effects_smoke.gd

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 9, "spirit": 8,
		"blade": 20, "axe": 0, "bludgeon": 0, "pike": 0, "shooting": 10,
		"fire": 0, "water": 0, "air": 0, "earth": 0, "astral": 0,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.hero_class = "warrior"
	Game.hero_name = "Тест"
	Game.hero_race = "human"
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print("POTION: %s %s" % ["ok  " if ok else "FAIL", what])


func _run() -> void:
	# 1) Values come from the database strings, not from the key name.
	var small := Player.potion_values(ItemDB.find("Potion Small Healing"))
	var medium := Player.potion_values(ItemDB.find("Potion Medium Healing"))
	var big := Player.potion_values(ItemDB.find("Potion Big Healing"))
	_check(int(small.get("heal", 0)) == 12, "Small Healing = 12 (data)")
	_check(int(medium.get("heal", 0)) == 30, "Medium Healing = 30 (data)")
	_check(int(big.get("heal", 0)) == 100, "Big Healing = 100 (data)")
	var small_m := Player.potion_values(ItemDB.find("Potion Small Mana"))
	var big_m := Player.potion_values(ItemDB.find("Potion Big Mana"))
	_check(int(small_m.get("mana", 0)) == 12, "Small Mana = 12 (data)")
	_check(int(big_m.get("mana", 0)) == 100, "Big Mana = 100 (data)")

	# 2) Explicit fields (new/modded potions) and raw effect strings.
	var explicit := Player.potion_values({"heal": 40, "mana": 7})
	_check(int(explicit.get("heal", 0)) == 40 and int(explicit.get("mana", 0)) == 7,
		"поля heal/mana работают без effects")
	var raw := Player.potion_values({"effects": ["health=+9", "mana=+4"]})
	_check(int(raw.get("heal", 0)) == 9 and int(raw.get("mana", 0)) == 4,
		"строки health=/mana= разобраны")
	_check(Player.potion_values({}).get("heal", 0) == 0, "пустое зелье = 0")

	# 3) Real player: bottle heals the data amount and is spent.
	var p := Player.new()
	root.add_child(p)
	await process_frame
	Game.hero = p
	p.inventory = ["Potion Small Healing"]
	p.max_hp = 100
	p.current_hp = 10
	var ok := p.use_potion("Potion Small Healing")
	_check(ok, "Small Healing выпито")
	_check(p.current_hp == 22, "вылечено ровно на 12 (HP=%d)" % p.current_hp)
	_check(not p.inventory.has("Potion Small Healing"), "бутылка потрачена")

	# 4) Mana potion.
	p.inventory = ["Potion Small Mana"]
	p.max_mana = 50
	p.current_mana = 0
	p.use_potion("Potion Small Mana")
	_check(p.current_mana == 12, "мана +12 (M=%d)" % p.current_mana)

	# 5) Regeneration is a timed effect, not a hardcoded instant heal.
	p.inventory = ["Potion Health Regeneration"]
	p.max_hp = 100
	p.current_hp = 10
	p.use_potion("Potion Health Regeneration")
	_check(StatusEffects.has_effect(p, "regen"), "регенерация наложена")
	for i in 60:
		StatusEffects.tick(1.0)
	_check(p.current_hp > 90, "за 60 с регенерация восстановила жизнь (HP=%d)"
		% p.current_hp)
	_check(not StatusEffects.has_effect(p, "regen"), "регенерация истекла")

	# 6) Antipoison uses the armour channel from its effects string.
	p.inventory = ["Potion Antipoison"]
	p.use_potion("Potion Antipoison")
	_check(StatusEffects.shield_armor_absorption(p) == 50,
		"антидот даёт поглощение 50 (%d)" % StatusEffects.shield_armor_absorption(p))

	p.queue_free()
	Game.hero = null
	_finish()


func _finish() -> void:
	print("")
	if _fails.is_empty():
		print("RESULT: OK potion_effects_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL potion_effects_smoke (%d checks, %d fails)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)
