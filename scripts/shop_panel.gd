class_name ShopPanel
extends CanvasLayer

signal closed
signal inventory_changed

## Категории — toggle-кнопки в шапке. Снаряжение в лавке НЕТ (08.10):
## снаряжение = лут + крафт по свиткам; лавка продаёт зелья, книги и рецепты.
## Рецепты разбиты по виду, иначе в общей куче неудобно искать (08.10).
const CATEGORIES := [
	{"id": "recipes_armor", "label": "Рец. Броня"},
	{"id": "recipes_weapon", "label": "Рец. Оружие"},
	{"id": "recipes_clothes", "label": "Рец. Маг. одежда"},
	{"id": "potions", "label": "Зелья"},
	{"id": "materials", "label": "Материалы"},
	{"id": "books", "label": "Книги и свитки"},
	{"id": "recipes_faction", "label": "Рец. Фракция"},
]
const MERCHANT_LINES := [
	"Снаряжение дорожает с каждой новой стражей у ворот.",
	"Зелья всегда пригодятся: герои тоже умеют получать раны.",
	"Магические книги есть только у тех, кто действительно читает магию.",
	"Не торопись: хорошая броня окупается после второй вылазки.",
]
const _CELL_BUY := Vector2(100, 104)
const _CELL_SELL := Vector2(94, 96)

var player: Player
var _root: MarginContainer
var _panel: PanelContainer
var _npc_scroll: ScrollContainer
var _player_scroll: ScrollContainer
var _npc_grid: GridContainer
var _player_grid: GridContainer
var _player_tabs: GridContainer
var _gold_label: Label
var _rep_label: Label
var _npc_notice: Label
var _race := ""            # раса города: ось репутации ("" — карта без города)
var _rep := 0              # репутация героя у этой расы на момент открытия
var _hint_label: Label
var _merchant_label: Label
var _merchant_button: Button
var _close_button: Button
var _category_buttons: Array[Button] = []
var _category_group: ButtonGroup
var _previous_focus: Control
var _hover_card: PanelContainer = null
var _category_index := 3   # открываемся на зельях: вкладки рецептов без репутации пусты (28.10)
var _focus_restored := false

const _PANEL_MIN := Vector2(980, 580)

static var _all_cache: Array = []

func setup(p: Player, city_race: String = "") -> void:
	player = p
	_race = city_race
	_rep = Game.hero_reputation(_race)
	layer = 10
	if _all_cache.is_empty():
		_all_cache = ItemDB.all()
	_build_ui()

func _ready() -> void:
	_previous_focus = UiKit.save_focus(self)
	_configure_category_focus()
	_refresh()

func _exit_tree() -> void:
	pass

