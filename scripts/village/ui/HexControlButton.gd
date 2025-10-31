extends Control
class_name HexControlButton

## A lightweight clickable hex overlay. Draws a hex, shows axial coords,
## and emits `pressed` on click/tap release. Used by HexButtonSpawner.

signal pressed

enum Orientation { POINTY_TOP, FLAT_TOP }

@export var side_px: float = 128.0
@export var orientation: int = Orientation.POINTY_TOP   # enum is int-typed
@export var fill_color: Color = Color(1, 1, 1, 0.08)
@export var outline_color: Color = Color(1, 1, 1, 0.45)
@export var outline_width: float = 2.0

@export var auto_label_coords: bool = true
@export var axial_q: int = 0
@export var axial_r: int = 0

# Set by spawner (public on purpose for perf/minimal API surface)
var _bbox: Vector2 = Vector2.ZERO
var _pts: PackedVector2Array = PackedVector2Array()

const SQRT3 := 1.7320508075688772

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	if _pts.is_empty():
		_bbox = _compute_bbox(side_px, orientation)
		_pts = _make_hex_points(side_px, orientation)
	custom_minimum_size = _bbox
	size = _bbox

func _draw() -> void:
	if _pts.size() == 6:
		draw_colored_polygon(_pts, fill_color)
		# outline
		for i: int in range(6):
			var a: Vector2 = _pts[i]
			var b: Vector2 = _pts[(i + 1) % 6]
			draw_line(a, b, outline_color, outline_width)

	if auto_label_coords:
		var label := "%d,%d" % [axial_q, axial_r]
		var font: Font = get_theme_default_font()
		var sz: int = get_theme_default_font_size()
		var m: Vector2 = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, sz)
		var pos: Vector2 = (size * 0.5) - (m * 0.5)
		draw_string(font, pos + Vector2(0, sz * 0.35), label, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, Color(1,1,1,0.9))

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var e := event as InputEventMouseButton
		if e.button_index == MOUSE_BUTTON_LEFT and not e.pressed:
			pressed.emit()
	elif event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if not t.pressed:
			pressed.emit()

# --- geometry helpers ---------------------------------------------------------

static func _compute_bbox(s: float, o: int) -> Vector2:
	return Vector2(SQRT3 * s, 2.0 * s) if o == Orientation.POINTY_TOP else Vector2(2.0 * s, SQRT3 * s)

static func _make_hex_points(s: float, o: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	if o == Orientation.POINTY_TOP:
		var w: float = SQRT3 * s
		var h: float = 2.0 * s
		var cx: float = w * 0.5
		var cy: float = h * 0.5
		pts.push_back(Vector2(cx + 0.0,               cy - s))
		pts.push_back(Vector2(cx + (SQRT3 * 0.5) * s, cy - 0.5 * s))
		pts.push_back(Vector2(cx + (SQRT3 * 0.5) * s, cy + 0.5 * s))
		pts.push_back(Vector2(cx + 0.0,               cy + s))
		pts.push_back(Vector2(cx - (SQRT3 * 0.5) * s, cy + 0.5 * s))
		pts.push_back(Vector2(cx - (SQRT3 * 0.5) * s, cy - 0.5 * s))
	else:
		var w2: float = 2.0 * s
		var h2: float = SQRT3 * s
		var cx2: float = w2 * 0.5
		var cy2: float = h2 * 0.5
		pts.push_back(Vector2(cx2 + s,          cy2 + 0.0))
		pts.push_back(Vector2(cx2 + 0.5 * s,    cy2 + (SQRT3 * 0.5) * s))
		pts.push_back(Vector2(cx2 - 0.5 * s,    cy2 + (SQRT3 * 0.5) * s))
		pts.push_back(Vector2(cx2 - s,          cy2 + 0.0))
		pts.push_back(Vector2(cx2 - 0.5 * s,    cy2 - (SQRT3 * 0.5) * s))
		pts.push_back(Vector2(cx2 + 0.5 * s,    cy2 - (SQRT3 * 0.5) * s))
	return pts
