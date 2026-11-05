extends SceneTree
## Headless-проверка авто-волшебства ГЕРОЯ (D3).
##
## Жалоба игрока 27.10: «героя сильно подбили, а он не лечится и не лечит
## никого». Причина: лечение включалось только после ручного ПКМ-назначения
## (`Game.auto_spell`), а цель "party" вообще не включала самого мага.
##
## Проверяет:
##  1. маг лечится САМ без ручного auto_spell;
##  2. уровень «Базовое» баффает себя (ускорение/щит);
##  3. цель «Только я» — раненого союзника не лечит;
##  4. цель «Я и моя группа» — лечит раненого наёмника;
##  5. НПЦ-маг лечит героя рядом (второе требование).
##
## Запуск:
##   godot --headless --path . --script res://tests/auto_magic_smoke.gd

var _fails: Array = []
var _hero: Player = null
var _merc: Mercenary = null


func _initialize() -> void:
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 13, "spirit": 12,
		"blade": 10, "bludgeon": 10, "pike": 10, "shooting": 10,
		"fire": 20, "water": 20, "air": 20, "earth": 20, "astral": 20,
		"weapon": "staff", "shield": false, "armor": "light"}
	Game.hero_class = "mage"
	Game.hero_name = "Маг"
	Game.debug_magic = true
	Game.auto_spell = ""
	Game.auto_buff_tier = "base"
	Game.auto_targets = "party"
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails.append(what)
	print("AUTOMAGIC: %s %s" % ["ok  " if ok else "FAIL", what])


