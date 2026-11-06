extends CharacterBody2D
class_name Npc
## Мирный житель (НПЦ): гуляет у своей точки, не отвлекается на игрока.
## role "citizen" — стоит на посту (мелкое шевеление); role "guard" —
## патрулирует город (is_patrol) и дерётся с Серыми (монстрами), героя не трогает.

@export var anim_set: String = "ork_mage_a52/t0"
@export var patrol_radius: int = 3           # клеток вокруг точки привязки
@export var walk_speed: float = 45.0
@export var pause_min: float = 1.2
@export var pause_max: float = 4.0
@export var max_hp: int = 30                 # здоровье жителя
@export var role: String = "citizen"         # citizen | guard
@export var is_patrol: bool = false          # патруль вокруг поста (стражи)
@export var damage: int = 0                  # урон стражи (граждане не бьют)
@export var aggro_radius: float = 133.0      # guard aggro on Greys: GameConfig "npc"/"guard_aggro_radius" (-30%)
@export var is_archmage: bool = false        # капитан = великий маг (клик → панель)
## Глава города (22.10): отдельный NPC, держит квесты, над головой —
## QuestMarker «!»/«?». city_id — id записи _cities генератора ("c0t0").
@export var is_city_head: bool = false
@export var city_id: String = ""

var current_hp: int
var state: String = "idle"                   # idle | move | dying | decay | corpse
var _corpse_timer := 0.0
var home := Vector2.ZERO       # мировая точка привязки (центр клетки)
var post := Vector2.ZERO       # мировой пост (центр клетки) из sidecar
var alm_map = null             # CustomMap или AlmMap из группы "alm_map"
var _anim: UnitAnimBase = null
var _target := Vector2.ZERO
var _moving := false
var _waiting := true
var _pause_timer := 0.0
var attack_cooldown := 0.0
var _impact_timer := -1.0
var _path: Array = []
var _repath := 0.0
## Кулдаун лечения мага-НПЦ (см. `_mage_heal_tick`).
var _heal_cd := 0.0
## Бюджет A*: не больше 2 запросов пути за физический кадр на всю карту.
## Без него десяток патрульных в городе мог запускать поиск в один кадр.
static var _path_frame := -1
static var _path_calls := 0
var quest_marker: QuestMarker = null

func _ready() -> void:
	add_to_group("npcs")
	Game.configure_unit_body(self)
	_repath = randf() * 1.2
	# Мирные NPC не блокируют путь героя (слой 2). Иначе толпа жителей
	# в центре города превращает ходьбу в рывки: mask=1 у героя и layer=1
	# у NPC делали их физическими стенами.
	if role == "citizen" or is_archmage:
		var body := self as CharacterBody2D
		if body != null:
			body.collision_layer = 2
	current_hp = max_hp
	alm_map = get_tree().get_first_node_in_group("alm_map")
	_anim = UnitAnim.new()
	_anim.name = "UnitAnim"
	add_child(_anim)
	_anim.setup(anim_set)
	_anim.play(UnitAnim.Anim.IDLE)
	_pick_new_target()
	if is_city_head:
		_make_quest_marker()
	# Жители — статичная декорация города: не патрулируют, не ищут путь и не
	# тикают физику. Именно их толпа давала просадку при входе в город.
	if role == "citizen":
		velocity = Vector2.ZERO
		_waiting = true
		set_physics_process(false)


## The "!"/"?" marker above the head of a city head. The kind is set by
## QuestSystem through Npc.refresh_quest_marker(): the NPC itself knows no quests.
##
## The height is measured from the TOP OF THE FIGURE, not from sel_box. Before,
## `sel_box().position.y` was used — a coordinate inside the texture (10 px for a
## 64 px frame), not "pixels above the feet" — so the marker hung at 24 px, which is
## waist level (player report 06.11: "the question mark sits over the crotch").
func _make_quest_marker() -> void:
	quest_marker = QuestMarker.new()
	quest_marker.name = "QuestMarker"
	quest_marker.set_height_px(_quest_marker_height())
	add_child(quest_marker)
	refresh_quest_marker()


