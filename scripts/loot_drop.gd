class_name LootDrop
extends Node2D
## Добыча на земле (03.10). Мешок убран — игрок сразу видит, ЧТО выпало:
## броня лежит иконкой брони, оружие — иконкой оружия, зелье — баночкой
## ХП или МАНы, золото — монетой.
##
## Почему так. Замер 03.10: `LootIcons.gold_icon()` возвращал `gold_ingot.png`,
## то есть ЗОЛОТО рисовалось слитком. Но слиток это предмет из item_db, а
## золото — число у игрока в `player.gold`. Игрок брал мешок, видел слиток,
## потом не находил его в инвентаре и справедливо жаловался. Теперь у золота
## своя картинка (tests/gen_gold_coin.py), а предметы показывают себя сами.
##
## Подбор автоматический при подходе (решение игрока).

var items: Array = []   # [{"gold": N}] / [{"key": "item_db key"}, ...]
var _player: Node2D = null
var _pick_radius := 26.0
## Animated ground bottles (06.11): Sprite2D does not play frames by itself,
## so the drop owns one timer for every bottle it spawned.
var _animated: Array[Dictionary] = []
var _anim_t := 0.0
const ANIM_STEP := 0.22

## Размер баночки зелья: задаёт создатель добычи (см. enemy.gd/_make_loot).
## Логика: сильный враг роняет большую баночку, слабый — маленькую.
var potion_size := "small"

const ICON_PX := 18.0       # сторона иконки на земле
const ICON_GAP := 3.0       # зазор между соседними иконками
const GROUND_Y := -4.0      # чуть выше земли, чтобы не тонули в текстуре


func _ready() -> void:
	z_index = 10
	_player = get_tree().get_first_node_in_group("player")
	add_to_group("loot")
	add_to_group("loot_bag")   # старое имя группы: game.gd:_clear_world_units чистит по нему
	_build_ground_sprites()


## Иконки предметов раскладываются в ряд по центру точки смерти с лёгким
## разбросом по вертикали. Раньше они висели сеткой НАД мешком, и на земле
## было видно только общий мешок — что именно выпало, угадать было нельзя.
func _build_ground_sprites() -> void:
	for c in get_children():
		if c is Sprite2D:
			c.queue_free()
	_animated.clear()
	var slots: Array[Dictionary] = []
	for it in items:
		if not (it is Dictionary):
			continue
		var path := ""
		var tier := 0
		var coin := false
		var frames: Array = []
		if it.has("gold"):
			path = LootIcons.gold_icon()
			coin = true
		elif it.has("key"):
			var d := ItemDB.find(str(it.get("key", "")))
			frames = LootIcons.ground_frames_for(d, potion_size)
			if str(d.get("quality", "")) == "Potion":
				path = LootIcons.icon_for_potion(d, potion_size)
			if path == "":
				path = LootIcons.icon_for(d)
			# Уровень крафтовой вещи: подсвеченная вещь должна бросаться в
			# глаза на земле не меньше, чем в складе, иначе игрок не заметит,
			# что именно выпало.
			tier = CraftVFX.tier_of_item(d)
		if path != "" or not frames.is_empty():
			slots.append({"path": path, "tier": tier, "coin": coin, "frames": frames})
	if slots.is_empty():
		return
	_sprite_positions.clear()
	var total := float(slots.size()) * ICON_PX + float(maxi(0, slots.size() - 1)) * ICON_GAP
	var start_x := -total * 0.5 + ICON_PX * 0.5
	for i in slots.size():
		# Лёгкий разброс по вертикали, чтобы добыча не выглядела «линейкой».
		var jitter := GROUND_Y + float((i % 2) * 2 - 1)
		var px := start_x + float(i) * (ICON_PX + ICON_GAP)
		if bool(slots[i].get("coin", false)):
			var coin := make_ground_coin()
			coin.set_layout_position(Vector2(px, jitter))
			coin.z_index = 1
			add_child(coin)
			_sprite_positions.append(Vector2(px, jitter + ICON_PX * 0.5))
			continue
		var s := Sprite2D.new()
		var frames: Array = slots[i].get("frames", [])
		var tex: Texture2D = frames[0] if not frames.is_empty() \
			else load(str(slots[i]["path"]))
		s.texture = tex
		# Иконки в loot_icons 32 px, а часть артов мельче — масштабируем от
		# размера текстумы, иначе баночка была бы вдвое крупнее меча.
		var k := ICON_PX / float(maxi(1, maxi(tex.get_width(), tex.get_height())))
		s.scale = Vector2(k, k)
		s.position = Vector2(px, jitter)
		s.z_index = 1
		add_child(s)
		if frames.size() > 1:
			_animated.append({"sprite": s, "frames": frames, "frame": 0})
		# Свечение уровня. Sprite2D — не Control, но наследует CanvasItem,
		# поэтому material с canvas_item-шейдером работает так же.
		CraftVFX.apply_to_icon(s, int(slots[i].get("tier", 0)))
		_sprite_positions.append(Vector2(px, jitter + ICON_PX * 0.5))


