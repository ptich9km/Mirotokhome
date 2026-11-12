# ============================================================================
# СЛОЙ 2 — SIM. «Мир живёт сам»: тик в ЖЁСТКОМ порядке из 7 шагов (эталон!):
#   1 TickGlobalThreat   глобальная угроза растёт со временем
#   2 TickFactions      фракции: энергия/ресурсы/отношения (utility-скоринг)
#   3 TickArmies        армии: находят врага, двигаются, воюют
#   4 TickSettlements   города: экономика/население/верность
#   5 TickEvents        события мира (бунт, знамение, караван…)
#   6 TickPlayer        «привилегированный» герой — регенерация/опыт
#   7 EmitWorldChanged  мир завершил тик — только ФАКТ, без ссылок на UI
#
# Слой 2 — чистый RefCounted. НИ ОДНОЙ Godot-ноды, как и WorldState.
# Сообщения только в state.journal (данные, сериализуются), UI их сам читает.
# ============================================================================
extends RefCounted
# NOTE (Слой-2 headless-canon): НЕТ `class_name WorldSim` и НЕТ типовых ссылок
# `WorldState` — headless `--quit`/`--script` парсит только по preload-путям.
# Всё взаимодействие слоёв — через const-пути в world_bus.gd, не по имени класса.

var state  # WorldState (данные), см. слой-1; здесь бестипово для headless-canon.

## Food eaten by one citizen per day.
const FOOD_PER_POP := 0.15
## Loyalty lost per unit of daily hunger.
const LOYALTY_PER_HUNGER := 0.1
## Loyalty regained on a day without hunger.
const LOYALTY_RECOVERY := 0.5


func _init(state_) -> void:
	state = state_


## `live` — тик из живой игры (WorldBus.tick_day), а не из headless sim_runner.
## В живой игре шаг TickPlayer пропускается: SIM-герой — отдельная сущность
## с собственным HP и уровнем, и его «Герой окреп (ур. N)» писал бы в журнал
## ложные события про настоящего героя.
func tick(live: bool = false) -> void:
	TickGlobalThreat()
	TickFactions()
	TickArmies()
	TickSettlements()
	TickEvents()
	if not live:
		TickPlayer()
	EmitWorldChanged()


# --- 1. Глобальная угроза -----------------------------------------------------
func TickGlobalThreat() -> void:
	state.global_threat = clampf(state.global_threat + 0.02, 0.0, 1.0)


# --- 2. Фракции (utility) ------------------------------------------------------
func TickFactions() -> void:
	for fid: String in state.factions:
		var f: Dictionary = state.factions[fid]
		var gold := int(f.get("gold", 0))
		var res := int(f.get("res", 0))
		f["gold"] = gold + 5 + randi_range(0, 5)
		f["res"] = res + 2
		f["threat_level"] = state.global_threat
		if randi_range(1, 20) == 1:
			f["mood"] = "_frai" if randi_range(0, 1) == 0 else "_hop"
		else:
			f["mood"] = "_calm"


## Спад могущества великого мага за ОДИН тик (реальное время, не sim-day).
## Возвращает НОВОЕ power (0..power_max), а не величину спада.
## Числа: [archmage] в game.cfg — проверены tests/sim_archmage_stakes.py.
func TickArchmage(power: float, threat: float) -> float:
	var max_power := 100.0
	var cfg = load("res://scripts/game_config.gd")
	if cfg != null:
		max_power = cfg.getf("archmage", "power_max")
	var d := _archmage_decay(threat)
	return clampf(power - d, 0.0, max_power)


func _archmage_decay(threat: float) -> float:
	var base := 0.0005
	var per_threat := 0.0015
	var cfg = load("res://scripts/game_config.gd")
	if cfg != null:
		base = cfg.getf("archmage", "decay_base")
		per_threat = cfg.getf("archmage", "decay_threat")
	return base + per_threat * threat


## Тик всех великих магов: спад + смена ступени (ровно одна запись в журнал).
## Вызывается ТОЛЬКО из WorldBus.archmage_tick — не из sim.tick().
func tick_archmages() -> void:
	_tick_archmages()


