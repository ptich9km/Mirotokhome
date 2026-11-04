class_name Settings
extends RefCounted
## Настройки игрока: `user://settings.cfg`. Владеет файлом целиком.
##
## ## Почему не `assets/config/game.cfg`
##
## Тот файл — дев-тюнинг в git (12 секций, ~90 ключей, комментируется `;`),
## его крутит разработчик. Настройки игрока — другое: язык, звук, видео,
## переназначенные клавиши. Класть их в git нельзя, а `GameConfig` не умеет
## ни строки, ни запись в рантайме (`game_config.gd` — только `geti`/`getf` и
## write-once `seed_user_file`).
##
## ## Один владелец файла
##
## Язык тоже живёт здесь (`player/language`), и `Loc` обращается к нему через
## `Settings`. Это не украшение: если бы и `Loc`, и `Settings` писали в один
## `ConfigFile` каждый со своим кэшем, они бы затирали друг друга — `Loc`
## сохранил бы файл без звука.
##
## ## Атомарность
##
## Пишем во временный файл и только потом переименовываем. На Windows
## `rename` поверх существующего файла не атомарен, поэтому сначала удаляем
## старый; цена — микросекунды, выигрыш — настройки не теряются при обрыве.

const PATH := "user://settings.cfg"

const DEFAULT_MASTER_VOLUME := 0.8
const DEFAULT_UI_SCALE := 1.0
const UI_SCALE_MIN := 0.75
const UI_SCALE_MAX := 1.5

## Переназначаемые действия. Полный список `project.godot [input]` — 6 штук
## (move_click, attack_click, pause, cast_1..3). Действия создаются здесь
## списком, а не читаются из проекта: иначе в меню настроек появилось бы
## действие, для которого нет ни кнопки, ни подписи.
const REBINDABLE := [
	["move_click", "ui.keys.move_click"],
	["attack_click", "ui.keys.attack_click"],
	["pause", "ui.keys.pause"],
	["cast_1", "ui.keys.cast_1"],
	["cast_2", "ui.keys.cast_2"],
	["cast_3", "ui.keys.cast_3"],
]

static var _cfg: ConfigFile = null
static var _loaded := false


static func _cfg_get() -> ConfigFile:
	if _cfg != null:
		return _cfg
	_cfg = ConfigFile.new()
	_loaded = true
	var err := _cfg.load(PATH)
	if err != OK and err != ERR_FILE_NOT_FOUND:
		push_warning("Settings: %s не читается (ошибка %d) — беру значения по умолчанию"
			% [PATH, err])
		_cfg = ConfigFile.new()
	return _cfg


static func getf(section: String, key: String, fallback: float) -> float:
	var raw: Variant = _cfg_get().get_value(section, key, fallback)
	# JSON/CFG отдаёт числа как float — приводим явно, иначе дефолт не сработает
	# на битом файле и сравнение типов уронит тест.
	if raw is float or raw is int:
		return float(raw)
	return fallback


static func geti(section: String, key: String, fallback: int) -> int:
	var raw: Variant = _cfg_get().get_value(section, key, fallback)
	if raw is float or raw is int:
		return int(raw)
	return fallback


static func getb(section: String, key: String, fallback: bool) -> bool:
	return geti(section, key, 1 if fallback else 0) != 0


static func set_value(section: String, key: String, value: Variant) -> void:
	_cfg_get().set_value(section, key, value)


static func has(section: String, key: String) -> bool:
	return _cfg_get().has_section_key(section, key)


## Значение как строка — нужно `Loc`, у которого язык хранится строкой, а
## `ConfigFile` строки не отличает от чисел при чтении.
static func get_value(section: String, key: String, fallback: Variant = null) -> Variant:
	return _cfg_get().get_value(section, key, fallback)


# --- Звук ---

static func master_volume() -> float:
	return clampf(getf("audio", "master_volume", DEFAULT_MASTER_VOLUME), 0.0, 1.0)


static func set_master_volume(v: float) -> void:
	set_value("audio", "master_volume", clampf(v, 0.0, 1.0))


static func muted() -> bool:
	return getb("audio", "muted", false)


static func set_muted(on: bool) -> void:
	set_value("audio", "muted", 1 if on else 0)


## Громкость в дБ. `linear_to_db` даёт -inf при 0, поэтому ноль ->
## полное отключение, а не «очень тихо».
static func master_volume_db() -> float:
	if master_volume() <= 0.0001:
		return -80.0
	return linear_to_db(master_volume())


const DEFAULT_MUSIC_VOLUME := 0.7
const DEFAULT_SFX_VOLUME := 0.8
const DEFAULT_VOICE_VOLUME := 0.9


static func music_volume() -> float:
	return clampf(getf("audio", "music_volume", DEFAULT_MUSIC_VOLUME), 0.0, 1.0)


