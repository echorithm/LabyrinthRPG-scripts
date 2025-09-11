# File: res://scripts/combat/CtbQueue.gd
# Godot 4.4.1 — Typed CTB queue (FFX-style)

class_name CtbQueue
extends RefCounted

var current_time: int = 0
var actors: Array[CtbActor] = []

func add_actor(a: CtbActor) -> void:
	actors.append(a)

func pop_next() -> CtbActor:
	var idx := _index_of_next()
	var a: CtbActor = actors[idx]
	current_time = a.next_turn_at
	return a

func schedule(a: CtbActor, ctb_cost: int) -> void:
	var inc: int = int(ceil(float(ctb_cost) / float(max(1, a.speed))))
	a.next_turn_at = current_time + inc

func peek_next(count: int, exclude: CtbActor = null) -> Array[CtbActor]:
	# Returns the next N actors by order (optionally excluding 'exclude').
	var indices: Array[int] = []
	for i in range(actors.size()):
		if exclude != null and actors[i] == exclude:
			continue
		indices.append(i)
	indices.sort_custom(Callable(self, "_cmp_index"))  # Godot 4 signature
	var out: Array[CtbActor] = []
	for i in indices:
		out.append(actors[i])
		if out.size() >= count:
			break
	return out

func _index_of_next() -> int:
	var idx := 0
	var best := 0x7fffffff
	for i in range(actors.size()):
		var t := actors[i].next_turn_at
		if t < best:
			best = t
			idx = i
	return idx

func _cmp_index(a: int, b: int) -> bool:
	return actors[a].next_turn_at < actors[b].next_turn_at
