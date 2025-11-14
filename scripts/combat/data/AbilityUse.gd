extends RefCounted
class_name AbilityUse

var actor_id: int
var targets: Array[int]
var ability_id: String
var source_tags: PackedStringArray
var time_ctb_cost: float

static func make(actor_id_in: int, targets_in: Array[int], ability_id_in: String, tags_in: PackedStringArray, ctb_cost_in: float) -> AbilityUse:
	var a := AbilityUse.new()
	a.actor_id = actor_id_in
	a.targets = []
	for t in targets_in:
		a.targets.append(int(t))
	a.ability_id = ability_id_in
	a.source_tags = tags_in.duplicate()
	a.time_ctb_cost = float(ctb_cost_in)
	return a

func to_dict() -> Dictionary:
	return {
		"actor_id": actor_id,
		"targets": targets,
		"ability_id": ability_id,
		"source_tags": source_tags,
		"time_ctb_cost": time_ctb_cost
	}
