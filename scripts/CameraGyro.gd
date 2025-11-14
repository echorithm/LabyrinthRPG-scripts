extends Camera3D
class_name CameraGyro

@export var gyro_enabled: bool = true
@export var gyro_sensitivity: float = 1.2
@export var mouse_sensitivity: float = 0.005
@export var stick_sensitivity: float = 2.5
@export var key_sensitivity: float = 1.8

# Global invert (mouse / gyro / arrow keys)
@export var invert_pitch: bool = true
@export var invert_yaw: bool = false

# Stick-specific invert (right on-screen stick only)
@export var invert_pitch_stick: bool = false
@export var invert_yaw_stick: bool = false

@export var clamp_pitch_deg: float = 80.0
@export var enable_mouse_in_editor: bool = true     # RMB to capture
@export var look_stick: NodePath                     # path to right stick node

var yaw: float = 0.0
var pitch: float = 0.0

@onready var pivot: Node3D = $".."
@onready var _stick: VirtualStickLook = get_node_or_null(look_stick) as VirtualStickLook

func _ready() -> void:
	add_to_group("look_controller")
	if Engine.is_editor_hint() and enable_mouse_in_editor:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	# Fallback: find stick by group if NodePath isn't set
	if _stick == null:
		_stick = get_tree().get_first_node_in_group("look_stick") as VirtualStickLook
	if _stick == null:
		push_warning("CameraGyro: Look Stick not assigned or found (set 'look_stick' NodePath or add the node to group 'look_stick').")

func set_gyro_enabled(v: bool) -> void:
	gyro_enabled = v

func _unhandled_input(event: InputEvent) -> void:
	# Mouse look (editor/desktop). Right-click toggles capture.
	if Engine.is_editor_hint() and enable_mouse_in_editor:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			var mm := Input.get_mouse_mode()
			if mm == Input.MOUSE_MODE_CAPTURED:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			else:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		elif event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			var m := event as InputEventMouseMotion
			var yaw_dir: float = 1.0 if invert_yaw else -1.0
			var pitch_dir: float = 1.0 if invert_pitch else -1.0
			yaw += m.relative.x * mouse_sensitivity * yaw_dir
			pitch += m.relative.y * mouse_sensitivity * pitch_dir
			_apply_rot()

func _process(delta: float) -> void:
	# Resolve stick if it was null at _ready()
	if _stick == null and look_stick != NodePath(""):
		_stick = get_node_or_null(look_stick) as VirtualStickLook

	# ===== Right stick (independent invert) =====
	var used_stick: bool = false
	if _stick != null:
		var v := _stick.get_value()
		if v.length_squared() > 0.0025:
			# UI coords: right = +x, up = -y
			var stick_yaw :=  v.x * stick_sensitivity * delta
			var stick_pitch := -v.y * stick_sensitivity * delta
			if invert_yaw_stick:
				stick_yaw *= -1.0
			if invert_pitch_stick:
				stick_pitch *= -1.0
			yaw   += stick_yaw
			pitch += stick_pitch
			used_stick = true

	# ===== Arrow keys (use global invert) =====
	var yaw_dir_keys: float = 1.0 if invert_yaw else -1.0
	var pitch_dir_keys: float = 1.0 if invert_pitch else -1.0

	var kv := Vector2(
		Input.get_action_strength("look_right") - Input.get_action_strength("look_left"),
		Input.get_action_strength("look_down")  - Input.get_action_strength("look_up")
	)
	if kv.length_squared() > 0.0:
		yaw   += kv.x * key_sensitivity * delta * yaw_dir_keys
		pitch += kv.y * key_sensitivity * delta * pitch_dir_keys

	# ===== Gyro (use global invert; pause if stick used this frame) =====
	if gyro_enabled and not used_stick:
		var g := Input.get_gyroscope() # rad/s
		if g != Vector3.ZERO:
			var yaw_dir_gyro: float = 1.0 if invert_yaw else -1.0
			var pitch_dir_gyro: float = 1.0 if invert_pitch else -1.0
			yaw   += g.y * gyro_sensitivity * delta * yaw_dir_gyro
			pitch += g.x * gyro_sensitivity * delta * pitch_dir_gyro

	_apply_rot()

func _apply_rot() -> void:
	pitch = clamp(pitch, deg_to_rad(-clamp_pitch_deg), deg_to_rad(clamp_pitch_deg))
	pivot.rotation.y = yaw
	rotation.x = pitch

func reset_camera_orientation() -> void:
	yaw = 0.0
	pitch = 0.0
	pivot.rotation.y = 0.0
	rotation = Vector3.ZERO
