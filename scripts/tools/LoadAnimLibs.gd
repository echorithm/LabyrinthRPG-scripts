@tool
extends EditorScript
class_name BulkLoadAnimLibsAuto

# ------------ Config ---------------------------------------------------
const MERGE_TO_DEFAULT := false         # true → merge all clips into one library (key DEFAULT_KEY)
const DEFAULT_KEY := ""                 # when MERGE_TO_DEFAULT=true, which key to use on the AnimationPlayer
const RENAME_SINGLE_CLIP_TO_KEY := false# if a lib has one clip named "Take 001", rename it to the library key
const MATERIAL_PATH := "res://art/monsters/common/materials/PBR_Default.tres"

const WRITE_MANIFEST := true            # write a JSON manifest next to the .tscn
const MANIFEST_NAME := "anim_manifest.json"
# ----------------------------------------------------------------------

func _run() -> void:
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		push_error("Open your enemy scene (e.g., bat.tscn) and run this script again.")
		return
	if root.scene_file_path.is_empty():
		push_error("Save the scene first.")
		return
	if root.get_child_count() == 0:
		push_error("Root has no children. Expected your *Mesh parent as the first child.")
		return

	# Host node = first child of the scene (e.g., BatMesh / SpiderMesh / etc.)
	var host: Node = root.get_child(0)

	# Ensure /animations folder exists next to the scene
	var scene_dir := root.scene_file_path.get_base_dir()
	var anims_dir := scene_dir.path_join("animations")

	# Find or create AnimationPlayer directly under the host (or anywhere below it)
	var ap := _find_ap_under(host)
	var created_ap := false
	if ap == null:
		ap = AnimationPlayer.new()
		ap.name = "AnimationPlayer"
		host.add_child(ap)
		ap.owner = root
		created_ap = true
		print("Created AnimationPlayer under %s" % host.name)
	# Drive the host (parent of the AnimationPlayer)
	ap.root_node = NodePath("..")

	# Apply shared material to all MeshInstance3D under host
	var mat: Material = load(MATERIAL_PATH) as Material
	var material_applied_to := 0
	if mat == null:
		push_warning("Material not found: %s" % MATERIAL_PATH)
	else:
		material_applied_to = _apply_materials_recursive(host, mat)
		print("Applied material to %d MeshInstance3D nodes under %s." % [material_applied_to, host.name])

	# ---- Load animation libraries from /animations ----
	var dir := DirAccess.open(anims_dir)
	if dir == null:
		push_error("Animations folder not found: %s" % anims_dir)
		return

	print("Scanning %s" % anims_dir)
	var added_libs := 0
	var merged_count := 0
	var master := AnimationLibrary.new()
	var lib_paths: Dictionary = {}  # library key -> resource_path (for manifest)

	dir.list_dir_begin()
	while true:
		var fname := dir.get_next()
		if fname == "":
			break
		if dir.current_is_dir():
			continue
		if not fname.to_lower().ends_with(".fbx"):
			continue

		var fpath := anims_dir.path_join(fname)
		var res := ResourceLoader.load(fpath)
		if res == null:
			push_warning("Could not load: %s" % fpath)
			continue

		if res is AnimationLibrary:
			var lib := res as AnimationLibrary

			# Optional: if the library has a single clip, rename "Take 001" → library key
			if RENAME_SINGLE_CLIP_TO_KEY and not MERGE_TO_DEFAULT:
				var names := lib.get_animation_list()
				if names.size() == 1:
					var only := String(names[0])
					var key_from_file := fname.get_basename()
					if only != key_from_file and not lib.has_animation(key_from_file):
						var anim := lib.get_animation(only)
						lib.remove_animation(only)
						lib.add_animation(key_from_file, anim)
						print("Renamed clip '%s' -> '%s' in %s" % [only, key_from_file, fname])

			if MERGE_TO_DEFAULT:
				for nm in lib.get_animation_list():
					var dst := String(nm).strip_edges()
					if master.has_animation(dst):
						dst = "%s__%s" % [dst, fname.get_basename()]
					var anim: Animation = lib.get_animation(nm)
					master.add_animation(dst, anim.duplicate(true))
					merged_count += 1
				lib_paths[DEFAULT_KEY] = "(merged)"
			else:
				var key := fname.get_basename()
				ap.add_animation_library(key, lib)
				lib_paths[key] = lib.resource_path
				added_libs += 1
				print("Added library: %s" % key)
		else:
			push_warning("Skipping %s (type: %s). Reimport FBX as 'Animation Library' with 'Import as Skeleton Bones' ON." % [fpath, res.get_class()])
	dir.list_dir_end()

	if MERGE_TO_DEFAULT and master.get_animation_list().size() > 0:
		ap.add_animation_library(DEFAULT_KEY, master)
		print("Merged %d animations into library key '%s'." % [merged_count, DEFAULT_KEY])
	else:
		print("Added %d Animation Libraries." % added_libs)

	print("Done → AnimationPlayer (under %s) now has your clips." % host.name)

	# ---- Write JSON manifest ------------------------------------------------
	if WRITE_MANIFEST:
		var manifest := _build_manifest_json(root, host, ap, scene_dir, anims_dir, lib_paths, material_applied_to, created_ap)
		_write_manifest(scene_dir, manifest)


