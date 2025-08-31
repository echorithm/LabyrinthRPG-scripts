# res://scripts/Player.gd
extends CharacterBody3D

const VirtualStick = preload("res://ui/VirtualStick.gd")

@export var move_speed: float = 4.5
@export var gravity: float = 9.8

@export var virtual_stick: NodePath
@export var debug_text: NodePath

# NEW: per-axis inversion just for the movement stick (mobile)
@export var move_stick_invert_x: bool = false
@export var move_stick_invert_y: bool = false

@onready var _stick: VirtualStick = get_node_or_null(virtual_stick) as VirtualStick
@onready var _debug_label: Label = get_node_or_null(debug_text) as Label

func _physics_process(delta: float) -> void:
	var v2: Vector2 = Vector2.ZERO

	# 1) On-screen movement stick
	if _stick != null:
		var sv: Vector2 = _stick.get_value() # +x right, +y down
		if sv.length_squared() > 0.0025:
			var sx := ( -sv.x if move_stick_invert_x else sv.x )
			var sy := ( -sv.y if move_stick_invert_y else sv.y )
			v2 = Vector2(sx, -sy)  # invert GUI Y so up on stick = forward

	# 2) Keyboard fallback
	if v2 == Vector2.ZERO:
		v2 = Vector2(
			Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left"),
			Input.get_action_strength("ui_down")  - Input.get_action_strength("ui_up")
		)
		if v2.length_squared() > 1.0:
			v2 = v2.normalized()

	# Move relative to camera pivot
	var dir: Vector3 = (-$Pivot.basis.z * v2.y) + ($Pivot.basis.x * v2.x)  # NOTE: + on basis.x (strafe)
	velocity.x = dir.x * move_speed
	velocity.z = dir.z * move_speed

	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	if _debug_label:
		_debug_label.text = "v2=%s  stick=%s  vel=%s" % [
			str(v2).substr(0,14),
			str(_stick and _stick.get_value()).substr(0,14),
			str(Vector2(velocity.x, velocity.z)).substr(0,14)
		]

	move_and_slide()
