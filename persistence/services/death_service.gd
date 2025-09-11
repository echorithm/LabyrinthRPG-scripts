extends RefCounted
class_name DeathService
## Orchestrates "on death" flow:
## - Applies meta penalties
## - Determines respawn floor (anchor)
## - Adjusts RUN (depth, hp/mp, optionally clear gold/items/seed)
## - Returns a summary for UI

const _S     := preload("res://persistence/util/save_utils.gd")
const _ASeg  := preload("res://persistence/services/anchor_segment_service.gd")
const _Prog  := preload("res://persistence/services/progression_service.gd")
const _Inv   := preload("res://persistence/services/inventory_service.gd")
const _CProg := preload("res://persistence/services/combat_progression_service.gd")

const DEFAULT_SLOT: int = 1

# Policy toggles (reasonable defaults)
static var CLEAR_RUN_GOLD: bool = true
static var CLEAR_RUN_ITEMS: bool = false
static var RESET_RUN_SEED: bool = false
static var RESET_ACTION_SKILLS: bool = false

static func on_player_death(current_floor: int, slot: int = DEFAULT_SLOT) -> Dictionary:
	# 1) Apply meta penalties
	_Prog.apply_death_penalties(slot)

	# 2) Pick respawn anchor (nearest <= current)
	var respawn_floor: int = _ASeg.nearest_anchor_at_or_below(current_floor, slot)
	if respawn_floor < 1:
		respawn_floor = 1

	# 3) Optionally mark current segment as drained (design choice; enable later if needed)
	# _ASeg.mark_segment_drained_by_floor(current_floor, slot)

	# 4) Adjust RUN
	var rs: Dictionary = SaveManager.load_run(slot)

	# Reset HP/MP to max on respawn
	var hp_max: int = int(_S.dget(rs, "hp_max", 30))
	var mp_max: int = int(_S.dget(rs, "mp_max", 10))
	rs["hp"] = hp_max
	rs["mp"] = mp_max

	# Travel back to respawn floor
	rs["depth"] = max(1, respawn_floor)

	# Clearables
	if CLEAR_RUN_GOLD:
		rs["gold"] = 0
	if CLEAR_RUN_ITEMS:
		rs["items"] = []  # your RUN items (not META inventory)
	if RESET_RUN_SEED:
		rs["run_seed"] = 0  # will be re-randomized by your run init if seed==0

	SaveManager.save_run(rs, slot)
	SaveManager.set_current_floor(respawn_floor, slot)
	SaveManager.set_run_floor(respawn_floor, slot)

	# 5) Optional: clear per-action progression for a fresh segment start
	if RESET_ACTION_SKILLS:
		_CProg.reset_for_new_run(slot)

	# 6) Summary for UI
	return {
		"respawn_floor": respawn_floor,
		"hp": hp_max, "mp": mp_max,
		"cleared": {
			"gold": CLEAR_RUN_GOLD,
			"run_items": CLEAR_RUN_ITEMS,
			"run_seed": RESET_RUN_SEED,
			"action_skills": RESET_ACTION_SKILLS,
		}
	}
