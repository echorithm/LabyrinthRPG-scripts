# res://scenes/interact.gd
extends TouchScreenButton

@export var action_name: StringName = &"interact"
@export_range(0.0, 1.0, 0.01) var width_frac: float = 0.35
@export_range(0.0, 1.0, 0.01) var height_frac: float = 0.25
@export var keep_on_top: bool = true

@onready var _rect: RectangleShape2D = RectangleShape2D.new()

func _ready() -> void:
	
	action = action_name
	shape = _rect
	shape_centered = true
	shape_visible = false
	if keep_on_top:
		z_index = 1000

	# KEY CHANGE: don’t consume the event; allow sticks to also see the touch.
	passby_press = true

	_update_area()
	get_viewport().size_changed.connect(_update_area)

func _update_area() -> void:
	var vs: Vector2 = get_viewport_rect().size
	var sz: Vector2 = Vector2(vs.x * width_frac, vs.y * height_frac)
	_rect.size = sz
	position = vs * 0.5
