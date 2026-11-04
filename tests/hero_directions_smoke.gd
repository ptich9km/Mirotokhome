extends SceneTree
## Direction data and the skill -> stat wiring (04.11).
##
## The character screen must not invent numbers: its preview calls the same
## Player statics as combat. This test walks every direction, checks the
## 20/10/0 rule, the bronze starter kit, and compares the preview arithmetic
## with a live (tree-less) Player built from the same stats.
##
## Run: godot --headless --path . --script res://tests/hero_directions_smoke.gd

const CLASSES := ["warrior", "mage"]

var _fails: Array[String] = []
var _checks := 0


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print("DIR: %s %s" % ["ok  " if ok else "FAIL", what])


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_data()
	_starter_kits()
	_skill_mapping()
	_derived()
	_grant()
	print("")
	if _fails.is_empty():
		print("RESULT: OK hero_directions_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL hero_directions_smoke (%d checks, %d fails)"
			% [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)


func _data() -> void:
	for cls in CLASSES:
		var all := HeroDirections.for_class(cls)
		_check(all.size() == 5, "%s: 5 направлений (получено %d)" % [cls, all.size()])
		var prim := HeroDirections.primaries(cls)
		_check(prim.size() == 4, "%s: 4 основных (получено %d)" % [cls, prim.size()])
		var aux := HeroDirections.aux(cls)
		_check(not aux.is_empty(), "%s: есть вспомогательное" % cls)
		var aux_skill := str(aux.get("skill", ""))
		_check(aux_skill == ("shooting" if cls == "warrior" else "astral"),
			"%s: вспомогательное = %s" % [cls, aux_skill])
		for d in prim:
			var skill := str((d as Dictionary).get("skill", ""))
			_check(skill != "astral" and skill != "shooting",
				"%s: %s не может быть основным" % [cls, skill])
			_check(str(d.get("label", "")) != "", "%s/%s: есть название" % [cls, skill])
			_check(str(d.get("desc", "")).length() > 20, "%s/%s: есть описание" % [cls, skill])
			if cls == "mage":
				_check(str(d.get("sphere", "")) in ContentRules.list("spells.spheres"),
					"%s/%s: сфера существует" % [cls, skill])
	var aux_w := HeroDirections.aux("warrior")
	_check(str(aux_w.get("skill", "")) == "shooting", "воин: вспомогательная стрельба")
	var aux_m := HeroDirections.aux("mage")
	_check(str(aux_m.get("skill", "")) == "astral", "маг: вспомогательный астрал")


func _starter_kits() -> void:
	var expected := {
		"blade": "Common bronze Long Sword",
		"axe": "Common bronze Axe",
		"bludgeon": "Common bronze Mace",
		"pike": "Common bronze Pike",
	}
	for skill in expected:
		var kind := HeroDirections.weapon_kind_of(skill)
		var key := Player.starter_weapon_key("warrior", kind)
		_check(key == expected[skill], "%s -> %s" % [skill, key])
		var item := ItemDB.find(key)
		_check(not item.is_empty(), "%s существует в item_db" % key)
		var kit := Player.starter_items("warrior", kind, true, "")
		_check(kit[0] == key, "%s: оружие первым в наборе" % skill)
		_check(kit.has("Common bronze Buckler"), "%s: бронзовый щит в наборе" % skill)
		_check(kit.has("Potion Medium Healing"), "%s: лечебное зелье в наборе" % skill)
	var staff := Player.starter_weapon_key("mage", "staff")
	_check(staff == "Common Wood Staff", "маг: деревянный посох")
	for sphere in ["Fire", "Water", "Air", "Earth"]:
		var sphere_name := str(sphere)
		var book := SpellDB.book_key_for_spell(SpellDB.simplest_spell_of_sphere(sphere_name))
		var kit := Player.starter_items("mage", "staff", false, book)
		_check(kit.has(staff), "%s: посох в наборе" % sphere_name)
		_check(kit.has(book), "%s: книга %s в наборе" % [sphere_name, book])
		var spell := SpellDB.simplest_spell_of_sphere(sphere_name)
		_check(SpellDB.kind_of(spell) in ["attack", "area"] and SpellDB.damage(spell) > 0,
			"%s: стартовое заклинание боевое (%s)" % [sphere_name, spell])


func _make_player(cls: String, primary: String, aux: String,
		body: int, agility: int, mind: int, spirit: int) -> Player:
	Game.hero_class = cls
	Game.hero_primary_skill = primary
	Game.hero_aux_skill = aux
	Game.hero_stats = {}
	var p := Player.new()
	p.body = body
	p.agility = agility
	p.mind = mind
	p.spirit = spirit
	p.has_mana = cls == "mage"
	for s in p.SKILL_NAMES:
		p._set_skill_value(str(s), 0)
	p._set_skill_value(primary, 20)
	p._set_skill_value(aux, 10)
	return p


func _skill_mapping() -> void:
	# Club uses bludgeon, not blade. Before the fix the name "bludgeon" never
	# matched weapon_kind()'s "club", so a mace trained the sword skill.
	var p := _make_player("warrior", "bludgeon", "shooting", 12, 11, 9, 8)
	p.weapon = "club"
	p.equipped["weapon"] = "Common bronze Mace"
	var mace := ItemDB.find("Common bronze Mace")
	_check(p._weapon_skill_for_damage() == 20, "булава использует навык булавы")
	_check(p.get_damage_min() == Player.damage_min_of(int(mace["damage_min"]), 20, 11),
		"урон булавы от bludgeon 20, не от меча")
	_check(p.get_attack() == Player.attack_of(11, 20, int(mace.get("to_hit", 0))),
		"атака булавы от навыка булавы")
	p.free()

	# Axe must not borrow the blade hit chance.
	p = _make_player("warrior", "axe", "shooting", 12, 11, 9, 8)
	p.weapon = "axe"
	p.equipped["weapon"] = "Common bronze Axe"
	var axe := ItemDB.find("Common bronze Axe")
	_check(p.get_attack() == Player.attack_of(11, 20, int(axe.get("to_hit", 0))),
		"атака топора от навыка топора")
	p.free()

	# A staff uses the best magic school, not always fire.
	p = _make_player("mage", "air", "astral", 8, 9, 13, 12)
	p.weapon = "staff"
	p.equipped["weapon"] = "Common Wood Staff"
	_check(p._weapon_skill_for_damage() == 20, "посох считает лучшую школу (воздух 20)")
	p.free()


func _derived() -> void:
	# Warrior: 20 + 10 * 0.6 = 26 development points -> +13 HP, +5 defence.
	var w := _make_player("warrior", "blade", "shooting", 12, 11, 9, 8)
	var dev := 20.0 + 10.0 * GameConfig.getf("skill_stats", "aux_factor")
	_check(absf(dev - 26.0) < 0.001, "26 очков развития (20 + 10×0.6)")
	_check(w._calc_max_hp() == Player.max_hp_of(12) + 13, "жизнь воина +13")
	_check(w.get_defense() == Player.defense_of(11, 12, 0) + 5, "защита воина +5")
	_check(w._calc_max_mana() == 0, "у воина нет маны")
	w.free()

	# Mage: +13 HP and +13 mana, no defence bonus.
	var m := _make_player("mage", "fire", "astral", 8, 9, 13, 12)
	_check(m._calc_max_hp() == Player.max_hp_of(8) + 13, "жизнь мага +13")
	_check(m._calc_max_mana() == Player.max_mana_of(12) + 13, "мана мага +13")
	_check(m.get_defense() == Player.defense_of(9, 8, 0), "магу направление не даёт защиту")
	# Magic damage: SP = 20 + 13 - 15 = 18%.
	var sp := Game.spell_power_value(20.0, 13.0)
	_check(absf(sp - 18.0) < 0.001, "сила магии 18%% (получено %d)" % int(sp))
	m.free()

	# An empty primary (old save before the rule) keeps the old numbers.
	Game.hero_primary_skill = ""
	Game.hero_aux_skill = ""
	var old := Player.new()
	old.body = 10
	old.has_mana = false
	old._set_skill_value("blade", 30)
	_check(old._calc_max_hp() == Player.max_hp_of(10), "без направления жизнь без бонуса")
	old.free()

	# Leveling the primary raises the maximum AND tops up the current HP by
	# the gain (school training must be felt immediately).
	var lv := _make_player("warrior", "blade", "shooting", 12, 11, 9, 8)
	lv.max_hp = lv._calc_max_hp()
	lv.current_hp = 50
	var before_max := lv.max_hp
	lv.set_skill_field("blade_skill", 30)
	_check(lv.max_hp == before_max + 5, "навык 30: максимум +5 (получено %d)" % lv.max_hp)
	_check(lv.current_hp == 55, "повышение навыка добавляет прирост к текущей жизни")
	lv.free()


## The live starter handout must match the same helper the screen renders.
func _grant() -> void:
	Game.hero_save = {}
	Game.hero_class = "warrior"
	Game.hero_stats = {"shield": true}
	Game.hero_start_book = ""
	var p := Player.new()
	p.weapon = "club"
	p._grant_starter_set()
	_check(not p.inventory.has("Common bronze Mace"), "выдача: булава ушла из склада")
	_check(str(p.equipped.get("weapon", "")) == "Common bronze Mace",
		"выдача: булава надета")
	_check(str(p.equipped.get("shield", "")) == "Common bronze Buckler",
		"выдача: бронзовый щит надет")
	_check(p.inventory.has("Potion Medium Healing"), "выдача: лечебные зелья")
	p.free()

	Game.hero_class = "mage"
	Game.hero_stats = {"shield": false}
	Game.hero_start_book = "Book Fire Arrow"
	p = Player.new()
	p.weapon = "staff"
	p._grant_starter_set()
	_check(not p.inventory.has("Common Wood Staff"), "выдача: посох ушёл из склада")
	_check(p.inventory.has("Book Fire Arrow"), "выдача: книга школы")
	_check(str(p.equipped.get("weapon", "")) == "Common Wood Staff", "выдача: посох надет")
	_check(not p.inventory.has("Common bronze Buckler"), "магу щит не выдаётся")
	p.free()
