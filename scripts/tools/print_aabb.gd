@tool
extends EditorScript
func _run():
	var sel = get_editor_interface().get_selection().get_selected_nodes()
	for n in sel:
		if n is MeshInstance3D:
			var a = n.get_aabb()
			print(n.get_path(), " size(m) = ", a.size)
