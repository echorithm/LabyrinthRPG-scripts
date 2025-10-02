# res://persistence/services/village_service.gd
extends RefCounted
class_name VillageService

const _S := preload("res://persistence/util/save_utils.gd")
const _Schema := preload("res://persistence/schemas/village_schema.gd")
const _Wallet := preload("res://persistence/services/village_wallet.gd")
const _Prog := preload("res://persistence/services/progression_service.gd")

const PATH_COSTS   : String = "res://data/village/cost_curves.json"
const PATH_CAMP    : String = "res://data/village/camp_perks.json"
const PATH_CATALOG : String = "res://data/village/buildings_catalog.json" # RTS + services (incl. trainers)

var _costs: Dictionary = {}
var _camp: Dictionary = {}
var _catalog: Dictionary = {}
var _loaded: bool = false

func _ensure_loaded() -> void:
	if _loaded:
		return
	_costs = _load_json(PATH_COSTS)
	_camp = _load_json(PATH_CAMP)
	_catalog = _load_json(PATH_CATALOG)
	_loaded = true

static func _load_json(path: String) -> Dictionary:
	if not ResourceLoader.exists(path):
		push_error("[VillageService] Missing data: " + path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return (parsed as Dictionary) if typeof(parsed) == TYPE_DICTIONARY else {}

# -------------------------------------------------------------------
# Camp
# -------------------------------------------------------------------

static func get_camp_level(slot: int = 1) -> int:
	var gs: Dictionary = SaveManager.load_game(slot)
	var fixed: Dictionary = _Schema.migrate_into(gs)
	if not gs.has("village"):
		SaveManager.save_game(fixed, slot)
	var v: Dictionary = _S.to_dict(fixed.get("village", {}))
	return int(_S.dget(v, "camp_level", 0))

func next_camp_cost(level_now: int) -> Dictionary:
	_ensure_loaded()
	var c: Dictionary = _S.to_dict(_S.dget(_costs, "camp", {}))
	var base_g: float = float(_S.dget(c, "base_gold", 300.0))
	var g1: float     = float(_S.dget(c, "gold_step", 0.25))
	var pow_g: float  = float(_S.dget(c, "gold_power", 1.15))

	var base_s: float = float(_S.dget(c, "base_shards", 1.0))
	var s1: float     = float(_S.dget(c, "shard_step_l", 0.8))
	var s2: float     = float(_S.dget(c, "shard_step_q", 0.25))

	var l: float = float(level_now)
	var gold: int = int(round(base_g * pow(1.0 + g1 * l, pow_g)))
	var shards: int = int(round(base_s + s1 * l + s2 * pow(l, 1.2)))
	return { "gold": max(0, gold), "shards": max(0, shards) }

func camp_level_name(level: int) -> String:
	_ensure_loaded()
	var names: Array = (_S.dget(_camp, "names", []) as Array)
	if names.is_empty():
		return "Camp L%d" % level
	var idx: int = clampi(level, 0, names.size() - 1)
	return String(names[idx])

func camp_perks_for_level(level: int) -> Dictionary:
	_ensure_loaded()
	var rows: Array = (_S.dget(_camp, "levels", []) as Array)
	for any in rows:
		if any is Dictionary and int(_S.dget(any, "level", -1)) == level:
			return (any as Dictionary).duplicate(true)
	return {
		"level": level,
		"name": camp_level_name(level),
		"perks": {
			"well_rested_ctb_pct": 3 * level,
			"rest_resist_pct": 2 * level,
			"overheal_carry_pct": int(5.0 * (float(level) / 2.0))
		},
		"milestones": []
	}

static func can_upgrade_camp(slot: int = 1) -> Dictionary:
	var lvl_now: int = get_camp_level(slot)
	var svc := VillageService.new()
	var cost: Dictionary = svc.next_camp_cost(lvl_now)
	var afford: bool = _Wallet.can_afford(int(cost["gold"]), int(cost["shards"]), slot)
	return {
		"can": afford,
		"cost": cost,
		"level_now": lvl_now,
		"level_next": (lvl_now + 1)
	}

static func upgrade_camp(slot: int = 1) -> Dictionary:
	var gs: Dictionary = SaveManager.load_game(slot)
	gs = _Schema.migrate_into(gs)
	var v: Dictionary = _S.to_dict(gs.get("village", {}))

	var level_now: int = int(_S.dget(v, "camp_level", 0))
	var svc := VillageService.new()
	var cost: Dictionary = svc.next_camp_cost(level_now)

	if not _Wallet.can_afford(int(cost["gold"]), int(cost["shards"]), slot):
		return { "ok": false, "reason": "insufficient_funds", "cost": cost, "level_now": level_now }
	if not _Wallet.spend(int(cost["gold"]), int(cost["shards"]), "camp_upgrade", slot):
		return { "ok": false, "reason": "spend_failed", "cost": cost, "level_now": level_now }

	var new_level: int = level_now + 1
	v["camp_level"] = new_level
	gs["village"] = v
	gs["updated_at"] = _S.now_ts()
	SaveManager.save_game(gs, slot)

	try_unlock_all(slot)

	print("[Village] Camp upgraded to L", new_level, " (", VillageService.new().camp_level_name(new_level), ")")
	return { "ok": true, "new_level": new_level, "spent": cost }

# -------------------------------------------------------------------
# Buildings (RTS + Services + Trainers)
# -------------------------------------------------------------------

func _cat_row(id: String) -> Dictionary:
	_ensure_loaded()
	var arr: Array = (_S.dget(_catalog, "buildings", []) as Array)
	for any in arr:
		if any is Dictionary and String(_S.dget(any, "id", "")) == id:
			return (any as Dictionary)
	return {}

# Static-friendly catalog row fetch
static func _cat_row_s(id: String) -> Dictionary:
	var svc := VillageService.new()
	svc._ensure_loaded()
	var arr: Array = (_S.dget(svc._catalog, "buildings", []) as Array)
	for any in arr:
		if any is Dictionary and String(_S.dget(any, "id", "")) == id:
			return (any as Dictionary)
	return {}

# ---- Trainer helpers (static so they can be used in static upgrade()) ----

static func _is_trainer(id: String) -> bool:
	var row: Dictionary = _cat_row_s(id)
	if row.is_empty():
		return false
	var groups_any: Variant = row.get("ability_groups")
	return (groups_any is Array) and ((groups_any as Array).size() > 0)

static func _trainer_groups(id: String) -> Array[String]:
	var out: Array[String] = []
	var row: Dictionary = _cat_row_s(id)
	if row.is_empty():
		return out
	var g_any: Variant = row.get("ability_groups")
	if g_any is Array:
		for v in (g_any as Array):
			var s := String(v)
			if s != "":
				out.append(s)
	return out

static func _unlock_groups_for_trainer(trainer_id: String, slot: int) -> void:
	var groups: Array[String] = _trainer_groups(trainer_id)
	if groups.is_empty():
		return
	for g in groups:
		_Prog.unlock_all_in_group(g, slot)

# -------------------------------------------------------------------

static func is_unlocked(id: String, slot: int = 1) -> bool:
	var gs: Dictionary = SaveManager.load_game(slot)
	var fixed: Dictionary = _Schema.migrate_into(gs)
	var v: Dictionary = _S.to_dict(fixed.get("village", {}))
	var u: Dictionary = _S.to_dict(v.get("unlocked", {}))
	return bool(_S.dget(u, id, false))

static func set_unlocked(id: String, unlocked: bool, slot: int = 1) -> void:
	var gs: Dictionary = SaveManager.load_game(slot)
	gs = _Schema.migrate_into(gs)
	var v: Dictionary = _S.to_dict(gs.get("village", {}))
	var u: Dictionary = _S.to_dict(v.get("unlocked", {}))
	u[id] = unlocked
	v["unlocked"] = u
	gs["village"] = v
	gs["updated_at"] = _S.now_ts()
	SaveManager.save_game(gs, slot)

static func try_unlock_all(slot: int = 1) -> void:
	var svc := VillageService.new()
	svc._ensure_loaded()

	var gs: Dictionary = SaveManager.load_game(slot)
	gs = _Schema.migrate_into(gs)
	var v: Dictionary = _S.to_dict(gs.get("village", {}))
	var u: Dictionary = _S.to_dict(v.get("unlocked", {}))
	var camp_level: int = int(_S.dget(v, "camp_level", 0))

	var blds: Array = (_S.dget(svc._catalog, "buildings", []) as Array)
	for any in blds:
		if not (any is Dictionary):
			continue
		var row: Dictionary = any
		var id: String = String(_S.dget(row, "id", ""))
		if id.is_empty():
			continue
		if bool(_S.dget(u, id, false)):
			continue

		var conds: Array = (_S.dget(row, "unlock_conditions", []) as Array)
		var ok: bool = true
		for c_any in conds:
			if not (c_any is Dictionary):
				continue
			var typ: String = String(_S.dget(c_any, "type", ""))
			match typ:
				"camp_level_at_least":
					var vmin: int = int(_S.dget(c_any, "value", 0))
					if camp_level < vmin:
						ok = false
				_:
					pass
		if ok:
			u[id] = true
			print("[Village] Unlocked building: ", id)

	v["unlocked"] = u
	gs["village"] = v
	gs["updated_at"] = _S.now_ts()
	SaveManager.save_game(gs, slot)

static func get_level(id: String, slot: int = 1) -> int:
	if id == "camp":
		return get_camp_level(slot)
	var gs: Dictionary = SaveManager.load_game(slot)
	var fixed: Dictionary = _Schema.migrate_into(gs)
	var v: Dictionary = _S.to_dict(fixed.get("village", {}))
	var b: Dictionary = _S.to_dict(v.get("buildings", {}))
	if ["farms", "trade", "housing"].has(id):
		return int(_S.dget(_S.to_dict(b.get("rts", {})), id, 0))
	return int(_S.dget(_S.to_dict(b.get("services", {})), id, 0))

static func set_level(id: String, new_level: int, slot: int = 1) -> void:
	var gs: Dictionary = SaveManager.load_game(slot)
	gs = _Schema.migrate_into(gs)
	var v: Dictionary = _S.to_dict(gs.get("village", {}))
	var b: Dictionary = _S.to_dict(v.get("buildings", {}))

	if ["farms", "trade", "housing"].has(id):
		var rts: Dictionary = _S.to_dict(b.get("rts", {}))
		rts[id] = max(0, new_level)
		b["rts"] = rts
	else:
		var svc_tbl: Dictionary = _S.to_dict(b.get("services", {}))
		svc_tbl[id] = max(0, new_level)
		b["services"] = svc_tbl

	v["buildings"] = b
	gs["village"] = v
	gs["updated_at"] = _S.now_ts()
	SaveManager.save_game(gs, slot)

func next_cost_for(id: String, level_now: int) -> Dictionary:
	_ensure_loaded()
	var cat: Dictionary = _cat_row(id)
	var curve_id: String = String(_S.dget(cat, "cost_curve", ""))
	var curve: Dictionary
	if curve_id != "":
		curve = _S.to_dict(_S.dget(_costs, curve_id, {}))
	else:
		var kind: String = String(_S.dget(cat, "kind", "service"))
		curve = _S.to_dict(_S.dget(_costs, kind, {}))

	var base_g: float = float(_S.dget(curve, "base_gold", 300.0))
	var g1: float     = float(_S.dget(curve, "gold_step", 0.25))
	var pow_g: float  = float(_S.dget(curve, "gold_power", 1.15))

	var base_s: float = float(_S.dget(curve, "base_shards", 1.0))
	var s1: float     = float(_S.dget(curve, "shard_step_l", 0.8))
	var s2: float     = float(_S.dget(curve, "shard_step_q", 0.25))

	var l: float = float(level_now)
	var gold: int = int(round(base_g * pow(1.0 + g1 * l, pow_g)))
	var shards: int = int(round(base_s + s1 * l + s2 * pow(l, 1.2)))
	return { "gold": max(0, gold), "shards": max(0, shards) }

# --------- Formulaic RTS prereqs (infinite-safe) -------------------

func _meets_prereqs(id: String, level_next: int, slot: int) -> bool:
	_ensure_loaded()

	# non-trainers: honor static JSON prereqs
	if not _is_trainer(id):
		var cat: Dictionary = _cat_row(id)
		var reqs_by_level: Dictionary = _S.to_dict(_S.dget(cat, "rts_requires", {}))
		if reqs_by_level.is_empty():
			return true
		var req: Dictionary = _S.to_dict(reqs_by_level.get(str(level_next), {}))
		if req.is_empty():
			return true

		var r_f: int = get_level("farms", slot)
		var r_t: int = get_level("trade", slot)
		var r_h: int = get_level("housing", slot)

		var need_f: int = int(_S.dget(req, "farms", 0))
		var need_t: int = int(_S.dget(req, "trade", 0))
		var need_h: int = int(_S.dget(req, "housing", 0))

		return (r_f >= need_f and r_t >= need_t and r_h >= need_h)

	# Trainers: infinite formula based on tier T = floor((L-1)/3)
	var L_next: int = max(1, level_next)
	var T: int = int(floor(float(L_next - 1) / 3.0))

	var farms_need: int = 0
	var trade_need: int = 0
	var housing_need: int = 0

	var groups: Array[String] = _trainer_groups(id)
	var group: String = ""
	if groups.size() > 0:
		group = groups[0]

	# Defaults per family (weights in "units"; ceil to int levels)
	if group in ["spear","sword","mace","bow"]:
		var trade_weight: float = 1.0
		if group == "bow":
			trade_weight = 1.5
		housing_need = int(ceil(float(T) * 1.0))
		trade_need   = int(ceil(float(T) * trade_weight))
		farms_need   = 0
	elif group in ["fire","water","wind","earth"]:
		var farms_w: float = 1.0
		var trade_w: float = 1.0
		if group == "fire":
			trade_w = 1.5
		if group == "water" or group == "earth":
			farms_w = 1.5
		farms_need  = int(ceil(float(T) * farms_w))
		trade_need  = int(ceil(float(T) * trade_w))
		housing_need = 0
	elif group == "light":
		housing_need = int(ceil(float(T) * 1.5))
		trade_need   = int(ceil(float(T) * 0.5))
		farms_need   = 0
	elif group == "dark":
		trade_need   = int(ceil(float(T) * 1.5))
		housing_need = int(ceil(float(T) * 0.5))
		farms_need   = 0
	elif group == "defense":
		housing_need = int(ceil(float(T) * 1.0))
		farms_need   = int(ceil(float(T) * 1.0))
		trade_need   = 0
	else:
		farms_need = 0
		trade_need = 0
		housing_need = 0

	var r_f: int = get_level("farms", slot)
	var r_t: int = get_level("trade", slot)
	var r_h: int = get_level("housing", slot)

	return (r_f >= farms_need and r_t >= trade_need and r_h >= housing_need)

# --------- Public upgrade surface ----------------------------------

static func can_upgrade(id: String, slot: int = 1) -> Dictionary:
	if id == "camp":
		return can_upgrade_camp(slot)

	if not is_unlocked(id, slot):
		return { "can": false, "reason": "locked", "level_now": get_level(id, slot) }

	var svc := VillageService.new()
	var lvl: int = get_level(id, slot)
	var cost: Dictionary = svc.next_cost_for(id, lvl)
	var prereq_ok: bool = svc._meets_prereqs(id, lvl + 1, slot)
	var afford: bool = _Wallet.can_afford(int(cost["gold"]), int(cost["shards"]), slot)

	var reason: String = ""
	if not prereq_ok:
		reason = "prereq_fail"
	elif not afford:
		reason = "insufficient_funds"

	return {
		"can": (prereq_ok and afford),
		"reason": reason,
		"cost": cost,
		"level_now": lvl,
		"level_next": (lvl + 1)
	}

static func upgrade(id: String, slot: int = 1) -> Dictionary:
	if id == "camp":
		return upgrade_camp(slot)
	if not is_unlocked(id, slot):
		return { "ok": false, "reason": "locked" }

	var chk: Dictionary = can_upgrade(id, slot)
	if not bool(_S.dget(chk, "can", false)):
		return { "ok": false, "reason": String(_S.dget(chk, "reason", "cannot")) }

	var cost: Dictionary = _S.to_dict(_S.dget(chk, "cost", {}))
	if not _Wallet.spend(int(_S.dget(cost, "gold", 0)), int(_S.dget(cost, "shards", 0)), "building_upgrade:" + id, slot):
		return { "ok": false, "reason": "spend_failed" }

	var before_level: int = get_level(id, slot)
	var new_level: int = before_level + 1
	set_level(id, new_level, slot)
	print("[Village] Upgraded ", id, " -> L", new_level)

	# Trainers: L1 unlocks their group immediately; any upgrade should recompute caps.
	if _is_trainer(id):
		if before_level <= 0 and new_level >= 1:
			_unlock_groups_for_trainer(id, slot)
		# Always recompute caps after trainer level change
		_Prog.recompute_all_skill_caps(slot)

	return { "ok": true, "new_level": new_level, "spent": cost }

# --------- Village → Run benefits (unchanged) ----------------------------

static func derive_run_benefits(slot: int = 1) -> Dictionary:
	var gs: Dictionary = SaveManager.load_game(slot)
	gs = _Schema.migrate_into(gs)

	var v: Dictionary = _S.to_dict(gs.get("village", {}))
	var camp_level: int = int(_S.dget(v, "camp_level", 0))

	var b: Dictionary = _S.to_dict(v.get("buildings", {}))
	var rts: Dictionary = _S.to_dict(b.get("rts", {}))
	var svc: Dictionary = _S.to_dict(b.get("services", {}))

	var mods: Dictionary = {}
	var ids: Array[String] = []

	if camp_level > 0:
		_addf(mods, "ctb_cost_reduction_pct", 0.5 * float(camp_level))
		_addf(mods, "status_resist_pct",       1.0 * float(camp_level))
		ids.append("camp_L%d" % camp_level)

	var farms: int   = _get_level_from(rts, "farms")
	var trade: int   = _get_level_from(rts, "trade")
	var housing: int = _get_level_from(rts, "housing")

	if farms > 0:
		_addf(mods, "life_on_hit_flat", 0.30 * float(farms))
	if trade > 0:
		_addf(mods, "gold_find_pct",    2.00 * float(trade))
	if housing > 0:
		_addf(mods, "carry_capacity_flat", 1.0 * float(housing))

	var inn: int        = _get_level_from(svc, "inn")
	var trainer_old: int    = _get_level_from(svc, "trainer") # legacy single trainer, may remain 0
	var temple: int     = _get_level_from(svc, "temple")
	var blacksmith: int = _get_level_from(svc, "blacksmith")
	var alchemist: int  = _get_level_from(svc, "alchemist")
	var library: int    = _get_level_from(svc, "library")
	var guild: int      = _get_level_from(svc, "guild")

	if inn > 0:
		_addf(mods, "ctb_cost_reduction_pct", 1.0 * float(inn))
		ids.append("inn_L%d" % inn)

	if trainer_old > 0:
		_addf(mods, "skill_xp_gain_pct", 2.0 * float(trainer_old))
		ids.append("trainer_L%d" % trainer_old)

	if temple > 0:
		_addf(mods, "status_resist_pct", 1.5 * float(temple))
		ids.append("temple_L%d" % temple)

	if blacksmith > 0:
		_addf(mods, "flat_power",       1.0 * float(blacksmith))
		_addf(mods, "crit_chance_pct",  0.5 * float(blacksmith))
		ids.append("blacksmith_L%d" % blacksmith)

	if alchemist > 0:
		_addf(mods, "life_on_hit_flat", 0.5 * float(alchemist))
		_addf(mods, "mana_on_hit_flat", 0.5 * float(alchemist))
		ids.append("alchemist_L%d" % alchemist)

	if library > 0:
		_addf(mods, "gold_find_pct", 1.0 * float(library))
		ids.append("library_L%d" % library)

	if guild > 0:
		_addf(mods, "ctb_on_kill_pct", 1.0 * float(guild))
		_addf(mods, "dodge_chance_pct", 0.5 * float(guild))
		ids.append("guild_L%d" % guild)

	return { "mods": mods, "buff_ids": ids }

static func _addf(mods: Dictionary, key: String, v: float) -> void:
	mods[key] = float(mods.get(key, 0.0)) + float(v)

static func _get_level_from(dict_in: Dictionary, id: String) -> int:
	return int(dict_in.get(id, 0))

# --------- UI Helpers ---------------------------------------------------

# Utility
static func list_all_buildings() -> Array[String]:
	# Prefer the catalog so new buildings don’t require code edits.
	var ids: Array[String] = catalog_ids()
	# Prepend camp (catalog doesn’t include it)
	if not ids.has("camp"):
		ids.push_front("camp")
	return ids


static func catalog_ids() -> Array[String]:
	var out: Array[String] = []
	var svc := VillageService.new()
	svc._ensure_loaded()
	var arr: Array = (svc._catalog.get("buildings", []) as Array)
	for any in arr:
		if any is Dictionary:
			var id := String(any.get("id", ""))
			if id != "":
				out.append(id)
	return out

static func display_name(id: String) -> String:
	var row := _cat_row_s(id)
	if row.is_empty():
		return id
	var disp := String(row.get("display", ""))
	if disp != "":
		return disp
	return id

# --------- Public: trainer tier for a group -----------------------------

static func trainer_tier_for_group(group_id: String, slot: int = 1) -> int:
	var svc := VillageService.new()
	svc._ensure_loaded()
	var arr: Array = (_S.dget(svc._catalog, "buildings", []) as Array)
	var level_for_group: int = 0
	for any in arr:
		if not (any is Dictionary):
			continue
		var row: Dictionary = any
		var id: String = String(_S.dget(row, "id", ""))
		if id == "":
			continue
		var gs_any: Variant = row.get("ability_groups")
		if gs_any is Array:
			for g_any in (gs_any as Array):
				if String(g_any) == group_id:
					level_for_group = max(level_for_group, get_level(id, slot))
	# tier = floor((L-1)/3); cap never negative
	return int(floor(float(max(0, level_for_group) - 1) / 3.0))
