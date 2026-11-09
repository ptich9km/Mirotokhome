class_name SoundDB
## Звуки игры: именованный ключ -> файл в assets/audio/sfx + шина + громкость.
##
## Индекс собирается `tests/gen_audio_db.py` из бесплатных CC0-паков
## (провенанс — `docs/audio-credits.md`). Числовые ID Аллодов больше не
## поддерживаются: `play(1)` молча вернёт false.
##
## Шины Music/SFX/UI/Voice/Ambient создаются в рантайме (см. `ensure_buses`),
## чтобы не трогать `project.godot` и не зависеть от `.tres` раскладки.
##
## Статический класс — не требует автозагрузки: пул плееров создаётся
## в корне сцены при первом проигрывании.

const DB_PATH := "res://assets/audio/sound_db.json"
const SFX_ROOT := "res://assets/audio/sfx/"
const POOL_SIZE := 16
const BUS_NAMES := ["Music", "SFX", "UI", "Voice", "Ambient"]

static var _keys: Dictionary = {}
static var _loaded := false
static var _bus: Node = null
static var _pool: Array = []
static var _round_robin := 0
static var _warned: Dictionary = {}

static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var f := FileAccess.open(DB_PATH, FileAccess.READ)
	if f == null:
		push_error("SoundDB: не открыть " + DB_PATH)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		var k: Variant = (parsed as Dictionary).get("keys", {})
		if k is Dictionary:
			_keys = k

## Есть ли такой ключ в индексе (для тестов и безопасных вызовов).
static func has(key: String) -> bool:
	ensure_loaded()
	return _keys.has(key)

## Проиграть звук по ключу. Неизвестный ключ/старый числовой ID — молча false.
static func play(id_or_key: Variant, volume_db: float = 0.0, pitch: float = 1.0) -> bool:
	if id_or_key is int or id_or_key is float:
		return false  # наследие Аллодов: числовые ID выведены из обращения
	var key := str(id_or_key)
	if key == "":
		return false
	ensure_loaded()
	var entry: Variant = _keys.get(key, null)
	if not (entry is Dictionary):
		_warn_once("key:" + key, "SoundDB: нет ключа " + key)
		return false
	var files: Variant = (entry as Dictionary).get("files", [])
	if not (files is Array) or (files as Array).is_empty():
		return false
	var rel := str((files as Array)[randi() % (files as Array).size()])
	var stream: Variant = load(SFX_ROOT + rel)
	if stream == null:
		_warn_once("file:" + rel, "SoundDB: не загрузить " + rel)
		return false
	if not _ensure_pool():
		return false
	var player := _borrow_player(str((entry as Dictionary).get("bus", "SFX")))
	if player == null:
		return false
	var jitter := float((entry as Dictionary).get("pitch_jitter", 0.0))
	if jitter > 0.0:
		pitch *= randf_range(1.0 - jitter, 1.0 + jitter)
	player.stream = stream
	player.volume_db = volume_db + float((entry as Dictionary).get("gain_db", 0.0))
	player.pitch_scale = clampf(pitch, 0.25, 4.0)
	player.play()
	return true

## Dialogue line with an optional race-specific take: "voice.npc.inn.ork.3"
## when it exists, otherwise the shared "voice.npc.inn.3" (human is the base).
static func raced_key(base: String, race: String, index: int) -> String:
	var key := "%s.%d" % [base, index]
	if race != "" and race != "human":
		var raced := "%s.%s.%d" % [base, race, index]
		if has(raced):
			key = raced
	return key

static func play_raced(base: String, race: String, index: int) -> bool:
	return play(raced_key(base, race, index))

## Случайная боль юнита (позиции [2]/[3] массива звуков).
static func play_pain(sounds: Array) -> void:
	var a: Variant = sound_at(sounds, 2)
	var b: Variant = sound_at(sounds, 3)
	var has_a := str(a) != ""
	var has_b := str(b) != ""
	if not has_a and not has_b:
		return
	if has_a and has_b:
		play(a if randi() % 2 == 0 else b)
	else:
		play(a if has_a else b)

## Ключ из массива юнита по позиции ("" если нет).
static func sound_at(sounds: Array, idx: int) -> Variant:
	if idx >= 0 and idx < sounds.size():
		return sounds[idx]
	return ""

## Создать шины и применить громкости из настроек. Идемпотентно.
static func ensure_buses() -> void:
	for name in BUS_NAMES:
		if AudioServer.get_bus_index(name) >= 0:
			continue
		var idx := AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, name)
		AudioServer.set_bus_send(idx, "Master")
	apply_volumes()

## Перечитать громкости шин (после изменения настроек).
static func apply_volumes() -> void:
	_set_bus("Music", Settings.music_volume())
	_set_bus("Ambient", Settings.music_volume())
	_set_bus("SFX", Settings.sfx_volume())
	_set_bus("UI", Settings.sfx_volume())
	_set_bus("Voice", Settings.voice_volume())

static func _set_bus(bus_name: String, linear: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	if linear <= 0.0001:
		AudioServer.set_bus_volume_db(idx, -80.0)
	else:
		AudioServer.set_bus_volume_db(idx, linear_to_db(clampf(linear, 0.0, 1.0)))

static func _warn_once(tag: String, message: String) -> void:
	if _warned.has(tag):
		return
	_warned[tag] = true
	push_warning(message)

static func _borrow_player(bus_name: String) -> AudioStreamPlayer:
	_ensure_pool()
	if _pool.is_empty():
		return null
	var p: AudioStreamPlayer = null
	for candidate in _pool:
		if not (candidate as AudioStreamPlayer).playing:
			p = candidate
			break
	if p == null:
		p = _pool[_round_robin % _pool.size()]
		_round_robin += 1
	if AudioServer.get_bus_index(bus_name) >= 0:
		p.bus = bus_name
	else:
		p.bus = "Master"
	return p

static func _ensure_pool() -> bool:
	if _bus != null and is_instance_valid(_bus):
		return true
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		_bus = null
		return false
	ensure_buses()
	_bus = Node.new()
	_bus.name = "SoundBus"
	_bus.tree_exiting.connect(_on_bus_exiting)
	tree.root.add_child(_bus)
	_pool.clear()
	for i in range(POOL_SIZE):
		var p := AudioStreamPlayer.new()
		p.name = "Sfx%02d" % i
		_bus.add_child(p)
		_pool.append(p)
	return true

## Статические ссылки на плееры держат AudioStream до самого выхода из игры;
## на выходе отпускаем их, чтобы не было «resources still in use at exit».
static func _on_bus_exiting() -> void:
	_pool.clear()
	_bus = null
