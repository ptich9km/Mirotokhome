class_name CraftTab
extends VBoxContainer

## Базовая вкладка мастерской: слева список, справа действие.
##
## Не абстрактный класс в смысле GD - конкретные вкладки (кузнец, портной,
## мастер) наследуют его и переопределяют `_fill_list()` / `_on_action()`.
## Фокус и прокрутка живут здесь, чтобы третья вкладка не расходилась с
## первыми двумя по поведению.
##
## ФОКУС ВКЛАДОК. UiKit.wire_grid_focus ставит АБСОЛЮТНЫЕ get_path() в
## focus_neighbor_*. Пути действительны, пока вкладка видима: при переключении
## узлы пересоздаются, и старые пути указывают в пустоту. Поэтому
## configure_focus() зовётся хостом НА КАЖДОМ tab_switched, а не один раз.

const LIST_MIN_HEIGHT := 120.0
const LIST_MAX_HEIGHT := 360.0

## Режим элемента списка: переработка сломанного или рецепт.
const RECYCLE_ID := "__recycle__"
const RECIPE_ID := "__recipe__"

var player: Player
var craft: String = ""
var _list_box: VBoxContainer
var _scroll: ScrollContainer
var _detail: VBoxContainer
var _status_label: Label
var _action_button: Button
var _list_buttons: Array[Button] = []
var _selected := -1
## Essence icons of the open detail: they share one animation tick.
var _essence_icons: Array[TextureRect] = []
var _essence_frame := 0
var _essence_t := 0.0

signal request_refresh
signal request_inventory_changed


func setup(p: Player, c: String) -> void:
	player = p
	craft = c


func _ready() -> void:
	_build()
	refresh()
	set_process(true)


## The essence icons in the detail share one slow sway, like the quest coin.
func _process(delta: float) -> void:
	if _essence_icons.is_empty():
		return
	_essence_icons = _essence_icons.filter(
		func(n): return is_instance_valid(n) and n.is_inside_tree())
	if _essence_icons.is_empty():
		return
	var step := EssenceIcons.tick_frame(delta, _essence_t, _essence_frame)
	_essence_t = float(step["t"])
	var next := int(step["frame"])
	if next == _essence_frame:
		return
	_essence_frame = next
	var frames := EssenceIcons.frames()
	if frames.is_empty():
		return
	for icon in _essence_icons:
		icon.texture = frames[_essence_frame % frames.size()]


## Путь к декору вкладки ("" — нет). Крупная цветная картинка справа.
func _decor_path() -> String:
	return ""


func _build() -> void:
	var name_ := "%sSection" % _variation_prefix()
	add_theme_constant_override("separation", UiTheme.SPACE_2)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", UiTheme.SPACE_4)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(body)

	var list_panel := PanelContainer.new()
	list_panel.theme_type_variation = &"%sListPanel" % _variation_prefix()
	list_panel.custom_minimum_size = Vector2(340, 0)
	body.add_child(list_panel)

	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.follow_focus = true
	list_panel.add_child(_scroll)

	_list_box = VBoxContainer.new()
	_list_box.name = "ListBox"
	_list_box.add_theme_constant_override("separation", UiTheme.SPACE_1)
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list_box)

	# Правая зона: деталь (лево) + декор (право), 2 строки по высоте —
	# без отдельной строки под шапкой, которая «расползала» панель.
	var right_row := HBoxContainer.new()
	right_row.name = "RightRow"
	right_row.add_theme_constant_override("separation", UiTheme.SPACE_3)
	right_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(right_row)

	_detail = VBoxContainer.new()
	_detail.name = "Detail"
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.add_theme_constant_override("separation", UiTheme.SPACE_2)
	right_row.add_child(_detail)

	var decor_path := _decor_path()
	if decor_path != "" and ResourceLoader.exists(decor_path):
		var decor := TextureRect.new()
		decor.name = "Decor"
		decor.texture = load(decor_path)
		decor.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		decor.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		decor.size_flags_horizontal = Control.SIZE_SHRINK_END
		decor.size_flags_vertical = Control.SIZE_EXPAND_FILL
		decor.custom_minimum_size = Vector2(180, 0)
		decor.mouse_filter = Control.MOUSE_FILTER_IGNORE
		right_row.add_child(decor)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", UiTheme.SPACE_2)
	add_child(footer)

	_status_label = Label.new()
	_status_label.theme_type_variation = &"%sHint" % _variation_prefix()
	_status_label.text = Loc.t("ui.craft.choose")
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	footer.add_child(_status_label)

	_action_button = Button.new()
	_action_button.name = "Action"
	_action_button.custom_minimum_size = Vector2(190, 40)
	_action_button.focus_mode = Control.FOCUS_ALL
	_action_button.pressed.connect(_on_action)
	footer.add_child(_action_button)

	UiKit.bind_resize(get_window(), _fit_list)


