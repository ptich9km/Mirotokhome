class_name SoundDB
## Game sounds: a named key -> file in assets/audio/sfx + bus + volume.
##
## The index is built by `tests/gen_audio_db.py` from free CC0 packs
## (provenance — `docs/audio-credits.md`). Allods numeric IDs are gone:
## `play(1)` silently returns false.
##
## Buses Music/SFX/UI/Voice/Ambient are created at runtime (see `ensure_buses`)
## so `project.godot` stays untouched and nothing depends on a `.tres` layout.
##
## A static class — no autoload needed: the player pool is created in the scene
## root on the first sound played.

const DB_PATH := "res://assets/audio/sound_db.json"
const SFX_ROOT := "res://assets/audio/sfx/"
const POOL_SIZE := 16
const BUS_NAMES := ["Music", "SFX", "UI", "Voice", "Ambient"]

## Music dip under a dialogue line. Speech and a track at the same level turn into
## mud; 6 dB is enough to hear the line and not so much that the track disappears.
## 0.0 switches ducking off.
const DUCK_DB := -6.0
const DUCK_ATTACK := 0.12   # fast: the line must not start over the full track
const DUCK_RELEASE := 0.35  # slow: a short dip would pump the music

static var _keys: Dictionary = {}
static var _loaded := false
static var _bus: Node = null
static var _pool: Array = []
static var _voice: AudioStreamPlayer = null
static var _voice_ducked := false
static var _duck_tween: Tween = null
static var _round_robin := 0
static var _warned: Dictionary = {}

static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var f := FileAccess.open(DB_PATH, FileAccess.READ)
	if f == null:
		push_error("SoundDB: cannot open " + DB_PATH)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		var k: Variant = (parsed as Dictionary).get("keys", {})
		if k is Dictionary:
			_keys = k

## Whether the index holds this key (for tests and safe call sites).
static func has(key: String) -> bool:
	ensure_loaded()
	return _keys.has(key)

## Play a sound by key. Unknown key / legacy numeric id — silent false.
static func play(id_or_key: Variant, volume_db: float = 0.0, pitch: float = 1.0) -> bool:
	if id_or_key is int or id_or_key is float:
		return false  # Allods legacy: numeric ids are out of use
	var key := str(id_or_key)
	if key == "":
		return false
	ensure_loaded()
	var entry: Variant = _keys.get(key, null)
	if not (entry is Dictionary):
		_warn_once("key:" + key, "SoundDB: no key " + key)
		return false
	var files: Variant = (entry as Dictionary).get("files", [])
	if not (files is Array) or (files as Array).is_empty():
		return false
	var rel := str((files as Array)[randi() % (files as Array).size()])
	var stream: Variant = load(SFX_ROOT + rel)
	if stream == null:
		_warn_once("file:" + rel, "SoundDB: cannot load " + rel)
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

## The same key in the UI language, when that take exists: "voice.npc.inn.3" ->
## "voice.en.npc.inn.3". Russian stays the reference; a missing English take
## falls back to it instead of going silent.
static func localized_key(key: String) -> String:
	if not key.begins_with("voice.") or key.begins_with("voice.en."):
		return key
	if Loc.locale() != "en":
		return key
	var en := "voice.en." + key.substr("voice.".length())
	return en if has(en) else key

## Play a dialogue line on the SINGLE voice channel.
##
## Unlike `play()`, a new line STOPS the previous one: clicking "Поговорить" twice
## used to start two speakers at once, and walking from the shop to the inn left
## the first merchant talking. The music bus also dips while a line plays — the
## hero's battle shout does NOT go through here, otherwise every swing would pump
## the track.
static func play_voice(key: String, volume_db: float = 0.0, pitch: float = 1.0) -> bool:
	key = localized_key(key)
	ensure_loaded()
	var entry: Variant = _keys.get(key, null)
	if not (entry is Dictionary):
		_warn_once("key:" + key, "SoundDB: no key " + key)
		return false
	var files: Variant = (entry as Dictionary).get("files", [])
	if not (files is Array) or (files as Array).is_empty():
		return false
	if not _ensure_pool():
		return false
	var player := _voice_player()
	if player == null:
		return false
	var rel := str((files as Array)[randi() % (files as Array).size()])
	var stream: Variant = load(SFX_ROOT + rel)
	if stream == null:
		_warn_once("file:" + rel, "SoundDB: cannot load " + rel)
		return false
	player.stop()
	player.stream = stream
	player.volume_db = volume_db + float((entry as Dictionary).get("gain_db", 0.0))
	player.pitch_scale = clampf(pitch, 0.25, 4.0)
	player.play()
	_duck(true)
	return true

