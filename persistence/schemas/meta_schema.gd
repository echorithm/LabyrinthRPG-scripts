extends RefCounted
class_name MetaSchema

const LATEST_VERSION: int = 4

# --- convenience ---
const _S := preload("res://persistence/util/save_utils.gd")

# -------------------------------------------------
# Public API
# -------------------------------------------------
static func defaults() -> Dictionary:
	var now: int = _S.now_ts()
	return {
		"schema_version": LATEST_VERSION,
		"created_at": now,
		"updated_at": now,

		# Floors
		"last_floor": 1,
		"current_floor": 1,
		"previous_floor": 0,

		# Non-double-dip (character)
		"highest_claimed_level": 1,

		# Player block (canonical)
		"player": {
			"stat_block": {
				"level": 1,
				"xp_current": 0,
				"xp_needed": 90, # initial step; tune/formula elsewhere
				# UPPERCASE attributes
				"attributes": _default_attributes_upper(),
			},

			# Legacy mirrors (kept for UI compat; not authoritative)
			"health": 100,
			"level": 1,
			"highest_claimed_level": 1,

			# Equipment/loadout + identity
			"loadout": {
				"equipment": _empty_equipment_slots(), # stores uids for durable items (or null)
				"weapon_tags": [],
			},
			"known_actions": [],

			# Progression lists
			# Skills persist across runs (mastery); cap gates enforced elsewhere
			# {id, level, xp_current, xp_needed, cap, milestones_claimed[]}
			"skills": [],
			# Inventory is authoritative in META; RUN uses a snapshot (Option B) per session
			# Item: {id,count,ilvl,archetype,rarity,affixes[],durability_max,durability_current,weight,uid?}
			"inventory": [],
		},

		# World
		"world_flags": {},
		"floor_seeds": {},      # kept for legacy compat; not required if you derive per-run
		"anchors_unlocked": [1],
		# Drained by triad (segment of 3 floors)
		"world_segments": [
			{"segment_id": 1, "drained": false, "boss_sigil": false}
		],

		# Death penalties (config defaults; applied by SaveManager)
		"penalties": {
			"level_pct": 0.10,          # kept for reference; not used in current death rule
			"skill_xp_pct": 0.15,       # kept for reference; not used in current death rule
			"floor_at_level": 1,
			"floor_at_skill_level": 1
		}
	}

static func migrate(d_in: Dictionary) -> Dictionary:
	# Defensive copy + timestamps
	var d: Dictionary = _S.deep_copy_dict(d_in)
	var now: int = _S.now_ts()
	var ver: int = int(_S.dget(d, "schema_version", 0))
	if ver <= 0:
		ver = 1
		d["schema_version"] = 1
	if not d.has("created_at"):
		d["created_at"] = now

	# Chain migrations up to LATEST_VERSION
	if ver == 1:
		d = _migrate_v1_to_v2(d)
		ver = 2
	if ver == 2:
		d = _migrate_v2_to_v3(d)
		ver = 3
	if ver == 3:
		d = _migrate_v3_to_v4(d)
		ver = 4

	# Normalize common fields every time
	d = _normalize_common(d)
	d["schema_version"] = LATEST_VERSION
	d["updated_at"] = now
	return d

# Convenience alias
static func normalize(d: Dictionary) -> Dictionary:
	return migrate(d)

# -------------------------------------------------
# Internal: migrations
# -------------------------------------------------
static func _migrate_v1_to_v2(d_in: Dictionary) -> Dictionary:
	var d: Dictionary = _S.deep_copy_dict(d_in)

	# Player → add stat_block; move level into it (keep old level for backward UI if referenced)
	var p: Dictionary = _S.to_dict(_S.dget(d, "player", {}))
	var lvl: int = max(1, int(_S.dget(p, "level", 1)))
	var sb_any: Variant = _S.dget(p, "stat_block", {})
	var sb: Dictionary = _S.to_dict(sb_any)
	if not sb.has("level"): sb["level"] = lvl
	if not sb.has("xp"): sb["xp"] = 0
	if not sb.has("attributes"): sb["attributes"] = _default_attributes_upper() # will be normalized later
	p["stat_block"] = sb

	# Highest-claimed guard
	var hc_pl: int = max(1, int(_S.dget(p, "highest_claimed_level", lvl)))
	p["highest_claimed_level"] = hc_pl
	d["highest_claimed_level"] = int(max(1, int(_S.dget(d, "highest_claimed_level", hc_pl))))

	d["player"] = p
	d["schema_version"] = 2
	return d

