class_name CraftDB
extends RefCounted

## Правила мастерской: рецепты, переработка, шансы трёх уровней вещи.
##
## Основной читатель ключей секции [craft] из game.cfg. Причина именно
## так: tests/config_dead_keys_smoke.gd падает на любом ключе, который не
## встречается строковым литералом в коде. Держать их в одном классе —
## меньше мест, где забыть ключ при рефакторинге.
##
## ИСКЛЮЧЕНИЯ (читают [craft] напрямую, не через CraftDB):
## - workshop_panel.gd — master_enabled (флаг вкладки «Мастер»);
## - tier_improved_mult / tier_master_mult — только генератор
##   tests/gen_crafted_items.py, в рантайме не читаются.
##
## ТИРЫ КРАФТОВОЙ ВЕЩИ. Рецепт хранит все три выхода явно, веса — базовые,
## а навык сдвигает их в рантайме. Три записи в базе вместо одного:
## инвентарь хранит `Array[String]` ключей (player.gd:39), и две крафтовые
## вещи одного рецепта с РАЗНЫМ уровнем невозможно различить иначе. Цена
## решения — база растёт на число рецептов x 3.
##
## Почему шансы зашиты формулой, а не таблицей по уровням: сумма должна быть
## ровно 100 при ЛЮБОМ навыке, а таблица из 40 строк разъезжается при первой
## же правке. Сумма здесь сохраняется тождественно:
##     (80 - 1.4*s) + (15 + 0.9*s) + (5 + 0.5*s) = 100.

const RECIPE_DIR := "res://assets/professions/workshop/"

## Виды ремесла. Индексы фиксированы: третья вкладка (мастер) введётся
## позже, и сдвигать их нельзя — иначе сломается сохранённый фокус панели.
const SMITH := "smith"
const TAILOR := "tailor"
const MASTER := "master"

const CRAFT_KINDS := [SMITH, TAILOR, MASTER]

## Навык крафта по виду ремесла. У каждого ремесла СВОЙ счётчик: крафт в
## кузне не должен качать портново, иначе игрок не выбирает, а «прокачивает
## всё понемногу». Алхимия живёт в своём здании, но навык общий с ремеслами,
## поэтому вынесена в отдельную константу.
const SKILL_OF := {
	SMITH: "smithing",
	TAILOR: "tailoring",
	MASTER: "mastering",
}
const ALCHEMY_SKILL := "alchemy"

## Ресурсы крафта. Ключи из item_db (gen_broken_items.py).
const FABRIC_KEY := "Fabric"
const ESSENCE_KEY := "Magic Essence"

## Три уровня крафтовой вещи. Обычная без эффекта, улучшенная и мастерская
## получают шейдер свечения (scripts/craft_vfx.gd).
const TIER_ORDINARY := 0
const TIER_IMPROVED := 1
const TIER_MASTER := 2

## Префикс качества у записей базы по уровню. Обычная - пусто, поэтому её
## ключ совпадает с «крафтовой вещью без приставкой».
const TIER_QUALITY := ["", "Fine ", "Master "]
const TIER_QUALITY_LONG := ["Crafted", "Crafted Fine", "Crafted Master"]

## Свитки рецептов: ключ = "Recipe <id>". Лавка продаёт их, инвентарь
## хранит — рецепт открыт. Качество "Recipe", не экипируется.
const RECIPE_SCROLL_PREFIX := "Recipe "

## Выход переработки ЦЕЛОЙ вещи = 0.8 от ресурсов её крафта. Игрок: «у целой
## брони выход на 20% ниже, чем ресурсов на крафт». Сломанная по-прежнему
## идёт по качеству (yield_broken*).
const INTACT_RECYCLE_MULT := 0.8

static var _recipes: Dictionary = {}
static var _loaded := false


static func clear_cache() -> void:
	_recipes = {}
	_loaded = false


# --- Загрузка рецептов ----------------------------------------------------

static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	for kind in CRAFT_KINDS:
		_recipes[kind] = []
	for kind in [SMITH, TAILOR]:
		var path := "%s%s_recipes.json" % [RECIPE_DIR, kind]
		# FileAccess, а не ResourceLoader.exists: JSON не импортируется движком
		# как ресурс, и проверка существования через ResourceLoader врёт.
		# Тот же приём в alchemy_panel.gd:138.
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			push_error("CraftDB: не открыть " + path)
			continue
		var parsed: Variant = JSON.parse_string(file.get_as_text())
		file.close()
		if not (parsed is Dictionary):
			push_error("CraftDB: рецепты " + path + " - не объект JSON")
			continue
		var list: Variant = (parsed as Dictionary).get("recipes", [])
		if not (list is Array):
			continue
		for raw in list:
			var r: Variant = _validate(raw, kind, path)
			if not r.is_empty():
				_recipes[kind].append(r)


