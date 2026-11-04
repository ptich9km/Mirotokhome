extends CharacterBody2D
class_name Enemy

@export var max_hp: int = 50
@export var damage: int = 8
@export var move_speed: float = 80.0
@export var aggro_radius: float = 150.0
@export var deaggro_radius: float = 200.0
@export var home_position: Vector2
## Набор анимации врага. Пуст по умолчанию НАМЕРЕННО: арт Аллодов удалён
## (11.10), наборов Серых в базе нет, и дефолт вида на удалённый набор
## означал бы либо падение в setup(), либо невидимого врага. Набор приходит
## из генератора карты при спавне; пока пул пуст, враги не спавнятся вовсе.
@export var anim_set: String = ""

## Смерть врага (22.10): сигнал для квестов (QuestSystem считает охоту).
## Зверь-цель квеста несёт quest_id — так голова стаи отличается от обычной
## особи того же набора.
signal died(unit: Enemy)

var quest_id: String = ""

var current_hp: int
var state: String = "idle"
var attack_target: Node2D = null
var attack_cooldown: float = 0.0
var _impact_timer := -1.0            # отсчёт до кадра удара (замах); <0 = нет удара в полёте
var can_flee: bool = false        # по умолчанию монстр дерётся до конца, не убегает
var _path: Array = []             # маршрут к игроку (обход препятствий)
var _repath := 0.0
var _corpse_timer := 0.0          # сколько труп лежит до удаления (без разложения)
var health_bar: HealthBar
var _anim: UnitAnimBase = null
## Стычка событий (19.10): тег своей группы и тег противника. Пусто = обычный Серый.
var event_tag: String = ""
var foe_group: String = ""

## Форпост фракции (пакет B, 28.10). Пустая faction — обычный Серый.
## Стражник форпоста НЕ враг по умолчанию: он бьёт героя только при вражде
## (репутация фракции < 0) или после удара героя (provoked). Это и есть
## решение игрока «враждебны при плохой репутации».
@export var faction: String = ""
@export var outpost_id: String = ""
var provoked: bool = false

func _ready():
	add_to_group("enemy")
	Game.configure_unit_body(self)
	# Стартовый разброс репаса: иначе все враги зовут find_path в одном кадре.
	_repath = randf() * 1.2
	current_hp = max_hp
	home_position = global_position
	_create_sprite()
	_create_health_bar()

func _create_health_bar():
	health_bar = preload("res://scripts/health_bar.gd").new()
	health_bar.max_hp = max_hp
	health_bar.has_mana = false  # У врагов нет маны
	add_child(health_bar)

func _create_sprite():
	var old_sprite = get_node_or_null("Sprite")
	if old_sprite:
		old_sprite.queue_free()

	_anim = UnitAnim.new()
	_anim.name = "UnitAnim"
	add_child(_anim)
	_anim.setup(anim_set)
	_anim.play(UnitAnim.Anim.IDLE)

func _physics_process(delta):
	if not Game.perf_enabled:
		_physics_process_impl(delta)
		return
	var t0 := Time.get_ticks_usec()
	_physics_process_impl(delta)
	Game.perf_end("enemy_ai", t0)


