extends RefCounted
class_name StatsSchema
## Canonical stats block for actors (player/NPC/enemy).
## Shape:
## {
##   "base":        { String: float },     # primary stats (design-owned)
##   "resist":     { String: float },      # % resistances 0..1 per damage type
##   "derived":    { String: float },      # computed numbers (hp_max, mp_max, etc.)
##   "caps":       { String: float },      # max clamps for derived, optional
##   "tags":       Array[String],          # e.g., ["Humanoid","Undead"]
## }
##
## You can tune the formulas in _derive_defaults().

const _S := preload("res://persistence/util/save_utils.gd")

static func default_block() -> Dictionary:
	return {
		"base": {
			"power": 5.0,
			"tech": 5.0,
			"mind": 5.0,
			"vitality": 5.0,
			"agility": 5.0,
			"luck": 5.0,
		},
		"resist": {
			"physical": 0.0,
			"fire": 0.0,
			"ice": 0.0,
			"lightning": 0.0,
			"poison": 0.0,
			"arcane": 0.0,
		},
		"derived": {},
		"caps": {
			"hp_max": 9999.0,
			"mp_max": 9999.0,
			"stamina_max": 9999.0,
			"crit_chance": 0.95,
			"crit_multi": 5.0,
		},
		"tags": [],
	}

static func normalize(d_any: Variant) -> Dictionary:
	var d: Dictionary = _S.to_dict(d_any)
	if not d.has("base"):    d["base"] = default_block()["base"].duplicate()
	if not d.has("resist"):  d["resist"] = default_block()["resist"].duplicate()
	if not d.has("derived"): d["derived"] = {}
	if not d.has("caps"):    d["caps"] = default_block()["caps"].duplicate()
	if not d.has("tags"):    d["tags"] = []
	# Coerce types
	d["base"]   = _coerce_floats(d["base"])
	d["resist"] = _clamp_resists(_coerce_floats(d["resist"]))
	d["caps"]   = _coerce_floats(d["caps"])
	d["tags"]   = _coerce_str_array(d["tags"])
	# Recompute derived with safe clamps
	d["derived"] = _derive_defaults(d["base"], d["caps"])
	return d

static func _coerce_floats(src_any: Variant) -> Dictionary:
	var out: Dictionary = {}
	if src_any is Dictionary:
		for k in (src_any as Dictionary).keys():
			out[String(k)] = float((src_any as Dictionary)[k])
	return out

static func _coerce_str_array(src_any: Variant) -> Array[String]:
	var out: Array[String] = []
	if src_any is Array:
		for v in (src_any as Array):
			out.append(String(v))
	return out

static func _clamp_resists(res: Dictionary) -> Dictionary:
	for k in res.keys():
		var v: float = clampf(float(res[k]), -0.9, 0.95) # allow some vuln, cap strong res
		res[k] = v
	return res

# --- Default derivation formulas (change freely) ---
static func _derive_defaults(base: Dictionary, caps: Dictionary) -> Dictionary:
	var powv: float = float(_S.dget(base, "power", 5.0))
	var tech: float = float(_S.dget(base, "tech", 5.0))
	var mind: float = float(_S.dget(base, "mind", 5.0))
	var vit:  float = float(_S.dget(base, "vitality", 5.0))
	var agi:  float = float(_S.dget(base, "agility", 5.0))
	var luck: float = float(_S.dget(base, "luck", 5.0))

	var hp_max: float = min(float(_S.dget(caps, "hp_max", 9999.0)), 50.0 + vit * 15.0)
	var mp_max: float = min(float(_S.dget(caps, "mp_max", 9999.0)), 20.0 + mind * 10.0 + tech * 4.0)
	var stamina_max: float = min(float(_S.dget(caps, "stamina_max", 9999.0)), 50.0 + agi * 8.0 + vit * 4.0)

	var attack: float = powv * 2.5 + tech * 0.5
	var spell_power: float = mind * 2.5 + tech * 0.5
	var defense: float = vit * 1.8 + tech * 0.7
	var speed: float = 1.0 + agi * 0.08
	var evade: float = clampf(0.02 + agi * 0.003 + luck * 0.001, 0.0, 0.50)
	var crit_chance: float = clampf(0.03 + luck * 0.004, 0.0, float(_S.dget(caps, "crit_chance", 0.95)))
	var crit_multi: float = clampf(1.5 + luck * 0.03, 1.0, float(_S.dget(caps, "crit_multi", 5.0)))

	return {
		"hp_max": hp_max,
		"mp_max": mp_max,
		"stamina_max": stamina_max,
		"attack": attack,
		"spell_power": spell_power,
		"defense": defense,
		"speed": speed,
		"evade": evade,
		"crit_chance": crit_chance,
		"crit_multi": crit_multi,
	}
