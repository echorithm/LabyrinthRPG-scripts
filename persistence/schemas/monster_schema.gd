extends RefCounted
class_name MonsterSchema

const _S := preload("res://persistence/util/save_utils.gd")
const StatsSchema := preload("res://persistence/schemas/stats_schema.gd")
const AbilitySchema := preload("res://persistence/schemas/ability_schema.gd")

const _LANE_KEYS: PackedStringArray = [
	"pierce","slash","ranged","blunt","dark","light","fire","water","earth","wind"
]

static func normalize(m_any: Variant) -> Dictionary:
	var m: Dictionary = _S.to_dict(m_any)

	var out: Dictionary = {
		"id":                int(_S.dget(m, "id", 0)),
		"slug":              String(_S.dget(m, "slug", "")),
		"display_name":      String(_S.dget(m, "display_name", "")),
		"scene_path":        String(_S.dget(m, "scene_path", "")),
		"roles_allowed":     _S.to_string_array(_S.dget(m, "roles_allowed", ["regular","elite","boss"])),
		"boss_only":         bool(_S.dget(m, "boss_only", false)),
		"base_weight":       max(0, int(_S.dget(m, "base_weight", 1))),
		"level_baseline":    max(1, int(_S.dget(m, "level_baseline", 0))),

		# Base stats/resists/tags (derived stays empty)
		"stats":             StatsSchema.normalize(_S.dget(m, "stats", {})),

		# New in catalog: caps (+ carry schema/version strings through)
		"caps":              _norm_caps(_S.dget(m, "caps", {})),
		"schema_version":    String(_S.dget(m, "schema_version", "")),
		"version":           String(_S.dget(m, "version", "1.1.0")),

		# Abilities normalized one by one (with lanes/ai pass-through)
		"abilities":         [],

		# Existing gameplay fields
		"xp_species_mod":    float(_S.dget(m, "xp_species_mod", 1.0)),
		"loot_source_id":    String(_S.dget(m, "loot_source_id", "LT_default")),
		"sigil_credit":      int(_S.dget(m, "sigil_credit", 0)),
		"collision_profile": String(_S.dget(m, "collision_profile", "CP_blocker")),
	}

	# Normalize abilities list
	var ab_any: Variant = _S.dget(m, "abilities", [])
	var ab_in: Array = (ab_any as Array) if ab_any is Array else []
	var ab_out: Array = []
	for a_any in ab_in:
		if a_any is Dictionary:
			var a_dict: Dictionary = a_any as Dictionary
			# Start from the global ability normalization (IDs, costs, scaling, progression, etc.)
			var base: Dictionary = AbilitySchema.normalize(a_dict)
			# Overlay monster-specific authoring extras (lanes/ai), made total and typed
			base["lanes"] = _norm_lanes(_S.dget(a_dict, "lanes", {}))
			base["ai"] = _norm_ai(_S.dget(a_dict, "ai", {}))
			ab_out.append(base)
	out["abilities"] = ab_out

	return out

# --- helpers --------------------------------------------------------

static func _norm_caps(c_any: Variant) -> Dictionary:
	var c: Dictionary = _S.to_dict(c_any)
	return {
		"crit_chance_cap": float(_S.dget(c, "crit_chance_cap", 0.35)),
		"crit_multi_cap":  float(_S.dget(c, "crit_multi_cap", 2.5)),
	}

static func _norm_lanes(l_any: Variant) -> Dictionary:
	var l: Dictionary = _S.to_dict(l_any)
	var out: Dictionary = {}
	for k in _LANE_KEYS:
		out[k] = float(_S.dget(l, k, 0.0))
	return out

static func _norm_ai(ai_any: Variant) -> Dictionary:
	var ai: Dictionary = _S.to_dict(ai_any)
	return {
		"targeting": String(_S.dget(ai, "targeting", "")),
		"range":     String(_S.dget(ai, "range", "")),
	}