func _build_ui() -> void:
	var dim := UiKit.make_dim(0.58)
	add_child(dim)

	_root = MarginContainer.new()
	_root.name = "ShopRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.set_margins(_root, UiTheme.SCREEN_INSET, UiTheme.SCREEN_INSET,
		UiTheme.SCREEN_INSET, UiTheme.SCREEN_INSET)
	_root.theme = _make_theme()
	add_child(_root)

	# Центр + фиксированный размер — как у инвентаря: панель всегда по центру
	# и не «прыгает» при resize (08.10).
	var center := CenterContainer.new()
	center.name = "Center"
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.theme_type_variation = &"ShopPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_panel.custom_minimum_size = _PANEL_MIN
	center.add_child(_panel)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	UiKit.set_margins(margin, UiTheme.SPACE_4, UiTheme.SPACE_3,
		UiTheme.SPACE_4, UiTheme.SPACE_3)
	_panel.add_child(margin)

	var content := VBoxContainer.new()
	content.name = "Content"
	content.add_theme_constant_override("separation", UiTheme.SPACE_2)
	margin.add_child(content)

	# Header: title + gold + close
	var header := HBoxContainer.new()
	header.name = "Header"
	header.add_theme_constant_override("separation", UiTheme.SPACE_3)
	content.add_child(header)
	var title := Label.new()
	title.name = "Title"
	title.theme_type_variation = &"ShopTitle"
	title.text = tr("МАГАЗИН")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_gold_label = Label.new()
	_gold_label.name = "Gold"
	_gold_label.theme_type_variation = &"ShopGoldLabel"
	_gold_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_gold_label)
	_rep_label = Label.new()
	_rep_label.name = "Reputation"
	_rep_label.theme_type_variation = &"ShopGoldLabel"
	_rep_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_rep_label)
	_close_button = Button.new()
	_close_button.name = "Close"
	_close_button.text = tr("Закрыть")
	_close_button.theme_type_variation = &"ShopClose"
	_close_button.custom_minimum_size = Vector2(120, 32)
	_close_button.pressed.connect(close)
	header.add_child(_close_button)

	# Categories as tabs
	var cat_row := HBoxContainer.new()
	cat_row.name = "Categories"
	cat_row.add_theme_constant_override("separation", UiTheme.SPACE_2)
	content.add_child(cat_row)
	_build_category_buttons(cat_row)

	# Shelves: merchant | player
	var body := HBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", UiTheme.SPACE_3)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(body)

	var buy_col := VBoxContainer.new()
	buy_col.name = "BuyCol"
	buy_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buy_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(buy_col)
	var buy_title := Label.new()
	buy_title.theme_type_variation = &"ShopSection"
	buy_title.text = tr("У торговца")
	buy_col.add_child(buy_title)
	_npc_notice = Label.new()
	_npc_notice.name = "ReputationNotice"
	_npc_notice.theme_type_variation = &"ShopEmptyTabLabel"
	_npc_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_npc_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_npc_notice.visible = false
	buy_col.add_child(_npc_notice)
	_npc_scroll = ScrollContainer.new()
	_npc_scroll.name = "NpcShelfScroll"
	_npc_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_npc_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_npc_scroll.follow_focus = true
	_npc_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_npc_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buy_col.add_child(_npc_scroll)
	_npc_grid = GridContainer.new()
	_npc_grid.name = "NpcShelf"
	_npc_grid.columns = 4
	_npc_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_npc_grid.add_theme_constant_override("h_separation", UiTheme.SPACE_1)
	_npc_grid.add_theme_constant_override("v_separation", UiTheme.SPACE_1)
	_npc_scroll.add_child(_npc_grid)

	var sell_col := VBoxContainer.new()
	sell_col.name = "SellCol"
	sell_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sell_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(sell_col)
	var sell_title := Label.new()
	sell_title.theme_type_variation = &"ShopSection"
	sell_title.text = tr("Ваш склад")
	sell_col.add_child(sell_title)
	_player_scroll = ScrollContainer.new()
	_player_scroll.name = "PlayerShelfScroll"
	_player_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_player_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_player_scroll.follow_focus = true
	_player_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_player_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sell_col.add_child(_player_scroll)
	_player_grid = GridContainer.new()
	_player_grid.name = "PlayerShelf"
	_player_grid.columns = 5
	_player_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_player_grid.add_theme_constant_override("h_separation", UiTheme.SPACE_1)
	_player_grid.add_theme_constant_override("v_separation", UiTheme.SPACE_1)
	_player_scroll.add_child(_player_grid)

	# Merchant strip
	var merchant := PanelContainer.new()
	merchant.name = "MerchantPanel"
	merchant.theme_type_variation = &"ShopDialogPanel"
	content.add_child(merchant)
	var mmargin := MarginContainer.new()
	UiKit.set_margins(mmargin, UiTheme.SPACE_3, UiTheme.SPACE_2,
		UiTheme.SPACE_3, UiTheme.SPACE_2)
	merchant.add_child(mmargin)
	var mrow := HBoxContainer.new()
	mrow.add_theme_constant_override("separation", UiTheme.SPACE_3)
	mmargin.add_child(mrow)
	_merchant_label = Label.new()
	_merchant_label.name = "MerchantText"
	_merchant_label.text = tr("Торговец предлагает снаряжение и зелья.")
	_merchant_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_merchant_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_merchant_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mrow.add_child(_merchant_label)
	_merchant_button = Button.new()
	_merchant_button.name = "Talk"
	_merchant_button.text = tr("Поговорить")
	_merchant_button.theme_type_variation = &"ShopPrimary"
	_merchant_button.custom_minimum_size = Vector2(140, 32)
	_merchant_button.pressed.connect(_talk)
	mrow.add_child(_merchant_button)

	_hint_label = Label.new()
	_hint_label.name = "TradeHint"
	_hint_label.theme_type_variation = &"ShopHintLabel"
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_hint_label)

	_build_hover_card()

