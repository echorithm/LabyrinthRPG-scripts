extends Node
class_name StepStepper

const TimeService := preload("res://persistence/services/time_service.gd")

@export var encounter_autoload_path: NodePath = ^"/root/EncounterDirector"
@export var player_root: NodePath = NodePath()  # leave empty to use owner

# ---- Debug step logging
@export var debug_steps: bool = false                    # master toggle
@export var debug_steps_every: int = 1                    # print every N steps (1 = every step)
@export var debug_steps_log_world: bool = true            # include world xyz
@export var debug_steps_log_reason_skips: bool = true     # reserved for director suppression logs

# ---- Out-of-combat stamina regen
@export var stam_regen_enabled: bool = true               # master toggle for OOC regen
@export var stam_regen_per_cell: int = 3                  # grant per new cell entered
@export var stam_regen_every_n_steps: int = 1             # e.g., 3 -> grant every 3rd step
@export var stam_regen_blocked_in_battle: bool = true     # skip while EncounterDirector says we're in battle
@export var stam_regen_max_per_tick: int = 24              # safety cap per single grant (handles teleport/large moves)
@export var runstate_path: NodePath = ^"/root/RunState"
var _rs: Node = null

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
	var cell_v: Variant = _enc.call("world_to_cell", world)
	var cell: Vector2i = cell_v if cell_v is Vector2i else Vector2i.ZERO

	if cell != _last_cell:
		_last_cell = cell
		_step_count += 1

		# Notify director
		_enc.call("on_step", cell, world)

		# Try out-of-combat stamina regen on step
		_try_stam_regen_on_step()

		# NEW: accrue dungeon time (minutes) deterministically per step
		var in_battle: bool = _is_in_battle()
		TimeService.on_step(in_battle)

func reset_after_floor_change() -> void:
	_last_cell = Vector2i(1<<28, 1<<28)  # force next _process to emit a step immediately
	_step_count = 0
	if debug_steps:
		print("[Step] reset_after_floor_change (cell_size=", _cell_size, ")")

# --- OOC Stamina Regen -----------------------------------------------

func _try_stam_regen_on_step() -> void:
	if not stam_regen_enabled:
		return

	# Respect combat state if the director exposes it
	if stam_regen_blocked_in_battle and _is_in_battle():
		return

	# Step gating (every N steps)
	if stam_regen_every_n_steps <= 0:
		return
	if (_step_count % stam_regen_every_n_steps) != 0:
		return

	# Determine how much to grant this tick
	var grant: int = max(0, stam_regen_per_cell)
	grant = min(grant, stam_regen_max_per_tick)
	if grant <= 0:
		return

	_grant_stam(grant)

func _is_in_battle() -> bool:
	if _enc != null and _enc.has_method("is_in_battle"):
		return bool(_enc.call("is_in_battle"))
	# If director doesn't expose the method, assume not in battle so OOC regen works.
	return false

func _grant_stam(amount: int) -> void:
	if amount <= 0:
		return

	# Script autoload singleton; available as a global variable.
	var rs: Node = RunState  # RunState.gd extends Node
	var have: int = int(rs.stam)
	var cap : int = int(rs.stam_max)
	if have >= cap:
		return

	var new_val: int = clampi(have + amount, 0, cap)

	# Prefer the slot RunState advertises
	var slot_i: int = int(rs.get_slot()) if rs.has_method("get_slot") else SaveManager.DEFAULT_SLOT

	# set_stam(new_value, autosave, slot)
	rs.set_stam(new_val, true, slot_i)

	# Optional debug:
	# print("[StepStepper] +%d SP -> %d/%d" % [amount, new_val, cap])

func _resolve_runstate() -> Node:
	if _rs == null:
		_rs = get_node_or_null(runstate_path)
	return _rs
