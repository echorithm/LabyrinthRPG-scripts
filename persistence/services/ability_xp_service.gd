extends RefCounted
class_name AbilityXPService
## Ability XP-on-use with a pluggable, data-driven formula.
## Call award_on_use("fireball", ctx) from combat resolution.

const _S := preload("res://persistence/util/save_utils.gd")

const DEFAULT_SLOT: int = 1

# Tunables (adjust freely)
const BASE_XP: int = 5
const COOLDOWN_WEIGHT: float = 2.0
const COST_WEIGHT: float = 0.2           # per point of mana/stam cost
const FLOOR_SQRT_WEIGHT: float = 1.0     # sqrt(floor)*weight
const HIT_XP: float = 1.0                # per hit landed
const CRIT_XP: float = 3.0               # per crit
const KILL_XP: float = 10.0              # per kill
const ELITE_BONUS: int = 15
const BOSS_BONUS: int = 30
const OVERKILL_WEIGHT: float = 2.0       # overkill ratio (0..1+) * weight
const MIN_XP: int = 1
const MAX_XP: int = 100
const DIMINISH_PER_USE: float = 0.10     # -10% per prior use in the same run

# Public entrypoint -----------------------------------------------------------

static func award_on_use(ability_id: String, ctx_in: Dictionary, slot: int = DEFAULT_SLOT) -> Dictionary:
	# If the ability isn't unlocked, do nothing (design choice: permanent unlocks come from elsewhere)
	if not AbilityService.is_unlocked(ability_id, slot):
		return {}

	var ctx: Dictionary = _normalize_ctx(ctx_in)
	var raw_xp: int = _compute_xp(ctx)

	# Diminishing returns: read/advance per-run use count
	var rs: Dictionary = SaveManager.load_run(slot)
	var counts: Dictionary = _S.to_dict(_S.dget(rs, "ability_use_counts", {}))
	var used_before: int = int(counts.get(ability_id, 0))
	var diminish: float = max(0.0, 1.0 - float(used_before) * DIMINISH_PER_USE)
	var final_xp: int = clampi(int(round(float(raw_xp) * diminish)), MIN_XP, MAX_XP)

	counts[ability_id] = used_before + 1
	rs["ability_use_counts"] = counts
	SaveManager.save_run(rs, slot)

	return AbilityService.award_xp(ability_id, final_xp, slot)

# Formula ---------------------------------------------------------------------

static func _compute_xp(ctx: Dictionary) -> int:
	var floor_i: int = int(_S.dget(ctx, "floor", 1))
	var cd: int = int(_S.dget(ctx, "cooldown", 0))
	var mana_cost: int = int(_S.dget(ctx, "mana_cost", 0))
	var stam_cost: int = int(_S.dget(ctx, "stam_cost", 0))
	var hits: int = int(_S.dget(ctx, "hits", 0))
	var crits: int = int(_S.dget(ctx, "crits", 0))
	var kills: int = int(_S.dget(ctx, "kills", 0))
	var elite_kill: bool = bool(_S.dget(ctx, "elite_kill", false))
	var boss_kill: bool = bool(_S.dget(ctx, "boss_kill", false))
	var overkill_ratio: float = float(_S.dget(ctx, "overkill_ratio", 0.0)) # 0..1+

	var xp_f: float = float(BASE_XP)
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

# Normalizer ------------------------------------------------------------------

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
