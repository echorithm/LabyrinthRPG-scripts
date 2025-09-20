extends RefCounted
class_name ProgressionService
## Progression helpers backed by SaveManager (META JSON).
## - Character: { level, highest_claimed_level }
## - Skills: [{ id, level, xp, cap, highest_claimed_level, milestones_claimed[] }]
## - Uses SaveManager.apply_death_penalties() for death handling.
## - XP curve is simple & replaceable (see xp_needed_for_skill_level()).

const _S    := preload("res://persistence/util/save_utils.gd")
const _Meta := preload("res://persistence/schemas/meta_schema.gd")

const DEFAULT_SLOT: int = 1

# -------------------------------------------------
# Public: Character helpers
# -------------------------------------------------
static func get_character_level(slot: int = DEFAULT_SLOT) -> int:
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _pl(gs)
	return int(_S.dget(pl, "level", 1))

static func set_character_level(level: int, slot: int = DEFAULT_SLOT) -> void:
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _pl(gs)
	pl["level"] = max(1, level)
	_save_pl(gs, pl, slot)

static func get_highest_claimed_character_level(slot: int = DEFAULT_SLOT) -> int:
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _pl(gs)
	return int(_S.dget(pl, "highest_claimed_level", int(_S.dget(pl, "level", 1))))

static func claim_character_level(slot: int = DEFAULT_SLOT) -> void:
	## Marks the current character level as "highest_claimed_level" (anti double-dip).
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _pl(gs)
	var lvl: int = int(_S.dget(pl, "level", 1))
	SaveManager.claim_character_level(lvl, slot)

# -------------------------------------------------
# Public: Skill queries and mutation
# -------------------------------------------------
static func list_skills(slot: int = DEFAULT_SLOT) -> Array:
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _pl(gs)
	var arr_any: Variant = _S.dget(pl, "skills", [])
	var arr: Array = (arr_any as Array) if arr_any is Array else []
	return arr.duplicate(true)

static func get_skill(skill_id: String, slot: int = DEFAULT_SLOT) -> Dictionary:
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _pl(gs)
	var skills: Array = _skills(pl)
	for s_any in skills:
		if s_any is Dictionary:
			var s: Dictionary = s_any
			if String(_S.dget(s, "id", "")) == skill_id:
				return s.duplicate(true)
	return {} # not found

static func ensure_skill(skill_id: String, slot: int = DEFAULT_SLOT) -> Dictionary:
	## Ensures the skill entry exists; returns the (current) entry.
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _pl(gs)
	var skills: Array = _skills(pl)

	var idx: int = _find_skill_index(skills, skill_id)
	if idx < 0:
		var s: Dictionary = {
			"id": skill_id,
			"level": 1,
			"xp": 0,
			"cap": 10,
			"highest_claimed_level": 1,
			"milestones_claimed": [0],
		}
		skills.append(s)
		pl["skills"] = skills
		_save_pl(gs, pl, slot)
		return s
	return (skills[idx] as Dictionary).duplicate(true)

static func award_skill_xp(skill_id: String, amount: int, slot: int = DEFAULT_SLOT) -> Dictionary:
	## Add XP to a skill, auto-leveling while under cap. Does NOT modify 'highest_claimed_level'.
	## Returns a COPY of the updated skill dict.
	var add: int = max(0, amount)
	if add == 0:
		return get_skill(skill_id, slot)

	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _pl(gs)
	var skills: Array = _skills(pl)

	var idx: int = _find_skill_index(skills, skill_id)
	if idx < 0:
		# create a new record then proceed
		var init: Dictionary = {
			"id": skill_id, "level": 1, "xp": 0, "cap": 10,
			"highest_claimed_level": 1, "milestones_claimed": [0]
		}
		skills.append(init)
		idx = skills.size() - 1

	var sd: Dictionary = skills[idx]
	var lvl: int = max(1, int(_S.dget(sd, "level", 1)))
	var xp: int = max(0, int(_S.dget(sd, "xp", 0)))
	var cap: int = max(1, int(_S.dget(sd, "cap", 10)))

	xp += add
	while lvl < cap:
		var need: int = xp_needed_for_skill_level(lvl)
		if xp < need:
			break
		xp -= need
		lvl += 1

	sd["level"] = lvl
	sd["xp"] = xp
	skills[idx] = sd
	pl["skills"] = skills
	_save_pl(gs, pl, slot)
	return sd.duplicate(true)

