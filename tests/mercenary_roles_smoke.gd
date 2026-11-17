extends SceneTree
## Mercenary roles (17.11): mage staff/magic/healing, archer bow, warrior melee.
##
## Why this test exists: the tavern used to be the only place a mercenary was
## ever mentioned. A hired mage walked into melee, and nothing in the game could
## say "cast" or "heal". Now the role is a per-mercenary field, the party tab in
## the inventory switches it, and the save keeps it.
##
## Run: godot --headless --path . --script res://tests/mercenary_roles_smoke.gd

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


func _run() -> void:
	Game.hero = null
	Game.party = []
	Game.enemies = []
	Game.npcs = []
	_make_bus()

	_test_rules()
	_test_role_defaults()
	_test_spell_lists()
	_test_magic_numbers()
	_test_healer()
	_test_archer()
	_test_save_fields()
	await _test_party_tab()

	Game.party = []
	Game.enemies = []
	if _fails.is_empty():
		print("RESULT: OK mercenary_roles_smoke (проверок: %d)" % _checks)
	else:
		print("RESULT: FAIL (%d из %d)" % [_fails.size(), _checks])
	quit()


func _make_bus() -> void:
	_bus = root.get_node_or_null("WorldBus")
	if _bus != null:
		return
	_bus = WorldBusClass.new()
	_bus.name = "WorldBus"
	_bus._ready()
	root.add_child(_bus)


func _set_rep(value: int) -> void:
	_bus.state.hero_reputation[RACE] = value


func _merc(set_name: String) -> Mercenary:
	var m := Mercenary.new()
	m.anim_set = set_name
	m.max_hp = 70
	m.damage = 6
	m.current_hp = m.max_hp
	return m


# --- Rules -------------------------------------------------------------------
func _test_rules() -> void:
	var heal := ContentRules.dict("merc.heal")
	_check(absf(float(heal.get("percent", 0.0)) - 0.08) < 0.0001,
		"лечение наёмника: 8 % от максимума (player decision)")
	_check(absf(float(heal.get("cooldown", 0.0)) - 2.5) < 0.0001,
		"кулдаун лечения 2.5 с (слабее мага-НПЦ)")
	var ranged := ContentRules.dict("merc.ranged")
	_check(float(ranged.get("keep", 0.0)) > 100.0, "лучник держит дистанцию")
	var spells := ContentRules.dict("merc.spells")
	_check(spells.size() == 4, "заклинания наёмников заданы для 4 рас")
	for race in ["humans", "ork", "druid", "necro"]:
		var list: Array = spells.get(race, [])
		_check(not list.is_empty(), "у расы %s есть хотя бы одно заклинание" % race)
		for raw in list:
			var spell := str((raw as Dictionary).get("spell", ""))
			_check(SpellDB.get_spell(spell).size() > 0,
				"заклинание %s расы %s есть в базе" % [spell, race])


# --- Roles ---------------------------------------------------------------------
func _test_role_defaults() -> void:
	var mage := _merc("merc/human_mage/t0")
	_check(mage.is_mage(), "набор мага распознан по имени")
	_check(mage.role_name() == Mercenary.ROLE_SPELL, "маг по умолчанию кастует, а не идёт в упор")
	_check(mage.available_roles().size() == 3, "у мага три роли")
	var warrior := _merc("merc/human_warrior/t0")
	_check(not warrior.is_mage(), "воин не маг")
	_check(warrior.role_name() == Mercenary.ROLE_MELEE, "воин бьёт в упор")
	_check(warrior.available_roles().size() == 1, "у воина одна роль")
	var archer := _merc("merc/human_archer/t0")
	_check(archer.is_archer(), "набор лучника распознан")
	_check(archer.role_name() == Mercenary.ROLE_RANGED, "лучник стреляет")
	_check(archer.available_roles().size() == 1, "у лучника одна роль")

	# A role the class cannot play is refused, not silently stored.
	_check(not warrior.set_role(Mercenary.ROLE_SPELL), "воину нельзя дать роль «магия»")
	_check(warrior.role_name() == Mercenary.ROLE_MELEE, "после отказа роль не изменилась")
	_check(not mage.set_role(Mercenary.ROLE_RANGED), "магу нельзя дать роль «лук»")
	_check(not archer.set_role(Mercenary.ROLE_HEAL), "лучнику нельзя дать роль «лечение»")
	_check(mage.set_role(Mercenary.ROLE_HEAL), "магу можно дать роль «лечение»")
	_check(mage.role_name() == Mercenary.ROLE_HEAL, "роль лечения применилась")
	_check(mage.set_role(""), "пустая роль = роль класса")
	_check(mage.role_name() == Mercenary.ROLE_SPELL, "после сброса маг снова кастует")


