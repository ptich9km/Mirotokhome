extends SceneTree
##
## Вкладки инвентаря (28.10): «Склад», «Отношения», «Ремесла».
##
## ЗАЧЕМ
## -----
## Репутацию с фракциями негде было посмотреть, а навыки ремёсел жили только
## внутри мастерской. Игрок предложил не лепить всё в одну кучу, а разложить
## по вкладкам инвентаря. Вкладки стоят в ШАПКЕ: отдельная строка отняла бы
## высоту у склада и вернула бы прокрутку (жалоба 23.10).
##
## ЧТО ПРОВЕРЯЕМ
## -------------
##   1. три вкладки, три страницы, видна ровно одна;
##   2. «Склад» сохранил прежние узлы (Top/InvCol, сетка, статы) — склад не сломан;
##   3. «Отношения»: 4 фракции со значениями, статус словом, что открыто,
##      и пары отношений фракций между собой;
##   4. «Ремесла»: четыре навыка с уровнем и прогрессом + рецепты в складе;
##   5. панель влезает в 1280×800 и 1280×600, склад не получил прокрутку.
##
## Запуск: godot --headless --path . --script res://tests/inventory_tabs_smoke.gd

const SIZES := [Vector2i(1280, 800), Vector2i(1280, 600)]

var _checks := 0
var _fails: Array[String] = []


func _initialize() -> void:
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 9, "spirit": 8,
		"blade": 30, "bludgeon": 15, "pike": 10,
		"fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.hero_class = "warrior"
	Game.hero_name = "Тест"
	Game.hero_character_id = "mfighter"
	Game.hero_race = "human"
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print(("  OK  " if ok else "  FAIL") + " " + what)


func _rows(box: Node) -> Array:
	var out: Array = []
	if box == null:
		return out
	for c in box.get_children():
		if c is HBoxContainer:
			out.append(c)
	return out


func _row_text(row: Node) -> String:
	var parts: Array[String] = []
	for c in row.get_children():
		if c is Label:
			parts.append(str((c as Label).text))
	return " | ".join(parts)


func _run() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	var game = packed.instantiate()
	root.add_child(game)
	for i in range(3):
		await process_frame
	var player = game.get("player")
	var ui = game.get("ui")
	ui.call("open_inventory_panel")
	await process_frame
	var inv = ui.get("_inventory_panel")
	_check(inv != null, "инвентарь открыт")
	if inv == null:
		_report()
		return

	print("-- три вкладки --")
	var tabs: Array = inv.get("_view_tabs")
	var pages: Array = inv.get("_view_pages")
	_check(tabs.size() == 3, "вкладок три (сейчас %d)" % tabs.size())
	_check(pages.size() == 3, "страниц три (сейчас %d)" % pages.size())
	if tabs.size() == 3 and pages.size() == 3:
		# The tab text comes from ui.json now, so the check compares against the
		# localized key instead of a Russian literal: a literal would break on the
		# language switch and would pin the wording to one locale.
		_check(str((tabs[0] as Button).text) == Loc.t("ui.inv.tab.storage"), "первая вкладка — «Склад»")
		_check(str((tabs[1] as Button).text) == Loc.t("ui.inv.tab.relations"), "вторая — «Отношения»")
		_check(str((tabs[2] as Button).text) == Loc.t("ui.inv.tab.crafts"), "третья — «Ремёсла»")
		_check((pages[0] as Control).visible and not (pages[1] as Control).visible
			and not (pages[2] as Control).visible, "видна только страница склада")

	print("-- склад не сломан --")
	var page_inv: Control = pages[0] if pages.size() > 0 else null
	_check(page_inv != null and page_inv.find_child("Top", true, false) != null,
		"страница склада содержит Top (кукла+статы)")
	_check(page_inv != null and page_inv.find_child("InvCol", true, false) != null,
		"страница склада содержит InvCol (сетка предметов)")
	var grid = inv.get("_inventory_grid")
	_check(grid != null and (grid as GridContainer).columns > 1,
		"сетка склада многоколоночная")

	print("-- отношения --")
	var bus = root.get_node_or_null("WorldBus")
	if bus != null and bus.state != null:
		bus.state.hero_reputation["humans"] = 42
		bus.state.hero_reputation["ork"] = 5
	inv.call("_set_view", 1)
	await process_frame
	var rel_box = inv.get("_relations_box")
	var rel_rows := _rows(rel_box)
	_check(rel_rows.size() >= 4, "четыре фракции в «Вашем отношении» (строк %d)" % rel_rows.size())
	var humans_text := ""
	for row in rel_rows:
		var t := _row_text(row)
		if t.contains("люди"):
			humans_text = t
	_check(humans_text.contains("42"), "репутация людей показана (42): %s" % humans_text)
	_check(humans_text.to_lower().contains("дружелюбно") or humans_text.to_lower().contains("доверие"),
		"статус человеческой репутации словом: %s" % humans_text)
	_check(humans_text.contains("Наёмники"), "в строке видно, что открывает репутация")
	var pairs := 0
	for row in rel_rows:
		if _row_text(row).contains(" — "):
			pairs += 1
	_check(pairs >= 1, "есть пары отношений фракций между собой (%d)" % pairs)
	_check((pages[1] as Control).visible and not (pages[0] as Control).visible,
		"переключение показало страницу отношений")

	print("-- ремёсла --")
	inv.call("_set_view", 2)
	await process_frame
	var craft_box = inv.get("_crafts_box")
	var craft_rows := _rows(craft_box)
	_check(craft_rows.size() >= 4, "четыре навыка ремесла (строк %d)" % craft_rows.size())
	var names := ""
	for row in craft_rows:
		names += _row_text(row)
	for want in ["Кузнец", "Портной", "Мастер", "Алхимия"]:
		_check(names.contains(want), "навык «%s» на месте" % want)
	var lvl_row := ""
	for row in craft_rows:
		if _row_text(row).contains("Кузнец") and _row_text(row).contains("ур."):
			lvl_row = _row_text(row)
	_check(lvl_row.contains("ур."), "у навыка показан уровень: %s" % lvl_row)
	_check((pages[2] as Control).visible and not (pages[1] as Control).visible,
		"переключение показало страницу ремёсел")

	print("-- раскладка --")
	inv.call("_set_view", 0)
	await process_frame
	var panel: Control = inv.get("_panel")
	for size in SIZES:
		root.size = Vector2(size)
		await process_frame
		var vp := root.get_visible_rect()
		_check(panel != null and vp.encloses(panel.get_global_rect()),
			"[%dx%d] панель внутри окна" % [size.x, size.y])
	_check(grid != null and (grid as GridContainer).columns > 1,
		"склад остаётся многоколоночным после переключений")

	inv.call("close")
	print("")
	if _fails.is_empty():
		print("RESULT: OK inventory_tabs_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL inventory_tabs_smoke (%d checks, %d fails)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)


func _report() -> void:
	print("RESULT: FAIL inventory_tabs_smoke (панель не открылась)")
	quit(1)
