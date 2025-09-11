extends RefCounted
class_name AbilitySchema
## Canonical ability entry usable in META (known abilities) and RUN (cooldowns).
## Shape:
## {
##   "id": String, "name": String,
##   "school": String,             # e.g., "Sword", "Pyromancy"
##   "rank": int,                  # learned rank/upgrade tier
##   "cost": { "mp":int, "hp":int, "stamina":int },
##   "cooldown": { "max":float, "current":float },
##   "potency": { String: float }, # scalar params, e.g., {"atk_scale":1.0,"mind_scale":0.3,"flat":5}
##   "tags": Array[String],        # e.g., ["Melee","Fire","AOE"]
##   "enabled": bool               # can be toggled by equipment or passives
## }

const _S := preload("res://persistence/util/save_utils.gd")

static func default_entry() -> Dictionary:
	return {
		"id": "",
		"name": "",
		"school": "",
		"rank": 1,
		"cost": { "mp": 0, "hp": 0, "stamina": 0 },
		"cooldown": { "max": 0.0, "current": 0.0 },
		"potency": { "atk_scale": 1.0, "mind_scale": 0.0, "flat": 0.0 },
		"tags": [],
		"enabled": true,
	}

static func normalize(a_any: Variant) -> Dictionary:
	var a: Dictionary = _S.to_dict(a_any)
	var def: Dictionary = default_entry()
	if not a.has("id"): a["id"] = def["id"]
	if not a.has("name"): a["name"] = def["name"]
	if not a.has("school"): a["school"] = def["school"]
	a["rank"] = max(1, int(_S.dget(a, "rank", 1)))

	# cost
	var c_any: Variant = _S.dget(a, "cost", def["cost"])
	var c: Dictionary = _S.to_dict(c_any)
	a["cost"] = { "mp": int(_S.dget(c, "mp", 0)), "hp": int(_S.dget(c, "hp", 0)), "stamina": int(_S.dget(c, "stamina", 0)) }

	# cooldown
	var cd_any: Variant = _S.dget(a, "cooldown", def["cooldown"])
	var cd: Dictionary = _S.to_dict(cd_any)
	a["cooldown"] = { "max": float(_S.dget(cd, "max", 0.0)), "current": max(0.0, float(_S.dget(cd, "current", 0.0))) }

	# potency & tags
	var p_any: Variant = _S.dget(a, "potency", def["potency"])
	var p: Dictionary = _S.to_dict(p_any)
	a["potency"] = {
		"atk_scale": float(_S.dget(p, "atk_scale", 1.0)),
		"mind_scale": float(_S.dget(p, "mind_scale", 0.0)),
		"flat": float(_S.dget(p, "flat", 0.0)),
	}

	var tags_any: Variant = _S.dget(a, "tags", [])
	var tags_out: Array[String] = []
	if tags_any is Array:
		for v in (tags_any as Array):
			tags_out.append(String(v))
	a["tags"] = tags_out
	a["enabled"] = bool(_S.dget(a, "enabled", true))
	return a

static func tick_cooldown(a_any: Variant, delta: float) -> Dictionary:
	var a: Dictionary = normalize(a_any)
	var cd: Dictionary = a["cooldown"]
	var cur: float = max(0.0, float(cd["current"]) - max(0.0, delta))
	cd["current"] = cur
	a["cooldown"] = cd
	return a

static func trigger_cooldown(a_any: Variant) -> Dictionary:
	var a: Dictionary = normalize(a_any)
	var cd: Dictionary = a["cooldown"]
	cd["current"] = float(cd["max"])
	a["cooldown"] = cd
	return a

static func is_ready(a_any: Variant) -> bool:
	var a: Dictionary = normalize(a_any)
	var cd: Dictionary = a["cooldown"]
	return float(cd["current"]) <= 0.0 && bool(_S.dget(a, "enabled", true))