## Figure top above the feet + gap + half of the marker icon.
## The main source is content_rect() (the alpha frame of the current frame, it already
## contains the set scale); the fallback is frame height minus the sel_box top, the
## last resort is the old 24 px.
func _quest_marker_height() -> float:
	const GAP := 6.0
	const MARKER_HALF := 12.0   # marks/*.png are 24×24 and the sprite is centered
	const FALLBACK := 24.0
	var figure_top := 0.0
	if _anim != null:
		var r: Rect2 = _anim.content_rect()
		if r.size.y > 0.5:
			figure_top = -r.position.y
		elif _anim.sprite_height() > 0.0:
			var box := UnitDB.sel_box(anim_set)
			figure_top = _anim.sprite_height() - float(box.position.y)
	if figure_top <= 0.0:
		return FALLBACK
	return figure_top + GAP + MARKER_HALF


## Пересчитать вид маркера по состоянию квестов города.
func refresh_quest_marker() -> void:
	if quest_marker == null or not is_instance_valid(quest_marker):
		return
	if QuestSystem.instance == null or city_id == "":
		quest_marker.set_kind("")
		return
	quest_marker.set_kind(QuestSystem.instance.marker_kind_for(city_id))

func _physics_process(delta: float) -> void:
	if not Game.perf_enabled:
		_physics_process_impl(delta)
		return
	var t0 := Time.get_ticks_usec()
	_physics_process_impl(delta)
	Game.perf_end("npc_ai", t0)


func _physics_process_impl(delta: float) -> void:
	if Game.is_paused or _anim == null:
		return
	# P5: далеко от героя — спим (патруль/бой не тикаем). Стража просыпается
	# позже жителей: город компактный, и 1600 px держало в работе всю стражу.
	if Game.hero != null and is_instance_valid(Game.hero) \
			and state != "dying" and state != "decay" and state != "corpse":
		var sleep_r := 1100.0 if role == "guard" else 1600.0
		if global_position.distance_squared_to(Game.hero.global_position) > sleep_r * sleep_r:
			velocity = Vector2.ZERO
			return
	# Туман войны (19.10): вне видимой клетки житель не тикает и не рисуется.
	if Game.fog != null and Game.fog.blocks_process(global_position):
		visible = false
		return
	visible = true
	_apply_relief_stand()

	# Житель умер (его ударили монстры/герой): падение, разложение, исчезновение
	if state == "dying" or state == "decay" or state == "corpse":
		velocity = velocity.move_toward(Vector2.ZERO, 1800.0 * delta)
		# Первый кадр смерти: снимаем коллизию, иначе труп блокирует героя.
		if state == "dying" and collision_layer != 0:
			collision_layer = 0
			collision_mask = 0
		match state:
			"dying":
				_anim.play(UnitAnim.Anim.DYING)
				if _anim.advance(delta):
					if UnitDB.decay_phases(anim_set) > 0:
						state = "decay"
						_anim.play(UnitAnim.Anim.DECAY)
					else:
						state = "corpse"
						_anim.freeze_last_frame(UnitAnim.Anim.DYING)
						_corpse_timer = 5.0
			"decay":
				if _anim.advance(delta):
					state = "corpse"
					_anim.freeze_last_frame(UnitAnim.Anim.DECAY)
					_corpse_timer = 3.0
			"corpse":
				_corpse_timer -= delta
				if _corpse_timer <= 0.0:
					queue_free()
					return
		move_and_slide()
		return

	# Маги-НПЦ лечат себя и раненых рядом (стража, жители, герой).
	_mage_heal_tick(delta)

	# Стража: Серые рядом — бой (граждане не дерутся)
	if role == "guard" and damage > 0 and _guard_combat(delta):
		return
	# Непатрульная стража стоит у поста: никаких случайных прогулок и A*.
	if not is_patrol:
		velocity = velocity.move_toward(Vector2.ZERO, 1800.0 * delta)
		_anim.play(UnitAnim.Anim.IDLE)
		return

	if _waiting:
		_pause_timer -= delta
		if _pause_timer <= 0.0:
			_waiting = false
			_pick_new_target()
		_anim.play(UnitAnim.Anim.IDLE)
		return

	# Идём к выбранной точке патруля
	var d := global_position.distance_to(_target)
	if d > 4.0:
		if _path.is_empty():
			_repath -= delta
			if _repath <= 0.0:
				_repath = 1.5 + randf() * 1.0
				if _can_pathfind() and alm_map != null and alm_map.has_method("find_path"):
					_path = alm_map.find_path(global_position, _target)
		if not _path.is_empty():
			var wp: Vector2 = _path[0]
			if global_position.distance_to(wp) <= 8.0:
				_path.pop_front()
		if not _path.is_empty():
			_move_checked(Game.safe_dir(global_position, _path[0]), walk_speed, delta)
			if velocity.length() > 10.0:
				_anim.play(_anim.Anim.MOVE)
				_anim.set_direction_vec(velocity)
				_anim.advance(delta)
			else:
				_anim.play(UnitAnim.Anim.IDLE)
			return
		velocity = velocity.move_toward(Vector2.ZERO, 1800.0 * delta)
		_anim.play(UnitAnim.Anim.IDLE)
	else:
		_path.clear()
		velocity = velocity.move_toward(Vector2.ZERO, 1800.0 * delta)
		_waiting = true
		_pause_timer = randf_range(pause_min, pause_max)
		_anim.play(UnitAnim.Anim.IDLE)

