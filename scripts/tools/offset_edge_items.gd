@tool
extends EditorScript
@export var library_path := "res://rooms/pieces/dungeon.meshlib"

func _run() -> void:
	var lib: MeshLibrary = ResourceLoader.load(library_path)
	assert(lib)
	for id in lib.get_item_list():
		var name := lib.get_item_name(id).to_lower()
		var xf := Transform3D()
		if (name.contains("wall") and not name.contains("corner")) or name.contains("doorway"):
			xf.origin.z = -2.0   # 4 m cell -> move half a cell to sit on border
		lib.set_item_transform(id, xf)
		print("Set transform for", lib.get_item_name(id), ":", xf.origin)
	var err := ResourceSaver.save(lib, library_path)
	if err != OK: push_error("Save failed")
