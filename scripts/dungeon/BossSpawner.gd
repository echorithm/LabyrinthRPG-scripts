extends Node
class_name BossSpawner

@export var boss_scene: PackedScene

func spawn_now() -> Node3D:
	if boss_scene == null:
		return null
	var anchor: Node3D = _find_boss_anchor()
	if anchor == null:
		push_warning("[BossSpawner] Anchor_Boss not found.")
		return null
	var inst: Node3D = boss_scene.instantiate() as Node3D
	if inst == null:
		return null
	inst.global_transform = anchor.global_transform
	anchor.add_sibling(inst)
	return inst

func _find_boss_anchor() -> Node3D:
	# Search under RuntimePrefabs for a node named "Anchor_Boss"
	var rt: Node = get_tree().get_root().find_child("RuntimePrefabs", true, false)
	if rt == null:
		rt = get_tree().get_root()
	var q: Array[Node] = [rt]
	while not q.is_empty():
		var n: Node = q.pop_back()
		if n.name == "Anchor_Boss":
			return n as Node3D
		for c in n.get_children():
			q.push_back(c)
	return null
