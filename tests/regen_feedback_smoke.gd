extends SceneTree
## Headless check of healing feedback (player report 06.11).
##
## Passive regeneration runs once per second and painted "+3" and "+1 маны"
## over the hero, so hits drowned in the noise. Floating text stays for hits,
## cast heals and bottles only.
##
## Run:
##   godot --headless --path . --script res://tests/regen_feedback_smoke.gd

var _fails: Array = []
var _hero: Player = null
var _game: Node = null

## How much HP/mana we take away before measuring a restore.
const SPARE := 40


func _initialize() -> void:
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 13, "spirit": 12,
		"blade": 10, "bludgeon": 10, "pike": 10, "shooting": 10,
		"fire": 20, "water": 20, "air": 20, "earth": 20, "astral": 20,
		"weapon": "staff", "shield": false, "armor": "light"}
	Game.hero_class = "mage"
	Game.hero_name = "Маг"
	Game.debug_magic = true
	# Auto-magic off: it heals on its own and would add numbers of its own.
	Game.auto_buff_tier = "none"
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails.append(what)
	print("REGEN: %s %s" % ["ok  " if ok else "FAIL", what])


## Floating texts currently alive on the map, in creation order.
func _numbers() -> Array:
	var out: Array = []
	if current_scene == null:
		return out
	for n in current_scene.get_children():
		if n is DamageNumber:
			for c in n.get_children():
				if c is Label:
					out.append(str((c as Label).text))
	return out


func _new_numbers(before: int) -> Array:
	var all := _numbers()
	if all.size() <= before:
		return []
	return all.slice(before)


func _run() -> void:
	var err := change_scene_to_file("res://scenes/main.tscn")
	if err != OK:
		_check(false, "main.tscn не загрузился")
		_finish()
		return
	await process_frame
	await create_timer(0.8).timeout
	_hero = get_first_node_in_group("player") as Player
	_game = current_scene
	_check(_hero != null, "герой загружен")
	if _hero == null:
		_finish()
		return
	for e in Game.enemies:
		if is_instance_valid(e):
			e.queue_free()
	Game.enemies.clear()

	# 1. Passive HP regeneration: HP grows, no number.
	_hero.state = "idle"
	_hero.current_hp = maxi(1, _hero.max_hp - SPARE)
	var hp_before := int(_hero.current_hp)
	var n := _numbers().size()
	_game.call("_regen_hero", 1.05)
	_check(int(_hero.current_hp) > hp_before,
		"регенерация поднимает HP (%d -> %d)" % [hp_before, int(_hero.current_hp)])
	_check(_new_numbers(n).is_empty(),
		"регенерация HP не рисует чисел (%s)" % str(_new_numbers(n)))

	# 2. Passive mana regeneration: same silence.
	_hero.current_mana = maxi(1, _hero.max_mana - SPARE)
	var mp_before := int(_hero.current_mana)
	n = _numbers().size()
	_game.call("_regen_hero", 1.05)
	_check(int(_hero.current_mana) > mp_before,
		"регенерация поднимает ману (%d -> %d)" % [mp_before, int(_hero.current_mana)])
	_check(_new_numbers(n).is_empty(), "регенерация маны не рисует чисел")

	# 3. A healing bottle shows the really restored HP.
	_hero.add_item("Potion Small Healing")
	_hero.current_hp = maxi(1, _hero.max_hp - SPARE)
	var pot_before := int(_hero.current_hp)
	n = _numbers().size()
	_check(_hero.use_potion("Potion Small Healing"), "бутылка лечения выпита")
	var pot_nums := _new_numbers(n)
	_check(int(_hero.current_hp) == mini(_hero.max_hp, pot_before + 12),
		"бутылка лечит на 12 (%d -> %d)" % [pot_before, int(_hero.current_hp)])
	_check(pot_nums == ["+12"], "бутылка показывает '+12' (%s)" % str(pot_nums))

	# 4. A mana bottle shows its own number.
	_hero.add_item("Potion Small Mana")
	_hero.current_hp = _hero.max_hp
	_hero.current_mana = maxi(1, _hero.max_mana - SPARE)
	n = _numbers().size()
	_check(_hero.use_potion("Potion Small Mana"), "бутылка маны выпита")
	var mana_nums := _new_numbers(n)
	_check(mana_nums == [Loc.f("ui.msg.mana", [12])],
		"бутылка маны показывает '+12 маны' (%s)" % str(mana_nums))

	# 5. A cast heal still shows its number.
	_hero.known_spells["Heal"] = {"charges": -1}
	_hero.cast_cooldowns.clear()
	_hero.current_hp = maxi(1, _hero.max_hp - SPARE)
	n = _numbers().size()
	_hero.cast_spell("Heal", _hero.global_position, _hero)
	var heal_nums := _new_numbers(n)
	_check(heal_nums.size() == 1 and str(heal_nums[0]).begins_with("+"),
		"каст лечения показывает одно число (%s)" % str(heal_nums))

	# 6. A hit still shows a number (the reason the label exists).
	_hero.current_hp = _hero.max_hp
	n = _numbers().size()
	Game.deal_damage(_hero, 3, "physical", "", _hero)
	var hit_nums := _new_numbers(n)
	_check(hit_nums.size() >= 1, "удар по герою показывает число (%s)" % str(hit_nums))

	_finish()


func _finish() -> void:
	if _fails.is_empty():
		print("REGEN: RESULT: OK")
	else:
		print("REGEN: RESULT: FAIL (%d): %s" % [_fails.size(), str(_fails)])
	quit(0 if _fails.is_empty() else 1)
