# res://ui/GyroToggle.gd
extends CheckButton
class_name GyroToggle

@onready var _cam := get_tree().get_first_node_in_group("look_controller")

func _ready() -> void:
	if _cam and "gyro_enabled" in _cam:
		button_pressed = _cam.gyro_enabled
	toggled.connect(_on_toggled)

func _on_toggled(toggled_on: bool) -> void:
	if _cam and "set_gyro_enabled" in _cam:
		_cam.set_gyro_enabled(toggled_on)
