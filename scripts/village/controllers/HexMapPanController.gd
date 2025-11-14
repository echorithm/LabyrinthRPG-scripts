# res://scripts/village/controllers/HexMapPanController.gd
extends Control
class_name HexMapPanController

signal pan_started
signal pan_moved(delta: Vector2)
signal pan_ended

@export var grid_path: NodePath
@export var buttons_path: NodePath

# ---- Pan config
@export var drag_threshold_px: float = 8.0
@export var enable_mouse: bool = true
@export var enable_touch: bool = true

# ---- Zoom config
@export var enable_zoom: bool = true
@export var min_zoom: float = 0.5
@export var max_zoom: float = 2.0
@export var wheel_step: float = 0.1
@export var trackpad_step_scale: float = 1.0
@export var zoom_to_cursor: bool = true

# ---- Modal gating (Option A)
@export var block_when_modal_open: bool = true
@export var tile_modal_service_path: NodePath

# ---- Debug
@export var debug_logging: bool = true
@export var log_each_move: bool = false

var _grid_node: Node2D
var _buttons_node: Node2D

# Optional: cached TileModalService (any Node exposing is_modal_open())
var _modal: Node = null

# Pan state
var _pointer_id: int = -9999
var _pointer_active: bool = false
var _press_pos: Vector2 = Vector2.ZERO
var _last_pos: Vector2 = Vector2.ZERO
var _dragging: bool = false

# Zoom state
var _zoom: float = 1.0
var _touch_points: Dictionary = {}
var _pinching: bool = false
var _pinch_initial_distance: float = 0.0
var _pinch_initial_zoom: float = 1.0

func _ready() -> void:
	_grid_node = get_node_or_null(grid_path) as Node2D
	_buttons_node = get_node_or_null(buttons_path) as Node2D
	mouse_filter = Control.MOUSE_FILTER_PASS

	# Try resolve TileModalService (optional)
	if tile_modal_service_path != NodePath():
		var n := get_node_or_null(tile_modal_service_path)
		if n != null:
			_modal = n
	if _modal == null:
		var g: Array = get_tree().get_nodes_in_group("village_modal_service")
		if g.size() > 0:
			_modal = g[0]

func _input(event: InputEvent) -> void:
	# If a modal is open, stop any ongoing gesture and swallow inputs.
	if _is_modal_open():
		_cancel_interaction()
		return  # don't accept_event; let modal Controls receive input

	# --- Mouse pan/zoom
	if enable_mouse:
		if event is InputEventMouseButton:
			var e := event as InputEventMouseButton
			if e.button_index == MOUSE_BUTTON_LEFT:
				if e.pressed:
					_begin_pointer(-1, e.position)
				else:
					_end_pointer(-1, e.position)
			elif enable_zoom and (e.button_index == MOUSE_BUTTON_WHEEL_UP or e.button_index == MOUSE_BUTTON_WHEEL_DOWN):
				var dir: float = 1.0
				if e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
					dir = -1.0
				_zoom_wheel(dir, e.position)
		elif event is InputEventMouseMotion:
			var m := event as InputEventMouseMotion
			if _pointer_active and _pointer_id == -1 and not _pinching:
				_update_pointer(m.position)

	# --- Trackpad pinch
	if enable_zoom and event is InputEventMagnifyGesture:
		var g := event as InputEventMagnifyGesture
		var factor: float = 1.0 + ((g.factor - 1.0) * trackpad_step_scale)
		_zoom_at(factor, get_viewport().get_mouse_position())

	# --- Touch pan/pinch
	if enable_touch:
		if event is InputEventScreenTouch:
			var t := event as InputEventScreenTouch
			if t.pressed:
				_touch_points[t.index] = t.position
				if _touch_points.size() == 1 and not _pointer_active:
					_begin_pointer(t.index, t.position)
				elif enable_zoom and _touch_points.size() == 2:
					_start_pinch()
			else:
				_touch_points.erase(t.index)
				if _pinching:
					if _touch_points.size() < 2:
						_end_pinch()
				else:
					if _pointer_active and t.index == _pointer_id:
						_end_pointer(t.index, t.position)
		elif event is InputEventScreenDrag:
			var d := event as InputEventScreenDrag
			_touch_points[d.index] = d.position
			if _pinching and enable_zoom:
				_update_pinch()
			elif _pointer_active and d.index == _pointer_id:
				_update_pointer(d.position)

# --- Pan helpers --------------------------------------------------------------

func _begin_pointer(id: int, pos: Vector2) -> void:
	_pointer_id = id
	_pointer_active = true
	_press_pos = pos
	_last_pos = pos
	_dragging = false
	#_dbg("press", {"id": id, "pos": pos})