static func _validate(raw: Variant, kind: String, path: String) -> Dictionary:
	if not (raw is Dictionary):
		push_error("CraftDB: рецепт не объект в " + path)
		return {}
	var d: Dictionary = raw
	var id := str(d.get("id", ""))
	if id == "":
		push_error("CraftDB: рецепт без id в " + path)
		return {}
	var inputs: Variant = d.get("inputs", [])
	if not (inputs is Array) or (inputs as Array).is_empty():
		push_error("CraftDB: рецепт %s без ингредиентов" % id)
		return {}
	for ing in inputs as Array:
		if not (ing is Dictionary):
			push_error("CraftDB: ингредиент %s не объект" % id)
			return {}
		var key := str((ing as Dictionary).get("item", ""))
		if key == "" or ItemDB.find(key).is_empty():
			push_error("CraftDB: неизвестный ингредиент '%s' в %s" % [key, id])
			return {}
		if int((ing as Dictionary).get("count", 0)) <= 0:
			push_error("CraftDB: неположительный count в %s" % id)
			return {}
	var outs: Variant = d.get("outputs", [])
	if not (outs is Array) or (outs as Array).is_empty():
		push_error("CraftDB: рецепт %s без выходов" % id)
		return {}
	for out in outs as Array:
		if not (out is Dictionary):
			push_error("CraftDB: выход %s не объект" % id)
			return {}
		var okey := str((out as Dictionary).get("key", ""))
		if ItemDB.find(okey).is_empty():
			push_error("CraftDB: неизвестный выход '%s' в %s" % [okey, id])
			return {}
		if float((out as Dictionary).get("weight", 0.0)) <= 0.0:
			push_error("CraftDB: неположительный weight в %s" % okey)
			return {}
	d["craft"] = str(d.get("craft", kind))
	d["inputs"] = (inputs as Array).duplicate(true)
	d["outputs"] = (outs as Array).duplicate(true)
	return d


static func recipes(kind: String) -> Array:
	_load()
	return _recipes.get(kind, [])


static func recipe_by_id(id: String) -> Dictionary:
	_load()
	for kind in CRAFT_KINDS:
		for r in recipes(kind):
			if str(r.get("id", "")) == id:
				return r
	return {}


## Ключ свитка-рецепта для id рецепта.
static func recipe_scroll_key(recipe_id: String) -> String:
	return RECIPE_SCROLL_PREFIX + recipe_id


## id всех рецептов всех профессий. Нужен наградам (квест главы может дать
## чертёж): перебирать имена файлов *_recipes.json в геймплейном коде нельзя.
static func all_recipe_ids() -> Array:
	_load()
	var out: Array = []
	for kind in CRAFT_KINDS:
		for r in recipes(kind):
			var id := str(r.get("id", ""))
			if id != "":
				out.append(id)
	return out


## Рецепты фракционного набора (пакет C+D): id вида
## `faction_<раса>_<kit>_<slot>`. Их выдают за захват форпоста этой фракции.
static func recipe_ids_of_faction(race: String) -> Array:
	if race == "":
		return []
	var prefix := "faction_%s_" % race
	var out: Array = []
	for id in all_recipe_ids():
		if str(id).begins_with(prefix):
			out.append(str(id))
	return out


## Есть ли у игрока свиток этого рецепта.
static func has_recipe_scroll(player: Player, recipe_id: String) -> bool:
	if not is_instance_valid(player):
		return false
	var key := recipe_scroll_key(recipe_id)
	for raw in player.inventory:
		if str(raw) == key:
			return true
	return false


## Faction recipes are single-run: one scroll = one craft. Everything else is
## learned forever from its scroll (04.11).
static func is_rare_recipe(recipe: Dictionary) -> bool:
	# Faction recipes have no "bp" field in their JSON; the id prefix is the
	# stable marker (faction_<race>_<slot>).
	return str(recipe.get("bp", "")) == "faction" \
		or str(recipe.get("id", "")).begins_with("faction_")


static func is_rare_recipe_id(recipe_id: String) -> bool:
	return is_rare_recipe(recipe_by_id(recipe_id))


static func has_recipe(player: Player, recipe_id: String) -> bool:
	if not is_instance_valid(player) or recipe_id == "":
		return false
	if player.known_recipes.has(recipe_id):
		return true
	return has_recipe_scroll(player, recipe_id)


