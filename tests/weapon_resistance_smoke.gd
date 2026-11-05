extends SceneTree
## Weapon-kind resistance from Allods (04.11).
##
## Original formula (reverse-engineered in againrom, HERO-DAMAGE-022):
##   hit -> subtract absorption -> trunc(damage * (100 - resistance) / 100 + 0.75)
## A club is 125% against undead and 75% against people (player's example),
## which is resistance -25 / +25 in that model.
##
## Run: godot --headless --path . --script res://tests/weapon_resistance_smoke.gd

var _fails: Array[String] = []
var _checks := 0


class DummyUnit extends Node2D:
	var current_hp := 500
	var max_hp := 500
	var anim_set := ""
	var weapon := ""
	var absorption := 0

	func get_absorption() -> int:
		return absorption

	func take_damage(dmg: int, _attacker) -> int:
		var d := mini(dmg, current_hp)
		current_hp -= d
		return d


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print("WRES: %s %s" % ["ok  " if ok else "FAIL", what])


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_table()
	_creature_types()
	_damage()
	_guards()
	print("")
	if _fails.is_empty():
		print("RESULT: OK weapon_resistance_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL weapon_resistance_smoke (%d checks, %d fails)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)


func _table() -> void:
	# The player's exact example: club 125% undead, 75% people.
	_check(UnitDB.weapon_percent("club", "undead") == 125, "булава по нежити = 125%")
	_check(UnitDB.weapon_percent("club", "human") == 75, "булава по людям = 75%")
	_check(UnitDB.weapon_percent("sword", "beast") == 110, "меч по зверям = 110%")
	_check(UnitDB.weapon_percent("pike", "monster") == 125, "копьё по чудовищам = 125%")
	_check(UnitDB.weapon_percent("axe", "undead") == 75, "топор по нежити = 75%")
	_check(UnitDB.weapon_percent("club", "unknown_type") == 100, "неизвестный тип = 100%")
	_check(UnitDB.weapon_percent("staff", "undead") == 100, "посох не в таблице = 100%")
	# The Allods rounding: 10 * 125% = 12.5 -> 13 (0.75 before truncation).
	_check(Game.apply_weapon_percent(10, 125) == 13, "10 × 125% = 13")
	_check(Game.apply_weapon_percent(10, 75) == 8, "10 × 75% = 8")
	_check(Game.apply_weapon_percent(7, 125) == 9, "7 × 125% = 9")
	_check(Game.apply_weapon_percent(7, 75) == 6, "7 × 75% = 6")
	_check(Game.apply_weapon_percent(0, 125) == 0, "0 остаётся 0")


func _creature_types() -> void:
	_check(UnitDB.creature_type_of("monsters/wolf") == "beast", "волк — зверь")
	_check(UnitDB.creature_type_of("monsters/ghost") == "undead", "призрак — нежить")
	_check(UnitDB.creature_type_of("monsters/troll") == "monster", "тролль — чудовище")
	_check(UnitDB.creature_type_of("monsters/bee") == "insect", "пчела — насекомое")
	_check(UnitDB.creature_type_of("city_human_warrior/t0") == "human", "горожанин — человек")
	_check(UnitDB.creature_type_of("city_necro_warrior/t0") == "undead", "городская нежить — нежить")
	var hero := DummyUnit.new()
	hero.anim_set = ""
	_check(Game.creature_type_of(hero) == "", "юнит без набора — без типа")
	hero.free()


func _damage() -> void:
	var attacker := DummyUnit.new()
	attacker.weapon = "club"
	var ghost := DummyUnit.new()
	ghost.anim_set = "monsters/ghost"
	Game.deal_damage(ghost, 10, "physical", "", attacker)
	_check(ghost.current_hp == 500 - 13, "булава по нежити: 10 -> 13 (HP %d)" % ghost.current_hp)
	ghost.free()

	var human := DummyUnit.new()
	human.anim_set = "city_human_warrior/t0"
	Game.deal_damage(human, 10, "physical", "", attacker)
	_check(human.current_hp == 500 - 8, "булава по людям: 10 -> 8 (HP %d)" % human.current_hp)
	human.free()

	# Resistance runs AFTER absorption, as in the original.
	var armored := DummyUnit.new()
	armored.anim_set = "monsters/ghost"
	armored.absorption = 3
	Game.deal_damage(armored, 10, "physical", "", attacker)
	_check(armored.current_hp == 500 - 9, "поглощение 3, затем 125%: (10-3)=7 -> 9 (HP %d)"
		% armored.current_hp)
	armored.free()

	# A staff (bare/unsupported slot) bypasses the table.
	attacker.weapon = "staff"
	var ghost2 := DummyUnit.new()
	ghost2.anim_set = "monsters/ghost"
	Game.deal_damage(ghost2, 10, "physical", "", attacker)
	_check(ghost2.current_hp == 500 - 10, "посох не получает сопротивление оружию")
	ghost2.free()

	# Magic never consults the weapon-kind table.
	attacker.weapon = "club"
	var ghost3 := DummyUnit.new()
	ghost3.anim_set = "monsters/ghost"
	Game.deal_damage(ghost3, 10, "magic", "Fire", attacker)
	_check(ghost3.current_hp == 500 - 10, "магия не зависит от булавы")
	ghost3.free()

	# A sword is neutral against people.
	attacker.weapon = "sword"
	var human2 := DummyUnit.new()
	human2.anim_set = "city_human_warrior/t0"
	Game.deal_damage(human2, 10, "physical", "", attacker)
	_check(human2.current_hp == 500 - 10, "меч по людям: 100%")
	human2.free()
	attacker.free()


func _guards() -> void:
	var attacker := DummyUnit.new()
	attacker.weapon = "unarmed"
	var target := DummyUnit.new()
	target.anim_set = "monsters/ghost"
	Game.deal_damage(target, 10, "physical", "", attacker)
	_check(target.current_hp == 500 - 10, "кулак не получает сопротивление оружию")
	target.free()
	attacker.free()