## Позиции иконок — нужны для теней в _draw() (тень должна лежать под спрайтом,
## а не внутри него, иначе она ездит за иконкой вразнобой).
var _sprite_positions: Array[Vector2] = []


## Side of the world-space coin marker: sized like the other loot icons.
const COIN_PX := 24.0


## Gold coin on the ground: the swaying sprite of the quest reward.
func make_ground_coin(px: float = COIN_PX) -> CoinAnim:
	var c := CoinAnim.new()
	c.name = "CoinAnim"
	c.setup(px)
	return c


func _process(delta: float) -> void:
	_tick_anim(delta)
	if not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
		if _player == null:
			return
	if global_position.distance_to(_player.global_position) < _pick_radius:
		_collect()


## One timer for every animated bottle on this drop (they share the pace).
func _tick_anim(delta: float) -> void:
	if _animated.is_empty():
		return
	_anim_t += delta
	if _anim_t < ANIM_STEP:
		return
	_anim_t -= ANIM_STEP
	for i in range(_animated.size() - 1, -1, -1):
		var a: Dictionary = _animated[i]
		var sprite: Sprite2D = a.get("sprite", null)
		if not is_instance_valid(sprite):
			_animated.remove_at(i)
			continue
		var frames: Array = a.get("frames", [])
		if frames.size() < 2:
			continue
		var frame := (int(a.get("frame", 0)) + 1) % frames.size()
		a["frame"] = frame
		sprite.texture = frames[frame]


func _collect() -> void:
	## Подбор: золото в казну, предметы в склад. После — обязательно
	## refresh_inventory(), иначе склад на экране остаётся старым, пока игрок
	## не откроет его заново (раньше здесь не вызывалось ничего).
	var got_gold := 0
	var got_items: Array[String] = []
	for it in items:
		if it is Dictionary:
			if it.has("gold"):
				var g := int(it.get("gold", 0))
				if g > 0:
					if _player.has_method("add_gold"):
						_player.call("add_gold", g)
					got_gold += g
			elif it.has("key"):
				var key := str(it.get("key", ""))
				if key != "" and _player.has_method("add_item"):
					_player.call("add_item", key)
					got_items.append(key)
	if got_gold > 0:
		print("+%d золота" % got_gold)
	for k in got_items:
		print("+%s" % k)
	if got_gold > 0 or not got_items.is_empty():
		SoundDB.play("ui.click")  # click00
		_notify_ui()
	queue_free()


## Попросить HUD обновить склад. Узел UI НЕ состоит в группе "ui" (в main.tscn
## нет строки groups), поэтому сначала пробуем группу, потом ищем CanvasLayer с
## методом refresh_inventory — тот же приём, что в game.gd.
func _notify_ui() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var target: Node = tree.get_first_node_in_group("ui")
	if target == null or not target.has_method("refresh_inventory"):
		target = _find_ui(tree.root)
	if target != null and target.has_method("refresh_inventory"):
		target.call("refresh_inventory")


func _find_ui(from: Node) -> Node:
	if from == null:
		return null
	if from is CanvasLayer and from.has_method("refresh_inventory"):
		return from
	for c in from.get_children():
		var got := _find_ui(c)
		if got != null:
			return got
	return null


func _draw() -> void:
	# Мягкая тень под каждым предметом: без неё иконки «висят» над землёй.
	for p in _sprite_positions:
		draw_set_transform(Vector2(p.x, p.y), 0.0, Vector2(1.0, 0.42))
		draw_circle(Vector2.ZERO, 5.0, Color(0.0, 0.0, 0.0, 0.22))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)