func _physics_process_impl(delta):
	if Game.is_paused:
		return
	# P5: далеко от героя — AI спит (контент не трогаем, только CPU).
	if Game.hero != null and is_instance_valid(Game.hero):
		if global_position.distance_squared_to(Game.hero.global_position) > 1600.0 * 1600.0:
			velocity = Vector2.ZERO
			return
	# Туман войны (19.10): вне видимой клетки юнит не тикает и не рисуется.
	if Game.fog != null and Game.fog.blocks_process(global_position):
		visible = false
		return
	visible = true

	attack_cooldown = max(0, attack_cooldown - delta)

	# Монстр умер — играем анимацию падения, потом труп остаётся на земле
	if state == "dying" or state == "decay" or state == "corpse":
		if _anim:
			match state:
				"dying":
					_anim.play(UnitAnim.Anim.DYING)
					if _anim.advance(delta):
						velocity = Vector2.ZERO
						if UnitDB.decay_phases(anim_set) > 0:
							state = "decay"          # есть разложение (скелет)
							_anim.play(UnitAnim.Anim.DECAY)
						else:
							state = "corpse"
							_anim.freeze_last_frame(UnitAnim.Anim.DYING)
							_corpse_timer = 5.0      # труп лежит 5 сек, потом исчезает
				"decay":
					if _anim.advance(delta):
						_corpse_timer = 3.0         # разложился — ещё немного лежит
						state = "corpse"
						_anim.freeze_last_frame(UnitAnim.Anim.DECAY)
				"corpse":
					if _corpse_timer > 0.0:
						_corpse_timer -= delta
						if _corpse_timer <= 0.0:
							EventSystem.note_freed()
							queue_free()
							return
		velocity = velocity.move_toward(Vector2.ZERO, GameConfig.getf("movement", "decel") * delta)
		move_and_slide()
		_apply_relief_stand()
		return

	# Обновляем бар здоровья
	if health_bar:
		health_bar.update_bars(current_hp)

	# Единая цель боя: игрок (приоритет) или страж города, что в радиусе агро.
	var target: Node2D = _combat_target()
	if target == null:
		velocity = Vector2.ZERO
		move_and_slide()
		# Стража форпоста стоит без цели (нейтральна) — обязана стоять на
		# рельефе, иначе на холме уходит под землю на высоту рельефа.
		_apply_relief_stand()
		return
	attack_target = target

	var distance_to_target = Game.units_range(self, target)
	var hp_percent = float(current_hp) / max_hp

	match state:
		"idle":
			if distance_to_target < aggro_radius:
				state = "chase"
		"chase":
			if distance_to_target > deaggro_radius:
				state = "idle"
				velocity = Vector2.ZERO
			elif distance_to_target < Game.attack_reach(self):
				state = "attack"
				velocity = Vector2.ZERO   # остановиться и бить, а не проскакивать мимо
			elif hp_percent < 0.15 and can_flee:
				state = "flee"
			else:
				_chase_move(delta, target)
		"attack":
			if distance_to_target > Game.attack_reach(self) + 8.0:
				state = "chase"
				_impact_timer = -1.0
			else:
				# Держим стоп между ударами: без этого инерция от погони
				# несёт монстра мимо игрока — он «бегает вокруг, то туда, то сюда»
				velocity = velocity.move_toward(Vector2.ZERO, GameConfig.getf("movement", "decel") * delta)
				if attack_cooldown <= 0.0 and _impact_timer < 0.0:
					attack_cooldown = GameConfig.getf("combat", "attack_cooldown")
					# Единая точка урона (промах + поглощение бронёй) — на кадре удара,
					# а не в начале замаха: удар звучит по анимации.
					_impact_timer = UnitDB.attack_delay(anim_set)
				elif _impact_timer >= 0.0:
					_impact_timer -= delta
					if _impact_timer < 0.0:
						_impact_timer = -1.0
						if Game.is_miss(self, target):
							print("%s промахнулся по %s!" % [name, target.name])
						else:
							Game.deal_damage(target, damage, "physical", "", self)
						SoundDB.play(_unit_sound_at(0))
		"flee":
			var flee_direction = Game.safe_dir(target.global_position, global_position)
			_move_checked(flee_direction, effective_speed() * 1.5, delta)
			if distance_to_target > deaggro_radius * 1.5:
				EventSystem.note_freed()
				queue_free()

	# Анимация монстра по состоянию
	if _anim:
		match state:
			"chase", "flee":
				_anim.play(UnitAnim.Anim.MOVE)
				_anim.set_direction_vec(velocity)
				_anim.advance(delta)
			"attack":
				_anim.play(UnitAnim.Anim.ATTACK)
				_anim.speed_scale = 1.0
				_anim.advance(delta)
			_:
				_anim.play(UnitAnim.Anim.IDLE)

	move_and_slide()
	_apply_relief_stand()

