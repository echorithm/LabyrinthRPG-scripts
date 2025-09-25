extends RefCounted
class_name MonsterSchema

const _S := preload("res://persistence/util/save_utils.gd")
const StatsSchema := preload("res://persistence/schemas/stats_schema.gd")
const AbilitySchema := preload("res://persistence/schemas/ability_schema.gd")

static func normalize(m_any: Variant) -> Dictionary:
	var m: Dictionary = _S.to_dict(m_any)

	var out: Dictionary = {
		"id":              int(_S.dget(m, "id", 0)),
		"slug":            String(_S.dget(m, "slug", "")),
		"display_name":    String(_S.dget(m, "display_name", "")),
		"scene_path":      String(_S.dget(m, "scene_path", "")),
		"roles_allowed":   _S.to_string_array(_S.dget(m, "roles_allowed", ["regular","elite","boss"])),
		"boss_only":       bool(_S.dget(m, "boss_only", false)),
		"base_weight":     max(0, int(_S.dget(m, "base_weight", 1))),
		"level_baseline":  max(1, int(_S.dget(m, "level_baseline", 1))),
		# Base stats/resists/tags (derived stays empty)
		"stats":           StatsSchema.normalize(_S.dget(m, "stats", {})),
		# Abilities normalized one by one
		"abilities":       [],
		"xp_species_mod":  float(_S.dget(m, "xp_species_mod", 1.0)),
		"loot_source_id":  String(_S.dget(m, "loot_source_id", "LT_default")),
		"sigil_credit":    int(_S.dget(m, "sigil_credit", 0)),
		"collision_profile": String(_S.dget(m, "collision_profile", "CP_blocker")),
		"version":         String(_S.dget(m, "version", "1.1.0"))
	}

	# Normalize abilities list
	var ab_any: Variant = _S.dget(m, "abilities", [])
	var ab_in: Array = (ab_any as Array) if ab_any is Array else []
	var ab_out: Array = []
	for a_any in ab_in:
		if a_any is Dictionary:
			ab_out.append(AbilitySchema.normalize(a_any))
	out["abilities"] = ab_out

	return out
