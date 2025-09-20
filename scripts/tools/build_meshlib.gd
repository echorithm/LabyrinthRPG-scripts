@tool
extends EditorScript

@export var library_path: String = "res://rooms/pieces/dungeon.meshlib"  # <-- make sure this matches what your GridMap uses

func _run() -> void:
	var lib: MeshLibrary = _load_or_create(library_path)

	# next free id
	var next_id := 0
	for i in lib.get_item_list():
		if i >= next_id:
			next_id = i + 1

	var sel := get_editor_interface().get_selection().get_selected_nodes()
	var added := 0
	for n in sel:
		if n is MeshInstance3D and n.mesh:
			lib.create_item(next_id)
			lib.set_item_name(next_id, n.name)
			lib.set_item_mesh(next_id, n.mesh)

			var shape: Shape3D = n.mesh.create_trimesh_shape()
			if shape != null:
				lib.set_item_shapes(next_id, [shape])  # 4.4: just (id, shapes)

			print("Added:", next_id, n.name)
			next_id += 1
			added += 1
		else:
			print("Skipped (not MeshInstance3D):", n)

	var err := ResourceSaver.save(lib, library_path)
	print("Saved:", library_path, "  items:", lib.get_item_list().size(), "  added:", added, "  err:", err)

func _load_or_create(path: String) -> MeshLibrary:
	if ResourceLoader.exists(path):
		var r := ResourceLoader.load(path)
		if r is MeshLibrary:
			return r
	return MeshLibrary.new()
