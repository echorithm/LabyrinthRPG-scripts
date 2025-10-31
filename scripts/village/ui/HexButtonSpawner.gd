extends Node2D
class_name HexButtonSpawner

@export var rings_to_spawn: int = 3
@export var side_px: float = 128.0
@export var orientation: int = 0
@export var z_above_art: int = 10
@export var debug_logging: bool = false
@export var debug_print_clicks: bool = true

# New: inspector toggles
@export var show_hex_outlines: bool = true: set = _set_show_hex_outlines
@export var show_hex_coords: bool = false: set = _set_show_hex_coords

@export var base_layer_path: NodePath
@export var grid_service_path: NodePath

var _base_layer: TileMapLayer
var _grid: HexGridService

const NEIGHBORS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)
]
const SQRT3: float = 1.7320508075688772

var ring_layers: Array[Dictionary] = []
var seen: Dictionary = {}
var parent_of: Dictionary = {}
var children_of: Dictionary = {}

func _ready() -> void:
	_bind_by_paths()
	# If buttons existed (scene reloaded), restyle them to match toggles.
	_restyle_all_buttons()

# ---------------- Public API ----------------

func clear_buttons() -> void:
	for c: Node in get_children():
		if c is HexControlButton:
			(c as HexControlButton).queue_free()

func spawn_for_hex_disc(radius: int) -> void:
	_bind_by_paths()
	if _base_layer == null or _grid == null:
		return
	clear_buttons()

	side_px = _grid.cell_side_px
	orientation = _grid.orientation

	var k: int = min(radius, rings_to_spawn)
	_build_layers(k, Vector2i(0, 0))

	var coords: Array[Vector2i] = _all_coords_up_to(k)
	for qr: Vector2i in coords:
		_spawn_button(qr)

func spawn_for_disk(radius: int) -> void:
	_bind_by_paths()
	if _base_layer == null or _grid == null:
		return
	clear_buttons()

	side_px = _grid.cell_side_px
	orientation = _grid.orientation

	var k: int = min(radius, rings_to_spawn)
	var coords: Array[Vector2i] = _rhombus_disc(k)
	coords = _filter_by_hex_distance(coords, k)
	for qr: Vector2i in coords:
		_spawn_button(qr)

# ---------------- Layer building ---------------------------------------------

func _build_layers(radius: int, origin: Vector2i) -> void:
	ring_layers.clear()
	seen.clear()
	parent_of.clear()
	children_of.clear()

	var L0: Dictionary = {}
	L0[origin] = true
	ring_layers.append(L0)
	seen[origin] = true

	for r: int in range(1, radius + 1):
		var prev: Dictionary = ring_layers[r - 1]
		var cur: Dictionary = {}
		for key in prev.keys():
			var p: Vector2i = key as Vector2i
			for d: Vector2i in NEIGHBORS:
				var q: Vector2i = p + d
				if not seen.has(q):
					seen[q] = true
					cur[q] = true
					parent_of[q] = p
					if not children_of.has(p):
						children_of[p] = [] as Array[Vector2i]
					(children_of[p] as Array[Vector2i]).append(q)
		ring_layers.append(cur)

