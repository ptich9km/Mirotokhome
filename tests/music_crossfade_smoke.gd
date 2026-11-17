extends SceneTree
## Music queue must never play two tracks at once.
##
## The defect this guards (found in play 18.11): the queue switches tracks on a
## timer that keeps running during a pause (the inventory and the tactical pause
## freeze the tree). The crossfade then started while the tree was frozen, and
## `AudioStreamPlayer.playing` read FALSE for the old track. The old player was
## therefore neither faded nor stopped, and after the unpause it came back at full
## volume on top of the new one — forever.
##
## Run: godot --headless --path . --script res://tests/music_crossfade_smoke.gd

var _checks := 0
var _fails: Array[String] = []


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print(("  OK  " if ok else "  FAIL") + " " + what)


func _initialize() -> void:
	_run.call_deferred()


func _wait(seconds: float) -> void:
	await create_timer(seconds, true).timeout


func _playing_count() -> int:
	var n := 0
	for raw in MusicDB._players:
		var p := raw as AudioStreamPlayer
		if p != null and p.playing:
			n += 1
	return n


func _playing_files() -> Array[String]:
	var out: Array[String] = []
	for raw in MusicDB._players:
		var p := raw as AudioStreamPlayer
		if p != null and p.playing and p.stream != null:
			out.append(p.stream.resource_path.get_file())
	return out


func _active_volume() -> float:
	var p := MusicDB._players[MusicDB._active] as AudioStreamPlayer
	return p.volume_db if p != null else 0.0


## Volume of the player that is NOT the current track (the one fading out).
func _fading_volume() -> float:
	var p := MusicDB._players[1 - MusicDB._active] as AudioStreamPlayer
	return p.volume_db if p != null else 0.0


func _run() -> void:
	MusicDB.ensure_loaded()
	_check(MusicDB.playlist_size() == 8, "плейлист из 8 треков прочитан")
	_check(MusicDB.start_playlist(), "очередь запущена")
	await _wait(0.4)
	_check(_playing_count() == 1, "после старта играет один трек (а не два)")

	# --- 1. The failing case: the crossfade starts while the tree is paused. ---
	print("-- кроссфейд во время паузы --")
	paused = true
	MusicDB._timer.stop()
	MusicDB.next_track()
	await _wait(1.2)
	_check(_playing_count() <= 2, "на паузе играет не больше двух треков (кроссфейд)")
	var fading := _fading_volume()
	_check(fading < MusicDB._gain_db - 2.0,
		"на паузе старый трек реально затухает (%.1f дБ)" % fading)
	paused = false
	await _wait(3.2)
	_check(_playing_count() == 1,
		"после снятия паузы всё ещё один трек (было два навсегда)")
	var active := MusicDB._players[MusicDB._active] as AudioStreamPlayer
	_check(active != null and active.playing, "активный плеер звучит")
	_check(MusicDB.current_file() == active.stream.resource_path.get_file(),
		"играет именно текущий трек очереди (%s)" % MusicDB.current_file())
	_check(absf(_active_volume() - MusicDB._gain_db) < 0.6,
		"громкость вышла на уровень трека (%.1f дБ)" % _active_volume())
	var names := _playing_files()
	_check(names.size() == 1 and names[0] == MusicDB.current_file(),
		"на шине Music один поток: %s" % str(names))

	# --- 2. Two advances in a row must not leave a fading zombie behind. ---
	print("-- два переключения подряд --")
	MusicDB.next_track()
	await _wait(0.2)
	MusicDB.next_track()
	await _wait(4.0)
	_check(_playing_count() == 1,
		"после двух переключений подряд играет один трек (сейчас %d)" % _playing_count())
	_check(MusicDB.current_file() == _playing_files()[0] if _playing_files().size() == 1 else false,
		"звучит последний выбранный трек")
	_check(absf(_active_volume() - MusicDB._gain_db) < 0.6,
		"переключение не оставило громкость в затухании (%.1f дБ)" % _active_volume())

	# --- 3. Stop silences everything. ---
	print("-- стоп --")
	MusicDB.stop()
	await _wait(0.2)
	_check(_playing_count() == 0, "stop() заглушил все плееры (сейчас %d)" % _playing_count())
	_check(not MusicDB.is_started(), "очередь помечена остановленной")
	_check(MusicDB.start_playlist(), "после стопа очередь запускается снова")
	await _wait(0.3)
	_check(_playing_count() == 1, "повторный запуск даёт один трек")
	MusicDB.stop()

	if _fails.is_empty():
		print("RESULT: OK music_crossfade_smoke (проверок: %d)" % _checks)
	else:
		print("RESULT: FAIL (%d из %d)" % [_fails.size(), _checks])
	quit()