## Стоять на рельефе: поднять спрайт на высоту клетки (как в Allods16).
## Летающие юниты (Z, монстры bat/dragon/succubus) парят над землёй.
func _apply_relief_stand() -> void:
	if _anim == null:
		return
	var h := 0.0
	var map_node = get_tree().get_first_node_in_group("alm_map")
	if map_node != null and map_node.has_method("relief_at_world"):
		h = float(map_node.call("relief_at_world", global_position))
	# Высота полёта юнита (Z из units.txt; обычно 0 = ходит по земле)
	var z := UnitDB.fly_z(anim_set)
	_anim.position = Vector2(_anim.position.x, -(h + z))
	if health_bar:
		# Над головой ФИГУРЫ, а не над холстом кадра (см. Game.unit_local_rect).
		var top := Game.unit_local_rect(self).position.y
		health_bar.position.y = top - (h + z) - 6.0

# --- Физика движения (плавный разгон/торможение + проходимость) ---
## Разгон/торможение - в GameConfig [movement] accel/decel.

## Движение с проверкой проходимости карты (летающие игнорируют землю).
## Как у игрока: полный вектор -> X-only -> Y-only. Иначе, упираясь в стену или
## дерево, враг гасил скорость целиком и «прилипал» — скользить вдоль препятствия
## он не умел вовсе.
func _move_checked(direction: Vector2, speed: float, delta: float) -> void:
	direction = Game.movement_direction(self, direction)
	var wanted := direction * speed
	var step := wanted * delta
	if _can_step(step):
		velocity = velocity.move_toward(wanted, GameConfig.getf("movement", "accel") * delta)
		return
	if delta <= 0.0:
		velocity = Vector2.ZERO
		return
	var slide := Vector2.ZERO
	# Обе оси пробуем всегда, а не «X, иначе Y»: выбор по близости к желаемому
	# направлению (Game.choose_slide) убирает дёрганье у деревьев и углов.
	var slide_axis := Game.choose_slide(direction,
		_can_step(Vector2(step.x, 0.0)), _can_step(Vector2(0.0, step.y)))
	slide = Vector2(slide_axis.x * step.x, slide_axis.y * step.y)
	if slide == Vector2.ZERO:
		velocity = velocity.move_toward(Vector2.ZERO, GameConfig.getf("movement", "decel") * delta)
	else:
		velocity = velocity.move_toward(slide / delta, GameConfig.getf("movement", "accel") * delta)

## Разрешён ли сдвиг: проходимая клетка (летающие игнорируют землю). Выход из
## СВОЕЙ непроходимой клетки разрешаем — иначе враг не сможет выбраться сам.
func _can_step(step: Vector2) -> bool:
	var map_node = get_tree().get_first_node_in_group("alm_map")
	if UnitDB.fly_z(anim_set) > 0 or map_node == null or not map_node.has_method("is_walkable_world"):
		return true
	var next := global_position + step
	return bool(map_node.is_walkable_world(next)) \
		or Vector2i(int(int(global_position.x) / 32.0), int(int(global_position.y) / 32.0)) \
			== Vector2i(int(int(next.x) / 32.0), int(int(next.y) / 32.0))

## Цель боя: игрок (приоритет; в агро или в погоне — до deaggro) или
## ближайший страж-НПЦ города в радиусе агро.
## Невидимого героя враг «не замечает» дальше 40 px, но видит вплотную.
func _combat_target() -> Node2D:
	if not Game.perf_enabled:
		return _combat_target_impl()
	var t0 := Time.get_ticks_usec()
	var out := _combat_target_impl()
	Game.perf_end("enemy_target_scan", t0)
	return out


