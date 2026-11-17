class_name MusicDB
## Музыка: непрерывный плейлист на весь сеанс игры.
##
## Треки длинные (3+ минуты), поэтому «трек на ситуацию» не подходит: любой
## переход резал бы его на середине. Вместо этого — одна очередь, которая
## стартует с первого файла при запуске и идёт по кругу. Смена сцены и пауза
## очередь не трогают: узлы живут в корне дерева, таймер — с PROCESS_MODE_ALWAYS.
##
## Каждый трек играет целиком; за `crossfade` секунд до конца начинается
## следующий (два плеера). Луп у файла выключен: с ним очередь не дойдёт до
## следующего трека.
##
## База — `assets/audio/music_db.json` (v2): bus, gain_db, crossfade, playlist.

const DB_PATH := "res://assets/audio/music_db.json"
const ROOT := "res://assets/audio/music/"
const START_FADE := 1.5   # вход первого трека из тишины
const FALLBACK_FADE := 0.4  # если трек кончился раньше таймера

static var _playlist: Array[String] = []
static var _bus_name := "Music"
static var _gain_db := -8.0
static var _crossfade := 2.5
static var _loaded := false

static var _root: Node = null
static var _players: Array = []
static var _timer: Timer = null
## The running crossfade. Kept as a single reference so a new track can cancel
## the previous fade instead of leaving two tweens on the same property.
static var _fade: Tween = null
static var _active := 0
static var _index := -1
static var _current_file := ""
static var _started := false

static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var f := FileAccess.open(DB_PATH, FileAccess.READ)
	if f == null:
		push_error("MusicDB: не открыть " + DB_PATH)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return
	var d := parsed as Dictionary
	_bus_name = str(d.get("bus", "Music"))
	_gain_db = float(d.get("gain_db", -8.0))
	_crossfade = maxf(0.2, float(d.get("crossfade", 2.5)))
	_playlist.clear()
	var list: Variant = d.get("playlist", [])
	if list is Array:
		for item in list:
			var file := str(item).strip_edges()
			if file != "":
				_playlist.append(file)

static func playlist_size() -> int:
	ensure_loaded()
	return _playlist.size()

static func current_index() -> int:
	return _index

static func current_file() -> String:
	return _current_file

static func is_started() -> bool:
	return _started

## Запустить очередь с первого трека. Идемпотентно: повторные вызовы из
## _ready разных сцен не перезапускают музыку.
static func start_playlist() -> bool:
	ensure_loaded()
	if _playlist.is_empty():
		push_warning("MusicDB: пустой playlist в " + DB_PATH)
		return false
	if _started:
		return true
	if not _ensure_nodes():
		return false
	_started = true
	_index = -1
	return _play_index(0, START_FADE)

## Следующий трек очереди (для теста и ручной проверки). С конца — на первый.
static func next_track() -> bool:
	if not _started:
		return start_playlist()
	return _advance(_crossfade)

## Плавно остановить музыку и сбросить очередь.
## Stop the queue immediately and silence every player.
##
## The fade-out that used to live here is gone on purpose: a tween on the same
## `volume_db` could outlive the stop and then stop the NEXT track that had just
## started fading in. Two tracks at once on one bus was the measured symptom, so
## the stop is now a hard stop for all players.
static func stop() -> void:
	if _timer != null:
		_timer.stop()
	if _fade != null and _fade.is_valid():
		_fade.kill()
		_fade = null
	_started = false
	_index = -1
	_current_file = ""
	for raw in _players:
		var player := raw as AudioStreamPlayer
		if player != null and player.playing:
			player.stop()

static func _advance(fade_in: float) -> bool:
	if _playlist.is_empty():
		return false
	var next := (_index + 1) % _playlist.size()
	return _play_index(next, fade_in)

static func _play_index(i: int, fade_in: float) -> bool:
	if i < 0 or i >= _playlist.size():
		return false
	var rel := _playlist[i]
	var stream: Variant = load(ROOT + rel)
	if stream == null:
		push_warning("MusicDB: не загрузить " + rel)
		return false
	if stream is AudioStreamOggVorbis:
		# Луп выключен: очередь сама решает, когда начать следующий трек.
		(stream as AudioStreamOggVorbis).loop = false
	var old := _players[_active] as AudioStreamPlayer
	var next := _players[1 - _active] as AudioStreamPlayer
	next.stream = stream
	next.bus = _bus_name
	next.volume_db = -45.0
	next.play()
	# A previous fade must not survive: two live tweens fight over `volume_db`,
	# and a stale one stops the track that is currently fading IN (measured).
	if _fade != null and _fade.is_valid():
		_fade.kill()
	_fade = next.create_tween()
	_fade.set_parallel(true)
	_fade.tween_property(next, "volume_db", _gain_db, fade_in)
	# The old player is faded and stopped UNCONDITIONALLY. Asking `old.playing`
	# was wrong: while the tree is paused the property reads false, so the old
	# track was neither faded nor stopped and came back at full volume after the
	# unpause, playing on top of the new one for the rest of the session.
	# The crossfade lands in a pause by design (the TrackTimer is ALWAYS).
	_fade.tween_property(old, "volume_db", -45.0, fade_in)
	_fade.chain().tween_callback(old.stop)
	_active = 1 - _active
	_index = i
	_current_file = rel
	var length := (next.stream as AudioStream).get_length()
	if _timer != null:
		_timer.stop()
		_timer.wait_time = maxf(0.5, length - _crossfade)
		_timer.start()
	return true

static func _on_track_timer() -> void:
	# Таймер стоит на (длина − кроссфейд), поэтому текущий трек ещё играет.
	_advance(_crossfade)

static func _on_player_finished() -> void:
	# Страховка: если таймер опоздал и трек уже кончился, начинаем следующий
	# без ожидания. Сигнал от затухающего старого плеера игнорируем — активный
	# в этот момент ещё играет.
	if not _started or _players.is_empty():
		return
	var active := _players[_active] as AudioStreamPlayer
	if active.playing:
		return
	_advance(FALLBACK_FADE)

static func _ensure_nodes() -> bool:
	if _root != null and is_instance_valid(_root):
		return true
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return false
	SoundDB.ensure_buses()
	_root = Node.new()
	_root.name = "MusicBus"
	# The queue and the track players ignore the pause: the TrackTimer was always
	# running during a pause, so a crossfade could start while the tree was frozen.
	# Then `playing` read false on the old player, its fade-out never ran, and the
	# old track came back at full volume on top of the new one (measured 18.11).
	_root.process_mode = Node.PROCESS_MODE_ALWAYS
	_root.tree_exiting.connect(_on_root_exiting)
	tree.root.add_child(_root)
	_players.clear()
	for i in range(2):
		var p := AudioStreamPlayer.new()
		p.name = "Music%02d" % i
		p.bus = _bus_name
		p.volume_db = -45.0
		p.finished.connect(_on_player_finished)
		_root.add_child(p)
		_players.append(p)
	_timer = Timer.new()
	_timer.name = "TrackTimer"
	_timer.one_shot = true
	# Пауза игры (Esc) не должна останавливать очередь.
	_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_timer.timeout.connect(_on_track_timer)
	_root.add_child(_timer)
	_active = 0
	return true

## Сбросить статические ссылки при выходе, иначе AudioStream остаётся
## «в использовании» до выгрузки скрипта.
static func _on_root_exiting() -> void:
	if _timer != null:
		_timer.stop()
	_timer = null
	_fade = null
	_players.clear()
	_root = null
	_index = -1
	_current_file = ""
	_started = false
