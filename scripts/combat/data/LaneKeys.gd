# res://scripts/combat/data/LaneKeys.gd
extends RefCounted
class_name LaneKeys

# Canonical 10 lanes: 4 physical + 6 magical
const PHYS_4: PackedStringArray = [
	"pierce", "slash", "blunt", "ranged"
]
const MAG_6: PackedStringArray = [
	"light", "dark", "earth", "water", "fire", "wind"
]
const LANES_10: PackedStringArray = PHYS_4 + MAG_6

static func is_physical(k: StringName) -> bool:
	var s: String = String(k)
	for p in PHYS_4:
		if s == p:
			return true
	return false

static func is_magical(k: StringName) -> bool:
	var s: String = String(k)
	for e in MAG_6:
		if s == e:
			return true
	return false

# Accept any dictionary of lane weights and return a strict 10-key map that sums to 1.0.
# Unknown keys are ignored. If all inputs are 0/empty → default to pierce=1.0
static func normalize_lanes_pct(src_any: Variant) -> Dictionary[String, float]:
	var out: Dictionary[String, float] = {} as Dictionary[String, float]
	for k in LANES_10:
		out[String(k)] = 0.0

	if typeof(src_any) == TYPE_DICTIONARY:
		var src: Dictionary = src_any as Dictionary
		var sum: float = 0.0
		for k_any in src.keys():
			var ks: String = String(k_any)
			if out.has(ks):
				# Pull as Variant -> cast to float safely, then clamp >= 0
				var vv: float = float(src.get(k_any, 0.0))
				var v: float = (vv if vv > 0.0 else 0.0)
				out[ks] = v
				sum += v

		if sum > 0.0:
			for k2 in LANES_10:
				var key2: String = String(k2)
				out[key2] = out[key2] / sum
			return out

	# Fallback when empty/zero
	print("normalize_lanes_pct - fallback")
	out["pierce"] = 1.0
	return out
