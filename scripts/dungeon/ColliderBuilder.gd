extends Object
class_name ColliderBuilder

const FLOOR_MODE_PLANE := 0
const FLOOR_MODE_TILES := 1
const FLOOR_MODE_NONE  := 2

static func rebuild_floor_colliders(
	open: PackedInt32Array,
	reserved: PackedByteArray,
	gm_floor: GridMap,
	root_owner: Node,
	floor_collision_mode: int,   # 0=Plane, 1=PerTileBoxes, 2=None
	floor_plane_lift: float,
	floor_top_y: float
) -> void:
	# hard reset of anything we previously built
	var removed := clear_floor_colliders(root_owner)
	if removed > 0:
		print("[COL] cleared ", removed, " old floor colliders")

	# container (kept for organization / backwards-compat)
	var container := Node3D.new()
	container.name = "FloorCollider"
	root_owner.add_child(container)

	# detect “holes” to avoid the infinite plane when reservations exist
	var has_reserved := false
	if reserved.size() > 0:
		for i in reserved.size():
			if reserved[i] != 0:
				has_reserved = true
				break

	# mode: None → skip entirely
	if floor_collision_mode == FLOOR_MODE_NONE:
		print("[COL] floor mode=None → no floor colliders built")
		return

	# mode: Plane (only if no reserved holes)
	if floor_collision_mode == FLOOR_MODE_PLANE and not has_reserved:
		var sb := _make_floor_body("Floor_Plane")
		var cs := CollisionShape3D.new()
		var plane := WorldBoundaryShape3D.new()
		plane.plane = Plane(Vector3.UP, floor_top_y + floor_plane_lift)
		cs.shape = plane
		sb.add_child(cs)
		container.add_child(sb)
		print("[COL] plane floor at y=", floor_top_y + floor_plane_lift)
		return

	# mode: PerTileBoxes (or Plane-with-holes fallback)
	var width: int  = int(root_owner.get("width"))
	var height: int = int(root_owner.get("height"))

	var cell_box := BoxShape3D.new()
	# use your cell size; tiny inset to avoid z-fighting with meshes
	cell_box.size = Vector3(gm_floor.cell_size.x - 0.04, 0.10, gm_floor.cell_size.z - 0.04)

	

	for z in range(height):
		for x in range(width):
			var idx := MazeGen.idx(x, z, width)
			if open[idx] == 0:       # closed cell
				continue
			if reserved.size() > 0 and reserved[idx] != 0:  # prefab hole
				continue

			var sb := _make_floor_body("FloorTile_%d_%d" % [x, z])
			var cs := CollisionShape3D.new()
			cs.shape = cell_box

			# place at cell center, slightly lifted
			var lp := (gm_floor.transform * gm_floor.map_to_local(Vector3i(x, 0, z))) + Vector3(0.0, 0.05, 0.0)
			cs.transform = Transform3D(Basis.IDENTITY, lp)

			sb.add_child(cs)
			container.add_child(sb)

	


# ---- reserved check for wall edges ----
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

	# Match DungeonPainter placement (S at z = cell - t2, E at x = cell - t2)
	var box_s := BoxShape3D.new() # long in X
	box_s.size = Vector3(cell, wall_height, wall_thickness)
	var box_e := BoxShape3D.new() # long in Z
	box_e.size = Vector3(wall_thickness, wall_height, cell)

	for z: int in range(height):
		for x: int in range(width):
			var m: int = open[MazeGen.idx(x, z, width)]
			if m == 0: continue

			# SOUTH edge
			if (m & MazeGen.MASK[MazeGen.S]) == 0 and z + 1 < height:
				if not _edge_touches_reserved(reserved, width, height, x, z, x, z + 1):
					var center_s_local := Vector3(float(x) * cell + 2.0, y_center, float(z) * cell + (cell - t2))
					var center_s_world := gm_walls.transform * center_s_local
					var cs_s := CollisionShape3D.new()
					cs_s.shape = box_s
					cs_s.transform = Transform3D(Basis.IDENTITY, center_s_world)
					root.add_child(cs_s)
					#if debug_wall_trace: print("[COL] S (x=%d,z=%d) -> %s" % [x, z, str(center_s_world)])

			# EAST edge
			if (m & MazeGen.MASK[MazeGen.E]) == 0 and x + 1 < width:
				if not _edge_touches_reserved(reserved, width, height, x, z, x + 1, z):
					var center_e_local := Vector3(float(x) * cell + (cell - t2), y_center, float(z) * cell + 2.0)
					var center_e_world := gm_walls.transform * center_e_local
					var cs_e := CollisionShape3D.new()
					cs_e.shape = box_e
					cs_e.transform = Transform3D(Basis.IDENTITY, center_e_world)
					root.add_child(cs_e)
					#if debug_wall_trace: print("[COL] E (x=%d,z=%d) -> %s" % [x, z, str(center_e_world)])

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

	var north_c_l := Vector3(full_w * 0.5, y_center, 0.5)
	var south_c_l := Vector3(full_w * 0.5, y_center, full_h - 0.5)
	var west_c_l  := Vector3(0.5, y_center, full_h * 0.5)
	var east_c_l  := Vector3(full_w - 0.5, y_center, full_h * 0.5)

	var north_c := gm_walls.transform * north_c_l
	var south_c := gm_walls.transform * south_c_l
	var west_c  := gm_walls.transform * west_c_l
	var east_c  := gm_walls.transform * east_c_l

	_add_box_shape(root, Vector3(full_w, wall_height, wall_thickness), Transform3D(Basis.IDENTITY, north_c))
	_add_box_shape(root, Vector3(full_w, wall_height, wall_thickness), Transform3D(Basis.IDENTITY, south_c))
	_add_box_shape(root, Vector3(wall_thickness, wall_height, full_h), Transform3D(Basis.IDENTITY, west_c))
	_add_box_shape(root, Vector3(wall_thickness, wall_height, full_h), Transform3D(Basis.IDENTITY, east_c))

