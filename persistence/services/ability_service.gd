extends RefCounted
class_name AbilityService

const _S    := preload("res://persistence/util/save_utils.gd")
const _Meta := preload("res://persistence/schemas/meta_schema.gd")

const DEFAULT_SLOT: int = 1

static func list_unlocked(slot: int = DEFAULT_SLOT) -> Dictionary:
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _pl(gs)
	return (_S.to_dict(_S.dget(pl, "abilities_unlocked", {}))).duplicate(true)

static func is_unlocked(ability_id: String, slot: int = DEFAULT_SLOT) -> bool:
	var au: Dictionary = list_unlocked(slot)
	return au.has(ability_id)

static func unlock(ability_id: String, start_level: int = 1, xp_needed: int = 25, slot: int = DEFAULT_SLOT) -> void:
	if ability_id.is_empty():
		return
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _pl(gs)
	var au: Dictionary = _S.to_dict(_S.dget(pl, "abilities_unlocked", {}))
	if not au.has(ability_id):
		au[ability_id] = {"level": max(1, start_level), "xp_current": 0, "xp_needed": max(1, xp_needed)}
		pl["abilities_unlocked"] = au
		gs["player"] = pl
		SaveManager.save_game(gs, slot)

static func award_xp(ability_id: String, xp_add: int, slot: int = DEFAULT_SLOT) -> Dictionary:
	var add: int = max(0, xp_add)
	if add == 0:
		return get_info(ability_id, slot)

	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _pl(gs)
	var au: Dictionary = _S.to_dict(_S.dget(pl, "abilities_unlocked", {}))
	if not au.has(ability_id):
		return {}

	var row: Dictionary = _S.to_dict(au[ability_id])
	var lvl: int = max(1, int(_S.dget(row, "level", 1)))
	var xc: int = max(0, int(_S.dget(row, "xp_current", 0)))
	var xn: int = max(1, int(_S.dget(row, "xp_needed", 25)))

	xc += add
	while xc >= xn:
		xc -= xn
		lvl += 1
		xn = _xp_needed_for_level(lvl)

	row["level"] = lvl
	row["xp_current"] = xc
	row["xp_needed"] = xn

	au[ability_id] = row
	pl["abilities_unlocked"] = au
	gs["player"] = pl
	SaveManager.save_game(gs, slot)
	return row.duplicate(true)

static func get_info(ability_id: String, slot: int = DEFAULT_SLOT) -> Dictionary:
	var au: Dictionary = list_unlocked(slot)
	if not au.has(ability_id):
		return {}
	return (_S.to_dict(au[ability_id])).duplicate(true)

# ------------ Runtime helpers ------------

static func set_runtime_state(ability_id: String, row: Dictionary, slot: int = DEFAULT_SLOT) -> void:
	var rs: Dictionary = SaveManager.load_run(slot)
	var map: Dictionary = _S.to_dict(_S.dget(rs, "abilities_runtime", {}))
	map[ability_id] = {
		"cd_remaining": max(0, int(_S.dget(row, "cd_remaining", 0))),
		"charges": max(0, int(_S.dget(row, "charges", 0))),
		"tags": _S.to_string_array(_S.dget(row, "tags", [])),
		"mag": float(_S.dget(row, "mag", 0.0))
	}
	rs["abilities_runtime"] = map
	SaveManager.save_run(rs, slot)

static func get_runtime_state(ability_id: String, slot: int = DEFAULT_SLOT) -> Dictionary:
	var rs: Dictionary = SaveManager.load_run(slot)
	var map: Dictionary = _S.to_dict(_S.dget(rs, "abilities_runtime", {}))
	if not map.has(ability_id):
		return {}
	return (_S.to_dict(map[ability_id])).duplicate(true)

# ------------ internal ------------

static func _pl(gs: Dictionary) -> Dictionary:
	var norm: Dictionary = _Meta.normalize(gs)
	return _S.to_dict(_S.dget(norm, "player", {}))

static func _xp_needed_for_level(level: int) -> int:
	var l: int = max(1, level)
	return 25 + 15 * (l - 1)
