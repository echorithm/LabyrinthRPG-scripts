extends RefCounted
class_name MetaSchema

const LATEST_VERSION: int = 5

const _S := preload("res://persistence/util/save_utils.gd")

static func defaults() -> Dictionary:
	var now: int = _S.now_ts()
	return {
		"schema_version": LATEST_VERSION,
		"created_at": now,
		"updated_at": now,

		# Floor/menu state (no more last_floor)
		"current_floor": 1,
		"previous_floor": 0,
		"highest_teleport_floor": 1, # unlocks: 4,7,10,… after beating 3,6,9,…

		# Player progression (canonical)
		"player": {
			"stat_block": {
				"level": 1,
				"xp_current": 0,
				"xp_needed": 90,
				"attributes": _default_attributes_upper(),
			},
			"level": 1,                    # legacy UI mirror
			"highest_claimed_level": 1,    # anti double-dip

			# Equipment/loadout identity (values are uids or null)
			"loadout": {
				"equipment": _empty_equipment_slots(),
				"weapon_tags": [],
			},

			# Unlocked permanent abilities (sparse map)
			"abilities_unlocked": {},

			# Skills persist across runs
			"skills": [],

			# Authoritative out-of-run inventory
			"inventory": [],
		},

		# Village safety
		"stash_gold": 0,
		"stash_shards": 0,
		"stash_items": [],  # same normalized item shape as inventory

		# Permanent & next-run buffs
		"permanent_blessings": [],
		"queued_blessings_next_run": [],

		# World flags (keep generic)
		"world_flags": {},
		"anchors_unlocked": [1],

		# Config references (kept; not directly used in death now)
		"penalties": {
			"level_pct": 0.10,
			"skill_xp_pct": 0.15,
			"floor_at_level": 1,
			"floor_at_skill_level": 1
		}
	}

static func migrate(d_in: Dictionary) -> Dictionary:
	var d: Dictionary = _S.deep_copy_dict(d_in)
	var now: int = _S.now_ts()
	var ver: int = int(_S.dget(d, "schema_version", 0))
	if ver <= 0:
		ver = 1
		d["schema_version"] = 1
	if not d.has("created_at"):
		d["created_at"] = now

	if ver == 1:
		d = _migrate_v1_to_v2(d); ver = 2
	if ver == 2:
		d = _migrate_v2_to_v3(d); ver = 3
	if ver == 3:
		d = _migrate_v3_to_v4(d); ver = 4
	if ver == 4:
		d = _migrate_v4_to_v5(d); ver = 5

	d = _normalize_common(d)
	d["schema_version"] = LATEST_VERSION
	d["updated_at"] = now
	return d

static func normalize(d: Dictionary) -> Dictionary:
	return migrate(d)

# -------------------- migrations --------------------

static func _migrate_v1_to_v2(d_in: Dictionary) -> Dictionary:
	var d: Dictionary = _S.deep_copy_dict(d_in)
	var p: Dictionary = _S.to_dict(_S.dget(d, "player", {}))
	if not p.has("stat_block"):
		p["stat_block"] = {
			"level": int(_S.dget(p,"level",1)),
			"xp_current": 0,
			"xp_needed": 90,
			"attributes": _default_attributes_upper()
		}
	d["player"] = p
	d["highest_claimed_level"] = max(1, int(_S.dget(d, "highest_claimed_level", 1)))
	return d

static func _migrate_v2_to_v3(d_in: Dictionary) -> Dictionary:
	var d: Dictionary = _S.deep_copy_dict(d_in)
	var p: Dictionary = _S.to_dict(_S.dget(d, "player", {}))
	if not p.has("loadout"):
		p["loadout"] = {"equipment": _empty_equipment_slots(), "weapon_tags": []}
	if not p.has("known_actions"):
		p["known_actions"] = []
	if not p.has("inventory"):
		p["inventory"] = []
	d["player"] = p
	return d

static func _migrate_v3_to_v4(d_in: Dictionary) -> Dictionary:
	var d: Dictionary = _S.deep_copy_dict(d_in)
	var p: Dictionary = _S.to_dict(_S.dget(d, "player", {}))
	var sb: Dictionary = _S.to_dict(_S.dget(p, "stat_block", {}))
	if not sb.has("xp_current"):
		sb["xp_current"] = int(_S.dget(sb, "xp", 0))
	if not sb.has("xp_needed"):
		sb["xp_needed"] = 90
	var attrs: Dictionary = _S.to_dict(_S.dget(sb, "attributes", {}))
	var out_attrs: Dictionary = {}
	for k in ["STR","AGI","DEX","END","INT","WIS","CHA","LCK"]:
		out_attrs[k] = float(attrs.get(k, 8.0))
	sb["attributes"] = out_attrs
	p["stat_block"] = sb
	d["player"] = p
	return d