func _all_coords_up_to(radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = [] as Array[Vector2i]
	var max_r: int = min(radius, ring_layers.size() - 1)
	for r: int in range(0, max_r + 1):
		for key in ring_layers[r].keys():
			out.append(key as Vector2i)
	out.sort_custom(Callable(self, "_sort_axial_canonical"))
	return out

func _sort_axial_canonical(a: Vector2i, b: Vector2i) -> bool:
	return a.y < b.y if a.y != b.y else a.x < b.x

# ---------------- Internals ---------------------------------------------------

func _bind_by_paths() -> void:
	_base_layer = get_node_or_null(base_layer_path) as TileMapLayer
	_grid = get_node_or_null(grid_service_path) as HexGridService
	#if debug_logging:
	#	print("[HexSpawner] bind base=", _base_layer != null, " grid=", _grid != null)

func _spawn_button(qr: Vector2i) -> void:
	var center_world: Vector2 = _grid.cell_center_world(qr, _base_layer)
	var bbox: Vector2 = _compute_bbox_local(side_px, orientation)
	var pts: PackedVector2Array = _make_hex_points_local(side_px, orientation)

	var btn := HexControlButton.new()
	btn.side_px = side_px
	btn.orientation = orientation
	btn.fill_color = Color(1, 1, 1, 0.06)
	btn.outline_color = Color(1, 1, 1, 0.35)
	btn.outline_width = (2.0 if show_hex_outlines else 0.0)
	btn.axial_q = qr.x
	btn.axial_r = qr.y
	btn.auto_label_coords = show_hex_coords

	add_child(btn)
	btn.z_index = z_above_art

	btn.custom_minimum_size = bbox
	btn.size = bbox
	btn._bbox = bbox
	btn._pts = pts
	btn.global_position = Vector2(round(center_world.x), round(center_world.y)) - bbox * 0.5

	btn.gui_input.connect(Callable(self, "_on_hex_button_gui_input").bind(qr))

	#if debug_logging:
	#	print("[HexSpawner] placed ", qr, " at ", center_world)

# ---------------- Click handlers ---------------------------------------------

func _on_hex_button_gui_input(event: InputEvent, qr: Vector2i) -> void:
	if event is InputEventMouseButton:
		var e := event as InputEventMouseButton
		if e.button_index == MOUSE_BUTTON_LEFT and not e.pressed:
			#print("[HexSpawner] RELEASE on ", qr, " @frame=", Engine.get_process_frames())
			_open_tile_modal_via_service(qr)
	elif event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if not t.pressed:
			#print("[HexSpawner] TAP on ", qr, " @frame=", Engine.get_process_frames())
			_open_tile_modal_via_service(qr)

func _open_tile_modal_via_service(qr: Vector2i) -> void:
	var svcs: Array = get_tree().get_nodes_in_group("village_modal_service")
	if svcs.is_empty():
		push_warning("[HexSpawner] TileModalService not found (group=village_modal_service).")
		return
	var svc: Node = svcs[0] as Node
	#print("[HexSpawner] service=", svc.get_class(), " path=", svc.get_path())

	var block_now: bool = false
	if svc.has_method("should_block_open"):
		block_now = bool(svc.call("should_block_open"))
		#print("[HexSpawner] should_block_open -> ", block_now)

	if block_now:
		#print("[HexSpawner] SKIP open (blocked) for ", qr)
		return

	if svc.has_method("open_for_tile"):
		#print("[HexSpawner] CALL open_for_tile ", qr)
		svc.call("open_for_tile", qr)
	else:
		print("[HexSpawner] service missing open_for_tile")

# ---------------- Shapes & helpers -------------------------------------------

static func _rhombus_disc(k: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = [] as Array[Vector2i]
	for r: int in range(-k, k + 1):
		for q: int in range(-k, k + 1):
			if max(abs(q), abs(r)) <= k:
				out.append(Vector2i(q, r))
	return out

static func _hex_disc(k: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = [] as Array[Vector2i]
	for r: int in range(-k, k + 1):
		var qmin: int = max(-k, -r - k)
		var qmax: int = min(k, -r + k)
		for q: int in range(qmin, qmax + 1):
			out.append(Vector2i(q, r))
	return out

static func _axial_distance(qr: Vector2i) -> int:
	var q: int = qr.x
	var r: int = qr.y
	var s: int = -q - r
	return (abs(q) + abs(r) + abs(s)) / 2

static func _filter_by_hex_distance(coords: Array[Vector2i], k: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = [] as Array[Vector2i]
	for qr: Vector2i in coords:
		if _axial_distance(qr) <= k:
			out.append(qr)
	return out

static func _compute_bbox_local(s: float, o: int) -> Vector2:
	return Vector2(SQRT3 * s, 2.0 * s) if o == HexControlButton.Orientation.POINTY_TOP else Vector2(2.0 * s, SQRT3 * s)

static func _make_hex_points_local(s: float, o: int) -> PackedVector2Array:
	var pts: PackedVector2Array = PackedVector2Array()
	if o == HexControlButton.Orientation.POINTY_TOP:
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

# ---------------- Styling helpers for toggles --------------------------------

func _set_show_hex_outlines(v: bool) -> void:
	show_hex_outlines = v
	_restyle_all_buttons()

func _set_show_hex_coords(v: bool) -> void:
	show_hex_coords = v
	_restyle_all_buttons()

func _restyle_all_buttons() -> void:
	for c in get_children():
		if c is HexControlButton:
			var b := c as HexControlButton
			b.outline_width = (2.0 if show_hex_outlines else 0.0)
			b.auto_label_coords = show_hex_coords
