extends Resource
class_name RpsMatrix

@export var phys_map: Dictionary = {}   # StringName -> (StringName -> float)
@export var elem_map: Dictionary = {}

func physical_multiplier(phys_tags: Array[StringName], materials: Array[StringName]) -> float:
	var best: float = 1.0
	for p in phys_tags:
		var row: Dictionary = phys_map.get(p, {})
		for m in materials:
			best = max(best, float(row.get(m, 1.0)))
	return best

func elemental_multiplier(elem_tags: Array[StringName], tags: Array[StringName]) -> float:
	var best: float = 1.0
	for e in elem_tags:
		var row: Dictionary = elem_map.get(e, {})
		for t in tags:
			best = max(best, float(row.get(t, 1.0)))
	return best
