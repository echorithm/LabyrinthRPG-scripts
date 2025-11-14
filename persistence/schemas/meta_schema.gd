# res://persistence/schemas/meta_schema.gd
extends RefCounted
class_name MetaSchema

## META schema: defaults + migration with difficulty-aware XP thresholds.
## This version computes xp_needed from the META difficulty code (if present),
## so newly-created or migrated saves never carry Common thresholds by accident.

const _S  := preload("res://persistence/util/save_utils.gd")
const _Xp := preload("res://scripts/rewards/XpTuning.gd")

const LATEST_VERSION: int = 7

static var DEBUG: bool = false
const _DBG_PREFIX := "[MetaSchema] "

static func _log(msg: String) -> void:
	if DEBUG:
		print(_DBG_PREFIX + msg)

# --- helpers ---------------------------------------------------------

static func _diff_from_meta(meta_like: Dictionary) -> String:
	var settings_any: Variant = meta_like.get("settings", {})
	var settings: Dictionary = (settings_any as Dictionary) if (settings_any is Dictionary) else {}
	var code: String = String(settings.get("difficulty", "C"))
	if code.length() != 1:
		code = "C"
	return code

static func _xp_needed_for(level: int, diff_code: String) -> int:
	var l: int = max(1, level)
	return _Xp.xp_to_next_level_v2(l, diff_code)

static func _skill_track_default(unlocked: bool, diff_code: String) -> Dictionary:
	return {
		"level": 1,
		"xp_current": 0,
		"xp_needed": _xp_needed_for(1, diff_code),
		"cap_band": 10,
		"unlocked": unlocked,
		"last_milestone_applied": 0
	}

static func _skill_id_list() -> Array[String]:
	var ids: Array[String] = [
		"arc_slash","thrust","skewer","riposte","guard_break","crush",
		"aimed_shot","piercing_bolt",
		"firebolt","flame_wall",
		"water_jet","tide_surge",
		"gust","cyclone",
		"stone_spikes",
		"shadow_grasp","curse_mark",
		"heal","purify",
		"block","bulwark",
		"punch","rest","meditate"
	]
	return ids

# --- defaults --------------------------------------------------------

static func defaults() -> Dictionary:
	var now_ts: int = _S.now_ts()
	# Defaults assume Common until NewGame stamps settings.difficulty and migration runs again.
	var base_diff: String = "C"

	var skill_ids: Array[String] = _skill_id_list()
	var tracks: Dictionary = {}
	for id: String in skill_ids:
		tracks[id] = _skill_track_default(false, base_diff)

	var d: Dictionary = {
		"schema_version": LATEST_VERSION,
		"created_at": float(now_ts),
		"updated_at": now_ts,
		"previous_floor": 0,
		"current_floor": 1,
		"highest_teleport_floor": 1,
		"stash_gold": 0,
		"stash_shards": 0,
		"player": {
			"points_unspent": 0,
			"inventory": [],
			"loadout": {
				"equipment": {
					"head": null, "chest": null, "legs": null, "boots": null,
					"sword": null, "spear": null, "mace": null, "bow": null,
					"ring1": null, "ring2": null, "amulet": null
				},
				"weapon_tags": []
			},
			"stat_block": {
				"attributes": {
					"STR": 8, "AGI": 8, "DEX": 8, "END": 8, "INT": 8, "WIS": 8, "CHA": 8, "LCK": 8
				},
				"level": 1,
				"xp_current": 0,
				"xp_needed": _xp_needed_for(1, base_diff)
			},
			"skill_tracks": tracks
		}
	}

	_log("defaults: base_diff=" + base_diff + " char_need=" + str(d["player"]["stat_block"]["xp_needed"]))
	return d

# --- migration / normalization --------------------------------------

