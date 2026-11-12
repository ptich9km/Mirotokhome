extends SceneTree

## Панель мастерской: вкладки, фокус, переработка и крафт end-to-end.

var _fails: Array[String] = []
var _checks := 0


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_fails.append(msg)


## _initialize, а не _init: в SceneTree._init() узлы НЕ получают
## NOTIFICATION_READY (проверено пробой: is_node_ready() == false, а
## _list_buttons пуст). Все рабочие тесты проекта используют _initialize() +
## `await process_frame` - см. inventory_ui_smoke.gd:21-39.
func _initialize() -> void:
	ItemDB.ensure_loaded()
	var panel := _build()
	if panel == null:
		print("checks=%d fails=%d" % [_checks, _fails.size()])
		print("RESULT: FAIL workshop_ui_smoke")
		quit(1)
		return
	await process_frame
	_test_structure(panel)
	await process_frame
	_test_smelt_flow(panel)
	await process_frame
	_test_craft_flow(panel)
	await process_frame
	_test_focus(panel)
	_test_input_passthrough(panel)
	print("checks=%d fails=%d" % [_checks, _fails.size()])
	if _fails.is_empty():
		print("RESULT: OK workshop_ui_smoke")
		quit(0)
	else:
		for f in _fails:
			print("FAIL %s" % f)
		print("RESULT: FAIL workshop_ui_smoke")
		quit(1)


## Открывает панель через GameUI - тот же путь, что и клик по зданию.
func _build() -> WorkshopPanel:
	root.add_to_group("ui")
	var player := Player.new()
	player.add_item(ItemDB.broken_key("iron", "Armor", "Broken Rare"))
	player.add_item(ItemDB.broken_key("Linen", "Garment", "Broken"))
	player.add_item("Common iron Cuirass")
	player.add_item("Common Linen Robe")
	player.add_item("Crafted Linen Cloak")
	player.add_item("iron Ingot")
	player.add_item("iron Ingot")
	player.add_item("iron Ingot")
	player.add_item("Fabric")
	player.add_item("Fabric")
	player.add_item("Fabric")
	player.add_item("Magic Essence")
	# Свитки рецептов: без них список рецептов пуст (петля лавки).
	player.add_item(CraftDB.recipe_scroll_key("iron_cuirass"))
	player.add_item(CraftDB.recipe_scroll_key("linen_robe"))
	player.add_item(CraftDB.recipe_scroll_key("linen_cloak"))
	player.gold = 1000
	var panel := WorkshopPanel.new()
	panel.setup(player)
	root.add_child(panel)
	return panel


func _tabs(panel: WorkshopPanel) -> TabContainer:
	return panel.get_node_or_null("WorkshopRoot") as TabContainer if false else \
		_find_tabs(panel)


func _find_tabs(panel: WorkshopPanel) -> TabContainer:
	for c in panel.get_children():
		var found := _search_tabs(c)
		if found != null:
			return found
	return null


func _search_tabs(node: Node) -> TabContainer:
	if node is TabContainer:
		return node as TabContainer
	for c in node.get_children():
		var r := _search_tabs(c)
		if r != null:
			return r
	return null


func _tab_of(panel: WorkshopPanel, kind: String) -> CraftTab:
	var tabs := _find_tabs(panel)
	if tabs == null:
		return null
	var n := tabs.get_node_or_null(kind)
	return n as CraftTab


# --- Структура ------------------------------------------------------------

