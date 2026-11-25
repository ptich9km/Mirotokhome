extends SceneTree
## World map 4x3 screen (23.10, SIM overlay 26.11).
##
## Run: godot --headless --path . --script res://tests/world_map_ui_smoke.gd
##
## Checks 12 cells, current sector, unexplored silhouette, capital, localization,
## grid focus, panel size at 1280x800 / 1280x600, faction tint, contested pulse
## and the SIM clash mark.

var _checks := 0
var _fails: Array[String] = []


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print(("  OK  " if ok else "  FAIL") + " " + what)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var bus = root.get_node_or_null("WorldBus")
	_check(bus != null, "WorldBus есть")
	if bus != null and bus.state != null:
		bus.state.init_world(4242, "humans")
		# The capital is far from the start: reveal it for label checks.
		if bus.state.sectors.has("s21"):
			var cap_state: Dictionary = bus.state.sectors["s21"]
			cap_state["discovered"] = 2
			bus.state.sectors["s21"] = cap_state
		# An ownerless, revealed sector must show the contested pulse.
		if bus.state.sectors.has("s11"):
			var open_state: Dictionary = bus.state.sectors["s11"]
			open_state["owner"] = ""
			open_state["discovered"] = 2
			bus.state.sectors["s11"] = open_state
		# Two hostile garrisons in the start sector create a visible SIM clash.
		var faction_ids: Array = bus.state.factions.keys()
		if faction_ids.size() >= 2:
			var left = bus.state.new_army(str(faction_ids[0]), Vector2(1, 1))
			var right = bus.state.new_army(str(faction_ids[1]), Vector2(2, 2))
			left["sector_id"] = "s41"
			right["sector_id"] = "s41"
			left["enemy_id"] = right.id
			right["enemy_id"] = left.id
	Game.world_seed = 4242
	Game.map_sector = "s41"
	Game.map_zone = "start"

	var script: GDScript = load("res://scripts/world_map_panel.gd")
	var panel = script.new()
	panel.setup()
	root.add_child(panel)
	await process_frame
	await process_frame

	var grid = panel.get("_grid")
	_check(grid != null, "сетка построена")
	if grid == null:
		_finish()
		return
	_check(grid.get_child_count() == 12, "12 ячеек (найдено %d)" % grid.get_child_count())

	var cells: Dictionary = panel.get("_cells")
	_check(cells.size() == 12, "12 секторов в карте ячеек")
	_check(cells.has("s41"), "стартовый сектор s41 есть")
	for sid: String in cells:
		var cell: Node = cells[sid]
		_check(cell.get_node_or_null("TerritoryTint") != null,
			"territory tint in %s" % sid)
		_check(cell.get_node_or_null("TerritoryStripe") != null,
			"faction stripe in %s" % sid)
	var current = cells.get("s41")
	_check(current != null and str(current.get("theme_type_variation")) == "WorldCellCurrent",
		"текущий сектор выделен")
	var cap = cells.get("s21")
	_check(cap != null, "столица s21 есть")
	if cap != null:
		var text := _all_text(cap)
		_check(text.contains(Loc.t("ui.world_map.capital")), "у столицы подпись «Столица»")
		_check(text.contains(Loc.t("ui.world_map.faction.humans"))
			or text.contains(Loc.t("ui.world_map.faction.ork"))
			or text.contains(Loc.t("ui.world_map.faction.druid"))
			or text.contains(Loc.t("ui.world_map.faction.necro")),
			"у столицы подпись фракции")
	var unknown := _all_text(cells.get("s12"))
	_check(unknown.contains(Loc.t("ui.world_map.unknown")),
		"неисследованный сектор — силуэт без имени")
	var start_text := _all_text(cells.get("s41"))
	_check(start_text.contains(Loc.t("ui.world_map.here")), "старт помечен «Ты здесь»")
	_check(start_text.contains("Тихая Заводь") or start_text.contains("Quiet Backwater"),
		"имя старта из локализации")
	var contested_cell = cells.get("s11")
	_check(contested_cell != null and contested_cell.get_node_or_null("ContestedAlert") != null,
		"ownerless sector pulses")
	_check(contested_cell != null and contested_cell.get_node_or_null("StateMark") != null
			and (contested_cell.get_node("StateMark") as Label).text == Loc.t("ui.world_map.contested_mark"),
		"contested sector has a non-colour mark")
	_check(start_text.contains(Loc.f("ui.world_map.clash", [2])),
		"SIM clash is named in the start sector")
	_check(current != null and current.get_node_or_null("StateMark") != null
			and (current.get_node("StateMark") as Label).text == Loc.t("ui.world_map.clash_mark"),
		"clash mark wins over contested mark")

	# Panel size must fit 1280x800 and 1280x600 with margins.
	var panel_node = panel.get("_panel")
	var min_size: Vector2 = panel_node.get_combined_minimum_size() if panel_node != null else Vector2.ZERO
	_check(min_size.x <= 1280.0 and min_size.y <= 600.0,
		"панель влезает в 1280x600 (%.0fx%.0f)" % [min_size.x, min_size.y])

	# Focus: the 4-column grid assigns neighbours. Buttons are not focused yet;
	# only the neighbour links are checked here.
	var first = grid.get_child(0)
	_check(first != null and first.has_method("grab_focus"), "ячейка — кнопка с фокусом")
	if first != null:
		_check(first.focus_neighbor_right.is_empty() == false
			or first.focus_neighbor_bottom.is_empty() == false,
			"у ячейки есть сосед по фокусу")

	panel.close()
	await process_frame
	_check(not is_instance_valid(panel), "Esc/close уничтожает панель")
	_finish()


func _all_text(node: Node) -> String:
	var out := ""
	if node is Label:
		out += (node as Label).text
	if node is Button:
		out += (node as Button).text
	for ch in node.get_children():
		out += " " + _all_text(ch)
	return out


func _finish() -> void:
	print("")
	if _fails.is_empty():
		print("RESULT: OK world_map_ui_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL world_map_ui_smoke (%d checks, %d fails)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)
