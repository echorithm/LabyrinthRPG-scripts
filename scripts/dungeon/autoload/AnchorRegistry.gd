extends Node


# floor -> Array[Transform3D]
var _elite_by_floor: Dictionary = {}
var _treasure_by_floor: Dictionary = {}

func set_floor_anchors(floor: int, elites: Array[Transform3D], treasures: Array[Transform3D]) -> void:
	_elite_by_floor[floor] = elites
	_treasure_by_floor[floor] = treasures

func get_elite_anchors(floor: int) -> Array[Transform3D]:
	var v: Variant = _elite_by_floor.get(floor)
	return (v as Array[Transform3D]) if (v is Array) else []

func get_treasure_anchors(floor: int) -> Array[Transform3D]:
	var v: Variant = _treasure_by_floor.get(floor)
	return (v as Array[Transform3D]) if (v is Array) else []

func clear_floor(floor: int) -> void:
	_elite_by_floor.erase(floor)
	_treasure_by_floor.erase(floor)
