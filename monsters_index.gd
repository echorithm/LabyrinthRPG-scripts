# res://tools/MonstersAuditTool.gd
@tool
extends EditorScript
class_name MonstersAuditTool

const ROOT_DIR        : String = "res://art/monsters"
const OUTPUT_INDEX    : String = "res://art/monsters/_monsters_index.json" # must be literal for const
const SKIP_FOLDERS    : Array[String] = ["common", ".godot"]
const META_CANDIDATES : Array[String] = ["monster.json", "meta.json"]

func _run() -> void:
	var warnings: Array[String] = []
	var out: Dictionary = {
		"generated_at": Time.get_datetime_string_from_system(false, true),
		"root": ROOT_DIR,
		"monsters": [] # will append dictionaries
	}

	var dir := DirAccess.open(ROOT_DIR)
	if dir == null:
		push_error("Missing root folder: %s" % ROOT_DIR)
		return

	dir.list_dir_begin()
	while true:
		var name := dir.get_next()
		if name == "": break
		if not dir.current_is_dir(): continue
		if name.begins_with(".") or name in SKIP_FOLDERS: continue

		var folder := ROOT_DIR.path_join(name)
		var entry: Dictionary = _audit_monster(folder, warnings)
		(out["monsters"] as Array).append(entry)
	dir.list_dir_end()

	# write combined index
	var f := FileAccess.open(OUTPUT_INDEX, FileAccess.WRITE)
	if f == null:
		push_error("Cannot write index: %s" % OUTPUT_INDEX)
		return
	f.store_string(JSON.stringify(out, "  "))
	f.close()
	print("Wrote: %s" % OUTPUT_INDEX)

	if warnings.size() > 0:
		push_warning("Audit produced %d warnings." % warnings.size())
		for w in warnings:
			print_rich("[color=yellow]- %s[/color]" % w)
	else:
		print("Audit OK: no warnings.")

func _audit_monster(folder: String, warnings: Array[String]) -> Dictionary:
	var info: Dictionary = {
		"folder": folder,
		"slug": folder.get_file(),
		"scene_path": "",
		"host_node": "",
		"has_animation_player": false,
		"libraries": [],   # Array of { key, count }
		"animations": [],  # Array of { play, length, tracks }
		"meta_path": "",
		"meta_ok": false,
		"issues": []       # Array of String tags
	}

	# find first .tscn
	var scene_path := _find_first_with_ext(folder, "tscn")
	if scene_path == "":
		(info["issues"] as Array).append("missing_scene")
		warnings.append("No .tscn in %s" % folder)
		return info
	info["scene_path"] = scene_path

	# load scene
	var packed := load(scene_path) as PackedScene
	if packed == null:
		(info["issues"] as Array).append("scene_load_failed")
		warnings.append("Failed to load scene: %s" % scene_path)
		return info

	var root := packed.instantiate()
	if root == null or root.get_child_count() == 0:
		(info["issues"] as Array).append("no_children_on_root")
		warnings.append("Root has no children: %s" % scene_path)
		return info

	var host := root.get_child(0)
	info["host_node"] = host.name

	var ap := host.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if ap == null:
		(info["issues"] as Array).append("no_animation_player")
	else:
		info["has_animation_player"] = true
		for key in ap.get_animation_library_list():
			var lib := ap.get_animation_library(key)
			var anim_names := lib.get_animation_list()
			(info["libraries"] as Array).append({ "key": key, "count": anim_names.size() })
			for an in anim_names:
				var a := lib.get_animation(an)
				(info["animations"] as Array).append({
					"play": "%s/%s" % [key, an],
					"length": a.length,
					"tracks": a.get_track_count()
				})
		if (info["animations"] as Array).size() == 0:
			(info["issues"] as Array).append("no_animations")
			warnings.append("No animations in %s" % scene_path)

	# optional per-folder meta json
	var meta_path := _find_meta_json(folder)
	if meta_path != "":
		info["meta_path"] = meta_path
		var s := FileAccess.get_file_as_string(meta_path)
		var parsed: Variant = JSON.parse_string(s)
		if parsed is Dictionary:
			var pd := parsed as Dictionary
			if pd.has("scene_path") and String(pd["scene_path"]) == scene_path:
				info["meta_ok"] = true
			else:
				(info["issues"] as Array).append("meta_scene_mismatch")
				warnings.append("Meta scene mismatch: %s" % meta_path)

			if pd.has("counts") and pd["counts"] is Dictionary and (pd["counts"] as Dictionary).has("libraries"):
				var want: int = int((pd["counts"] as Dictionary)["libraries"])
				var got: int = int((info["libraries"] as Array).size())
				if want != got:
					(info["issues"] as Array).append("meta_library_count_mismatch")
					warnings.append("[%s] Library count mismatch (meta:%d, got:%d)" % [folder.get_file(), want, got])
		else:
			(info["issues"] as Array).append("meta_parse_failed")
			warnings.append("Could not parse meta json: %s" % meta_path)
	else:
		(info["issues"] as Array).append("no_meta_json")

	return info

func _find_first_with_ext(folder: String, ext: String) -> String:
	var d := DirAccess.open(folder)
	if d == null: return ""
	d.list_dir_begin()
	while true:
		var f := d.get_next()
		if f == "": break
		if d.current_is_dir(): continue
		if f.to_lower().ends_with("." + ext.to_lower()):
			d.list_dir_end()
			return folder.path_join(f)
	d.list_dir_end()
	return ""

func _find_meta_json(folder: String) -> String:
	for cand in META_CANDIDATES:
		var p := folder.path_join(cand)
		if FileAccess.file_exists(p):
			return p
	var d := DirAccess.open(folder)
	if d == null: return ""
	d.list_dir_begin()
	while true:
		var f := d.get_next()
		if f == "": break
		if d.current_is_dir(): continue
		if f.to_lower().ends_with(".json"):
			d.list_dir_end()
			return folder.path_join(f)
	d.list_dir_end()
	return ""
