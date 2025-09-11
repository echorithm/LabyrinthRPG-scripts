extends CharacterBody3D

@export var move_speed: float = 4.5
@export var gravity: float = 9.8
@export var debug_fly: bool = false    # optional: hold to use move_up/down as noclip

@export var virtual_stick: NodePath
@export var debug_text: NodePath
@export var move_stick_invert_x: bool = false
@export var move_stick_invert_y: bool = false

@onready var _stick: VirtualStickMove = get_node_or_null(virtual_stick) as VirtualStickMove
@onready var _debug_label: Label = get_node_or_null(debug_text) as Label
@onready var _pivot: Node3D = get_node_or_null("Pivot") as Node3D

func _ready() -> void:
	# Ensure floor detection uses Y-up no matter what got saved in the scene.
	up_direction = Vector3.UP

func _physics_process(delta: float) -> void:
	var v2: Vector2 = Vector2.ZERO

	# 1) Virtual stick
	if _stick != null:
		var sv: Vector2 = _stick.get_value()
		if sv.length_squared() > 0.0025:
			var sx: float = ( -sv.x ) if move_stick_invert_x else sv.x
			var sy: float = ( -sv.y ) if move_stick_invert_y else sv.y
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
		var cam: Camera3D = get_viewport().get_camera_3d()
		if cam != null:
			basis_pivot = cam.global_transform.basis
		else:
			basis_pivot = global_transform.basis

	var dir: Vector3 = (-basis_pivot.z * v2.y) + (basis_pivot.x * v2.x)

	# Horizontal
	velocity.x = dir.x * move_speed
	velocity.z = dir.z * move_speed

	# Vertical
	if debug_fly:
		# Optional noclip/fly: only when you enable it.
		var up_strength: float = Input.get_action_strength("move_up")
		var down_strength: float = Input.get_action_strength("move_down")
		velocity.y = (up_strength - down_strength) * move_speed
	else:
		if not is_on_floor():
			velocity.y -= gravity * delta
		else:
			# keep contact and clear downward residue
			if velocity.y < 0.0:
				velocity.y = 0.0

	if _debug_label != null:
		_debug_label.text = "vel=%s | floor=%s" % [str(velocity), str(is_on_floor())]

	move_and_slide()
