extends RefCounted
class_name DungeonReset

# --- small helpers -----------------------------------------------------------

static func _to_path(v) -> NodePath:
	# Accept NodePath, String, or StringName and normalize to NodePath
	if v is NodePath:
		return v
	return NodePath(str(v))

static func _free_node(n: Node) -> void:
	if n == null: return
	var p := n.get_parent()
	if p: p.remove_child(n)
	n.free()  # free immediately (deterministic for rebuilds)

# --- runtime prefabs ---------------------------------------------------------

static func ensure_runtime_root(dungeon: Node, path="RuntimePrefabs") -> Node3D:
	var np := _to_path(path)
	var r := dungeon.get_node_or_null(np) as Node3D
	if r == null:
		r = Node3D.new()
		# name from last segment (works fine for simple names)
		r.name = str(np)
		dungeon.add_child(r)
	return r

static func clear_runtime_prefabs(dungeon: Node, path="RuntimePrefabs") -> int:
	var np := _to_path(path)
	var r := dungeon.get_node_or_null(np)
	if r == null:
		#print("[Reset] no ", str(np), " container to clear")
		return 0
	var cnt := r.get_child_count()
	for c in r.get_children():
		_free_node(c)
	#print("[Reset] cleared ", str(np), " children=", cnt)
	return cnt

# --- baked (editor) prefabs --------------------------------------------------

static func purge_baked_prefabs(dungeon: Node, baked_root_path="Prefabs") -> int:
	var np := _to_path(baked_root_path)
	var p := dungeon.get_node_or_null(np)
	if p == null:
		#print("[Reset] no baked Prefabs at ", str(np))
		return 0
	var kids := p.get_children()
	for n in kids:
		_free_node(n)
	#print("[Reset] purged baked Prefabs children=", kids.size())
	return kids.size()

# --- wall pieces -------------------------------------------------------------

static func clear_wall_pieces(dungeon: Node, node_path="WallPieces") -> int:
	var np := _to_path(node_path)
	var wp := dungeon.get_node_or_null(np)
	if wp == null:
		#print("[Reset] no ", str(np), " to clear")
		return 0
	var cnt := (wp as Node).get_child_count()
	_free_node(wp)  # remove the whole container; generator will recreate it
	#print("[Reset] removed ", str(np), " (children=", cnt, ")")
	return cnt

# --- colliders ---------------------------------------------------------------

static func clear_common_colliders(dungeon: Node) -> void:
	var names := ["RoomColliders", "WallColliders", "FloorColliders", "PerimeterColliders"]
	var removed := 0
	for nm in names:
		var n := dungeon.get_node_or_null(_to_path(nm))
		if n != null:
			_free_node(n)
			removed += 1
	#if removed > 0:
		#print("[Reset] removed collider roots count=", removed)

# --- gridmaps (optional) -----------------------------------------------------

static func clear_gridmaps(gridmaps: Array) -> void:
	for g in gridmaps:
		if g != null and g.has_method("clear"):
			g.clear()
	#print("[Reset] gridmaps cleared: ", gridmaps.size())

# --- one-shot entry point ----------------------------------------------------

static func pre_generate_cleanup(dungeon: Node, opts: Dictionary = {}) -> void:
	var baked_root_path     = opts.get("baked_root_path", "Prefabs")
	var runtime_root_name   = opts.get("runtime_root_name", "RuntimePrefabs")
	var wallpieces_name     = opts.get("wallpieces_name", "WallPieces")
	var also_clear_colliders: bool = opts.get("also_clear_colliders", true)
	var clear_gridmaps_flag: bool  = opts.get("clear_gridmaps", false)
	var gridmaps: Array           = opts.get("gridmaps", [])

	purge_baked_prefabs(dungeon, baked_root_path)
	clear_runtime_prefabs(dungeon, runtime_root_name)
	clear_wall_pieces(dungeon, wallpieces_name)
	if also_clear_colliders:
		clear_common_colliders(dungeon)
	if clear_gridmaps_flag and gridmaps.size() > 0:
		clear_gridmaps(gridmaps)
