extends SceneTree
##
## Network session smoke test (21.11). Two processes, one role each:
##
##   godot --headless --path . --script res://tests/net_handshake_probe.gd -- --role host --port 7801
##   godot --headless --path . --script res://tests/net_handshake_probe.gd -- --role client --port 7801
##
## The host waits for a peer, sends the world config, and expects the client's
## hero info. The client connects, waits for the world config, and sends its
## hero info. Both print "RESULT: OK net_handshake_probe (N checks)".
##
## What this proves: ENet link over the loopback, the RPC routing on the fixed
## /root/NetSession path, both handshake directions and the hero_join cache.
## It does NOT prove the in-game sync (snapshots need real Enemy nodes) вЂ” that
## is the manual two-machine test.

var _checks := 0
var _fails: Array[String] = []
var _role := "host"
var _port := 7801
var _session: NetSession = null
var _done := false

func _init() -> void:
	_parse_args()
	call_deferred("_run")

func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--role" and i + 1 < args.size():
			_role = args[i + 1]
		elif args[i] == "--port" and i + 1 < args.size():
			_port = int(args[i + 1])

func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
		print("  FAIL: " + what)

func _run() -> void:
	_session = NetSession.ensure()
	if _session == null:
		print("RESULT: FAIL net_handshake_probe (no NetSession node)")
		quit(1)
		return
	_check(_session != null, "session node exists")
	var path := _session.get_path()
	_check(str(path) == "/root/NetSession", "fixed RPC path, got %s" % str(path))
	if _role == "host":
		await _run_host()
	else:
		await _run_client()
	_session.leave()
	if _fails.is_empty():
		print("RESULT: OK net_handshake_probe (%d checks)" % _checks)
		quit(0)
	else:
		print("RESULT: FAIL net_handshake_probe (%d checks, %d failed)" % [_checks, _fails.size()])
		quit(1)

func _wait_signal(sig: Signal, seconds: float) -> bool:
	var t := create_timer(seconds)
	var fired := {"ok": false}
	var cb := func(_a = null, _b = null, _c = null, _d = null, _e = null) -> void:
		fired["ok"] = true
	# Bind-free: connect a lambda that ignores the arguments.
	sig.connect(cb, CONNECT_ONE_SHOT)
	while not fired["ok"]:
		await process_frame
		if t.time_left <= 0.0:
			break
	return bool(fired["ok"])

func _run_host() -> void:
	var err := _session.host(_port)
	_check(err == "", "host started: %s" % err)
	if err != "":
		return
	var joined := await _wait_signal(_session.peer_joined, 20.0)
	_check(joined, "a peer connected")
	if not joined:
		return
	# The host owns the world: same seed must reach the client.
	_session.send_world_config(123456, "start", 987, "start-1", "human")
	var got_hello := await _wait_signal(_session.hello_received, 5.0)
	_check(got_hello, "client hello arrived")
	var got_hero := await _wait_signal(_session.hero_joined, 5.0)
	_check(got_hero, "client hero info arrived")
	_check(not _session.peer_heroes.is_empty(), "hero info is cached for NetGame")

func _run_client() -> void:
	var err := _session.join("127.0.0.1", _port)
	_check(err == "", "join started: %s" % err)
	if err != "":
		return
	var connected := await _wait_signal(_session.connected_ok, 20.0)
	_check(connected, "connected to the host")
	if not connected:
		return
	var config := await _wait_signal(_session.world_config, 10.0)
	_check(config, "world config arrived")
	_session.send_hero_join({
		"peer": _session.multiplayer.get_unique_id(),
		"name": "Test",
		"anim_set": "hero/war_men",
		"max_hp": 100,
		"hp": 100,
		"max_mana": 0,
		"mana": 0,
		"attack": 10,
		"defense": 0,
		"absorption": 0,
		"protection": {},
	})
	# Give the host a moment to read it before the process exits.
	await create_timer(0.6).timeout

