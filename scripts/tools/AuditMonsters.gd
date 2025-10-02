@tool
extends EditorScript
class_name AuditMonsters

const ROOT_DIR: String = "res://art/monsters"
const MATERIAL_PATH: String = "res://art/monsters/common/materials/PBR_Default.tres"

# Required/optional animation keys → acceptable clip name substrings
static var REQUIRED: Dictionary = {
	"idle":   PackedStringArray(["IdleBattle", "IdleNormal", "Idle"]),
	"move":   PackedStringArray(["RunFWD", "WalkFWD", "FlyFWD", "Hover", "Run", "Walk"]),
	"attack": PackedStringArray(["Attack01", "Attack1", "Attack", "Attack02"]),
	"hit":    PackedStringArray(["GetHit", "Hit", "Damage"]),
	"die":    PackedStringArray(["Die", "Death"])
}
static var OPTIONAL: Dictionary = {
	"taunt":   PackedStringArray(["Taunting", "Roar", "Roar01"]),
	"victory": PackedStringArray(["Victory", "Win"])
}

func _run() -> void:
	var rows: Array[String] = []
	rows.append("Name,SceneOK,MeshNode,LibCount,Idle,Move,Attack,Hit,Die,Optional_Taunt,Optional_Victory,MatOK,MeshCount")

	var d: DirAccess = DirAccess.open(ROOT_DIR)
	if d == null:
		push_error("Missing folder: %s" % ROOT_DIR)
		return

	d.list_dir_begin()
	while true:
		var entry: String = d.get_next()
		if entry == "":
			break
		if not d.current_is_dir():
			continue
		if entry == "common" or entry.begins_with("."):
			continue

		var monster_dir: String = ROOT_DIR.path_join(entry)
		var scene_path: String = monster_dir.path_join("Enemy_%s.tscn" % entry)
		if not FileAccess.file_exists(scene_path):
			rows.append("%s,false,,,,,,,,,,," % entry)
			continue

		var scene: PackedScene = load(scene_path) as PackedScene
		if scene == null:
			rows.append("%s,false,,,,,,,,,,," % entry)
			continue

		var inst: Node = scene.instantiate()
		var mesh_host: Node = null
		if inst.get_child_count() > 0:
			mesh_host = inst.get_child(0)

		var ap: AnimationPlayer = null
		if mesh_host != null:
			ap = mesh_host.get_node_or_null("AnimationPlayer") as AnimationPlayer

		var libs_count: int = 0
		var have: Dictionary = {
			"idle": false, "move": false, "attack": false, "hit": false, "die": false,
			"taunt": false, "victory": false
		}

		if ap != null:
			var clips: PackedStringArray = _collect_clip_names(ap)
			libs_count = ap.get_animation_library_list().size()
			for key in REQUIRED.keys():
				var pats: PackedStringArray = REQUIRED[key]
				have[key] = _has_any(clips, pats)
			for key_opt in OPTIONAL.keys():
				var pats2: PackedStringArray = OPTIONAL[key_opt]
				if _has_any(clips, pats2):
					have[key_opt] = true

		# Material check across all MeshInstance3D under the mesh host
		var mat_ok: bool = false
		var mesh_count: int = 0
		if mesh_host != null:
			var target_mat: Material = load(MATERIAL_PATH) as Material
			var totals: Vector2i = _count_mesh_and_with_material(mesh_host, target_mat)
			mesh_count = totals.x
			var with_mat: int = totals.y
			mat_ok = (mesh_count > 0 and with_mat == mesh_count)

		var mesh_host_name: String = ""
		if mesh_host != null:
			mesh_host_name = mesh_host.name

		rows.append("%s,%s,%s,%d,%s,%s,%s,%s,%s,%s,%s,%s,%d" % [
			entry,
			"true",
			mesh_host_name,
			libs_count,
			_bool(have["idle"]),
			_bool(have["move"]),
			_bool(have["attack"]),
			_bool(have["hit"]),
			_bool(have["die"]),
			_bool(have["taunt"]),
			_bool(have["victory"]),
			_bool(mat_ok),
			mesh_count
		])

		inst.free()
	d.list_dir_end()

	var content: String = ""
	for i in range(rows.size()):
		if i > 0:
			content += "\n"
		content += rows[i]

	var out: FileAccess = FileAccess.open("res://monster_audit.csv", FileAccess.WRITE)
	if out:
		out.store_string(content)
		out.close()
	print("Audit complete → res://monster_audit.csv")

# --- helpers --------------------------------------------------------

func _collect_clip_names(ap: AnimationPlayer) -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	for lib_key: StringName in ap.get_animation_library_list():
		var lib: AnimationLibrary = ap.get_animation_library(lib_key)
		for n: StringName in lib.get_animation_list():
			names.append(String(n))
	return names

func _has_any(clips: PackedStringArray, patterns: PackedStringArray) -> bool:
	for p: String in patterns:
		for c: String in clips:
			if c.findn(p) != -1:
				return true
	return false

# Returns Vector2i(total_meshes, meshes_with_target_material)
func _count_mesh_and_with_material(node: Node, target_mat: Material) -> Vector2i:
	var total: int = 0
	var with_mat: int = 0
	var stack: Array[Node] = [node]
	while stack.size() > 0:
		var n: Node = stack.pop_back() as Node
		if n is MeshInstance3D:
			total += 1
			var mi: MeshInstance3D = n as MeshInstance3D
			if target_mat != null and mi.material_override == target_mat:
				with_mat += 1
		for child: Node in n.get_children():
			stack.push_back(child)
	return Vector2i(total, with_mat)

func _bool(b: bool) -> String:
	return "OK" if b else ""