# --- Spells by reputation ------------------------------------------------------
func _test_spell_lists() -> void:
	var mage := _merc("merc/human_mage/t0")
	_set_rep(0)
	_check(mage.rep_tier() == 0, "репутация 0 — тир 0")
	var low := mage.spell_options()
	_check(low.size() == 1, "на тире 0 у мага людей одно заклинание")
	_check(str((low[0] as Dictionary).get("spell", "")) == "Fire_Arrow",
		"базовое заклинание людей — огненная стрела")
	_set_rep(GameConfig.geti("reputation", "tier_2"))
	_check(mage.rep_tier() == 2, "репутация tier_2 — тир 2")
	var mid := mage.spell_options()
	_check(mid.size() >= 2, "на тире 2 открывается второе заклинание")
	_set_rep(GameConfig.geti("reputation", "tier_3"))
	var high := mage.spell_options()
	_check(high.size() > mid.size(), "на тире 3 открывается третье (элитное)")
	# Every offered spell must be castable by a scripted caster.
	for o in high:
		_check(SpellCasting.is_unit_castable(str((o as Dictionary).get("spell", ""))),
			"предлагаемое заклинание %s умеет кастовать не-герой"
				% str((o as Dictionary).get("spell", "")))
	_set_rep(0)

	# An unknown stored spell falls back to the first unlocked one.
	mage.spell = "Teleport"
	_check(mage.active_spell() == "Fire_Arrow", "недоступное заклинание отбрасывается")


# --- Numbers -------------------------------------------------------------------
func _test_magic_numbers() -> void:
	var mage := _merc("merc/human_mage/t0")
	mage.damage = 6
	var ref := SpellDB.damage(ContentRules.str_value("merc.magic.ref_spell", "Fire_Arrow"))
	_check(ref > 0, "опорное заклинание силы магии существует")
	_check(mage.magic_power() < 0.0,
		"сила магии наёмника отрицательная: база базы выше его удара")
	var dmg := mage.magic_damage("Fire_Arrow")
	_check(abs(dmg - mage.damage) <= 1,
		"огненная стрела бьёт как удар наёмника (%d против %d)" % [dmg, mage.damage])
	mage.damage = 12
	_check(mage.magic_damage("Fire_Arrow") > dmg, "сильнее наёмник — сильнее магия")


# --- Healing -------------------------------------------------------------------
func _test_healer() -> void:
	Game.party = []
	Game.enemies = []
	var healer := _merc("merc/human_mage/t0")
	healer.set_role(Mercenary.ROLE_HEAL)
	var ally := _merc("merc/human_warrior/t0")
	ally.current_hp = 20
	Game.party.append(ally)

	var picked := healer._wounded_ally()
	_check(picked == ally, "лекарь выбирает самого раненого союзника")
	healer._heal_patient(ally)
	_check(ally.current_hp > 20, "лекарь лечит союзника (%d -> %d)"
		% [20, ally.current_hp])
	_check(absf(healer._heal_cd - 2.5) < 0.01, "после лечения уходит в кулдаун 2.5 с")
	var after := ally.current_hp
	healer._heal_patient(ally)
	_check(ally.current_hp == after, "в кулдауне повторно не лечит")

	# An enemy is never a patient, even when it is the only wounded unit nearby.
	Game.party = []
	Game.enemies = []
	var foe := _merc("merc/human_warrior/t0")
	foe.current_hp = 5
	Game.enemies.append(foe)
	_check(healer._wounded_ally() != foe, "враг никогда не выбирается пациентом")
	Game.enemies = []

	# A healer does not run at the enemy: the role owns the frame without a target.
	Game.action_mode = "attack"
	var handled := healer._tick_heal(0.05)
	_check(handled, "роль лечения забирает кадр и не идёт в бой")
	Game.action_mode = "none"


# --- Archer --------------------------------------------------------------------
func _test_archer() -> void:
	var archer := _merc("merc/human_archer/t0")
	root.add_child(archer)
	_check(archer.weapon == "bow", "лучник помечен как владелец лука")
	_check(Game.weapon_kind_of(archer) == "bow",
		"таблица типов существ видит у него лук")
	Game.action_mode = "none"
	Game.enemies = []

	var target := Enemy.new()
	target.anim_set = "monsters/wolf/t1"
	target.max_hp = 200
	target.current_hp = 200
	root.add_child(target)
	target.reset_physics_interpolation()

	var before := target.current_hp
	var arrow := ArrowShot.new()
	arrow.from_pos = archer.global_position
	arrow.to_pos = target.global_position
	arrow.target = target
	arrow.shooter = archer
	arrow.damage = 6
	root.add_child(arrow)
	arrow.call("_hit")
	_check(target.current_hp < before, "стрела наносит урон (%d -> %d)"
		% [before, target.current_hp])
	_check(Game.weapon_kind_of(archer) == "bow",
		"урон стрелы идёт как удар луком (125 % по зверям)")
	Game.enemies = []
	archer.queue_free()
	if is_instance_valid(target):
		target.queue_free()