func _fit_list() -> void:
	if _scroll == null or not is_instance_valid(_scroll):
		return
	# Высота от ВКЛАДКИ (не viewport): панель мастерской меньше окна,
	# и привязка к окну выталкивала список за пределы TabContainer (08.10).
	var h := size.y
	if h < 50.0:
		var vp := get_viewport()
		if vp == null:
			return
		h = vp.get_visible_rect().size.y * 0.55
	_scroll.custom_minimum_size = Vector2(
		0.0, clampf(h - 70.0, LIST_MIN_HEIGHT, LIST_MAX_HEIGHT))


# --- Переопределяется наследниками ---------------------------------------

## Заполнить список элементов вкладки. Каждый элемент - Dictionary.
func _items() -> Array:
	return []


## Заголовок кнопки элемента.
func _item_label(entry: Dictionary) -> String:
	return str(entry.get("key", ""))


## Пересобрать правую часть по выбранному элементу.
func _build_detail(_entry: Dictionary) -> void:
	pass


## _action_label / _action_block_reason / _perform / _recycle / _craft заданы
## ниже, в общей секции: они одинаковы для всех вкладок, и объявлять их ещё
## и стабами здесь означало бы две декларации одного имени.


## Текущий элемент ({}, если ничего не выбрано).
func selected_entry() -> Dictionary:
	var items := _items()
	if _selected < 0 or _selected >= items.size():
		return {}
	return items[_selected]


## Навык этого ремесла.
func _skill() -> int:
	if not is_instance_valid(player):
		return 0
	var name := str(CraftDB.SKILL_OF.get(craft, ""))
	return player.skill_value(name) if name != "" else 0


# --- Действие: общее для всех вкладок -------------------------------------

func _action_label(entry: Dictionary) -> String:
	if str(entry.get("mode", "")) == RECYCLE_ID:
		return Loc.t("ui.craft.recycle")
	var recipe: Dictionary = entry.get("recipe", {})
	if recipe.is_empty():
		return ""
	return Loc.t("ui.craft.create")


func _action_block_reason(entry: Dictionary) -> String:
	if str(entry.get("mode", "")) == RECYCLE_ID:
		return ""
	var recipe: Dictionary = entry.get("recipe", {})
	if recipe.is_empty():
		return ""
	for ing in recipe.get("inputs", []):
		if _item_count(str(ing.get("item", ""))) < int(ing.get("count", 0)):
			return Loc.t("ui.craft.no_ingredients")
	return ""


func _perform(entry: Dictionary) -> String:
	if str(entry.get("mode", "")) == RECYCLE_ID:
		return _recycle(entry)
	return _craft(entry.get("recipe", {}))


## Переработка сломанной вещи. Общая для кузнеца (броня/оружие -> слитки +
## ткань) и портного (одежда -> ткань + эссенция): различается только
## таблица выхода в CraftDB.recycle_yield.
func _recycle(entry: Dictionary) -> String:
	if not is_instance_valid(player):
		return Loc.t("ui.craft.no_hero")
	var item: Dictionary = entry["item"]
	var key := str(entry["key"])
	if not player.remove_item(key):
		return Loc.t("ui.craft.nothing_to_salvage")
	var y := CraftDB.recycle_yield(item)
	var given: Array[String] = []
	if int(y.get("ingot", 0)) > 0:
		var ingot_key := ItemDB.ingot_key(str(item.get("material", "")))
		if ingot_key != "":
			for _i in int(y["ingot"]):
				player.add_item(ingot_key)
			given.append("%s ×%d" % [
				ItemDB.display_name(ItemDB.find(ingot_key)), int(y["ingot"])])
	if int(y.get("fabric", 0)) > 0:
		for _i in int(y["fabric"]):
			player.add_item(CraftDB.FABRIC_KEY)
		given.append("%s ×%d" % [ItemDB.display_name(ItemDB.find(CraftDB.FABRIC_KEY)),
			int(y["fabric"])])
	if int(y.get("essence", 0)) > 0:
		for _i in int(y["essence"]):
			player.add_item(CraftDB.ESSENCE_KEY)
		given.append("%s ×%d" % [ItemDB.display_name(ItemDB.find(CraftDB.ESSENCE_KEY)),
			int(y["essence"])])
	player.gain_skill_exp(str(CraftDB.SKILL_OF.get(craft, "")), CraftDB.xp_for_recycle())
	SoundDB.play("ui.craft")
	return Loc.f("ui.craft.salvaged", [", ".join(given)])