## Случайная проходимая точка у поста (патрульный — шире, остальные стоят).
func _can_pathfind() -> bool:
	var f := Engine.get_physics_frames()
	if f != _path_frame:
		_path_frame = f
		_path_calls = 0
	if _path_calls >= 2:
		return false
	_path_calls += 1
	return true


func _pick_new_target() -> void:
	var anchor := post if post != Vector2.ZERO else home
	if alm_map == null:
		_target = anchor
		return
	var rad := 2 if is_patrol else 1   # patrol walks a little around the post, standing guards stay put
	for attempt in range(8):
		var off := Vector2(
			randf_range(-rad, rad),
			randf_range(-rad, rad))
		var p := anchor + off * 32.0
		if p.distance_to(anchor) <= float(rad) * 32.0 + 16.0 \
				and alm_map.has_method("is_walkable_world") \
				and bool(alm_map.call("is_walkable_world", p)):
			_target = p
			return
	_target = anchor

## Стоять на рельефе: поднять спрайт на высоту клетки (как у игрока/врагов).
func _apply_relief_stand() -> void:
	if _anim == null:
		return
	var h := 0.0
	if alm_map != null and alm_map.has_method("relief_at_world"):
		h = float(alm_map.call("relief_at_world", global_position))
	_anim.position = Vector2(_anim.position.x, -h)

# --- Бой стражи с Серыми ---

## Один кадр боя стражи. Возвращает true, если страж занят (дерётся/преследует).
func _guard_combat(delta: float) -> bool:
	var target: Node2D = _nearest_enemy()
	if target == null:
		_impact_timer = -1.0
		return false
	attack_cooldown = maxf(0.0, attack_cooldown - delta)
	var dist := Game.units_range(self, target)
	# Defense leash: the guard never leaves its post further than guard_leash.
	var leash := GameConfig.getf("npc", "guard_leash")
	var anchor := post if post != Vector2.ZERO else home
	if dist > leash or global_position.distance_to(anchor) > leash:
		_impact_timer = -1.0
		return false
	velocity = velocity.move_toward(Vector2.ZERO, 1800.0 * delta)
	if dist > Game.attack_reach(self):
		_chase_move(delta, target)
	else:
		if attack_cooldown <= 0.0 and _impact_timer < 0.0:
			attack_cooldown = GameConfig.getf("combat", "attack_cooldown")
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
		_anim.play(UnitAnim.Anim.ATTACK)
		_anim.speed_scale = 1.0
		_anim.advance(delta)
	move_and_slide()
	return true

## Ближайший Серый в радиусе агро.
##
## ОТСЕЧЕНИЕ (29.10): раньше точный хит-бокс (`Game.units_range`) считался для
## ВСЕГО списка `Game.enemies` (на mid это 150-160 целей) — 9 стражей давали
## ~1400 расчётов в кадр и просадку до 5 FPS в городе. Теперь сначала дешёвое
## сравнение квадратов расстояний по центрам, и точная геометрия — только для
## целей, которые физически могут попасть в радиус (плюс запас на размер тела).
func _nearest_enemy() -> Node2D:
	var t0 := Game.perf_begin()
	var best: Node2D = null
	var bd := aggro_radius
	# 128 px — верхняя граница «полуширины» тел: центр может быть дальше
	# радиуса агро, а тела при этом уже соприкасаются.
	var reach := aggro_radius + 128.0
	var reach_sq := reach * reach
	for e in Game.enemies:
		if e == null or not is_instance_valid(e):
			continue
		var epos: Vector2 = (e as Node2D).global_position
		var dx := epos.x - global_position.x
		var dy := epos.y - global_position.y
		if dx * dx + dy * dy > reach_sq:
			continue
		var d := Game.units_range(self, e)
		if d < bd:
			bd = d
			best = e
	Game.perf_end("npc_target_scan", t0)
	Game.perf_count("npc_target_scan_n")
	return best

