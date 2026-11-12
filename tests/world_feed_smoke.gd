extends SceneTree
## Лента мира (F3): заголовок, лента, отладка, доли вьюпорта (23.10).
##
## Запуск: godot --headless --path . --script res://tests/world_feed_smoke.gd

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
	Game.world_seed = 4242
	Game.map_sector = "s41"
	Game.map_zone = "start"
	Game.map_seed = 12345
	MapGenerator.last_stats = {
		"source": "generated", "total_ms": 1200,
		"phases": {"1": 120, "2": 90}, "size": 96,
		"sector": "s41", "gen_version": 31,
	}
	var wf = load("res://scripts/world/world_feed.gd")
	wf.clear()
	wf.post("world", "first message")
	for i in range(12):
		wf.post("sim", "event %d" % i)

	var script: GDScript = load("res://scripts/world_feed_panel.gd")
	var panel = script.new()
	panel.setup()
	root.add_child(panel)
	await process_frame
	await process_frame

	var box = panel.get("_panel")
	var label = panel.get("_text")
	_check(box != null and box.visible, "лента видна по умолчанию")
	_check(box != null and box.offset_left == 2.0, "отступ слева 2 px")
	_check(box != null and box.offset_bottom == -2.0, "отступ снизу 2 px")
	_check(box != null and box.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"лента не перехватывает мышь")
	var vp: Vector2 = root.get_visible_rect().size
	var want_w := clampf(vp.x * 0.28, 320.0, 460.0)
	var want_h := clampf(vp.y * 0.25, 170.0, 280.0)
	_check(box != null and absf((box.offset_right - box.offset_left) - want_w) < 1.0,
		"ширина — 28%% вьюпорта (%.0f)" % want_w)
	_check(box != null and absf((box.offset_bottom - box.offset_top) - want_h) < 1.0,
		"высота — 25%% вьюпорта (%.0f)" % want_h)

	var text := str(label.text if label != null else "")
	var wm = load("res://scripts/world/world_map.gd")
	var sector_name_key := str(wm.sector("s41").get("name_key", ""))
	var sector_name := Loc.t(sector_name_key)
	_check(sector_name != "" and text.contains(sector_name),
		"имя сектора в заголовке (%s)" % sector_name)
	_check(text.contains("FPS"), "FPS в заголовке одной строкой")
	# The day prefix lives in the locale table and was capitalized during the
	# English pass: take the marker from the table instead of hardcoding the
	# Russian word, or this guard fails on a translation tweak, not on a bug.
	var day_pat := Loc.t("ui.feed.day")
	var day_mark := day_pat.substr(0, day_pat.find("%"))
	_check(text.contains(day_mark), "единый формат [день N]")
	_check(text.contains(Loc.t("ui.feed.kind.sim")), "префикс SIM")
	_check(text.contains("event 11"), "последнее сообщение видно")
	_check(not text.contains("first message"), "старые сообщения вытеснены (6–8 строк)")
	_check(not text.contains("gen 1200ms"), "технические цифры скрыты без F3")

	var f3 := InputEventKey.new()
	f3.keycode = KEY_F3
	f3.pressed = true
	panel._input(f3)
	await process_frame
	var dbg := str(label.text if label != null else "")
	_check(dbg.contains("gen 1200ms"), "F3 показывает технические цифры")
	_check(dbg.contains("npc "), "F3 показывает NPC/кадры")

	# Второе нажатие убирает отладку, лента остаётся.
	panel._input(f3)
	await process_frame
	var off := str(label.text if label != null else "")
	_check(not off.contains("gen 1200ms"), "повторный F3 скрывает отладку")
	_check(off.contains(day_mark), "лента остаётся после выключения отладки")

	# Данные болтовни читаются.
	var data: Dictionary = panel.get("_data")
	_check(not data.is_empty() and (data.get("generic", []) as Array).size() >= 5,
		"файл болтовни НПЦ загружен")

	panel.queue_free()
	print("")
	if _fails.is_empty():
		print("RESULT: OK world_feed_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL world_feed_smoke (%d checks, %d fails)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)