static func migrate(d_in: Dictionary) -> Dictionary:
	var d: Dictionary = _S.to_dict(d_in)
	if d.is_empty():
		_log("migrate: input empty → defaults()")
		return defaults()

	# Freshness & typing for top-level
	d["previous_floor"] = int(d.get("previous_floor", 0))
	d["current_floor"] = int(d.get("current_floor", 1))
	d["highest_teleport_floor"] = int(d.get("highest_teleport_floor", 1))
	d["stash_gold"] = int(d.get("stash_gold", 0))
	d["stash_shards"] = int(d.get("stash_shards", 0))

	# Difficulty to use for *all* threshold recalcs in this migration pass.
	var diff_code: String = _diff_from_meta(d)
	_log("migrate: using diff=" + diff_code)

	# --- Player block
	var pl: Dictionary = _S.to_dict(d.get("player", {}))
	pl["points_unspent"] = int(pl.get("points_unspent", 0))

	# Stat block
	var sb: Dictionary = _S.to_dict(pl.get("stat_block", {}))
	var lvl: int = int(sb.get("level", 1))
	sb["level"] = max(1, lvl)
	sb["xp_current"] = int(sb.get("xp_current", 0))
	sb["xp_needed"]  = _xp_needed_for(sb["level"], diff_code)
	pl["stat_block"] = sb
	_log("migrate: stat_block L" + str(sb["level"]) + " need=" + str(sb["xp_needed"]))

	# Loadout (canonical slots)
	var lo: Dictionary = _S.to_dict(pl.get("loadout", {}))
	var eq_in: Dictionary = _S.to_dict(lo.get("equipment", {}))
	var eq_out: Dictionary = {
		"head": null, "chest": null, "legs": null, "boots": null,
		"sword": null, "spear": null, "mace": null, "bow": null,
		"ring1": null, "ring2": null, "amulet": null
	}
	var canonical_keys: PackedStringArray = PackedStringArray([
		"head","chest","legs","boots","sword","spear","mace","bow","ring1","ring2","amulet"
	])
	for k: String in canonical_keys:
		eq_out[k] = eq_in.get(k, null)
	lo["equipment"] = eq_out
	lo["weapon_tags"] = _S.to_string_array(lo.get("weapon_tags", []))
	pl["loadout"] = lo

	# --- Skill tracks: always recompute xp_needed from difficulty code
	var st_in: Dictionary = _S.to_dict(pl.get("skill_tracks", {}))
	var st_out: Dictionary = {}
	var changed_count: int = 0

	# Collect IDs with typing
	var st_ids: Array[String] = []
	for k in st_in.keys():
		st_ids.append(String(k))

	for id: String in st_ids:
		var row: Dictionary = _S.to_dict(st_in.get(id, {}))
		var rlvl: int = max(1, int(row.get("level", 1)))
		var cur: int = 0
		if row.has("xp_current"):
			cur = int(row.get("xp_current", 0))
		elif row.has("banked_xp"):
			cur = int(row.get("banked_xp", 0))
		var cap: int = max(1, int(row.get("cap_band", 10)))
		var unlocked: bool = bool(row.get("unlocked", false))
		var last_ms: int = max(0, int(row.get("last_milestone_applied", 0)))

		var need_new: int = _xp_needed_for(rlvl, diff_code)
		var need_old: int = int(row.get("xp_needed", need_new))
		if need_old != need_new:
			changed_count += 1

		st_out[id] = {
			"level": rlvl,
			"xp_current": max(0, cur),
			"xp_needed": need_new,
			"cap_band": cap,
			"unlocked": unlocked,
			"last_milestone_applied": last_ms
		}

	# Ensure core/new tracks exist (locked by default)
	var ensure_ids: Array[String] = ["arc_slash", "heal", "punch", "rest", "meditate", "cyclone"]
	for nid: String in ensure_ids:
		if not st_out.has(nid):
			st_out[nid] = _skill_track_default(false, diff_code)

	pl["skill_tracks"] = st_out
	d["player"] = pl

	# Stamp & bump
	d["schema_version"] = LATEST_VERSION
	if not d.has("created_at"):
		d["created_at"] = float(_S.now_ts())
	d["updated_at"] = _S.now_ts()

	_log("migrate: tracks normalized=" + str(st_out.size()) + " thresholds_changed=" + str(changed_count))
	return d

# Backward-compatible alias
static func normalize(d_in: Dictionary) -> Dictionary:
	var input: Dictionary = _S.to_dict(d_in)
	return migrate(input)