## Silence the current line (the music returns to its level immediately).
static func stop_voice() -> void:
	if _voice != null and is_instance_valid(_voice) and _voice.playing:
		_voice.stop()
	_duck(false)

## Whether a dialogue line is playing right now (tests, panels).
static func is_voice_playing() -> bool:
	return _voice != null and is_instance_valid(_voice) and _voice.playing

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

## Same, but through the single voice channel (dialogue, not a bark).
static func play_raced_voice(base: String, race: String, index: int) -> bool:
	return play_voice(raced_key(base, race, index))

## Random unit pain sound (positions [2]/[3] of the unit sound array).
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

## A key from a unit's sound array by position ("" when absent).
static func sound_at(sounds: Array, idx: int) -> Variant:
	if idx >= 0 and idx < sounds.size():
		return sounds[idx]
	return ""

## Create the buses and apply the volumes from settings. Idempotent.
static func ensure_buses() -> void:
	for name in BUS_NAMES:
		if AudioServer.get_bus_index(name) >= 0:
			continue
		var idx := AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, name)
		AudioServer.set_bus_send(idx, "Master")
	apply_volumes()

## Re-read bus volumes (after a settings change). An active duck survives it:
## otherwise moving the music slider would undo the dip under a playing line.
static func apply_volumes() -> void:
	_set_bus("Music", Settings.music_volume())
	_set_bus("Ambient", Settings.music_volume())
	_set_bus("SFX", Settings.sfx_volume())
	_set_bus("UI", Settings.sfx_volume())
	_set_bus("Voice", Settings.voice_volume())
	if _voice_ducked and DUCK_DB != 0.0:
		for bus_name in ["Music", "Ambient"]:
			var idx := AudioServer.get_bus_index(bus_name)
			if idx >= 0:
				AudioServer.set_bus_volume_db(idx, _bus_target_db(bus_name, true))

static func _set_bus(bus_name: String, linear: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	AudioServer.set_bus_volume_db(idx, _linear_db(linear))

static func _linear_db(linear: float) -> float:
	if linear <= 0.0001:
		return -80.0
	return linear_to_db(clampf(linear, 0.0, 1.0))

## Where the bus must sit: the settings level, minus the dip when a line plays.
static func _bus_target_db(bus_name: String, ducked: bool) -> float:
	var linear := Settings.music_volume() if bus_name in ["Music", "Ambient"] \
		else Settings.sfx_volume()
	var db := _linear_db(linear)
	if ducked:
		db += DUCK_DB
	return db

## Dip (or release) the music/ambience under a dialogue line.
static func _duck(active: bool) -> void:
	_voice_ducked = active
	if DUCK_DB == 0.0:
		return
	if _bus == null or not is_instance_valid(_bus):
		return
	if _duck_tween != null and _duck_tween.is_valid():
		_duck_tween.kill()
	_duck_tween = _bus.create_tween()
	# Runs even when the tree is paused: a dip must not freeze mid-way.
	_duck_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_duck_tween.set_parallel(true)
	for bus_name in ["Music", "Ambient"]:
		var idx := AudioServer.get_bus_index(bus_name)
		if idx < 0:
			continue
		_duck_tween.tween_method(
			func(db: float) -> void: AudioServer.set_bus_volume_db(idx, db),
			AudioServer.get_bus_volume_db(idx), _bus_target_db(bus_name, active),
			DUCK_ATTACK if active else DUCK_RELEASE)

## The single voice player (created on first line).
static func _voice_player() -> AudioStreamPlayer:
	if _voice != null and is_instance_valid(_voice):
		return _voice
	_voice = AudioStreamPlayer.new()
	_voice.name = "Voice"
	_voice.bus = "Voice" if AudioServer.get_bus_index("Voice") >= 0 else "Master"
	_voice.finished.connect(_on_voice_finished)
	_bus.add_child(_voice)
	return _voice

static func _on_voice_finished() -> void:
	_duck(false)

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
	# ALWAYS: the tactical pause (Space, Esc menu, death screen) freezes the whole
	# tree, and INHERIT players froze with it — a line stopped on a syllable and
	# finished twenty seconds later, and a hit went silent until the pause ended.
	# Measured before the fix: 0.011 s of playback per second paused.
	_bus.process_mode = Node.PROCESS_MODE_ALWAYS
	_bus.tree_exiting.connect(_on_bus_exiting)
	tree.root.add_child(_bus)
	_pool.clear()
	for i in range(POOL_SIZE):
		var p := AudioStreamPlayer.new()
		p.name = "Sfx%02d" % i
		_bus.add_child(p)
		_pool.append(p)
	return true

## Static references hold the AudioStream until the game exits; release them on
## exit so the run does not end with "resources still in use at exit".
static func _on_bus_exiting() -> void:
	_pool.clear()
	_voice = null
	_bus = null
