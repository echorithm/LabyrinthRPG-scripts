extends Node2D

# ---- Config ----
enum Orientation { POINTY_TOP, FLAT_TOP }

@export var orientation: int = Orientation.POINTY_TOP
@export var side_px: float = 128.0                  # hex side length; used for camera/world math
@export var rings_to_spawn: int = 2                 # 1 = first ring, 2 = radius 2, etc.
@export var clear_before_build: bool = true

# Tile placement config (match your TileSet)
@export_node_path("TileMapLayer") var layer_path: NodePath
@export var tile_source_id: int = 0                 # TileSet Source ID
@export var tile_atlas_coord: Vector2i = Vector2i(0, 0)
@export var tile_alternative: int = 0

# Offset-grid parity:
#  - POINTY_TOP → usually odd-r
#  - FLAT_TOP   → usually odd-q
@export var use_odd_parity: bool = true

# ---- Nodes ----
@onready var layer: TileMapLayer = get_node(layer_path)
@onready var cam: Camera2D = $Camera2D

# ---- Internals ----
const SQRT3: float = 1.7320508075688772

# ---------------- Debug ----------------
func _dbg(section: String, msg: String, data: Dictionary = {}) -> void:
	var prefix: String = "[HexBoard]"
	if section != "": prefix += " " + section
	if data.is_empty(): print(prefix, " | ", msg)
	else: print(prefix, " | ", msg, "  ", data)

# ---------------- Axial ↔ world ----------------
func axial_to_world_center(q: int, r: int, s: float, o: int) -> Vector2:
	if o == Orientation.POINTY_TOP:
		return Vector2(s * SQRT3 * (float(q) + 0.5 * float(r)), s * 1.5 * float(r))
	else:
		return Vector2(s * 1.5 * float(q), s * SQRT3 * (float(r) + 0.5 * float(q)))

# Axial → offset coords matching TileMapLayer’s hex staggering
func axial_to_offset(q: int, r: int, o: int, odd_parity: bool) -> Vector2i:
	if o == Orientation.POINTY_TOP:
		# odd-r horizontal layout
		var parity: int = 1 if odd_parity else 0
		var col: int = q + int(floor((float(r) + float(parity)) * 0.5))
		var row: int = r
		return Vector2i(col, row)
	else:
		# odd-q vertical layout
		var parity2: int = 1 if odd_parity else 0
		var col2: int = q
		var row2: int = r + int(floor((float(q) + float(parity2)) * 0.5))
		return Vector2i(col2, row2)

# ---------------- Rings ----------------
func _axial_dirs() -> Array[Vector2i]:
	var dirs: Array[Vector2i] = [] as Array[Vector2i]
	dirs.append(Vector2i( 1,  0)) # E
	dirs.append(Vector2i( 1, -1)) # NE
	dirs.append(Vector2i( 0, -1)) # NW
	dirs.append(Vector2i(-1,  0)) # W
	dirs.append(Vector2i(-1,  1)) # SW
	dirs.append(Vector2i( 0,  1)) # SE
	return dirs

# Red Blob “ring”: start SW and walk 6 sides
func axial_ring(q0: int, r0: int, radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = [] as Array[Vector2i]
	if radius <= 0: return out
	var dirs: Array[Vector2i] = _axial_dirs()
	var cur: Vector2i = Vector2i(q0, r0) + dirs[4] * radius
	for side: int in range(6):
		var d: Vector2i = dirs[side]
		for _i: int in range(radius):
			out.append(cur)
			cur += d
	return out

# Optional: filled disk (<= radius)
func axial_disk(q0: int, r0: int, radius: int) -> Array[Vector2i]:
	var results: Array[Vector2i] = [] as Array[Vector2i]
	for rr: int in range(-radius, radius + 1):
		var qmin: int = max(-radius, -rr - radius)
		var qmax: int = min( radius, -rr + radius)
		for qq: int in range(qmin, qmax + 1):
			results.append(Vector2i(q0 + qq, r0 + rr))
	return results

# ---------------- Build ----------------
func _ready() -> void:
	_dbg("ready", "start", {"orientation": ("POINTY" if orientation == Orientation.POINTY_TOP else "FLAT"), "side_px": side_px})
	assert(layer != null, "TileMapLayer not found – set 'layer_path' export.")

	if clear_before_build:
		layer.clear()
		_dbg("layer", "cleared", {})

	# Prime
	_place_axial(0, 0)

	# Rings 1..R
	for radius: int in range(1, rings_to_spawn + 1):
		var ring: Array[Vector2i] = axial_ring(0, 0, radius)
		_dbg("build", "ring", {"radius": radius, "count": ring.size()})
		for qr: Vector2i in ring:
			_place_axial(qr.x, qr.y)

	# Center camera on (0,0)
	_center_camera_on(0, 0)

func _place_axial(q: int, r: int) -> void:
	var grid: Vector2i = axial_to_offset(q, r, orientation, use_odd_parity)
	layer.set_cell(grid, tile_source_id, tile_atlas_coord, tile_alternative)
	_dbg("layer", "set_cell", {"axial": str(q) + "," + str(r), "grid": str(grid)})

# ---------------- Camera ----------------
func _center_camera_on(q: int, r: int) -> void:
	var p: Vector2 = axial_to_world_center(q, r, side_px, orientation)
	cam.global_position = p
	_dbg("cam", "centered", {"q": q, "r": r, "world": "(" + str(p.x) + ", " + str(p.y) + ")"})
