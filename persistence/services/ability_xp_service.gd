# res://persistence/services/ability_xp_service.gd
extends RefCounted
class_name AbilityXPService

const AbilityService := preload("res://persistence/services/ability_service.gd")
const XpTuning := preload("res://scripts/rewards/XpTuning.gd")
const SaveManager := preload("res://persistence/SaveManager.gd")

const DEFAULT_SLOT: int = 1

# Pending usage map: encounter_id -> { ability_id -> { enemy_index:int -> uses:int } }
static var _pending: Dictionary = {}   # ← make static so static funcs can access it

## Record a use during combat. ctx may contain:
##  - "enemy_index": int   (single target)
##  - "enemy_indices": Array[int] (multi/AoE)
static func award_on_use_provisional(encounter_id: int, ability_id: String, ctx: Dictionary, slot: int = DEFAULT_SLOT) -> void:
	if encounter_id <= 0 or ability_id.is_empty():
		return
	if not AbilityService.is_unlocked(ability_id, slot):
		return
	if not _pending.has(encounter_id):
		_pending[encounter_id] = {}
	if not _pending[encounter_id].has(ability_id):
		_pending[encounter_id][ability_id] = {}

	var by_enemy: Dictionary = _pending[encounter_id][ability_id]
	if ctx.has("enemy_index"):
		var ei: int = int(ctx["enemy_index"])
		by_enemy[ei] = int(by_enemy.get(ei, 0)) + 1
	elif ctx.has("enemy_indices"):
		var arr: Array = ctx["enemy_indices"]
		for v in arr:
			var ei2: int = int(v)
			by_enemy[ei2] = int(by_enemy.get(ei2, 0)) + 1
	else:
		# Non-targeted skills (e.g., buffs/heals) receive no XP by default.
		# Policy option: credit them by multiplying by the encounter's total char XP.
		pass

## Victory-time commit (apply to RUN, returns applied rows).
## victory_ctx: { "player_level":int, "allies_count":int, "enemies":Array[{monster_level:int, role:int}] }
static func commit_encounter(encounter_id: int, victory_ctx: Dictionary = {}, slot: int = DEFAULT_SLOT) -> Array:
	var rows_out: Array = []
	if not _pending.has(encounter_id):
		return rows_out

	var enemies: Array = victory_ctx.get("enemies", [])
	var P: int = int(victory_ctx.get("player_level", 1))
	var ability_hits_by_enemy: Dictionary = _pending[encounter_id]

	# Compute totals using per-enemy rounded values
	var per_ability_xp: Dictionary = XpTuning.skill_xp_for_victory_v2(P, enemies, ability_hits_by_enemy)

	# Apply to RUN
	for aid in per_ability_xp.keys():
		var add_i: int = int(per_ability_xp[aid])
		if add_i <= 0:
			continue
		var after: Dictionary = SaveManager.apply_skill_xp_to_run(String(aid), add_i, slot)
		rows_out.append({ "id": String(aid), "xp": add_i, "new_level": int(after.get("level", 1)) })

	# Clear pending
	_pending.erase(encounter_id)
	return rows_out

static func discard_encounter(encounter_id: int, _slot: int = DEFAULT_SLOT) -> void:
	if _pending.has(encounter_id):
		_pending.erase(encounter_id)

# -------------------------
# NEW: compute rows for RewardService.grant(), do not apply to RUN
# (Used by BattleLoader fallback so modal can show Skill XP via receipt.)
# -------------------------
static func compute_rows_and_clear(encounter_id: int, victory_ctx: Dictionary = {}) -> Array[Dictionary]:
	var rows_out: Array[Dictionary] = []
	if encounter_id <= 0 or not _pending.has(encounter_id):
		return rows_out

	var enemies: Array = victory_ctx.get("enemies", [])
	var P: int = int(victory_ctx.get("player_level", 1))
	var ability_hits_by_enemy: Dictionary = _pending[encounter_id]

	var per_ability_xp: Dictionary = XpTuning.skill_xp_for_victory_v2(P, enemies, ability_hits_by_enemy)
	for aid in per_ability_xp.keys():
		var amt: int = int(per_ability_xp[aid])
		if amt > 0:
			rows_out.append({ "id": String(aid), "xp": amt })

	# Important: clear here so Orchestrator-commit (if it ran) and our fallback never double-apply
	_pending.erase(encounter_id)
	return rows_out
