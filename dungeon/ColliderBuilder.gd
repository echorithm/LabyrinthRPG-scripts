extends Object
class_name ColliderBuilder

static func rebuild_floor_colliders(
	open: PackedInt32Array,
	reserved: PackedByteArray,          # << supports “holes”
	gm_floor: GridMap,
	root_owner: Node,
	floor_collision_mode: int,          # 0 = plane, 1 = per-tile boxes
	floor_plane_lift: float,
	floor_top_y: float
) -> void:
	var old: Node3D = root_owner.get_node_or_null("FloorCollider") as Node3D
	if old != null:
		old.queue_free()

	var root := StaticBody3D.new()
	root.name = "FloorCollider"
	root.collision_layer = 1
	root.collision_mask = 1
	root_owner.add_child(root)

	# If any reserved (holes), force per-tile boxes even if “Plane” is chosen.
	var has_reserved: bool = false
	if reserved.size() > 0:
		for i: int in range(reserved.size()):
			if reserved[i] != 0:
				has_reserved = true
				break

	var use_plane: bool = (floor_collision_mode == 0 and not has_reserved)
	if use_plane:
		var cs := CollisionShape3D.new()
		var plane := WorldBoundaryShape3D.new()
		plane.plane = Plane(Vector3.UP, floor_top_y + floor_plane_lift)
		cs.shape = plane
		root.add_child(cs)
		return

	var cell_box := BoxShape3D.new()
	cell_box.size = Vector3(3.96, 0.10, 3.96)

	var width: int = int(root_owner.get("width"))
	var height: int = int(root_owner.get("height"))

	for z: int in range(height):
		for x: int in range(width):
			var idx: int = MazeGen.idx(x, z, width)
			if open[idx] == 0: continue
			if reserved.size() > 0 and reserved[idx] != 0: continue
			var csb := CollisionShape3D.new()
			csb.shape = cell_box
			var lp: Vector3 = (gm_floor.transform * gm_floor.map_to_local(Vector3i(x, 0, z))) + Vector3(0.0, 0.05, 0.0)
			csb.transform = Transform3D(Basis.IDENTITY, lp)
			root.add_child(csb)

# ---- reserved check ----
static func _edge_touches_reserved(reserved: PackedByteArray, w: int, h: int, ax: int, az: int, bx: int, bz: int) -> bool:
	if reserved.size() == 0: return false
	if ax < 0 or az < 0 or ax >= w or az >= h: return false
	if bx < 0 or bz < 0 or bx >= w or bz >= h: return false
	return reserved[MazeGen.idx(ax, az, w)] != 0 or reserved[MazeGen.idx(bx, bz, w)] != 0

# ---------- INNER WALLS (STRADDLED, E/S only) ----------
static func build_wall_colliders_from_topology(
	open: PackedInt32Array,
	reserved: PackedByteArray,
	gm_walls: GridMap,
	root_owner: Node,
	width: int,
	height: int,
	floor_top_y: float,
	wall_height: float,
	wall_thickness: float,
	debug_wall_trace: bool
) -> void:
	var old: Node3D = root_owner.get_node_or_null("WallColliders") as Node3D
	if old != null: old.queue_free()

	var root: StaticBody3D = StaticBody3D.new()
	root.name = "WallColliders"
	root.collision_layer = 1
	root.collision_mask = 1
	root_owner.add_child(root)

	var cell: float = gm_walls.cell_size.x
	var y_center: float = floor_top_y + wall_height * 0.5
	var t2: float = wall_thickness * 0.5

	# match DungeonPainter: S uses center at z = cell - t2; E uses center at x = cell - t2
	var box_s: BoxShape3D = BoxShape3D.new() # long in X
	box_s.size = Vector3(cell, wall_height, wall_thickness)
	var box_e: BoxShape3D = BoxShape3D.new() # long in Z
	box_e.size = Vector3(wall_thickness, wall_height, cell)

	for z: int in range(height):
		for x: int in range(width):
			var m: int = open[MazeGen.idx(x, z, width)]
			if m == 0: continue

			# SOUTH edge
			if (m & MazeGen.MASK[MazeGen.S]) == 0 and z + 1 < height:
				if not _edge_touches_reserved(reserved, width, height, x, z, x, z + 1):
					var center_s_local: Vector3 = Vector3(float(x) * cell + 2.0, y_center, float(z) * cell + (cell - t2))
					var center_s_world: Vector3 = gm_walls.transform * center_s_local
					var cs_s: CollisionShape3D = CollisionShape3D.new()
					cs_s.shape = box_s
					cs_s.transform = Transform3D(Basis.IDENTITY, center_s_world)
					root.add_child(cs_s)
					if debug_wall_trace: print("[COL] S (x=%d,z=%d) -> %s" % [x, z, str(center_s_world)])

			# EAST edge
			if (m & MazeGen.MASK[MazeGen.E]) == 0 and x + 1 < width:
				if not _edge_touches_reserved(reserved, width, height, x, z, x + 1, z):
					var center_e_local: Vector3 = Vector3(float(x) * cell + (cell - t2), y_center, float(z) * cell + 2.0)
					var center_e_world: Vector3 = gm_walls.transform * center_e_local
					var cs_e: CollisionShape3D = CollisionShape3D.new()
					cs_e.shape = box_e
					cs_e.transform = Transform3D(Basis.IDENTITY, center_e_world)
					root.add_child(cs_e)
					if debug_wall_trace: print("[COL] E (x=%d,z=%d) -> %s" % [x, z, str(center_e_world)])

