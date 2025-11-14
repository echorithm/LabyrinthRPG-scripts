extends Object
class_name DungeonPainter

# Minimal floor painter + metrics. No wall visuals.

static func paint_grid(
	gm_floor: GridMap,
	gm_walls: GridMap,
	open: PackedInt32Array,
	width: int,
	height: int,
	id_floor: int,
	id_wall: int,
	reserved: PackedByteArray = PackedByteArray(),
	_debug_wall_trace: bool = false   # kept for signature-compat
) -> Dictionary:
	# --- reset gridmaps ---
	gm_floor.clear()
	gm_walls.clear()
	gm_floor.collision_layer = 1
	gm_floor.collision_mask = 1
	gm_walls.collision_layer = 1
	gm_walls.collision_mask = 1

	# Purge any stale DungeonPainter visual leftovers from prior floors.
	# (We never create these now, but this guarantees no artifacts remain.)
	for c in gm_walls.get_children():
		if c is Node and (c as Node).name.begins_with("WallsVisual"):
			gm_walls.remove_child(c)
			c.free()

	var lib: MeshLibrary = gm_floor.mesh_library

	# Floor top Y in world space (taken from the floor mesh in cell 0,0)
	var floor_top_y: float = MeshLibTools.compute_floor_top_y_world(gm_floor, id_floor)

	# Derive wall dimensions from the wall mesh so ColliderBuilder can size boxes.
	var wall_thickness: float = 1.0
	var wall_height: float = 4.0
	if lib != null and id_wall >= 0:
		var wall_mesh: Mesh = lib.get_item_mesh(id_wall)
		if wall_mesh != null:
			var aabb: AABB = wall_mesh.get_aabb()
			# Thickness is the thin side in X/Z; height is Y.
			wall_thickness = min(aabb.size.x, aabb.size.z)
			wall_height = aabb.size.y

	# Force refresh (common Godot quirk when swapping libraries at runtime)
	gm_floor.mesh_library = gm_floor.mesh_library
	gm_walls.mesh_library = gm_walls.mesh_library

	# --- paint floors only where maze is open and not reserved (holes allowed) ---
	for z in range(height):
		for x in range(width):
			var i: int = MazeGen.idx(x, z, width)
			if open[i] == 0:
				continue
			if reserved.size() > 0 and reserved[i] != 0:
				continue
			gm_floor.set_cell_item(Vector3i(x, 0, z), id_floor, 0)

	# No wall visuals here. Wall meshes come from _skin_walls_with_pieces().
	# Colliders are built by ColliderBuilder using the values below.
	return {
		"floor_top_y": floor_top_y,
		"wall_thickness": wall_thickness,
		"wall_height": wall_height
	}
