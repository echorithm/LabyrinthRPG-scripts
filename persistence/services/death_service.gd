extends RefCounted
class_name DeathService
## Orchestrates "on death" flow:
## - Applies meta penalties
## - Determines respawn floor (anchor)
## - Adjusts RUN (depth, hp/mp, optionally clear gold/items/seed)
## - Clears unbanked skill XP deltas (death wipes XP)
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
	# 1) Apply META penalties (character + skills lose progress toward next level)
	_Prog.apply_death_penalties(slot)

	# 2) Pick respawn anchor (nearest <= current)
	var respawn_floor: int = _ASeg.nearest_anchor_at_or_below(current_floor, slot)
	if respawn_floor < 1:
		respawn_floor = 1

	# 3) Adjust RUN snapshot
	var rs: Dictionary = SaveManager.load_run(slot)

	# Reset HP/MP to max on respawn
	var hp_max: int = int(_S.dget(rs, "hp_max", 30))
	var mp_max: int = int(_S.dget(rs, "mp_max", 10))
	rs["hp"] = hp_max
	rs["mp"] = mp_max

	# Travel back to respawn floor
	rs["depth"] = max(1, respawn_floor)
	rs["furthest_depth_reached"] = max(int(_S.dget(rs, "furthest_depth_reached", 1)), rs["depth"])

	# Clearables
	if CLEAR_RUN_GOLD:
		rs["gold"] = 0
	if CLEAR_RUN_ITEMS:
		# RUN inventory is stored under "inventory" (not "items")
		rs["inventory"] = []

	# Death wipes any UNBANKED XP:
	# - Clear RUN deltas so nothing gets banked later by mistake
	if rs.has("skill_xp_delta"):
		rs["skill_xp_delta"] = {}
	# Clear any legacy/session fields if present
	if rs.has("action_xp_delta"):
		rs["action_xp_delta"] = {}

	# Reset seed if requested; SaveManager.save_run() will auto-assign a new seed if 0
	if RESET_RUN_SEED:
		rs["run_seed"] = 0

	# Persist RUN changes
	SaveManager.save_run(rs, slot)

	# Keep META current floor in sync for menus/UI
	SaveManager.set_current_floor(respawn_floor, slot)
	SaveManager.set_run_floor(respawn_floor, slot)

	# 4) Optional: clear per-action progression for a fresh segment start
	if RESET_ACTION_SKILLS:
		_CProg.reset_for_new_run(slot)

	# 5) (Optional) debug: presence of save files
	SaveManager.debug_print_presence(slot)

	# 6) Summary for UI
	return {
		"respawn_floor": respawn_floor,
		"hp": hp_max,
		"mp": mp_max,
		"cleared": {
			"gold": CLEAR_RUN_GOLD,
			"run_items": CLEAR_RUN_ITEMS,
			"run_seed": RESET_RUN_SEED,
			"action_skills": RESET_ACTION_SKILLS,
			"skill_xp_delta": true  # always cleared on death
		}
	}