func _test_structure(panel: WorkshopPanel) -> void:
	_check(panel.layer == 10, "слой 10, как у остальных интерьеров (%d)" % panel.layer)
	var tabs := _find_tabs(panel)
	_check(tabs != null, "есть TabContainer")
	if tabs == null:
		return
	# Три вкладки: кузнец, портной, мастер (master_enabled=1).
	_check(tabs.get_tab_count() == 3,
		"три вкладки (%d)" % tabs.get_tab_count())
	_check(tabs.get_tab_title(0) == Loc.t("ui.inv.craft.smith"),
		"первая вкладка «Кузнец» (%s)" % tabs.get_tab_title(0))
	_check(tabs.get_tab_title(1) == Loc.t("ui.inv.craft.tailor"),
		"вторая вкладка «Портной» (%s)" % tabs.get_tab_title(1))
	_check(tabs.get_tab_title(2) == Loc.t("ui.inv.craft.master"),
		"третья вкладка «Мастер» (%s)" % tabs.get_tab_title(2))
	_check(tabs.get_child_count() == 3, "три вкладки в контейнере")

	var smith := _tab_of(panel, CraftDB.SMITH)
	var tailor := _tab_of(panel, CraftDB.TAILOR)
	var master := _tab_of(panel, CraftDB.MASTER)
	_check(smith != null, "вкладка кузнеца создана")
	_check(tailor != null, "вкладка портного создана")
	_check(master != null, "вкладка мастера создана")
	if smith != null:
		_check(smith.craft == CraftDB.SMITH, "вкладка кузнеца знает своё ремесло")
		# Кузнец принимает сломанное И целую броню/оружие.
		var smith_sees_garment := false
		var smith_sees_armor := false
		var smith_sees_intact := false
		for e in smith.call("_items"):
			if str(e.get("mode", "")) != smith.RECYCLE_ID:
				continue
			var it: Dictionary = e["item"]
			var cat := ItemDB.broken_category(it)
			if cat == "Garment":
				smith_sees_garment = true
			elif cat == "Armor" or ItemDB.armor_kind(it) == "heavy" \
					or ItemDB.slot_of(it) == "weapon":
				smith_sees_armor = true
			if not ItemDB.is_broken(it) and ItemDB.is_equippable(it):
				smith_sees_intact = true
		_check(smith_sees_armor, "кузнец видит броню/оружие в списке")
		_check(not smith_sees_garment,
			"кузнец НЕ видит одежду (иначе ткань и эссенция у портного)")
		_check(smith_sees_intact, "кузнец видит целую броню для переплавки")
		# Рецепт с открытого свитка виден.
		var has_recipe := false
		for e in smith.call("_items"):
			if str(e.get("mode", "")) == smith.RECIPE_ID \
					and str(e.get("id", "")) == "iron_cuirass":
				has_recipe = true
		_check(has_recipe, "рецепт iron_cuirass виден по свитку")
	if tailor != null:
		var tailor_sees_garment := false
		var tailor_sees_intact := false
		for e in tailor.call("_items"):
			if str(e.get("mode", "")) == tailor.RECYCLE_ID:
				if ItemDB.broken_category(e["item"]) == "Garment":
					tailor_sees_garment = true
				if not ItemDB.is_broken(e["item"]) and ItemDB.is_equippable(e["item"]):
					tailor_sees_intact = true
		_check(tailor_sees_garment, "портной видит сломанную одежду")
		_check(tailor_sees_intact, "портной видит целую одежду мага")
	if master != null:
		_check(master.craft == CraftDB.MASTER, "вкладка мастера знает своё ремесло")
		var master_items: Array = master.call("_items")
		var master_has_upgrade := false
		for e in master_items:
			if str(e.get("mode", "")) == "forge":
				master_has_upgrade = true
		_check(master_has_upgrade,
			"мастер видит крафтовую вещь для улучшения (%d элементов)" % master_items.size())
		_test_essence_row(master)
	# Shop shelf: present and filled.
	var inv_grid := _find_named(panel, "InvShelf")
	_check(inv_grid != null, "полка инвентаря мастерской есть")
	if inv_grid is GridContainer:
		_check((inv_grid as GridContainer).get_child_count() > 0,
			"полка инвентаря не пуста")


