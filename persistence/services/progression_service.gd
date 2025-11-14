# res://persistence/services/progression_service.gd
extends RefCounted
class_name ProgressionService
## Character + Skill progression helpers (META).
## Adds: trainer/book-based cap recompute + group unlock helpers.

const _S    := preload("res://persistence/util/save_utils.gd")
const _Meta := preload("res://persistence/schemas/meta_schema.gd")
const XpTuning := preload("res://scripts/rewards/XpTuning.gd")

const DEFAULT_SLOT: int = 1
const ABILITY_CATALOG_PATH: String = "res://data/combat/abilities/ability_catalog.json"

static var DBG_PROG: bool = false
const _DBG_PREFIX := "[Prog] "

static func _log(msg: String) -> void:
	if DBG_PROG:
		print(_DBG_PREFIX + msg)

# ---------------- Character (delegates to XpTuning) ----------------

# Quadratic, difficulty-scaled threshold (prefer RUN difficulty)
static func xp_to_next(level: int) -> int:
	var l: int = max(1, level)
	var diff_code: String = "C"

	# Resolve difficulty directly from the SaveManager autoload (RUN → META → "C")
	var c_run: String = String(SaveManager.get_run_difficulty_code())
	if c_run.length() == 1:
		diff_code = c_run
	else:
		var c_meta: String = String(SaveManager.get_difficulty_code())
		if c_meta.length() == 1:
			diff_code = c_meta

	var out: int = XpTuning.xp_to_next_level_v2(l, diff_code)
	_log("xp_to_next: L=" + str(l) + " diff=" + diff_code + " → " + str(out))
	return out

# Level-up loop (character & skills)
static func _apply_xp_and_level(cur_xp: int, add: int, level: int, cap_band: int = 1_000_000) -> Dictionary:
	var new_xp: int = max(0, cur_xp) + max(0, add)
	var cur_level: int = max(1, level)
	var levels_gained: int = 0
	var need: int = xp_to_next(cur_level)
	while new_xp >= need and cur_level < cap_band:
		new_xp -= need
		cur_level += 1
		levels_gained += 1
		need = xp_to_next(cur_level)
	return {
		"xp": new_xp,
		"level": cur_level,
		"need": need,
		"levels_gained": levels_gained
	}

static func award_character_xp(amount: int, slot: int = DEFAULT_SLOT) -> Dictionary:
	var add: int = max(0, amount)
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _S.to_dict(gs.get("player", {}))
	var sb: Dictionary = _S.to_dict(pl.get("stat_block", {}))

	var lvl: int = int(sb.get("level", 1))
	var cur: int = int(sb.get("xp_current", 0))

	var res: Dictionary = _apply_xp_and_level(cur, add, lvl, 1_000_000)
	sb["level"] = int(res["level"])
	sb["xp_current"] = int(res["xp"])
	sb["xp_needed"]  = int(res["need"])

	# 2 points per character level-up (unchanged)
	var new_points: int = int(pl.get("points_unspent", 0)) + (int(res["levels_gained"]) * 2)
	pl["points_unspent"] = new_points
	pl["stat_block"] = sb

	gs["player"] = pl
	SaveManager.save_game(gs, slot)

	_log("award_character_xp: +%d → L%d xp=%d/%d (points=%d)" % [add, int(res["level"]), int(res["xp"]), int(res["need"]), new_points])
	return { "level": int(res["level"]), "xp_current": int(res["xp"]), "xp_needed": int(res["need"]), "points_unspent": new_points }

static func get_character_snapshot(slot: int = DEFAULT_SLOT) -> Dictionary:
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _S.to_dict(gs.get("player", {}))
	var sb: Dictionary = _S.to_dict(pl.get("stat_block", {}))
	var lvl: int = int(sb.get("level", 1))
	return {
		"level": lvl,
		"xp_current": int(sb.get("xp_current", 0)),
		"xp_needed": int(sb.get("xp_needed", xp_to_next(lvl))),
		"points_unspent": int(pl.get("points_unspent", 0))
	}

# ---------------- Skill Tracks (existing surface) ----------------------