func _build_category_buttons(parent: Node) -> void:
	_category_group = ButtonGroup.new()
	for index in range(CATEGORIES.size()):
		var category: Dictionary = CATEGORIES[index]
		var button := Button.new()
		button.name = "Category%d" % index
		button.text = str(category["label"])
		button.tooltip_text = str(category["label"])
		button.theme_type_variation = &"ShopCategoryButton"
		button.toggle_mode = true
		button.button_group = _category_group
		button.button_pressed = index == _category_index
		button.focus_mode = Control.FOCUS_ALL
		button.pressed.connect(_set_category.bind(index))
		parent.add_child(button)
		_category_buttons.append(button)

func _configure_category_focus() -> void:
	for index in range(_category_buttons.size()):
		var button := _category_buttons[index]
		button.focus_previous = _category_buttons[maxi(index - 1, 0)].get_path()
		button.focus_next = _category_buttons[mini(index + 1, _category_buttons.size() - 1)].get_path()

func _build_hover_card() -> void:
	_hover_card = UiKit.make_hover_card(300.0)
	_panel.add_child(_hover_card)

## Показать описание товара у курсора. Работает и по наведению мышью, и по
## фокусу с клавиатуры/геймпада.
func _attach_hover(slot: Control, item: Dictionary, buying: bool, count: int) -> void:
	if _hover_card == null or item.is_empty():
		return
	var show_at := func() -> void:
		if not is_instance_valid(slot) or not is_instance_valid(_panel):
			return
		# Карточка — дочерний узел _panel; координаты нужны локальные, не глобальные.
		var local: Vector2 = _panel.get_global_transform().affine_inverse() * slot.global_position
		UiKit.show_hover_card(_hover_card, _hover_lines(item, buying, count),
			local, _panel.size)
	slot.mouse_entered.connect(show_at)
	slot.mouse_exited.connect(func() -> void: UiKit.hide_hover_card(_hover_card))
	var focus_target: Control = slot
	var btn := _find_trade_button(slot)
	if btn != null:
		focus_target = btn
	focus_target.focus_entered.connect(show_at)
	focus_target.focus_exited.connect(func() -> void: UiKit.hide_hover_card(_hover_card))

func _find_trade_button(node: Node) -> Button:
	for child in node.get_children():
		if child is Button:
			return child as Button
		var found := _find_trade_button(child)
		if found != null:
			return found
	return null

func _hover_lines(item: Dictionary, buying: bool, count: int) -> Array:
	var key := str(item.get("key", ""))
	var lines: Array = [str(item.get("name_ru", key))]
	var sub: Array[String] = []
	var type := str(item.get("type", ""))
	if type != "":
		sub.append(type)
	var material := str(item.get("material", ""))
	if material != "" and material != "None":
		sub.append(material)
	var quality := str(item.get("quality", ""))
	if quality != "" and quality != "Common":
		sub.append(quality)
	if not sub.is_empty():
		lines.append(" · ".join(sub))
	var stats := _item_stats(item)
	if stats != "":
		lines.append(stats)
	var level := int(item.get("level", 0))
	if level > 0:
		lines.append(tr("Нужен уровень: %d") % level)
	lines.append(tr("Вес: %.1f") % float(item.get("weight", 0.0)))
	if not buying and count > 1:
		lines.append(tr("В складе: %d шт.") % count)
	var price := int(item.get("price", 0))
	if buying:
		lines.append(tr("Цена: %d з") % _buy_price(price))
	else:
		lines.append(tr("Продать за: %d з") % _sell_price(price))
	return lines

func _sell_price(price: int) -> int:
	return maxi(1, int(price / float(maxi(1, GameConfig.geti("economy", "sell_price_div")))))


