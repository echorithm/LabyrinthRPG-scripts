extends Node

signal encounter_requested(payload: Dictionary)
signal encounter_finished(result: Dictionary)

var _return_info: Dictionary = {}
var _next_encounter_id: int = 1

func request_encounter(payload: Dictionary, player: Node3D = null) -> void:
	_return_info.clear()

	# Assign an encounter_id if caller didn't provide one.
	var enc_id: int = int(payload.get("encounter_id", 0))
	if enc_id <= 0:
		enc_id = _next_encounter_id
		_next_encounter_id += 1

	# Persist routing info so finish_encounter can echo it back.
	_return_info["encounter_id"] = enc_id
	if player != null:
		_return_info["player_path"] = player.get_path()
		_return_info["player_transform"] = player.global_transform

	# If the requester includes its path, persist it (lets spawners filter finishes).
	if payload.has("requester_path"):
		_return_info["requester_path"] = String(payload["requester_path"])

	var p: Dictionary = payload.duplicate(true)
	p["encounter_id"] = enc_id
	emit_signal("encounter_requested", p)

func finish_encounter(result: Dictionary) -> void:
	var out: Dictionary = result.duplicate(true)
	# Echo back whatever we stored from request time.
	for k in _return_info.keys():
		out[k] = _return_info[k]
	emit_signal("encounter_finished", out)
	_return_info.clear()
