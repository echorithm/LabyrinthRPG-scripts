# res://persistence/services/progression_service.gd
extends RefCounted
class_name ProgressionService
## Character + Skill progression helpers (META).
## Adds: trainer/book-based cap recompute + group unlock helpers.

const _S    := preload("res://persistence/util/save_utils.gd")
const _Meta := preload("res://persistence/schemas/meta_schema.gd")
const VillageService := preload("res://persistence/services/village_service.gd")

const DEFAULT_SLOT: int = 1
const ABILITY_CATALOG_PATH: String = "res://data/combat/abilities/ability_catalog.json"

# ---------------- Character (unchanged) ----------------

static func xp_to_next(level: int) -> int:
	var l: int = max(1, level)
	return int(round(90.0 * pow(1.13, float(l - 1))))

static func award_character_xp(amount: int, slot: int = DEFAULT_SLOT) -> Dictionary:
	var add: int = max(0, amount)
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _S.to_dict(gs.get("player", {}))
	var sb: Dictionary = _S.to_dict(pl.get("stat_block", {}))

	var lvl: int = int(sb.get("level", 1))
	var cur: int = int(sb.get("xp_current", 0))
	var need: int = int(sb.get("xp_needed", xp_to_next(lvl)))

	var levels_gained := 0
	cur += add
	while cur >= need:
		cur -= need
		lvl += 1
		levels_gained += 1
		need = xp_to_next(lvl)

	sb["level"] = lvl
	sb["xp_current"] = cur
	sb["xp_needed"]  = need
	pl["stat_block"] = sb
	pl["points_unspent"] = int(pl.get("points_unspent", 0)) + (levels_gained * 2)

	gs["player"] = pl
	SaveManager.save_game(gs, slot)
	return { "level": lvl, "xp_current": cur, "xp_needed": need, "points_unspent": int(pl["points_unspent"]) }

static func get_character_snapshot(slot: int = DEFAULT_SLOT) -> Dictionary:
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _S.to_dict(gs.get("player", {}))
	var sb: Dictionary = _S.to_dict(pl.get("stat_block", {}))
	var lvl: int = int(sb.get("level",1))
	return {
		"level": lvl,
		"xp_current": int(sb.get("xp_current",0)),
		"xp_needed": int(sb.get("xp_needed", xp_to_next(lvl))),
		"points_unspent": int(pl.get("points_unspent", 0))
	}

# ---------------- Skill Tracks (existing surface) ----------------------

static func _normalize_track(row_in: Dictionary) -> Dictionary:
	var row := _S.to_dict(row_in)
	if row.has("banked_xp") and not row.has("xp_current"):
		row["xp_current"] = int(row.get("banked_xp", 0))
		row.erase("banked_xp")
	var lvl := int(row.get("level", 1))
	row["level"] = max(1, lvl)
	row["cap_band"] = int(row.get("cap_band", 10))
	row["unlocked"] = bool(row.get("unlocked", false))
	row["last_milestone_applied"] = int(row.get("last_milestone_applied", 0))
	row["xp_current"] = int(row.get("xp_current", 0))
	row["xp_needed"]  = int(row.get("xp_needed", xp_to_next(lvl)))
	return row

static func _get_tracks(pl: Dictionary) -> Dictionary:
	var st: Dictionary = _S.to_dict(pl.get("skill_tracks", {}))
	for k in st.keys():
		if st[k] is Dictionary:
			st[k] = _normalize_track(st[k])
	return st

static func list_skill_tracks(slot: int = DEFAULT_SLOT) -> Dictionary:
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _S.to_dict(gs.get("player", {}))
	return _get_tracks(pl).duplicate(true)

static func get_skill_track(id: String, slot: int = DEFAULT_SLOT) -> Dictionary:
	var all: Dictionary = list_skill_tracks(slot)
	if all.has(id) and all[id] is Dictionary:
		return (all[id] as Dictionary).duplicate(true)
	return {}

static func set_unlocked(id: String, unlocked: bool, slot: int = DEFAULT_SLOT) -> void:
	if id.is_empty(): return
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _S.to_dict(gs.get("player", {}))
	var st: Dictionary = _get_tracks(pl)
	var row: Dictionary = _S.to_dict(st.get(id, {}))
	if row.is_empty():
		row = _normalize_track({ "level": 1, "xp_current": 0, "xp_needed": xp_to_next(1), "cap_band": 10, "unlocked": unlocked, "last_milestone_applied": 0 })
	else:
		row["unlocked"] = unlocked
	st[id] = row
	pl["skill_tracks"] = st
	gs["player"] = pl
	SaveManager.save_game(gs, slot)

