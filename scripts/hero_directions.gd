class_name HeroDirections
extends RefCounted
## Character-creation development directions (assets/config/hero_directions.json).
##
## A direction is EITHER primary (20 skill points, 100% of the skill-derived
## life/mana/defence) OR auxiliary (10 points, 60% — see [skill_stats]
## aux_factor). Astral and Shooting are auxiliary by design: they cannot be
## chosen as the main direction.
##
## The file stores only names and text. Every number on the screen is computed
## from Player statics at run time, so the description cannot drift from combat.

const PATH := "res://assets/config/hero_directions.json"

static var _data: Dictionary = {}
static var _loaded := false


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(PATH):
		push_error("HeroDirections: %s is missing" % PATH)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if parsed is Dictionary:
		_data = parsed as Dictionary


static func for_class(hero_class: String) -> Array:
	ensure_loaded()
	var out: Variant = _data.get(hero_class, [])
	return (out as Array).duplicate(true) if out is Array else []


static func primaries(hero_class: String) -> Array:
	var out: Array = []
	for d in for_class(hero_class):
		if str((d as Dictionary).get("role", "")) == "primary":
			out.append(d)
	return out


## The one auxiliary direction of a class ({} when the data is broken).
static func aux(hero_class: String) -> Dictionary:
	for d in for_class(hero_class):
		if str((d as Dictionary).get("role", "")) == "aux":
			return d
	return {}


static func by_skill(skill: String) -> Dictionary:
	ensure_loaded()
	for cls in _data:
		var list: Variant = _data[cls]
		if not (list is Array):
			continue
		for d in list:
			if str((d as Dictionary).get("skill", "")) == skill:
				return (d as Dictionary).duplicate(true)
	return {}


## Weapon damage kind of a direction (sword/axe/club/pike/bow/staff).
static func weapon_kind_of(skill: String) -> String:
	return str(by_skill(skill).get("weapon_kind", ""))


## Sphere of a mage direction ("" for a warrior).
static func sphere_of(skill: String) -> String:
	return str(by_skill(skill).get("sphere", ""))
