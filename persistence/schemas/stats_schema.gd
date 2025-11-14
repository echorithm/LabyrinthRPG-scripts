extends RefCounted
class_name StatsSchema
## Canonical stats block for actors (player/NPC/enemy).
## Stores ONLY bases + resist tags; all combat numbers are derived elsewhere.

const _S := preload("res://persistence/util/save_utils.gd")

# --- Allowed keys (authoring guards) ---
const BASE_ATTRS: PackedStringArray = [
	"STR","AGI","DEX","END","INT","WIS","CHA","LCK"
]

# Physical subtypes + magic elements
const RESIST_KEYS: PackedStringArray = [
	"pierce","slash","blunt","ranged", # physical buckets
	"light","dark","wind","fire","water","earth"
]

# Optional tags like ["Beast","Flyer","LightArmor"]
const ARMOR_TAGS: PackedStringArray = ["HeavyArmor","LightArmor","ClothArmor"]

static func default_block() -> Dictionary:
	var base: Dictionary = {}
	for k in BASE_ATTRS:
		base[k] = 5.0
	var resist: Dictionary = {}
	for r in RESIST_KEYS:
		resist[r] = 0.0
	return {
		"base": base,         # String->float (design-owned)
		"resist": resist,     # String->float (-0.90..+0.95 as percent modifiers)
		"derived": {},        # computed at runtime (leave empty in JSON)
		"caps": {             # optional caps for derived; keep conservative defaults
			"crit_chance_cap": 0.35,
			"crit_multi_cap": 2.5
		},
		"tags": []            # Array[String]
	}

static func normalize(d_any: Variant) -> Dictionary:
	var d: Dictionary = _S.to_dict(d_any)
	if not d.has("base"):    d["base"] = default_block()["base"].duplicate()
	if not d.has("resist"):  d["resist"] = default_block()["resist"].duplicate()
	if not d.has("derived"): d["derived"] = {}
	if not d.has("caps"):    d["caps"] = default_block()["caps"].duplicate()
	if not d.has("tags"):    d["tags"] = []

	d["base"]   = _coerce_and_clamp_bases(d["base"])
	d["resist"] = _clamp_resists(_coerce_floats(d["resist"]))
	d["caps"]   = _coerce_floats(d["caps"])
	d["tags"]   = _coerce_str_array(d["tags"])
	# Leave 'derived' empty; your combat layer fills it at runtime.
	d["derived"] = {}
	return d

# -------- helpers --------
static func _coerce_and_clamp_bases(src_any: Variant) -> Dictionary:
	var out: Dictionary = {}
	if src_any is Dictionary:
		for k in BASE_ATTRS:
			var v: float = float((src_any as Dictionary).get(k, 5.0))
			out[k] = clampf(v, 0.0, 99.0)
	else:
		for k in BASE_ATTRS: out[k] = 5.0
	return out

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
	for k in RESIST_KEYS:
		var v: float = float(res.get(k, 0.0))
		res[k] = clampf(v, -0.90, 0.95) # allow vulnerability down to -90%, resist up to +95%
	return res