# =============== Helpers =====================================================

func _find_ap_under(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for c in node.get_children():
		var ap := _find_ap_under(c)
		if ap != null:
			return ap
	return null

func _apply_materials_recursive(node: Node, mat: Material) -> int:
	var count := 0
	if node is MeshInstance3D:
		(node as MeshInstance3D).material_override = mat
		count += 1
	for child in node.get_children():
		count += _apply_materials_recursive(child, mat)
	return count

func _build_manifest_json(
		root: Node,
		host: Node,
		ap: AnimationPlayer,
		scene_dir: String,
		anims_dir: String,
		lib_paths: Dictionary,
		material_applied_to: int,
		created_ap: bool
	) -> Dictionary:

	var mesh_info := _find_mesh_info(root, host, scene_dir)

	var libs: Array = []
	var anims: Array = []
	var total := 0

	for key in ap.get_animation_library_list():
		var lib: AnimationLibrary = ap.get_animation_library(key)
		var lib_res_path := lib.resource_path
		if lib_paths.has(key):
			lib_res_path = String(lib_paths[key])

		libs.append({
			"key": key,
			"resource_path": lib_res_path,
			"animation_count": lib.get_animation_list().size()
		})

		for nm in lib.get_animation_list():
			var a: Animation = lib.get_animation(nm)
			var play_str := "%s/%s" % [key, nm]
			anims.append({
				"library_key": key,
				"clip_name": nm,
				"play": play_str,
				"length": a.length,
				"tracks": a.get_track_count(),
				"loop": a.loop_mode != Animation.LOOP_NONE
			})
			total += 1

	return {
		"generated_at": Time.get_datetime_string_from_system(true),
		"scene_path": root.scene_file_path,
		"scene_dir": scene_dir,
		"host_node": {
			"name": host.name,
			"path_from_root": String(root.get_path_to(host)),
			"type": host.get_class()
		},
		"skeleton_path": _find_first_skeleton_path(host),
		"mesh": mesh_info,  # {file, resource_path, node_path, guessed_fbx}
		"material": {
			"path": MATERIAL_PATH,
			"applied_to_count": material_applied_to
		},
		"animation_player": {
			"created_this_run": created_ap,
			"root_node": String(ap.root_node)
		},
		"animations_dir": anims_dir,
		"libraries": libs,
		"animations": anims,
		"counts": {
			"libraries": libs.size(),
			"animations": total
		}
	}

func _write_manifest(scene_dir: String, data: Dictionary) -> void:
	var path := scene_dir.path_join(MANIFEST_NAME)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("Failed to open %s for writing." % path)
		return
	# Pretty JSON
	f.store_string(JSON.stringify(data, "  "))
	f.store_string("\n")
	f.close()
	print("Wrote manifest: %s" % path)

func _find_mesh_info(root: Node, host: Node, scene_dir: String) -> Dictionary:
	var mesh_inst := _find_first_mesh(host)
	if mesh_inst == null:
		return {"file": "", "resource_path": "", "node_path": "", "guessed_fbx": ""}

	var res_path := ""
	if mesh_inst.mesh:
		res_path = mesh_inst.mesh.resource_path  # may be FBX subresource or TSCN subresource

	var guessed := _guess_mesh_fbx(scene_dir, root.scene_file_path.get_file().get_basename())

	return {
		"file": root.scene_file_path,                 # the .tscn that owns this
		"resource_path": res_path,                    # actual mesh resource assigned
		"node_path": String(root.get_path_to(mesh_inst)),
		"guessed_fbx": guessed                        # best-guess original FBX next to the scene
	}

func _find_first_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for c in node.get_children():
		var found := _find_first_mesh(c)
		if found != null:
			return found
	return null

func _find_first_skeleton_path(node: Node) -> String:
	if node is Skeleton3D:
		return String((node as Skeleton3D).get_path())
	for c in node.get_children():
		var p := _find_first_skeleton_path(c)
		if p != "":
			return p
	return ""

func _guess_mesh_fbx(scene_dir: String, scene_base: String) -> String:
	var candidates: Array[String] = []
	var d := DirAccess.open(scene_dir)
	if d:
		d.list_dir_begin()
		while true:
			var f := d.get_next()
			if f == "":
				break
			if d.current_is_dir():
				continue
			var low := f.to_lower()
			if low.ends_with(".fbx"):
				candidates.append(f)
		d.list_dir_end()

	if candidates.is_empty():
		return ""

	# Prefer names containing "mesh"
	for c in candidates:
		if c.to_lower().contains("mesh"):
			return scene_dir.path_join(c)

	# Prefer those starting with scene base name (e.g., bat_mesh.fbx for bat.tscn)
	var base := scene_base.to_lower()
	for c in candidates:
		if c.to_lower().begins_with(base):
			return scene_dir.path_join(c)

	# Single candidate?
	if candidates.size() == 1:
		return scene_dir.path_join(candidates[0])

	# Fallback: first one
	return scene_dir.path_join(candidates[0])