static func lift_cap(id: String, new_cap_band: int, slot: int = DEFAULT_SLOT) -> void:
	if id.is_empty(): return
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _S.to_dict(gs.get("player", {}))
	var st: Dictionary = _get_tracks(pl)
	if not st.has(id): return
	var row: Dictionary = _S.to_dict(st[id])
	row["cap_band"] = max(int(row.get("cap_band", 10)), new_cap_band)
	st[id] = row
	pl["skill_tracks"] = st
	gs["player"] = pl
	SaveManager.save_game(gs, slot)

# ---------------- New: trainer/book cap recompute ----------------------

# Resolve group for an ability (weapon_type > element > defense tag/ID)
static func _group_for_ability(row: Dictionary) -> String:
	var weapon: String = String(_S.dget(row, "weapon_type", ""))
	if weapon in ["spear","sword","mace","bow"]:
		return weapon
	var elem: String = String(_S.dget(row, "element", ""))
	if elem in ["fire","water","wind","earth","light","dark"]:
		return elem
	var aid: String = String(_S.dget(row, "ability_id", ""))
	if aid == "block":
		return "defense"
	var tags_any: Variant = row.get("tags")
	if tags_any is Array:
		for t_any in (tags_any as Array):
			if String(t_any) == "defense":
				return "defense"
	# default bucket (least likely)
	return "physical"

# Read optional per-ability book tier (you said you'll wire this elsewhere)
static func _book_tier_for(ability_id: String, pl: Dictionary) -> int:
	var books: Dictionary = _S.to_dict(pl.get("skill_book_tiers", {})) # optional
	return int(_S.dget(books, ability_id, 0))

# Tier → cap band: Common=0→10, Uncommon=1→20, ... Mythic=6→70, Mythic xN→(6+N)*10
static func _cap_for_tier(tier: int) -> int:
	var t: int = max(0, tier)
	return 10 * (1 + t)

# Public: recompute caps for all abilities based on trainers + books.
static func recompute_all_skill_caps(slot: int = DEFAULT_SLOT) -> void:
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _S.to_dict(gs.get("player", {}))
	var st: Dictionary = _get_tracks(pl)

	var catalog: Array = _read_ability_catalog()

	for any in catalog:
		if not (any is Dictionary):
			continue
		var row: Dictionary = any
		var aid: String = String(_S.dget(row, "ability_id", ""))
		if aid == "":
			continue

		var group: String = _group_for_ability(row)
		var trainer_tier: int = VillageService.trainer_tier_for_group(group, slot)
		var book_tier: int = _book_tier_for(aid, pl)
		var effective_tier: int = max(trainer_tier, book_tier)
		var new_cap: int = _cap_for_tier(effective_tier)

		# Create row if missing (do not unlock here unless someone asked; see unlock functions below)
		if not st.has(aid):
			st[aid] = _normalize_track({ "level": 1, "xp_current": 0, "xp_needed": xp_to_next(1), "cap_band": new_cap, "unlocked": false, "last_milestone_applied": 0 })
		else:
			var cur: Dictionary = _S.to_dict(st[aid])
			cur["cap_band"] = max(int(_S.dget(cur, "cap_band", 10)), new_cap)
			st[aid] = cur

	pl["skill_tracks"] = st
	gs["player"] = pl
	SaveManager.save_game(gs, slot)

# Public: unlock all abilities in a group (trainer L1 or a group-book).
static func unlock_all_in_group(group_id: String, slot: int = DEFAULT_SLOT) -> void:
	if group_id == "":
		return
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _S.to_dict(gs.get("player", {}))
	var st: Dictionary = _get_tracks(pl)

	var catalog: Array = _read_ability_catalog()
	for any in catalog:
		if not (any is Dictionary):
			continue
		var row: Dictionary = any
		var aid: String = String(_S.dget(row, "ability_id", ""))
		if aid == "":
			continue
		if _group_for_ability(row) != group_id:
			continue

		# Unlock and set at least Common cap (10), but cap may be higher via trainers/books.
		var trainer_tier: int = VillageService.trainer_tier_for_group(group_id, slot)
		var book_tier: int = _book_tier_for(aid, pl)
		var effective_tier: int = max(trainer_tier, book_tier)
		var cap_band: int = _cap_for_tier(effective_tier)

		var row_cur: Dictionary = _S.to_dict(st.get(aid, {}))
		if row_cur.is_empty():
			row_cur = _normalize_track({ "level": 1, "xp_current": 0, "xp_needed": xp_to_next(1), "cap_band": cap_band, "unlocked": true, "last_milestone_applied": 0 })
		else:
			row_cur["unlocked"] = true
			row_cur["cap_band"] = max(int(_S.dget(row_cur, "cap_band", 10)), cap_band)
		st[aid] = row_cur

	pl["skill_tracks"] = st
	gs["player"] = pl
	SaveManager.save_game(gs, slot)