## Скидка по репутации: 0 / 5 / 10 / 15 % на порогах [reputation].
func _discount_percent() -> int:
	var d := 0
	if _rep >= GameConfig.geti("reputation", "tier_1"):
		d = GameConfig.geti("reputation", "discount_1")
	if _rep >= GameConfig.geti("reputation", "tier_2"):
		d = GameConfig.geti("reputation", "discount_2")
	if _rep >= GameConfig.geti("reputation", "tier_3"):
		d = GameConfig.geti("reputation", "discount_3")
	return clampi(d, 0, 90)


## Цена покупки с учётом репутации. Считается в ОДНОМ месте: витрина, подсказка,
## блокировка кнопки и списание золота обязаны показывать одно число.
func _buy_price(base: int) -> int:
	if base <= 0:
		return base
	return maxi(1, int(round(float(base) * (100.0 - float(_discount_percent())) / 100.0)))

func _update_layout() -> void:
	pass


## Подсказка под вкладками: ассортимент и цена зависят от отношения фракции
## города. Игрок должен видеть это ДО того, как решит, что товар пропал.
func _trade_hint() -> String:
	var base := tr("Слева покупка, справа продажа.")
	if _race == "":
		return tr("%s Ассортимент зависит от отношения фракции.") % base
	return tr("%s Отношение фракции «%s»: %d, скидка %d%%.") \
		% [base, Lore.faction_label(_race), _rep, _discount_percent()]


## Плашка над полкой, когда часть товаров закрыта репутацией: эльфийские
## свитки (порог `elven_rep`). Пустая полка без объяснения читается как
## «товары пропали» (жалоба игрока 28.10).
func _update_rep_notice(category: String) -> void:
	if _npc_notice == null:
		return
	var elven := GameConfig.geti("reputation", "elven_rep")
	if category == "recipes_faction":
		# Пакет F: полка фракционных чертежей. Она не «пустая без причины»:
		# чертежи можно добыть захватом форпоста, а тут — второй источник.
		if _race == "":
			_npc_notice.text = tr("Фракционные чертежи: на этой карте нет города.")
		else:
			_npc_notice.text = tr("Чертежи наборов фракции «%s»: добываются за захват форпоста или покупаются здесь.") \
				% Lore.faction_label(_race)
		_npc_notice.visible = true
		return
	if category == "books" and _rep < elven:
		_npc_notice.text = tr("Эльфийские свитки: нужна репутация %d (сейчас %d).") \
			% [elven, _rep]
		_npc_notice.visible = true
	else:
		_npc_notice.visible = false

func _refresh() -> void:
	if not is_instance_valid(player):
		return
	if _hover_card != null:
		UiKit.hide_hover_card(_hover_card)
	_gold_label.text = tr("Золото: %d") % player.gold
	if _rep_label != null:
		var discount := _discount_percent()
		if _race == "":
			_rep_label.text = tr("Репутация: нет города")
		elif discount > 0:
			_rep_label.text = tr("Репутация: %s %d · скидка %d%%") \
				% [Lore.faction_label(_race), _rep, discount]
		else:
			_rep_label.text = tr("Репутация: %s %d") \
				% [Lore.faction_label(_race), _rep]
	_hint_label.text = _trade_hint()
	for index in range(_category_buttons.size()):
		_category_buttons[index].button_pressed = index == _category_index
	# Позиции скролла и фокус: полная пересборка сеток сбрасывала их на каждой
	# покупке — отсюда «прыжки» при покупке многих вещей (08.10).
	var scroll_npc := 0
	var scroll_pl := 0
	if _npc_scroll != null and is_instance_valid(_npc_scroll):
		scroll_npc = _npc_scroll.scroll_vertical
	if _player_scroll != null and is_instance_valid(_player_scroll):
		scroll_pl = _player_scroll.scroll_vertical
	var focused_was_player := _is_focused_in(_player_scroll)
	var focused_was_npc := _is_focused_in(_npc_scroll)
	var npc_buttons := _build_buy_shelf(_category_index)
	var player_buttons := _build_sell_list()
	_configure_focus(npc_buttons, player_buttons)
	if _npc_scroll != null and is_instance_valid(_npc_scroll):
		_npc_scroll.scroll_vertical = scroll_npc
	if _player_scroll != null and is_instance_valid(_player_scroll):
		_player_scroll.scroll_vertical = scroll_pl
	# Фокус: не воровать у игрока, если он был на своей полке.
	if focused_was_player and not player_buttons.is_empty():
		player_buttons[0].call_deferred("grab_focus")
	elif focused_was_npc and not npc_buttons.is_empty():
		npc_buttons[0].call_deferred("grab_focus")
	elif not _focus_restored:
		if not npc_buttons.is_empty():
			npc_buttons[0].call_deferred("grab_focus")
		elif not player_buttons.is_empty():
			player_buttons[0].call_deferred("grab_focus")
		else:
			_category_buttons[_category_index].call_deferred("grab_focus")
		_focus_restored = true