func _combat_target_impl() -> Node2D:
	# Стычка событий (19.10): пока враг в группе события, он бьёт
	# противоположную группу; удар героя по нему переводит его на героя
	# (см. take_damage). Противник умер или исчез - обычная логика ниже.
	if foe_group != "":
		var foe: Node2D = EventSystem.foe_for(self)
		if foe != null:
			return foe
	# Форпост (пакет B): нейтральная стража героя не замечает. Вражда
	# начинается от репутации фракции < 0 или от удара героя (provoked).
	if not is_hostile_to_hero():
		return null
	var player = get_tree().get_first_node_in_group("player")
	if is_instance_valid(player) and not Game.hero_dead:
		var dp := Game.units_range(self, player)
		var committed := state == "chase" or state == "attack" or state == "flee"
		var lim := deaggro_radius if committed else aggro_radius
		lim *= StatusEffects.vision_mult(self)   # Darkness сужает обзор
		if StatusEffects.is_invisible(player) and not committed:
			lim = 40.0
		if dp < lim:
			return player
	var best: Node2D = null
	var bd := deaggro_radius * StatusEffects.vision_mult(self)
	# Отсечение (29.10): точная геометрия только для тех НПЦ, кто может
	# оказаться в радиусе; перебор всех 28 жителей с расчётом хит-боксов
	# каждому тикающему врагу — это и была вторая половина просадки в городе.
	var reach := bd + 128.0
	var reach_sq := reach * reach
	for n in Game.npcs:
		if n == null or not is_instance_valid(n):
			continue
		if not (n is Npc) or n.role != "guard":
			continue
		if StatusEffects.is_invisible(n):
			continue
		var npos: Vector2 = (n as Node2D).global_position
		var dx := npos.x - global_position.x
		var dy := npos.y - global_position.y
		if dx * dx + dy * dy > reach_sq:
			continue
		var d := Game.units_range(self, n)
		if d < bd:
			bd = d
			best = n
	return best

## Можно ли этому юниту бить героя. Пустая faction — обычный монстр (всегда).
## Форпост: вражда при репутации фракции < 0 либо после удара героя.
func is_hostile_to_hero() -> bool:
	if faction == "":
		return true
	if provoked:
		return true
	return Game.hero_reputation(faction) < 0


## Погоня с обходом препятствий. Перепланировка раз в ~1.2 с + случайный
## старт, чтобы 75 врагов не звали find_path в одном кадре (тормоза).
func _chase_move(delta: float, target: Node2D) -> void:
	var tpos: Vector2 = target.global_position
	var dist := global_position.distance_to(tpos)
	# Дальняя цель — напрямую; путь только когда реально есть препятствия.
	if _path.is_empty() or dist > 400.0:
		_repath -= delta
		if _repath <= 0.0:
			_repath = 1.2 + randf() * 0.6
			var map_node = get_tree().get_first_node_in_group("alm_map")
			if map_node != null and map_node.has_method("find_path") and dist < 500.0:
				_path = map_node.find_path(global_position, tpos)
	if _path.size() > 0:
		var wp: Vector2 = _path[0]
		if global_position.distance_to(wp) <= 8.0:
			_path.pop_front()
		if _path.size() > 0:
			wp = _path[0]
			_move_checked(Game.safe_dir(global_position, wp), effective_speed(), delta)
		else:
			# Путь кончился — идём напрямую к цели (не замираем).
			_move_checked(Game.safe_dir(global_position, tpos), effective_speed(), delta)
	else:
		_move_checked(Game.safe_dir(global_position, tpos), effective_speed(), delta)

## --- Производные характеристики (по данным монстра, как у героя) ---
## Применяются через Game.unit_*: атака->точность, защита->уклонение,
## поглощение->броня, защиты -> защита от стихий (для магии).

func get_attack() -> int:
	return int(damage / float(GameConfig.geti("combat", "enemy_attack_dmg_div"))) \
		+ int(max_hp / float(GameConfig.geti("combat", "enemy_attack_hp_div"))) \
		+ StatusEffects.stat_flat(self, "attack")

func get_defense() -> int:
	var base := int(max_hp / float(GameConfig.geti("combat", "enemy_defense_div")))
	return int(round((base + StatusEffects.stat_flat(self, "defense")) * StatusEffects.defense_mult(self)))

