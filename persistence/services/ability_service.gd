extends RefCounted
class_name AbilityService
## Ability data defaults/migration + lightweight query helpers used by XP/award code.

const _S  := preload("res://persistence/util/save_utils.gd")
const _PS := preload("res://persistence/services/progression_service.gd")

const LATEST_VERSION: int = 6

# -------------------------------------------------------------------
# Public API (defaults / migration for META.skill_tracks)
# -------------------------------------------------------------------

static func defaults() -> Dictionary:
	var now_ts: int = _S.now_ts()

	var skill_ids: Array[String] = [
		"arc_slash","thrust","skewer","riposte","guard_break","crush",
		"aimed_shot","piercing_bolt",
		"firebolt","flame_wall",
		"water_jet","tide_surge",
		"gust",
		"stone_spikes",
		"shadow_grasp","curse_mark",
		"heal","purify",
		"block","bulwark"
	]

	var tracks: Dictionary = {}
	for id in skill_ids:
		var start_unlocked: bool = (id == "arc_slash" or id == "heal")
		tracks[id] = _skill_track_default(start_unlocked)

	return {
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
					"mainhand": null, "offhand": null, "ring1": null, "ring2": null, "amulet": null
				},
				"weapon_tags": []
			},
			"stat_block": {
				"attributes": {
					"STR": 8, "AGI": 8, "DEX": 8, "END": 8, "INT": 8, "WIS": 8, "CHA": 8, "LCK": 8
				},
				"level": 1,
				"xp_current": 0,
				"xp_needed": _PS.xp_to_next(1)
			},
			"skill_tracks": tracks
		}
	}

# Back-compat: some callers used normalize(). Route to migrate().
static func normalize(d_in: Dictionary) -> Dictionary:
	return migrate(d_in)

static func migrate(d_in: Dictionary) -> Dictionary:
	var d: Dictionary = _S.to_dict(d_in)
	if d.is_empty():
		return defaults()

	var sv: int = int(d.get("schema_version", 0))
	if sv <= 0:
		sv = 1

	# ---------- Normalize top-level ----------
	d["previous_floor"] = int(d.get("previous_floor", 0))
	d["current_floor"] = int(d.get("current_floor", 1))
	d["highest_teleport_floor"] = int(d.get("highest_teleport_floor", 1))
	d["stash_gold"] = int(d.get("stash_gold", 0))
	d["stash_shards"] = int(d.get("stash_shards", 0))

	var pl: Dictionary = _S.to_dict(d.get("player", {}))
	pl["points_unspent"] = int(pl.get("points_unspent", 0))

	# stat_block
	var sb: Dictionary = _S.to_dict(pl.get("stat_block", {}))
	var lvl: int = int(sb.get("level", 1))
	sb["level"] = lvl
	sb["xp_current"] = int(sb.get("xp_current", 0))
	sb["xp_needed"] = int(sb.get("xp_needed", _PS.xp_to_next(lvl)))
	# attributes
	var attrs_in: Dictionary = _S.to_dict(sb.get("attributes", {}))
	var attrs_out: Dictionary = {
		"STR": 8, "AGI": 8, "DEX": 8, "END": 8, "INT": 8, "WIS": 8, "CHA": 8, "LCK": 8
	}
	for k in attrs_out.keys():
		attrs_out[k] = int(attrs_in.get(k, attrs_out[k]))
	sb["attributes"] = attrs_out
	pl["stat_block"] = sb

	# loadout
	var lo: Dictionary = _S.to_dict(pl.get("loadout", {}))
	var eq_in: Dictionary = _S.to_dict(lo.get("equipment", {}))
	var eq_out: Dictionary = {
		"head": null, "chest": null, "legs": null, "boots": null,
		"mainhand": null, "offhand": null, "ring1": null, "ring2": null, "amulet": null
	}
	for k in eq_out.keys():
		eq_out[k] = eq_in.get(k, null)
	lo["equipment"] = eq_out
	lo["weapon_tags"] = _S.to_string_array(lo.get("weapon_tags", []))
	pl["loadout"] = lo

	# ---------- Skill tracks: banked_xp -> xp_current/xp_needed ----------
	var st_in: Dictionary = _S.to_dict(pl.get("skill_tracks", {}))
	var st_out: Dictionary = {}

	for id in st_in.keys():
		var row: Dictionary = _S.to_dict(st_in[id])
		var rlvl: int = int(row.get("level", 1))

		var cur: int = 0
		if row.has("xp_current"):
			cur = int(row.get("xp_current", 0))
		else:
			cur = int(row.get("banked_xp", 0)) # legacy

		var need: int = int(row.get("xp_needed", _PS.xp_to_next(rlvl)))
		var cap: int = int(row.get("cap_band", 10))
		var unlocked: bool = bool(row.get("unlocked", false))
		var last_ms: int = int(row.get("last_milestone_applied", 0))

		st_out[id] = {
			"level": max(1, rlvl),
			"xp_current": max(0, cur),
			"xp_needed": max(1, need),
			"cap_band": max(1, cap),
			"unlocked": unlocked,
			"last_milestone_applied": max(0, last_ms)
		}

	# Ensure starters exist & unlocked
	for ensure_id in ["arc_slash", "heal"]:
		if not st_out.has(ensure_id):
			st_out[ensure_id] = _skill_track_default(true)
		else:
			var fixed: Dictionary = _S.to_dict(st_out[ensure_id])
			fixed["unlocked"] = true
			if not fixed.has("xp_current"):
				fixed["xp_current"] = 0
			if not fixed.has("xp_needed"):
				fixed["xp_needed"] = _PS.xp_to_next(int(fixed.get("level", 1)))
			st_out[ensure_id] = fixed

	pl["skill_tracks"] = st_out
	d["player"] = pl

	# ---------- Stamp + bump ----------
	d["schema_version"] = LATEST_VERSION
	if not d.has("created_at"):
		d["created_at"] = float(_S.now_ts())
	d["updated_at"] = _S.now_ts()

	return d

