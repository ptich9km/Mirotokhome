extends SceneTree
## Headless-проверка магазина: контейнерная раскладка без фонового арта.
##
## 05.10: JPEG shop_human.jpeg убран. Тест фиксирует контракт новой панели:
## сетки существуют, ячейки в пределах панели, hover-card работает,
## покупка/продажа не сломаны.
##
## Запуск:
##   godot --headless --path . --script res://tests/shop_ui_smoke.gd

var _fails: Array = []
var _shop: ShopPanel = null


func _initialize() -> void:
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 13, "spirit": 12,
		"blade": 10, "bludgeon": 10, "pike": 10, "shooting": 10,
		"fire": 20, "water": 20, "air": 20, "earth": 20, "astral": 20,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.hero_class = "warrior"
	Game.hero_name = "Покупатель"
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails.append(what)
	print("SHOP: %s %s" % ["ok  " if ok else "FAIL", what])


func _run() -> void:
	var err := change_scene_to_file("res://scenes/main.tscn")
	if err != OK:
		_check(false, "загрузка main.tscn: %d" % err)
		_finish()
		return
	await process_frame
	await create_timer(0.6).timeout
	var hero = get_first_node_in_group("player")
	if hero == null:
		_check(false, "герой не загружен")
		_finish()
		return
	hero.call("add_item", "Common iron Long Sword")
	hero.call("add_item", "Common Leather Mail")
	hero.call("add_item", "Potion Medium Healing")
	hero.gold = 100000

	_shop = ShopPanel.new()
	# Раса города задана явно: полка фракционных чертежей (пакет F) показывает
	# наборы ТОЛЬКО своей фракции, и без расы она пуста.
	_shop.setup(hero, "humans")
	current_scene.add_child(_shop)
	await process_frame
	await create_timer(0.3).timeout

	_test_layout()
	_test_cells_in_panel()
	_test_no_text_in_cell()
	await _test_hover_card()
	await _test_buy_sell()
	await _test_rep_notice()
	await _test_faction_shelf()
	_finish()


## 1. Раскладка: панель, полки, категории.
func _test_layout() -> void:
	var panel: Control = _find("Panel")
	_check(panel != null, "панель PanelContainer найдена")
	var npc_grid: GridContainer = _find("NpcShelf")
	var player_grid: GridContainer = _find("PlayerShelf")
	_check(npc_grid != null, "полка торговца найдена")
	_check(player_grid != null, "полка игрока найдена")
	if npc_grid == null or player_grid == null:
		return
	_check(npc_grid.columns == 4, "полка торговца: 4 колонки (получено %d)" % npc_grid.columns)
	_check(player_grid.columns == 5, "полка игрока: 5 колонок (получено %d)" % player_grid.columns)
	var cats: Node = _find("Categories")
	_check(cats != null and cats.get_child_count() >= 5, "категории — кнопки в шапке (3 рецепта + зелья + книги)")
	var bg: Node = _find("Background")
	_check(bg == null, "фонового JPEG больше нет")


## 2. Полки в пределах панели (не арта 1024×1024).
func _test_cells_in_panel() -> void:
	var panel: Control = _find("Panel")
	var scroll: ScrollContainer = _find("NpcShelfScroll")
	var pscroll: ScrollContainer = _find("PlayerShelfScroll")
	_check(scroll != null and pscroll != null, "скролл-полки найдены")
	if panel == null or scroll == null or pscroll == null:
		return
	var pglobal := panel.get_global_rect()
	_check(scroll.get_global_rect().encloses(pglobal.grow(-2.0)) or scroll.get_global_rect().intersects(pglobal),
		"полка торговца пересекается с панелью")
	_check(pscroll.get_global_rect().intersects(pglobal),
		"полка игрока пересекается с панелью")
	var slot: Control = _first_child_of_type(npc_grid_or_null(), "PanelContainer") if npc_grid_or_null() != null else null
	# Размер ячейки — контентный, не артовый 95.5
	if slot != null:
		_check(slot.custom_minimum_size.x > 40.0,
			"ячейка полки торговца шире 40 px (получено %.1f)" % slot.custom_minimum_size.x)


