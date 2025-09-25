extends RefCounted
class_name RunSchema

const LATEST_VERSION: int = 4

const _S := preload("res://persistence/util/save_utils.gd")

# -------------------------------------------------
# Public API
# -------------------------------------------------
static func defaults(meta_schema: int) -> Dictionary:
	var now: int = _S.now_ts()
	return {
		"schema_version": LATEST_VERSION,
		"linked_meta_schema": int(meta_schema),
		"created_at": now,
		"updated_at": now,

		# Core run
		"run_seed": 0,
		"depth": 1,
		"furthest_depth_reached": 1,

		# Player snapshot (ephemeral) — derived at run start
		"hp_max": 30, "hp": 30,
		"mp_max": 10, "mp": 10,
		"stam_max": 50, "stam": 50,

		# Run-scoped currencies (lost on death; banked on safe exit)
		"gold": 0,
		"shards": 0,

		# Simple run items (legacy string IDs)
		"items": [],

		# Session buffs/effects
		"buffs": [],   # Array[String]
		"effects": [], # Array[Dictionary]: {id:String, turns_remaining:int>=0, stacks:int>=1?, magnitude:float?, tags:Array[String]?}

		# Sigil "pity" session state (per segment)
		"sigils_segment_id": 1,
		"sigils_elites_killed_in_segment": 0,
		"sigils_required_elites": 4,
		"sigils_charged": false,

		# v2: per-action use-to-level deltas (run-scoped; committed to META on exit)
		# { action_id: { xp_delta:int>=0 } }
		"action_xp_delta": {},

		# v3: Inventory snapshot + equipment for Option B
		"inventory": [],       # snapshot of META inventory at run start, mutated during run
		"equipment": {         # same shape as MetaSchema._empty_equipment_slots(), values are uids or null
			"head": null, "chest": null, "legs": null, "boots": null,
			"mainhand": null, "offhand": null, "ring1": null, "ring2": null, "amulet": null
		},
		"weapon_tags": [],

		# v4: runtime ability maps
		"abilities_runtime": {},       # { id: { cd_remaining:int>=0, charges:int>=0, tags:[String], mag:float } }
		"ability_use_counts": {}       # { id: int>=0 } for diminishing returns per run
	}

static func migrate(d_in: Dictionary, meta_schema: int) -> Dictionary:
	var d: Dictionary = _S.deep_copy_dict(d_in)
	var now: int = _S.now_ts()
	var ver: int = int(_S.dget(d, "schema_version", 0))
	if ver <= 0:
		ver = 1
		d["schema_version"] = 1
	if not d.has("created_at"):
		d["created_at"] = now

	# Keep the cross-link updated
	d["linked_meta_schema"] = int(meta_schema)

	# Chain migrations
	if ver == 1:
		d = _migrate_v1_to_v2(d)
		ver = 2
	if ver == 2:
		d = _migrate_v2_to_v3(d)
		ver = 3
	if ver == 3:
		d = _migrate_v3_to_v4(d)
		ver = 4

	# Normalize common fields
	d = _normalize_common(d)
	d["schema_version"] = LATEST_VERSION
	d["updated_at"] = now
	return d

static func normalize(d: Dictionary, meta_schema: int) -> Dictionary:
	return migrate(d, meta_schema)

# -------------------------------------------------
# Internal: migrations
# -------------------------------------------------
static func _migrate_v1_to_v2(d_in: Dictionary) -> Dictionary:
	var d: Dictionary = _S.deep_copy_dict(d_in)
	# Replace action_skills with action_xp_delta (delta cache only)
	if d.has("action_skills") and not d.has("action_xp_delta"):
		d["action_xp_delta"] = {}
	return d

