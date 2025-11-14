extends RefCounted
class_name AbilitySchema
## Minimal authoring contract for monster abilities (data-only), with safe normalization.

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
		# Common extras used by UI/kernel:
		"damage_type":   String(_S.dget(a, "damage_type", _S.dget(a, "element", "physical"))),
		"mp_cost":       int(_S.dget(a, "mp_cost", 0)),
		"stam_cost":     int(_S.dget(a, "stam_cost", 0)),
		"cooldown":      int(_S.dget(a, "cooldown", 0)),
		"charges":       int(_S.dget(a, "charges", 0)),
		"gesture":       _norm_gesture(_S.dget(a, "gesture", {})),
		"progression":   _norm_progression(_S.dget(a, "progression", {})),
	}
	return out

# -------- inference/guards --------
static func _infer_element(a: Dictionary) -> String:
	# Prefer explicit school/element; default to physical for weapon-like.
	var school: String = String(_S.dget(a, "school", ""))
	if school in ELEMENTS: 
		return school
	var intent: String = String(_S.dget(a, "intent_id", ""))
	return "physical" if intent != "" else "physical"

static func _infer_scaling(a: Dictionary) -> String:
	var wt: String = String(_S.dget(a, "weapon_type", ""))
	if wt == "mace":
		return "power"
	if wt == "spear" or wt == "sword" or wt == "bow":
		return "finesse"
	var elem: String = _infer_element(a)
	if elem == "light":
		return "divine"
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
	var out: Dictionary = {}
	for k in ["STR","AGI","DEX","END","INT","WIS","CHA","LCK"]:
		if v.has(k):
			out[k] = float(v[k])
	return out

static func _norm_gesture(g_any: Variant) -> Dictionary:
	var g: Dictionary = _S.to_dict(g_any)
	return { "symbol_id": String(_S.dget(g, "symbol_id", "")) }

static func _norm_progression(p_any: Variant) -> Dictionary:
	var p: Dictionary = _S.to_dict(p_any)
	var per: Dictionary = _S.to_dict(_S.dget(p, "per_level", {}))
	var rider: Dictionary = _S.to_dict(_S.dget(p, "rider", {}))
	# Clamp common fields; tolerate missing keys.
	var per_out: Dictionary = {}
	if per.has("power_pct"):
		per_out["power_pct"] = float(per["power_pct"])
	if per.has("heal_pct"):
		per_out["heal_pct"] = float(per["heal_pct"])
	var r_out: Dictionary = {}
	for k in rider.keys():
		r_out[k] = rider[k] # free-form rider keys; UI will read specific ones
	return { "per_level": per_out, "rider": r_out }