func _tick_archmages() -> void:
	if state == null:
		return
	for fid: String in state.factions:
		var f: Dictionary = state.factions[fid]
		var am: Variant = f.get("archmage", null)
		if not (am is Dictionary):
			continue
		var a: Dictionary = am
		if a.is_empty():
			continue
		var old_power := float(a.get("power", 0.0))
		var old_tier := int(a.get("tier", 1))
		var new_power := TickArchmage(old_power, state.global_threat)
		var new_tier := _archmage_tier(new_power)
		var new_stance := _archmage_stance(new_power)
		a["power"] = new_power
		a["tier"] = new_tier
		a["stance"] = new_stance
		f["archmage"] = a
		if new_tier != old_tier:
			var city := str(a.get("city", f.get("name", fid)))
			var mname := str(a.get("name", Loc.t("ui.sim.mage_default")))
			if new_tier > old_tier:
				_log("archmage", Loc.f("ui.sim.archmage_stronger", [city, mname, new_tier]))
			else:
				_log("archmage", Loc.f("ui.sim.archmage_weaker", [city, mname, new_tier]))


func _archmage_tier(power: float) -> int:
	var cfg = load("res://scripts/game_config.gd")
	if cfg == null:
		if power >= 90.0:
			return 3
		if power >= 65.0:
			return 2
		if power >= 35.0:
			return 1
		return 0
	if power >= cfg.getf("archmage", "tier_3"):
		return 3
	if power >= cfg.getf("archmage", "tier_2"):
		return 2
	if power >= cfg.getf("archmage", "tier_1"):
		return 1
	return 0


func _archmage_stance(power: float) -> String:
	var thr := 35.0
	var cfg = load("res://scripts/game_config.gd")
	if cfg != null:
		thr = cfg.getf("archmage", "tier_1")
	return "offensive" if power >= thr else "defensive"


# --- 3. Армии ------------------------------------------------------------------
func TickArmies() -> void:
	var killed: Array[String] = []
	for aid: String in state.armies:
		var a: Dictionary = state.armies[aid]
		var fid: String = a.get("faction_id", "")
		if fid == "" or not state.armies.has(aid):
			continue
		# Ищем ближайшего врага по отношению < 0.
		var eid := _find_enemy(aid, a, killed)
		if eid == "":
			continue
		a["enemy_id"] = eid
		_fight(aid, a)


func _find_enemy(aid: String, a: Dictionary, killed: Array) -> String:
	var my_fid: String = a.get("faction_id", "")
	var best := ""
	var best_d := 1.0e9
	for oid: String in state.armies:
		if oid == aid or oid in killed:
			continue
		var o: Dictionary = state.armies[oid]
		var ofid: String = o.get("faction_id", "")
		if ofid == my_fid:
			continue
		var rel: int = state.relations.get("%s:%s" % [my_fid, ofid], 0)
		if rel >= 0:
			continue
		var d: float = a.get("pos", Vector2.ZERO).distance_to(o.get("pos", Vector2.ZERO))
		if d < best_d:
			best_d = d
			best = oid
	return best


## Combat power of an army. `power` is a cache in the army record; 0 means
## "never computed", then it is derived from `unit_ids` (attack + half max_hp).
## Without it `WorldBus.reseed()` created armies with no power, losses were
## computed from 1 and a fight never ended (audit 30.09, 01-§3.3). Reset `power`
## to 0 when the roster changes and the next fight derives it again.
func _army_power(a: Dictionary) -> int:
	var p := int(a.get("power", 0))
	if p > 0:
		return p
	for uid in a.get("unit_ids", []):
		var u: Dictionary = state.units.get(str(uid), {})
		if u.is_empty():
			continue
		p += int(u.get("attack", 10)) + int(float(u.get("max_hp", 100)) * 0.5)
	a["power"] = p
	return p


