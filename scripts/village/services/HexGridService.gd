extends Node
class_name HexGridService

## Hex layout/orientation and grid helpers used by art & buttons.
## IMPORTANT: Godot's TileMap uses an OFFSET hex grid. We expose axial (q,r)
## but convert to offset (col,row) whenever we talk to TileMap.

enum OrientationType { POINTY_TOP, FLAT_TOP }

@export var orientation: OrientationType = OrientationType.POINTY_TOP
@export var cell_side_px: float = 128.0
@export var debug_logging: bool = true

const SQRT3 := 1.7320508075688772

# --- axial coordinate helpers -------------------------------------------------

func axial_dirs() -> Array[Vector2i]:
	var dirs: Array[Vector2i] = []
	dirs.append(Vector2i(+1,  0))  # E
	dirs.append(Vector2i(+1, -1))  # NE
	dirs.append(Vector2i( 0, -1))  # NW
	dirs.append(Vector2i(-1,  0))  # W
	dirs.append(Vector2i(-1, +1))  # SW
	dirs.append(Vector2i( 0, +1))  # SE
	return dirs

func axial_ring(q0: int, r0: int, radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if radius <= 0:
		return out
	var dirs: Array[Vector2i] = axial_dirs()
	var cur: Vector2i = Vector2i(q0, r0) + dirs[4] * radius  # start at SW corner
	for side: int in range(6):
		var dir: Vector2i = dirs[side]
		for step: int in range(radius):
			out.append(cur)
			cur += dir
	return out

func axial_disk(radius: int) -> Array[Vector2i]:
	var results: Array[Vector2i] = []
	for r: int in range(-radius, radius + 1):
		var qmin: int = max(-radius, -r - radius)
		var qmax: int = min(radius, -r + radius)
		for q: int in range(qmin, qmax + 1):
			results.append(Vector2i(q, r))
	return results

func neighbors(qr: Vector2i) -> Array[Vector2i]:
	var d: Array[Vector2i] = axial_dirs()
	var out: Array[Vector2i] = []
	for i: int in range(d.size()):
		out.append(qr + d[i])
	return out

# --- axial <-> offset conversion (matches Godot's hex TileMap) ---------------

# Godot Hex + HORIZONTAL offset (pointy-top): use ODD-R offset coordinates
#   col = q + (r - (r&1)) / 2
#   row = r
# FLAT-TOP (VERTICAL offset): use ODD-Q offset coordinates
#   col = q
#   row = r + (q - (q&1)) / 2
static func _odd(v: int) -> int:
	return (v & 1)

func axial_to_offset(qr: Vector2i) -> Vector2i:
	var q: int = qr.x
	var r: int = qr.y
	if orientation == OrientationType.POINTY_TOP:
		var col: int = q + ((r - _odd(r)) / 2)
		var row: int = r
		return Vector2i(col, row)
	else:
		var col2: int = q
		var row2: int = r + ((q - _odd(q)) / 2)
		return Vector2i(col2, row2)

func offset_to_axial(cr: Vector2i) -> Vector2i:
	var col: int = cr.x
	var row: int = cr.y
	if orientation == OrientationType.POINTY_TOP:
		var q: int = col - ((row - _odd(row)) / 2)
		var r: int = row
		return Vector2i(q, r)
	else:
		var q2: int = col
		var r2: int = row - ((col - _odd(col)) / 2)
		return Vector2i(q2, r2)

# --- geometry used by art placement ------------------------------------------

func orientation_is_pointy() -> bool:
	return orientation == OrientationType.POINTY_TOP

## Logical bounding box (tile_size) for a cell given the side length.
func expected_bbox() -> Vector2i:
	var w: float
	var h: float
	if orientation_is_pointy():
		w = SQRT3 * cell_side_px
		h = 2.0 * cell_side_px
	else:
		w = 2.0 * cell_side_px
		h = SQRT3 * cell_side_px
	return Vector2i(int(round(w)), int(round(h)))

## Local vector (from cell center) to the bottom vertex of the hex.
func bottom_from_center_local() -> Vector2:
	if orientation_is_pointy():
		return Vector2(0.0, cell_side_px)
	else:
		return Vector2(0.0, (SQRT3 * 0.5) * cell_side_px)

## World center of a given AXIAL cell (q,r), using TileMapLayer as ground truth.
func cell_center_world(axial_qr: Vector2i, layer: TileMapLayer) -> Vector2:
	var offset_cr: Vector2i = axial_to_offset(axial_qr)
	return layer.to_global(layer.map_to_local(offset_cr))

## World position of the bottom vertex for a given AXIAL cell.
func cell_bottom_world(axial_qr: Vector2i, layer: TileMapLayer) -> Vector2:
	var center: Vector2 = cell_center_world(axial_qr, layer)
	var delta: Vector2 = bottom_from_center_local()
	return center + delta

func disk_coords(radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = [] as Array[Vector2i]
	for q in range(-radius, radius + 1):
		var r1: int = max(-radius, -q - radius)
		var r2: int = min(radius, -q + radius)
		for r in range(r1, r2 + 1):
			out.append(Vector2i(q, r))
	return out
