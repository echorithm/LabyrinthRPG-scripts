extends RefCounted
class_name AbilityXPService

const _S := preload("res://persistence/util/save_utils.gd")
const AbilityService := preload("res://persistence/services/ability_service.gd") # used only for is_unlocked
const XpTuning := preload("res://scripts/rewards/XpTuning.gd")

const DEFAULT_SLOT: int = 1

# Tunables
const BASE_XP: int = 5
const COOLDOWN_WEIGHT: float = 2.0
const COST_WEIGHT: float = 0.2
const FLOOR_SQRT_WEIGHT: float = 1.0
const HIT_XP: float = 1.0
const CRIT_XP: float = 3.0
const KILL_XP: float = 10.0
const ELITE_BONUS: int = 15
const BOSS_BONUS: int = 30
const OVERKILL_WEIGHT: float = 2.0
const MIN_XP: int = 1
const MAX_XP: int = 100
const DIMINISH_PER_USE: float = 0.10

static func award_on_use_provisional(encounter_id: int, ability_id: String, ctx_in: Dictionary, slot: int = DEFAULT_SLOT) -> void:
	if ability_id.is_empty() or encounter_id <= 0:
		return
	if not AbilityService.is_unlocked(ability_id, slot):
		return

	var ctx := _normalize_ctx(ctx_in)
	var raw_xp := _compute_xp(ctx)

	var rs := SaveManager.load_run(slot)
	var counts: Dictionary = _S.to_dict(_S.dget(rs, "ability_use_counts", {}))
	var used_before := int(_S.dget(counts, ability_id, 0))
	var diminish: Variant = max(0.0, 1.0 - float(used_before) * DIMINISH_PER_USE)
	var xp_final := clampi(int(round(float(raw_xp) * diminish)), MIN_XP, MAX_XP)

	counts[ability_id] = used_before + 1
	rs["ability_use_counts"] = counts

	var pend_all: Dictionary = _S.to_dict(_S.dget(rs, "ability_xp_pending", {}))
	var key := str(encounter_id)
	var pend: Dictionary = _S.to_dict(_S.dget(pend_all, key, {}))
	pend[ability_id] = int(_S.dget(pend, ability_id, 0)) + xp_final
	pend_all[key] = pend
	rs["ability_xp_pending"] = pend_all
	SaveManager.save_run(rs, slot)

static func commit_encounter(encounter_id: int, slot: int = DEFAULT_SLOT) -> Array:
	var rs := SaveManager.load_run(slot)
	var pend_all: Dictionary = _S.to_dict(_S.dget(rs, "ability_xp_pending", {}))
	var key := str(encounter_id)
	if not pend_all.has(key):
		return []
	var pend: Dictionary = _S.to_dict(pend_all[key])

	var out: Array = []
	for aid_any in pend.keys():
		var aid := String(aid_any)
		var xp_add := int(pend[aid_any])
		if xp_add <= 0:
			continue
		var after: Dictionary = SaveManager.apply_skill_xp_to_run(aid, xp_add, slot)
		out.append({
			"id": aid,
			"xp": xp_add,
			"new_level": int(_S.dget(after, "level", 1))
		})
	pend_all.erase(key)
	rs["ability_xp_pending"] = pend_all
	SaveManager.save_run(rs, slot)
	return out

static func discard_encounter(encounter_id: int, slot: int = DEFAULT_SLOT) -> void:
	var rs := SaveManager.load_run(slot)
	var pend_all: Dictionary = _S.to_dict(_S.dget(rs, "ability_xp_pending", {}))
	var key := str(encounter_id)
	if pend_all.has(key):
		pend_all.erase(key)
		rs["ability_xp_pending"] = pend_all
		SaveManager.save_run(rs, slot)

# Legacy immediate award -> now writes to RUN
static func award_on_use(ability_id: String, ctx_in: Dictionary, slot: int = DEFAULT_SLOT) -> Dictionary:
	if not AbilityService.is_unlocked(ability_id, slot):
		return {}
	var ctx := _normalize_ctx(ctx_in)
	var raw_xp := _compute_xp(ctx)

	var rs := SaveManager.load_run(slot)
	var counts: Dictionary = _S.to_dict(_S.dget(rs, "ability_use_counts", {}))
	var used_before := int(_S.dget(counts, ability_id, 0))
	var diminish: Variant = max(0.0, 1.0 - float(used_before) * DIMINISH_PER_USE)
	var final_xp := clampi(int(round(float(raw_xp) * diminish)), MIN_XP, MAX_XP)
	counts[ability_id] = used_before + 1
	rs["ability_use_counts"] = counts
	SaveManager.save_run(rs, slot)

	return SaveManager.apply_skill_xp_to_run(ability_id, final_xp, slot)

