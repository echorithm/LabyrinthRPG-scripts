# File: res://persistence/schemas/cost_curves_schema.gd
# Godot 4.5 — Validates cost_curves.json (placement-only)

class_name CostCurvesSchema

# Expected:
# {
#   "camp":   {"gold": {...}, "shards": {...}},
#   "rts":    {"gold": {...}, "shards": {...}},
#   "service":{"gold": {...}, "shards": {...}}
# }
# Each sub-dict can be arbitrary numeric params; we just ensure ints where needed.

func validate(input: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key in ["camp", "rts", "service"]:
		var fam_v: Variant = input.get(key, {})
		var fam: Dictionary = {}
		if typeof(fam_v) == TYPE_DICTIONARY:
			fam = fam_v
		out[key] = _intify_nested(fam)
	return out

static func _intify_nested(d: Dictionary) -> Dictionary:
	var clean: Dictionary = {}
	for k in d.keys():
		var v: Variant = d.get(k)
		if typeof(v) == TYPE_DICTIONARY:
			clean[String(k)] = _intify_nested(v as Dictionary)
		elif typeof(v) == TYPE_INT:
			clean[String(k)] = int(v)
		elif typeof(v) == TYPE_FLOAT:
			clean[String(k)] = int(floor(float(v)))
		else:
			clean[String(k)] = v
	return clean
