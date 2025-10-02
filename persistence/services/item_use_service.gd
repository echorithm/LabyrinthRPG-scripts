extends RefCounted
class_name ItemUseService

const _S := preload("res://persistence/util/save_utils.gd")
const DEFAULT_SLOT: int = 1

## Public entry: use an item by run inventory index.
## Returns:
##  { consumed: bool, message: String, hp?: int, mp?: int,
##    skill?: String, cap_band?: int, unlocked?: bool }
static func use_at_index(run_index: int, slot: int = DEFAULT_SLOT) -> Dictionary:
	var rs: Dictionary = SaveManager.load_run(slot)
	var inv_any: Variant = _S.dget(rs, "inventory", [])
	var inv: Array = (inv_any as Array) if inv_any is Array else []

	# Validate selection
	if run_index < 0 or run_index >= inv.size():
		return { "consumed": false, "message": "Invalid inventory selection." }

	var row_any: Variant = inv[run_index]
	if typeof(row_any) != TYPE_DICTIONARY:
		return { "consumed": false, "message": "Selected entry is not an item." }
	var item: Dictionary = row_any as Dictionary

	# Identify item basics
	var id: String = String(_S.dget(item, "id", ""))
	var dmax: int = int(_S.dget(item, "durability_max", 0))
	var qty: int = int(_S.dget(item, "count", 1))
	var rarity_s: String = String(_S.dget(item, "rarity", ""))
	var opts: Dictionary = _S.to_dict(_S.dget(item, "opts", {}))

	# Only stackables (dmax == 0) are "usable" here.
	if dmax > 0:
		return { "consumed": false, "message": "This item must be equipped." }

	# Dispatch by id prefix
	if id.begins_with("potion_"):
		var rc := _use_potion(id, rs)
		if bool(rc.get("consumed", false)):
			_consume_stack(inv, run_index)
			rs["inventory"] = inv
			rs["updated_at"] = _S.now_ts()
			SaveManager.save_run(rs, slot)
		return rc

	if id.begins_with("book_"):
		# Target skill & rarity mapping
		var target_skill: String = String(_S.dget(opts, "target_skill", _S.dget(item, "target_skill", "")))
		var r_code: String = _rar_code_from_name(rarity_s)
		var rc_b := _use_book(target_skill, r_code, rs)
		if bool(rc_b.get("consumed", false)):
			_consume_stack(inv, run_index)
			rs["inventory"] = inv
			rs["updated_at"] = _S.now_ts()
			SaveManager.save_run(rs, slot)
		return rc_b

	# Unknown consumable type
	return { "consumed": false, "message": "This item cannot be used." }

# -----------------------
# Potions
# -----------------------
static func _use_potion(id: String, rs: Dictionary) -> Dictionary:
	# Defaults: 30% restore for small potions; extend as needed
	var hp_max: int = int(_S.dget(rs, "hp_max", 0))
	var mp_max: int = int(_S.dget(rs, "mp_max", 0))
	var hp: int = int(_S.dget(rs, "hp", 0))
	var mp: int = int(_S.dget(rs, "mp", 0))

	match id:
		"potion_health":
			if hp >= hp_max:
				return { "consumed": false, "message": "HP is already full." }
			var add_hp: int = int(round(hp_max * 0.30))
			var new_hp: int = clampi(hp + add_hp, 0, hp_max)
			rs["hp"] = new_hp
			return { "consumed": true, "message": "You feel restored.", "hp": new_hp }
		"potion_mana":
			if mp >= mp_max:
				return { "consumed": false, "message": "MP is already full." }
			var add_mp: int = int(round(mp_max * 0.30))
			var new_mp: int = clampi(mp + add_mp, 0, mp_max)
			rs["mp"] = new_mp
			return { "consumed": true, "message": "Arcane energies surge.", "mp": new_mp }
		_:
			# Generic fallback: do nothing
			return { "consumed": false, "message": "Nothing happens." }