static func _migrate_v4_to_v5(d_in: Dictionary) -> Dictionary:
	var d: Dictionary = _S.deep_copy_dict(d_in)

	d.erase("floor_seeds")
	d.erase("last_floor")
	if not d.has("highest_teleport_floor"):
		d["highest_teleport_floor"] = max(1, int(_S.dget(d, "current_floor", 1)))
	if not d.has("stash_gold"): d["stash_gold"] = 0
	if not d.has("stash_shards"): d["stash_shards"] = 0
	if not d.has("stash_items"): d["stash_items"] = []
	if not d.has("permanent_blessings"): d["permanent_blessings"] = []
	if not d.has("queued_blessings_next_run"): d["queued_blessings_next_run"] = []

	var p: Dictionary = _S.to_dict(_S.dget(d, "player", {}))
	if not p.has("abilities_unlocked"):
		p["abilities_unlocked"] = {}
	else:
		var au_any: Variant = p["abilities_unlocked"]
		if au_any is Array:
			var map: Dictionary = {}
			for row_any in (au_any as Array):
				if row_any is Dictionary:
					var row: Dictionary = row_any
					var aid: String = String(_S.dget(row,"id",""))
					if aid.is_empty():
						continue
					map[aid] = {
						"level": max(1, int(_S.dget(row,"level",1))),
						"xp_current": int(_S.dget(row,"xp_current", 0)),
						"xp_needed": int(_S.dget(row,"xp_needed", 25))
					}
			p["abilities_unlocked"] = map
		elif not (au_any is Dictionary):
			p["abilities_unlocked"] = {}

	d["player"] = p
	return d

# -------------------- normalization --------------------

static func _normalize_common(d_in: Dictionary) -> Dictionary:
	var out: Dictionary = _S.deep_copy_dict(d_in)

	# Floors (clamp)
	out["current_floor"]  = max(1, int(_S.dget(out, "current_floor", 1)))
	out["previous_floor"] = max(0, int(_S.dget(out, "previous_floor", 0)))
	out["highest_teleport_floor"] = max(1, int(_S.dget(out, "highest_teleport_floor", 1)))

	# Player block
	var pl: Dictionary = _S.to_dict(_S.dget(out, "player", {}))
	var sb: Dictionary = _S.to_dict(_S.dget(pl, "stat_block", {}))
	if not sb.has("level"): sb["level"] = max(1, int(_S.dget(pl, "level", 1)))
	if not sb.has("xp_current"): sb["xp_current"] = 0
	if not sb.has("xp_needed"): sb["xp_needed"] = 90
	if not sb.has("attributes"): sb["attributes"] = _default_attributes_upper()
	pl["stat_block"] = sb

	pl["level"] = int(_S.dget(sb, "level", 1))
	pl["highest_claimed_level"] = max(1, int(_S.dget(pl, "highest_claimed_level", pl["level"])))

	# Abilities map normalize
	var au_in: Dictionary = _S.to_dict(_S.dget(pl, "abilities_unlocked", {}))
	var au_norm: Dictionary = {}
	for k in au_in.keys():
		var row: Dictionary = _S.to_dict(au_in[k])
		var lvl: int = max(1, int(_S.dget(row, "level", 1)))
		var xc: int = max(0, int(_S.dget(row, "xp_current", 0)))
		var xn: int = max(1, int(_S.dget(row, "xp_needed", 25)))
		au_norm[String(k)] = {"level": lvl, "xp_current": xc, "xp_needed": xn}
	pl["abilities_unlocked"] = au_norm

	# Inventory normalize (typed)
	var inv_any: Variant = _S.dget(pl, "inventory", [])
	var inv_in: Array = (inv_any as Array) if inv_any is Array else []
	var inv_out: Array = []
	var ilvl_guess: int = out["current_floor"]
	for it_any in inv_in:
		if it_any is Dictionary:
			inv_out.append(_normalize_item_dict(it_any as Dictionary, ilvl_guess))
	pl["inventory"] = inv_out

	# Loadout presence
	if not pl.has("loadout"):
		pl["loadout"] = {"equipment": _empty_equipment_slots(), "weapon_tags": []}
	else:
		var lo: Dictionary = _S.to_dict(pl["loadout"])
		if not lo.has("equipment"): lo["equipment"] = _empty_equipment_slots()
		if not lo.has("weapon_tags"): lo["weapon_tags"] = []
		pl["loadout"] = lo

	# Skills normalize (typed)
	var skills_any: Variant = _S.dget(pl, "skills", [])
	var skills_in: Array = (skills_any as Array) if skills_any is Array else []
	var skills_out: Array = []
	for s_any in skills_in:
		if s_any is Dictionary:
			var sd: Dictionary = s_any
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

	out["player"] = pl

	# Stash/buffs normalize
	out["stash_gold"] = max(0, int(_S.dget(out, "stash_gold", 0)))
	out["stash_shards"] = max(0, int(_S.dget(out, "stash_shards", 0)))
	if not out.has("stash_items"): out["stash_items"] = []
	if not out.has("permanent_blessings"): out["permanent_blessings"] = []
	if not out.has("queued_blessings_next_run"): out["queued_blessings_next_run"] = []

	return out

# -------------------- helpers --------------------

static func _default_attributes_upper() -> Dictionary:
	return {"STR": 8.0, "AGI": 8.0, "DEX": 8.0, "END": 8.0, "INT": 8.0, "WIS": 8.0, "CHA": 8.0, "LCK": 8.0}

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

	var out: Dictionary = {
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
	if dmax > 0:
		var uid_str: String = String(_S.dget(it_in, "uid", ""))
		if uid_str.is_empty():
			uid_str = _gen_uid()
		out["uid"] = uid_str
	return out

static func _gen_uid() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var a: int = _S.now_ts() & 0x7FFFFFFF
	var b: int = int(rng.randi() & 0x7FFFFFFF)
	return "u%08x%08x" % [a, b]