func _is_focused_in(scroll: ScrollContainer) -> bool:
	if scroll == null or not is_instance_valid(scroll):
		return false
	var f := get_viewport().gui_get_focus_owner()
	if f == null:
		return false
	var n: Node = f
	while n != null:
		if n == scroll:
			return true
		n = n.get_parent()
	return false


func _set_category(index: int) -> void:
	_category_index = clampi(index, 0, CATEGORIES.size() - 1)
	_focus_restored = false
	_refresh()

func _build_buy_shelf(category_index: int) -> Array[Button]:
	_clear_grid(_npc_grid)
	var pool := _category_items(category_index)
	_update_rep_notice(str(CATEGORIES[category_index]["id"]))
	pool.sort_custom(func(a: Dictionary, b: Dictionary):
		return _buy_price(int(a.get("price", 0))) < _buy_price(int(b.get("price", 0))))
	var buttons: Array[Button] = []
	for item in pool:
		var slot := _make_shop_slot(item, true, 1)
		_npc_grid.add_child(slot)
		var button := slot.find_child("Trade", true, false) as Button
		if button != null:
			button.disabled = player.gold < _buy_price(int(item.get("price", 0)))
			if not button.disabled:
				buttons.append(button)
	return buttons

func _build_sell_list() -> Array[Button]:
	_clear_grid(_player_grid)
	var entries: Array[Dictionary] = []
	if is_instance_valid(player):
		var seen: Dictionary = {}
		for key in player.inventory:
			var item := ItemDB.find(str(key))
			if item.is_empty():
				continue
			var item_key := str(key)
			seen[item_key] = int(seen.get(item_key, 0)) + 1
		for item_key in seen:
			entries.append({
				"item": ItemDB.find(item_key),
				"count": int(seen[item_key]),
				"price": maxi(1, int(int(ItemDB.find(item_key).get("price", 0)) / 2.0)),
			})
	entries.sort_custom(func(a: Dictionary, b: Dictionary): return int(a["price"]) < int(b["price"]))
	var buttons: Array[Button] = []
	for entry in entries:
		var item: Dictionary = entry.get("item", {})
		var slot := _make_shop_slot(item, false, int(entry.get("count", 1)))
		_player_grid.add_child(slot)
		var button := slot.find_child("Trade", true, false) as Button
		if button != null:
			buttons.append(button)
	return buttons