# -------------------------------------------------------------------
# Lightweight query/mutation helpers expected by other systems
# -------------------------------------------------------------------

static func is_unlocked(ability_id: String, slot: int = 1) -> bool:
	if ability_id.is_empty():
		return false
	var row: Dictionary = _PS.get_skill_track(ability_id, slot)
	return bool(row.get("unlocked", false))

static func level(ability_id: String, slot: int = 1) -> int:
	if ability_id.is_empty():
		return 1
	var row: Dictionary = _PS.get_skill_track(ability_id, slot)
	return int(row.get("level", 1))

static func xp_snapshot(ability_id: String, slot: int = 1) -> Dictionary:
	if ability_id.is_empty():
		return {}
	return _PS.get_skill_track(ability_id, slot)

static func unlock(ability_id: String, slot: int = 1) -> void:
	if ability_id.is_empty():
		return
	_PS.set_unlocked(ability_id, true, slot)

static func lock(ability_id: String, slot: int = 1) -> void:
	if ability_id.is_empty():
		return
	_PS.set_unlocked(ability_id, false, slot)

static func lift_cap(ability_id: String, new_cap_band: int, slot: int = 1) -> void:
	if ability_id.is_empty():
		return
	_PS.lift_cap(ability_id, new_cap_band, slot)

static func list_unlocked(slot: int = 1) -> Array[String]:
	var out: Array[String] = []
	var all: Dictionary = _PS.list_skill_tracks(slot)
	for k in all.keys():
		var row: Dictionary = all[k]
		if bool(row.get("unlocked", false)):
			out.append(String(k))
	return out

# --- NEW: direct XP award used by ability_xp_service ----------------

static func award_xp(ability_id: String, add_xp: int, slot: int = 1) -> Dictionary:
	if ability_id.is_empty():
		return {}

	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _S.to_dict(gs.get("player", {}))
	var st: Dictionary = _S.to_dict(pl.get("skill_tracks", {}))

	if not st.has(ability_id):
		st[ability_id] = _skill_track_default(false)

	var row: Dictionary = _S.to_dict(st.get(ability_id, {}))
	var lvl: int = int(row.get("level", 1))
	var cur: int = int(row.get("xp_current", 0))
	var need: int = int(row.get("xp_needed", _PS.xp_to_next(lvl)))
	var cap: int = int(row.get("cap_band", 10))

	cur += max(0, add_xp)

	while (lvl < cap) and (cur >= need):
		cur -= need
		lvl += 1
		need = _PS.xp_to_next(lvl)

	row["level"] = lvl
	row["xp_current"] = cur
	row["xp_needed"] = need
	st[ability_id] = row

	pl["skill_tracks"] = st
	gs["player"] = pl
	SaveManager.save_game(gs, slot)

	return row.duplicate(true)

# -------------------------------------------------------------------
# Internals
# -------------------------------------------------------------------

static func _skill_track_default(unlocked: bool) -> Dictionary:
	return {
		"level": 1,
		"xp_current": 0,
		"xp_needed": _PS.xp_to_next(1),
		"cap_band": 10,
		"unlocked": unlocked,
		"last_milestone_applied": 0
	}