## Погоня за Серыми. Перепланировка ~1.2 с + случайный старт (не в одном кадре).
func _chase_move(delta: float, target: Node2D) -> void:
	var tpos: Vector2 = target.global_position
	var dist := global_position.distance_to(tpos)
	if _path.is_empty() or dist > 400.0:
		_repath -= delta
		if _repath <= 0.0:
			_repath = 1.2 + randf() * 0.6
			if alm_map != null and alm_map.has_method("find_path") and dist < 500.0:
				_path = alm_map.find_path(global_position, tpos)
	if _path.size() > 0:
		var wp: Vector2 = _path[0]
		if global_position.distance_to(wp) <= 8.0:
			_path.pop_front()
		if _path.size() > 0:
			wp = _path[0]
			_move_checked(Game.safe_dir(global_position, wp), walk_speed, delta)
			_anim.play(UnitAnim.Anim.MOVE)
			_anim.set_direction_vec(velocity)
			_anim.advance(delta)
		else:
			_move_checked(Game.safe_dir(global_position, tpos), walk_speed, delta)
			_anim.play(UnitAnim.Anim.MOVE)
			_anim.set_direction_vec(velocity)
			_anim.advance(delta)
	else:
		_move_checked(Game.safe_dir(global_position, tpos), walk_speed, delta)
		_anim.play(UnitAnim.Anim.MOVE)
		_anim.set_direction_vec(velocity)
		_anim.advance(delta)

## Звуковой ID юнита по позиции массива Sound (attack/pain1/pain2/death).
func _unit_sound_at(idx: int) -> String:
	return str(SoundDB.sound_at(UnitDB.unit_sound(anim_set), idx))

## --- Статы (для Game.unit_*: атака->точность, защита->уклонение) ---
func get_attack() -> int:
	return int(damage / float(GameConfig.geti("combat", "enemy_attack_dmg_div"))) \
		+ int(max_hp / float(GameConfig.geti("combat", "enemy_attack_hp_div"))) \
		+ StatusEffects.stat_flat(self, "attack")

func get_defense() -> int:
	var base := int(max_hp / float(GameConfig.geti("combat", "enemy_defense_div")))
	return int(round((base + StatusEffects.stat_flat(self, "defense")) * StatusEffects.defense_mult(self)))

func get_absorption() -> int:
	return int(max_hp / float(GameConfig.geti("combat", "enemy_absorption_div")))

func _resist(sphere: String) -> int:
	return UnitDB.resist_of(anim_set, sphere) + StatusEffects.resist_bonus(self, sphere)

func get_protection_fire() -> int:   return _resist("Fire")
func get_protection_water() -> int:  return _resist("Water")
func get_protection_air() -> int:    return _resist("Air")
func get_protection_earth() -> int:  return _resist("Earth")
func get_protection_astral() -> int: return _resist("Astral")

## Получить урон (герой/монстры могут зацепить мирного жителя). При смерти —
## падение DYING → разложение DECAY (если есть) → исчезновение.
func take_damage(dmg: int, _attacker: Node2D) -> int:
	if state == "dying" or state == "decay" or state == "corpse":
		return 0
	# Потревоженный житель просыпается: иначе смерть/разложение стояли бы
	# статичным кадром (физика у жителей выключена ради города).
	if role == "citizen" and not is_physics_processing():
		set_physics_process(true)
	dmg = Game.shield_reduce(self, dmg)
	if dmg <= 0:
		SpellVFX.shield_hit(self)
		return 0
	current_hp -= dmg
	if current_hp > 0:
		SoundDB.play_pain(UnitDB.unit_sound(anim_set))
		return dmg
	current_hp = 0
	SoundDB.play("combat.death")
	_drop_loot()
	state = "dying"
	velocity = Vector2.ZERO
	Game.npcs.erase(self)
	if quest_marker != null and is_instance_valid(quest_marker):
		quest_marker.visible = false
	return dmg