func _run() -> void:
	var err := change_scene_to_file("res://scenes/main.tscn")
	if err != OK:
		_check(false, "main.tscn не загрузился")
		_finish()
		return
	await process_frame
	await create_timer(0.8).timeout
	_hero = get_first_node_in_group("player") as Player
	_check(_hero != null, "герой загружен")
	if _hero == null:
		_finish()
		return
	_clear_hostiles()
	_hero.known_spells["Heal"] = {"charges": -1}
	_hero.known_spells["Haste"] = {"charges": -1}
	_hero.known_spells["Shield"] = {"charges": -1}
	_hero.current_mana = 999

	# 1. Самолечение без ручного назначения заклинания.
	Game.auto_spell = ""
	_hero.state = "idle"
	_hero.current_hp = maxi(5, int(float(_hero.max_hp) * 0.2))
	var hp_before := int(_hero.current_hp)
	_hero.last_cast_sound = ""
	_hero._tick_auto_cast(1.05)
	await create_timer(1.2).timeout
	_check(int(_hero.current_hp) > hp_before,
		"лечится сам без auto_spell (%d -> %d)" % [hp_before, int(_hero.current_hp)])
	# 1b. Авто-лечение молчит (жалоба 06.11: звук при каждом тике восстановления).
	# Вызываем тик напрямую: за 1.2 с ожидания авто-бафф успевал сыграть свой звук
	# и затирал наблюдение.
	_hero.state = "idle"
	_hero.cast_cooldowns.clear()
	_hero.current_hp = maxi(5, int(float(_hero.max_hp) * 0.2))
	var hp_silent := int(_hero.current_hp)
	_hero.last_cast_sound = ""
	_hero._auto_try_heal("Heal", 0.45)
	_check(int(_hero.current_hp) > hp_silent,
		"авто-лечение сработало (%d -> %d)" % [hp_silent, int(_hero.current_hp)])
	_check(_hero.last_cast_sound != "magic.heal",
		"авто-лечение не играет звук (последний ключ: '%s')" % _hero.last_cast_sound)

	# 1c. Ручной каст лечения по-прежнему звучит.
	Game.auto_buff_tier = "none"
	_hero.state = "idle"
	_hero.cast_cooldowns.clear()
	_hero.current_hp = maxi(5, int(float(_hero.max_hp) * 0.2))
	_hero.last_cast_sound = ""
	_hero.cast_spell("Heal", _hero.global_position, _hero)
	await create_timer(0.8).timeout
	_check(_hero.last_cast_sound == "magic.heal",
		"ручной каст лечения звучит (последний ключ: '%s')" % _hero.last_cast_sound)
	Game.auto_buff_tier = "base"

	# 2. Бафф себя на «Базовом».
	_hero.state = "idle"
	_hero.current_hp = _hero.max_hp
	_hero._tick_auto_cast(2.2)
	await create_timer(1.2).timeout
	_check(_has_aura("haste") or _has_aura("shield"),
		"«Базовое» баффает самого мага (ускорение/щит)")

	# 3-4. Цель: союзник.
	_spawn_merc()
	await process_frame
	var merc_hp := int(_merc.current_hp)

	Game.auto_targets = "self"
	_hero.state = "idle"
	_hero.current_hp = _hero.max_hp
	_hero.cast_cooldowns.clear()
	_hero._tick_auto_cast(1.05)
	await create_timer(1.0).timeout
	_check(int(_merc.current_hp) == merc_hp,
		"«Только я» — союзника не лечит (%d)" % int(_merc.current_hp))

	Game.auto_targets = "party"
	_hero.state = "idle"
	_hero.cast_cooldowns.clear()
	_hero._tick_auto_cast(1.05)
	await create_timer(1.2).timeout
	_check(int(_merc.current_hp) > merc_hp,
		"«Я и моя группа» — лечит наёмника (%d -> %d)"
			% [merc_hp, int(_merc.current_hp)])

	# 5. НПЦ-маг лечит героя рядом.
	var npc := Npc.new()
	npc.anim_set = "city_human_mage/t1"
	npc.max_hp = 100
	npc.current_hp = 100
	npc.global_position = _hero.global_position + Vector2(48, 0)
	current_scene.add_child(npc)
	Game.npcs.append(npc)
	_hero.current_hp = maxi(5, int(float(_hero.max_hp) * 0.25))
	var hero_hp := int(_hero.current_hp)
	npc._mage_heal_tick(0.1)
	_check(int(_hero.current_hp) > hero_hp,
		"НПЦ-маг лечит героя рядом (%d -> %d)" % [hero_hp, int(_hero.current_hp)])

	# 6. Ускорение НЕ перекастовывается, пока эффект висит (баг 28.10).
	StatusEffects.clear(_hero)
	for sn in _hero.cast_cooldowns.keys():
		_hero.cast_cooldowns[sn] = 0.0
	_hero.state = "idle"
	_hero.current_hp = _hero.max_hp
	Game.auto_buff_tier = "base"
	_hero._auto_try_buffs()
	await create_timer(1.2).timeout
	var hasted := StatusEffects.has_effect(_hero, "haste")
	# Снимаем кулдаун: проверяем именно проверку «эффект уже висит».
	_hero.cast_cooldowns.clear()
	_hero.state = "idle"
	_hero._auto_try_buffs()
	await create_timer(0.6).timeout
	_check(hasted and StatusEffects.has_effect(_hero, "haste"),
		"ускорение наложено")
	_check(_hero.state == "idle" and float(_hero.cast_cooldowns.get("Haste", 0.0)) == 0.0,
		"ускорение не перекастовывается, пока эффект живёт")

	# 6b. Щит лежит в shield_armor — автокаст не должен его повторять (баг 28.10).
	_hero.cast_cooldowns.clear()
	_hero.state = "idle"
	_hero._auto_try_buffs()      # Haste активен → кастует следом Щит
	await create_timer(1.0).timeout
	var shield_on := StatusEffects.shield_armor_time(_hero) > 0.0
	_hero.cast_cooldowns.clear()
	_hero.state = "idle"
	_hero._auto_try_buffs()
	await create_timer(0.6).timeout
	_check(shield_on, "щит наложен (shield_armor)")
	_check(_hero.state == "idle"
			and float(_hero.cast_cooldowns.get("Shield", 0.0)) == 0.0,
		"щит не перекастовывается, пока shield_armor живёт")

	# 6c. Кулдаун считается от познания магии (навык сферы + разум).
	var cd_base := SpellDB.cooldown_of("Shield")
	var cd_low := Game.spell_cooldown(_hero, "Shield")
	var keep_astral := int(_hero.astral_skill)
	_hero.astral_skill = 100
	var cd_high := Game.spell_cooldown(_hero, "Shield")
	_hero.astral_skill = keep_astral
	_check(cd_low < cd_base and cd_high < cd_low,
		"кулдаун растёт от незнания: %.2f (навык %d) < %.2f < база %.2f"
			% [cd_high, 100, cd_low, cd_base])

	# 7. Воин: уровни авто-волшебства на него НЕ действуют.
	_hero.has_mana = false
	_hero.state = "idle"
	_hero.cast_cooldowns.clear()
	StatusEffects.clear(_hero)
	Game.auto_buff_tier = "max"
	_hero._tick_auto_cast(2.5)
	await create_timer(0.6).timeout
	_check(not StatusEffects.has_effect(_hero, "haste")
			and not StatusEffects.has_effect(_hero, "bless"),
		"у воина уровни авто-волшебства ничего не кастуют")

	# 8. Воин: ОДИН помеченный свиток, по кулдауну, ровно один за каст.
	var had := _hero.inventory.count("Scroll Haste")
	for i in range(10):
		_hero.add_item("Scroll Haste")
	Game.auto_scroll_item = "Scroll Haste"
	_hero.state = "idle"
	_hero.cast_cooldowns.clear()
	for i in range(3):
		_hero._tick_auto_cast(1.1)
		await create_timer(0.9).timeout
	var left := _hero.inventory.count("Scroll Haste")
	_check(left == had + 10 - 1,
		"из 10 свитков за серию кастов сгорел ровно 1 (осталось %d)" % left)
	_check(StatusEffects.has_effect(_hero, "haste"),
		"свиток ускорения наложился на самого воина")
	# Снимаем эффект и кулдаун — следующий каст разрешён.
	StatusEffects.clear(_hero)
	_hero.cast_cooldowns.clear()
	_hero.state = "idle"
	_hero._tick_auto_cast(1.1)
	await create_timer(0.9).timeout
	_check(_hero.inventory.count("Scroll Haste") == left - 1,
		"после снятия эффекта и кулдауна свиток расходуется снова")

	_cleanup()
	_finish()