# --- Save ----------------------------------------------------------------------
func _test_save_fields() -> void:
	Game.party = []
	var mage := _merc("merc/human_mage/t0")
	mage.set_role(Mercenary.ROLE_HEAL)
	Game.party.append(mage)
	var snap := SaveSystem._party_snapshot()
	_check(snap.size() == 1, "снимок отряда содержит наёмника")
	_check(str((snap[0] as Dictionary).get("role", "")) == Mercenary.ROLE_HEAL,
		"роль попала в сейв")
	var back := SaveSystem._party_saved(snap)
	_check(back.size() == 1, "сейв читается обратно")
	_check(str((back[0] as Dictionary).get("role", "")) == Mercenary.ROLE_HEAL,
		"роль пережила запись и чтение")
	Game.party = []


# --- Party tab -----------------------------------------------------------------
func _test_party_tab() -> void:
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 9, "spirit": 8,
		"blade": 30, "bludgeon": 15, "pike": 10,
		"fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.hero_class = "warrior"
	Game.hero_name = "Тест"
	Game.hero_character_id = "mfighter"

	var packed: PackedScene = load("res://scenes/main.tscn")
	var game = packed.instantiate()
	root.add_child(game)
	for i in range(3):
		await process_frame
	var ui = game.get("ui")
	ui.call("open_inventory_panel")
	await process_frame
	await process_frame
	var inv: Node = ui.get("_inventory_panel")
	_check(inv != null, "склад открыт")
	if inv == null:
		return

	var tabs: Array = inv.get("_view_tabs")
	_check(tabs.size() == 4, "в складе четыре вкладки (появился «Отряд»)")
	if tabs.size() == 4:
		_check(str((tabs[3] as Button).text) == Loc.t("ui.inv.tab.party"),
			"четвёртая вкладка подписана «Отряд»")

	# A mage in the party and the tab opened: one row with three role buttons.
	var mage := _merc("merc/human_mage/t0")
	mage.current_hp = 40
	Game.party.append(mage)
	inv.call("_set_view", 3)
	await process_frame
	var box: Node = inv.get("_party_box")
	_check(box != null, "страница «Отряд» построена")
	if box == null:
		return
	var buttons := _all_buttons(box)
	var labels: Array[String] = []
	for b in buttons:
		labels.append(b.text)
	_check(labels.has(Loc.t("ui.role.staff")), "у мага есть кнопка «Посох»")
	_check(labels.has(Loc.t("ui.role.spell")), "у мага есть кнопка «Магия»")
	_check(labels.has(Loc.t("ui.role.heal")), "у мага есть кнопка «Лечение»")
	_check(_option_buttons(box).size() == 1, "у мага есть выбор заклинания")

	var heal_button: Button = null
	for b in buttons:
		if b.text == Loc.t("ui.role.heal"):
			heal_button = b
	if heal_button != null:
		heal_button.emit_signal("pressed")
		await process_frame
		_check(mage.role_name() == Mercenary.ROLE_HEAL, "кнопка «Лечение» меняет роль")

	# The same tab shows an archer without role buttons beyond the bow.
	var archer := _merc("merc/human_archer/t0")
	archer.current_hp = 55
	Game.party.append(archer)
	inv.call("_refresh_party")
	await process_frame
	var texts := []
	for b in _all_buttons(box):
		texts.append(b.text)
	_check(texts.has(Loc.t("ui.role.ranged")), "у лучника показана роль «Лук»")
	# The whole page is checked, and the mage's own magic buttons are still there:
	# the archer must not have ADDED a second set of mage roles.
	var spell_buttons := 0
	for t in texts:
		if str(t) == Loc.t("ui.role.spell"):
			spell_buttons += 1
	_check(spell_buttons == 1, "лучник не добавил кнопок мага (одна — у мага)")

	Game.party = []
	game.queue_free()
	await process_frame


func _all_buttons(node: Node) -> Array[Button]:
	var out: Array[Button] = []
	if node is Button:
		out.append(node)
	for c in node.get_children():
		out.append_array(_all_buttons(c))
	return out


func _option_buttons(node: Node) -> Array[OptionButton]:
	var out: Array[OptionButton] = []
	if node is OptionButton:
		out.append(node)
	for c in node.get_children():
		out.append_array(_option_buttons(c))
	return out
