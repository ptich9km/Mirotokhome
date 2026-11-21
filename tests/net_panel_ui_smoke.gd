extends SceneTree
##
## Network panel layout (22.11): the window must fit both reference heights
## (800 and 600) and both modes must show their controls: the connection form
## and, after the link is up, the list of saved co-op heroes.
##
## Run: godot --headless --path . --script res://tests/net_panel_ui_smoke.gd

var _checks := 0
var _fails: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print(("  OK  " if ok else "  FAIL") + " " + what)

func _panel_rect(panel: CanvasLayer) -> Rect2:
	# The centered PanelContainer is the only one inside the CenterContainer.
	var center := _find(panel, "CenterContainer")
	if center == null:
		return Rect2()
	for c in center.get_children():
		if c is PanelContainer:
			return (c as PanelContainer).get_global_rect()
	return Rect2()

func _find(node: Node, cls: String) -> Node:
	for c in node.get_children():
		if c.get_class() == cls:
			return c
		var deep := _find(c, cls)
		if deep != null:
			return deep
	return null

func _buttons(node: Node, out: Array) -> void:
	for c in node.get_children():
		if c is Button:
			out.append(c)
		_buttons(c, out)

func _run() -> void:
	NetSession.ensure()
	for size in [Vector2i(1280, 800), Vector2i(1280, 600)]:
		root.size = size
		var panel := NetPanel.new()
		root.add_child(panel)
		panel.open()
		await process_frame
		await process_frame
		var buttons: Array = []
		_buttons(panel, buttons)
		var texts: Array = []
		for b in buttons:
			texts.append(str((b as Button).text))
		_check(texts.has(Loc.t("ui.net.host")), "connect mode: host button at %s" % str(size))
		_check(texts.has(Loc.t("ui.net.join")), "connect mode: join button at %s" % str(size))
		var rect := _panel_rect(panel)
		_check(rect.size.y <= float(size.y) and rect.size.x <= float(size.x),
			"panel fits %s (is %s)" % [str(size), str(rect.size)])

		# Characters mode: the host's hero list.
		panel._open_characters()
		await process_frame
		await process_frame
		buttons.clear()
		texts.clear()
		_buttons(panel, buttons)
		for b in buttons:
			texts.append(str((b as Button).text))
		_check(texts.has(Loc.t("ui.net.char.create")),
			"characters mode: create button at %s" % str(size))
		var rect2 := _panel_rect(panel)
		_check(rect2.size.y <= float(size.y) and rect2.size.x <= float(size.x),
			"characters panel fits %s (is %s)" % [str(size), str(rect2.size)])
		panel.queue_free()
		await process_frame

	var session := NetSession.active()
	if session != null:
		session.leave()
	if _fails.is_empty():
		print("RESULT: OK net_panel_ui_smoke (%d checks)" % _checks)
		quit(0)
	else:
		print("RESULT: FAIL net_panel_ui_smoke (%d checks, %d failed)" % [_checks, _fails.size()])
		quit(1)
