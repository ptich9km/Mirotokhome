extends RefCounted
class_name MinimapMarkers
## Реестр маркеров миникарты (19.10): события и квест-метки.
##
## Маркеры ВСЕГДА видны на миникарте (решение игрока): они направляют
## игрока, но не выдают позиции юнитов - точка события рисуется по клетке
## события, а не по живым юнитам. Квест-типы использует quest_system
## (с 22.10), маркеры «!»/«?» стоят над головами глав городов.

signal changed

enum Kind { BATTLE, QUEST_DELIVER, QUEST_GATHER, QUEST_DESTROY, QUEST_RESCUE }

static var instance: MinimapMarkers = null

var _items: Array[Dictionary] = []
var _next_id := 1

func _init() -> void:
	instance = self

## Добавить маркер. seed/zone - к какой карте он относится.
## ttl_seconds - жизнь в реальных секундах (день мира в живой игре не тикает).
func add(kind: int, cell: Vector2i, ttl_seconds: float, seed_value: int, zone: String,
		sector: String = "") -> int:
	var id := _next_id
	_next_id += 1
	_items.append({
		"id": id, "kind": kind,
		"cell_x": cell.x, "cell_y": cell.y,
		"ttl_left": ttl_seconds,
		"seed": seed_value, "zone": zone, "sector": sector,
	})
	changed.emit()
	return id

func remove(id: int) -> void:
	var before := _items.size()
	for it in _items.duplicate():
		if int(it["id"]) == id:
			_items.erase(it)
	if _items.size() != before:
		changed.emit()

## Жизнь маркеров в реальном времени (тикает EventSystem).
func tick_life(delta: float) -> void:
	var dirty := false
	for it in _items.duplicate():
		it["ttl_left"] = float(it["ttl_left"]) - delta
		if float(it["ttl_left"]) <= 0.0:
			_items.erase(it)
			dirty = true
	if dirty:
		changed.emit()

## Маркеры текущей карты.
func all_for(seed_value: int, zone: String, sector: String = "") -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for it in _items:
		if int(it["seed"]) != seed_value or str(it["zone"]) != zone:
			continue
		if sector != "" and str(it.get("sector", "")) != sector:
			continue
		out.append(it)
	return out

## Полная зачистка (смена карты).
func clear_all() -> void:
	if _items.is_empty():
		return
	_items.clear()
	changed.emit()

func item_count() -> int:
	return _items.size()