func _make_shop_slot(item: Dictionary, buying: bool, count: int) -> PanelContainer:
	var slot := PanelContainer.new()
	slot.theme_type_variation = &"ShopItemSlot"
	slot.custom_minimum_size = _CELL_BUY if buying else _CELL_SELL
	var margin := MarginContainer.new()
	_set_margins(margin, UiTheme.SPACE_1, UiTheme.SPACE_1, UiTheme.SPACE_1, UiTheme.SPACE_1)
	slot.add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 1)
	margin.add_child(content)
	if item.is_empty():
		return slot
	var key := str(item.get("key", ""))
	var name := str(item.get("name_ru", key))
	var base_price := int(item.get("price", 0))
	var price := _buy_price(base_price) if buying else base_price
	var icon := TextureRect.new()
	var icon_path := str(item.get("icon", ""))
	if not icon_path.is_empty() and ResourceLoader.exists(icon_path):
		icon.texture = load(icon_path)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(0, 48)
	icon.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	icon.size_flags_vertical = Control.SIZE_EXPAND_FILL
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Свечение уровня крафтовой вещи. Полки магазина перестраиваются на каждый
	# refresh, узлы не пулятся, так что материал каждый раз новый - но и
	# Shader кэшируется в CraftVFX, поэтому компиляция не повторяется.
	CraftVFX.apply_to_icon(icon, CraftVFX.tier_of_item(item))
	CraftVFX.apply_elven(icon, item)
	content.add_child(icon)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 1)
	content.add_child(actions)
	if not buying and count > 1:
		var count_label := Label.new()
		count_label.theme_type_variation = &"ShopCountLabel"
		count_label.text = "×%d" % count
		count_label.custom_minimum_size = Vector2(20, 22)
		count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		actions.add_child(count_label)
	var button := Button.new()
	button.name = "Trade"
	button.text = tr("Купить %d") % price if buying else tr("%d з") % _sell_price(price)
	button.tooltip_text = "%s — %s" % [name, tr("продать за %d з") % _sell_price(price) if not buying else tr("купить за %d з") % price]
	button.custom_minimum_size = Vector2(0, 22)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.focus_mode = Control.FOCUS_ALL
	button.pressed.connect(_buy_item.bind(key, price) if buying else _sell_item.bind(key, _sell_price(price)))
	actions.add_child(button)
	_attach_hover(slot, item, buying, count)
	return slot

func _item_stats(item: Dictionary) -> String:
	var parts: Array[String] = []
	var dmin := int(item.get("damage_min", 0))
	var dmax := int(item.get("damage_max", 0))
	if dmax > 0 or dmin > 0:
		parts.append("Урон %d-%d" % [dmin, dmax] if dmin != dmax else "Урон %d" % dmax)
	var to_hit := int(item.get("to_hit", 0))
	if to_hit != 0:
		parts.append("Точн. %+d" % to_hit)
	var defence := int(item.get("defence", 0))
	if defence != 0:
		parts.append("Броня %d" % defence)
	var absorption := int(item.get("absorption", 0))
	if absorption != 0:
		parts.append("Погл. %d" % absorption)
	var magcap := int(item.get("magcap", 0))
	if magcap != 0:
		parts.append("Мана %d" % magcap)
	var level := int(item.get("level", 0))
	if level > 0:
		parts.append("ур. %d" % level)
	return " · ".join(parts)

