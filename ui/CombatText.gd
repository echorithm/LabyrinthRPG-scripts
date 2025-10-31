# res://ui/CombatText.gd
extends Control
class_name CombatText

@export var rise_px: float = 40.0
@export var lifetime: float = 0.8

# Visual tuning
@export var base_font_size: int = 22
@export var big_font_size: int = 38
@export var outline_size: int = 6
@export var outline_color: Color = Color(0, 0, 0, 0.85)

var _t: float = 0.0
var _start_pos: Vector2 = Vector2.ZERO

@onready var _lbl: Label = _ensure_label()

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_INHERIT
	set_process(true)
	hide()

func show_at(pos: Vector2, text: String, color: Color) -> void:
	# Normal popup (e.g., +SP, small notifications)
	_apply_style(_lbl, base_font_size, color)
	_start(pos, text)

func show_at_big(pos: Vector2, text: String, color: Color) -> void:
	# Emphasized popup (e.g., damage)
	_apply_style(_lbl, big_font_size, color)
	_start(pos, text)

func _start(pos: Vector2, text: String) -> void:
	_start_pos = pos
	position = pos
	_lbl.text = text
	_t = 0.0
	show()

func _process(delta: float) -> void:
	_t += delta
	var a: float = clampf(_t / lifetime, 0.0, 1.0)
	# Smooth rise
	position = _start_pos + Vector2(0, -rise_px * a)
	# Fade out
	var c: Color = _lbl.modulate
	c.a = 1.0 - a
	_lbl.modulate = c
	if a >= 1.0:
		queue_free()

func _ensure_label() -> Label:
	var lbl := get_node_or_null("Label") as Label
	if lbl == null:
		lbl = Label.new()
		lbl.name = "Label"
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		add_child(lbl)
	return lbl

func _apply_style(lbl: Label, size: int, color: Color) -> void:
	lbl.add_theme_font_size_override("font_size", size)
	lbl.add_theme_color_override("font_color", color)
	# Outline for visibility
	lbl.add_theme_color_override("font_outline_color", outline_color)
	lbl.add_theme_constant_override("outline_size", outline_size)
	# Reset alpha in case a previous run left it faded
	var c: Color = color
	c.a = 1.0
	lbl.modulate = c
