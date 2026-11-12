extends SceneTree
## Two-step hero creation and the direction rules (04.11).
##
## Step 1 — identity (race, class/gender cards, name). Step 2 — development:
## only the class's own five directions, the main at 20, the auxiliary at 10,
## everything else at 0. Astral and Shooting are auxiliary and can never be
## chosen as the main direction. The starter weapon follows the direction and
## is bronze.
##
## Run: godot --headless --path . --script res://tests/character_select_flow_smoke.gd

const SIZES := [Vector2i(1280, 800), Vector2i(1280, 600)]

var _fails: Array[String] = []
var _checks := 0


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print("FLOW: %s %s" % ["ok  " if ok else "FAIL", what])


func _run() -> void:
	var packed: PackedScene = load("res://scenes/character_select.tscn")
	var cs = packed.instantiate()
	root.add_child(cs)
	for i in range(6):
		await process_frame

	await _warrior(cs)
	await _mage(cs)
	await _layout(cs, true)
	await _escape(cs)
	await _layout(cs, false)

	print("")
	if _fails.is_empty():
		print("RESULT: OK character_select_flow_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL character_select_flow_smoke (%d checks, %d fails)"
			% [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)


func _warrior(cs) -> void:
	_check(cs._step1_box.visible and not cs._step2_box.visible, "старт на шаге 1")
	_check(cs._next_btn != null and cs._next_btn.text == Loc.t("ui.char.next"),
		"на шаге 1 есть «Далее: развитие»")
	_check(cs._dir_buttons.size() == 4, "у воина 4 основных направления (получено %d)"
		% cs._dir_buttons.size())
	_check(not cs._dir_buttons.has("fire"), "магия не предлагается воину")
	_check(not cs._dir_buttons.has("shooting"), "стрельба не основное умение")
	_check(int(cs._edit.get("blade", -1)) == 20, "меч = 20")
	_check(int(cs._edit.get("shooting", -1)) == 10, "стрельба = 10")
	_check(int(cs._edit.get("axe", -1)) == 0, "топор = 0")
	_check(str(cs._edit.get("weapon", "")) == "sword", "стартовое оружие — меч")

	cs._show_step(2)
	await process_frame
	_check(cs._step2_box.visible and not cs._step1_box.visible, "«Далее» переводит на шаг 2")

	cs._pick_direction("bludgeon")
	await process_frame
	_check(str(cs._selected_primary) == "bludgeon", "выбрана булава")
	_check(int(cs._edit.get("bludgeon", -1)) == 20, "булава = 20")
	_check(int(cs._edit.get("blade", -1)) == 0, "меч сброшен в 0")
	_check(int(cs._edit.get("shooting", -1)) == 10, "стрельба осталась 10")
	_check(str(cs._edit.get("weapon", "")) == "club", "стартовое оружие — булава")
	var text := _detail_text(cs)
	_check(text.contains(Loc.t("ui.skill.bludgeon")), "в описании есть название")
	_check(text.contains("125"), "описание обещает 125% (тип существа — из данных карточки)")
	_check(text.contains("75"), "описание обещает 75% (тип существа — из данных карточки)")
	_check(text.to_lower().contains("bronze") or text.to_lower().contains("бронз"),
		"описание показывает бронзовое оружие")
	_check(text.contains(_part_label(Loc.t("ui.char.hp_def_abs"), 1) + " 16"),
		"защита с бронзовым щитом = 16")
	var kit: Array = cs._starter_keys("warrior", "bludgeon")
	_check(kit.has("Common bronze Mace"), "в наборе бронзовая булава")
	_check(kit.has("Common bronze Buckler"), "у мужского воина есть бронзовый щит")
	_check(kit.has("Potion Medium Healing"), "в наборе есть лечебные зелья")


func _mage(cs) -> void:
	# Card index 2 is the male mage (warrior male/female, mage male/female).
	cs._select(2)
	await process_frame
	_check(cs._dir_buttons.size() == 4, "у мага 4 основных школы (получено %d)"
		% cs._dir_buttons.size())
	_check(cs._dir_buttons.has("fire") and cs._dir_buttons.has("water"),
		"школы огня и воды предложены")
	_check(not cs._dir_buttons.has("astral"), "астрал не основная школа")
	_check(int(cs._edit.get("fire", -1)) == 20, "огонь = 20 по умолчанию")
	_check(int(cs._edit.get("astral", -1)) == 10, "астрал = 10 (вспомогательный)")
	_check(int(cs._edit.get("blade", -1)) == 0, "меч у мага = 0")
	_check(str(cs._edit.get("weapon", "")) == "staff", "стартовое оружие — посох")

	cs._pick_direction("astral")
	await process_frame
	_check(str(cs._selected_primary) == "fire", "астрал не становится основным")
	_check(_detail_text(cs).contains("60%"), "астрал описан как 60% прибавки")

	cs._pick_direction("water")
	await process_frame
	_check(str(cs._selected_primary) == "water", "вода — основная школа")
	_check(int(cs._edit.get("water", -1)) == 20, "вода = 20")
	_check(int(cs._edit.get("fire", -1)) == 0, "огонь сброшен в 0")
	_check(int(cs._edit.get("astral", -1)) == 10, "астрал остался 10")
	var mage_text := _detail_text(cs)
	_check(mage_text.contains(_part_label(Loc.t("ui.char.hp_mana"), 0) + " 97"),
		"жизнь мага с направлением = 97")
	_check(mage_text.contains(_part_label(Loc.t("ui.char.hp_mana"), 1) + " 71"),
		"мана мага с направлением = 71")

	var kit: Array = cs._starter_keys("mage", "water")
	_check(kit.has("Common Wood Staff"), "у мага деревянный посох")
	var has_book := false
	for k in kit:
		if str(k).begins_with("Book "):
			has_book = true
	_check(has_book, "у мага в наборе книга школы")


## Label of one numeric segment of a localized template: `_part_label(t, 1)` on
## "Жизнь: %d · Защита: %d" gives "Защита:" (and "Defence:" in English).
func _part_label(template: String, index: int) -> String:
	var parts := template.split("%d")
	if index >= parts.size():
		return ""
	var s := str(parts[index]).strip_edges()
	while s.begins_with("·"):
		s = s.substr(1).strip_edges()
	var colon := s.find(":")
	return s.substr(0, colon + 1) if colon >= 0 else s


func _detail_text(cs) -> String:
	var out := ""
	for c in cs._dir_detail.get_children():
		if c is Label:
			out += str((c as Label).text) + "\n"
	return out


## Whole visible interface must stay inside the window on both steps.
func _layout(cs, step2: bool) -> void:
	if step2:
		cs._show_step(2)
	else:
		cs._show_step(1)
	await process_frame
	for size_px: Vector2i in SIZES:
		root.size = size_px
		for i in range(4):
			await process_frame
		var win := root.get_visible_rect()
		var worst := ""
		for node in _walk(cs):
			var c := node as Control
			if c == null or not c.is_visible_in_tree():
				continue
			if _inside_scroll(c):
				continue
			var r := Rect2(c.global_position, c.size)
			if r.size.x <= 0.0 or r.size.y <= 0.0:
				continue
			if not win.encloses(r):
				worst = "%s %s" % [c.get_path(), r]
				break
		_check(worst == "", "[%s %s] всё внутри окна%s"
			% ["шаг 2" if step2 else "шаг 1", str(size_px),
				"" if worst == "" else " — " + worst])


func _inside_scroll(c: Control) -> bool:
	var p := c.get_parent()
	while p != null:
		if p is ScrollContainer:
			return true
		p = p.get_parent()
	return false


func _walk(node: Node) -> Array:
	var out: Array = [node]
	for child in node.get_children():
		out.append_array(_walk(child))
	return out


func _escape(cs) -> void:
	cs._show_step(2)
	await process_frame
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.physical_keycode = KEY_ESCAPE
	ev.pressed = true
	root.push_input(ev)
	var up := ev.duplicate()
	up.pressed = false
	root.push_input(up)
	for i in range(3):
		await process_frame
	_check(is_instance_valid(cs) and cs.is_inside_tree(), "Esc не уводит со сцены")
	_check(cs._step1_box.visible, "Esc с шага 2 возвращает на шаг 1")
