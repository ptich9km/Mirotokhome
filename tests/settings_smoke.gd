extends SceneTree
## Смоук окна настроек (scripts/settings.gd, scripts/settings_panel.gd).
##
## Закрывает то, что в настройках ломается тихо:
##
##  * **Файл настроек принадлежит ОДНОМУ классу.** Язык (`Loc`) и звук/видео
##    (`Settings`) писали бы в один `ConfigFile` с разными кэшами и затирали
##    друг друга. Проверяем: смена языка НЕ стирает громкость и наоборот.
##  * **Настройки переживают перезапуск**, иначе игрок настраивает каждый раз.
##  * **Битый файл не ломает игру** (та же политика, что у `GameConfig`).
##  * **Переназначение клавиш не создаёт конфликтов.** Две кнопки на одну
##    клавишу — это поломка управления, и её видно только в игре.
##  * **Переназначение реально дошло до InputMap**, а не осталось в файле.
##  * **Громкость реально применилась к шине Master**, а не записалась в файл.
##  * **Окно настроек открывается из главного меню** и закрывается по Esc.
##
## Запуск: godot --headless --path . --script res://tests/settings_smoke.gd

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)


func _run() -> void:
	_settings_store()
	_locale_and_settings_share_one_file()
	_corrupt_file_is_survivable()
	_audio_reaches_master_bus()
	_rebind_conflicts()
	_rebind_reaches_inputmap()
	_saved_rebind_applies_on_start()
	_gameplay_reads_actions()
	await _panel_opens_and_closes()

	Settings.reset_to_defaults()
	_report()
	quit(0 if _fails.is_empty() else 1)


# --- Хранилище ---

func _settings_store() -> void:
	Settings.reset_to_defaults()
	Settings.reload_from_disk()
	_check(absf(Settings.master_volume() - Settings.DEFAULT_MASTER_VOLUME) < 0.001,
		"громкость по умолчанию = %.2f" % Settings.DEFAULT_MASTER_VOLUME)
	_check(absf(Settings.ui_scale() - 1.0) < 0.001, "масштаб по умолчанию = 100%")
	_check(not Settings.fullscreen(), "полный экран по умолчанию выключен")
	_check(Settings.vsync(), "vsync по умолчанию включён")

	Settings.set_master_volume(0.35)
	Settings.set_ui_scale(1.25)
	Settings.set_fullscreen(true)
	_check(Settings.save(), "настройки записаны в %s" % Settings.PATH)
	_check(FileAccess.file_exists(Settings.PATH), "файл настроек существует")

	Settings.reload_from_disk()
	_check(absf(Settings.master_volume() - 0.35) < 0.01,
		"громкость пережила перезапуск (%.2f)" % Settings.master_volume())
	_check(absf(Settings.ui_scale() - 1.25) < 0.01,
		"масштаб пережил перезапуск (%.2f)" % Settings.ui_scale())
	_check(Settings.fullscreen(), "полный экран пережил перезапуск")

	# Границы: движок не должен принять -5 или 99.
	Settings.set_ui_scale(9.0)
	_check(Settings.ui_scale() <= Settings.UI_SCALE_MAX,
		"масштаб зажат сверху (%.2f <= %.2f)" % [Settings.ui_scale(), Settings.UI_SCALE_MAX])
	Settings.set_ui_scale(0.1)
	_check(Settings.ui_scale() >= Settings.UI_SCALE_MIN,
		"масштаб зажат снизу (%.2f >= %.2f)" % [Settings.ui_scale(), Settings.UI_SCALE_MIN])
	Settings.set_master_volume(-3.0)
	_check(Settings.master_volume() >= 0.0, "громкость не уходит в минус")