func get_absorption() -> int:
	return int(max_hp / float(GameConfig.geti("combat", "enemy_absorption_div")))

## Сопротивление стихии — из данных набора (assets/units/units_db.json, поле
## "resist"). Раньше было max_hp/60, из-за чего босс с большим HP становился
## почти неуязвимым к одной стихии.
func _resist(sphere: String) -> int:
	return UnitDB.resist_of(anim_set, sphere) + StatusEffects.resist_bonus(self, sphere)

func get_protection_fire() -> int:   return _resist("Fire")
func get_protection_water() -> int:  return _resist("Water")
func get_protection_air() -> int:    return _resist("Air")
func get_protection_earth() -> int:  return _resist("Earth")
func get_protection_astral() -> int: return _resist("Astral")

## Скорость с учётом Haste/Slow (move_speed — база, кэшировать нельзя).
func effective_speed() -> float:
	return move_speed * StatusEffects.speed_mult(self)

## Обзор с учётом Darkness (Vision ×0.5 и т.п.).
func effective_sight() -> int:
	return maxi(1, int(get_sight() * StatusEffects.vision_mult(self)))

## Обзор в клетках (влияет на радиус агро — как просили: «обзор -> агро»).
func get_sight() -> int:
	return maxi(1, int(move_speed / 8.0) + int(max_hp / 60.0))

## Единая точка входящего урона: вызывается из Game.deal_damage
## (там уже применены промах, поглощение брони и защиты стихий).
## Возвращает фактически снятое HP (после щита) — его рисует Game.deal_damage.
func take_damage(dmg: int, attacker) -> int:
	# Мёртвый монстр (труп/разложение) урона не получает — иначе повторный
	# лут/звуки при махах по трупу
	if state == "dying" or state == "decay" or state == "corpse":
		return 0
	if dmg <= 0:
		return 0
	# Герой ударил участника стычки - выходит из события и отвечает герою.
	if foe_group != "" and is_instance_valid(attacker) \
			and (attacker as Node).is_in_group("player"):
		event_tag = ""
		foe_group = ""
	# Нейтральная стража форпоста после удара героя становится враждебной.
	if faction != "" and is_instance_valid(attacker) \
			and (attacker as Node).is_in_group("player"):
		provoked = true
		# Бьют лагерь — поднимается весь лагерь, а не один стражник: иначе
		# форпост разбирался бы по одному безнаказанно.
		if outpost_id != "":
			for other in Game.enemies:
				if other == null or not is_instance_valid(other) or other == self:
					continue
				if str(other.get("outpost_id")) == outpost_id:
					other.set("provoked", true)
	# Раньше щит на враге не работал: shield_reduce здесь не вызывался
	var shielded := Game.shield_reduce(self, dmg)
	if shielded <= 0:
		SpellVFX.shield_hit(self)
		return 0
	current_hp -= shielded
	# При получении урона — сразу начинаем погоню (но не прерываем текущую атаку,
	# иначе после каждого попадания монстр сбрасывает замах)
	if is_instance_valid(attacker):
		if state != "attack":
			state = "chase"
			attack_target = attacker
	if current_hp <= 0:
		SoundDB.play(_unit_sound_at(4))  # смерть
		# Убираем из списка врагов: герой перестаёт выбирать труп целью
		Game.enemies.erase(self)
		EventSystem.note_freed()
		_drop_loot()
		# Форпост: смерть стражи может зачистить лагерь (пакет B).
		if outpost_id != "":
			Game.on_outpost_guard_died(self)
		state = "dying"
		attack_target = null
		velocity = Vector2.ZERO
		# Труп не блокирует движение (жалоба: «спотыкаюсь о лут» — это труп
		# держал collision_layer=1 ещё 5–8 секунд).
		collision_layer = 0
		collision_mask = 0
		if health_bar:
			health_bar.visible = false  # труп не показывает шкалу
		died.emit(self)
	else:
		SoundDB.play_pain(UnitDB.unit_sound(anim_set))  # боль
	return shielded