func _has_aura(kind: String) -> bool:
	for c in _hero.get_children():
		if c is SpellAura and (c as SpellAura).kind == kind:
			return true
	return false


func _spawn_merc() -> void:
	_merc = Mercenary.new()
	_merc.anim_set = "monsters/wolf"
	_merc.max_hp = 100
	_merc.damage = 1
	_merc.global_position = _hero.global_position + Vector2(40, 0)
	current_scene.add_child(_merc)
	_merc.current_hp = 20
	Game.party.append(_merc)


func _clear_hostiles() -> void:
	for arr in [Game.enemies, Game.npcs, Game.party]:
		for u in arr.duplicate():
			arr.erase(u)
			if is_instance_valid(u) and u is Node:
				(u as Node).queue_free()


func _cleanup() -> void:
	Game.party.clear()
	Game.npcs.clear()
	Game.enemies.clear()
	Game.auto_spell = ""
	Game.auto_buff_tier = "base"
	Game.auto_targets = "party"
	Game.auto_scroll_item = ""
	StatusEffects.clear(_hero)


func _finish() -> void:
	if _fails.is_empty():
		print("AUTOMAGIC: RESULT: OK")
	else:
		print("AUTOMAGIC: RESULT: FAIL (%d): %s" % [_fails.size(), str(_fails)])
	quit(0 if _fails.is_empty() else 1)