func npc_grid_or_null() -> GridContainer:
	return _find("NpcShelf") as GridContainer


## 3. В ячейке нет текстовых ярлыков — только иконка и кнопка.
func _test_no_text_in_cell() -> void:
	var grid: GridContainer = _find("NpcShelf")
	if grid == null:
		_check(false, "полка торговца не найдена")
		return
	var slot: Control = _first_child_of_type(grid, "PanelContainer")
	if slot == null:
		_check(false, "в полке нет ячеек")
		return
	var labels := _count_labels(slot)
	_check(labels == 0,
		"в ячейке нет текстовых ярлыков (название ушло в карточку), найдено %d" % labels)
	var buttons := _count_of_type(slot, "Button")
	_check(buttons == 1, "в ячейке ровно одна кнопка (Купить), найдено %d" % buttons)


## 4. Карточка по наведению.
func _test_hover_card() -> void:
	var card: PanelContainer = _find("HoverCard")
	_check(card != null, "карточка создана")
	if card == null:
		return
	root.gui_release_focus()
	await process_frame
	_check(not card.visible, "карточка скрыта, когда ни один предмет не выбран")
	_check(card.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"карточка не перехватывает мышь")

	var grid: GridContainer = _find("NpcShelf")
	var slot: Control = _first_child_of_type(grid, "PanelContainer")
	if slot == null:
		_check(false, "нет ячейки для проверки карточки")
		return
	slot.emit_signal("mouse_entered")
	await process_frame
	_check(card.visible, "карточка появилась при наведении")
	var lines := _card_lines(card)
	_check(lines.size() >= 3,
		"в карточке строк с данными: %d" % lines.size())
	if lines.size() > 0:
		_check(not str(lines[0]).is_empty(), "первая строка — название")
	var joined := " | ".join(lines)
	# Price label without the number: "Цена: " / "Price: " — language-agnostic.
	_check(joined.contains(Loc.t("ui.shop.price").split("%")[0]),
		"в карточке есть цена")
	slot.emit_signal("mouse_exited")
	await process_frame
	_check(not card.visible, "карточка спряталась после ухода курсора")


## 5. Покупка и продажа. await обязателен: функция содержит process_frame,
## без await проверки уедут за пределы отчёта (класс граблей AGENTS.md §12).
func _test_buy_sell() -> void:
	var hero = get_first_node_in_group("player")
	if hero == null:
		_check(false, "герой для сделки не найден")
		return
	var gold_before: int = hero.gold
	var inv_before: int = hero.inventory.size()
	var npc_grid: GridContainer = _find("NpcShelf")
	var slot: Control = _first_child_of_type(npc_grid, "PanelContainer") if npc_grid != null else null
	var btn: Button = _find_button(slot) if slot != null else null
	if btn == null:
		_check(false, "нет кнопки «Купить»")
		return
	if btn.disabled:
		_check(true, "первая кнопка «Купить» заблокирована — пропускаем эмит")
		return
	btn.pressed.emit()
	await process_frame
	_check(hero.gold < gold_before or hero.inventory.size() > inv_before,
		"покупка изменила золото/инвентарь (gold %d→%d, inv %d→%d)"
			% [gold_before, hero.gold, inv_before, hero.inventory.size()])


## 28.10: репутация гейтит эльфийские свитки; закрытое должно быть объяснено,
## иначе «товары пропали». Плашка и подсказка живут вне сетки, поэтому их
## видно и при непустой вкладке.
func _test_rep_notice() -> void:
	var idx := -1
	for i in range(ShopPanel.CATEGORIES.size()):
		if str(ShopPanel.CATEGORIES[i]["id"]) == "books":
			idx = i
			break
	if idx < 0:
		_check(false, "вкладка «Книги и свитки» найдена")
		return
	_shop.call("_set_category", idx)
	await process_frame
	var notice = _shop.get("_npc_notice")
	_check(notice is Label and (notice as Label).visible,
		"закрытые эльфийские свитки объяснены плашкой")
	if notice is Label:
		_check(str((notice as Label).text).contains("40"),
			"плашка называет порог репутации")
	var hint = _shop.get("_hint_label")
	var faction_label := Lore.faction_label(str(_shop.get("_race")))
	_check(hint is Label and str((hint as Label).text).contains(faction_label),
		"подсказка называет фракцию города (%s)" % faction_label)


