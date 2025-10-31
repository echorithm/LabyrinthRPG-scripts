# File: res://scripts/data/Loadout.gd
# ID-based loadout; gestures map to action IDs.
class_name Loadout
extends Resource

@export var action_ids: Array[StringName] = []                         # e.g., ["slash","block","fireball","heal"]
@export var fallback_id: StringName = &"fizzle"
@export var gesture_to_action: Dictionary[StringName, StringName] = {  # gesture id -> action id
	&"arc_slash": &"arc_slash",
	&"block": &"block",
	&"fireball": &"fireball",
	&"heal": &"heal"
}

func action_id_for_gesture(gesture_id: StringName) -> StringName:
	return gesture_to_action.get(gesture_id, fallback_id)