static func _migrate_v2_to_v3(d_in: Dictionary) -> Dictionary:
	var d: Dictionary = _S.deep_copy_dict(d_in)
	# Add inventory snapshot + equipment + stamina/buffs/effects if missing
	if not d.has("inventory"):
		d["inventory"] = []
	if not d.has("equipment"):
		d["equipment"] = {
			"head": null, "chest": null, "legs": null, "boots": null,
			"mainhand": null, "offhand": null, "ring1": null, "ring2": null, "amulet": null
		}
	if not d.has("weapon_tags"):
		d["weapon_tags"] = []
	if not d.has("stam_max"):
		d["stam_max"] = 50
	if not d.has("stam"):
		d["stam"] = d["stam_max"]
	if not d.has("buffs"):
		d["buffs"] = []
	if not d.has("effects"):
		d["effects"] = []
	return d

static func _migrate_v3_to_v4(d_in: Dictionary) -> Dictionary:
	var d: Dictionary = _S.deep_copy_dict(d_in)
	# Add run-scoped shards and ability runtime maps
	if not d.has("shards"):
		d["shards"] = 0
	if not d.has("abilities_runtime"):
		d["abilities_runtime"] = {}
	if not d.has("ability_use_counts"):
		d["ability_use_counts"] = {}
	# Ensure furthest_depth_reached exists for drained-floor logic
	if not d.has("furthest_depth_reached"):
		var depth: int = int(_S.dget(d, "depth", 1))
		d["furthest_depth_reached"] = max(1, depth)
	return d

