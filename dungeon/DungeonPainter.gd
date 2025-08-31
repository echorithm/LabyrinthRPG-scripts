extends Object
class_name DungeonPainter

#
# ──────────────────────────────────────────────────────────────────────────────
#  Tuning knobs
# ──────────────────────────────────────────────────────────────────────────────
#
# Enable/disable extra filler meshes at wall junctions:
const USE_SMALL_CORNERS: bool   = false # L-corner fillers (two walls meet at right angle)
const USE_END_CAPS: bool        = false # dead-end caps (one wall segment ends)
const USE_JUNCTION_POSTS: bool  = false  # posts at T / Cross junctions (>= 2 segments)
const SMALL_CORNERS_USE_PILLAR: bool = true   # ← when true, L-corners use pillar mesh

# Offsets for the three filler types — tweak these to nudge in X/Z:
# (Positive increases world X/Z; negative decreases.)
const POST_DX: float    = 1.50   # ← moves the T/Cross "post" along X
const POST_DZ: float    = 1.50   # ← moves the T/Cross "post" along Z
const CORNER_DX: float  = 1.50   # ← moves the small corner along X
const CORNER_DZ: float  = 1.50   # ← moves the small corner along Z
const CAP_DX: float     = 0   # ← moves the dead-end cap along X
const CAP_DZ: float     = 1.50  # ← moves the dead-end cap along Z

# Straddled placement (visual consistency)
const STR: Vector3 = Vector3(-0.5, 0.0, -0.5)

# ──────────────────────────────────────────────────────────────────────────────