## Главный риск общего файла: один класс стирает настройки другого.
func _locale_and_settings_share_one_file() -> void:
	Settings.reset_to_defaults()
	Settings.reload_from_disk()
	Loc.clear_saved()
	Loc.set_locale("en")
	Settings.set_master_volume(0.44)
	_check(Settings.save(), "сохранили настройки")
	_check(Loc.save_locale(), "сохранили язык")

	Loc.load_locale()
	Settings.reload_from_disk()
	_check(Loc.locale() == "en", "язык сохранён")
	_check(absf(Settings.master_volume() - 0.44) < 0.01,
		"смена языка НЕ стёрла громкость (%.2f)" % Settings.master_volume())

	Settings.set_master_volume(0.22)
	_check(Settings.save(), "снова сохранили настройки")
	Loc.load_locale()
	_check(Loc.locale() == "en",
		"смена громкости НЕ стёрла язык (%s)" % Loc.locale())
	Loc.set_locale("ru")
	Loc.save_locale()
	Settings.reset_to_defaults()
	Settings.reload_from_disk()
	Loc.clear_saved()


func _corrupt_file_is_survivable() -> void:
	var f := FileAccess.open(Settings.PATH, FileAccess.WRITE)
	f.store_string("[audio]\nmaster_volume=не число\n[[[")
	f.close()
	Settings.reload_from_disk()
	_check(absf(Settings.master_volume() - Settings.DEFAULT_MASTER_VOLUME) < 0.001,
		"битый файл -> громкость по умолчанию, а не падение (%.2f)"
			% Settings.master_volume())
	Loc.load_locale()
	_check(Loc.locale() == "ru", "битый файл -> язык по умолчанию")
	Settings.reset_to_defaults()
	Settings.reload_from_disk()
	Loc.clear_saved()


## Громкость должна влиять на шину Master, а не только лежать в файле.
func _audio_reaches_master_bus() -> void:
	Settings.reset_to_defaults()
	Settings.set_master_volume(0.5)
	Settings.set_muted(false)
	Settings.apply_audio()
	var bus := AudioServer.get_bus_index("Master")
	_check(bus >= 0, "шина Master существует")
	if bus < 0:
		return
	var db := AudioServer.get_bus_volume_db(bus)
	var want := linear_to_db(0.5)
	_check(absf(db - want) < 0.01,
		"громкость 0.5 -> %.2f дБ (ожидалось %.2f)" % [db, want])
	Settings.set_muted(true)
	Settings.apply_audio()
	_check(AudioServer.is_bus_mute(bus), "mute применён к шине")
	Settings.set_muted(false)
	Settings.set_master_volume(0.0)
	Settings.apply_audio()
	_check(AudioServer.get_bus_volume_db(bus) < -60.0,
		"нулевая громкость не «очень тихо», а -80 дБ (%.1f)"
			% AudioServer.get_bus_volume_db(bus))
	Settings.reset_to_defaults()
	Settings.reload_from_disk()
	Settings.apply_audio()


# --- Клавиши ---

func _rebind_conflicts() -> void:
	Settings.reset_to_defaults()
	Settings.reload_from_disk()
	var actions: Array = []
	for e in Settings.REBINDABLE:
		actions.append(str(e[0]))
	_check(actions.size() >= 4, "переназначаемых действий хотя бы 4 (=%d)" % actions.size())
	for a in actions:
		_check(InputMap.has_action(str(a)),
			"действие %s есть в InputMap" % a)

	Settings.set_key_for("pause", KEY_F5)
	_check(Settings.key_for("pause") == KEY_F5, "клавиша записана в настройки")
	_check(Settings.conflict_for(KEY_F5, "pause") == "",
		"своя же клавиша не считается конфликтом")
	_check(Settings.conflict_for(KEY_F5, "move_click") == "pause",
		"чужое действие найдено как конфликт")

	Settings.reset_to_defaults()
	Settings.reload_from_disk()
	_check(Settings.key_for("pause") == 0, "сброс вернул клавиши к умолчанию")