## Звуковой ID юнита по позиции массива Sound (attack/pain1/pain2/death).
func _unit_sound_at(idx: int) -> String:
	return str(SoundDB.sound_at(UnitDB.unit_sound(anim_set), idx))

func _drop_loot():
	# Мешок убран (03.10): игрок сразу видит, что именно выпало. Класс переименован
	# loot_bag.gd -> loot_drop.gd, поэтому здесь новый путь и новое имя.
	var drop_script: GDScript = load("res://scripts/loot_drop.gd")
	if drop_script == null:
		return
	var drop: LootDrop = drop_script.new()
	drop.items = _make_loot()
	# Размер баночки зелья по силе врага: труп муравья и труп босса не должны
	# выглядеть одинаково. Пороги те же, что в npc.gd:_potion_size.
	drop.potion_size = "large" if max_hp >= 100 else ("medium" if max_hp >= 55 else "small")
	# Добыча на высоте рельефа (юнит поднят на высоту холма; без этого иконки
	# «тонут» ниже уровня земли на высоту рельефа)
	var h := _relief_here()
	drop.global_position = global_position + Vector2(randf_range(-22, 22), randf_range(-16, 16) - h)
	# Родитель, а не get_tree().current_scene: последний равен null в
	# headless-скриптах и при спавне юнита из теста.
	var host := get_parent()
	if host == null:
		host = get_tree().current_scene
	if host != null:
		host.add_child(drop)

## Высота рельефа под юнитом (0, если карты нет).
func _relief_here() -> float:
	var map_node := get_tree().get_first_node_in_group("alm_map")
	if map_node != null and map_node.has_method("relief_at_world"):
		return float(map_node.call("relief_at_world", global_position))
	return 0.0

## Добыча по СЕМЕЙСТВУ вида (loot_tables.json + UnitDB.loot_family_of).
## Звери/насекомые: золото + трава, БЕЗ оружия/брони (решение игрока 07.10).
##
## СНАРЯЖЕНИЕ С 22.10 ПАДАЕТ СЛОМАННЫМ. Причина не в эстетике: целую вещь
## мастерская переплавляет по выходу «целое» (0.8 от рецепта,
## CraftDB.INTACT_RECYCLE_MULT), и она обходила выход по качеству сломанной
## (1/2/4 слитка). Игрок копил целые вещи с Серых и получал слитки мимо
## качества. Металл сломанной вещи выбирается ПО ТИРУ врага
## (ItemDB.broken_materials), иначе зверь-новичок ронял бы радий.
##
## Вещей ДВЕ: своё снаряжение (броня или оружие) и, с шансом
## `garment_share`, одежда. Так было до перехода на сломанные вещи, но потом
## одежда оказалась в той же строке вероятности и стала съедать шанс брони.
func _make_loot() -> Array:
	var family := UnitDB.loot_family_of(anim_set)
	if family == "":
		family = "default"
	var table := _loot_table(family)
	var pool: Array = []
	var gold_mult := float(table.get("gold_mult", 0.6)) * GameConfig.getf("economy", "loot_gold_multiplier")
	var gold_base := 4 + int(max_hp / 5.0)
	var gold := int(round(float(gold_base + randi() % gold_base) * gold_mult))
	if gold > 0:
		pool.append({"gold": gold})
	if randi() % 100 < int(table.get("potion_chance", 20)):
		pool.append({"key": "Potion Medium Healing" if randi() % 2 == 0 else "Potion Mana Regeneration"})
	if randi() % 100 < int(table.get("broken_gear_chance", 20)):
		pool.append_array(_broken_gear(int(table.get("garment_share", 0))))
	# ЦЕЛАЯ вещь — редкий бонус: у боссов и драконов свой шанс
	# ([craft] boss_intact_chance), у обычных Серых — intact_gear_chance из
	# таблицы (у monstrous он 0).
	var intact_chance := GameConfig.geti("craft", "boss_intact_chance") \
		if UnitDB.is_boss(anim_set) else int(table.get("intact_gear_chance", 0))
	if randi() % 100 < intact_chance:
		var intact := _random_intact_gear()
		if not intact.is_empty():
			pool.append(intact)
	# Бирка фракции (пакет B переработки ковки): стражник форпоста носит свою
	# бирку всегда — решение игрока 28.10 «падают в любом случае». Это не
	# роскошь, а единственный источник фракционного ингредиента для брони.
	if faction != "":
		var tag := ItemDB.tag_key(faction)
		if tag != "" and not ItemDB.find(tag).is_empty():
			pool.append({"key": tag})
	# Магическая эссенция - второй источник наряду с портной (07.10).
	if randi() % 100 < int(table.get("essence_chance", 0)):
		pool.append({"key": CraftDB.ESSENCE_KEY})
	if randi() % 100 < int(table.get("herb_chance", 0)):
		var herbs: Array = table.get("herbs", [])
		if herbs.size() > 0:
			pool.append({"key": str(herbs[randi() % herbs.size()])})
	return pool