static func _normalize_track(row_in: Dictionary) -> Dictionary:
	var row: Dictionary = _S.to_dict(row_in)
	if row.has("banked_xp") and not row.has("xp_current"):
		row["xp_current"] = int(row.get("banked_xp", 0))
		row.erase("banked_xp")
	var lvl: int = max(1, int(row.get("level", 1)))
	row["level"] = lvl
	row["cap_band"] = int(row.get("cap_band", 10))
	row["unlocked"] = bool(row.get("unlocked", false))
	row["last_milestone_applied"] = int(row.get("last_milestone_applied", 0))
	row["xp_current"] = int(row.get("xp_current", 0))
	# Always recompute threshold from difficulty (do not trust persisted xp_needed)
	row["xp_needed"]  = xp_to_next(lvl)
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
	var out: Dictionary = _get_tracks(pl).duplicate(true)
	_log("list_skill_tracks: count=" + str(out.size()))
	return out

static func get_skill_track(id: String, slot: int = DEFAULT_SLOT) -> Dictionary:
	var all: Dictionary = list_skill_tracks(slot)
	if all.has(id) and all[id] is Dictionary:
		return (all[id] as Dictionary).duplicate(true)
	return {}

static func set_unlocked(id: String, unlocked: bool, slot: int = DEFAULT_SLOT) -> void:
	if id.is_empty():
		return
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _S.to_dict(gs.get("player", {}))
	var st: Dictionary = _get_tracks(pl)
	var row: Dictionary = _S.to_dict(st.get(id, {}))
	if row.is_empty():
		row = _normalize_track({ "level": 1, "xp_current": 0, "cap_band": 10, "unlocked": unlocked, "last_milestone_applied": 0 })
	else:
		row["unlocked"] = unlocked
	# Threshold is recomputed by _normalize_track; ensure it is applied:
	row = _normalize_track(row)
	st[id] = row
	pl["skill_tracks"] = st
	gs["player"] = pl
	SaveManager.save_game(gs, slot)
	_log("set_unlocked: id=%s unlocked=%s" % [id, str(unlocked)])

static func lift_cap(id: String, new_cap_band: int, slot: int = DEFAULT_SLOT) -> void:
	if id.is_empty():
		return
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _S.to_dict(gs.get("player", {}))
	var st: Dictionary = _get_tracks(pl)
	if not st.has(id):
		return
	var row: Dictionary = _S.to_dict(st[id])
	row["cap_band"] = max(int(row.get("cap_band", 10)), new_cap_band)
	st[id] = _normalize_track(row)
	pl["skill_tracks"] = st
	gs["player"] = pl
	SaveManager.save_game(gs, slot)
	_log("lift_cap: id=%s cap=%d" % [id, int(st[id]["cap_band"])])

# ---------------- New: trainer/book cap recompute ----------------------

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
	return "physical"

static func _book_tier_for(ability_id: String, pl: Dictionary) -> int:
	var books: Dictionary = _S.to_dict(pl.get("skill_book_tiers", {})) # optional
	return int(_S.dget(books, ability_id, 0))

static func _cap_for_tier(tier: int) -> int:
	var t: int = max(0, tier)
	return 10 * (1 + t)

static func recompute_all_skill_caps(slot: int = DEFAULT_SLOT) -> void:
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _S.to_dict(gs.get("player", {}))
	var st: Dictionary = _get_tracks(pl)

	var catalog: Array[Dictionary] = _read_ability_catalog()
	for any in catalog:
		if not (any is Dictionary):
			continue
		var row: Dictionary = any
		var aid: String = String(_S.dget(row, "ability_id", ""))
		if aid == "":
			continue
		var group: String = _group_for_ability(row)
		var book_tier: int = _book_tier_for(aid, pl)
		# TODO: incorporate trainers + book_tier -> cap band into st[aid]["cap_band"]
		# (kept as a placeholder)

	pl["skill_tracks"] = st
	gs["player"] = pl
	SaveManager.save_game(gs, slot)
	_log("recompute_all_skill_caps: catalog=" + str(catalog.size()))

