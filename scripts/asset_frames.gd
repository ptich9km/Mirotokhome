class_name AssetFrames
extends RefCounted
## Frame files of a sprite folder (`sprites-001.png`, `house-001.png`, ...).
##
## An exported build lists imported textures as "<name>.png.import" (the source
## .png is not packed), while the editor lists BOTH names. So any runtime
## directory listing has to strip the stub suffix and dedupe by frame number —
## 2026-11-07: trees and props were invisible in the Windows build because the
## counter saw no ".png" entry and silently fell back to "the folder is missing".

## Sorted frame numbers picked from raw directory entry names.
static func numbers_from(names: Array, prefix := "sprites-") -> Array:
	var found := {}
	for raw in names:
		var name := str(raw).trim_suffix(".import")
		if not name.begins_with(prefix) or not name.ends_with(".png"):
			continue
		var num := int(name.trim_prefix(prefix).trim_suffix(".png"))
		if num > 0:
			found[num] = true
	var out: Array = found.keys()
	out.sort()
	return out

## Sorted frame numbers of a folder (empty when the folder cannot be listed).
static func numbers(dir_path: String, prefix := "sprites-") -> Array:
	var names: Array = []
	var dir := DirAccess.open(dir_path)
	if dir != null:
		dir.list_dir_begin()
		var fn := dir.get_next()
		while fn != "":
			if not dir.current_is_dir():
				names.append(fn)
			fn = dir.get_next()
		dir.list_dir_end()
	if names.is_empty():
		return []
	return numbers_from(names, prefix)

## Number of animation frames in a folder.
static func count(dir_path: String, prefix := "sprites-") -> int:
	return numbers(dir_path, prefix).size()

## Frame file names in order ("sprites-001.png", ...) — same in editor and pack.
static func file_names(dir_path: String, prefix := "sprites-") -> Array:
	var out: Array = []
	for num in numbers(dir_path, prefix):
		out.append("%s%03d.png" % [prefix, int(num)])
	return out