## Таблица лута из assets/config/loot_tables.json (кэш на процесс).
static var _loot_tables_cache: Dictionary = {}
static var _loot_tables_loaded: bool = false


static func _loot_table(family: String) -> Dictionary:
	if not _loot_tables_loaded:
		_loot_tables_loaded = true
		var path := "res://assets/config/loot_tables.json"
		if ResourceLoader.exists(path):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			if parsed is Dictionary:
				_loot_tables_cache = parsed as Dictionary
	var t: Dictionary = _loot_tables_cache.get(family, {})
	if t.is_empty():
		t = _loot_tables_cache.get("default", {})
	return t

## Категории и материалы вещей, которые носил Серый, для ItemDB.roll_broken_gear.
## Пара «снаряжение + возможно одежда»: металл снаряжения — по тиру
## (_gear_tier), одежда — лён.
func _gear_options(garment_share: int) -> Array:
	var own := ItemDB.broken_materials("Armor", _gear_tier())
	var options: Array = [
		{"materials": own, "categories": ["Armor", "Weapon"]},
	]
	if garment_share > 0 and randi() % 100 < garment_share:
		options.append({"materials": ItemDB.broken_materials("Garment", _gear_tier()),
			"categories": ["Garment"]})
	return options


## Сломанные вещи в мешке: качество, металл и подбор ключа — в
## ItemDB.roll_broken_gear (тот же хелпер зовёт НПЦ, npc.gd:_random_gear).
func _broken_gear(garment_share: int) -> Array:
	var out: Array = []
	for opt in _gear_options(garment_share):
		var gear := ItemDB.roll_broken_gear(
			(opt as Dictionary).get("materials", []), (opt as Dictionary).get("categories", []))
		if not gear.is_empty():
			out.append(gear)
	return out


## Тир Серого (1..5): поле `tier` набора, а при отсутствии — суффикс `_t<N>`
## имени. Металл сломанного растёт вместе с тиром (ItemDB.broken_materials):
## волк тира 1 не должен ронять радий.
func _gear_tier() -> int:
	var t := UnitDB.tier(anim_set)
	if t > 0:
		return t
	var short := anim_set.get_file()
	var at := short.rfind("_t")
	if at > 0 and short.substr(at + 2).is_valid_int():
		return int(short.substr(at + 2))
	return 1

## Случайная ЦЕЛАЯ вещь «по силе врага» (бюджет = HP × 12), из настоящей базы.
## Только для редкого бонуса (intact_gear_chance / боссы): обычный поток
## снаряжения с Серых — сломанный (_broken_gear).
func _random_intact_gear() -> Dictionary:
	var budget := maxi(20, max_hp * 12)
	var pool: Array = []
	for it in ItemDB.all():
		if not ItemDB.is_equippable(it):
			continue
		var p := int(it.get("price", 0))
		if p > 0 and p <= budget:
			pool.append(it)
	if pool.is_empty():
		return {}
	return {"key": str((pool[randi() % pool.size()] as Dictionary).get("key", ""))}