## Назначение должно реально менять InputMap, иначе файл изменится, а игра нет.
func _rebind_reaches_inputmap() -> void:
	Settings.reset_to_defaults()
	Settings.reload_from_disk()
	var packed: PackedScene = load("res://scenes/main_menu.tscn")
	if packed == null:
		_check(false, "main_menu.tscn загружается")
		return
	var menu = packed.instantiate()
	root.add_child(menu)
	await process_frame
	await process_frame

	var panel = menu.find_child("SettingsPanel", true, false)
	_check(panel == null, "окно настроек не открыто само")

	# Кнопку ищем по ключу перевода, а не по имени узла: Godot выедает точки,
	# и `ui.menu.settings` в имени узла становится `ui_menu_settings`.
	var btn = menu.menu_button("ui.menu.settings")
	_check(btn != null, "кнопка «Настройки» есть в меню")
	if btn != null:
		(btn as Button).pressed.emit()
		await process_frame
		await process_frame

	panel = menu.find_child("SettingsPanel", true, false)
	_check(panel != null, "окно настроек открылось")
	if panel == null:
		menu.queue_free()
		await process_frame
		return

	# Переходим на вкладку «Управление» — теперь она четвёртая (Tab3):
	# вкладку «Магия» вставили ПЕРЕД ней 27.10.
	var tab2 = panel.find_child("Tab3", true, false)
	_check(tab2 is Button, "вкладка «Управление» есть")
	if tab2 is Button:
		(tab2 as Button).pressed.emit()
		await process_frame

	var key_pause = panel.find_child("Key_pause", true, false)
	_check(key_pause is Button, "кнопка переназначения для pause есть")
	if key_pause is Button:
		(key_pause as Button).pressed.emit()
		await process_frame
		# Ключ приходит событием, а не вызовом метода.
		var ev := InputEventKey.new()
		ev.pressed = true
		ev.keycode = KEY_F7
		panel.call("_on_unhandled_input", ev)
		await process_frame
		_check(Settings.key_for("pause") == KEY_F7,
			"назначение дошло до настроек (%d)" % Settings.key_for("pause"))
		var in_map := false
		for e in InputMap.action_get_events("pause"):
			if e is InputEventKey and (e as InputEventKey).physical_keycode == KEY_F7:
				in_map = true
		_check(in_map, "назначение дошло до InputMap")

		# Конфликт: F7 теперь занят pause.
		Settings.set_key_for("pause", KEY_F7)
		var ev2 := InputEventKey.new()
		ev2.pressed = true
		ev2.keycode = KEY_F7
		if key_pause is Button:
			(key_pause as Button).pressed.emit()
			await process_frame
		panel.call("_on_unhandled_input", ev2)
		await process_frame
		var status = panel.find_child("Status", true, false)
		_check(Settings.key_for("pause") == KEY_F7,
			"конфликт не перезаписал назначение")
		_check(status is Label and (status as Label).text != "",
			"о конфликте сообщено игроку")

	# Esc закрывает окно настроек, а не выкидывает в главное меню.
	var ev3 := InputEventKey.new()
	ev3.pressed = true
	ev3.keycode = KEY_ESCAPE
	panel.call("_input", ev3)
	await process_frame
	await process_frame
	_check(menu.find_child("SettingsPanel", true, false) == null,
		"Esc закрыл окно настроек")
	_check(menu.menu_button("ui.menu.new_game") != null,
		"после закрытия меню осталось целым")

	menu.queue_free()
	await process_frame
	Settings.reset_to_defaults()
	Settings.reload_from_disk()


## Persisted key must be applied at startup, not only in the panel's session.
func _saved_rebind_applies_on_start() -> void:
	Settings.reset_to_defaults()
	Settings.reload_from_disk()
	Settings.set_key_for("pause", KEY_F8)
	Settings.save()
	Settings.reload_from_disk()
	# Simulate a fresh process: project defaults, then startup apply.
	InputMap.load_from_project_settings()
	Settings.apply_input()
	var found := false
	for e in InputMap.action_get_events("pause"):
		if e is InputEventKey and (e as InputEventKey).physical_keycode == KEY_F8:
			found = true
	_check(found, "сохранённая клавиша применилась при старте (F8)")

	InputMap.load_from_project_settings()
	Settings.reset_to_defaults()
	Settings.reload_from_disk()