static func level_up_skill(skill_id: String, levels: int = 1, slot: int = DEFAULT_SLOT) -> Dictionary:
	## Directly bumps level (still obeys cap). Does NOT modify 'highest_claimed_level'.
	var bump: int = max(0, levels)
	if bump == 0:
		return get_skill(skill_id, slot)

	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _pl(gs)
	var skills: Array = _skills(pl)

	var idx: int = _find_skill_index(skills, skill_id)
	if idx < 0:
		var init: Dictionary = {
			"id": skill_id, "level": 1, "xp": 0, "cap": 10,
			"highest_claimed_level": 1, "milestones_claimed": [0]
		}
		skills.append(init)
		idx = skills.size() - 1

	var sd: Dictionary = skills[idx]
	var lvl: int = max(1, int(_S.dget(sd, "level", 1)))
	var cap: int = max(1, int(_S.dget(sd, "cap", 10)))
	lvl = min(cap, lvl + bump)
	sd["level"] = lvl
	skills[idx] = sd
	pl["skills"] = skills
	_save_pl(gs, pl, slot)
	return sd.duplicate(true)

static func claim_skill_level(skill_id: String, slot: int = DEFAULT_SLOT) -> void:
	## Marks the skill's current level as 'highest_claimed_level' and persists.
	SaveManager.claim_skill_level(skill_id, int(_S.dget(get_skill(skill_id, slot), "level", 1)), slot)

static func mark_milestone_claimed(skill_id: String, milestone_level: int, slot: int = DEFAULT_SLOT) -> bool:
	## Adds 'milestone_level' to milestones_claimed[] if not already present.
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _pl(gs)
	var skills: Array = _skills(pl)

	var idx: int = _find_skill_index(skills, skill_id)
	if idx < 0:
		return false

	var sd: Dictionary = skills[idx]
	var m_any: Variant = _S.dget(sd, "milestones_claimed", [0])
	var m_arr: Array = []
	if m_any is PackedInt32Array:
		for v in (m_any as PackedInt32Array):
			m_arr.append(int(v))
	elif m_any is Array:
		for v in (m_any as Array):
			m_arr.append(int(v))
	else:
		m_arr = [0]

	var ml: int = max(0, milestone_level)
	for v in m_arr:
		if int(v) == ml:
			return false
	m_arr.append(ml)
	m_arr.sort()
	sd["milestones_claimed"] = m_arr
	skills[idx] = sd
	pl["skills"] = skills
	_save_pl(gs, pl, slot)
	return true

# -------------------------------------------------
# Public: Penalties & death
# -------------------------------------------------
static func set_penalty_tunables(level_pct: float, skill_xp_pct: float, floor_at_level: int, floor_at_skill_level: int, slot: int = DEFAULT_SLOT) -> void:
	var gs: Dictionary = SaveManager.load_game(slot)
	var p_any: Variant = _S.dget(gs, "penalties", {})
	var p: Dictionary = (p_any as Dictionary) if p_any is Dictionary else {}
	p["level_pct"] = max(0.0, level_pct)
	p["skill_xp_pct"] = max(0.0, skill_xp_pct)
	p["floor_at_level"] = max(1, floor_at_level)
	p["floor_at_skill_level"] = max(1, floor_at_skill_level)
	gs["penalties"] = p
	SaveManager.save_game(gs, slot)

static func apply_death_penalties(slot: int = DEFAULT_SLOT) -> void:
	## Delegates to SaveManager (keeps the single source of truth).
	SaveManager.apply_death_penalties(slot)

# -------------------------------------------------
# Public: Utility / inspection
# -------------------------------------------------
static func recompute_highest_claimed_sync(slot: int = DEFAULT_SLOT) -> void:
	## Syncs meta.highest_claimed_level with player.highest_claimed_level (safety).
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _pl(gs)
	var h_pl: int = int(_S.dget(pl, "highest_claimed_level", int(_S.dget(pl, "level", 1))))
	gs["highest_claimed_level"] = max(h_pl, int(_S.dget(gs, "highest_claimed_level", h_pl)))
	SaveManager.save_game(gs, slot)

# -------------------------------------------------
# XP curve (replace/tune freely)
# -------------------------------------------------
static func xp_needed_for_skill_level(level: int) -> int:
	## Simple linear-ish ramp: next = 25 + 25 * (level-1) => L1->L2 = 25, L2->L3 = 50, ...
	## Replace with whatever is in your design sheet later.
	var l: int = max(1, level)
	return 25 + 25 * (l - 1)

# -------------------------------------------------
# Internal helpers
# -------------------------------------------------
static func _pl(gs: Dictionary) -> Dictionary:
	# Normalize through MetaSchema to ensure the player block shape exists.
	var norm: Dictionary = _Meta.normalize(gs)
	return _S.to_dict(_S.dget(norm, "player", {}))

static func _skills(pl: Dictionary) -> Array:
	var arr_any: Variant = _S.dget(pl, "skills", [])
	return (arr_any as Array) if arr_any is Array else []

static func _save_pl(gs: Dictionary, pl: Dictionary, slot: int) -> void:
	gs["player"] = pl
	SaveManager.save_game(gs, slot)

static func _find_skill_index(skills: Array, skill_id: String) -> int:
	for i in range(skills.size()):
		var it_any: Variant = skills[i]
		if it_any is Dictionary:
			var it: Dictionary = it_any
			if String(_S.dget(it, "id", "")) == skill_id:
				return i
	return -1
