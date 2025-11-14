@tool
extends EditorScript
class_name BuildMonsters

# --- CONFIG ------------------------------------------------------------
const MONSTERS_ROOT: String = "res://art/monsters"
const MATERIAL_PATH: String = "res://art/monsters/common/materials/PBR_Default.tres"
const OVERWRITE_SCENES: bool = false          # true = recreate Enemy_{Name}.tscn if it exists
const MERGE_ANIMS_TO_DEFAULT: bool = false    # true = merge all clips into one library (key "")
const DEFAULT_LIB_KEY: String = ""            # "" = default library slot
# ----------------------------------------------------------------------

func _run() -> void:
	var root_dir := DirAccess.open(MONSTERS_ROOT)
	if root_dir == null:
		push_error("MONSTERS_ROOT not found: %s" % MONSTERS_ROOT); return

	var built: int = 0
	root_dir.list_dir_begin()
	while true:
		var entry := root_dir.get_next()
		if entry == "": break
		if not root_dir.current_is_dir(): continue
		if entry.begins_with("."): continue

		var monster_dir := MONSTERS_ROOT.path_join(entry)            # e.g., .../BattleBee
		if entry == "common": continue

		var ok := _build_one(monster_dir, entry)
		if ok: built += 1
	root_dir.list_dir_end()
	print("BuildMonsters: finished. Built %d wrappers." % built)


func _build_one(monster_dir: String, enemy_name: String) -> bool:
	var wrapper_path := monster_dir.path_join("Enemy_%s.tscn" % enemy_name)
	if FileAccess.file_exists(wrapper_path) and not OVERWRITE_SCENES:
		print("Skip (exists): %s" % wrapper_path)
		return false

	# 1) Find a mesh FBX in the monster folder (prefer *Mesh.fbx)
	var mesh_path := _find_mesh_fbx(monster_dir)
	if mesh_path.is_empty():
		push_warning("No *Mesh.fbx in %s" % monster_dir)
		return false

	var mesh_scene := load(mesh_path) as PackedScene
	if mesh_scene == null:
		push_warning("Failed to load mesh scene: %s" % mesh_path)
		return false

	# 2) Build wrapper
	var wrapper_root := Node3D.new()
	wrapper_root.name = "Enemy%s" % enemy_name

	var mesh_inst := mesh_scene.instantiate() as Node3D
	mesh_inst.name = "%s_Mesh" % enemy_name
	wrapper_root.add_child(mesh_inst)
	_set_owner_recursive(mesh_inst, wrapper_root)

	# 3) Add AnimationPlayer on wrapper and set Root Node to the mesh node
	var ap := AnimationPlayer.new()
	ap.name = "AnimationPlayer"
	wrapper_root.add_child(ap)
	ap.owner = wrapper_root
	ap.root_node = NodePath(mesh_inst.name)  # target the *Mesh node

	# 4) Apply shared material to every MeshInstance3D under the mesh instance
	var mat := load(MATERIAL_PATH) as Material
	if mat == null:
		push_warning("MATERIAL_PATH missing: %s" % MATERIAL_PATH)
	else:
		var applied: int = _apply_material_recursive(mesh_inst, mat)
		print("Applied material to %d MeshInstance3D nodes in %s." % [applied, enemy_name])

	# 5) Load animation libraries from /animations (if present)
	var anims_dir := monster_dir.path_join("animations")
	var added := _load_anim_libs(ap, anims_dir)
	if added == 0:
		print("No animation libraries found in %s (remember to import as Animation Library + Skeleton Bones)." % anims_dir)

	# 6) Save wrapper
	var ps := PackedScene.new()
	var ok := ps.pack(wrapper_root)
	if not ok:
		push_error("Failed to pack scene for %s" % enemy_name)
		return false

	var err := ResourceSaver.save(ps, wrapper_path)
	if err != OK:
		push_error("Failed to save wrapper: %s (err=%d)" % [wrapper_path, err])
		return false

	print("Built: %s  (mesh=%s, anim_libs=%d)" % [wrapper_path, mesh_path.get_file(), added])
	return true


func _find_mesh_fbx(dir_path: String) -> String:
	var d := DirAccess.open(dir_path)
	if d == null: return ""
	var fallback := ""
	d.list_dir_begin()
	while true:
		var name := d.get_next()
		if name == "": break
		if d.current_is_dir(): continue
		var lower := name.to_lower()
		if not lower.ends_with(".fbx"): continue
		if lower.ends_with("_mesh.fbx") or lower.ends_with("mesh.fbx"):
			d.list_dir_end()
			return dir_path.path_join(name)
		if fallback.is_empty():
			fallback = dir_path.path_join(name)
	d.list_dir_end()
	return fallback


func _apply_material_recursive(node: Node, mat: Material) -> int:
	var count := 0
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		mi.material_override = mat
		count += 1
	for child in node.get_children():
		count += _apply_material_recursive(child, mat)
	return count


func _load_anim_libs(ap: AnimationPlayer, anims_dir: String) -> int:
	var dir := DirAccess.open(anims_dir)
	if dir == null: return 0

	var master := AnimationLibrary.new()
	var added_libs := 0
	var merged := 0

	dir.list_dir_begin()
	while true:
		var fname := dir.get_next()
		if fname == "": break
		if dir.current_is_dir(): continue
		if not fname.to_lower().ends_with(".fbx"): continue

		var path := anims_dir.path_join(fname)
		var res := ResourceLoader.load(path)
		if res is AnimationLibrary:
			var lib := res as AnimationLibrary
			if MERGE_ANIMS_TO_DEFAULT:
				for anim_name in lib.get_animation_list():
					var dst := anim_name.strip_edges()
					if master.has_animation(dst):
						dst = "%s__%s" % [dst, fname.get_basename()]
					master.add_animation(dst, lib.get_animation(anim_name).duplicate(true))
					merged += 1
			else:
				var key := fname.get_basename()
				ap.add_animation_library(key, lib)
				added_libs += 1
				print("  + Library: %s" % key)
		else:
			push_warning("  ! %s is %s (reimport as Animation Library + Skeleton Bones)" % [path, res.get_class()])
	dir.list_dir_end()

	if MERGE_ANIMS_TO_DEFAULT and master.get_animation_list().size() > 0:
		ap.add_animation_library(DEFAULT_LIB_KEY, master)
		print("  + Merged %d clips into key '%s'." % [merged, DEFAULT_LIB_KEY])
		return master.get_animation_list().size()
	return added_libs


func _set_owner_recursive(n: Node, owner: Node) -> void:
	n.owner = owner
	for c in n.get_children():
		_set_owner_recursive(c, owner)