# -----------------------
# Books (skills & caps)
# -----------------------
# Rules:
#  C: unlock only (non-consume if already unlocked)
#  U/R/E/L: set cap to 20/30/40/50 (consume only if it improves)
#  M: cap_band += 10 (always consume; repeatable)
static func _use_book(target_skill: String, rarity_code: String, rs: Dictionary) -> Dictionary:
	if target_skill.is_empty():
		return { "consumed": false, "message": "This tome has no known discipline." }

	var tracks_any: Variant = _S.dget(rs, "skill_tracks", {})
	var tracks: Dictionary = (tracks_any as Dictionary) if tracks_any is Dictionary else {}

	# Ensure the skill row exists (copy default if needed)
	var row: Dictionary = _S.to_dict(_S.dget(tracks, target_skill, {}))
	if row.is_empty():
		# default skill row
		row = {
			"level": 1,
			"xp_current": 0,
			"xp_needed": 90,
			"cap_band": 10,
			"unlocked": false,
			"last_milestone_applied": 0
		}

	var unlocked: bool = bool(_S.dget(row, "unlocked", false))
	var cap_band: int = int(_S.dget(row, "cap_band", 10))

	match rarity_code:
		"C":
			if unlocked:
				return { "consumed": false, "message": "Already know this skill.", "skill": target_skill, "unlocked": true, "cap_band": cap_band }
			row["unlocked"] = true
			tracks[target_skill] = row
			rs["skill_tracks"] = tracks
			return { "consumed": true, "message": "You learn a new skill!", "skill": target_skill, "unlocked": true, "cap_band": cap_band }

		"U", "R", "E", "L":
			var target_cap: int = 10
			match rarity_code:
				"U": target_cap = 20
				"R": target_cap = 30
				"E": target_cap = 40
				"L": target_cap = 50
			if cap_band >= target_cap:
				return { "consumed": false, "message": "Your understanding is already this advanced.", "skill": target_skill, "cap_band": cap_band }
			row["cap_band"] = target_cap
			# Auto-unlock if still locked
			if not unlocked:
				row["unlocked"] = true
				unlocked = true
			tracks[target_skill] = row
			rs["skill_tracks"] = tracks
			return { "consumed": true, "message": "Your mastery expands.", "skill": target_skill, "unlocked": unlocked, "cap_band": target_cap }

		"M":
			var new_cap: int = cap_band + 10
			row["cap_band"] = new_cap
			# Auto-unlock if still locked
			if not unlocked:
				row["unlocked"] = true
				unlocked = true
			tracks[target_skill] = row
			rs["skill_tracks"] = tracks
			return { "consumed": true, "message": "A mythic insight deepens your mastery!", "skill": target_skill, "unlocked": unlocked, "cap_band": new_cap }

		_:
			return { "consumed": false, "message": "This script is too obscure to decipher." }

# -----------------------
# Utils
# -----------------------
static func _rar_code_from_name(rarity_name: String) -> String:
	# Accept full names or single-letter codes. Defaults to "U" for stackables in your data.
	var r := rarity_name.strip_edges()
	if r.is_empty(): return "U"
	var first := r.substr(0, 1).to_upper()
	match first:
		"C","U","R","E","L","A","M":
			return first
		# Map full names to codes
		_:
			var s := r.to_lower()
			if s == "common": return "C"
			if s == "uncommon": return "U"
			if s == "rare": return "R"
			if s == "epic": return "E"
			if s == "legendary": return "L"
			if s == "ancient": return "A"
			if s == "mythic": return "M"
	return "U"

static func _consume_stack(inv: Array, index: int) -> void:
	if index < 0 or index >= inv.size(): return
	var row_any: Variant = inv[index]
	if not (row_any is Dictionary): return
	var row: Dictionary = row_any as Dictionary
	var qty: int = int(_S.dget(row, "count", 1))
	qty = max(1, qty)
	if qty > 1:
		row["count"] = qty - 1
		inv[index] = row
	else:
		inv.remove_at(index)