static func paint_grid(
	gm_floor: GridMap,
	gm_walls: GridMap,
	open: PackedInt32Array,
	width: int,
	height: int,
	id_floor: int,
	id_wall: int,
	reserved: PackedByteArray = PackedByteArray(),
	debug_wall_trace: bool = false
) -> Dictionary:
	# Reset gridmaps and layers
	gm_floor.clear()
	gm_walls.clear()
	gm_floor.collision_layer = 1
	gm_floor.collision_mask = 1
	gm_walls.collision_layer = 1
	gm_walls.collision_mask = 1

	var lib: MeshLibrary = gm_floor.mesh_library

	# Floor top Y from the floor mesh
	var floor_top_y: float = MeshLibTools.compute_floor_top_y_world(gm_floor, id_floor)

	# Wall dimensions from id_wall
	var wall_mesh: Mesh = null
	if id_wall >= 0:
		wall_mesh = lib.get_item_mesh(id_wall)
	var aabb: AABB = AABB()
	if wall_mesh != null:
		aabb = wall_mesh.get_aabb()
	var wall_thickness: float = 1.0
	var wall_height: float = 4.0
	if wall_mesh != null:
		wall_thickness = min(aabb.size.x, aabb.size.z)
		wall_height = aabb.size.y

	# Optional extra meshes from the same MeshLibrary
	var id_pillar: int = MeshLibTools.find_any(lib, PackedStringArray(["pillar", "post", "column"]))
	var id_corner_small: int = MeshLibTools.find_any(lib, PackedStringArray(["wall_corner_small", "corner_small", "corner"]))
	var id_end_cap: int = MeshLibTools.find_any(lib, PackedStringArray(["wall_end_cap", "wall_cap", "end_cap", "cap"]))

	var pillar_mesh: Mesh = null
	var corner_small_mesh: Mesh = null
	var cap_mesh: Mesh = null
	if id_pillar >= 0:
		pillar_mesh = lib.get_item_mesh(id_pillar)
	if id_corner_small >= 0:
		corner_small_mesh = lib.get_item_mesh(id_corner_small)
	if id_end_cap >= 0:
		cap_mesh = lib.get_item_mesh(id_end_cap)

	# Force refresh (Godot quirk)
	gm_floor.mesh_library = gm_floor.mesh_library
	gm_walls.mesh_library = gm_walls.mesh_library

	# -------- Floors: paint ONLY where maze is open and not reserved --------
	for z in range(height):
		for x in range(width):
			var i: int = MazeGen.idx(x, z, width)
			if open[i] != 0:
				if reserved.size() == 0 or reserved[i] == 0:
					gm_floor.set_cell_item(Vector3i(x, 0, z), id_floor, 0)

	# -------- Visual inner walls (straddled; E/S edges only; skip edges touching reserved) --------
	var old_wv: Node3D = gm_walls.get_node_or_null("WallsVisual") as Node3D
	if old_wv != null:
		old_wv.queue_free()
	var walls_visual: Node3D = Node3D.new()
	walls_visual.name = "WallsVisual"
	gm_walls.add_child(walls_visual)

	var cell: float = gm_walls.cell_size.x
	var y_local: float = floor_top_y
	var t2: float = wall_thickness * 0.5

	if wall_mesh != null:
		for z2 in range(height):
			for x2 in range(width):
				var i0: int = MazeGen.idx(x2, z2, width)
				var m: int = open[i0]
				if m == 0:
					continue

				# South edge between (x2,z2) and (x2,z2+1)
				if (m & MazeGen.MASK[MazeGen.S]) == 0 and z2 + 1 < height:
					var i1: int = MazeGen.idx(x2, z2 + 1, width)
					var touches_reserved_s: bool = false
					if reserved.size() > 0:
						if reserved[i0] != 0 or reserved[i1] != 0:
							touches_reserved_s = true
					if not touches_reserved_s:
						var pos_s: Vector3 = Vector3(float(x2) * cell + 2.0, y_local, float(z2) * cell + (cell - t2))
						_add_wall_instance(walls_visual, wall_mesh, Transform3D(_yaw(180.0), pos_s))
						if debug_wall_trace:
							print("[VIS] S (%d,%d) pos=%s" % [x2, z2, str(pos_s)])

				# East edge between (x2,z2) and (x2+1,z2)
				if (m & MazeGen.MASK[MazeGen.E]) == 0 and x2 + 1 < width:
					var j1: int = MazeGen.idx(x2 + 1, z2, width)
					var touches_reserved_e: bool = false
					if reserved.size() > 0:
						if reserved[i0] != 0 or reserved[j1] != 0:
							touches_reserved_e = true
					if not touches_reserved_e:
						var pos_e: Vector3 = Vector3(float(x2) * cell + (cell - t2), y_local, float(z2) * cell + 2.0)
						_add_wall_instance(walls_visual, wall_mesh, Transform3D(_yaw(90.0), pos_e))
						if debug_wall_trace:
							print("[VIS] E (%d,%d) pos=%s" % [x2, z2, str(pos_e)])

		# Perimeter visuals (flush/straddled to outer ring)
		_paint_perimeter_visual_walls_wmesh(
			walls_visual, wall_mesh, width, height, cell, y_local, wall_thickness, debug_wall_trace
		)

	# -------- Vertex analysis for posts / corners / caps --------
	# For each vertex (grid intersection), count how many wall segments meet there by
	# checking the E and S edges of the adjacent cells.
	for vz in range(height + 1):
		for vx in range(width + 1):
			var h_count: int = 0  # number of S segments meeting this vertex
			var v_count: int = 0  # number of E segments meeting this vertex

			# South edges contributing at this vertex:
			#  - S of (vx-1, vz)  (to the left)
			#  - S of (vx,   vz)  (to the right)
			if vx - 1 >= 0 and vz < height:
				if _has_s_wall(open, width, height, vx - 1, vz):
					h_count += 1
			if vx < width and vz < height:
				if _has_s_wall(open, width, height, vx, vz):
					h_count += 1

			# East edges contributing at this vertex:
			#  - E of (vx, vz-1)  (above)
			#  - E of (vx, vz)    (below)
			if vz - 1 >= 0 and vx < width:
				if _has_e_wall(open, width, height, vx, vz - 1):
					v_count += 1
			if vx < width and vz < height:
				if _has_e_wall(open, width, height, vx, vz):
					v_count += 1

			var total: int = h_count + v_count
			if total <= 0:
				continue  # nothing meets here

			# Base (midline) intersection in local grid coordinates
			var base_x: float = float(vx) * cell + 2.0
			var base_z: float = float(vz) * cell + 2.0

			# 1) L-corner (one horizontal + one vertical)
			if USE_SMALL_CORNERS and h_count == 1 and v_count == 1:
				var which_corner_mesh: Mesh = null
				if SMALL_CORNERS_USE_PILLAR and pillar_mesh != null:
					which_corner_mesh = pillar_mesh
				elif corner_small_mesh != null:
					which_corner_mesh = corner_small_mesh

				if which_corner_mesh != null:
					var cx: float = base_x + CORNER_DX   # ← tweak L-corner X offset here
					var cz: float = base_z + CORNER_DZ   # ← tweak L-corner Z offset here
					var cp: Vector3 = Vector3(cx, y_local, cz)
					_add_wall_instance(walls_visual, which_corner_mesh, Transform3D(Basis.IDENTITY, cp))
					if debug_wall_trace:
						print("[VIS CORNER] at (x=%d,z=%d) -> %s" % [vx, vz, str(cp)])


			# 2) Dead-end cap (exactly one segment)
			elif USE_END_CAPS and total == 1:
				var ex: float = base_x + CAP_DX
				var ez: float = base_z + CAP_DZ
				var ep: Vector3 = Vector3(ex, y_local, ez)
				var which_mesh: Mesh = null
				if cap_mesh != null:
					which_mesh = cap_mesh
				elif pillar_mesh != null:
					which_mesh = pillar_mesh
				if which_mesh != null:
					_add_wall_instance(walls_visual, which_mesh, Transform3D(Basis.IDENTITY, ep))
					if debug_wall_trace:
						var end_h: bool = (h_count == 1 and v_count == 0)
						var end_v: bool = (v_count == 1 and h_count == 0)
						print("[VIS CAP] at (x=%d,z=%d) end_h=%s end_v=%s -> %s" % [vx, vz, str(end_h), str(end_v), str(ep)])

			# 3) T or Cross → junction post (two or more segments)
			elif USE_JUNCTION_POSTS and total >= 2:
				if pillar_mesh != null:
					var px: float = base_x + POST_DX
					var pz: float = base_z + POST_DZ
					var pp: Vector3 = Vector3(px, y_local, pz)
					_add_wall_instance(walls_visual, pillar_mesh, Transform3D(Basis.IDENTITY, pp))
					if debug_wall_trace:
						print("[VIS POST] at (x=%d,z=%d) -> %s" % [vx, vz, str(pp)])

	return {
		"floor_top_y": floor_top_y,
		"wall_thickness": wall_thickness,
		"wall_height": wall_height
	}

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

