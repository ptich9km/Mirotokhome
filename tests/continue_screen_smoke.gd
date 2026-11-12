extends SceneTree
## Smoke: загрузка из главного меню (перенос «Продолжить» с character_select).
##
## Запуск: godot --headless --path . --script res://tests/continue_screen_smoke.gd

var _fails: Array[String] = []
var _checks := 0

## The slots live in a scratch directory: a test run must never touch the
## saves of the player (`tests/save_sandbox.gd`).
const Sandbox := preload("res://tests/save_sandbox.gd")

func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
	print(("  OK  " if ok else "  FAIL") + " " + msg)

func _initialize() -> void:
	Sandbox.use_test_dir()
	_wipe()
	_run.call_deferred()

func _run() -> void:
	# --- 1. Без сейвов: все слоты пусты, кнопки disabled ---
	await _open_menu()
	var load_btn := _find_button(Loc.t("ui.menu.load_game"))
	_check(load_btn != null, "кнопка «%s»" % Loc.t("ui.menu.load_game"))
	if load_btn != null:
		load_btn.pressed.emit()
		await process_frame
		await create_timer(0.2).timeout
	var empty_slots := _count_slot_buttons(true)
	_check(empty_slots == 6, "без сейвов 6 пустых слотов (%d)" % empty_slots)
	var back := _find_button(Loc.t("ui.common.back"))
	if back != null:
		back.pressed.emit()
		await process_frame

	# --- 2. С сохранением: слот заполнен, apply_payload ---
	_write_save("slot_0", "Тестовый маг", 12, 5000)
	await _open_menu()
	load_btn = _find_button(Loc.t("ui.menu.load_game"))
	_check(load_btn != null, "кнопка «%s» (2)" % Loc.t("ui.menu.load_game"))
	if load_btn != null:
		load_btn.pressed.emit()
		await process_frame
		await create_timer(0.2).timeout
	var filled := _count_slot_buttons(false)
	_check(filled >= 1, "есть заполненный слот (%d)" % filled)
	var slot_btn := _find_filled_slot_button()
	_check(slot_btn != null, "найдена кнопка заполненного слота")
	if slot_btn != null:
		_check(str(slot_btn.text).contains("Тестовый маг"),
			"в подписи слота имя героя («%s»)" % str(slot_btn.text))
		var res := SaveSystem.load_slot("slot_0")
		var data: Dictionary = res.get("data", {})
		SaveSystem.apply_payload(data, null)
		_check(Game.hero_name == "Тестовый маг", "apply_payload: hero_name")
		_check(Game.map_seed == 777, "apply_payload: map_seed")
		_check(Game.hero_class == "mage", "apply_payload: hero_class")

	# --- 3. character_select без «Продолжить» ---
	var err := change_scene_to_file("res://scenes/character_select.tscn")
	await process_frame
	await create_timer(0.3).timeout
	var cs = current_scene
	if cs != null:
		_check(_find_button_in(cs, "Продолжить") == null
			and _find_button_in(cs, "Continue") == null,
			"character_select: «Продолжить» удалён")
		_check(_find_button_in(cs, Loc.t("ui.char.start")) != null,
			"character_select: «%s» на месте" % Loc.t("ui.char.start"))

	_wipe()
	_report()

func _open_menu() -> void:
	Game.hero_stats = {}
	var err := change_scene_to_file("res://scenes/main_menu.tscn")
	if err != OK:
		push_error("main_menu: %s" % err)
		return
	await process_frame
	await create_timer(0.35).timeout

func _write_save(slot: String, hero: String, day: int, stamp: int) -> void:
	SaveSystem.save(slot, {
		"version": SaveSystem.VERSION,
		"map": { "seed": 777, "zone": "mid" },
		"hero": {
			"class": "mage", "gender": "female", "name": hero,
			"character_id": "fmage", "stats": {"mind": 25}, "start_book": "book",
			"max_hp": 120, "max_mana": 80, "current_hp": 90, "current_mana": 40,
			"gold": 555, "inventory": [], "equipped": {}, "experience": {},
			"known_spells": {}, "sphere_books": {}, "position": Vector2(0, 0),
		},
		"world": { "day": day, "global_threat": 0.4, "relations": {}, "hero": {},
			"journal": [], "cities": {} },
		"quests": {},
		"meta": { "hero_name": hero, "hero_class": "mage", "level": 5, "day": day,
			"zone": "mid", "seed": 777, "stamp": stamp },
	})

## Slot row text is localized ("Слот %d — пусто" / "Slot %d — empty"): the row
## prefix and the empty marker come from the table, not from a hardcoded word.
func _slot_prefix() -> String:
	return str(Loc.t("ui.load.slot_empty").split("%")[0])


func _empty_mark() -> String:
	return str(Loc.t("ui.load.slot_empty").split("%d")[1]).strip_edges() \
		.trim_prefix("—").strip_edges()


func _count_slot_buttons(empty_only: bool) -> int:
	var mm = current_scene
	if mm == null:
		return 0
	var n := 0
	for b in _buttons_in(mm):
		var t := str((b as Button).text)
		if not t.contains(_slot_prefix()):
			continue
		var empty := t.contains(_empty_mark())
		if empty_only == empty:
			n += 1
	return n

func _find_filled_slot_button() -> Button:
	var mm = current_scene
	if mm == null:
		return null
	for b in _buttons_in(mm):
		var t := str((b as Button).text)
		if t.contains(_slot_prefix()) and not t.contains(_empty_mark()):
			return b
	return null

func _find_button(text: String) -> Button:
	return _find_button_in(current_scene, text)

func _find_button_in(node: Node, text: String) -> Button:
	if node == null:
		return null
	if node is Button and str((node as Button).text) == text:
		return node
	for c in node.get_children():
		var r := _find_button_in(c, text)
		if r != null:
			return r
	return null

func _buttons_in(node: Node) -> Array:
	var out: Array = []
	if node == null:
		return out
	if node is Button:
		out.append(node)
	for c in node.get_children():
		out.append_array(_buttons_in(c))
	return out

func _wipe() -> void:
	Sandbox.wipe()

func _report() -> void:
	if _fails.is_empty():
		print("RESULT: OK continue_screen_smoke (%d)" % _checks)
		quit(0)
	else:
		print("RESULT: FAIL (%d): %s" % [_fails.size(), str(_fails)])
		quit(1)
