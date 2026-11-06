class_name LootIcons
extends RefCounted
## Иконки для мешка лута: какой спрайт показать на земле и в тултипе.
##
## ЗАЧЕМ ОТДЕЛЬНЫЙ КЛАСС. assets/loot_icons/ содержит металлы x {оружие,
## броня} плюс баночки зелий трёх размеров - это "видно с расстояния" версии
## предметов, мелкие и читаемые. (Пакет A, 28.10: 16 фракционных металлов
## удалены, остались bronze/iron/steel/gold.) Фракционные иконки из
## assets/items/faction/ годятся для склада, но не для мешка на земле: там
## нужно опознать вещь за секунду, а не рассмотреть.
##
## ПРАВИЛА.
##  * золото-ДЕНЬГИ -> монета gold_coin.png; деньгами gold_icon() зовёт
##    loot_drop.gd напрямую (золото — число у игрока, не предмет);
##  * золото-СНАРЯЖЕНИЕ с 20.10 -> {gold}_weapon/_armor.png, как у прочих
##    металлов (программные дроп-иконки, tests/gen_loot_icons_derived.py;
##    раньше mat == "gold" гонялся на монету — золотая броня на земле
##    выглядела деньгами);
##  * снаряжение -> {material}_weapon.png или {material}_armor.png, выбор по
##    ItemDB.slot_of(): оружие и щиты считаются оружием, остальное бронёй;
##  * зелья -> баночка по типу (health/mana) и размеру; размер задаёт
##    вызывающий код, потому что сила врага известна только там;
##  * всё остальное (книги, свитки, травы) -> иконка самого предмета из
##    item_db;
##  * СЛОМАННАЯ вещь (22.10) -> её собственная иконка из assets/items/broken/:
##    это иконка того же металла с нарисованной трещиной
##    (tests/gen_broken_overlay.py). Общая иконка металла на земле врала бы:
##    игрок не понял бы, что подобрал сырьё для кузницы, а не целую вещь.
##    Иконки 60–80 px против 32 px у loot_icons, поэтому LootDrop масштабирует
##    от размера текстуры (loot_drop.gd:_build_ground_sprites).
##
## ВСЁ СТАТИКА: класс состояния не имеет, его нечему инстанцировать.

const LOOT_DIR := "res://assets/loot_icons/"
const INGOT_DIR := "res://assets/professions/blacksmith/"

## Слоты, которые в loot_icons показаны "оружием", остальные - "бронёй".
## Shield отдельно от оружия, но иконка у него одна - shield_weapon.
const WEAPON_SLOTS := ["weapon", "shield"]

## Тип зелья -> префикс баночки. Определяется по name_ru, потому что у зелий
## нет поля "материал" и общего признака в данных.
const POTION_HEALTH_WORDS := ["healing", "health", "regeneration", "леч", "здоров"]
const POTION_MANA_WORDS := ["mana", "мана", "маги"]


static func icon_for(item: Dictionary) -> String:
	## Путь к иконке лута для предмета ("" если иконки нет).
	if item.is_empty():
		return ""
	var key := str(item.get("key", ""))
	if key == "":
		return ""
	# Сломанное — до проверки слота: у сломанной вещи slot_of намеренно пуст
	# (надеть нельзя), и без этой ветки она бы получила иконку предмета
	# вообще, то есть общую с целой вещью того же вида.
	if ItemDB.is_broken(item):
		var broken := str(item.get("icon", ""))
		if broken != "" and ResourceLoader.exists(broken):
			return broken
	var mat := str(item.get("material", "")).to_lower()
	var slot := ItemDB.slot_of(item)
	var glyph := _loot_icon_for_material(mat, slot)
	if glyph != "":
		return glyph
	# не снаряжение - берём иконку самого предмета из item_db
	if ItemDB.is_craft_material(item) and str(item.get("quality", "")) == "Essence":
		var essence := EssenceIcons.icon()
		if essence != "":
			return essence
	return str(item.get("icon", ""))


static func gold_icon() -> String:
	# 03.10: раньше здесь был СЛИТОК (gold_ingot.png). Но слиток — это предмет
	# из item_db, а золото — число у игрока, и игрок искал слиток в инвентаре
	# после подбора. У золота теперь своя картинка — монета
	# (tests/gen_gold_coin.py, 32x32, тот же стиль, что у баночек).
	# 20.10: эта функция — только про ДЕНЬГИ. Снаряжение из золота рисуется
	# своими {gold}_weapon/_armor.png через _loot_icon_for_material().
	var coin := "%sgold_coin.png" % LOOT_DIR
	if ResourceLoader.exists(coin):
		return coin
	return "%sgold_ingot.png" % INGOT_DIR


## Ground-only animation frames (06.11): the AI-looking bottles made for loot
## on the ground. Inventory keeps the classic item icons; the drop animates.
static func ground_frames_for(item: Dictionary, size: String) -> Array:
	var key := str(item.get("key", ""))
	if key == "Boss Core":
		return _frames("boss")
	if str(item.get("quality", "")) == "Essence":
		return _frames("essence")
	if str(item.get("quality", "")) == "Potion":
		var kind := "mana" if _is_mana_potion(item) else "health"
		return _frames(kind)
	return []


static func _frames(kind: String) -> Array:
	var out: Array = []
	for i in range(4):
		var path := "%sbottle_%s_frame%02d.png" % [LOOT_DIR, kind, i]
		if not ResourceLoader.exists(path):
			return []
		out.append(load(path))
	return out


static func icon_for_potion(item: Dictionary, size: String) -> String:
	## Баночка по типу (health/mana) и размеру ("small"/"medium"/"large").
	## size определяет вызывающий код: слабый врач -> small, босс -> large.
	if size not in ["small", "medium", "large"]:
		size = "small"
	var kind := "mana" if _is_mana_potion(item) else "health"
	var p := "%s%s_%s_frame00.png" % [LOOT_DIR, kind, size]
	return p if ResourceLoader.exists(p) else ""


static func _loot_icon_for_material(mat: String, slot: String) -> String:
	if mat == "" or mat == "none":
		return ""
	if slot in WEAPON_SLOTS:
		return _existing("%s%s_weapon.png" % [LOOT_DIR, mat])
	# броня, аксессуары, плащи - всё идёт в *_armor. Аксессуаров в loot_icons
	# нет, поэтому для них честно возвращаем "" и вызывающий код берёт иконку
	# из item_db: кольцо, нарисованное как кольцо из того же металла, честнее
	# нагрудника.
	return _existing("%s%s_armor.png" % [LOOT_DIR, mat])


static func _existing(path: String) -> String:
	return path if ResourceLoader.exists(path) else ""


static func _is_mana_potion(item: Dictionary) -> bool:
	var text := (str(item.get("name_ru", "")) + " " + str(item.get("key", ""))).to_lower()
	for w in POTION_MANA_WORDS:
		if text.contains(w):
			return true
	for w in POTION_HEALTH_WORDS:
		if text.contains(w):
			return false
	return false


## Золото в мешке: сколько монет показать стопкой.
static func stack_preview(items: Array) -> int:
	## Сколько иконок рисовать на мешке (1..3). Больше трёх - каша: игрок всё
	## равно не разглядит, зато мешок станет неопознаваемым.
	var n := 0
	for it in items:
		if it is Dictionary:
			if it.has("gold") or it.has("key"):
				n += 1
		if n >= 3:
			break
	return maxi(1, n)
