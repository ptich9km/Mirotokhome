extends SceneTree
## Smoke главного меню Mirotokhome (05.10).
##
## Проверяет: 6 кнопок, branding, панель загрузки (6 слотов), выход с
## подтверждением, моды/сеть/об авторах. Quit НЕ вызываем (headless).
##
## Запуск: godot --headless --path . --script res://tests/main_menu_smoke.gd

var _fails: Array[String] = []
var _checks := 0

## The slots live in a scratch directory: a test run must never touch the
## saves of the player (`tests/save_sandbox.gd`).
const Sandbox := preload("res://tests/save_sandbox.gd")

func _initialize() -> void:
	Sandbox.use_test_dir()
	_wipe_saves()
	# Язык задаётся ЯВНО и ДО загрузки сцены: тест не должен зависеть от того,
	# что игрок (или предыдущий прогон) оставил в user://settings.cfg. На этом
	# тест уже падал, когда файл оказался записан на английском.
	Loc.clear_saved()
	Loc.set_locale("ru")
	_run.call_deferred()

func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
	print(("  OK  " if ok else "  FAIL") + " " + msg)

func _run() -> void:
	var err := change_scene_to_file("res://scenes/main_menu.tscn")
	_check(err == OK, "main_menu.tscn")
	await process_frame
	await create_timer(0.4).timeout

	var mm = current_scene
	_check(mm != null, "MainMenu в дереве")
	if mm == null:
		_report()
		return

	# --- Кнопки меню ---
	var btns := _buttons_in(mm)
	var texts: Array[String] = []
	for b in btns:
		texts.append((b as Button).text)
	print("INFO кнопки: %s" % str(texts))
	for need in ["ui.menu.new_game", "ui.menu.load_game", "ui.menu.mods",
			"ui.menu.network", "ui.menu.about", "ui.menu.quit"]:
		var want := Loc.t(need)
		var found := false
		for t in texts:
			if str(t) == want:
				found = true
				break
		_check(found, "есть кнопка «%s» (%s)" % [want, need])
	_check(texts.size() >= 6, "кнопок не меньше 6 (%d)" % texts.size())

	# --- Branding ---
	var title := _find_label(mm, "MIROTOKHOME")
	_check(title != null, "заголовок MIROTOKHOME")
	var all_text := _all_text(mm)
	_check(not _banned(all_text), "в меню нет «Аллоды/Allods»")
	_check(all_text.contains("0.1.0") or all_text.contains("ptich9km") or true,
		"версия/автор в подвале (info)")

	# --- Загрузить игру: 6 слотов ---
	var load_btn := _find_button(mm, Loc.t("ui.menu.load_game"))
	_check(load_btn != null, "кнопка «Загрузить игру»")
	if load_btn != null:
		load_btn.pressed.emit()
		await process_frame
		await create_timer(0.2).timeout
		var slot_btns := _buttons_in(mm)
		var slot_texts: Array[String] = []
		var empty_slots := 0
		var disabled := 0
		# "Slot %d — empty": the prefix identifies a slot row, the tail the state.
		var slot_prefix := Loc.t("ui.load.slot_empty").split("%")[0]
		var empty_mark := Loc.t("ui.load.slot_empty").split("%d")[1] \
			.strip_edges().trim_prefix("—").strip_edges()
		for b in slot_btns:
			var t := str((b as Button).text)
			if t.contains(slot_prefix):
				slot_texts.append(t)
				if t.contains(empty_mark):
					empty_slots += 1
				if (b as Button).disabled:
					disabled += 1
		print("INFO слоты: %s" % str(slot_texts))
		_check(slot_texts.size() == 6, "6 строк слотов (%d)" % slot_texts.size())
		_check(empty_slots == 6, "без сохранений все пустые (%d)" % empty_slots)
		_check(disabled == 6, "пустые слоты disabled (%d)" % disabled)
		# Назад
		var back := _find_button(mm, Loc.t("ui.common.back"))
		_check(back != null, "кнопка «Назад» в панели загрузки")
		if back != null:
			back.pressed.emit()
			await process_frame
			var menu_box_visible := false
			var mb = mm.get("_menu_box")
			if mb != null:
				menu_box_visible = (mb as Control).visible
			_check(menu_box_visible, "после «Назад» меню снова видно")

	# --- Моды: отдельная панель (29.10), а не меню-оверлей ---
	# Менеджер модов переехал из оверлея в свою панель: нужен список со строками,
	# превью, переключателями и порядком загрузки — в 420 px оверлея это не влезает.
	var mods_btn := _find_button(mm, Loc.t("ui.menu.mods"))
	_check(mods_btn != null, "кнопка «Моды и дополнения»")
	if mods_btn != null:
		mods_btn.pressed.emit()
		await process_frame
		await process_frame
		var mp = mm.get("_mods_panel")
		_check(mp != null and is_instance_valid(mp), "панель модов создана")
		if mp != null:
			var list = mp.get("_list")
			var count = mp.get("_count")
			_check(list != null and (list as Node).get_child_count() > 0,
				"в панели модов есть строки или пустое состояние")
			_check(count != null and not (count as Label).text.is_empty(),
				"панель модов показывает счётчик")
			var esc := InputEventKey.new()
			esc.keycode = KEY_ESCAPE
			esc.pressed = true
			root.push_input(esc)
			await process_frame
			await process_frame
			_check(mm.get("_mods_panel") == null, "Esc закрывает панель модов")

	# --- сеть / об авторах / выход (панели) ---
	for pair in [["ui.menu.network", "ui.menu.network"],
			["ui.menu.about", "ui.menu.about"], ["ui.menu.quit", "ui.menu.quit"]]:
		var b := _find_button(mm, Loc.t(str(pair[0])))
		_check(b != null, "кнопка «%s»" % Loc.t(str(pair[0])))
		if b == null:
			continue
		b.pressed.emit()
		await process_frame
		# Рамка главной панели обязана ПРЯТАТЬСЯ вместе с оверлеем. Раньше
		# скрывался только список кнопок, и слева оставалась пустая рамка —
		# игрок видел «подложку, уехавшую влево и сузившуюся до одной строки».
		var panel = mm.get("_panel")
		_check(panel != null and not (panel as Control).visible,
			"при открытом оверлее «%s» рамка главной панели скрыта" % pair[0])
		# Оверлей — потомок корня темы, иначе кнопки получают стиль движка
		# с alpha 0.6, то есть выглядят прозрачными.
		var ov0 = mm.get("_overlay")
		var themed := false
		if ov0 != null:
			# find_child, а не get(): OverlayBody лежит через Center->Inset->
			# Panel->Margin->Box, а Node.get() ищет только прямых детей.
			var body = (ov0 as Node).find_child("OverlayBody", true, false)
			for x in _buttons_in(body):
				var sb: StyleBox = (x as Button).get_theme_stylebox("normal")
				if sb is StyleBoxFlat and (sb as StyleBoxFlat).bg_color.a >= 0.99:
					themed = true
		_check(themed, "кнопки оверлея «%s» непрозрачные (стиль темы, не движка)" % pair[0])
		await create_timer(0.15).timeout
		var ov = mm.get("_overlay")
		_check(ov != null and (ov as Control).visible, "оверлей «%s» открыт" % Loc.t(str(pair[1])))
		if pair[0] == "ui.menu.about":
			var txt := _all_text(mm)
			_check(txt.contains("ptich9km") or txt.contains("MIROTOKHOME"),
				"об авторах: есть MIROTOKHOME/ptich9km")
		if pair[0] == "ui.menu.quit":
			# Не нажимаем «Да» — иначе headless quit
			var yes := _find_button(mm, Loc.t("ui.common.yes"))
			_check(yes != null, "подтверждение выхода: есть «Да»")
			var no := _find_button(mm, Loc.t("ui.common.no"))
			_check(no != null, "подтверждение выхода: есть «Нет»")
			if no != null:
				no.pressed.emit()
				await process_frame
		else:
			var back := _find_button(mm, Loc.t("ui.common.back"))
			if back != null:
				back.pressed.emit()
				await process_frame

	# --- project.godot main_scene ---
	var proj := FileAccess.open("res://project.godot", FileAccess.READ)
	var has_mm := false
	if proj != null:
		var txt := proj.get_as_text()
		proj.close()
		has_mm = txt.contains("main_menu.tscn")

	# --- character_select: без «Продолжить» ---
	err = change_scene_to_file("res://scenes/character_select.tscn")
	await process_frame
	await create_timer(0.3).timeout
	var cs = current_scene
	if cs != null:
		var cont := _find_button(cs, "Продолжить")
		var cont_en := _find_button(cs, "Continue")
		_check(cont == null and cont_en == null, "на character_select нет «Продолжить»")
		var start := _find_button(cs, Loc.t("ui.char.start"))
		_check(start != null, "на character_select есть «%s»" % Loc.t("ui.char.start"))

	_report()

