extends RefCounted
class_name AbilitySchema
## Minimal authoring contract for monster abilities (data-only).

const _S := preload("res://persistence/util/save_utils.gd")

# Enums-as-strings for data safety
const ELEMENTS: PackedStringArray = ["light","dark","wind","fire","water","earth","physical"]
const SCALINGS: PackedStringArray = ["power","finesse","arcane","divine","support"]
const WEAPON_TYPES: PackedStringArray = ["spear","sword","mace","bow"]

static func normalize(a_any: Variant) -> Dictionary:
	var a: Dictionary = _S.to_dict(a_any)
	var out: Dictionary = {
		"id":            String(_S.dget(a, "ability_id", "")),
		"display_name":  String(_S.dget(a, "display_name", "")),
		"element":       _norm_element(String(_S.dget(a, "element", _infer_element(a)))),
		"scaling":       _norm_scaling(String(_S.dget(a, "scaling", _infer_scaling(a)))),
		"to_hit":        bool(_S.dget(a, "to_hit", true)),
		"crit_allowed":  bool(_S.dget(a, "crit_allowed", true)),
		"base_power":    int(_S.dget(a, "base_power", 16)),
		"ctb_cost":      int(_S.dget(a, "ctb_cost", 100)),
		"intent_id":     String(_S.dget(a, "intent_id", "")),
		"animation_key": String(_S.dget(a, "animation_key", "")),
		"weapon_type":   _norm_weapon(String(_S.dget(a, "weapon_type", ""))),
		"weight":        clampf(float(_S.dget(a, "weight", 1.0)), 0.0, 10.0),
		"skill_level_baseline": max(1, int(_S.dget(a, "skill_level_baseline", 1))),
		"stat_bias":     _norm_bias(_S.dget(a, "stat_bias", {})),
		"tags":          _S.to_string_array(_S.dget(a, "tags", [])),
	}
	return out

# -------- inference/guards --------
static func _infer_element(a: Dictionary) -> String:
	# Default: physical for weapon-like; otherwise keep existing 'school' if present (wind/fire/etc.)
	var school: String = String(_S.dget(a, "school", ""))
	if school in ELEMENTS: return school
	var intent: String = String(_S.dget(a, "intent_id", ""))
	return "physical" if intent.begins_with("IT_") else "physical"

static func _infer_scaling(a: Dictionary) -> String:
	var wt: String = String(_S.dget(a, "weapon_type", ""))
	if wt == "mace": return "power"
	if wt == "spear" or wt == "sword" or wt == "bow": return "finesse"
	var elem: String = _infer_element(a)
	if elem == "light": return "divine"
	if elem == "dark" or elem == "wind" or elem == "fire" or elem == "water" or elem == "earth":
		return "arcane"
	return "support"

static func _norm_element(e: String) -> String:
	return e if e in ELEMENTS else "physical"

static func _norm_scaling(s: String) -> String:
	return s if s in SCALINGS else "finesse"

static func _norm_weapon(w: String) -> String:
	return w if w in WEAPON_TYPES else ""

static func _norm_bias(v_any: Variant) -> Dictionary:
	var v: Dictionary = _S.to_dict(v_any)
	# Keep only your 8 base keys, coerce to floats (weights)
	var out: Dictionary = {}
	for k in ["STR","AGI","DEX","END","INT","WIS","CHA","LCK"]:
		if v.has(k):
			out[k] = float(v[k])
	return out
