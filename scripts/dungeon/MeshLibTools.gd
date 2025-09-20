extends Object
class_name MeshLibTools

static func find_any(lib: MeshLibrary, needles: PackedStringArray) -> int:
	for n: String in needles:
		var nl: String = n.to_lower()
		for id: int in lib.get_item_list():
			if lib.get_item_name(id).to_lower() == nl:
				return id
	for n2: String in needles:
		var nl2: String = n2.to_lower()
		for id2: int in lib.get_item_list():
			if lib.get_item_name(id2).to_lower().find(nl2) != -1:
				return id2
	return -1

static func yaw_to_orient(deg90_steps: int, which: GridMap) -> int:
	var steps: int = (deg90_steps % 4 + 4) % 4
	var yaw: float = deg_to_rad(90.0 * float(steps))
	var b: Basis = Basis(Vector3.UP, yaw)
	return which.get_orthogonal_index_from_basis(b)

# Floor top in WORLD space at GridMap cell (0,0,0)
static func compute_floor_top_y_world(gm_floor: GridMap, id_floor: int) -> float:
	var lib: MeshLibrary = gm_floor.mesh_library
	var mesh: Mesh = lib.get_item_mesh(id_floor)
	if mesh == null:
		return 0.0
	var bb: AABB = mesh.get_aabb()
	var t_item: Transform3D = lib.get_item_mesh_transform(id_floor)
	var cell0_local: Vector3 = gm_floor.map_to_local(Vector3i(0, 0, 0))
	var cell0_world: Vector3 = gm_floor.transform * cell0_local
	return cell0_world.y + t_item.origin.y + bb.position.y + bb.size.y

static func dump_items(lib: MeshLibrary) -> void:
	print("--- MeshLibrary items ---")
	for id: int in lib.get_item_list():
		print(id, ": ", lib.get_item_name(id))