static func _migrate_v2_to_v3(d_in: Dictionary) -> Dictionary:
	var d: Dictionary = _S.deep_copy_dict(d_in)
	var p: Dictionary = _S.to_dict(_S.dget(d, "player", {}))

	# Add loadout/equipment + weapon_tags
	if not p.has("loadout"):
		p["loadout"] = {}
	var lo: Dictionary = _S.to_dict(p["loadout"])
	if not lo.has("equipment"):
		lo["equipment"] = _empty_equipment_slots()
	if not lo.has("weapon_tags"):
		lo["weapon_tags"] = []
	p["loadout"] = lo

	# Add known_actions if missing
	if not p.has("known_actions"):
		p["known_actions"] = []

	# Inventory: ensure new shape + uid for non-stackables
	var inv_any: Variant = _S.dget(p, "inventory", [])
	var inv_in: Array = (inv_any as Array) if inv_any is Array else []
	var ilvl_guess: int = max(1, int(_S.dget(d, "current_floor", 1)))
	var inv_out: Array = []
	for it_any in inv_in:
		if not (it_any is Dictionary):
			continue
		var it: Dictionary = _normalize_item_dict(it_any as Dictionary, ilvl_guess)
		inv_out.append(it)
	p["inventory"] = inv_out

	d["player"] = p
	d["schema_version"] = 3
	return d

# v3 → v4: uppercase attributes; split xp into xp_current/xp_needed
static func _migrate_v3_to_v4(d_in: Dictionary) -> Dictionary:
	var d: Dictionary = _S.deep_copy_dict(d_in)
	var p: Dictionary = _S.to_dict(_S.dget(d, "player", {}))
	var sb: Dictionary = _S.to_dict(_S.dget(p, "stat_block", {}))
	var attrs_any: Variant = _S.dget(sb, "attributes", {})
	var attrs: Dictionary = _S.to_dict(attrs_any)

	# Map lowercase to uppercase, fill missing with 8
	var out_attrs: Dictionary = {}
	var keys: Array[String] = ["STR","AGI","DEX","END","INT","WIS","CHA","LCK"]
	var lower_map: Dictionary = {
		"str":"STR","agi":"AGI","dex":"DEX","end":"END","int":"INT","wis":"WIS","cha":"CHA","lck":"LCK"
	}
	for k in keys:
		if attrs.has(k):
			out_attrs[k] = float(attrs[k])
		else:
			# fallback from lowercase source or default 8
			var lk: String = ""
			for m in lower_map.keys():
				if lower_map[m] == k: lk = String(m)
			out_attrs[k] = float(attrs.get(lk, 8.0))

	# Split xp fields
	var xp_legacy: int = int(_S.dget(sb, "xp", 0))
	if not sb.has("xp_current"):
		sb["xp_current"] = xp_legacy
	if not sb.has("xp_needed"):
		sb["xp_needed"] = 90

	sb["attributes"] = out_attrs
	p["stat_block"] = sb
	d["player"] = p
	d["schema_version"] = 4
	return d