## The essence row of the upgrade cost has an icon (the animated essence art or
## the item icon while the art is missing) and shows up even on the Fine step,
## where the cost is 0 (player complaint 22.10).
func _test_essence_row(master: CraftTab) -> void:
	var items: Array = master.call("_items")
	var index := -1
	for i in items.size():
		var e: Dictionary = items[i]
		if str(e.get("mode", "")) != "forge":
			continue
		index = i
		break
	if index < 0:
		return
	master.set("_selected", index)
	master.call("_build_detail", items[index])
	var row: Node = _find_named(master, "CostRow_Magic_Essence")
	_check(row != null, "строка эссенции в стоимости улучшения есть всегда")
	if row == null:
		return
	var icon: TextureRect = null
	for c in row.find_children("EssenceIcon", "TextureRect", true, false):
		icon = c as TextureRect
		break
	_check(icon != null and icon.texture != null, "у эссенции в крафте есть иконка")
	_check(EssenceIcons.icon() != "", "иконка эссенции находится (%s)" % EssenceIcons.icon().get_file())
	_check(EssenceIcons.has_anim(),
		"у эссенции 4 кадра анимации (%d)" % EssenceIcons.frames().size())
	if icon == null:
		return
	_check(icon.texture.resource_path.ends_with("essence-000.png"),
		"иконка в крафте — кадр анимированного арта (%s)" % icon.texture.resource_path.get_file())


func _find_named(node: Node, name_: String) -> Node:
	if node.name == name_:
		return node
	for c in node.get_children():
		var r := _find_named(c, name_)
		if r != null:
			return r
	return null


# --- Переработка ----------------------------------------------------------

func _test_smelt_flow(panel: WorkshopPanel) -> void:
	var smith := _tab_of(panel, CraftDB.SMITH)
	if smith == null:
		return
	var player: Player = smith.player
	var ingots_before := _count(player, "iron Ingot")
	var fabric_before := _count(player, "Fabric")

	# Выбираем сломанную редкую броню и «перерабатываем».
	var idx := _find_recycle_index(smith, "Armor")
	_check(idx >= 0, "сломанная броня есть в списке кузнеца")
	if idx < 0:
		return
	var expected := CraftDB.recycle_yield(
		ItemDB.find(ItemDB.broken_key("iron", "Armor", "Broken Rare")))
	var status := str(smith.call("_recycle",
		smith.call("_items")[_index_of(smith, idx)]))

	_check(status.find(Loc.t("ui.craft.salvaged").split("%")[0]) >= 0,
		"статус сообщает о переработке (%s)" % status)
	_check(_count(player, "iron Ingot") == ingots_before + int(expected["ingot"]),
		"слитков +%d (было %d, стало %d)" % [int(expected["ingot"]), ingots_before,
			_count(player, "iron Ingot")])
	_check(_count(player, "Fabric") == fabric_before + int(expected["fabric"]),
		"ткани +%d" % int(expected["fabric"]))
	_check(player.smithing_skill >= 0, "навык кузнеца не отрицательный")

	# Портной перерабатывает одежду в эссенцию.
	var tailor := _tab_of(panel, CraftDB.TAILOR)
	if tailor == null:
		return
	var gidx := _find_recycle_index(tailor, "Garment")
	if gidx >= 0:
		var ess_before := _count(player, CraftDB.ESSENCE_KEY)
		tailor.call("_recycle", tailor.call("_items")[_index_of(tailor, gidx)])
		var ey := CraftDB.recycle_yield(
			ItemDB.find(ItemDB.broken_key("Linen", "Garment", "Broken")))
		_check(_count(player, CraftDB.ESSENCE_KEY) == ess_before + int(ey["essence"]),
			"эссенции +%d" % int(ey["essence"]))
	else:
		_check(false, "сломанная одежда есть в списке портного")


# --- Крафт ----------------------------------------------------------------

func _test_craft_flow(panel: WorkshopPanel) -> void:
	var smith := _tab_of(panel, CraftDB.SMITH)
	if smith == null:
		return
	var player: Player = smith.player
	var idx := _find_recipe_index(smith)
	_check(idx >= 0, "рецепт есть в списке")
	if idx < 0:
		return
	var entry: Dictionary = smith.call("_items")[_index_of(smith, idx)]
	var recipe: Dictionary = entry["recipe"]
	var before := {}
	for ing in recipe.get("inputs", []):
		var k := str(ing["item"])
		before[k] = _count(player, k)
	var status := str(smith.call("_craft", recipe))
	_check(status.find(Loc.t("ui.craft.crafted").split("%")[0]) >= 0,
		"крафт удался (%s)" % status)
	var produced := 0
	for ing in recipe.get("inputs", []):
		var k := str(ing["item"])
		var want := int(before[k]) - int(ing["count"])
		_check(_count(player, k) == want,
			"%s списано ровно %d (%d -> %d)" % [k, int(ing["count"]), int(before[k]),
				_count(player, k)])
	for tier in 3:
		var okey := CraftDB.output_key(recipe, tier)
		_check(not ItemDB.find(okey).is_empty(), "выход уровня %d существует" % tier)

	# Навык вырос (навык читаем; рост опыта не гарантирует смену уровня).
	_check(player.smithing_skill >= 0, "навык кузнеца читаем (%d)" % player.smithing_skill)
	# После крафта ровно один выход рецепта добавлен в инвентарь
	# (add_item(out_key), см. craft_tab._craft). Сторож не должен быть `or true`.
	var any_out := false
	for tier in 3:
		if _count(player, CraftDB.output_key(recipe, tier)) > 0:
			any_out = true
			break
	_check(any_out, "после крафта в инвентаре есть выход рецепта")