# ---------- PERIMETER (STRADDLED) ----------
static func build_perimeter_wall_colliders(
	gm_walls: GridMap,
	root_owner: Node,
	width: int,
	height: int,
	floor_top_y: float,
	wall_height: float,
	wall_thickness: float,
	debug_wall_trace: bool
) -> void:
	var old: Node3D = root_owner.get_node_or_null("PerimeterColliders") as Node3D
	if old != null: old.queue_free()

	var root: StaticBody3D = StaticBody3D.new()
	root.name = "PerimeterColliders"
	root.collision_layer = 1
	root.collision_mask = 1
	root_owner.add_child(root)

	var cell: float = gm_walls.cell_size.x
	var full_w: float = float(width) * cell
	var full_h: float = float(height) * cell
	var y_center: float = floor_top_y + wall_height * 0.5

	var north_c_l: Vector3 = Vector3(full_w * 0.5, y_center, 0.5)
	var south_c_l: Vector3 = Vector3(full_w * 0.5, y_center, full_h - 0.5)
	var west_c_l: Vector3  = Vector3(0.5, y_center, full_h * 0.5)
	var east_c_l: Vector3  = Vector3(full_w - 0.5, y_center, full_h * 0.5)

	var north_c: Vector3 = gm_walls.transform * north_c_l
	var south_c: Vector3 = gm_walls.transform * south_c_l
	var west_c: Vector3  = gm_walls.transform * west_c_l
	var east_c: Vector3  = gm_walls.transform * east_c_l

	_add_box_shape(root, Vector3(full_w, wall_height, wall_thickness), Transform3D(Basis.IDENTITY, north_c))
	_add_box_shape(root, Vector3(full_w, wall_height, wall_thickness), Transform3D(Basis.IDENTITY, south_c))
	_add_box_shape(root, Vector3(wall_thickness, wall_height, full_h), Transform3D(Basis.IDENTITY, west_c))
	_add_box_shape(root, Vector3(wall_thickness, wall_height, full_h), Transform3D(Basis.IDENTITY, east_c))

	if debug_wall_trace:
		print("[COL PERIM] N center=%s size=%s" % [str(north_c), str(Vector3(full_w, wall_height, wall_thickness))])
		print("[COL PERIM] S center=%s size=%s" % [str(south_c), str(Vector3(full_w, wall_height, wall_thickness))])
		print("[COL PERIM] W center=%s size=%s" % [str(west_c),  str(Vector3(wall_thickness, wall_height, full_h))])
		print("[COL PERIM] E center=%s size=%s" % [str(east_c),  str(Vector3(wall_thickness, wall_height, full_h))])

static func _add_box_shape(parent: Node, size: Vector3, xform: Transform3D) -> void:
	var cs: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	cs.shape = box
	cs.transform = xform
	parent.add_child(cs)