# -------------------------------------------------
# Internal: normalization (idempotent)
# -------------------------------------------------
static func _normalize_common(d_in: Dictionary) -> Dictionary:
	var out: Dictionary = _S.deep_copy_dict(d_in)

	# Core fields
	out["run_seed"] = int(_S.dget(out, "run_seed", 0))
	out["depth"] = max(1, int(_S.dget(out, "depth", 1)))
	out["furthest_depth_reached"] = max(1, int(_S.dget(out, "furthest_depth_reached", out["depth"])))

	# Player snapshot
	out["hp_max"] = int(_S.dget(out, "hp_max", 30))
	out["hp"] = int(_S.dget(out, "hp", out["hp_max"]))
	out["mp_max"] = int(_S.dget(out, "mp_max", 10))
	out["mp"] = int(_S.dget(out, "mp", out["mp_max"]))
	out["stam_max"] = int(_S.dget(out, "stam_max", 50))
	out["stam"] = int(_S.dget(out, "stam", out["stam_max"]))

	# Clamp pools
	out["hp"] = clampi(out["hp"], 0, out["hp_max"])
	out["mp"] = clampi(out["mp"], 0, out["mp_max"])
	out["stam"] = clampi(out["stam"], 0, out["stam_max"])

	# Currencies
	out["gold"] = max(0, int(_S.dget(out, "gold", 0)))
	out["shards"] = max(0, int(_S.dget(out, "shards", 0)))

	# Items as Array[String]
	var items_arr: Array[String] = _S.to_string_array(_S.dget(out, "items", []))
	out["items"] = items_arr

	# Buffs/effects
	out["buffs"] = _S.to_string_array(_S.dget(out, "buffs", []))
	var effects_any: Variant = _S.dget(out, "effects", [])
	var effects_in: Array = (effects_any as Array) if effects_any is Array else []
	var effects_out: Array = []
	for e_any: Variant in effects_in:
		if not (e_any is Dictionary):
			continue
		var e: Dictionary = e_any as Dictionary
		var eid: String = String(_S.dget(e, "id", ""))
		if eid.is_empty():
			continue
		var turns: int = max(0, int(_S.dget(e, "turns_remaining", 0)))
		var stacks: int = max(1, int(_S.dget(e, "stacks", 1)))
		var mag: float = float(_S.dget(e, "magnitude", 0.0))
		var tags: Array[String] = _S.to_string_array(_S.dget(e, "tags", []))
		effects_out.append({
			"id": eid, "turns_remaining": turns, "stacks": stacks,
			"magnitude": mag, "tags": tags
		})
	out["effects"] = effects_out

	# Sigils session state
	out["sigils_segment_id"] = max(1, int(_S.dget(out, "sigils_segment_id", 1)))
	out["sigils_elites_killed_in_segment"] = max(0, int(_S.dget(out, "sigils_elites_killed_in_segment", 0)))
	out["sigils_required_elites"] = max(1, int(_S.dget(out, "sigils_required_elites", 4)))
	var charged: bool = bool(_S.dget(out, "sigils_charged", false))
	if out["sigils_elites_killed_in_segment"] >= out["sigils_required_elites"]:
		charged = true
	out["sigils_charged"] = charged

	# v2+ action_xp_delta
	var axd_any: Variant = _S.dget(out, "action_xp_delta", {})
	var axd_in: Dictionary = _S.to_dict(axd_any)
	var axd_out: Dictionary = {}
	for k in axd_in.keys():
		var v_any: Variant = axd_in[k]
		var v: Dictionary = _S.to_dict(v_any)
		var xp: int = max(0, int(_S.dget(v, "xp_delta", int(v.get("xp", 0)))))
		axd_out[String(k)] = {"xp_delta": xp}
	out["action_xp_delta"] = axd_out

	# v3 inventory snapshot/equipment
	var inv_any: Variant = _S.dget(out, "inventory", [])
	var inv_in: Array = (inv_any as Array) if inv_any is Array else []
	var inv_out: Array = []
	for it_any: Variant in inv_in:
		if it_any is Dictionary:
			var it: Dictionary = it_any as Dictionary
			var id_str: String = String(_S.dget(it, "id", ""))
			var count: int = max(1, int(_S.dget(it, "count", 1)))
			var aff: Array[String] = _S.to_string_array(_S.dget(it, "affixes", []))
			var ilvl: int = int(_S.dget(it, "ilvl", 1))
			var arche: String = String(_S.dget(it, "archetype", "Light"))
			var rarity: String = String(_S.dget(it, "rarity", "Common"))
			var dmax: int = int(_S.dget(it, "durability_max", 0))
			var dcur: int = int(_S.dget(it, "durability_current", dmax))
			var w: float = float(_S.dget(it, "weight", 1.0))
			var out_it: Dictionary = {
				"id": id_str, "count": count, "ilvl": ilvl,
				"archetype": arche, "rarity": rarity,
				"affixes": aff, "durability_max": dmax, "durability_current": dcur, "weight": w
			}
			if dmax > 0:
				out_it["uid"] = String(_S.dget(it, "uid", ""))
			inv_out.append(out_it)
	out["inventory"] = inv_out

	var eq_any: Variant = _S.dget(out, "equipment", {})
	var eq: Dictionary = _S.to_dict(eq_any)
	var eq_norm: Dictionary = {
		"head": null, "chest": null, "legs": null, "boots": null,
		"mainhand": null, "offhand": null,
		"ring1": null, "ring2": null, "amulet": null
	}
	for k in eq_norm.keys():
		var v: Variant = eq.get(k, null)
		eq_norm[k] = (String(v) if v != null else null)
	out["equipment"] = eq_norm

	out["weapon_tags"] = _S.to_string_array(_S.dget(out, "weapon_tags", []))

	# v4: abilities runtime + per-run use counts
	var ar_any: Variant = _S.dget(out, "abilities_runtime", {})
	var ar_map: Dictionary = _S.to_dict(ar_any)
	var ar_norm: Dictionary = {}
	for k in ar_map.keys():
		var row: Dictionary = _S.to_dict(ar_map[k])
		ar_norm[String(k)] = {
			"cd_remaining": max(0, int(_S.dget(row, "cd_remaining", 0))),
			"charges": max(0, int(_S.dget(row, "charges", 0))),
			"tags": _S.to_string_array(_S.dget(row, "tags", [])),
			"mag": float(_S.dget(row, "mag", 0.0))
		}
	out["abilities_runtime"] = ar_norm

	var auc_any: Variant = _S.dget(out, "ability_use_counts", {})
	var auc_in: Dictionary = _S.to_dict(auc_any)
	var auc_norm: Dictionary = {}
	for k2 in auc_in.keys():
		auc_norm[String(k2)] = max(0, int(auc_in[k2]))
	out["ability_use_counts"] = auc_norm

	return out
