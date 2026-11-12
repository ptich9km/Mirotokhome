class_name CraftTailorTab
extends CraftSmithTab

## Вкладка портного: переработка сломанной одежды мага -> ткань +
## магическая эссенция, и крафт одежды по рецептам (много ткани + немного
## слитков).
##
## Наследует кузнеца, а не CraftTab напрямую: разметка списка, карточки трёх
## уровней, строки ингредиентов и обе операции (переработка + крафт) у них
## совпадают до слова. Различается ТОЛЬКО тем, что перерабатывается
## (CraftDB.can_recycle) и какие рецепты грузятся. Дублировать эти ~150 строк
## ради двух строк разницы - ровно тот случай, где две копии через месяц
## разъезжаются.

const GARMENT_MATERIAL := "Linen"


func _decor_path() -> String:
	return "res://assets/professions/workshop/loom.png"


func _items() -> Array:
	var out: Array = []
	for raw in _inventory_items():
		var item: Dictionary = raw["item"]
		if not CraftDB.can_recycle(CraftDB.TAILOR, item):
			continue
		out.append({
			"mode": RECYCLE_ID,
			"key": str(raw["key"]),
			"item": item,
			"count": int(raw["count"]),
		})
	out.append({"mode": RECIPE_ID, "id": "", "recipe": {}})
	for r in CraftDB.known_recipes(CraftDB.TAILOR, player):
		out.append({"mode": RECIPE_ID, "id": str(r.get("id", "")), "recipe": r})
	return out


func _item_label(entry: Dictionary) -> String:
	var recipe: Dictionary = entry.get("recipe", {})
	if str(entry.get("mode", "")) == RECIPE_ID and recipe.is_empty():
		return Loc.t("ui.craft.recipes_header")
	if str(entry.get("mode", "")) == RECYCLE_ID:
		var item: Dictionary = entry["item"]
		var mark := "" if ItemDB.is_broken(item) else Loc.t("ui.craft.intact")
		return "  %s  ×%d%s" % [ItemDB.display_name(item), int(entry["count"]), mark]
	return super._item_label(entry)


func _build_recipe_detail(entry: Dictionary) -> void:
	var recipe: Dictionary = entry.get("recipe", {})
	if recipe.is_empty():
		_detail.add_child(_make_hint(Loc.t("ui.craft.tailor.hint")))
		return
	_detail.add_child(_heading(CraftDB.display_name(recipe)))
	_detail.add_child(_tier_cards(recipe))
	_detail.add_child(HSeparator.new())
	_detail.add_child(_section(Loc.t("ui.craft.ingredients")))
	for ing in recipe.get("inputs", []):
		_detail.add_child(_make_ingredient_row(ing))


func _variation_prefix() -> String:
	return "CraftTailor"