static func _add_box_shape(parent: Node, size: Vector3, xform: Transform3D) -> void:
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	cs.transform = xform
	parent.add_child(cs)

static func _reserved_at(res: PackedByteArray, x: int, z: int, w: int, h: int) -> bool:
	if res.is_empty(): return false
	if x < 0 or z < 0 or x >= w or z >= h: return false
	return res[MazeGen.idx(x, z, w)] != 0

# ---------- CLEANUP / PUNCH-OUT ----------
# Remove any per-tile FLOOR collider boxes whose (x,z) cell falls inside any of the rects.
# pad_cells expands each rect (0 = exact, 1 = include a 1-cell ring, etc.)
static func remove_floor_colliders_under_rects(
	root_owner: Node,
	gm_floor: GridMap,
	rects: Array,        # Array[Rect2i]
	pad_cells: int = 0,
	verbose: bool = false
) -> int:
	var root: Node = root_owner.get_node_or_null("FloorCollider")
	if root == null:
		return 0

	var inv: Transform3D = gm_floor.global_transform.affine_inverse()
	var removed: int = 0

	for child in root.get_children():
		var cs: CollisionShape3D = child as CollisionShape3D
		if cs == null:
			continue

		# Godot 4: use Transform3D * Vector3 (no xform())
		var local_pos: Vector3 = inv * cs.global_transform.origin
		var cell_v3i: Vector3i = gm_floor.local_to_map(local_pos)
		var p: Vector2i = Vector2i(cell_v3i.x, cell_v3i.z)

		for r_any in rects:
			var r: Rect2i = r_any as Rect2i
			var rr: Rect2i = Rect2i(
				r.position - Vector2i(pad_cells, pad_cells),
				r.size + Vector2i(pad_cells * 2, pad_cells * 2)
			)
			if rr.has_point(p):
				if verbose:
					print("[COL CLEAN] removing floor tile at cell=", p, " world=", cs.global_transform.origin)
				cs.queue_free()
				removed += 1
				break
	return removed

static func _build_floor_colliders_merged(
	open: PackedInt32Array,
	reserved: PackedByteArray,
	gm_floor: GridMap,
	parent: Node,
	w: int,
	h: int,
	floor_top_y: float
) -> void:
	var cell: float = gm_floor.cell_size.x
	var slab_h: float = 0.10
	var y: float = floor_top_y + slab_h * 0.5

	# track which tiles are already covered by a merged slab
	var used: PackedByteArray = PackedByteArray()
	used.resize(w * h) # zeros

	# local lambda instead of inner func
	var walkable := func(i: int) -> bool:
		if i < 0 or i >= w * h:
			return false
		if open[i] == 0:
			return false
		if reserved.size() > 0 and reserved[i] != 0:
			return false
		return true

	for z: int in range(h):
		for x: int in range(w):
			var i: int = MazeGen.idx(x, z, w)
			if not walkable.call(i): # <-- call the lambda
				continue
			if used[i] != 0:
				continue

			# grow width
			var run_w: int = 0
			while x + run_w < w:
				var i2: int = MazeGen.idx(x + run_w, z, w)
				if not walkable.call(i2) or used[i2] != 0:
					break
				run_w += 1

			# grow height while entire row qualifies
			var run_h: int = 1
			var can_expand: bool = true
			while z + run_h < h and can_expand:
				for dx: int in range(run_w):
					var ii: int = MazeGen.idx(x + dx, z + run_h, w)
					if not walkable.call(ii) or used[ii] != 0:
						can_expand = false
						break
				if can_expand:
					run_h += 1

			# mark used
			for dz: int in range(run_h):
				for dx: int in range(run_w):
					used[MazeGen.idx(x + dx, z + dz, w)] = 1

			# add one thin slab for the rectangle
			var size: Vector3 = Vector3(float(run_w) * cell, slab_h, float(run_h) * cell)
			var center_local: Vector3 = Vector3(float(x) * cell + size.x * 0.5, y, float(z) * cell + size.z * 0.5)
			var center_world: Vector3 = gm_floor.transform * center_local

			var cs: CollisionShape3D = CollisionShape3D.new()
			var box: BoxShape3D = BoxShape3D.new()
			box.size = size
			cs.shape = box
			cs.transform = Transform3D(Basis.IDENTITY, center_world)
			parent.add_child(cs)

# Returns (creating if needed) a container for floor colliders.
static func _get_or_make_floor_root(parent: Node) -> Node3D:
	var r := parent.get_node_or_null("FloorColliders") as Node3D
	if r == null:
		r = Node3D.new()
		r.name = "FloorColliders"
		parent.add_child(r)
	return r

static func _make_floor_body(name: String) -> StaticBody3D:
	var sb := StaticBody3D.new()
	sb.name = name
	sb.collision_layer = 1
	sb.collision_mask  = 1
	sb.add_to_group("gen_floor_col")  # tag everything we create
	return sb

static func clear_floor_colliders(root_owner: Node) -> int:
	var removed := 0
	# remove anything we tagged previously
	for n in root_owner.get_tree().get_nodes_in_group("gen_floor_col"):
		n.queue_free()
		removed += 1
	# also nuke the container if present (older builds)
	var old := root_owner.get_node_or_null("FloorCollider")
	if old:
		old.queue_free()
		removed += 1
	return removed