func _fight(aid: String, a: Dictionary) -> void:
	var eid: String = a.get("enemy_id", "")
	if not state.armies.has(eid):
		a["enemy_id"] = ""
		return
	var e: Dictionary = state.armies[eid]
	var my_p := _army_power(a)
	var e_p := _army_power(e)
	if my_p <= 0 or e_p <= 0:
		a["enemy_id"] = ""
		return
	# Losses come from the OPPONENT's strength. Losses proportional to one's own
	# power decay geometrically and `int()` rounds down to 0 long before 0, so
	# two armies traded blows forever (audit 30.09, 01-§3.3). At least 1 per
	# tick guarantees a decisive end.
	var my_loss := maxi(1, int(float(e_p) * 0.15))
	var e_loss := maxi(1, int(float(my_p) * 0.15))
	a["power"] = maxi(0, my_p - my_loss)
	e["power"] = maxi(0, e_p - e_loss)
	# Even armies annihilate each other in one tick; handling it explicitly
	# avoids leaving a "power 0" husk on the map that can never fight again.
	if a["power"] <= 0 and e["power"] <= 0:
		_log("battle", Loc.f("ui.sim.armies_mutual", [aid, eid]))
		state.armies.erase(aid)
		state.armies.erase(eid)
		return
	var winner := ""
	if a["power"] <= 0:
		winner = eid
	elif e["power"] <= 0:
		winner = aid
	if winner != "":
		_log("battle", Loc.f("ui.sim.army_won",
			[winner, (aid if winner == eid else eid)]))
		state.armies.erase(winner if winner == eid else aid)


# --- 4. Города ------------------------------------------------------------------
## Economy lives in `cities[].economy` (see WorldState.city_economy); the flat
## keys the first version of this tick read simply did not exist, so every city
## was permanently broke and starving no matter what the data said.
func TickSettlements() -> void:
	for cid: String in state.cities:
		var c: Dictionary = state.cities[cid]
		var eco: Dictionary = state.city_economy(c)
		var pop := int(c.get("population", 100))
		var prod := float(eco.get("prod", 5.0))
		var net := prod - pop * FOOD_PER_POP
		# The granary cannot hold a negative amount: hunger is the daily deficit
		# (`hunger_of`), not a debt that keeps growing below zero.
		eco["food"] = maxf(0.0, float(eco.get("food", 100.0)) + net)
		eco["gold"] = float(eco.get("gold", 50.0)) + prod
		if net > 0.0:
			c["population"] = pop + 1
		elif net < 0.0:
			c["population"] = maxi(1, pop - 1)
		var hunger := hunger_of(net)
		var loyalty := float(c.get("loyalty", 50.0))
		if hunger > 0.0:
			loyalty -= hunger * LOYALTY_PER_HUNGER
		else:
			loyalty += LOYALTY_RECOVERY
		c["loyalty"] = clampf(loyalty, 0.0, 100.0)
		# Once per 10 days: a hungry city would otherwise write one revolt line
		# per day and flood the journal (cap 400 in the live game).
		if c["loyalty"] < 15.0 and state.day % 10 == 0:
			_log("revolt", Loc.f("ui.sim.revolt",
				[c.get("name", cid), int(c["loyalty"])]))


## How hard hunger is felt today. Only a deficit counts: a surplus is not
## "negative hunger". The old `felt()` returned `abs`, so abundance lowered
## loyalty exactly like famine did, which made the function pointless.
func hunger_of(net: float) -> float:
	return maxf(0.0, -net)


# --- 5. События -----------------------------------------------------------------
func TickEvents() -> void:
	if state.day % 10 == 0 and randi_range(1, 3) == 1:
		_log("omen", Loc.f("ui.sim.threat", [state.day]))
	if state.day % 30 == 0:
		_log("faction", Loc.t("ui.sim.diplomacy"))


# --- 6. Игрок (но SIM знает про него как про юнита, не как про UI) -------------
func TickPlayer() -> void:
	var h: Dictionary = state.hero
	h["curr_hp"] = mini(int(h.get("max_hp", 100)), int(h.get("curr_hp", 100)) + 3)
	h["level"] = int(h.get("level", 1))
	if state.day % 7 == 0:
		h["level"] += 1
		_log("hero", Loc.f("ui.sim.hero_level", [h["level"]]))


# --- 7. Факт завершения тика (без ссылок на UI/ноды) ---------------------------
func EmitWorldChanged() -> void:
	state.day += 1


func _log(kind: String, text: String) -> void:
	state.log_entry(kind, text)