## Learn a common recipe permanently. Rare recipes are not learned: their
## scroll is spent by the craft itself.
static func learn_recipe(player: Player, recipe_id: String) -> bool:
	if not is_instance_valid(player) or recipe_id == "":
		return false
	if is_rare_recipe_id(recipe_id):
		return false
	if not has_recipe_scroll(player, recipe_id):
		return false
	if not player.remove_item(recipe_scroll_key(recipe_id)):
		return false
	if not player.known_recipes.has(recipe_id):
		player.known_recipes.append(recipe_id)
	return true


## Рецепты, доступные игроку (по свиткам в инвентаре).
static func known_recipes(kind: String, player: Player) -> Array:
	var out: Array = []
	for r in recipes(kind):
		if has_recipe(player, str(r.get("id", ""))):
			out.append(r)
	return out


## Свитки-рецепты в инвентаре: [{key, item, count, recipe_id}].
static func recipe_scroll_items(player: Player) -> Array:
	var counts := {}
	for raw in player.inventory if is_instance_valid(player) else []:
		var key := str(raw)
		if not key.begins_with(RECIPE_SCROLL_PREFIX):
			continue
		counts[key] = int(counts.get(key, 0)) + 1
	var out: Array = []
	for key: String in counts:
		var item := ItemDB.find(key)
		if item.is_empty():
			continue
		out.append({
			"key": key,
			"item": item,
			"count": int(counts[key]),
			"recipe_id": key.substr(RECIPE_SCROLL_PREFIX.length()),
		})
	return out


# --- Шансы трёх уровней ---------------------------------------------------

## Веса уровней для навыка skill. Сумма ровно 100 при ЛЮБОМ навыке.
##
## Сумма тождественно сохранялась бы простой формулой
## (80-1.4s) + (15+0.9s) + (5+0.5s) = 100, но только пока обычная не упирается
## в floor_ordinary. На навыке 44+ она упирается, и сумма начинает расти
## (на 100 было бы 165) - а сумма больше 100 означает, что шансы перестали быть
## вероятностями, и игрок получает вещь "бесплатно". Поэтому после клампа
## улучшенная и мастерская масштабируются пропорционально.
static func tier_weights(skill: int) -> Array[float]:
	var s := float(maxi(0, skill))
	var floor_ordinary := GameConfig.getf("craft", "floor_ordinary")
	var ordinary := GameConfig.getf("craft", "chance_ordinary") \
		- GameConfig.getf("craft", "ordinary_step") * s
	var improved := GameConfig.getf("craft", "chance_improved") \
		+ GameConfig.getf("craft", "improved_step") * s
	var master := GameConfig.getf("craft", "chance_master") \
		+ GameConfig.getf("craft", "master_step") * s
	if ordinary < floor_ordinary:
		# Деление перераспределяет остаток между двумя другими уровнями в том
		# же соотношении, в каком они выросли, - иначе мастерская забирала бы
		# себе всё, а улучшенная стояла бы на месте.
		var rest := improved + master
		if rest > 0.0:
			var scale := (100.0 - floor_ordinary) / rest
			improved *= scale
			master *= scale
		ordinary = floor_ordinary
	return [ordinary, improved, master]


## Уровень по весу шанса. roll в [0, 100).
static func tier_for_roll(roll: float, skill: int) -> int:
	var w := tier_weights(skill)
	var acc := 0.0
	for i in w.size():
		acc += w[i]
		if roll < acc:
			return i
	return TIER_ORDINARY


## Случайный уровень крафтовой вещи при данном навыке.
static func roll_tier(skill: int, rng: RandomNumberGenerator = null) -> int:
	var r := randf() * 100.0 if rng == null else rng.randf() * 100.0
	return tier_for_roll(r, skill)


## Ключ выхода рецепта для уровня tier ("" если такого выхода нет).
static func output_key(recipe: Dictionary, tier: int) -> String:
	var outs: Array = recipe.get("outputs", [])
	if outs.is_empty():
		return ""
	var idx := clampi(tier, 0, outs.size() - 1)
	return str((outs[idx] as Dictionary).get("key", ""))


# --- Переработка (сломанное + целое) --------------------------------------

## Выход переработки: {"ingot": int, "fabric": int, "essence": int}.
## Сломанное: качество вещи решает, сколько слитков.
## Целое: ресурсы КРАФТА этой вещи x INTACT_RECYCLE_MULT (0.8), игрок 08.10.
static func recycle_yield(item: Dictionary) -> Dictionary:
	if ItemDB.is_broken(item):
		return _yield_broken(item)
	return _yield_intact(item)


