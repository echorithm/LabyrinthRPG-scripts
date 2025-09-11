extends RefCounted
class_name RunSchema

const LATEST_VERSION: int = 2

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

		# Player snapshot (ephemeral)
		"hp_max": 30, "hp": 30,
		"mp_max": 10, "mp": 10,
		"gold": 0,

		# Simple run items (string IDs)
		"items": [],

		# Sigil "pity" session state (per segment)
		"sigils_segment_id": 1,
		"sigils_elites_killed_in_segment": 0,
		"sigils_required_elites": 4,
		"sigils_charged": false,

		# v2: per-action use-to-level (kept in RUN by default)
		# { action_id: { level:int>=1, xp:int>=0 } }
		"action_skills": {}
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

	# Normalize common fields
	d = _normalize_common(d)
	d["schema_version"] = LATEST_VERSION
	d["updated_at"] = now
	return d

static func normalize(d: Dictionary, meta_schema: int) -> Dictionary:
	# Alias if you prefer the name 'normalize'
	return migrate(d, meta_schema)

# -------------------------------------------------
# Internal: migrations
# -------------------------------------------------
static func _migrate_v1_to_v2(d_in: Dictionary) -> Dictionary:
	var d: Dictionary = _S.deep_copy_dict(d_in)
	# Add action_skills if missing
	if not d.has("action_skills"):
		d["action_skills"] = {}
	return d

# -------------------------------------------------
# Internal: normalization (idempotent)
# -------------------------------------------------
static func _normalize_common(d_in: Dictionary) -> Dictionary:
	var out: Dictionary = _S.deep_copy_dict(d_in)

	# Core fields
	out["run_seed"] = int(_S.dget(out, "run_seed", 0))
	out["depth"] = max(1, int(_S.dget(out, "depth", 1)))

	# Player snapshot
	out["hp_max"] = int(_S.dget(out, "hp_max", 30))
	out["hp"] = int(_S.dget(out, "hp", out["hp_max"]))
	out["mp_max"] = int(_S.dget(out, "mp_max", 10))
	out["mp"] = int(_S.dget(out, "mp", out["mp_max"]))
	out["gold"] = int(_S.dget(out, "gold", 0))

	# Clamp hp/mp to max/min
	out["hp"] = clampi(out["hp"], 0, out["hp_max"])
	out["mp"] = clampi(out["mp"], 0, out["mp_max"])

	# Items as Array[String]
	var items_arr: Array[String] = _S.to_string_array(_S.dget(out, "items", []))
	out["items"] = items_arr

	# Sigils session state
	out["sigils_segment_id"] = max(1, int(_S.dget(out, "sigils_segment_id", 1)))
	out["sigils_elites_killed_in_segment"] = max(0, int(_S.dget(out, "sigils_elites_killed_in_segment", 0)))
	out["sigils_required_elites"] = max(1, int(_S.dget(out, "sigils_required_elites", 4)))
	# Re-evaluate charged flag consistently
	var charged: bool = bool(_S.dget(out, "sigils_charged", false))
	if out["sigils_elites_killed_in_segment"] >= out["sigils_required_elites"]:
		charged = true
	out["sigils_charged"] = charged

	# v2: action_skills dictionary normalize
	var as_any: Variant = _S.dget(out, "action_skills", {})
	var as_in: Dictionary = _S.to_dict(as_any)
	var as_out: Dictionary = {}
	for k in as_in.keys():
		var v_any: Variant = as_in[k]
		var v: Dictionary = _S.to_dict(v_any)
		var lvl: int = max(1, int(_S.dget(v, "level", 1)))
		var xp: int = max(0, int(_S.dget(v, "xp", 0)))
		as_out[String(k)] = { "level": lvl, "xp": xp }
	out["action_skills"] = as_out

	return out