## Лут с NPC. Раньше NPC не роняли ничего: лут был только у врагов, поэтому
## убийство горожанина или стража не давало ничего. Содержимое зависит от роли:
## страж - в латах (steel), горожанин - попроще (bronze).
##
## Размер баночки зелья зависит от силы врага: max_hp у жителей 30, у стражей
## больше, поэтому сильный страж роняет большую баночку. Правило общее с
## enemy.gd:_make_loot, чтобы лут читался одинаково.
func _drop_loot() -> void:
	# Мешок убран (03.10): игрок сразу видит, что именно выпало.
	var drop_script: GDScript = load("res://scripts/loot_drop.gd")
	if drop_script == null:
		return
	var pool: Array = []
	var gold_base := 3 + maxi(1, int(max_hp / 8.0))
	var gold_mult := GameConfig.getf("economy", "loot_gold_multiplier")
	pool.append({"gold": int(round(float(gold_base + randi() % maxi(1, gold_base)) * gold_mult))})
	# жители щедры на зелья, стражей - реже: они вооружены
	var potion_chance := GameConfig.geti("loot", "npc_citizen_potion_chance") if role == "citizen" \
		else GameConfig.geti("loot", "npc_guard_potion_chance")
	if randi() % 100 < potion_chance:
		var potion := "Potion Medium Healing" if randi() % 2 == 0 \
			else "Potion Medium Mana"
		if not ItemDB.find(potion).is_empty():
			pool.append({"key": potion})
	# Снаряжение: страж и горожанин роняют его ВСЕГДА (шанс снят 07.10).
	#
	# С 07.10 NPC роняет СЛОМАННУЮ вещь, а не целую: металл в игре появляется
	# только так (убил НПЦ -> переплавка -> слиток -> рецепт). Целую вещь
	# роняют БОССЫ и драконы - с маленьким шансом, [craft] boss_intact_chance.
	var gear := _random_gear()
	if not gear.is_empty():
		pool.append(gear)
	var drop: LootDrop = drop_script.new()
	drop.items = pool
	drop.potion_size = _potion_size()
	drop.global_position = global_position
	# Родитель, а не get_tree().current_scene: current_scene равен null в
	# headless-скриптах и при добавлении узла из теста, добыча просто не появлялась.
	# Родитель всегда есть и в том, и в другом случае.
	var host := get_parent()
	if host == null:
		host = get_tree().current_scene
	if host != null:
		host.add_child(drop)


## Случайная СЛОМАННАЯ вещь.
##
## Категория зависит от роли: страж носит броню и оружие, горожанин - одежду
## мага. Это не украшение: кузнец перерабатывает броню и оружие в слитки,
## портной - одежду в ткань и эссенцию. Если бы все роняли одно и то же,
## одна из профессий осталась бы без сырья.
##
## Выбор качества (60/25/15) и подбор существующего ключа живут в
## ItemDB.roll_broken_gear — тот же хелпер зовёт Серый (enemy.gd:_broken_gear),
## иначе правила НПЦ и Серых разъехались бы молча.
func _random_gear() -> Dictionary:
	var categories := ["Armor", "Weapon"] if role == "guard" else ["Garment"]
	return ItemDB.roll_broken_gear([_gear_material()], categories)


## Металл сломанной вещи по роли. Страж - сталь, горожанин - бронза (то же,
## что и до 07.10 в _random_gear).
func _gear_material() -> String:
	return "steel" if role == "guard" else "bronze"


func _potion_size() -> String:
	## small/medium/large по силе юнита. Пороги взяты по реальным max_hp:
	## горожане 30, стражь ~60-120, элитные твари выше.
	if max_hp >= 100:
		return "large"
	if max_hp >= 55:
		return "medium"
	return "small"