# -------------------------------------------------
# Internal: normalization pass (idempotent)
# -------------------------------------------------
static func _normalize_common(d_in: Dictionary) -> Dictionary:
	var out: Dictionary = _S.deep_copy_dict(d_in)

	# Floors
	out["last_floor"]     = int(_S.dget(out, "last_floor", 1))
	out["current_floor"]  = max(1, int(_S.dget(out, "current_floor", 1)))
	out["previous_floor"] = max(0, int(_S.dget(out, "previous_floor", 0)))

	# Penalties
	var p_any: Variant = _S.dget(out, "penalties", {})
	var p: Dictionary = _S.to_dict(p_any)
	out["penalties"] = {
		"level_pct": float(_S.dget(p, "level_pct", 0.10)),
		"skill_xp_pct": float(_S.dget(p, "skill_xp_pct", 0.15)),
		"floor_at_level": max(1, int(_S.dget(p, "floor_at_level", 1))),
		"floor_at_skill_level": max(1, int(_S.dget(p, "floor_at_skill_level", 1))),
	}

	# Anchors & segments
	if not out.has("anchors_unlocked"):
		out["anchors_unlocked"] = [1]
	if not out.has("world_segments"):
		out["world_segments"] = [{"segment_id": 1, "drained": false, "boss_sigil": false}]

	# Player normalization (skills, inventory finalized here too)
	var pl: Dictionary = _S.to_dict(_S.dget(out, "player", {}))

	# Stat block presence
	var sb: Dictionary = _S.to_dict(_S.dget(pl, "stat_block", {}))
	if not sb.has("level"):
		sb["level"] = max(1, int(_S.dget(pl, "level", 1)))
	if not sb.has("xp_current"):
		sb["xp_current"] = int(_S.dget(sb, "xp", 0))
	if not sb.has("xp_needed"):
		sb["xp_needed"] = 90
	if not sb.has("attributes"):
		sb["attributes"] = _default_attributes_upper()
	else:
		# Coerce to UPPERCASE and floats
		var attrs_in: Dictionary = _S.to_dict(sb["attributes"])
		var attrs_out: Dictionary = {}
		for k in ["STR","AGI","DEX","END","INT","WIS","CHA","LCK"]:
			attrs_out[k] = float(attrs_in.get(k, 8.0))
		sb["attributes"] = attrs_out
	pl["stat_block"] = sb

	# Highest-claimed protections
	var lvl: int = int(_S.dget(sb, "level", 1))
	pl["highest_claimed_level"] = max(1, int(_S.dget(pl, "highest_claimed_level", lvl)))
	out["highest_claimed_level"] = max(1, int(_S.dget(out, "highest_claimed_level", pl["highest_claimed_level"])))

	# Skills normalize
	var skills_any: Variant = _S.dget(pl, "skills", [])
	var skills_in: Array = (skills_any as Array) if skills_any is Array else []
	var skills_out: Array = []
	for s_any in skills_in:
		if not (s_any is Dictionary):
			continue
		var sd: Dictionary = s_any as Dictionary
		var lvl_s: int = max(1, int(_S.dget(sd, "level", 1)))
		var cap: int = max(1, int(_S.dget(sd, "cap", 10)))
		var xp_cur: int = int(_S.dget(sd, "xp_current", int(_S.dget(sd, "xp", 0))))
		var xp_need: int = int(_S.dget(sd, "xp_needed", 90))
		var m_arr: Array[int] = _S.to_int_array(_S.dget(sd, "milestones_claimed", [0]))
		if m_arr.is_empty():
			m_arr = [0]
		skills_out.append({
			"id": String(_S.dget(sd, "id", "")),
			"level": lvl_s,
			"xp_current": xp_cur,
			"xp_needed": xp_need,
			"cap": cap,
			"milestones_claimed": m_arr
		})
	pl["skills"] = skills_out

	# Inventory normalize (idempotent)
	var inv_in_any: Variant = _S.dget(pl, "inventory", [])
	var inv_in: Array = (inv_in_any as Array) if inv_in_any is Array else []
	var inv_out: Array = []
	var ilvl_guess: int = max(1, int(_S.dget(out, "current_floor", 1)))
	for it_any in inv_in:
		if it_any is Dictionary:
			inv_out.append(_normalize_item_dict(it_any as Dictionary, ilvl_guess))
	pl["inventory"] = inv_out

	# Loadout / known_actions presence
	if not pl.has("loadout"):
		pl["loadout"] = {"equipment": _empty_equipment_slots(), "weapon_tags": []}
	else:
		var lo: Dictionary = _S.to_dict(pl["loadout"])
		if not lo.has("equipment"):
			lo["equipment"] = _empty_equipment_slots()
		if not lo.has("weapon_tags"):
			lo["weapon_tags"] = []
		pl["loadout"] = lo

	if not pl.has("known_actions"):
		pl["known_actions"] = []

	out["player"] = pl

	# Seeds normalize (legacy compat)
	out["floor_seeds"] = _S.normalize_seeds(_S.dget(out, "floor_seeds", {}))
	return out

# -------------------------------------------------
# Internal: helpers
# -------------------------------------------------
static func _default_attributes_upper() -> Dictionary:
	return {
		"STR": 8.0, "AGI": 8.0, "DEX": 8.0, "END": 8.0,
		"INT": 8.0, "WIS": 8.0, "CHA": 8.0, "LCK": 8.0
	}

static func _empty_equipment_slots() -> Dictionary:
	return {
		"head": null, "chest": null, "legs": null, "boots": null,
		"mainhand": null, "offhand": null,
		"ring1": null, "ring2": null, "amulet": null
	}

static func _normalize_item_dict(it_in: Dictionary, ilvl_guess: int) -> Dictionary:
	var it: Dictionary = _S.deep_copy_dict(it_in)
	var id_str: String = String(_S.dget(it, "id", ""))

	var count: int = max(1, int(_S.dget(it, "count", 1)))
	var aff_arr: Array[String] = _S.to_string_array(_S.dget(it, "affixes", []))
	var ilvl: int = int(_S.dget(it, "ilvl", ilvl_guess))
	var arche: String = String(_S.dget(it, "archetype", "Light"))
	var rarity: String = String(_S.dget(it, "rarity", "Common"))
	var dmax: int = int(_S.dget(it, "durability_max", 100))
	var dcur: int = int(_S.dget(it, "durability_current", dmax))
	var w: float = float(_S.dget(it, "weight", 1.0))

	it = {
		"id": id_str,
		"count": count,
		"ilvl": ilvl,
		"archetype": arche,
		"rarity": rarity,
		"affixes": aff_arr,
		"durability_max": dmax,
		"durability_current": dcur,
		"weight": w
	}

	# Assign a uid to non-stackables to support equipment references
	if dmax > 0:
		var uid_str: String = String(_S.dget(it_in, "uid", ""))
		if uid_str.is_empty():
			uid_str = _gen_uid()
		it["uid"] = uid_str

	return it

static func _gen_uid() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var a: int = _S.now_ts() & 0x7FFFFFFF
	var b: int = int(rng.randi() & 0x7FFFFFFF)
	return "u%08x%08x" % [a, b]
