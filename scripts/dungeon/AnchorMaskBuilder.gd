extends RefCounted
class_name AnchorMaskBuilder

var _gm: GridMap
var _width: int
var _height: int
var _open: PackedInt32Array
var _reserved: PackedByteArray
var _cell_size: float
var _forbidden: Array[Vector3] = []

func _init(gm: GridMap, width: int, height: int, open: PackedInt32Array, reserved: PackedByteArray) -> void:
	_gm = gm
	_width = width
	_height = height
	_open = open
	_reserved = reserved
	_cell_size = gm.cell_size.x

func push_forbidden(p_world: Vector3) -> void:
	_forbidden.append(p_world)

func _cell_center_world(cx: int, cz: int) -> Vector3:
	var local: Vector3 = _gm.map_to_local(Vector3i(cx, 0, cz))
	return _gm.transform * local

func build_valid_mask(perim_buffer_cells: int, door_buf_m: float, start_buf_m: float) -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize(_width * _height)
	for z in range(_height):
		for x in range(_width):
			var i: int = MazeGen.idx(x, z, _width)
			var ok: bool = true
			if _open[i] == 0:
				ok = false
			elif _reserved.size() > 0 and _reserved[i] != 0:
				ok = false
			else:
				var edge_dist: int = min(min(x, _width - 1 - x), min(z, _height - 1 - z))
				if edge_dist < perim_buffer_cells:
					ok = false
			if ok and _forbidden.size() > 0:
				var w: Vector3 = _cell_center_world(x, z)
				for f in _forbidden:
					if f != Vector3.INF:
						if w.distance_to(f) < door_buf_m or w.distance_to(f) < start_buf_m:
							ok = false
							break
			mask[i] = (1 if ok else 0)
	return mask

func collect_candidates(mask: PackedByteArray) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for z in range(_height):
		for x in range(_width):
			var i: int = MazeGen.idx(x, z, _width)
			if mask[i] == 1:
				out.append(Vector2i(x, z))
	return out

func world_of_cell(c: Vector2i) -> Vector3:
	return _cell_center_world(c.x, c.y)

func cell_size() -> float:
	return _cell_size