static func _yaw(deg: float) -> Basis:
	return Basis(Vector3.UP, deg_to_rad(deg))

static func _add_wall_instance(parent: Node3D, mesh: Mesh, xform: Transform3D) -> void:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	mi.transform = xform
	parent.add_child(mi)

static func _paint_perimeter_visual_walls_wmesh(
	walls_visual: Node3D,
	mesh: Mesh,
	width: int,
	height: int,
	cell: float,
	y_local: float,
	wall_thickness: float,
	debug_wall_trace: bool
) -> void:
	var full_w: float = float(width) * cell
	var full_h: float = float(height) * cell
	var t2: float = wall_thickness * 0.5

	# North / South runs
	for x in range(width):
		var x_pos: float = float(x) * cell + 2.0
		var pos_n: Vector3 = Vector3(x_pos, y_local, 0.0 + t2)
		var pos_s: Vector3 = Vector3(x_pos, y_local, full_h - t2)
		_add_wall_instance(walls_visual, mesh, Transform3D(_yaw(0.0), pos_n))
		_add_wall_instance(walls_visual, mesh, Transform3D(_yaw(180.0), pos_s))
		if debug_wall_trace:
			print("[VIS PERIM] N x=%d pos=%s" % [x, str(pos_n)])
			print("[VIS PERIM] S x=%d pos=%s" % [x, str(pos_s)])

	# West / East runs
	for z in range(height):
		var z_pos: float = float(z) * cell + 2.0
		var pos_w: Vector3 = Vector3(0.0 + t2, y_local, z_pos)
		var pos_e: Vector3 = Vector3(full_w - t2, y_local, z_pos)
		_add_wall_instance(walls_visual, mesh, Transform3D(_yaw(270.0), pos_w))
		_add_wall_instance(walls_visual, mesh, Transform3D(_yaw(90.0), pos_e))
		if debug_wall_trace:
			print("[VIS PERIM] W z=%d pos=%s" % [z, str(pos_w)])
			print("[VIS PERIM] E z=%d pos=%s" % [z, str(pos_e)])

# Does this cell have a CLOSED south edge? (i.e., a visible wall segment there)
static func _has_s_wall(open: PackedInt32Array, cols: int, rows: int, x: int, z: int) -> bool:
	if x < 0 or x >= cols or z < 0 or z >= rows:
		return false
	var m: int = open[MazeGen.idx(x, z, cols)]
	if z + 1 >= rows:
		return false
	return (m & MazeGen.MASK[MazeGen.S]) == 0

# Does this cell have a CLOSED east edge?
static func _has_e_wall(open: PackedInt32Array, cols: int, rows: int, x: int, z: int) -> bool:
	if x < 0 or x >= cols or z < 0 or z >= rows:
		return false
	var m: int = open[MazeGen.idx(x, z, cols)]
	if x + 1 >= cols:
		return false
	return (m & MazeGen.MASK[MazeGen.E]) == 0
