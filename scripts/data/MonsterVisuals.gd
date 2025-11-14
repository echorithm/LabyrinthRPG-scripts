extends Node

@export var entries: Array[MonsterVisualEntry] = []

var _by_id: Dictionary = {}  # StringName -> MonsterVisualEntry

func _ready() -> void:
	_by_id.clear()
	for e: MonsterVisualEntry in entries:
		if e != null and e.id != StringName(""):
			_by_id[e.id] = e

# NOTE: don't name this `get` (would shadow Object.get)
func get_entry(id: StringName) -> MonsterVisualEntry:
	var v: Variant = _by_id.get(id)
	return (v as MonsterVisualEntry) if v is MonsterVisualEntry else null

func instantiate_into(parent: Node3D, id: StringName) -> Node3D:
	var e: MonsterVisualEntry = get_entry(id)
	if e == null or e.scene == null:
		return null
	var inst: Node3D = e.scene.instantiate() as Node3D
	if inst == null:
		return null
	parent.add_child(inst)
	if e.scale != Vector3.ONE:
		inst.scale = e.scale
	if abs(e.y_offset_m) > 0.0001:
		var t: Transform3D = inst.transform
		t.origin.y += e.y_offset_m
		inst.transform = t
	return inst

func enemy_id_for_visual(id: StringName) -> StringName:
	var e: MonsterVisualEntry = get_entry(id)
	if e != null and e.alias_enemy_id != StringName(""):
		return e.alias_enemy_id
	return id