## Gameplay must read the six actions, not raw keycodes. This guards the exact
## regressions the audit found: pause on Space and slot 1 as cast_1.
func _gameplay_reads_actions() -> void:
	Settings.reset_to_defaults()
	Settings.reload_from_disk()
	InputMap.load_from_project_settings()
	Settings.apply_input()
	var game = load("res://scripts/game.gd").new()

	var space := InputEventKey.new()
	space.pressed = true
	space.keycode = KEY_SPACE
	_check(space.is_action_pressed("pause"), "Space — это действие pause")

	var one := InputEventKey.new()
	one.pressed = true
	one.keycode = KEY_1
	_check(game.call("_cast_slot_of", one) == 0, "1 — это слот cast_1")

	Settings.set_key_for("cast_1", KEY_Q)
	Settings.apply_input()
	var q := InputEventKey.new()
	q.pressed = true
	q.keycode = KEY_Q
	q.physical_keycode = KEY_Q
	_check(game.call("_cast_slot_of", q) == 0, "Q после переназначения — слот cast_1")
	_check(game.call("_cast_slot_of", one) == -1,
		"старая 1 больше не кастует слот 0 после переназначения")

	# 4..9 остаются фиксированными до появления cast_4..9.
	var four := InputEventKey.new()
	four.pressed = true
	four.keycode = KEY_4
	_check(game.call("_cast_slot_of", four) == 3, "4 остаётся слотом 4")

	game.free()
	InputMap.load_from_project_settings()
	Settings.reset_to_defaults()
	Settings.reload_from_disk()


# --- Окно ---

func _panel_opens_and_closes() -> void:
	var panel := SettingsPanel.new()
	panel.setup()
	root.add_child(panel)
	await process_frame
	await process_frame

	_check(panel.get("_root") != null, "панель настроек собрана")
	var tabs: Array = panel.get("_tab_buttons")
	_check(tabs.size() == 4, "четыре раздела: графика, звук, магия, управление (=%d)" % tabs.size())

	# Каждый раздел обязан что-то содержать: пустой вкладкой считать нельзя.
	for i in range(tabs.size()):
		var b: Button = tabs[i]
		b.pressed.emit()
		await process_frame
		var body = panel.get("_body")
		_check(body is VBoxContainer and (body as VBoxContainer).get_child_count() > 0,
			"раздел %d непустой" % i)

	# Раздел «Магия»: уровень авто-волшебства и цель меняют статики Game.
	(tabs[2] as Button).pressed.emit()
	await process_frame
	var base_btn = panel.find_child("Opt_base", true, false)
	var max_btn = panel.find_child("Opt_max", true, false)
	var self_btn = panel.find_child("Opt_self", true, false)
	_check(base_btn is Button, "кнопка уровня «Базовое» есть")
	_check(max_btn is Button, "кнопка уровня «Максимальное» есть")
	_check(self_btn is Button, "кнопка цели «Только я» есть")
	Game.auto_buff_tier = "base"
	Game.auto_targets = "party"
	if max_btn is Button:
		(max_btn as Button).pressed.emit()
		await process_frame
		_check(Game.auto_buff_tier == "max", "нажатие уровня меняет Game.auto_buff_tier")
	# После нажатия панель пересобирает раздел (подсветка активного варианта),
	# поэтому прежняя ссылка на кнопку уже освобождена — ищем заново.
	var self_btn2 = panel.find_child("Opt_self", true, false)
	if self_btn2 is Button:
		(self_btn2 as Button).pressed.emit()
		await process_frame
		_check(Game.auto_targets == "self", "нажатие цели меняет Game.auto_targets")
	Game.auto_buff_tier = "base"
	Game.auto_targets = "party"

	# Esc.
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.keycode = KEY_ESCAPE
	panel.call("_input", ev)
	await process_frame
	await process_frame
	_check(not is_instance_valid(panel) or panel.is_queued_for_deletion(),
		"Esc закрывает панель")

	Settings.reset_to_defaults()
	Settings.reload_from_disk()


func _report() -> void:
	print("RESULT: %s settings_smoke (проверок: %d, провалов: %d)"
			% ["OK" if _fails.is_empty() else "FAIL", _checks, _fails.size()])
	for f in _fails:
		print("  FAIL " + f)