extends RefCounted
class_name CombatProgressionService
## Per-action progression stored in RUN save.
## RUN block key: "action_skills" -> { action_id: { id, level, xp, cap, uses, last_used_at } }
## - Leveling is XP-based with a simple ramp (see xp_needed_for_action_level()).
## - When `record_action_use(..., forward_to_meta=true)`, we immediately apply the same XP
##   into RUN.skill_tracks via SaveManager.apply_skill_xp_to_run (no staging/deltas).

const _S := preload("res://persistence/util/save_utils.gd")

const DEFAULT_SLOT: int = 1

# Tunables
static var DEFAULT_CAP: int = 10
static var DEFAULT_XP_PER_USE: int = 5

# Optional mapping: action_id -> ability_id (skill_id for RUN track)
static var ACTION_TO_SKILL: Dictionary = {
	"basic_attack": "arc_slash",
	"heavy_attack": "crush",
	"fireball": "firebolt",
	"ice_bolt": "water_jet",
}

# -------------------------------------------------
# Public API: queries
# -------------------------------------------------

static func list_action_skills(slot: int = DEFAULT_SLOT) -> Dictionary:
	var rs: Dictionary = SaveManager.load_run(slot)
	var table_any: Variant = _S.dget(rs, "action_skills", {})
	var table: Dictionary = (table_any as Dictionary) if table_any is Dictionary else {}
	return table.duplicate(true)

static func get_action_entry(action_id: String, slot: int = DEFAULT_SLOT) -> Dictionary:
	var rs: Dictionary = SaveManager.load_run(slot)
	var table: Dictionary = _ensure_table(rs)
	if table.has(action_id):
		return (table[action_id] as Dictionary).duplicate(true)
	return {}

# -------------------------------------------------
# Public API: mutation
# -------------------------------------------------

static func record_action_use(
	action_id: String,
	uses: int = 1,
	xp_per_use: int = DEFAULT_XP_PER_USE,
	forward_to_meta: bool = true,  # kept for API compatibility; applies immediately to RUN.skill_tracks
	slot: int = DEFAULT_SLOT
) -> Dictionary:
	## Adds uses and XP to an action; handles level-ups within cap.
	## Also mirrors XP into RUN.skill_tracks immediately (if forward_to_meta).
	if action_id.is_empty():
		return {}

	var rs: Dictionary = SaveManager.load_run(slot)
	var table: Dictionary = _ensure_table(rs)

	var entry: Dictionary
	if table.has(action_id) and table[action_id] is Dictionary:
		entry = (table[action_id] as Dictionary).duplicate(true)
	else:
		entry = {
			"id": action_id,
			"level": 1,
			"xp": 0,
			"cap": DEFAULT_CAP,
			"uses": 0,
			"last_used_at": 0,
		}

	# Clamp inputs
	var u: int = max(0, uses)
	var per: int = max(0, xp_per_use)
	var gained_xp: int = u * per

	# Apply XP and level-ups (RUN-local for the action skill)
	var lvl: int = max(1, int(_S.dget(entry, "level", 1)))
	var xp: int  = max(0, int(_S.dget(entry, "xp", 0)))
	var cap: int = max(1, int(_S.dget(entry, "cap", DEFAULT_CAP)))

	xp += gained_xp
	while lvl < cap:
		var need: int = xp_needed_for_action_level(lvl)
		if xp < need:
			break
		xp -= need
		lvl += 1

	entry["level"] = lvl
	entry["xp"] = xp
	entry["uses"] = int(_S.dget(entry, "uses", 0)) + u
	entry["last_used_at"] = _S.now_ts()

	table[action_id] = entry
	rs["action_skills"] = table
	SaveManager.save_run(rs, slot)

	# Mirror to a RUN skill track NOW (no deltas).
	if forward_to_meta and gained_xp > 0:
		var skill_id_any: Variant = _S.dget(ACTION_TO_SKILL, action_id, "")
		var skill_id: String = String(skill_id_any)
		if not skill_id.is_empty():
			SaveManager.apply_skill_xp_to_run(skill_id, gained_xp, slot)

	return entry.duplicate(true)

static func set_action_cap(action_id: String, cap: int, slot: int = DEFAULT_SLOT) -> void:
	var rs: Dictionary = SaveManager.load_run(slot)
	var table: Dictionary = _ensure_table(rs)
	var c: int = max(1, cap)
	var entry: Dictionary = _get_or_create(table, action_id)
	entry["cap"] = c
	table[action_id] = entry
	rs["action_skills"] = table
	SaveManager.save_run(rs, slot)

static func reset_for_new_run(slot: int = DEFAULT_SLOT) -> void:
	## Clears action_skills table (call when starting a brand-new run).
	var rs: Dictionary = SaveManager.load_run(slot)
	rs["action_skills"] = {}
	SaveManager.save_run(rs, slot)

# -------------------------------------------------
# Wiring helpers
# -------------------------------------------------

static func map_action_to_skill(action_id: String, skill_id: String) -> void:
	if action_id.is_empty():
		return
	if skill_id.is_empty():
		ACTION_TO_SKILL.erase(action_id)
	else:
		ACTION_TO_SKILL[action_id] = skill_id

static func set_default_xp_per_use(xp_value: int) -> void:
	DEFAULT_XP_PER_USE = max(0, xp_value)

static func set_default_cap(cap_value: int) -> void:
	DEFAULT_CAP = max(1, cap_value)

# -------------------------------------------------
# XP curve for actions (replace/tune as desired)
# -------------------------------------------------

static func xp_needed_for_action_level(level: int) -> int:
	## Simple linear ramp: L1->L2 = 20, L2->L3 = 40, ...
	var l: int = max(1, level)
	return 20 + 20 * (l - 1)

# -------------------------------------------------
# Internal
# -------------------------------------------------

static func _ensure_table(rs: Dictionary) -> Dictionary:
	var any_t: Variant = _S.dget(rs, "action_skills", {})
	var t: Dictionary = (any_t as Dictionary) if any_t is Dictionary else {}
	# Normalize entries (lightweight guard)
	for k in t.keys():
		var v_any: Variant = t[k]
		if not (v_any is Dictionary):
			t[k] = {
				"id": String(k), "level": 1, "xp": 0, "cap": DEFAULT_CAP, "uses": 0, "last_used_at": 0
			}
	return t

static func _get_or_create(table: Dictionary, action_id: String) -> Dictionary:
	if table.has(action_id) and table[action_id] is Dictionary:
		return (table[action_id] as Dictionary).duplicate(true)
	return {
		"id": action_id,
		"level": 1,
		"xp": 0,
		"cap": DEFAULT_CAP,
		"uses": 0,
		"last_used_at": 0,
	}

# Legacy compatibility: if anything still calls this, just apply to RUN immediately.
static func _stage_meta_skill_xp_delta(skill_id: String, amount: int, slot: int) -> void:
	var add_i: int = max(0, amount)
	if skill_id.is_empty() or add_i <= 0:
		return
	SaveManager.apply_skill_xp_to_run(skill_id, add_i, slot)