func _category_items(category_index: int) -> Array[Dictionary]:
	var category := str(CATEGORIES[category_index]["id"])
	var elven_rep := GameConfig.geti("reputation", "elven_rep")
	var pool: Array[Dictionary] = []
	for raw in _all_cache:
		var item: Dictionary = raw
		var quality := str(item.get("quality", ""))
		var price := int(item.get("price", 0))
		# Репутация — пропуск к эльфийским свиткам (28.10). Чертежи мастерской
		# продаются всем: без них рушится цикл крафта, а вкладки пустеют
		# (жалоба игрока: «в магазине не осталось товаров»).
		if quality == "SuperScroll" and _rep < elven_rep:
			continue
		# Фильтр цены: пропускаем сломанное (0) и мусор. Зелья/книги/эликсиры
		# с ценой 1M и книги price=0 проходят отдельно ниже.
		if quality == "Recipe" and not category.begins_with("recipes"):
			continue
		var matches := false
		match category:
			"potions":
				# Все зелья, включая эликсиры атрибутов за 1M.
				matches = quality == "Potion" and price > 0
			"materials":
				# The common forge catalyst. Boss Core is drop-only.
				matches = str(item.get("key", "")) == CraftDB.ESSENCE_KEY
			"books":
				# Scrolls from the base. Books of a SINGLE spell are added below
				# via make_book_item. Since 2026-10-30 SCHOOL books are sold too
				# (quality "Book"): the five vanilla ones cost 0 (they are given
				# at start), while a mod can sell its own — and that opens the
				# whole new magic school.
				matches = quality in ["Scroll", "SuperScroll", "Book"]
			"recipes_armor":
				matches = quality == "Recipe" and str(item.get("bp", "")) == "armor"
			"recipes_weapon":
				matches = quality == "Recipe" and str(item.get("bp", "")) == "weapon"
			"recipes_clothes":
				matches = quality == "Recipe" and str(item.get("bp", "")) == "clothes"
			"recipes_faction":
				# Пакет F: чертежи фракционных наборов. В лавке города — только
				# наборы ЕГО фракции (8 слотов: тяжёлый + лёгкий комплект).
				# Карта без города — полка пуста, о чём говорит плашка.
				matches = quality == "Recipe" and str(item.get("bp", "")) == "faction"
				if matches and _race != "":
					matches = str(item.get("recipe_id", "")).begins_with("faction_%s_" % _race)
				elif matches:
					matches = false
		if not matches:
			continue
		# Для не-зелья/книг/свитков: сломанное (price 0) и мусор >60k.
		var materials_ok := category == "materials" \
			and str(item.get("key", "")) == CraftDB.ESSENCE_KEY
		if quality not in ["Potion", "Scroll", "SuperScroll"] \
				and (price <= 0 or price > 60000) and not materials_ok:
			continue
		var shop_item := item
		if materials_ok:
			shop_item = item.duplicate(true)
			shop_item["price"] = 60
		if quality in ["Scroll", "SuperScroll"] and price <= 0:
			continue
		pool.append(shop_item)
	# Книги заклинаний для мага — всегда в «Книги и свитки» (не только магу:
	# свитки уже продаются, книги — продолжение той же петли).
	if category == "books":
		for spell in SpellDB.catalog_spells():
			var book := SpellDB.make_book_item(spell)
			if not book.is_empty():
				pool.append(book)
	return pool

func _configure_focus(npc_buttons: Array[Button], player_buttons: Array[Button]) -> void:
	UiKit.wire_grid_focus(npc_buttons, _npc_grid.columns)
	UiKit.wire_grid_focus(player_buttons, _player_grid.columns)
	var first_target: Control = _category_buttons[_category_index]
	if not npc_buttons.is_empty():
		first_target = npc_buttons[0]
	elif not player_buttons.is_empty():
		first_target = player_buttons[0]
	_category_buttons[_category_index].focus_next = first_target.get_path()
	first_target.focus_previous = _category_buttons[_category_index].get_path()
	if not npc_buttons.is_empty() and not player_buttons.is_empty():
		npc_buttons[-1].focus_next = player_buttons[0].get_path()
		player_buttons[0].focus_previous = npc_buttons[-1].get_path()
	var last_action: Control = npc_buttons[-1] if not npc_buttons.is_empty() else (player_buttons[-1] if not player_buttons.is_empty() else first_target)
	last_action.focus_next = _merchant_button.get_path()
	_merchant_button.focus_previous = last_action.get_path()
	_merchant_button.focus_next = _close_button.get_path()
	_close_button.focus_previous = _merchant_button.get_path()
	_close_button.focus_next = _category_buttons[0].get_path()

func _hero_portrait() -> Texture2D:
	var path := Game.hero_portrait_path()
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	if is_instance_valid(player):
		var preview := UnitDB.preview_frame(player.anim_set_name())
		if preview != null:
			return preview
	return null

func _set_margins(container: MarginContainer, left: int, top: int, right: int, bottom: int) -> void:
	UiKit.set_margins(container, left, top, right, bottom)

