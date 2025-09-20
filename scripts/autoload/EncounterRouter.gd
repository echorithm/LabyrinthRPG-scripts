extends Node

signal encounter_requested(payload: Dictionary)
signal encounter_finished(result: Dictionary)

var _return_info: Dictionary = {}

func request_encounter(payload: Dictionary, player: Node3D = null) -> void:
	_return_info.clear()
	if player != null:
		_return_info["player_path"] = player.get_path()
		_return_info["player_transform"] = player.global_transform
	var p: Dictionary = payload.duplicate(true)
	emit_signal("encounter_requested", p)

func finish_encounter(result: Dictionary) -> void:
	var out: Dictionary = result.duplicate(true)
	out["return_info"] = _return_info.duplicate(true)
	emit_signal("encounter_finished", out)
	_return_info.clear()
