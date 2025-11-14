extends Control
class_name VirtualStickLook

# ---- Layout ----
enum Corner { BOTTOM_LEFT, BOTTOM_RIGHT }
enum TriggerSide { LEFT, RIGHT, ANY }

@export var corner: int = Corner.BOTTOM_RIGHT
@export var margin: Vector2 = Vector2(64, 64)
@export var use_viewport_space: bool = true
@export var top_level_layout: bool = true
@export var z_layer: int = 1000
@export var add_to_look_group: bool = true

# Mobile tweaks
@export var mobile_radius_scale: float = 1.20
@export var mobile_extra_margin: Vector2 = Vector2(16, 16)

# ---- Behavior ----
@export var radius: float = 110.0
@export var deadzone: float = 0.12
@export var show_debug_label: bool = true

# New behavior
@export var appear_on_touch: bool = true                 # hidden until touched
@export var trigger_side: int = TriggerSide.RIGHT        # where a touch can spawn it
@export var only_touchscreen: bool = true                # ignore mouse completely

# UI respect
@export var respect_ui: bool = true
@export var ui_block_group: StringName = &"ui_block_touch"

signal pressed(index: int)
signal released(index: int)
signal value_changed(value: Vector2)

var _active: bool = false
var _pointer_id: int = -1
var _center: Vector2 = Vector2.ZERO
var _value: Vector2 = Vector2.ZERO
var _knob_pos: Vector2 = Vector2.ZERO
var _label: Label = null

const MOUSE_ID: int = -2
const COL_BASE: Color      = Color(0, 0, 0, 0.45)
const COL_RING_IDLE: Color = Color(1, 1, 1, 0.35)
const COL_RING_ON: Color   = Color(0.2, 0.8, 1.0, 0.9)
const COL_SHADOW: Color    = Color(0, 0, 0, 0.35)
const COL_KNOB: Color      = Color(1, 1, 1, 0.95)

func _ready() -> void:
	if top_level_layout and use_viewport_space:
		top_level = true
	z_index = z_layer

	_apply_mobile_tweaks()
	_ensure_size_from_radius()

	mouse_filter = Control.MOUSE_FILTER_IGNORE

	if show_debug_label:
		_label = Label.new()
		_label.modulate = Color(1, 1, 1, 0.9)
		add_child(_label)

	if add_to_look_group and not is_in_group("look_stick"):
		add_to_group("look_stick")

	_relayout()
	get_viewport().size_changed.connect(_relayout)

	if appear_on_touch:
		visible = false

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
	if appear_on_touch:
		# Fullscreen trigger; actual stick center moves to touch point.
		if use_viewport_space:
			top_level = true
			global_position = Vector2.ZERO
		else:
			position = Vector2.ZERO
		size = vp
		_center = size * 0.5
		if _label:
			_label.position = Vector2(8, size.y - 24)
		return

	# Legacy fixed-corner layout
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
	# Fullscreen rect when appear_on_touch; otherwise the control's rect.
	var rect: Rect2
	if appear_on_touch:
		rect = Rect2(Vector2.ZERO, get_viewport_rect().size)
	else:
		rect = get_global_rect()

	if event is InputEventScreenTouch:
		var e := event as InputEventScreenTouch
		if e.pressed and _pointer_id == -1 and _trigger_allows(e.position, rect) and (not respect_ui or not _ui_blocks(e.position)):
			if appear_on_touch:
				visible = true
				_center = e.position - rect.position
				_knob_pos = Vector2.ZERO
			_begin(e.index, e.position, rect); accept_event()
		elif (not e.pressed) and e.index == _pointer_id:
			_end(); accept_event()

	elif event is InputEventScreenDrag and _active and event.index == _pointer_id:
		_update_from_global(event.position, rect); accept_event()

	elif not only_touchscreen:
		if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			var mb := event as InputEventMouseButton
			if mb.pressed and _pointer_id == -1 and _trigger_allows(mb.position, rect) and (not respect_ui or not _ui_blocks(mb.position)):
				if appear_on_touch:
					visible = true
					_center = mb.position - rect.position
					_knob_pos = Vector2.ZERO
				_begin(MOUSE_ID, mb.position, rect); accept_event()
			elif (not mb.pressed) and _pointer_id == MOUSE_ID:
				_end(); accept_event()
		elif event is InputEventMouseMotion and _active and _pointer_id == MOUSE_ID:
			var mm := event as InputEventMouseMotion
			_update_from_global(mm.position, rect); accept_event()

func _trigger_allows(p: Vector2, rect: Rect2) -> bool:
	var vp: Vector2 = rect.size
	match trigger_side:
		TriggerSide.LEFT:
			return (p.x - rect.position.x) <= vp.x * 0.5
		TriggerSide.RIGHT:
			return (p.x - rect.position.x) >= vp.x * 0.5
		_:
			return true

func _ui_blocks(global_pos: Vector2) -> bool:
	var vp: Viewport = get_viewport()
	if vp == null:
		return false

	# Ensure the hovered control reflects this touch position on mobile.
	# (Hover isn't updated automatically for ScreenTouch events.)
	if only_touchscreen and OS.has_feature("mobile"):
		vp.warp_mouse(global_pos)

	var hit: Control = vp.gui_get_hovered_control()
	while hit:
		if hit == self:
			hit = hit.get_parent() as Control
			continue
		if hit.is_in_group(ui_block_group):
			return true
		if hit is Control and (hit as Control).mouse_filter != Control.MOUSE_FILTER_IGNORE:
			return true
		hit = hit.get_parent() as Control
	return false

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
	if not visible:
		return
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
	visible = not appear_on_touch
	released.emit(id)

func on_hud_locked(locked: bool) -> void:
	# Called by BattleLoader to hide during battle and keep state sane.
	_active = false
	_pointer_id = -1
	_value = Vector2.ZERO
	_knob_pos = Vector2.ZERO
	if locked:
		visible = false
	else:
		# After battle, keep hidden if appear_on_touch; user will reveal by touching.
		visible = not appear_on_touch
	queue_redraw()