static func unlock_all_in_group(group_id: String, slot: int = DEFAULT_SLOT) -> void:
	if group_id == "":
		return
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _S.to_dict(gs.get("player", {}))
	var st: Dictionary = _get_tracks(pl)

	var catalog: Array[Dictionary] = _read_ability_catalog()
	for any in catalog:
		if not (any is Dictionary):
			continue
		var row: Dictionary = any
		var aid: String = String(_S.dget(row, "ability_id", ""))
		if aid == "":
			continue
		if _group_for_ability(row) != group_id:
			continue
		var r: Dictionary = _S.to_dict(st.get(aid, {}))
		r["unlocked"] = true
		st[aid] = _normalize_track(r)

	pl["skill_tracks"] = st
	gs["player"] = pl
	SaveManager.save_game(gs, slot)
	_log("unlock_all_in_group: group=%s" % group_id)

# ---------------- Awarding skill XP (RUN delegate) ---------------------

static func award_skill_xp(id: String, add_xp: int, slot: int = DEFAULT_SLOT) -> Dictionary:
	return SaveManager.apply_skill_xp_to_run(String(id), int(add_xp), slot)

# ---------------- Death penalties (unchanged) -------------------------

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
		if not (st[k] is Dictionary):
			continue
		var row: Dictionary = _S.to_dict(st[k])
		var lvl: int = int(row.get("level", 1))
		row["xp_current"] = 0
		row["xp_needed"]  = xp_to_next(lvl)
		st[k] = row

	pl["skill_tracks"] = st
	gs["player"] = pl
	SaveManager.save_game(gs, slot)
	_log("apply_death_penalties: reset to current diff thresholds")

# ---------------- Milestones / stat bias (META helper) ----------------

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
	_log("_apply_milestone_stat_grant: id=%s bias=%s" % [skill_id, str(bias)])

static func _stat_bias_for(skill_id: String) -> Dictionary:
	var rows: Array[Dictionary] = _read_ability_catalog()
	var found: Dictionary = {}
	for d_any in rows:
		if d_any is Dictionary:
			var d: Dictionary = d_any
			if String(d.get("ability_id","")) == skill_id:
				found = d
				break

	var bias_in: Dictionary = _S.to_dict(found.get("stat_bias", _S.to_dict(found.get("statBias", {}))))
	var out: Dictionary = {
		"STR": 0, "AGI": 0, "DEX": 0, "END": 0,
		"INT": 0, "WIS": 0, "CHA": 0, "LCK": 0
	}
	for k in bias_in.keys():
		out[k] = int(bias_in[k])

	_log("_stat_bias_for: id=%s found=%s bias=%s" % [skill_id, str(not found.is_empty()), str(out)])
	return out

static func _read_ability_catalog() -> Array[Dictionary]:
	var out_arr: Array[Dictionary] = []

	if not ResourceLoader.exists(ABILITY_CATALOG_PATH):
		push_error("[Prog/_read_ability_catalog] MISSING file at %s" % ABILITY_CATALOG_PATH)
		return out_arr

	var f: FileAccess = FileAccess.open(ABILITY_CATALOG_PATH, FileAccess.READ)
	if f == null:
		push_error("[Prog/_read_ability_catalog] open() failed: %s" % ABILITY_CATALOG_PATH)
		return out_arr

	var parsed: Variant = JSON.parse_string(f.get_as_text())

	# Case 1: already an array
	if parsed is Array:
		for elem in (parsed as Array):
			if elem is Dictionary:
				out_arr.append((elem as Dictionary).duplicate(true))
		_log("_read_ability_catalog: loaded entries=" + str(out_arr.size()) + " (array)")
		return out_arr

	# Case 2: single row object
	if parsed is Dictionary and (parsed as Dictionary).has("ability_id"):
		out_arr.append((parsed as Dictionary).duplicate(true))
		_log("_read_ability_catalog: loaded entries=1 (single object)")
		return out_arr

	# Case 3: pre-keyed dict { "arc_slash": {...}, ... }
	if parsed is Dictionary:
		var d: Dictionary = parsed as Dictionary
		for k in d.keys():
			var row_any: Variant = d[k]
			if row_any is Dictionary:
				var row: Dictionary = (row_any as Dictionary).duplicate(true)
				if not row.has("ability_id"):
					row["ability_id"] = String(k)
				out_arr.append(row)
		_log("_read_ability_catalog: loaded entries=" + str(out_arr.size()) + " (pre-keyed map)")
		return out_arr

	_log("_read_ability_catalog: parsed unknown shape; entries=0")
	return out_arr