# --- internals (unchanged math) ---
static func _compute_xp(ctx: Dictionary) -> int:
	var floor_i := int(_S.dget(ctx, "floor", 1))
	var cd := int(_S.dget(ctx, "cooldown", 0))
	var mana_cost := int(_S.dget(ctx, "mana_cost", 0))
	var stam_cost := int(_S.dget(ctx, "stam_cost", 0))
	var hits := int(_S.dget(ctx, "hits", 0))
	var crits := int(_S.dget(ctx, "crits", 0))
	var kills := int(_S.dget(ctx, "kills", 0))
	var elite_kill := bool(_S.dget(ctx, "elite_kill", false))
	var boss_kill := bool(_S.dget(ctx, "boss_kill", false))
	var overkill_ratio := float(_S.dget(ctx, "overkill_ratio", 0.0))

	var xp_f := float(BASE_XP)
	xp_f += float(cd) * COOLDOWN_WEIGHT
	xp_f += float(mana_cost + stam_cost) * COST_WEIGHT
	xp_f += sqrt(float(max(1, floor_i))) * FLOOR_SQRT_WEIGHT
	xp_f += float(hits) * HIT_XP
	xp_f += float(crits) * CRIT_XP
	xp_f += float(kills) * KILL_XP
	if elite_kill: xp_f += float(ELITE_BONUS)
	if boss_kill: xp_f += float(BOSS_BONUS)
	xp_f += clampf(overkill_ratio, 0.0, 5.0) * OVERKILL_WEIGHT
	return clampi(int(round(xp_f)), MIN_XP, MAX_XP)

static func _normalize_ctx(ctx_any: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	out["floor"] = max(1, int(_S.dget(ctx_any, "floor", 1)))
	out["cooldown"] = max(0, int(_S.dget(ctx_any, "cooldown", 0)))
	out["mana_cost"] = max(0, int(_S.dget(ctx_any, "mana_cost", 0)))
	out["stam_cost"] = max(0, int(_S.dget(ctx_any, "stam_cost", 0)))
	out["hits"] = max(0, int(_S.dget(ctx_any, "hits", 0)))
	out["crits"] = max(0, int(_S.dget(ctx_any, "crits", 0)))
	out["kills"] = max(0, int(_S.dget(ctx_any, "kills", 0)))
	out["elite_kill"] = bool(_S.dget(ctx_any, "elite_kill", false))
	out["boss_kill"] = bool(_S.dget(ctx_any, "boss_kill", false))
	out["overkill_ratio"] = max(0.0, float(_S.dget(ctx_any, "overkill_ratio", 0.0)))
	return out

static func commit_all_pending(slot: int = DEFAULT_SLOT) -> Array:
	var rs := SaveManager.load_run(slot)
	var pend_all: Dictionary = _S.to_dict(_S.dget(rs, "ability_xp_pending", {}))
	var out: Array = []
	for key in pend_all.keys():
		var pend: Dictionary = _S.to_dict(pend_all[key])
		for aid_any in pend.keys():
			var aid := String(aid_any)
			var xp_add := int(pend[aid_any])
			if xp_add <= 0:
				continue
			var after: Variant = SaveManager.apply_skill_xp_to_run(aid, xp_add, slot)
			out.append({
				"id": aid,
				"xp": xp_add,
				"new_level": int(_S.dget(after, "level", 1)),
				"xp_current": int(_S.dget(after, "xp_current", 0)),
				"xp_needed": int(_S.dget(after, "xp_needed", 90)),
			})
	rs["ability_xp_pending"] = {}
	SaveManager.save_run(rs, slot)
	return out
	


static func grant_now(ability_id: String, xp_add: int, slot: int = SaveManager.DEFAULT_SLOT) -> Dictionary:
	var aid: String = String(ability_id)
	var add_i: int = int(xp_add)
	if aid == "" or add_i <= 0:
		return {}
	return SaveManager.apply_skill_xp_to_run(aid, add_i, slot)

# If you still have a "settle_pending" somewhere:
static func settle_pending(slot: int = SaveManager.DEFAULT_SLOT) -> void:
	# No-op by design now; everything is applied immediately.
	# Leave here for compatibility with any old call sites.
	pass
