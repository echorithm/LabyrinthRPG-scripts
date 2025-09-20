# Godot 4.4.1
extends RefCounted
class_name CTBModel

var gauge_size: int
var gauge: float
var fill_scale: float
var ctb_speed: float
var ready: bool

func _init(_gauge_size: int, _fill_scale: float, _ctb_speed: float) -> void:
	gauge_size = max(1, _gauge_size)
	fill_scale = max(0.0, _fill_scale)
	ctb_speed = max(0.0, _ctb_speed)
	gauge = 0.0
	ready = false

func tick(delta: float) -> void:
	if ready:
		return
	gauge += ctb_speed * fill_scale * max(0.0, delta)
	if gauge >= float(gauge_size):
		gauge = float(gauge_size)
		ready = true

func consume(cost: int) -> void:
	var c: float = float(max(0, cost))
	gauge = clampf(gauge - c, 0.0, float(gauge_size))
	ready = false
