extends CanvasLayer

@export var font_size: int = 20
@export var show_seconds: float = 1.8

var _label: Label
var _timer: Timer

func _ready() -> void:
	_label = Label.new()
	add_child(_label)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.anchor_left = 0.5
	_label.anchor_right = 0.5
	_label.anchor_top = 0
	_label.anchor_bottom = 0
	_label.position = Vector2(0, 28)
	_label.add_theme_font_size_override("font_size", font_size)
	_label.modulate.a = 0.0

	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_hide)
	add_child(_timer)

func notify(t: String) -> void:
	_label.text = t
	_label.modulate.a = 1.0
	_timer.start(show_seconds)

func _hide() -> void:
	_label.modulate.a = 0.0