## АТОМНОЕ ПОТРЕБЛЕНИЕ. Проверка и списание - в одном проходе, а не
## «сначала проверить, потом снять». Разделение не атомарно: если remove_item
## не сработает на середине, ингредиенты останутся снятыми наполовину - ровно
## тот дефект, что зафиксирован в alchemy_panel.gd:291-309.
func _craft(recipe: Dictionary) -> String:
	if recipe.is_empty():
		return Loc.t("ui.craft.recipe_not_chosen")
	if not is_instance_valid(player):
		return Loc.t("ui.craft.no_hero")
	# 1. How much is needed and how much is there - without consuming.
	var need := {}
	for ing in recipe.get("inputs", []):
		var k := str(ing.get("item", ""))
		need[k] = int(need.get(k, 0)) + int(ing.get("count", 0))
	# 2. Check EVERYTHING at once, before the first removal.
	for k: String in need:
		if _item_count(k) < int(need[k]):
			return Loc.f("ui.craft.missing", [ItemDB.display_name(ItemDB.find(k))])
	var recipe_id := str(recipe.get("id", ""))
	if not CraftDB.has_recipe(player, recipe_id):
		return Loc.t("ui.craft.recipe_not_learned")
	var rare := CraftDB.is_rare_recipe(recipe)
	var scroll_key := CraftDB.recipe_scroll_key(recipe_id)
	if rare and not player.inventory.has(scroll_key):
		return Loc.t("ui.craft.rare_scroll_needed")
	# 3. Consume. A rare scroll is the single-run permit for this craft.
	for k: String in need:
		for _i in int(need[k]):
			player.remove_item(k)
	if rare:
		player.remove_item(scroll_key)
	var tier := CraftDB.roll_tier(_skill())
	var out_key := CraftDB.output_key(recipe, tier)
	var out := ItemDB.find(out_key)
	if out.is_empty():
		# Rollback: a recipe without a result is a database error, not player state.
		for k: String in need:
			for _i in int(need[k]):
				player.add_item(k)
		if rare:
			player.add_item(scroll_key)
		return Loc.t("ui.craft.recipe_no_output")
	player.add_item(out_key)
	player.gain_skill_exp(str(CraftDB.SKILL_OF.get(craft, "")), CraftDB.xp_for_craft(tier))
	SoundDB.play("ui.craft")
	var prefix := Loc.f("ui.craft.crafted", [ItemDB.display_name(out)])
	if tier == CraftDB.TIER_MASTER:
		return prefix + Loc.t("ui.craft.crafted_master")
	if tier == CraftDB.TIER_IMPROVED:
		return prefix + Loc.t("ui.craft.crafted_improved")
	return prefix


# --- Общее ----------------------------------------------------------------

func refresh() -> void:
	if _list_box == null:
		return
	UiKit.clear(_list_box)
	_list_buttons.clear()
	var items := _items()
	if _selected >= items.size():
		_selected = items.size() - 1
	for i in items.size():
		_list_buttons.append(_make_list_button(items[i], i))
	_rebuild_detail()
	_fit_list()


func _make_list_button(entry: Dictionary, index: int) -> Button:
	var b := Button.new()
	b.text = _item_label(entry)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(0, 34)
	b.focus_mode = Control.FOCUS_ALL
	b.theme_type_variation = &"%sListItemActive" % _variation_prefix() \
		if index == _selected else &"%sListItem" % _variation_prefix()
	b.pressed.connect(_select.bind(index))
	_list_box.add_child(b)
	return b


func _select(index: int) -> void:
	_selected = index
	refresh()


func _rebuild_detail() -> void:
	if _detail == null:
		return
	UiKit.clear(_detail)
	var entry := selected_entry()
	if entry.is_empty():
		_detail.add_child(_make_empty_hint())
	else:
		_build_detail(entry)
	var label := _action_label(entry)
	var reason := _action_block_reason(entry)
	_action_button.text = label if label != "" else Loc.t("ui.craft.unavailable")
	_action_button.disabled = label == "" or reason != ""
	if reason != "":
		_status_label.text = reason