func _make_theme() -> Theme:
	var theme := UiTheme.app_theme()
	theme.set_stylebox("normal", "Button", UiKit.button_style(
		UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE,
		UiTheme.BORDER_NORMAL, UiTheme.RADIUS_PANEL, UiTheme.SPACE_2))
	theme.set_stylebox("hover", "Button", UiKit.button_style(
		UiTheme.PANEL_INNER.lightened(0.12), UiTheme.ACCENT_DIM,
		UiTheme.BORDER_NORMAL, UiTheme.RADIUS_PANEL, UiTheme.SPACE_2))
	theme.set_stylebox("pressed", "Button", UiKit.button_style(
		UiTheme.BG_DEEP, UiTheme.PANEL_EDGE,
		UiTheme.BORDER_NORMAL, UiTheme.RADIUS_PANEL, UiTheme.SPACE_2))
	theme.set_stylebox("focus", "Button", UiKit.button_style(
		UiTheme.TRANSPARENT, UiTheme.ACCENT,
		UiTheme.BORDER_FOCUS, UiTheme.RADIUS_PANEL, UiTheme.SPACE_2))
	UiKit.apply_scrollbar(theme, UiTheme.RADIUS_SLOT, UiTheme.SPACE_1)
	UiKit.add_panel(theme, &"ShopPanel",
		UiTheme.PANEL_BG, UiTheme.PANEL_EDGE, UiTheme.RADIUS_FRAME)
	UiTheme.add_display_label(theme, &"ShopTitle", UiTheme.FONT_TITLE, UiTheme.ACCENT)
	UiKit.add_label(theme, &"ShopGoldLabel", UiTheme.ACCENT, UiTheme.FONT_SUBHEAD)
	UiKit.add_label(theme, &"ShopHintLabel", UiTheme.TEXT_MUTED, UiTheme.FONT_MICRO)
	UiKit.add_label(theme, &"ShopSection", UiTheme.TEXT_MUTED, UiTheme.FONT_SECTION)
	UiKit.add_slot(theme, &"ShopItemSlot")
	UiKit.add_panel(theme, &"ShopPlayerTab",
		UiTheme.SLOT_BG, UiTheme.SLOT_EDGE, UiTheme.RADIUS_SLOT)
	UiKit.add_panel(theme, &"ShopDialogPanel",
		UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE, UiTheme.RADIUS_PANEL)
	UiKit.add_hover_card_styles(theme)
	UiKit.add_label(theme, &"ShopEmptyTabLabel", UiTheme.TEXT_OFF, UiTheme.FONT_BODY)
	UiKit.add_label(theme, &"ShopCountLabel", UiTheme.ACCENT, UiTheme.FONT_MICRO)
	UiKit.add_button(theme, &"ShopCategoryButton",
		UiTheme.TRANSPARENT, UiTheme.TRANSPARENT,
		UiTheme.PANEL_INNER, UiTheme.ACCENT_DIM,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_1)
	UiKit.add_button(theme, &"ShopPrimary",
		UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE,
		UiTheme.PANEL_INNER.lightened(0.14), UiTheme.ACCENT_DIM,
		UiTheme.RADIUS_PANEL, UiTheme.SPACE_2)
	UiKit.add_button(theme, &"ShopClose",
		UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE.darkened(0.25),
		UiTheme.PANEL_INNER.lightened(0.12), UiTheme.ACCENT_DIM,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_2)
	return theme

func _clear_grid(grid: GridContainer) -> void:
	UiKit.clear(grid)

func _buy_item(key: String, price: int) -> void:
	if not is_instance_valid(player) or player.gold < price:
		return
	player.gold -= price
	player.add_item(key)
	SoundDB.play("ui.craft")
	inventory_changed.emit()
	_refresh()
	print("Куплено: " + key)

func _sell_item(key: String, price: int) -> void:
	if not is_instance_valid(player) or not player.remove_item(key):
		return
	player.gold += price
	SoundDB.play("ui.craft")
	inventory_changed.emit()
	_refresh()
	print("Продано: " + key)

func _talk() -> void:
	if not is_instance_valid(_merchant_label):
		return
	var lines: Array = MERCHANT_LINES.duplicate()
	var idx := randi() % lines.size()
	_merchant_label.text = tr("Торговец: «%s»") % str(lines[idx])
	SoundDB.play("voice.npc.merchant.%d" % (idx + 1))

func _input(event: InputEvent) -> void:
	if UiKit.esc_pressed(event):
		close()
		get_viewport().set_input_as_handled()

func close() -> void:
	UiKit.restore_focus(_previous_focus)
	closed.emit()
	queue_free()
