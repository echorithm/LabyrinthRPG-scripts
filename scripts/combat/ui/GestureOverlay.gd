# File: res://scripts/combat/ui/GestureOverlay.gd
# Godot 4.5 — typed gesture capture + simple drawing

class_name GestureOverlay
extends Control

signal submitted(points: Array[Vector2])
signal cleared()
signal stroke_updated(points: Array[Vector2])

@export var stroke_color: Color = Color(1, 1, 1, 0.95)
@export var stroke_width: float = 6.0
@export var min_sample_distance: float = 4.0
@export var submit_action: StringName = &"ui_submit"
@export var clear_action: StringName = &"ui_clear"

const DEBUG: bool = true  # set false to silence

var _points: Array[Vector2] = []
var _drawing: bool = false

func _ready() -> void:
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	clip_contents = false

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_begin_stroke(mb.position)
			else:
				_end_stroke(mb.position)
	elif event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			_begin_stroke(st.position)
		else:
			_end_stroke(st.position)
	elif event is InputEventMouseMotion and _drawing:
		var mm := event as InputEventMouseMotion
		_maybe_add_point(mm.position)
	elif event is InputEventScreenDrag and _drawing:
		var sd := event as InputEventScreenDrag
		_maybe_add_point(sd.position)

func _unhandled_input(event: InputEvent) -> void:
	if DEBUG and (event.is_action_pressed(submit_action) or event.is_action_pressed(clear_action)):
		print("[GestureOverlay] action: ", event.as_text())
	if event.is_action_pressed(submit_action):
		if _points.size() >= 2:
			submitted.emit(_points.duplicate())
	elif event.is_action_pressed(clear_action):
		clear_stroke()

func _begin_stroke(pos: Vector2) -> void:
	if DEBUG:
		print("[GestureOverlay] begin @", pos)
	_drawing = true
	_points.clear()
	_points.append(pos)
	stroke_updated.emit(_points.duplicate())
	queue_redraw()

func _end_stroke(pos: Vector2) -> void:
	if not _drawing:
		return
	if DEBUG:
		print("[GestureOverlay] end   @", pos, " (", _points.size(), " pts)")
	# IMPORTANT: these must run regardless of DEBUG
	_drawing = false
	_maybe_add_point(pos)
	stroke_updated.emit(_points.duplicate())
	queue_redraw()

func _maybe_add_point(pos: Vector2) -> void:
	if _points.is_empty() or _points[_points.size() - 1].distance_to(pos) >= min_sample_distance:
		_points.append(pos)
		stroke_updated.emit(_points.duplicate())
		queue_redraw()

func clear_stroke() -> void:
	_points.clear()
	cleared.emit()
	queue_redraw()

func _draw() -> void:
	if _points.size() >= 2:
		draw_polyline(PackedVector2Array(_points), stroke_color, stroke_width, true)
		draw_circle(_points[_points.size() - 1], stroke_width * 0.5, stroke_color)

func show_demo(points: Array[Vector2], submit: bool = false) -> void:
	_points = points.duplicate()
	stroke_updated.emit(_points.duplicate())
	queue_redraw()
	if submit:
		submitted.emit(_points.duplicate())