func _make_hint(text: String) -> Label:
	var l := Label.new()
	l.theme_type_variation = &"%sHint" % _variation_prefix()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


## Читаемое «ничего не выбрано»: крупный кегль, не муted-микро.
func _make_empty_hint() -> Label:
	var l := Label.new()
	l.theme_type_variation = &"CraftEmpty"
	l.text = Loc.t("ui.craft.nothing_selected")
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return l


func set_status(text: String) -> void:
	_status_label.text = text


func _on_action() -> void:
	var entry := selected_entry()
	if entry.is_empty() or _action_button.disabled:
		return
	_status_label.text = _perform(entry)
	refresh()
	request_inventory_changed.emit()


# --- Инвентарь ------------------------------------------------------------

func _item_count(key: String) -> int:
	if not is_instance_valid(player) or key == "":
		return 0
	var n := 0
	for raw in player.inventory:
		if str(raw) == key:
			n += 1
	return n


## Разобранный инвентарь: [{key, item, count}] по убыванию количества.
func _inventory_items() -> Array:
	var counts := {}
	for raw in player.inventory if is_instance_valid(player) else []:
		var key := str(raw)
		counts[key] = int(counts.get(key, 0)) + 1
	var out: Array = []
	for key: String in counts:
		var item := ItemDB.find(key)
		if item.is_empty():
			continue
		out.append({"key": key, "item": item, "count": int(counts[key])})
	out.sort_custom(func(a, b):
		var qa := UiKit.quality_color(str((a as Dictionary)["item"].get("quality", "")))
		var qb := UiKit.quality_color(str((b as Dictionary)["item"].get("quality", "")))
		if qa.r != qb.r:
			return qa.r < qb.r
		return str(a["key"]) < str(b["key"]))
	return out


# --- Иконки ---------------------------------------------------------------

## Иконка с навешенным свечением уровня крафтовой вещи.
func _make_icon(item: Dictionary, box: Vector2) -> TextureRect:
	var icon := TextureRect.new()
	var path := str(item.get("icon", ""))
	if str(item.get("quality", "")) == "Essence":
		# The essence has an animated art: the detail shows its first frame here,
		# _process sways it like the quest coin.
		var tex := EssenceIcons.texture()
		if tex != null:
			icon.texture = tex
			icon.name = "EssenceIcon"
			_essence_icons.append(icon)
	elif not path.is_empty() and ResourceLoader.exists(path):
		icon.texture = load(path)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = box
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Свечение уровня. Для обычной вещи tier_material возвращает null и
	# material просто не назначается - это нормальный путь, не ошибка.
	CraftVFX.apply_to_icon(icon, CraftVFX.tier_of_item(item))
	return icon


func _set_margins(c: MarginContainer, l: int, t: int, r: int, b: int) -> void:
	UiKit.set_margins(c, l, t, r, b)


func _variation_prefix() -> String:
	match craft:
		CraftDB.TAILOR:
			return "CraftTailor"
		CraftDB.MASTER:
			return "CraftMaster"
		_:
			return "CraftSmith"


# --- Фокус ----------------------------------------------------------------

## Первая кнопка для начального фокуса.
func first_focus_target() -> Control:
	if not _list_buttons.is_empty():
		return _list_buttons[0]
	return _action_button


## Связать фокус ТОЛЬКО внутри этой вкладки.
##
## focus_next/focus_previous - это СВОЙСТВА NodePath, а не ссылки на узлы.
## Присваивать им Button нельзя, нужен .get_path(). Плюс пути валидны, пока
## вкладка видима: узлы списка пересоздаются в refresh(), поэтому хост зовёт
## configure_focus() на каждом tab_switched, а не один раз при открытии.
func configure_focus(close_button: Button = null) -> void:
	if _list_buttons.size() > 1:
		UiKit.wire_grid_focus(_list_buttons, 1)
	if close_button != null and not _list_buttons.is_empty():
		_list_buttons[0].focus_previous = close_button.get_path()
		_list_buttons[_list_buttons.size() - 1].focus_next = _action_button.get_path()
		_action_button.focus_next = close_button.get_path()
		close_button.focus_previous = _action_button.get_path()