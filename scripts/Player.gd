extends CharacterBody3D

@export var move_speed: float = 4.5
@export var gravity: float = 9.8
@export var debug_fly: bool = false

@export var virtual_stick: NodePath
@export var debug_text: NodePath
@export var move_stick_invert_x: bool = false
@export var move_stick_invert_y: bool = false

@onready var _stick: VirtualStickMove = get_node_or_null(virtual_stick) as VirtualStickMove
@onready var _debug_label: Label = get_node_or_null(debug_text) as Label
@onready var _pivot: Node3D = get_node_or_null("Pivot") as Node3D
@onready var _stepper: Node = get_node_or_null("StepStepper")
@onready var _player_cam: Camera3D = get_node_or_null("Pivot/Camera3D") as Camera3D

# --- lock state snapshots ---
var _pre_lock_process: bool = true
var _pre_lock_physics: bool = true
var _pre_lock_process_input: bool = true
var _pre_lock_stepper_process: bool = true
var _in_battle_lock: bool = false

func _ready() -> void:
	up_direction = Vector3.UP

func _physics_process(delta: float) -> void:
	if _in_battle_lock:
		# Held in place while locked. (Physics is off during lock, but this
		# early-out is useful if someone re-enables physics before exit.)
		velocity = Vector3.ZERO
		return

	var v2: Vector2 = Vector2.ZERO

	# 1) Virtual stick
	if _stick != null:
		var sv: Vector2 = _stick.get_value()
		if sv.length_squared() > 0.0025:
			var sx: float = (-sv.x) if move_stick_invert_x else sv.x
			var sy: float = (-sv.y) if move_stick_invert_y else sv.y
			v2 = Vector2(sx, -sy)

	# 2) Keyboard fallback
	if v2 == Vector2.ZERO:
		v2 = Vector2(
			Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left"),
			Input.get_action_strength("ui_up")    - Input.get_action_strength("ui_down")
		).limit_length(1.0)

	var basis_pivot: Basis
	if _pivot != null:
		basis_pivot = _pivot.basis
	else:
		var cam := get_viewport().get_camera_3d()
		basis_pivot = cam.global_transform.basis if cam != null else global_transform.basis

	var dir: Vector3 = (-basis_pivot.z * v2.y) + (basis_pivot.x * v2.x)

	# Horizontal
	velocity.x = dir.x * move_speed
	velocity.z = dir.z * move_speed

	# Vertical
	if debug_fly:
		var up_strength: float = Input.get_action_strength("move_up")
		var down_strength: float = Input.get_action_strength("move_down")
		velocity.y = (up_strength - down_strength) * move_speed
	else:
		if not is_on_floor():
			velocity.y -= gravity * delta
		elif velocity.y < 0.0:
			velocity.y = 0.0

	if _debug_label != null:
		_debug_label.text = "vel=%s | floor=%s" % [str(velocity), str(is_on_floor())]

	move_and_slide()

# -------- Battle lock API (called by BattleLoader) --------
func enter_battle_lock() -> void:
	if _in_battle_lock:
		return
	_in_battle_lock = true

	# snapshot
	_pre_lock_process         = is_processing()
	_pre_lock_physics         = is_physics_processing()
	_pre_lock_process_input   = is_processing_input()
	_pre_lock_stepper_process = (_stepper != null and _stepper.is_processing())

	# stop everything on the player
	set_process(false)
	set_physics_process(false)
	set_process_input(false)
	if _stepper != null:
		_stepper.set_process(false)

	# zero out motion immediately
	velocity = Vector3.ZERO

func exit_battle_lock() -> void:
	if not _in_battle_lock:
		return
	_in_battle_lock = false

	# restore previous states
	set_process(_pre_lock_process)
	set_physics_process(_pre_lock_physics)
	set_process_input(_pre_lock_process_input)
	if _stepper != null:
		_stepper.set_process(_pre_lock_stepper_process)
