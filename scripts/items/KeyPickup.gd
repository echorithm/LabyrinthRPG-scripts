# KeyPickup.gd
extends Node3D
class_name KeyPickup

@export var key_id: StringName = &"gold"
@export var player_group: StringName = &"player"

func _ready() -> void:
	var area := $Area3D
	if area:
		area.body_entered.connect(_on_enter)

func _on_enter(b: Node) -> void:
	if b.is_in_group(player_group):
		# Tell all exit doors to unlock, then remove the key
		get_tree().call_group("exit_door", "unlock")
		queue_free()
		
func set_key_id(id: StringName) -> void:
	key_id = id