## Лечение мага-НПЦ: себя и раненых рядом (стража, жители, герой).
##
## У НПЦ нет маны, поэтому ограничение — кулдаун из `game.cfg [magic]`; сила
## лечения — доля максимального HP цели. Врагов не лечит никогда.
## «Маг» определяется по набору: `city_*_mage`, `ork_mage_a52` и т. п.
func _mage_heal_tick(delta: float) -> void:
	if not anim_set.contains("mage"):
		return
	_heal_cd = maxf(0.0, _heal_cd - delta)
	if _heal_cd > 0.0:
		return
	var ratio := GameConfig.getf("magic", "auto_heal_ratio")
	if ratio <= 0.0:
		ratio = 0.45
	var reach := maxf(120.0, SpellDB.range_of("Heal"))
	var best: Node2D = null
	var worst := ratio
	for u in _heal_allies():
		if not is_instance_valid(u) or not u.has_method("heal_amount"):
			continue
		if not ("current_hp" in u) or not ("max_hp" in u):
			continue
		var mx := int(u.get("max_hp"))
		if mx <= 0:
			continue
		var r := float(int(u.get("current_hp"))) / float(mx)
		if r >= worst:
			continue
		if u != self and global_position.distance_to((u as Node2D).global_position) > reach:
			continue
		worst = r
		best = u
	if best == null:
		return
	var pct := GameConfig.getf("magic", "npc_heal_percent")
	if pct <= 0.0:
		pct = 0.12
	var amount := maxi(1, int(round(float(int(best.get("max_hp"))) * pct)))
	best.call("heal_amount", amount)
	SpellAura.heal_cross(best)
	SoundDB.play("magic.heal")
	_heal_cd = maxf(1.0, GameConfig.getf("magic", "npc_heal_cooldown"))


## Кого маг-НПЦ считает своим: себя, героя, стражу, жителей, наёмников героя.
## Враги (`Game.enemies`) сюда не попадают принципиально.
func _heal_allies() -> Array:
	var out: Array = [self]
	if is_instance_valid(Game.hero):
		out.append(Game.hero)
	for n in Game.npcs:
		if is_instance_valid(n) and n != self:
			out.append(n)
	for m in Game.party:
		if is_instance_valid(m):
			out.append(m)
	return out


## Восстановить HP (лечение, вампиризм). Возвращает реально восстановленное.
func heal_amount(amount: int) -> int:
	if amount <= 0 or current_hp >= max_hp:
		return 0
	if state == "dying" or state == "decay" or state == "corpse":
		return 0
	var healed := mini(max_hp, current_hp + amount) - current_hp
	current_hp += healed
	DamageNumber.show_at(global_position, healed, "heal")
	return healed

## Плавное движение с проверкой проходимости (без «льда» и «сквозь стены»).
func _move_checked(direction: Vector2, speed: float, delta: float) -> void:
	direction = Game.movement_direction(self, direction)
	var wanted := direction * speed
	var step := wanted * delta
	var can_step := true
	var can_x := false
	var can_y := false
	if alm_map != null and alm_map.has_method("is_walkable_world"):
		# Разрешаем шаг внутри СВОЕЙ непроходимой клетки (выход из застревания)
		var here := Vector2i(int(int(global_position.x) / 32.0), int(int(global_position.y) / 32.0))
		can_step = alm_map.is_walkable_world(global_position + step) \
			or here == Vector2i(int((global_position.x + step.x) / 32.0),
				int((global_position.y + step.y) / 32.0))
		if can_step:
			velocity = velocity.move_toward(wanted, 1100.0 * delta)
			return
		can_x = alm_map.is_walkable_world(global_position + Vector2(step.x, 0.0)) \
			or here == Vector2i(int((global_position.x + step.x) / 32.0), int(global_position.y / 32.0))
		can_y = alm_map.is_walkable_world(global_position + Vector2(0.0, step.y)) \
			or here == Vector2i(int(global_position.x / 32.0), int((global_position.y + step.y) / 32.0))
		# Скольжение по ближайшей к движению оси. Раньше его не было вовсе:
		# страж, упёршийся в угол, просто останавливался, и патруль мог
		# зависнуть на месте.
		var axis := Game.choose_slide(direction, can_x, can_y)
		if axis != Vector2.ZERO:
			var slide := Vector2(axis.x * step.x, axis.y * step.y)
			velocity = velocity.move_toward(slide / maxf(delta, 0.0001), 1100.0 * delta)
			return
	if can_step:
		velocity = velocity.move_toward(wanted, 1100.0 * delta)
	else:
		velocity = velocity.move_toward(Vector2.ZERO, 1800.0 * delta)