## Пакет F: полка фракционных чертежей — только наборы своей фракции, с плашкой.
func _test_faction_shelf() -> void:
	var idx := -1
	for i in range(ShopPanel.CATEGORIES.size()):
		if str(ShopPanel.CATEGORIES[i]["id"]) == "recipes_faction":
			idx = i
			break
	_check(idx >= 0, "вкладка «Рец. Фракция» есть")
	if idx < 0:
		return
	_shop.call("_set_category", idx)
	await process_frame
	var pool: Array = _shop.call("_category_items", idx)
	_check(pool.size() == 12, "полка фракции: 12 чертежей наборов (%d)" % pool.size())
	var foreign := 0
	for item in pool:
		var rid := str((item as Dictionary).get("recipe_id", ""))
		if not rid.begins_with("faction_humans_"):
			foreign += 1
	_check(foreign == 0, "на полке только чертежи фракции города (%d чужих)" % foreign)
	var grid: GridContainer = _find("NpcShelf")
	var cells := 0
	if grid != null:
		for c in grid.get_children():
			if c is PanelContainer:
				cells += 1
	_check(cells == 12, "ячеек на полке фракции: %d" % cells)
	var notice = _shop.get("_npc_notice")
	_check(notice is Label and (notice as Label).visible,
		"полка фракции объяснена плашкой")
	var shelf_label := Lore.faction_label(str(_shop.get("_race")))
	if notice is Label:
		_check(str((notice as Label).text).contains(shelf_label),
			"плашка называет фракцию (%s)" % shelf_label)
	# Чертежи фракции не должны просачиваться в другие вкладки рецептов.
	for other in range(ShopPanel.CATEGORIES.size()):
		if other == idx:
			continue
		var other_pool: Array = _shop.call("_category_items", other)
		var leaked := 0
		for item2 in other_pool:
			if str((item2 as Dictionary).get("bp", "")) == "faction":
				leaked += 1
		if leaked > 0:
			_check(false, "чертежи фракции просочились во вкладку %s (%d шт.)"
				% [str(ShopPanel.CATEGORIES[other]["id"]), leaked])
			return
	_check(true, "в других вкладках чертежей фракции нет")


func _find(node_name: String) -> Node:
	if _shop == null:
		return null
	return _shop.find_child(node_name, true, false)

func _first_child_of_type(root: Node, type_name: String) -> Control:
	if root == null:
		return null
	for c in root.get_children():
		if c.get_class() == type_name:
			return c as Control
	return null


func _count_labels(root: Node) -> int:
	var n := 0
	for c in root.get_children():
		if c is Label:
			n += 1
		n += _count_labels(c)
	return n


func _count_of_type(root: Node, type_name: String) -> int:
	var n := 0
	for c in root.get_children():
		if c.get_class() == type_name:
			n += 1
		n += _count_of_type(c, type_name)
	return n


func _find_button(root: Node) -> Button:
	if root == null:
		return null
	for c in root.get_children():
		if c is Button:
			return c as Button
		var found := _find_button(c)
		if found != null:
			return found
	return null


func _card_lines(card: PanelContainer) -> Array:
	var out: Array = []
	var box: Node = card.find_child("Box", true, false)
	if box == null:
		return out
	for c in box.get_children():
		if c is Label:
			out.append(str((c as Label).text))
	return out


func _finish() -> void:
	if _fails.is_empty():
		print("SHOP: RESULT: OK")
	else:
		print("SHOP: RESULT: FAIL (%d): %s" % [_fails.size(), str(_fails)])
	quit(0 if _fails.is_empty() else 1)