# ---------------- Awarding skill XP (unchanged logic) -------------------

static func award_skill_xp(id: String, add_xp: int, slot: int = DEFAULT_SLOT) -> Dictionary:
	if id.is_empty() or add_xp <= 0:
		return get_skill_track(id, slot)

	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _S.to_dict(gs.get("player", {}))
	var st: Dictionary = _get_tracks(pl)

	if not st.has(id):
		st[id] = _normalize_track({ "level": 1, "xp_current": 0, "xp_needed": xp_to_next(1), "cap_band": 10, "unlocked": false, "last_milestone_applied": 0 })

	var row: Dictionary = _S.to_dict(st[id])
	var unlocked: bool = bool(row.get("unlocked", false))
	var lvl: int = int(row.get("level", 1))
	var cap: int = int(row.get("cap_band", 10))
	var xp: int = int(row.get("xp_current", 0))
	var need: int = int(row.get("xp_needed", xp_to_next(lvl)))
	var last_ms: int = int(row.get("last_milestone_applied", 0))

	if (not unlocked) or (lvl >= cap):
		st[id] = row
		pl["skill_tracks"] = st
		gs["player"] = pl
		SaveManager.save_game(gs, slot)
		return row.duplicate(true)

	xp += max(0, add_xp)
	while (lvl < cap) and (xp >= need):
		xp -= need
		lvl += 1
		need = xp_to_next(lvl)
		if (lvl % 5 == 0) and (lvl > last_ms):
			_apply_milestone_stat_grant(id, lvl, slot)
			last_ms = lvl

	row["level"] = lvl
	row["xp_current"] = xp
	row["xp_needed"]  = need
	row["last_milestone_applied"] = last_ms
	st[id] = row

	pl["skill_tracks"] = st
	gs["player"] = pl
	SaveManager.save_game(gs, slot)
	return row.duplicate(true)

# ---------------- Death penalties (unchanged) ---------------------------

static func apply_death_penalties(slot: int = DEFAULT_SLOT) -> void:
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _S.to_dict(gs.get("player", {}))
	var sb: Dictionary = _S.to_dict(pl.get("stat_block", {}))
	var clvl: int = int(sb.get("level", 1))
	sb["xp_current"] = 0
	sb["xp_needed"]  = xp_to_next(clvl)
	pl["stat_block"] = sb

	var st: Dictionary = _get_tracks(pl)
	for k in st.keys():
		if not (st[k] is Dictionary): continue
		var row: Dictionary = _S.to_dict(st[k])
		var lvl := int(row.get("level", 1))
		row["xp_current"] = 0
		row["xp_needed"]  = xp_to_next(lvl)
		st[k] = row

	pl["skill_tracks"] = st
	gs["player"] = pl
	SaveManager.save_game(gs, slot)

# ---------------- Milestones / stat bias (unchanged) --------------------

static func _apply_milestone_stat_grant(skill_id: String, _milestone_level: int, slot: int) -> void:
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _S.to_dict(gs.get("player", {}))
	var sb: Dictionary = _S.to_dict(pl.get("stat_block", {}))
	var attrs: Dictionary = _S.to_dict(sb.get("attributes", {}))

	var bias: Dictionary = _stat_bias_for(skill_id)
	for k in bias.keys():
		attrs[k] = int(attrs.get(k, 0)) + int(bias[k])

	sb["attributes"] = attrs
	pl["stat_block"] = sb
	gs["player"] = pl
	SaveManager.save_game(gs, slot)

static func _stat_bias_for(skill_id: String) -> Dictionary:
	var arr: Array = _read_ability_catalog()
	for any in arr:
		if any is Dictionary:
			var d: Dictionary = any
			if String(d.get("ability_id","")) == skill_id:
				var bias_in: Dictionary = _S.to_dict(d.get("stat_bias", {}))
				var out: Dictionary = {
					"STR": 0, "DEX": 0, "INT": 0, "WIS": 0,
					"END": 0, "AGI": 0, "CHA": 0, "LCK": 0
				}
				for k in bias_in.keys():
					out[k] = int(bias_in[k])
				return out
	return { "STR":0,"DEX":0,"INT":0,"WIS":0,"END":0,"AGI":0,"CHA":0,"LCK":0 }

static func _read_ability_catalog() -> Array:
	if not ResourceLoader.exists(ABILITY_CATALOG_PATH):
		return []
	var f: FileAccess = FileAccess.open(ABILITY_CATALOG_PATH, FileAccess.READ)
	if f == null:
		return []
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) == TYPE_ARRAY:
		return (parsed as Array)
	return []
