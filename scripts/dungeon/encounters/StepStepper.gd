extends Node
class_name StepStepper

@export var encounter_autoload_path: NodePath = ^"/root/EncounterDirector"
@export var player_root: NodePath = NodePath()  # leave empty to use owner

# ---- Debug step logging
@export var debug_steps: bool = true                      # master toggle
@export var debug_steps_every: int = 1                    # print every N steps (1 = every step)
@export var debug_steps_log_world: bool = true           # include world xyz
@export var debug_steps_log_reason_skips: bool = true    # if director exposes suppression logs, prefer those

var _enc: Node = null
var _player: Node3D = null
var _last_cell: Vector2i = Vector2i(-9999, -9999)
var _cell_size: float = 4.0
var _step_count: int = 0

func _ready() -> void:
	_enc = get_node_or_null(encounter_autoload_path)
	_player = (get_node(player_root) as Node3D) if player_root != NodePath() else (owner as Node3D)
	if _enc == null or _player == null:
		push_warning("[StepStepper] Missing EncounterDirector or player.")
		set_process(false)
		return
	if _enc.has_method("register_player"):
		_enc.call("register_player", _player)

	# Cache cell size so we can reason about steps
	if _enc.has_method("cell_size"):
		_cell_size = float(_enc.call("cell_size"))
	reset_after_floor_change()

func _process(_dt: float) -> void:
	if _enc == null or _player == null:
		return
	if not _enc.has_method("world_to_cell") or not _enc.has_method("on_step"):
		return

	var world: Vector3 = _player.global_transform.origin
	var cell: Vector2i = _enc.call("world_to_cell", world)

	if cell != _last_cell:
		_last_cell = cell
		_step_count += 1

		# Debug print for steps
#		if debug_steps and (debug_steps_every > 0) and ((_step_count % debug_steps_every) == 0):
#			if debug_steps_log_world:
#				print("[Step] #", _step_count, " cell=", cell, " world=(",
#					snapped(world.x, 0.01), ", ", snapped(world.y, 0.01), ", ", snapped(world.z, 0.01), ")")
#			else:
#				print("[Step] #", _step_count, " cell=", cell)

		_enc.call("on_step", cell, world)

func reset_after_floor_change() -> void:
	_last_cell = Vector2i(1<<28, 1<<28)  # force next _process to emit a step immediately
	_step_count = 0
	if debug_steps:
		print("[Step] reset_after_floor_change (cell_size=", _cell_size, ")")