func _update_pointer(pos: Vector2) -> void:
	if not _pointer_active:
		return
	var total_delta: Vector2 = pos - _press_pos
	if not _dragging and total_delta.length() >= drag_threshold_px:
		_dragging = true
		pan_started.emit()
		accept_event()
		#_dbg("pan_started", {"from": _press_pos, "at": pos})
	if _dragging:
		var frame_delta: Vector2 = pos - _last_pos
		_pan_layers(frame_delta)
		pan_moved.emit(frame_delta)
		_last_pos = pos
		accept_event()
		#if log_each_move:
			#_dbg("pan_move", {"delta": frame_delta})

func _end_pointer(id: int, pos: Vector2) -> void:
	if not _pointer_active or id != _pointer_id:
		return
	if _dragging:
		pan_ended.emit()
		accept_event()
		#_dbg("pan_ended", {"pos": pos})
	_pointer_active = false
	_pointer_id = -9999
	_dragging = false

func _pan_layers(delta: Vector2) -> void:
	if _grid_node != null:
		_grid_node.position += delta
	if _buttons_node != null:
		_buttons_node.position += delta

# --- Zoom helpers -------------------------------------------------------------

func _zoom_wheel(direction: float, at_screen: Vector2) -> void:
	var step: float = 1.0 + (wheel_step * direction)
	_zoom_at(step, at_screen)

func _start_pinch() -> void:
	_pinching = true
	_pinch_initial_zoom = _zoom
	var pts: Array[Vector2] = _first_two_touch_points()
	_pinch_initial_distance = pts[0].distance_to(pts[1])
	accept_event()
	#_dbg("pinch_started", {"distance": _pinch_initial_distance})

func _update_pinch() -> void:
	if not _pinching:
		return
	var pts: Array[Vector2] = _first_two_touch_points()
	var dist: float = pts[0].distance_to(pts[1])
	if _pinch_initial_distance <= 0.0:
		return
	var target_zoom: float = clamp(_pinch_initial_zoom * (dist / _pinch_initial_distance), min_zoom, max_zoom)
	var factor: float = target_zoom / _zoom
	var focus: Vector2 = (pts[0] + pts[1]) * 0.5
	_zoom_at(factor, focus)
	accept_event()

func _end_pinch() -> void:
	_pinching = false
	#_dbg("pinch_ended", {"zoom": _zoom})

func _first_two_touch_points() -> Array[Vector2]:
	var out: Array[Vector2] = []
	for k in _touch_points.keys():
		var p: Vector2 = _touch_points[k]
		out.append(p)
		if out.size() == 2:
			break
	if out.size() == 0:
		out.append(Vector2.ZERO)
	if out.size() == 1:
		out.append(out[0])
	return out

func _zoom_at(factor: float, focus_screen: Vector2) -> void:
	# Extra guard so programmatic zoom calls also respect modal state
	if _is_modal_open():
		return
	if not enable_zoom:
		return
	var new_zoom: float = clamp(_zoom * factor, min_zoom, max_zoom)
	var actual: float = new_zoom / _zoom
	if abs(actual - 1.0) < 0.001:
		return

	var focus: Vector2 = get_viewport_rect().size * 0.5
	if zoom_to_cursor:
		focus = focus_screen

	var nodes: Array[Node2D] = []
	if _grid_node != null:
		nodes.append(_grid_node)
	if _buttons_node != null:
		nodes.append(_buttons_node)

	for n: Node2D in nodes:
		var old_pos: Vector2 = n.position
		n.scale = n.scale * actual
		n.position = focus - (focus - old_pos) * actual

	_zoom = new_zoom
	#_dbg("zoom", {"zoom": _zoom, "factor": actual})

# --- Modal gating helpers -----------------------------------------------------

func _is_modal_open() -> bool:
	if not block_when_modal_open:
		return false

	# Preferred: ask the service if it exposes is_modal_open()
	if _modal != null and _modal.has_method("is_modal_open"):
		return bool(_modal.call("is_modal_open"))

	# Fallback: detect our auto UI layer with any visible Control child
	var scene := get_tree().current_scene
	if scene != null:
		var layer := scene.get_node_or_null("TileUILayer")
		if layer is CanvasLayer:
			var kids: Array = (layer as CanvasLayer).get_children()
			for ch in kids:
				if ch is Control and (ch as Control).visible:
					return true
	return false

func _cancel_interaction() -> void:
	_pointer_active = false
	_pointer_id = -9999
	_dragging = false
	_pinching = false
	_touch_points.clear()

# --- Debug --------------------------------------------------------------------

func _dbg(tag: String, data: Dictionary) -> void:
	if debug_logging:
		print("[Pan] ", tag, " | ", data)