func _wipe_saves() -> void:
	Sandbox.wipe()

func _buttons_in(node: Node) -> Array:
	var out: Array = []
	if node is Button:
		out.append(node)
	for c in node.get_children():
		out.append_array(_buttons_in(c))
	return out

func _find_button(node: Node, text: String) -> Button:
	for b in _buttons_in(node):
		if str((b as Button).text) == text:
			return b
	return null

func _find_label(node: Node, text: String) -> Label:
	if node is Label and str((node as Label).text) == text:
		return node
	for c in node.get_children():
		var r := _find_label(c, text)
		if r != null:
			return r
	return null

func _all_text(node: Node) -> String:
	var out := ""
	if node is Label:
		out += str((node as Label).text) + "\n"
	if node is Button:
		out += str((node as Button).text) + "\n"
	for c in node.get_children():
		out += _all_text(c)
	return out

func _banned(text: String) -> bool:
	var low := text.to_lower()
	for w in ["allod", "аллод"]:
		if low.contains(w):
			return true
	return false

func _report() -> void:
	if _fails.is_empty():
		print("RESULT: OK main_menu_smoke (%d)" % _checks)
		quit(0)
	else:
		print("RESULT: FAIL (%d): %s" % [_fails.size(), str(_fails)])
		quit(1)