static func set_music_volume(v: float) -> void:
	set_value("audio", "music_volume", clampf(v, 0.0, 1.0))


static func sfx_volume() -> float:
	return clampf(getf("audio", "sfx_volume", DEFAULT_SFX_VOLUME), 0.0, 1.0)


static func set_sfx_volume(v: float) -> void:
	set_value("audio", "sfx_volume", clampf(v, 0.0, 1.0))


static func voice_volume() -> float:
	return clampf(getf("audio", "voice_volume", DEFAULT_VOICE_VOLUME), 0.0, 1.0)


static func set_voice_volume(v: float) -> void:
	set_value("audio", "voice_volume", clampf(v, 0.0, 1.0))


# --- Видео ---

static func fullscreen() -> bool:
	return getb("video", "fullscreen", false)


static func set_fullscreen(on: bool) -> void:
	set_value("video", "fullscreen", 1 if on else 0)


static func vsync() -> bool:
	return getb("video", "vsync", true)


static func set_vsync(on: bool) -> void:
	set_value("video", "vsync", 1 if on else 0)


static func ui_scale() -> float:
	return clampf(getf("video", "ui_scale", DEFAULT_UI_SCALE), UI_SCALE_MIN, UI_SCALE_MAX)


static func set_ui_scale(v: float) -> void:
	set_value("video", "ui_scale", clampf(v, UI_SCALE_MIN, UI_SCALE_MAX))


# --- Управление ---

## Код клавиши действия или 0, если не переопределено.
static func key_for(action: String) -> int:
	return geti("input", action, 0)


static func set_key_for(action: String, keycode: int) -> void:
	set_value("input", action, keycode)


## Действие уже занято другой клавишей? `except_action` исключает само себя,
## иначе повторное назначение той же клавиши считалось бы конфликтом.
static func conflict_for(keycode: int, except_action: String) -> String:
	for entry in REBINDABLE:
		var action := str(entry[0])
		if action == except_action:
			continue
		if key_for(action) == keycode:
			return action
	return ""


# --- Сохранение и применение ---

static func save() -> bool:
	var tmp := PATH + ".tmp"
	if _cfg_get().save(tmp) != OK:
		push_warning("Settings: не записать %s" % tmp)
		return false
	var da := DirAccess.open("user://")
	if da == null:
		push_warning("Settings: user:// недоступен")
		return false
	if da.rename(tmp, PATH) != OK:
		# Windows не переименовывает поверх существующего файла.
		da.remove(PATH)
		if da.rename(tmp, PATH) != OK:
			push_warning("Settings: не переименовать %s -> %s" % [tmp, PATH])
			return false
	return true


## Applies input, audio and video at startup. Must run before the first scene
## reads input; otherwise a saved rebind exists only in settings.cfg.
static func apply_all(root_window: Window) -> void:
	_apply_input()
	_apply_audio()
	if root_window != null:
		root_window.content_scale_factor = ui_scale()
	_apply_video()


## Public entry for tests and for scenes that only need the bindings.
static func apply_input() -> void:
	_apply_input()


## Replace the key event of every rebindable action that has a saved key.
## Actions without a saved key keep their project.godot defaults.
static func _apply_input() -> void:
	for entry in REBINDABLE:
		var action := str(entry[0])
		var key := key_for(action)
		if key <= 0 or not InputMap.has_action(action):
			continue
		for ev in InputMap.action_get_events(action):
			if ev is InputEventKey:
				InputMap.action_erase_event(action, ev)
		var e := InputEventKey.new()
		e.physical_keycode = key
		InputMap.action_add_event(action, e)


static func _apply_audio() -> void:
	var bus := AudioServer.get_bus_index("Master")
	if bus < 0:
		return
	AudioServer.set_bus_volume_db(bus, master_volume_db())
	AudioServer.set_bus_mute(bus, muted())


static func apply_audio() -> void:
	_apply_audio()


static func _apply_video() -> void:
	var want := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen() \
		else DisplayServer.WINDOW_MODE_WINDOWED
	var screen := DisplayServer.window_get_mode()
	if screen == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
		want = DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	if screen != want:
		DisplayServer.window_set_mode(want)
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if vsync() else DisplayServer.VSYNC_DISABLED)


static func apply_video(root_window: Window) -> void:
	_apply_video()
	if root_window != null:
		root_window.content_scale_factor = ui_scale()


## Сброс к значениям по умолчанию. Файл удаляется, чтобы не осталось
## «мусорных» ключей от прошлых раскладок.
static func reset_to_defaults() -> void:
	_cfg = ConfigFile.new()
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))


## Только для тестов: забыть кэш и прочитать файл заново.
static func reload_from_disk() -> void:
	_cfg = null
	_cfg_get()