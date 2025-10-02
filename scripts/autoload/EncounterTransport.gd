extends Node

@export var encounter_scene: PackedScene = preload("res://scenes/combat/BattleScene.tscn")

var _instance: Node = null

func _ready() -> void:
	EncounterRouter.encounter_requested.connect(_on_encounter_requested)
	EncounterRouter.encounter_finished.connect(_on_encounter_finished)

func _on_encounter_requested(payload: Dictionary) -> void:
	if is_instance_valid(_instance):
		_instance.queue_free()
		_instance = null

	_instance = encounter_scene.instantiate()
	_instance.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.add_child(_instance)
	get_tree().paused = true

	if _instance.has_method("begin"):
		_instance.call("begin", payload)

func _on_encounter_finished(_result: Dictionary) -> void:
	if is_instance_valid(_instance):
		_instance.queue_free()
	_instance = null
	get_tree().paused = false
