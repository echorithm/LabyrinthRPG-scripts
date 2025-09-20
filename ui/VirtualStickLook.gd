extends Control
class_name VirtualStickLook

# ---- Layout ----
enum Corner { BOTTOM_LEFT, BOTTOM_RIGHT }

@export var corner: int = Corner.BOTTOM_RIGHT
@export var margin: Vector2 = Vector2(64, 64)     # more padding by default
@export var use_viewport_space: bool = true       # position in viewport space (ignores parent)
@export var top_level_layout: bool = true         # use global_position
@export var z_layer: int = 1000
@export var add_to_look_group: bool = true

# Mobile tweaks
@export var mobile_radius_scale: float = 1.20     # ~20% larger on mobile
@export var mobile_extra_margin: Vector2 = Vector2(16, 16)

# ---- Behavior ----
@export var radius: float = 110.0                 # slightly larger default
@export var deadzone: float = 0.12
@export var show_debug_label: bool = true
@export var mouse_emulate_touch: bool = true

signal pressed(index: int)
signal released(index: int)
signal value_changed(value: Vector2)

var _active: bool = false
var _pointer_id: int = -1
var _center: Vector2 = Vector2.ZERO
var _value: Vector2 = Vector2.ZERO
var _knob_pos: Vector2 = Vector2.ZERO
var _label: Label

const MOUSE_ID := -2
const COL_BASE      := Color(0, 0, 0, 0.45)
const COL_RING_IDLE := Color(1, 1, 1, 0.35)
const COL_RING_ON   := Color(0.2, 0.8, 1.0, 0.9)
const COL_SHADOW    := Color(0, 0, 0, 0.35)
const COL_KNOB      := Color(1, 1, 1, 0.95)

func _ready() -> void:
	if top_level_layout and use_viewport_space:
		top_level = true
	z_index = z_layer

	_apply_mobile_tweaks()
	_ensure_size_from_radius()
	_center = size * 0.5

	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if show_debug_label:
		_label = Label.new()
		_label.modulate = Color(1, 1, 1, 0.9)
		add_child(_label)

	if add_to_look_group and not is_in_group("look_stick"):
		add_to_group("look_stick")

	_relayout()
	get_viewport().size_changed.connect(_relayout)

func _apply_mobile_tweaks() -> void:
	if OS.has_feature("mobile"):
		radius = maxf(8.0, radius * mobile_radius_scale)
		margin += mobile_extra_margin

func _ensure_size_from_radius() -> void:
	var need: Vector2 = Vector2(radius * 2.0 + 48.0, radius * 2.0 + 48.0)
	if size.x < need.x or size.y < need.y:
		size = need

func _relayout() -> void:
	var vp: Vector2 = get_viewport_rect().size
	var p: Vector2
	if corner == Corner.BOTTOM_RIGHT:
		p = Vector2(vp.x - size.x - margin.x, vp.y - size.y - margin.y)
	else:
		p = Vector2(margin.x, vp.y - size.y - margin.y)
	if use_viewport_space:
		global_position = p
	else:
		position = p
	_center = size * 0.5
	if _label:
		_label.position = Vector2(8, size.y + 4)

func get_value() -> Vector2:
	return _value

func _process(_d: float) -> void:
	if _label:
		_label.text = "look " + str(_value).substr(0, 14)

func _input(event: InputEvent) -> void:
	var rect: Rect2 = get_global_rect()

	if event is InputEventScreenTouch:
		var e := event as InputEventScreenTouch
		if e.pressed and _pointer_id == -1 and rect.has_point(e.position):
			_begin(e.index, e.position, rect); accept_event()
		elif (not e.pressed) and e.index == _pointer_id:
			_end(); accept_event()
	elif event is InputEventScreenDrag and _active and event.index == _pointer_id:
		_update_from_global(event.position, rect); accept_event()
	elif mouse_emulate_touch and Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			var mb := event as InputEventMouseButton
			if mb.pressed and _pointer_id == -1 and rect.has_point(mb.position):
				_begin(MOUSE_ID, mb.position, rect); accept_event()
			elif (not mb.pressed) and _pointer_id == MOUSE_ID:
				_end(); accept_event()
		elif event is InputEventMouseMotion and _active and _pointer_id == MOUSE_ID:
			var mm := event as InputEventMouseMotion
			_update_from_global(mm.position, rect); accept_event()

func _update_from_global(global_pos: Vector2, rect: Rect2) -> void:
	var local: Vector2 = global_pos - rect.position
	var raw: Vector2 = (local - _center)
	if raw.length() > radius:
		raw = raw.normalized() * radius
	_knob_pos = raw

	var v: Vector2 = raw / radius
	if v.length() >= deadzone:
		_value = v
	else:
		_value = Vector2.ZERO

	value_changed.emit(_value)
	queue_redraw()

func _draw() -> void:
	draw_circle(_center, radius, COL_BASE)
	var ring: Color = COL_RING_ON if _active else COL_RING_IDLE
	draw_arc(_center, radius + 4.0, 0.0, TAU, 48, ring, 6.0, true)
	draw_circle(_center + _knob_pos + Vector2(2, 2), 26.0, COL_SHADOW)
	draw_circle(_center + _knob_pos, 24.0, COL_KNOB)

func _begin(id: int, pos: Vector2, rect: Rect2) -> void:
	_active = true
	_pointer_id = id
	_update_from_global(pos, rect)
	pressed.emit(id)

func _end() -> void:
	_active = false
	var id: int = _pointer_id
	_pointer_id = -1
	_value = Vector2.ZERO
	_knob_pos = Vector2.ZERO
	queue_redraw()
	released.emit(id)
