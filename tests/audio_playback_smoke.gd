extends SceneTree
## Dialogue channel and pause behaviour of game audio.
##
## Player reports and measurements (12.11): a repeated "Поговорить" click started
## two speakers at once, and the tactical pause FROZE every one-shot sound — a line
## broke on a syllable and finished twenty seconds later, a sword hit went silent.
## Music was protected (MusicDB is PROCESS_MODE_ALWAYS), the SoundDB bus was not.
##
## Run: godot --headless --path . --script res://tests/audio_playback_smoke.gd
## Result: RESULT: OK audio_playback_smoke checks=N

const BUSES := ["Music", "SFX", "UI", "Voice", "Ambient"]
const SFX_LEN := 6.81   # npc_inn_1.mp3, the longest line we have

var _checks := 0
var _fails: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
	print(("  OK   " if ok else "  FAIL ") + msg)


func _run() -> void:
	await process_frame
	SoundDB.ensure_buses()
	await _buses()
	await _voice_channel()
	await _ducking()
	await _pause_keeps_audio()
	_report()


func _buses() -> void:
	print("-- buses --")
	for name in BUSES:
		_check(AudioServer.get_bus_index(name) >= 0, "шина %s существует" % name)
	if root.get_node_or_null("SoundBus") == null:
		SoundDB.play("ui.craft")   # the pool is lazy: created on first play
		await process_frame
	var bus := root.get_node_or_null("SoundBus")
	_check(bus != null, "узел SoundBus создан")
	if bus != null:
		_check(bus.process_mode == Node.PROCESS_MODE_ALWAYS,
			"SoundBus в PROCESS_MODE_ALWAYS (пауза не глушит звук)")


func _voice_channel() -> void:
	print("-- голосовой канал --")
	var ok := SoundDB.play_voice("voice.npc.inn.1")
	await process_frame
	_check(ok and SoundDB.is_voice_playing(), "реплика запускается")
	var first_stream: AudioStream = _voice_stream()
	# A second click must REPLACE the line, not start a second speaker.
	SoundDB.play_voice("voice.npc.inn.2")
	await process_frame
	_check(SoundDB.is_voice_playing(), "вторая реплика играет")
	var playing_voice := _count_playing("Voice")
	_check(playing_voice == 1,
		"на шине Voice играет ровно один плеер (сейчас %d)" % playing_voice)
	var second_stream := _voice_stream()
	_check(second_stream != null and second_stream != first_stream,
		"вторая реплика подменила поток первой")
	SoundDB.stop_voice()
	await process_frame
	_check(not SoundDB.is_voice_playing(), "stop_voice останавливает реплику")
	_check(_count_playing("Voice") == 0, "после stop_voice на шине Voice тишина")
	await create_timer(0.5).timeout


func _ducking() -> void:
	print("-- дакинг музыки --")
	var music := AudioServer.get_bus_index("Music")
	if music < 0:
		_check(false, "шина Music есть")
		return
	var base := AudioServer.get_bus_volume_db(music)
	SoundDB.play_voice("voice.npc.inn.1")
	await create_timer(0.4).timeout
	var ducked := AudioServer.get_bus_volume_db(music)
	_check(ducked < base - 3.0,
		"музыка приседает под репликой (%.1f -> %.1f dB)" % [base, ducked])
	SoundDB.stop_voice()
	await create_timer(0.6).timeout
	var restored := AudioServer.get_bus_volume_db(music)
	_check(absf(restored - base) < 0.6,
		"после реплики музыка возвращается (%.1f -> %.1f dB)" % [ducked, restored])

	# A line that ENDS on its own must release the dip (the `finished` signal):
	# otherwise the music would stay quiet until the next line.
	SoundDB.play_voice("voice.hero.male.attack.1")
	await create_timer(0.3).timeout
	var mid := AudioServer.get_bus_volume_db(music)
	_check(mid < base - 3.0, "короткая реплика тоже приседает (%.1f dB)" % mid)
	await create_timer(2.0).timeout
	var after := AudioServer.get_bus_volume_db(music)
	_check(absf(after - base) < 0.6,
		"реплика кончилась — музыка вернулась сама (%.1f -> %.1f dB)" % [mid, after])
	_check(not SoundDB.is_voice_playing(), "после конца реплики канал свободен")


func _pause_keeps_audio() -> void:
	print("-- пауза не режет звук --")
	# A long stream through the POOL (a line played as a one-shot, not the voice
	# channel): a stinger of 0.2 s would end before the second measurement.
	SoundDB.play("voice.npc.inn.1")
	await process_frame
	var p := _first_pool_player()
	if p == null:
		_check(false, "звук из пула запустился")
		return
	var p0 := p.get_playback_position()
	await create_timer(0.5).timeout
	var p1 := p.get_playback_position()
	_check(p1 > p0 + 0.2, "звук идёт без паузы (%.3f -> %.3f)" % [p0, p1])
	# Freeze the tree: the sound must keep playing, not stop on a half-frame.
	paused = true
	var p2 := p.get_playback_position()
	await create_timer(0.5).timeout
	var p3 := p.get_playback_position()
	paused = false
	_check(p3 > p2 + 0.2,
		"на тактической паузе звук продолжается (%.3f -> %.3f)" % [p2, p3])

	# The same for a dialogue line: it must not break off on a syllable.
	SoundDB.play_voice("voice.npc.inn.1")
	await process_frame
	var v := _voice_player()
	if v == null:
		_check(false, "голосовой плеер найден")
		return
	var v0 := v.get_playback_position()
	paused = true
	await create_timer(0.5).timeout
	var v1 := v.get_playback_position()
	paused = false
	_check(v1 > v0 + 0.2,
		"на тактической паузе реплика продолжается (%.3f -> %.3f)" % [v0, v1])
	SoundDB.stop_voice()
	await create_timer(0.5).timeout


func _voice_player() -> AudioStreamPlayer:
	var bus := root.get_node_or_null("SoundBus")
	if bus == null:
		return null
	for c in bus.get_children():
		if c is AudioStreamPlayer and c.name == "Voice":
			return c as AudioStreamPlayer
	return null


func _voice_stream() -> AudioStream:
	var p := _voice_player()
	return p.stream if p != null else null


func _count_playing(bus_name: String) -> int:
	var n := 0
	var bus := root.get_node_or_null("SoundBus")
	if bus == null:
		return 0
	for c in bus.get_children():
		if c is AudioStreamPlayer:
			var ap := c as AudioStreamPlayer
			if ap.playing and ap.bus == bus_name:
				n += 1
	return n


func _first_pool_player() -> AudioStreamPlayer:
	var bus := root.get_node_or_null("SoundBus")
	if bus == null:
		return null
	for c in bus.get_children():
		if c is AudioStreamPlayer:
			var ap := c as AudioStreamPlayer
			if ap.playing and ap.name.begins_with("Sfx"):
				return ap
	return null


func _report() -> void:
	print()
	if _fails.is_empty():
		print("RESULT: OK audio_playback_smoke checks=%d" % _checks)
		quit(0)
	else:
		print("RESULT: FAIL audio_playback_smoke checks=%d fails=%d"
			% [_checks, _fails.size()])
		for m in _fails:
			print("  - %s" % m)
		quit(1)