static func _yield_broken(item: Dictionary) -> Dictionary:
	var q := ItemDB.broken_quality(item)
	if q == "":
		return {"ingot": 0, "fabric": 0, "essence": 0}
	var fine := q == "Broken Fine"
	var rare := q == "Broken Rare"
	var out := {"ingot": 0, "fabric": 0, "essence": 0}
	match ItemDB.broken_category(item):
		"Armor":
			out.ingot = _tier(fine, rare, "yield_broken", "yield_broken_fine", "yield_broken_rare")
			out.fabric = _tier(fine, rare, "fabric_from_armor", "fabric_from_armor_fine", "fabric_from_armor_rare")
		"Weapon":
			out.ingot = _tier(fine, rare, "yield_broken", "yield_broken_fine", "yield_broken_rare")
			out.fabric = _tier(fine, rare, "fabric_from_weapon", "fabric_from_weapon_fine", "fabric_from_weapon_rare")
		"Garment":
			out.fabric = _tier(fine, rare, "fabric_from_garment", "fabric_from_garment_fine", "fabric_from_garment_rare")
			out.essence = _tier(fine, rare, "essence_from_garment", "essence_from_garment_fine", "essence_from_garment_rare")
	return out


## Выход переработки ЦЕЛОЙ вещи = 0.8 от входов рецепта, который её создаёт.
static func _yield_intact(item: Dictionary) -> Dictionary:
	var out := {"ingot": 0, "fabric": 0, "essence": 0}
	var r := recipe_for_item(item)
	if r.is_empty():
		return out
	var mult := INTACT_RECYCLE_MULT
	for ing in r.get("inputs", []):
		var ikey := str(ing.get("item", ""))
		var n := int(floor(int(ing.get("count", 0)) * mult))
		if n <= 0:
			continue
		if ikey == FABRIC_KEY:
			out.fabric += n
		elif ikey == ESSENCE_KEY:
			out.essence += n
		elif ItemDB.find(ikey).get("type", "") == "Ingot":
			out.ingot += n
	return out


## Рецепт, выходом которого является эта вещь (с учётом префиксов качества).
static func recipe_for_item(item: Dictionary) -> Dictionary:
	var key := str(item.get("key", ""))
	if key == "":
		return {}
	var base := _strip_quality(key)
	for kind in [SMITH, TAILOR]:
		for r in recipes(kind):
			for out in r.get("outputs", []):
				var okey := str((out as Dictionary).get("key", ""))
				if okey == key or _strip_quality(okey) == base:
					return r
	return {}


const _QUALITY_PREFIXES := [
	"Crafted Master ", "Crafted Fine ", "Crafted ",
	"Master ", "Fine ", "Common ", "Rare ", "Very Rare ",
	"Good ", "Cheap ", "Bad ", "Elite ", "Elven ",
]


static func _strip_quality(key: String) -> String:
	for p in _QUALITY_PREFIXES:
		if key.begins_with(p):
			return key.substr(p.length())
	return key


static func _tier(fine: bool, rare: bool, k0: String, k1: String, k2: String) -> int:
	if rare:
		return GameConfig.geti("craft", k2)
	if fine:
		return GameConfig.geti("craft", k1)
	return GameConfig.geti("craft", k0)


## Может ли этот вид ремесла переработать такую вещь?
## Сломанное + ЦЕЛАЯ экипируемая броня/оружие (кузнец) и одежда (портной).
static func can_recycle(kind: String, item: Dictionary) -> bool:
	if ItemDB.is_craft_material(item):
		return false
	if ItemDB.is_broken(item):
		var cat := ItemDB.broken_category(item)
		if cat == "Garment":
			return kind == TAILOR
		return kind == SMITH
	# Целое: только то, что можно надеть, и только своё ремесло.
	if not ItemDB.is_equippable(item):
		return false
	if str(item.get("type", "")) == "Ingot":
		return false
	var slot := ItemDB.slot_of(item)
	if slot == "":
		return false
	if kind == SMITH:
		return slot == "weapon" or ItemDB.armor_kind(item) == "heavy"
	if kind == TAILOR:
		return ItemDB.armor_kind(item) == "light" or slot in ["cloak", "body", "head"]
	return false


## --- Опыт навыка ----------------------------------------------------------

## Опыт за крафт: базовый + надбавка за уровень вещи.
static func xp_for_craft(tier: int) -> int:
	var xp := GameConfig.geti("craft", "xp_per_craft")
	if tier == TIER_IMPROVED:
		xp += GameConfig.geti("craft", "xp_tier_bonus")
	elif tier == TIER_MASTER:
		xp += GameConfig.geti("craft", "xp_tier_bonus") * 2
	return maxi(1, xp)


static func xp_for_recycle() -> int:
	return maxi(1, GameConfig.geti("craft", "xp_per_recycle"))