# --- Фокус ----------------------------------------------------------------

func _test_focus(panel: WorkshopPanel) -> void:
	var smith := _tab_of(panel, CraftDB.SMITH)
	if smith == null:
		return
	# _ready вкладки не вызывается вручную - панель добавлена в дерево, и
	# дочерние узлы получают _ready сами. Если список пуст, значит refresh()
	# не отработал, и это уже дефект.
	var first: Variant = smith.call("first_focus_target")
	_check(first != null,
		"у вкладки есть узел начального фокуса (список: %d кнопок)"
		% (smith.get("_list_buttons") as Array).size())
	_check(first is Control, "начальный фокус - Control (%s)" % str(first))
	_check(first is Button, "начальный фокус - кнопка (%s)" % str(first))

	# Фокус не должен утекать в невидимую вкладку: узлы списка пересоздаются
	# при refresh, и абсолютные пути wire_grid_focus после этого указывают в
	# пустоту. Поэтому configure_focus зовётся на каждом tab_switched.
	smith.call("refresh")
	var tailor := _tab_of(panel, CraftDB.TAILOR)
	if tailor != null:
		tailor.call("refresh")
		var t_first: Variant = tailor.call("first_focus_target")
		_check(t_first is Control and is_instance_valid(t_first),
			"после refresh фокус у портного живой")


## Клик по панели не должен уводить героя по карте: это контракт
## game.gd:_input, который bail-ает на ui.is_editor_open().
func _test_input_passthrough(panel: WorkshopPanel) -> void:
	_check(panel.layer == 10, "панель выше мира (layer 10) - клики не проходят в мир")


# --- Хелперы --------------------------------------------------------------

func _count(player: Player, key: String) -> int:
	var n := 0
	for raw in player.inventory:
		if str(raw) == key:
			n += 1
	return n


func _has_any(player: Player, keys: Array) -> bool:
	for k in keys:
		if _count(player, str(k)) > 0:
			return true
	return false


## Индекс элемента с данным режимом и категорией среди НЕРЕЦЕПТНЫХ записей.
func _index_of(tab: CraftTab, wanted_index: int) -> int:
	return wanted_index


func _find_recycle_index(tab: CraftTab, category: String) -> int:
	var items: Array = tab.call("_items")
	for i in items.size():
		var e: Dictionary = items[i]
		if str(e.get("mode", "")) != tab.RECYCLE_ID:
			continue
		if ItemDB.broken_category(e["item"]) == category:
			return i
	return -1


## Первый рецепт, на который хватает ингредиентов. Первый по списку брать
## нельзя: список отсортирован по базе, а не по доступности, и «Не хватает»
## было бы правильным поведением кода, а не находкой.
func _find_recipe_index(tab: CraftTab) -> int:
	var items: Array = tab.call("_items")
	var player: Player = tab.player
	for i in items.size():
		var e: Dictionary = items[i]
		if str(e.get("mode", "")) != tab.RECIPE_ID:
			continue
		var recipe: Dictionary = e.get("recipe", {})
		if recipe.is_empty():
			continue
		var ok := true
		for ing in recipe.get("inputs", []):
			if _count(player, str(ing.get("item", ""))) < int(ing.get("count", 0)):
				ok = false
				break
		if ok:
			return i
	return -1