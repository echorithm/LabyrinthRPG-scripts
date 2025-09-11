extends TouchScreenButton

@export var action_name: StringName = &"interact"
@export_range(0.0, 1.0, 0.01) var width_frac: float = 0.5
@export_range(0.0, 1.0, 0.01) var height_frac: float = 0.5
@export var keep_on_top: bool = true   # z-index for safety

@onready var _rect: RectangleShape2D = RectangleShape2D.new()

func _ready() -> void:
	print("interact")
	action = action_name
	shape = _rect
	shape_centered = true
	shape_visible = false     # invisible but still clickable
	if keep_on_top:
		z_index = 1000

	_update_area()
	get_viewport().size_changed.connect(_update_area)  # handle rotation / resize

func _update_area() -> void:
	var vs: Vector2 = get_viewport_rect().size
	var sz: Vector2 = Vector2(vs.x * width_frac, vs.y * height_frac)
	_rect.size = sz                     # Godot 4: RectangleShape2D uses `size`
	position = vs * 0.5                 # center the button

	# Optional: if you want touches to pass through to UI underneath, enable this:
	# passby_press = true
	
