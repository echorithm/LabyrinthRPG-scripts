extends RefCounted
class_name CombatProgressionService
## Per-action progression stored in RUN save.
## RUN block key: "action_skills" -> { action_id: { id, level, xp, cap, uses, last_used_at } }
## - Leveling is XP-based with a simple ramp (see xp_needed_for_action_level()).
## - You can opt-in to forward some/all gained XP to META skills (anti double-dip still handled by ProgressionService).

const _S      := preload("res://persistence/util/save_utils.gd")
const _Run    := preload("res://persistence/schemas/run_schema.gd")
const _Meta   := preload("res://persistence/schemas/meta_schema.gd")
const _Prog   := preload("res://persistence/services/progression_service.gd")

const DEFAULT_SLOT: int = 1

# Tunables (you can tweak at runtime if needed)
static var DEFAULT_CAP: int = 10
static var DEFAULT_XP_PER_USE: int = 5
static var FORWARD_XP_RATIO_TO_META: float = 0.5  # 50% of action XP goes to linked META skill (rounded down)

# Optional mapping: action_id -> skill_id (for forwarding XP into META skills)
static var ACTION_TO_SKILL: Dictionary = {
	# Example defaults; adjust to your ability ids
	"basic_attack": "swordsmanship",
	"heavy_attack": "swordsmanship",
	"fireball": "pyromancy",
	"ice_bolt": "cryomancy",
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
static func record_action_use(action_id: String, uses: int = 1, xp_per_use: int = DEFAULT_XP_PER_USE, forward_to_meta: bool = true, slot: int = DEFAULT_SLOT) -> Dictionary:
	## Adds uses and XP to an action; handles level-ups within cap.
	## Returns a COPY of the updated entry.
	if action_id.is_empty():
		return {}

	var rs: Dictionary = SaveManager.load_run(slot)
	var table: Dictionary = _ensure_table(rs)

	var entry: Dictionary = {}
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

	# Apply XP and level-ups
	var lvl: int = max(1, int(_S.dget(entry, "level", 1)))
	var xp: int = max(0, int(_S.dget(entry, "xp", 0)))
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

	# Optional: forward some XP into META skill progression
	if forward_to_meta and gained_xp > 0:
		var skill_id: String = String(_S.dget(ACTION_TO_SKILL, action_id, ""))
		if not skill_id.is_empty():
			var meta_xp: int = int(floor(float(gained_xp) * max(0.0, FORWARD_XP_RATIO_TO_META)))
			if meta_xp > 0:
				_Prog.award_skill_xp(skill_id, meta_xp, slot)

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

static func set_forward_ratio_to_meta(ratio_0_to_1: float) -> void:
	FORWARD_XP_RATIO_TO_META = clampf(ratio_0_to_1, 0.0, 1.0)

static func set_default_xp_per_use(xp_value: int) -> void:
	DEFAULT_XP_PER_USE = max(0, xp_value)

static func set_default_cap(cap_value: int) -> void:
	DEFAULT_CAP = max(1, cap_value)

# -------------------------------------------------
# XP curve for actions (replace/tune as desired)
# -------------------------------------------------
static func xp_needed_for_action_level(level: int) -> int:
	## Simple linear ramp (same family as skills, can diverge):
	## L1->L2 = 20, L2->L3 = 40, ...
	var l: int = max(1, level)
	return 20 + 20 * (l - 1)

# -------------------------------------------------
# Internal
# -------------------------------------------------
static func _ensure_table(rs: Dictionary) -> Dictionary:
	var any_t: Variant = _S.dget(rs, "action_skills", {})
	var t: Dictionary = (any_t as Dictionary) if any_t is Dictionary else {}
	# Normalize entries (optional lightweight guard)
	for k in t.keys():
		var v_any: Variant = t[k]
		if not (v_any is Dictionary):
			t[k] = {
				"id": String(k), "level": 1, "xp": 0, "cap": DEFAULT_CAP, "uses": 0, "last_used_at": 0
			}
	# Ensure attached to rs (caller will save)
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
