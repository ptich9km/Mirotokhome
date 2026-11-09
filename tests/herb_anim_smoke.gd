extends SceneTree
## Herb animation frames (09.11): all-or-nothing per herb.
##
## `HerbDB` promises 4 frames at 6 fps for every herb; the art arrives one herb
## at a time from `gen_herb_strip.py` + `extract_herb_strip.py`. `HerbNode` falls
## back to the still icon when a frame is missing, which is fine for the game but
## would hide a half-generated set. This guard makes that visible:
##   * a herb has either NO frames or the COMPLETE set;
##   * every frame is 32x32 and not empty;
##   * the plant height is stable across frames (a pulsing plant is a bug);
##   * HerbDB itself is sane (frame_count >= 1, fps >= 0 when animated).
##
## Run: godot --headless --path . --script res://tests/herb_anim_smoke.gd

const FRAMES := 4
const SIZE := 32

var _fails: Array[String] = []
var _checks := 0


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print("HERBANIM: %s %s" % ["ok  " if ok else "FAIL", what])


func _initialize() -> void:
	HerbDB.ensure_loaded()
	call_deferred("_run")


func _run() -> void:
	var herbs := HerbDB.all()
	_check(herbs.size() == 12, "12 трав в HerbDB (%d)" % herbs.size())
	var animated := 0
	var still := 0
	for key in herbs:
		var frames_of := HerbDB.frames_of(str(key))
		var fps := HerbDB.fps_of(str(key))
		_check(frames_of >= 1, "%s: frame_count >= 1 (%d)" % [key, frames_of])
		_check(fps >= 0 and (frames_of == 1 or fps > 0),
			"%s: fps задан для анимации (%d)" % [key, fps])
		var base := HerbDB.icon_of(str(key)).get_basename()
		var existing: Array[String] = []
		for index in range(frames_of):
			var path := "%s_frame%02d.png" % [base, index]
			if ResourceLoader.exists(path):
				existing.append(path)
		if existing.is_empty():
			still += 1
			continue
		_check(existing.size() == frames_of,
			"%s: кадров %d из %d (половина набора хуже, чем ничего)" % [
				key, existing.size(), frames_of])
		if existing.size() != frames_of:
			continue
		animated += 1
		var heights: Array[int] = []
		for path in existing:
			var texture := load(path) as Texture2D
			if texture == null:
				_check(false, "%s: %s не загрузился" % [key, path.get_file()])
				continue
			_check(texture.get_size() == Vector2(SIZE, SIZE),
				"%s: %s размер %s" % [key, path.get_file(), str(texture.get_size())])
			var height := _content_height(texture)
			_check(height > 0, "%s: %s не пустой" % [key, path.get_file()])
			heights.append(height)
		if heights.size() >= 2:
			var low: int = heights.min()
			var high: int = heights.max()
			_check(high - low <= 4,
				"%s: высота растения не скачет между кадрами %s" % [key, str(heights)])
	print("HERBANIM: анимировано %d, статикой %d (кадров пока нет)" % [animated, still])
	_finish()


## Height of the opaque part of a frame, in pixels.
func _content_height(texture: Texture2D) -> int:
	var image := texture.get_image()
	if image == null:
		return 0
	if image.is_compressed():
		image.decompress()
	var top := -1
	var bottom := -1
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			if image.get_pixel(x, y).a > 0.15:
				if top < 0:
					top = y
				bottom = y
				break
	return 0 if top < 0 else bottom - top + 1


func _finish() -> void:
	print("")
	if _fails.is_empty():
		print("RESULT: OK herb_anim_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL herb_anim_smoke (%d checks, %d fails)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)
