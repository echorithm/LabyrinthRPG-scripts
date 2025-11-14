extends Node3D

signal finish_triggered

const DungeonReset = preload("res://scripts/dungeon/DungeonReset.gd")

# ---------------- Nodes ----------------
@onready var gm_floor: GridMap       = get_node_or_null("GridFloors") as GridMap
@onready var gm_walls: GridMap       = get_node_or_null("GridWalls") as GridMap
@onready var gm_ceilings: GridMap    = get_node_or_null("GridCeilings") as GridMap
@onready var light_mgr: DungeonLight = get_node_or_null("DungeonLight") as DungeonLight

@export var level_manager_path: NodePath
@export var light_mgr_path: NodePath   # optional; assign a DungeonLight node here if you like

# ---------------- Generation params ----------------
@export var width: int = 11
@export var height: int = 11
@export var loop_percent: float = 5.0
@export var room_max: int = 1
@export var room_attempts: int = 1
@export var ensure_prefab_paths: bool = true
@export var rng_seed: int = -1
@export var debug_wall_trace: bool = false
@export var autogenerate_on_ready: bool = false   # <- default OFF when using LevelManager
@export var autoseed_on_ready: bool = false       # <- only for standalone DG scene debug

# ---------------- Prefabs ----------------
@export var prefabs: Array[PrefabSpec] = []
@export var prefab_debug_guides: bool = false

# ---------------- Player / debug ----------------
@export var player_path: NodePath
@export var show_center_debug_box: bool = false
@export var spawn_player_on_start: bool = true
#test
@export_group("Player Spawn Tweaks")
@export var spawn_y_offset: float = 0.1
@export var snap_down_on_spawn: bool = true
@export var snap_down_max: float = 3.0
@export var snap_mask: int = 1

@export var apply_first_spawn_yaw: bool = true
@export var first_spawn_yaw_deg: float = 180.0
@export var yaw_pivot_path: NodePath

var _did_initial_spawn: bool = false

# ---------------- Floor collision ----------------
@export_enum("Plane", "PerTileBoxes", "None") var floor_collision_mode: int = 2
@export var floor_plane_lift: float = 0.02

# ---------------- Perimeter ----------------
@export var build_perimeter_fence: bool = true
@export var perimeter_thickness: float = 1.0
@export var build_perimeter_visuals: bool = true

# ---------------- Prefab pathing / detours ----------------
@export_enum("Shortest", "WaypointDetours") var prefab_path_mode: int = 0
@export var prefab_detour_radius: int = 3
@export var prefab_detour_count: int = 1
@export var prefab_detour_fallback: bool = true
@export var detour_snap_to_perimeter: bool = true

# ---------------- Key / Lock ----------------
@export_group("Key / Lock")
@export var key_scene: PackedScene
@export var key_id: StringName = &"gold"
@export var exit_door_group: StringName = &"exit_door"
@export var key_max_perimeter_dist: int = 2
@export var key_height_m: float = 1.5
@export var key_roll_deg: float = -90.0
@export var enable_key_spawn: bool = true
@export var player_group: StringName = &"player"
@export_group("Key spawn safety")
@export var key_clearance_radius: float = 0.35   # how far from walls/meshes the key should be
@export var key_inward_step_m: float = 0.20      # step size when walking inward
@export var key_inward_max_m: float = 2.0        # max distance to walk inward

var _key_area: Area3D = null
var _key_node: Node3D = null
var _player_in_key_zone: bool = false
var _has_key: bool = false

# ---------------- Wall Pieces ----------------
@export_group("Wall Pieces")
@export var enable_wall_pieces: bool = true
@export var wall_plain_scene: PackedScene
@export var wall_pillar1_scene: PackedScene
@export var wall_pillar2_scene: PackedScene
@export var piece_inset_m: float = 0.07
@export var piece_y_m: float = 2.05
@export var debug_verbose: bool = true

@export_group("Wall Piece Debug")
@export var debug_wall_pieces: bool = false
@export var debug_wall_piece_markers: bool = false

@export_group("Ceilings")
@export var build_ceilings: bool = true
@export var ceiling_name: StringName = &"ceiling_tile"
@export var ceiling_epsilon: float = 02.36

# ---------------- Enemies and Loot -----------------

@export_group("Encounter Anchors")
@export var triad_rules: TriadRules
@export var elite_anchor_y_offset_m: float = 0
@export var treasure_anchor_y_offset_m: float = -0.2
@export var treasure_chest_scene: PackedScene


# ---------------- Internals ----------------
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _floor_top_y: float = 0.0
var _wall_thickness: float = 1.0
var _wall_height: float = 4.0
var _id_floor: int = -1
var _id_wall: int = -1
var _last_reserved: PackedByteArray = PackedByteArray()

var _placed_rects: Array[Rect2i] = []
var _placed_specs: Array[PrefabSpec] = []
var _placed_anchor_cells: Array[Vector2i] = []

var _last_open: PackedInt32Array = PackedInt32Array()
var _finish_door: Node = null

var _runtime_prefabs_root: Node3D = null

# =============================================================
# Lifecycle
# =============================================================
func _ready() -> void:
	if gm_floor == null or gm_walls == null:
		push_error("[DG] Missing GridFloors and/or GridWalls.")
		return
	if gm_floor.mesh_library == null or gm_walls.mesh_library == null:
		push_error("[DG] Assign the same MeshLibrary to both GridMaps.")
		return
		
	

	gm_floor.cell_size = Vector3(4.0, 4.0, 4.0)
	gm_walls.cell_size = Vector3(4.0, 4.0, 4.0)
	if gm_ceilings != null:
		gm_ceilings.cell_size = gm_floor.cell_size

	# Only do seed + generate if explicitly enabled (e.g., when launching this scene directly)
	if autoseed_on_ready and rng_seed <= 0:
		var r := RandomNumberGenerator.new()
		r.randomize()
		rng_seed = int(r.randi())
		print("[DG] RNG auto-seeded ->", rng_seed)

	if autogenerate_on_ready:
		_apply_seed(false)
		_generate_and_paint()

func _apply_seed(use_random_now: bool) -> void:
	var seed_to_use: int
	if use_random_now or rng_seed < 0:
		rng.randomize()
		seed_to_use = int(rng.randi())
		rng_seed = seed_to_use
		print("[DG] RNG auto-seeded ->", seed_to_use)
	else:
		seed_to_use = rng_seed
		print("[DG] RNG using inspector seed ->", seed_to_use)
	rng.seed = seed_to_use

func _runtime_root() -> Node3D:
	_runtime_prefabs_root = DungeonReset.ensure_runtime_root(self, "RuntimePrefabs")
	return _runtime_prefabs_root

# =============================================================
# Main build
# =============================================================
func _generate_and_paint() -> void:
	_clear_debug_box()

	# Centralized cleanup
	DungeonReset.pre_generate_cleanup(self, {
		"baked_root_path": "Prefabs",
		"runtime_root_name": "RuntimePrefabs",
		"wallpieces_name": "WallPieces",
		"also_clear_colliders": true,
		"clear_gridmaps": false,
		"gridmaps": [gm_floor, gm_walls, gm_ceilings]
	})

	#print("[DG] wall pieces enabled=", enable_wall_pieces,
	#	" scenes set? plain=", wall_plain_scene != null,
	#	" p1=", wall_pillar1_scene != null,
	#	" p2=", wall_pillar2_scene != null)
	#_dbg("=== _generate_and_paint BEGIN ===")

	# --- lighting: start a new context for this build ---
	var lm := _ensure_light_mgr()
	lm.apply_config(_light_cfg())
	lm.new_context(rng_seed)

	_has_key = false
	_finish_door = null
	if _key_area != null: _key_area.queue_free(); _key_area = null
	if _key_node != null: _key_node.queue_free(); _key_node = null

	print("[DG] Generate start size:%dx%d seed:%d" % [width, height, rng_seed])

	# 1) Topology
	var open: PackedInt32Array = MazeGen.carve_maze(width, height, rng)
	var loops_opened: int = MazeGen.add_loops(open, loop_percent, width, height, rng)
	var rooms_injected: int = MazeGen.inject_rooms(open, room_attempts, room_max, width, height, rng)
	MazeGen.block_out_of_bounds_sides(open, width, height)
	print("[DG] Loops opened:%d  Rooms injected:%d" % [loops_opened, rooms_injected])

	# 2) Reserved (start all-zero; will be marked during prefab placement)
	var reserved: PackedByteArray = _alloc_reserved(width, height)

	# 3) Prefab placement (marks 'reserved')
	_place_all_prefabs(prefabs, open, reserved, width, height, gm_floor, rng)

	# Dump what actually got instantiated under RuntimePrefabs (catches dupes/overlaps)
	_dbg_runtime_prefabs(self)

	_last_open = open
	_last_reserved = reserved.duplicate()

	# 4) Mesh ids + initial floor Y from meshlib
	_id_floor = MeshLibTools.find_any(gm_floor.mesh_library, PackedStringArray(["floor_tile_large", "floor"]))
	_id_wall  = MeshLibTools.find_any(gm_floor.mesh_library, PackedStringArray(["wall_half", "wall"]))
	if _id_floor < 0 or _id_wall < 0:
		MeshLibTools.dump_items(gm_floor.mesh_library)
		push_error("[DG] Need floor & wall items in MeshLibrary.")
		return
	_floor_top_y = MeshLibTools.compute_floor_top_y_world(gm_floor, _id_floor)

	# 4.5) Instance prefabs (+anchors)
	_placed_anchor_cells.clear()
	var spawn_world: Vector3 = Vector3.INF
	for i: int in range(_placed_rects.size()):
		var inst: Node3D = _instance_prefab(_placed_rects[i], _placed_specs[i])
		if inst == null:
			_placed_anchor_cells.append(Vector2i(-1, -1))
			continue

		_maybe_record_anchor_cell(
			inst,
			_placed_rects[i],
			gm_walls.cell_size.x,
			gm_walls.global_transform.origin
		)

		var spec := _placed_specs[i]
		if spawn_world == Vector3.INF and spec.is_spawn_room and spec.spawn_node_path != NodePath():
			var spawn_node: Node3D = inst.get_node_or_null(spec.spawn_node_path) as Node3D
			if spawn_node != null:
				spawn_world = spawn_node.global_transform.origin
				#print("[DG] Spawn from prefab '%s' at %s" % [inst.name, str(spawn_world)])

		if spec.is_finish_room:
			if spec.finish_node_path != NodePath():
				var area: Area3D = inst.get_node_or_null(spec.finish_node_path) as Area3D
				if area != null and not area.body_entered.is_connected(_on_finish_body_entered):
					area.body_entered.connect(_on_finish_body_entered)
			if spec.finish_door_path != NodePath():
				var d: Node = inst.get_node_or_null(spec.finish_door_path)
				if d != null:
					_finish_door = d
					if d.has_method("set_locked"):
						d.call("set_locked", true)

	# 5) Ensure graph connectivity (paths + global)
	if ensure_prefab_paths:
		_connect_prefabs_with_paths(open, reserved)
	var fixed_edges: int = _ensure_global_connectivity(open, width, height, reserved)
	

	# 6) Paint base grid (returns floor_top_y, wall sizes)
	var info: Dictionary = DungeonPainter.paint_grid(
		gm_floor, gm_walls, open, width, height,
		_id_floor, _id_wall, reserved, debug_wall_trace
	)
	_floor_top_y    = float(info.get("floor_top_y", _floor_top_y))
	_wall_thickness = float(info.get("wall_thickness", _wall_thickness))
	_wall_height    = float(info.get("wall_height", _wall_height))

	# Disable GridMap physics; we use our own colliders
	_disable_gridmap_collisions()

	# 6.5) Ceilings
	if build_ceilings:
		_paint_ceilings(open, reserved)

	# 7) Colliders — build ONCE, after prefabs & painting
	var reserved_for_colliders: PackedByteArray = reserved.duplicate()

	ColliderBuilder.rebuild_floor_colliders(
		open, reserved_for_colliders,
		gm_floor, self,
		floor_collision_mode, floor_plane_lift, _floor_top_y
	)

	ColliderBuilder.build_wall_colliders_from_topology(
		open, reserved_for_colliders,
		gm_walls, self, width, height,
		_floor_top_y, _wall_height, _wall_thickness, debug_wall_trace
	)

	if build_perimeter_fence:
		ColliderBuilder.build_perimeter_wall_colliders(
			gm_walls, self, width, height,
			_floor_top_y, _wall_height, perimeter_thickness, debug_wall_trace
		)

	# Extra belt-and-suspenders: delete any stray floor tiles under prefab rects.
	var removed_fc := ColliderBuilder.remove_floor_colliders_under_rects(self, gm_floor, _placed_rects, 0)
	

	# 7.5) Wall pieces (pillars/torches) …
	
	if enable_wall_pieces:
		_skin_walls_with_pieces(open, reserved)
		_ensure_light_mgr().apply_group_gate()
	_dbg_dump_wallpieces_once()
	var wp_after: Node3D = _dbg_find_wallpieces_root()
	
	
	_last_open = open  # <-- ensure we store the FINAL topology for anchor placement

	# 8) Key
	if enable_key_spawn:
		_spawn_key_near_perimeter(open, reserved)

	# 9) Player
	if spawn_world != Vector3.INF and player_path != NodePath():
		call_deferred("_place_player_at_world", spawn_world)
	elif spawn_player_on_start:
		var spawn_cell: Vector2i = MazeGen.pick_spawn_cell(open, width, height)
		_place_player_over(spawn_cell)

	if show_center_debug_box:
		_place_debug_box(Vector3i(width / 2, 0, height / 2))

	call_deferred("_debug_probe")


# =============================================================
# Prefab placement
# =============================================================
func _place_all_prefabs(
	specs: Array,                       # Array[PrefabSpec]
	open: PackedInt32Array,
	reserved: PackedByteArray,
	cols: int, rows: int,
	gm_floor: GridMap,
	rng: RandomNumberGenerator
) -> void:
	# Clear what we’re about to repopulate
	_placed_rects.clear()
	_placed_specs.clear()

	for idx in range(specs.size()):
		var spec: PrefabSpec = specs[idx]
		for copy_i in range(max(1, spec.count)):
			# 1) Pick a rect for this prefab
			var r := _reserve_rect_for_spec(spec, cols, rows, rng, reserved)
			
			if r.size == Vector2i.ZERO:
				push_warning("[PF] no space found for prefab; skipping: " + str(spec))
				continue

			# 2) DEBUG: rect → world + reserved coverage + doors
			_dbg_rect_world("PF", r, gm_floor)
			_dbg_reserved_check("PF", reserved, cols, rows, r)
			_dbg_doors_for_rect("PF", cols, rows, r)

			# 3) Mark reserved cells (this is the only mutation here)
			if not MazeGen.reserve_rect(reserved, cols, rows, r):
				push_warning("[PF] reserve_rect failed; out of bounds? r=" + str(r))
				continue
			

			# 4) Optionally open mid sockets on the maze topology
			if spec.open_sockets:
				MazeGen.open_room_sockets(open, cols, rows, r)
				

			# 5) Record for later instantiation/pass wiring
			_placed_rects.append(r)
			_placed_specs.append(spec)

		

	# After all prefabs, dump the runtime container (should still be empty now)
	_dbg_runtime_prefabs(self)
	var exits := get_tree().get_nodes_in_group("exit_door")
	
	

func _can_fit_rect(reserved: PackedByteArray, r: Rect2i, margin: int) -> bool:
	if r.position.x < margin or r.position.y < margin: return false
	if r.position.x + r.size.x > width - margin: return false
	if r.position.y + r.size.y > height - margin: return false

	var x0: int = max(0, r.position.x - margin)
	var z0: int = max(0, r.position.y - margin)
	var x1: int = min(width  - 1, r.position.x + r.size.x + margin - 1)
	var z1: int = min(height - 1, r.position.y + r.size.y + margin - 1)

	for z: int in range(z0, z1 + 1):
		for x: int in range(x0, x1 + 1):
			if reserved[MazeGen.idx(x, z, width)] != 0:
				return false
	return true

func _instance_prefab(rect: Rect2i, spec: PrefabSpec) -> Node3D:
	var inst: Node3D = spec.scene.instantiate() as Node3D
	if inst == null:
		return null

	# --- position the prefab by its anchor ---
	var cell: float = gm_floor.cell_size.x
	var half: float = cell * 0.5

	var nw_center_local: Vector3 = gm_floor.map_to_local(Vector3i(rect.position.x, 0, rect.position.y))
	var nw_center_world: Vector3 = gm_floor.transform * nw_center_local

	var target: Vector3 = Vector3(
		nw_center_world.x - half + 1.5 + spec.extra_offset_m.x,
		_floor_top_y,
		nw_center_world.z - half + 1.5 + spec.extra_offset_m.y
	)

	var anchor: Node3D = inst.get_node_or_null("SnapOrigin") as Node3D
	if anchor == null: anchor = inst.get_node_or_null("Anchor_TopLeft") as Node3D
	if anchor == null: anchor = inst.get_node_or_null("Anchor_NW") as Node3D

	var local_anchor: Vector3 = Vector3.ZERO
	if anchor != null:
		local_anchor = anchor.transform.origin

	inst.transform = Transform3D(Basis.IDENTITY, target - local_anchor)
	_runtime_root().add_child(inst)  # parent under RuntimePrefabs

	if prefab_debug_guides:
		_draw_prefab_guides(rect)

	# --- optional door wiring inside the prefab ---
	var lm: Node = null
	if level_manager_path != NodePath() and has_node(level_manager_path):
		lm = get_node(level_manager_path)

	var doors: Array[Door] = []
	_collect_doors(inst, doors)

	if spec.is_spawn_room:
		_apply_spawn_room_rules(doors, lm)

	if spec.is_finish_room:
		_apply_finish_room_rules(doors, lm)

	var sockets: Dictionary = _get_prefab_sockets(rect)
	if inst.has_method("set_openings"):
		inst.call("set_openings", sockets.n, sockets.e, sockets.s, sockets.w)

	return inst

func _collect_doors(root: Node, out: Array[Door]) -> void:
	var q: Array[Node] = [root]
	while not q.is_empty():
		var n: Node = q.pop_back()
		var d: Door = n as Door
		if d != null:
			out.append(d)
		for c in n.get_children():
			q.append(c)

func _apply_spawn_room_rules(doors: Array[Door], lm: Node) -> void:
	var entry: Door = null
	for d in doors:
		if d == null:
			continue

		# Bind LevelManager path if present
		if lm != null and d.has_method("get") and d.has_method("set"):
			if d.get("level_manager_path") != null:
				d.set("level_manager_path", level_manager_path)

		# Prefer a door that is flagged to start open
		if d.has_method("get"):
			var start_v: Variant = d.get("start_open_on_ready")
			var start_flag: bool = (typeof(start_v) == TYPE_BOOL and bool(start_v))
			if start_flag and entry == null:
				entry = d

	# Fallback
	if entry == null and doors.size() > 0:
		entry = doors[0]

	# Open it immediately and keep it open
	if entry != null:
		if entry.has_method("set_locked"):
			entry.call("set_locked", false)
		if entry.has_method("force_open_unlocked_now"):
			entry.call("force_open_unlocked_now")
		if entry.has_method("get") and entry.has_method("set"):
			var ac_v: Variant = entry.get("auto_close_on_ready")
			if typeof(ac_v) == TYPE_BOOL and bool(ac_v):
				entry.set("auto_close_on_ready", false)


func _apply_finish_room_rules(doors: Array[Door], lm: Node) -> void:
	var next_door: Door = null
	for d in doors:
		if d == null:
			continue

		# Bind LevelManager path if present
		if lm != null and d.has_method("get") and d.has_method("set"):
			if d.get("level_manager_path") != null:
				d.set("level_manager_path", level_manager_path)

		# Look for the door whose on_open_action == Next (1)
		if d.has_method("get"):
			var act_v: Variant = d.get("on_open_action")
			var act_i: int = (int(act_v) if typeof(act_v) == TYPE_INT else -1)
			if act_i == 1:
				next_door = d
				break

	# Start locked; key will unlock later
	if next_door != null and next_door.has_method("set_locked"):
		next_door.call("set_locked", true)


func _get_prefab_sockets(r: Rect2i) -> Dictionary:
	var cx: int = r.position.x + r.size.x / 2
	var cz: int = r.position.y + r.size.y / 2

	var n := false
	var e := false
	var s := false
	var w := false

	if r.position.y > 0:
		var idx_n: int = MazeGen.idx(cx, r.position.y - 1, width)
		n = ((_last_open[idx_n]) & MazeGen.MASK[MazeGen.S]) != 0
	if r.position.y + r.size.y < height:
		var idx_s: int = MazeGen.idx(cx, r.position.y + r.size.y - 1, width)
		s = ((_last_open[idx_s]) & MazeGen.MASK[MazeGen.S]) != 0
	if r.position.x > 0:
		var idx_w: int = MazeGen.idx(r.position.x - 1, cz, width)
		w = ((_last_open[idx_w]) & MazeGen.MASK[MazeGen.E]) != 0
	if r.position.x + r.size.x < width:
		var idx_e: int = MazeGen.idx(r.position.x + r.size.x - 1, cz, width)
		e = ((_last_open[idx_e]) & MazeGen.MASK[MazeGen.E]) != 0

	return {"n": n, "e": e, "s": s, "w": w}

# =============================================================
# Connect placed prefabs with guaranteed paths
# =============================================================
func _connect_prefabs_with_paths(open: PackedInt32Array, reserved: PackedByteArray) -> void:
	if _placed_rects.size() < 2: return

	if _placed_anchor_cells.size() != _placed_rects.size():
		_placed_anchor_cells.resize(_placed_rects.size())
		for k: int in range(_placed_anchor_cells.size()):
			if _placed_anchor_cells[k] == Vector2i():
				_placed_anchor_cells[k] = Vector2i(-1, -1)

	for i: int in range(_placed_rects.size() - 1):
		var r_a: Rect2i = _placed_rects[i]
		var r_b: Rect2i = _placed_rects[i + 1]

		var use_anchors: bool = (
			_placed_anchor_cells[i]     != Vector2i(-1, -1) and
			_placed_anchor_cells[i + 1] != Vector2i(-1, -1)
		)

		var best_a: Vector2i
		var best_b: Vector2i

		if use_anchors:
			best_a = _placed_anchor_cells[i]
			best_b = _placed_anchor_cells[i + 1]
		else:
			var doors_a: Array[Vector2i] = MazeGen.door_cells_for_rect(width, height, r_a)
			var doors_b: Array[Vector2i] = MazeGen.door_cells_for_rect(width, height, r_b)
			if doors_a.is_empty() or doors_b.is_empty():
				continue
			var best_d: int = 1 << 30
			best_a = doors_a[0]
			best_b = doors_b[0]
			for da: Vector2i in doors_a:
				for db: Vector2i in doors_b:
					var d: int = abs(da.x - db.x) + abs(da.y - db.y)
					if d < best_d:
						best_d = d
						best_a = da
						best_b = db

		MazeGen.open_portal_into_rect(open, width, height, r_a, best_a)
		MazeGen.open_portal_into_rect(open, width, height, r_b, best_b)

		if prefab_path_mode == 1:
			var path: Array[Vector2i] = _path_via_waypoints(best_a, best_b, width, height, reserved, prefab_detour_radius, prefab_detour_count)
			if path.size() > 1:
				MazeGen.carve_path(open, width, height, path)
			elif prefab_detour_fallback:
				MazeGen.ensure_path_between(open, width, height, reserved, best_a, best_b)
		else:
			if not MazeGen.has_path_between(open, width, height, reserved, best_a, best_b):
				if MazeGen.ensure_path_between(open, width, height, reserved, best_a, best_b):
					print("[DG] Linked prefabs via path ", best_a, " -> ", best_b)
				else:
					print("[DG] WARNING: could not link prefabs at ", best_a, " & ", best_b)

	var fixed_edges2: int = _ensure_global_connectivity(open, width, height, reserved)
	if fixed_edges2 > 0:
		print("[DG] Connectivity fix carved ", fixed_edges2, " edges.")

# =============================================================
# Finish / next-level
# =============================================================
func _on_finish_body_entered(body: Node) -> void:
	if player_path == NodePath(): return
	var player: Node = get_node_or_null(player_path)
	if body != player: return
	if enable_key_spawn and not _has_key:
		print("[DG] Finish is locked. Find the key!")
		return
	_finish_level()

func _finish_level() -> void:
	emit_signal("finish_triggered")
	if level_manager_path != NodePath():
		var mgr: Node = get_node_or_null(level_manager_path)
		if mgr != null:
			if mgr.has_method("goto_next_level"):
				mgr.call("goto_next_level")
			elif mgr.has_method("request_next_level"):
				mgr.call("request_next_level")

# (Optional) build a finish Area3D
func _build_finish_area_for_rect(rect: Rect2i) -> void:
	var container: Node3D = get_node_or_null("FinishAreas") as Node3D
	if container == null:
		container = Node3D.new()
		container.name = "FinishAreas"
		add_child(container)

	var area: Area3D = Area3D.new()
	area.name = "Finish_" + str(rect.position) + "_" + str(rect.size)
	area.collision_layer = 1
	area.collision_mask = 1
	area.monitoring = true
	area.monitorable = true

	var shape: BoxShape3D = BoxShape3D.new()
	var cell: float = gm_floor.cell_size.x
	shape.size = Vector3(float(rect.size.x) * cell - 0.1, 0.5, float(rect.size.y) * cell - 0.1)

	var cs: CollisionShape3D = CollisionShape3D.new()
	cs.shape = shape
	area.add_child(cs)

	var cx: int = rect.position.x + rect.size.x / 2
	var cz: int = rect.position.y + rect.size.y / 2
	var center_local: Vector3 = gm_floor.map_to_local(Vector3i(cx, 0, cz))
	var center_world: Vector3 = gm_floor.transform * center_local
	area.transform = Transform3D(Basis.IDENTITY, Vector3(center_world.x, _floor_top_y + 0.25, center_world.z))

	container.add_child(area)
	if not area.body_entered.is_connected(_on_finish_body_entered):
		area.body_entered.connect(_on_finish_body_entered)

func _clear_finish_areas() -> void:
	var container: Node3D = get_node_or_null("FinishAreas") as Node3D
	if container != null:
		container.queue_free()

# =============================================================
# Debug guides
# =============================================================
func _draw_prefab_guides(r: Rect2i) -> void:
	var old: Node3D = get_node_or_null("PrefabGuides") as Node3D
	if old != null: old.queue_free()

	var root: Node3D = Node3D.new()
	root.name = "PrefabGuides"
	add_child(root)

	var cell: float = gm_walls.cell_size.x
	var full_w: float = float(r.size.x) * cell
	var full_h: float = float(r.size.y) * cell

	var corner_local: Vector3 = gm_floor.map_to_local(Vector3i(r.position.x, 0, r.position.y))
	var corner_world: Vector3 = gm_floor.transform * corner_local
	var y_center: float = _floor_top_y + _wall_height * 0.5

	var north_c: Vector3 = corner_world + Vector3(full_w * 0.5, y_center, 0.5)
	var south_c: Vector3 = corner_world + Vector3(full_w * 0.5, y_center, full_h - 0.5)
	var west_c:  Vector3 = corner_world + Vector3(0.5, y_center, full_h * 0.5)
	var east_c:  Vector3 = corner_world + Vector3(full_w - 0.5, y_center, full_h * 0.5)

	_add_debug_box(root, Vector3(full_w, 0.1, 0.1), north_c)
	_add_debug_box(root, Vector3(full_w, 0.1, 0.1), south_c)
	_add_debug_box(root, Vector3(0.1, 0.1, full_h), west_c)
	_add_debug_box(root, Vector3(0.1, 0.1, full_h), east_c)

func _add_debug_box(parent: Node3D, size: Vector3, center: Vector3) -> void:
	var mi: MeshInstance3D = MeshInstance3D.new()
	var bm: BoxMesh = BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.transform = Transform3D(Basis.IDENTITY, center)
	parent.add_child(mi)

# =============================================================
# Player helpers
# =============================================================
func _place_player_over(cell: Vector2i) -> void:
	if player_path == NodePath() or gm_floor == null:
		return
	var p := get_node_or_null(player_path) as Node3D
	if p == null:
		return

	var local := gm_floor.map_to_local(Vector3i(cell.x, 0, cell.y))
	var world := gm_floor.transform * local
	var pos := Vector3(
		global_transform.origin.x + world.x,
		0.0,
		global_transform.origin.z + world.z
	)

	pos.y = _snap_y_to_floor_player(pos)

	var t := p.global_transform
	t.origin = pos
	p.global_transform = t

	_apply_first_spawn_yaw_if_needed(p)

	var pco := p as CollisionObject3D
	if pco != null:
		pco.collision_mask |= 1

func _place_player_at_world(spawn_world: Vector3) -> void:
	if player_path == NodePath():
		return
	var p := get_node_or_null(player_path) as Node3D
	if p == null:
		return

	var pos := spawn_world
	pos.y = _snap_y_to_floor_player(pos)

	var t := p.global_transform
	t.origin = pos
	p.global_transform = t

	_apply_first_spawn_yaw_if_needed(p)

func _debug_probe() -> void:
	var c: Vector3i = Vector3i(width / 2, 0, height / 2)
	var p_dungeon_local: Vector3 = gm_floor.transform * gm_floor.map_to_local(c)
	var from: Vector3 = p_dungeon_local + Vector3(6.0, 10.0, 0.0)
	var to: Vector3 = p_dungeon_local + Vector3(6.0, -50.0, 0.0)
	var q: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(global_transform * from, global_transform * to)
	q.collision_mask = 1
	q.collide_with_areas = false
	q.collide_with_bodies = true
	if player_path != NodePath():
		var p: CollisionObject3D = get_node_or_null(player_path) as CollisionObject3D
		if p != null: q.exclude = [p.get_rid()]
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(q)
	

func _clear_debug_box() -> void:
	var n: Node3D = get_node_or_null("CenterDebugBox") as Node3D
	if n != null: n.queue_free()

func _place_debug_box(cell: Vector3i) -> void:
	_clear_debug_box()
	var lp: Vector3 = (gm_floor.transform * gm_floor.map_to_local(cell)) + Vector3(0.0, 0.11, 0.0)
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = "CenterDebugBox"
	var bm: BoxMesh = BoxMesh.new()
	bm.size = Vector3(4.0, 0.2, 4.0)
	mi.mesh = bm
	mi.transform = Transform3D(Basis.IDENTITY, lp)
	add_child(mi)

func _maybe_record_anchor_cell(inst: Node3D, rect: Rect2i, cell_size: float, grid_origin: Vector3) -> void:
	var anchor: Node3D = inst.get_node_or_null("Anchor_Entry") as Node3D
	if anchor == null:
		_placed_anchor_cells.append(Vector2i(-1, -1))
		return

	var world: Vector3 = anchor.global_transform.origin
	var local: Vector3 = world - grid_origin
	var ax: int = int(round(local.x / cell_size))
	var az: int = int(round(local.z / cell_size))
	var c: Vector2i = Vector2i(ax, az)

	if c.x >= rect.position.x and c.x < rect.position.x + rect.size.x \
	and c.y >= rect.position.y and c.y < rect.position.y + rect.size.y:
		var rcx: float = float(ax) - float(rect.position.x) - float(rect.size.x) * 0.5
		var rcz: float = float(az) - float(rect.position.y) - float(rect.size.y) * 0.5
		var d: int = MazeGen.E
		if abs(rcx) > abs(rcz):
			d = MazeGen.E if rcx >= 0.0 else MazeGen.W
		else:
			d = MazeGen.S if rcz >= 0.0 else MazeGen.N
		c = Vector2i(c.x + MazeGen.DX[d], c.y + MazeGen.DZ[d])

	_placed_anchor_cells.append(c)

# =============================================================
# Detours
# =============================================================
func _sgn(i: int) -> int:
	if i > 0: return 1
	if i < 0: return -1
	return 0

func _clamp_cell(p: Vector2i, w: int, h: int) -> Vector2i:
	return Vector2i(clamp(p.x, 0, w - 1), clamp(p.y, 0, h - 1))

func _clamp_cell_interior(p: Vector2i, w: int, h: int) -> Vector2i:
	return Vector2i(clamp(p.x, 1, w - 2), clamp(p.y, 1, h - 2))

func _cell_blocked(p: Vector2i, reserved: PackedByteArray, w: int, h: int) -> bool:
	if p.x < 0 or p.x >= w or p.y < 0 or p.y >= h: return true
	if reserved.size() == 0: return false
	return reserved[MazeGen.idx(p.x, p.y, w)] != 0

func _make_detour_points(a: Vector2i, b: Vector2i, w: int, h: int, reserved: PackedByteArray, radius: int, count: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var c_count: int = clamp(count, 0, 3)
	if c_count <= 0 or radius <= 0:
		return out

	var dx: int = b.x - a.x
	var dz: int = b.y - a.y
	var perp: Vector2i = Vector2i(-_sgn(dz), _sgn(dx))
	if perp == Vector2i.ZERO:
		perp = Vector2i(0, 1)

	var rng_local := RandomNumberGenerator.new()
	rng_local.randomize()
	var tries: int = 8

	for k: int in range(c_count):
		var t_num: int = (k + 1)
		var t_den: int = (c_count + 1)
		var along: Vector2i = Vector2i(a.x + (b.x - a.x) * t_num / t_den, a.y + (b.y - a.y) * t_num / t_den)
		var side_pick: int = 1
		if (rng_local.randi() % 2) != 0:
			side_pick = -1
		var r: int = radius

		var best: Vector2i = Vector2i(-1, -1)
		for _t: int in range(tries):
			var jitter: int = int(rng_local.randi_range(-1, 1))
			var cand: Vector2i = along + perp * (side_pick * (r + jitter))
			if detour_snap_to_perimeter:
				cand = _clamp_cell(cand, w, h)
			else:
				cand = _clamp_cell_interior(cand, w, h)
			if not _cell_blocked(cand, reserved, w, h):
				best = cand
				break
			side_pick = -side_pick
			r = max(1, r - 1)

		if best.x >= 0:
			out.append(best)

	for i: int in range(out.size() - 1, -1, -1):
		if out[i] == a or out[i] == b:
			out.remove_at(i)
	return out

func _path_via_waypoints(a: Vector2i, b: Vector2i, w: int, h: int, reserved: PackedByteArray, radius: int, count: int) -> Array[Vector2i]:
	var route: Array[Vector2i] = []
	var pts: Array[Vector2i] = []
	pts.append(a)
	var detours: Array[Vector2i] = _make_detour_points(a, b, w, h, reserved, radius, count)
	for p: Vector2i in detours:
		pts.append(p)
	pts.append(b)

	for i: int in range(pts.size() - 1):
		var seg: Array[Vector2i] = MazeGen.shortest_cell_path(w, h, reserved, pts[i], pts[i + 1])
		if seg.is_empty():
			return []
		if i > 0:
			seg.remove_at(0)
		route.append_array(seg)
	return route

# =============================================================
# Reachability
# =============================================================
func _reachable_mask(open: PackedInt32Array, w: int, h: int, reserved: PackedByteArray, start: Vector2i) -> PackedByteArray:
	var vis: PackedByteArray = PackedByteArray()
	vis.resize(w * h)
	if start.x < 0 or start.y < 0:
		return vis

	var q: Array[Vector2i] = []
	q.push_back(start)
	vis[MazeGen.idx(start.x, start.y, w)] = 1

	while q.size() > 0:
		var c: Vector2i = q.pop_front()
		var i2: int = MazeGen.idx(c.x, c.y, w)
		var m: int = open[i2]

		for d: int in [MazeGen.N, MazeGen.E, MazeGen.S, MazeGen.W]:
			if (m & MazeGen.MASK[d]) == 0:
				continue
			var nx: int = c.x + MazeGen.DX[d]
			var nz: int = c.y + MazeGen.DZ[d]
			if nx < 0 or nx >= w or nz < 0 or nz >= h:
				continue
			var ni: int = MazeGen.idx(nx, nz, w)
			if reserved.size() > 0 and reserved[ni] != 0:
				continue
			if vis[ni] == 1:
				continue
			vis[ni] = 1
			q.push_back(Vector2i(nx, nz))

	return vis

func _ensure_global_connectivity(open: PackedInt32Array, w: int, h: int, reserved: PackedByteArray) -> int:
	var carved_segments: int = 0
	var start: Vector2i = MazeGen.pick_spawn_cell(open, w, h)
	var vis: PackedByteArray = _reachable_mask(open, w, h, reserved, start)

	while true:
		var target: Vector2i = Vector2i(-1, -1)
		for z: int in range(h):
			for x: int in range(w):
				var i: int = MazeGen.idx(x, z, w)
				if open[i] == 0:
					continue
				if reserved.size() > 0 and reserved[i] != 0:
					continue
				if vis[i] == 0:
					target = Vector2i(x, z)
					break
			if target.x >= 0: break

		if target.x < 0:
			break

		var best: Vector2i = Vector2i(-1, -1)
		var best_d: int = 1 << 30
		for z2: int in range(h):
			for x2: int in range(w):
				var j: int = MazeGen.idx(x2, z2, w)
				if vis[j] == 1:
					var d: int = abs(x2 - target.x) + abs(z2 - target.y)
					if d < best_d:
						best_d = d
						best = Vector2i(x2, z2)

		var path: Array[Vector2i] = MazeGen.shortest_cell_path(w, h, reserved, target, best)
		if path.size() > 1:
			MazeGen.carve_path(open, w, h, path)
			carved_segments += path.size() - 1
			vis = _reachable_mask(open, w, h, reserved, start)
		else:
			print("[DG] connectivity: couldn’t connect pocket at ", target)
			break

	return carved_segments

# =============================================================
# Key spawning & pickup
# =============================================================
func _spawn_key_near_perimeter(open: PackedInt32Array, reserved: PackedByteArray) -> void:
	if key_scene == null: return

	# perimeter-adjacent open cells
	var candidates: Array[Vector2i] = []
	for z: int in range(height):
		for x: int in range(width):
			var i: int = MazeGen.idx(x, z, width)
			if open[i] == 0: continue
			if reserved.size() > 0 and reserved[i] != 0: continue
			var dist_i: int = min(min(x, width - 1 - x), min(z, height - 1 - z))
			if dist_i <= key_max_perimeter_dist:
				candidates.append(Vector2i(x, z))
	if candidates.is_empty():
		print("[DG] Key spawn: no valid perimeter-adjacent cells.")
		return

	var rng_local := RandomNumberGenerator.new()
	rng_local.randomize()
	var pick: Vector2i = candidates[rng_local.randi_range(0, candidates.size() - 1)]
	var x: int = pick.x
	var z: int = pick.y

	# nearest perimeter side for this cell
	var dW: int = x
	var dE: int = width  - 1 - x
	var dN: int = z
	var dS: int = height - 1 - z
	var m: int = min(min(dW, dE), min(dN, dS))
	var sides: Array[int] = []
	if dN == m: sides.append(MazeGen.N)
	if dE == m: sides.append(MazeGen.E)
	if dS == m: sides.append(MazeGen.S)
	if dW == m: sides.append(MazeGen.W)
	var side: int = sides[rng_local.randi_range(0, sides.size() - 1)]

	# base transforms/offsets
	var cell: float = gm_walls.cell_size.x
	var half: float = cell * 0.5
	var center_local: Vector3 = gm_walls.map_to_local(Vector3i(x, 0, z))

	var wall_dir_local: Vector3
	var yaw_deg: float
	match side:
		MazeGen.N: wall_dir_local = Vector3( 0, 0,  1); yaw_deg = 180.0
		MazeGen.S: wall_dir_local = Vector3( 0, 0, -1); yaw_deg = 0.0
		MazeGen.W: wall_dir_local = Vector3( 1, 0,  0); yaw_deg = 90.0
		_:         wall_dir_local = Vector3(-1, 0,  0); yaw_deg = 270.0

	var tangent_local: Vector3 = Vector3(wall_dir_local.z, 0.0, -wall_dir_local.x)
	var side_shift: float = rng_local.randf_range(-0.25, 0.25)

	# progressive inward nudges
	var try_offsets: Array[float] = [0.35, 0.5, 0.7, 0.9, 1.1, 1.3]

	var picked_world: Vector3 = Vector3.ZERO
	var found: bool = false
	for inset: float in try_offsets:
		var offset_local: Vector3 = wall_dir_local * (half - inset) + tangent_local * side_shift
		var base_world: Vector3 = gm_walls.transform * (center_local + offset_local)
		var test_world: Vector3 = _snap_to_floor_y(base_world)
		if _key_is_clear(test_world, 0.26):
			picked_world = test_world
			found = true
			break

	# try exact center if all failed
	if not found:
		var center_world: Vector3 = gm_walls.transform * center_local
		center_world = _snap_to_floor_y(center_world)
		if _key_is_clear(center_world, 0.26):
			picked_world = center_world
			found = true

	if not found:
		print("[DG] Key spawn: could not find a clear spot in cell (%d,%d)" % [x, z])
		return

	var basis: Basis = Basis().rotated(Vector3.UP, deg_to_rad(yaw_deg)).rotated(Vector3.FORWARD, deg_to_rad(key_roll_deg))
	var inst: Node3D = key_scene.instantiate() as Node3D
	if inst == null: return
	inst.global_transform = Transform3D(basis, picked_world)

	var items: Node3D = get_node_or_null("Items") as Node3D
	if items == null:
		items = Node3D.new(); items.name = "Items"; add_child(items)
	items.add_child(inst)
	_key_node = inst

	# pickup area
	_key_area = Area3D.new()
	_key_area.name = "KeyArea"
	_key_area.monitoring = true
	_key_area.monitorable = true
	_key_area.collision_layer = 0
	_key_area.collision_mask = 1
	_key_area.global_transform = Transform3D(Basis.IDENTITY, picked_world)

	var shp := SphereShape3D.new()
	shp.radius = 1.2
	var cs := CollisionShape3D.new()
	cs.shape = shp
	_key_area.add_child(cs)
	items.add_child(_key_area)

	if not _key_area.body_entered.is_connected(_on_key_area_entered):
		_key_area.body_entered.connect(_on_key_area_entered)
	if not _key_area.body_exited.is_connected(_on_key_area_exited):
		_key_area.body_exited.connect(_on_key_area_exited)

func _on_key_area_entered(body: Node) -> void:
	if player_path == NodePath(): return
	var player: Node = get_node_or_null(player_path)
	if body != player: return

	_has_key = true
	if _key_node != null: _key_node.queue_free(); _key_node = null
	if _key_area != null: _key_area.queue_free(); _key_area = null

	_unlock_finish_doors()
	print("[DG] Key collected! Finish is now unlocked.")

func _on_key_area_exited(_body: Node) -> void:
	pass

func _unlock_finish_doors() -> void:
	var unlocked: int = 0
	var nodes: Array[Node] = get_tree().get_nodes_in_group(exit_door_group)
	print("[DG] Unlock broadcast to group '%s' -> %d nodes" % [String(exit_door_group), nodes.size()])
	for n: Node in nodes:
		if n.has_method("unlock"): n.call("unlock"); unlocked += 1
		elif n.has_method("set_locked"): n.call("set_locked", false); unlocked += 1

	if unlocked == 0:
		var stack: Array[Node] = [get_tree().get_root()]
		while stack.size() > 0:
			var cur: Node = stack.pop_back()
			for c: Node in cur.get_children():
				stack.push_back(c)
				if c.has_method("unlock"):
					c.call("unlock"); unlocked += 1
				elif c.has_method("set_locked"):
					c.call("set_locked", false); unlocked += 1

	print("[DG] Unlock complete: doors=%d" % unlocked)

# =============================================================
# Wall piece pass (pillars + built-in torches)
# =============================================================
func _ensure_wallpieces_root() -> Node3D:
	var r: Node3D = get_node_or_null("WallPieces") as Node3D
	if r == null:
		r = Node3D.new(); r.name = "WallPieces"; add_child(r)
	return r

func _side_name(s: int) -> String:
	match s:
		MazeGen.N: return "N"
		MazeGen.E: return "E"
		MazeGen.S: return "S"
		MazeGen.W: return "W"
		_: return "?"

func _debug_piece_marker(p: Vector3, _side: int) -> void:
	var mi: MeshInstance3D = MeshInstance3D.new()
	var bm: BoxMesh = BoxMesh.new()
	bm.size = Vector3(0.15, 0.15, 0.15)
	mi.mesh = bm
	mi.transform = Transform3D(Basis.IDENTITY, p + Vector3(0, 0.1, 0))
	_ensure_wallpieces_root().add_child(mi)

func _edge_touches_reserved_local(reserved: PackedByteArray, w: int, h: int, ax: int, az: int, bx: int, bz: int) -> bool:
	if reserved.size() == 0: return false
	if ax < 0 or az < 0 or ax >= w or az >= h: return false
	if bx < 0 or bz < 0 or bx >= w or bz >= h: return false
	return reserved[MazeGen.idx(ax, az, w)] != 0 or reserved[MazeGen.idx(bx, bz, w)] != 0

func _has_s_wall(open: PackedInt32Array, xi: int, zi: int) -> bool:
	if xi < 0 or zi < 0 or xi >= width or zi >= height: return false
	if zi + 1 >= height: return false
	var m: int = open[MazeGen.idx(xi, zi, width)]
	return (m & MazeGen.MASK[MazeGen.S]) == 0

func _has_e_wall(open: PackedInt32Array, xi: int, zi: int) -> bool:
	if xi < 0 or zi < 0 or xi >= width or zi >= height: return false
	if xi + 1 >= width: return false
	var m: int = open[MazeGen.idx(xi, zi, width)]
	return (m & MazeGen.MASK[MazeGen.E]) == 0

func _place_wall_segment(x: int, z: int, side: int, piece_kind: int) -> void:
	var scene: PackedScene = null
	match piece_kind:
		0: scene = wall_plain_scene
		1: scene = wall_pillar1_scene
		_: scene = wall_pillar2_scene
	
	if scene == null:
		push_warning("[DG] SKIP piece kind=%d — PackedScene is null" % piece_kind)
		return

	var inst: Node3D = scene.instantiate() as Node3D
	if inst == null: return

	var cell: float = gm_floor.cell_size.x
	var half: float = cell * 0.5
	var inset: float = piece_inset_m

	var center_local: Vector3 = gm_floor.map_to_local(Vector3i(x, 0, z))
	var offset_local: Vector3 = Vector3.ZERO
	var yaw_deg: float = 0.0

	match side:
		MazeGen.N: offset_local = Vector3(0.0, 0.0, -half + inset); yaw_deg = 0.0
		MazeGen.S: offset_local = Vector3(0.0, 0.0,  half - inset); yaw_deg = 180.0
		MazeGen.W: offset_local = Vector3(-half + inset, 0.0, 0.0);  yaw_deg = 90.0
		_:         offset_local = Vector3( half - inset, 0.0, 0.0);  yaw_deg = 270.0

	var p_world: Vector3 = gm_floor.transform * (center_local + offset_local)
	p_world.y = _floor_top_y

	var basis: Basis = Basis().rotated(Vector3.UP, deg_to_rad(yaw_deg))
	inst.global_transform = Transform3D(basis, p_world)
	_ensure_wallpieces_root().add_child(inst)

	# lighting per-piece (supports "Torch" holder)
	var lm := _ensure_light_mgr()
	var dl_side := (DungeonLight.SIDE_E if side == MazeGen.E else DungeonLight.SIDE_S)
	lm.process_wallpiece(inst, dl_side, x, z, p_world)

	if debug_wall_piece_markers:
		_debug_piece_marker(p_world, side)

	if debug_wall_pieces:
		var kind_name_list: Array[String] = ["Plain", "Pillar1", "Pillar2"]
		var kind_idx: int = clamp(piece_kind, 0, 2)
		print("[DG] piece @(", x, ",", z, ") side=", _side_name(side), " kind=", kind_name_list[kind_idx])

func _skin_walls_with_pieces(open: PackedInt32Array, reserved: PackedByteArray) -> void:
	

	# Gate: feature toggle
	if not enable_wall_pieces:
		print("[DG/DBG] SKIP: enable_wall_pieces=false")
		return

	# Clear any previous root
	var r_old: Node3D = get_node_or_null("WallPieces") as Node3D
	var before_children: int = 0
	if r_old != null:
		before_children = r_old.get_child_count()
	

	if r_old != null:
		r_old.free() 

	# Ensure fresh root
	var wp: Node3D = _ensure_wallpieces_root()
	

	# Scenes present?
	var plain_ok: bool = wall_plain_scene != null
	var p1_ok: bool = wall_pillar1_scene != null
	var p2_ok: bool = wall_pillar2_scene != null
	

	if wall_plain_scene == null or wall_pillar1_scene == null or wall_pillar2_scene == null:
		push_warning("[DG] Wall piece scenes NOT set (plain=%s p1=%s p2=%s). Skipping placement."
			% [str(wall_plain_scene), str(wall_pillar1_scene), str(wall_pillar2_scene)])
		
		return

	# Aggregated counters
	var placed_total: int = 0
	var placed_south: int = 0
	var placed_east: int = 0
	var skipped_closed_cell: int = 0
	var skipped_reserved_s: int = 0
	var skipped_reserved_e: int = 0

	# Lightweight sampling log budget
	var sample_budget: int = 5

	for z: int in range(height):
		for x: int in range(width):
			var i: int = MazeGen.idx(x, z, width)
			var m: int = open[i]
			if m == 0:
				skipped_closed_cell += 1
				continue

			# SOUTH edge
			if (m & MazeGen.MASK[MazeGen.S]) == 0 and z + 1 < height:
				if not _edge_touches_reserved_local(reserved, width, height, x, z, x, z + 1):
					var left_flush: bool = _has_s_wall(open, x - 1, z)
					var right_flush: bool = _has_s_wall(open, x + 1, z)
					var ends_open: int = (0 if left_flush else 1) + (0 if right_flush else 1)

					var kind: int = 0
					if ends_open == 0:
						kind = 0
					elif ends_open == 2:
						kind = 2
					else:
						kind = 2

					_place_wall_segment(x, z, MazeGen.S, kind)
					placed_total += 1
					placed_south += 1
					if sample_budget > 0:
						
						sample_budget -= 1
				else:
					skipped_reserved_s += 1

			# EAST edge
			if (m & MazeGen.MASK[MazeGen.E]) == 0 and x + 1 < width:
				if not _edge_touches_reserved_local(reserved, width, height, x, z, x + 1, z):
					var up_flush: bool = _has_e_wall(open, x, z - 1)
					var down_flush: bool = _has_e_wall(open, x, z + 1)
					var ends_open_e: int = (0 if up_flush else 1) + (0 if down_flush else 1)

					var kind_e: int = 0
					if ends_open_e == 0:
						kind_e = 0
					elif ends_open_e == 2:
						kind_e = 2
					else:
						kind_e = 2

					_place_wall_segment(x, z, MazeGen.E, kind_e)
					placed_total += 1
					placed_east += 1
					if sample_budget > 0:
						
						sample_budget -= 1
				else:
					skipped_reserved_e += 1
					
	_skin_perimeter_walls_from_topology(open, reserved)
	# Final summary / counts
	var wp_after: Node3D = _ensure_wallpieces_root()
	var child_count: int = wp_after.get_child_count() if wp_after != null else -1
	
	
func _skin_perimeter_walls_from_topology(open: PackedInt32Array, reserved: PackedByteArray) -> void:
	var placed := 0

	# --- TOP row (z = 0) → NORTH edges
	var top_z := 0
	for xi in range(width):
		var i := MazeGen.idx(xi, top_z, width)
		if open[i] == 0: continue
		if reserved.size() > 0 and reserved[i] != 0: continue
		if _has_wall_dir(open, xi, top_z, MazeGen.N):
			var left_flush  := (xi > 0) and _has_wall_dir(open, xi - 1, top_z, MazeGen.N)
			var right_flush := (xi + 1 < width) and _has_wall_dir(open, xi + 1, top_z, MazeGen.N)
			var kind := (0 if (left_flush and right_flush) else 2)
			_place_wall_segment(xi, top_z, MazeGen.N, kind)
			placed += 1

	# --- LEFT column (x = 0) → WEST edges
	var left_x := 0
	for zi in range(height):
		var i2 := MazeGen.idx(left_x, zi, width)
		if open[i2] == 0: continue
		if reserved.size() > 0 and reserved[i2] != 0: continue
		if _has_wall_dir(open, left_x, zi, MazeGen.W):
			var up_flush   := (zi > 0) and _has_wall_dir(open, left_x, zi - 1, MazeGen.W)
			var down_flush := (zi + 1 < height) and _has_wall_dir(open, left_x, zi + 1, MazeGen.W)
			var kind2 := (0 if (up_flush and down_flush) else 2)
			_place_wall_segment(left_x, zi, MazeGen.W, kind2)
			placed += 1

	# --- BOTTOM row (z = height - 1) → SOUTH edges
	var bottom_z := height - 1
	for xi2 in range(width):
		var i3 := MazeGen.idx(xi2, bottom_z, width)
		if open[i3] == 0: continue
		if reserved.size() > 0 and reserved[i3] != 0: continue
		if _has_wall_dir(open, xi2, bottom_z, MazeGen.S):
			var left_flush_b  := (xi2 > 0) and _has_wall_dir(open, xi2 - 1, bottom_z, MazeGen.S)
			var right_flush_b := (xi2 + 1 < width) and _has_wall_dir(open, xi2 + 1, bottom_z, MazeGen.S)
			var kind3 := (0 if (left_flush_b and right_flush_b) else 2)
			_place_wall_segment(xi2, bottom_z, MazeGen.S, kind3)
			placed += 1

	# --- RIGHT column (x = width - 1) → EAST edges
	var right_x := width - 1
	for zi2 in range(height):
		var i4 := MazeGen.idx(right_x, zi2, width)
		if open[i4] == 0: continue
		if reserved.size() > 0 and reserved[i4] != 0: continue
		if _has_wall_dir(open, right_x, zi2, MazeGen.E):
			var up_flush_r   := (zi2 > 0) and _has_wall_dir(open, right_x, zi2 - 1, MazeGen.E)
			var down_flush_r := (zi2 + 1 < height) and _has_wall_dir(open, right_x, zi2 + 1, MazeGen.E)
			var kind4 := (0 if (up_flush_r and down_flush_r) else 2)
			_place_wall_segment(right_x, zi2, MazeGen.E, kind4)
			placed += 1

	


# =============================================================
# Ceilings
# =============================================================
func _ensure_ceilings_gridmap() -> GridMap:
	var gm: GridMap = get_node_or_null("GridCeilings") as GridMap
	if gm == null:
		gm = GridMap.new()
		gm.name = "GridCeilings"
		gm.mesh_library = gm_floor.mesh_library
		gm.cell_size = gm_floor.cell_size
		add_child(gm)
	return gm

func _paint_ceilings(open: PackedInt32Array, reserved: PackedByteArray) -> void:
	var gm := _ensure_ceilings_gridmap()
	gm.clear()

	var id_ceiling := MeshLibTools.find_any(gm_floor.mesh_library, PackedStringArray([String(ceiling_name), "ceiling_tile"]))
	if id_ceiling < 0:
		id_ceiling = _id_floor

	var y_off := (_floor_top_y + _wall_height - ceiling_epsilon -.35)
	
	gm.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, y_off, 0.0))

	for z: int in range(height):
		for x: int in range(width):
			var i := MazeGen.idx(x, z, width)
			if open[i] == 0: continue
			if reserved.size() > 0 and reserved[i] != 0: continue
			gm.set_cell_item(Vector3i(x, 0, z), id_ceiling, 0)

# =============================================================
# Light manager helper
# =============================================================
func _ensure_light_mgr() -> DungeonLight:
	if light_mgr == null:
		# Prefer explicit path if provided
		if light_mgr_path != NodePath() and has_node(light_mgr_path):
			light_mgr = get_node(light_mgr_path) as DungeonLight
		else:
			# Try a child named "DungeonLight"
			light_mgr = get_node_or_null("DungeonLight") as DungeonLight
			if light_mgr == null:
				light_mgr = DungeonLight.new()
				light_mgr.name = "DungeonLight"
				add_child(light_mgr)
	return light_mgr

func _light_cfg() -> Dictionary:
	var lm := light_mgr
	if lm == null:
		return {}
	return {
		"torch_light_energy":        lm.torch_light_energy,
		"torch_light_color":         lm.torch_light_color,
		"torch_light_range":         lm.torch_light_range,
		"torch_light_shadows":       lm.torch_light_shadows,
		"torch_shadow_bias":         lm.torch_shadow_bias,
		"torch_shadow_normal_bias":  lm.torch_shadow_normal_bias,
		"torch_group_count":         lm.torch_group_count,
		"torch_group_active":        lm.torch_group_active,
		"torch_min_segment_gap":     lm.torch_min_segment_gap,
		"torch_spawn_chance":        lm.torch_spawn_chance,
		"torch_cross_gap_cells":     lm.torch_cross_gap_cells,
		"torch_min_world_dist_m":    lm.torch_min_world_dist_m,
		"torch_debug_verbose":       lm.torch_debug_verbose,
	}

# =============================================================
# Misc helpers used by key placement
# =============================================================
func _snap_key_to_ground(p: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	var start := p + Vector3(0, 10.0, 0)
	var end   := p + Vector3(0, -50.0, 0)

	var exclude: Array[RID] = []
	for _i in range(6):
		var q := PhysicsRayQueryParameters3D.create(start, end)
		q.collision_mask = 1
		q.collide_with_areas = false
		q.collide_with_bodies = true
		q.exclude = exclude

		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return Vector3(p.x, _floor_top_y + key_height_m, p.z)

		var n: Vector3 = hit.normal
		if n.y >= 0.2:
			return Vector3(p.x, float(hit.position.y) + key_height_m, p.z)

		if hit.has("rid"):
			exclude.append(hit["rid"])
	return Vector3(p.x, _floor_top_y + key_height_m, p.z)

func _spot_is_clear(p: Vector3, radius: float) -> bool:
	var space := get_world_3d().direct_space_state
	var shape := SphereShape3D.new()
	shape.radius = radius
	var xf := Transform3D(Basis.IDENTITY, p)
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform = xf
	q.margin = 0.02
	q.collision_mask = 1
	var hits := space.intersect_shape(q, 1)
	return hits.is_empty()

func _find_clear_spot_around(p: Vector3, radius: float, step: float) -> Vector3:
	if _spot_is_clear(p, 0.25):
		return p
	var r := step
	while r <= radius:
		var samples := int(max(8, floor(PI * 2.0 * r / step)))
		for i in range(samples):
			var ang := float(i) / float(samples) * TAU
			var cand := Vector3(p.x + cos(ang) * r, p.y, p.z + sin(ang) * r)
			var on_ground := _snap_key_to_ground(cand)
			if _spot_is_clear(on_ground, 0.25):
				return on_ground
		r += step
	return p

# ---- Public API for LevelManager ----
func get_current_level_cfg() -> Dictionary:
	return {
		"seed": rng_seed,
		"width": width,
		"height": height,
		"room_attempts": room_attempts,
		"room_max": room_max,
		"unlocked": false, # filled by LevelManager when leaving floor
	}

func build_level(seed: int, w: int, h: int, ra: int, rm: int, force_finish_unlocked: bool=false) -> void:
	rng_seed = seed
	width = w
	height = h
	room_attempts = ra
	room_max = rm
	_apply_seed(false)
	_generate_and_paint()
	if force_finish_unlocked:
		_unlock_finish_doors()

func _key_is_clear(p: Vector3, radius: float) -> bool:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	var qp := PhysicsShapeQueryParameters3D.new()
	qp.shape = sphere
	qp.transform = Transform3D(Basis.IDENTITY, p)
	qp.collision_mask = 1
	qp.collide_with_areas = true
	qp.collide_with_bodies = true
	var hits: Array = space.intersect_shape(qp, 8)
	return hits.is_empty()

func _snap_to_floor_y(p: Vector3) -> Vector3:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var from: Vector3 = p + Vector3(0, 3.0, 0)
	var to:   Vector3 = p + Vector3(0, -6.0, 0)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 1
	q.collide_with_bodies = true
	q.collide_with_areas = false
	var hit: Dictionary = space.intersect_ray(q)
	if hit.has("position"):
		var hp: Vector3 = hit["position"]
		hp.y += key_height_m
		return hp
	return Vector3(p.x, _floor_top_y + key_height_m, p.z)

# =============================================================
# Debug utils
# =============================================================
func _dbg(msg: String) -> void:
	if debug_verbose:
		print("[DG/DBG] ", msg)

func _dbg_node3d(n: Node3D) -> String:
	if n == null:
		return "<null>"
	return "path=" + str(n.get_path()) \
		+ " vis=" + str(n.visible) \
		+ " pos=" + str(n.global_transform.origin)

func _dbg_light_summary(n: Node3D) -> String:
	if n == null:
		return "<none>"
	var l: OmniLight3D = n as OmniLight3D
	if l != null:
		return "E=" + str(l.light_energy) + " R=" + str(l.omni_range) \
			+ " shadows=" + ( "on" if l.shadow_enabled else "off" )
	if n.has_node(^"Torch"):
		var c: OmniLight3D = n.get_node(^"Torch") as OmniLight3D
		if c != null:
			return "E=" + str(c.light_energy) + " R=" + str(c.omni_range) \
				+ " shadows=" + ( "on" if c.shadow_enabled else "off" )
	return "<no light found>"

func _dbg_find_wallpieces_root() -> Node3D:
	return _ensure_wallpieces_root()

func _dbg_count_children(n: Node) -> int:
	if n == null:
		return 0
	var c: int = 0
	for child in n.get_children():
		c += 1
	return c

func _dbg_dump_wallpieces_once() -> void:
	var wp: Node3D = _dbg_find_wallpieces_root()
	if wp == null:
		_dbg("WallPieces: <none>")
		return
	var total: int = 0
	var with_light: int = 0
	for ch in wp.get_children():
		total += 1
		var n3: Node3D = ch as Node3D
		if n3 != null:
			var lsum: String = _dbg_light_summary(n3)
			if lsum != "<no light found>":
				with_light += 1
	_dbg("WallPieces children=" + str(total) + " with_light=" + str(with_light))


#delete after testing
# Make/clear the reserved bitmap for this level and log its size.
func _alloc_reserved(cols: int, rows: int) -> PackedByteArray:
	var reserved := PackedByteArray()
	reserved.resize(cols * rows)
	for i in range(cols * rows):
		reserved[i] = 0
	_dbg_reserved_size(cols, rows, reserved) # <— DEBUG (item 3)
	return reserved

# Compute a Rect2i for a prefab according to its placement mode + margins.
func _reserve_rect_for_spec(
	spec: PrefabSpec, cols: int, rows: int,
	rng: RandomNumberGenerator,
	reserved: PackedByteArray
) -> Rect2i:
	# desired size, clamped to grid
	var w: int = clamp(spec.size_cells.x, 1, cols)
	var h: int = clamp(spec.size_cells.y, 1, rows)
	var mg: int = max(0, spec.margin_cells)

	# search bounds honoring margin
	var min_x: int = mg
	var min_z: int = mg
	var max_x: int = max(mg, cols - w - mg)
	var max_z: int = max(mg, rows - h - mg)

	match spec.placement_mode:
		# Fixed
		2:
			var fx: int = clamp((spec.fixed_cell.x if spec.fixed_cell.x >= 0 else min_x), min_x, max_x)
			var fz: int = clamp((spec.fixed_cell.y if spec.fixed_cell.y >= 0 else min_z), min_z, max_z)
			var rf: Rect2i = Rect2i(fx, fz, w, h)
			return rf if _can_fit_rect(reserved, rf, mg) else Rect2i()

		# Center (fallback to random / scan if center blocked)
		0:
			var cx: int = clamp(cols / 2 - w / 2, min_x, max_x)
			var cz: int = clamp(rows / 2 - h / 2, min_z, max_z)
			var rc: Rect2i = Rect2i(cx, cz, w, h)
			if _can_fit_rect(reserved, rc, mg):
				return rc
			# try random positions
			for _i: int in range(200):
				var rx: int = rng.randi_range(min_x, max_x)
				var rz: int = rng.randi_range(min_z, max_z)
				var rr: Rect2i = Rect2i(rx, rz, w, h)
				if _can_fit_rect(reserved, rr, mg):
					
					return rr
			# final scan sweep
			for z: int in range(min_z, max_z + 1):
				for x: int in range(min_x, max_x + 1):
					var rs: Rect2i = Rect2i(x, z, w, h)
					if _can_fit_rect(reserved, rs, mg):
						
						return rs
			return Rect2i()

		# Random (default)
		_:
			for _i: int in range(200):
				var rx: int = rng.randi_range(min_x, max_x)
				var rz: int = rng.randi_range(min_z, max_z)
				var rr: Rect2i = Rect2i(rx, rz, w, h)
				if _can_fit_rect(reserved, rr, mg):
					return rr
			for z: int in range(min_z, max_z + 1):
				for x: int in range(min_x, max_x + 1):
					var rs: Rect2i = Rect2i(x, z, w, h)
					if _can_fit_rect(reserved, rs, mg):
						return rs
			return Rect2i()


func _dbg_reserved_size(cols: int, rows: int, reserved: PackedByteArray) -> void:
	var nz := 0
	for i in range(reserved.size()):
		if reserved[i] != 0:
			nz += 1
	

func _dbg_rect_world(prefix: String, r: Rect2i, gm: GridMap) -> void:
	var corners: Array[Vector2i] = [
		r.position,
		Vector2i(r.position.x + r.size.x, r.position.y),
		Vector2i(r.position.x + r.size.x, r.position.y + r.size.y),
		Vector2i(r.position.x,           r.position.y + r.size.y),
	]
	for i in range(corners.size()):
		var c: Vector2i = corners[i]
		var w := gm.transform * gm.map_to_local(Vector3i(c.x, 0, c.y))
		
	var cx := r.position.x + r.size.x / 2
	var cz := r.position.y + r.size.y / 2
	var center_w := gm.transform * gm.map_to_local(Vector3i(cx, 0, cz))
	

func _dbg_reserved_check(prefix: String, reserved: PackedByteArray, cols: int, rows: int, r: Rect2i) -> void:
	var marked := 0
	var samples: Array[Vector2i] = []
	for z in range(r.position.y, r.position.y + r.size.y):
		for x in range(r.position.x, r.position.x + r.size.x):
			var idx := MazeGen.idx(x, z, cols)
			if idx >= 0 and idx < reserved.size() and reserved[idx] != 0:
				marked += 1
				if samples.size() < 8:
					samples.append(Vector2i(x, z))
	

func _dbg_doors_for_rect(prefix: String, cols: int, rows: int, r: Rect2i) -> Array[Vector2i]:
	var doors: Array[Vector2i] = MazeGen.door_cells_for_rect(cols, rows, r)
	
	return doors

func _dbg_runtime_prefabs(root: Node) -> void:
	var rt := root.get_node_or_null(^"RuntimePrefabs") as Node3D
	if rt == null:
		
		return
	
	for ch in rt.get_children():
		var n3 := ch as Node3D
		if n3 != null:
			print("  •", n3.name, " @ ", n3.global_transform.origin)

func _disable_gridmap_collisions() -> void:
	if gm_floor:  _strip_gridmap_colliders(gm_floor)
	if gm_walls:  _strip_gridmap_colliders(gm_walls)
	if gm_ceilings: _strip_gridmap_colliders(gm_ceilings)

func _strip_gridmap_colliders(gm: GridMap) -> void:
	if gm == null:
		return

	# Make sure the GridMap itself has no physics.
	gm.collision_layer = 0
	gm.collision_mask  = 0

	# Recursively delete any StaticBody/Area that GridMap spawned
	# (often under a "Collision" node).
	var removed := _strip_under(gm)
	if removed > 0:
		print("[GRIDMAP] stripped ", removed, " auto-collider nodes from ", gm.name)

func _strip_under(n: Node) -> int:
	var count := 0
	for c in n.get_children():
		if c is StaticBody3D or c is Area3D or c.name.to_lower().begins_with("collision"):
			c.queue_free()              # ← just call it, no assignment
			count += 1
		else:
			count += _strip_under(c)    # recurse
	return count
		
func _mask_at(open: PackedInt32Array, x: int, z: int) -> int:
	if x < 0 or z < 0 or x >= width or z >= height:
		return 0
	return open[MazeGen.idx(x, z, width)]

func _has_wall_dir(open: PackedInt32Array, x: int, z: int, dir: int) -> bool:
	var m := _mask_at(open, x, z)
	match dir:
		MazeGen.N: return (m & MazeGen.MASK[MazeGen.N]) == 0
		MazeGen.S: return (m & MazeGen.MASK[MazeGen.S]) == 0
		MazeGen.W: return (m & MazeGen.MASK[MazeGen.W]) == 0
		_:         return (m & MazeGen.MASK[MazeGen.E]) == 0

func _snap_y_to_floor_player(base_world_pos: Vector3) -> float:
	if not snap_down_on_spawn:
		return base_world_pos.y

	var cushion := clampf(spawn_y_offset, 0.0, 0.5)
	var from := base_world_pos + Vector3(0, max(0.5, cushion), 0)
	var to   := base_world_pos + Vector3(0, -snap_down_max, 0)

	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = snap_mask
	q.collide_with_areas = false
	q.collide_with_bodies = true

	var dss := get_viewport().world_3d.direct_space_state
	var hit := dss.intersect_ray(q)
	if hit.is_empty():
		return _floor_top_y + cushion
	return (hit["position"] as Vector3).y + cushion


func _apply_first_spawn_yaw_if_needed(p: Node3D) -> void:
	if not apply_first_spawn_yaw or _did_initial_spawn:
		return
	var pivot := (p.get_node_or_null(yaw_pivot_path) as Node3D) if yaw_pivot_path != NodePath() else null
	if pivot == null:
		pivot = p
	pivot.rotate_y(deg_to_rad(first_spawn_yaw_deg))
	_did_initial_spawn = true
	
# ---------------- Enemies and Loot Helpers -----------------
func _ensure_anchors_root() -> Node3D:
	var r: Node3D = get_node_or_null("Anchors") as Node3D
	if r == null:
		r = Node3D.new()
		r.name = "Anchors"
		add_child(r)
	return r

func _clear_anchors() -> void:
	var r: Node3D = get_node_or_null("Anchors") as Node3D
	if r != null:
		r.queue_free()

func _cell_center_world(cx: int, cz: int) -> Vector3:
	var local: Vector3 = gm_floor.map_to_local(Vector3i(cx, 0, cz))
	return gm_floor.transform * local

func build_anchors_for_floor(floor: int) -> void:
	if triad_rules == null:
		triad_rules = TriadRules.new()
	if _last_open.is_empty():
		push_warning("[DG] build_anchors_for_floor: _last_open is empty; call after _generate_and_paint.")
		return

	# Forbidden points: finish door, boss anchor, player (if present)
	var forbidden: Array[Vector3] = []
	if _finish_door != null:
		var nd3: Node3D = _finish_door as Node3D
		if nd3 != null:
			forbidden.append(nd3.global_transform.origin)
	var boss_anchor: Node3D = _find_named_node_recursive("Anchor_Boss")
	if boss_anchor != null:
		forbidden.append(boss_anchor.global_transform.origin)
	if player_path != NodePath():
		var p: Node3D = get_node_or_null(player_path) as Node3D
		if p != null:
			forbidden.append(p.global_transform.origin)

	var mask_builder := AnchorMaskBuilder.new(gm_floor, width, height, _last_open, _last_reserved)
	for p_world in forbidden:
		if p_world != Vector3.INF:
			mask_builder.push_forbidden(p_world)

	var mask: PackedByteArray = mask_builder.build_valid_mask(
		triad_rules.perim_buffer_cells,
		triad_rules.door_buffer_m,
		triad_rules.start_buffer_m
	)
	var candidates: Array[Vector2i] = mask_builder.collect_candidates(mask)
	var cell_sz: float = mask_builder.cell_size()

	var e_count: int = max(0, triad_rules.elite_count_for_floor(floor))
	var t_count: int = max(0, triad_rules.treasure_count_for_floor(floor, e_count))

	var rng_local := RandomNumberGenerator.new()
	rng_local.seed = int(rng_seed) ^ int(floor) ^ 0xE17E11

	var elites: Array[Vector2i] = EliteAnchorPlacer.place(
		e_count,
		candidates,
		cell_sz,
		triad_rules.elite_min_dist_m,
		rng_local,
		_count_mask_ones(mask),
		triad_rules.area_target_m2_per_elite
	)

	var treasures: Array[Vector2i] = TreasureAnchorPlacer.place(
		t_count,
		candidates,
		cell_sz,
		triad_rules.treasure_min_dist_m,
		elites,
		triad_rules.elite_treasure_min_dist_m,
		rng_local
	)

	_clear_anchors()
	var root: Node3D = _ensure_anchors_root()
	var elite_root := Node3D.new(); elite_root.name = "EliteAnchors"; root.add_child(elite_root)
	var treasure_root := Node3D.new(); treasure_root.name = "TreasureAnchors"; root.add_child(treasure_root)

	var elite_xforms: Array[Transform3D] = []
	var treasure_xforms: Array[Transform3D] = []

	# ---- PRINT COORDS FOR ELITES ----
	for i in range(elites.size()):
		var c: Vector2i = elites[i]
		var w: Vector3 = _cell_center_world(c.x, c.y)
		w.y = _floor_y_at_point(w, 0.02)
		var n := Marker3D.new()
		n.name = "EliteAnchor_%03d" % i
		n.global_transform = Transform3D(Basis.IDENTITY, w)
		n.add_to_group(&"elite_anchor")
		elite_root.add_child(n)
		elite_xforms.append(n.global_transform)
		

	# ---- PRINT COORDS FOR TREASURES ----
	for i in range(treasures.size()):
		var c2: Vector2i = treasures[i]
		var w2: Vector3 = _snap_to_floor_anchor(_cell_center_world(c2.x, c2.y), treasure_anchor_y_offset_m)
		var n2 := Marker3D.new()
		n2.name = "TreasureAnchor_%03d" % i
		n2.global_transform = Transform3D(Basis.IDENTITY, w2)
		n2.add_to_group(&"treasure_anchor")
		treasure_root.add_child(n2)
		treasure_xforms.append(n2.global_transform)
		

	var reg: Node = get_node_or_null("/root/AnchorRegistry") as Node
	if reg != null:
		reg.call("set_floor_anchors", floor, elite_xforms, treasure_xforms)
	
func _count_mask_ones(mask: PackedByteArray) -> int:
	var n: int = 0
	for i in range(mask.size()):
		if mask[i] == 1:
			n += 1
	return n

func _find_named_node_recursive(name_sought: String) -> Node3D:
	var root: Node = self
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur.name == name_sought:
			return cur as Node3D
		for child in cur.get_children():
			stack.push_back(child)
	return null

func get_floor_navdata() -> Dictionary:
	# Compute finish cell if we have a door node
	var finish_cell: Vector2i = Vector2i(-1, -1)
	if _finish_door != null:
		var d3: Node3D = _finish_door as Node3D
		if d3 != null:
			var local: Vector3 = gm_floor.transform.affine_inverse() * d3.global_transform.origin
			var cx: int = int(floor(local.x / gm_floor.cell_size.x + 0.5))
			var cz: int = int(floor(local.z / gm_floor.cell_size.x + 0.5))
			finish_cell = Vector2i(cx, cz)

	return {
		"width": width,
		"height": height,
		"cell_size": gm_floor.cell_size.x,
		"grid_transform": gm_floor.transform,
		"reserved": _last_reserved,
		"open": _last_open,
		"finish_cell": finish_cell
	}
	
func populate_elites_and_boss(floor: int) -> void:
	# Clear previous population if any (keeps earlier floors empty once drained).
	var pop_root: Node3D = get_node_or_null("Population") as Node3D
	if pop_root != null:
		pop_root.queue_free()
	pop_root = Node3D.new()
	pop_root.name = "Population"
	add_child(pop_root)

	if gm_floor == null:
		push_warning("[DG][Populate] gm_floor is null; aborting.")
		return

	# --- Slot-aware run reads ---
	var slot_i: int = SaveManager.active_slot()

	# --- Early-out: drained floor/segment (backtracking or earlier triads) ---
	# Use RUN.furthest_depth_reached as the authoritative drain rule.
	var rs: Dictionary = SaveManager.load_run(slot_i)
	var furthest: int = int(rs.get("furthest_depth_reached", int(rs.get("depth", 1))))
	if floor < furthest:
		if debug_verbose:
			print("[DG][Populate] skip: floor ", floor, " < furthest_depth_reached=", furthest, " (drained)")
		return

	# Optional: honor segment drain flag if you choose to set it elsewhere.
	var _ASeg := preload("res://persistence/services/anchor_segment_service.gd")
	if _ASeg.is_segment_drained_by_floor(floor, slot_i):
		if debug_verbose:
			print("[DG][Populate] skip: segment drained for floor ", floor)
		return

	# --- Elite anchors ---
	var elite_root: Node = get_node_or_null(^"Anchors/EliteAnchors")
	if elite_root != null:
		var enc := get_node_or_null(^"/root/EncounterDirector")
		var i: int = 0
		for n in elite_root.get_children():
			var a: Node3D = n as Node3D
			if a == null:
				continue

			# Convert world -> grid cell
			var local: Vector3 = gm_floor.transform.affine_inverse() * a.global_transform.origin
			var cs: float = gm_floor.cell_size.x
			var cx: int = int(round(local.x / cs))
			var cz: int = int(round(local.z / cs))
			var cell: Vector2i = Vector2i(cx, cz)

			# Skip if anchor fell on a reserved (prefab) cell
			var reserved_hit := false
			if not _last_reserved.is_empty():
				if cell.x < 0 or cell.x >= width or cell.y < 0 or cell.y >= height:
					reserved_hit = true
				else:
					var idx: int = MazeGen.idx(cell.x, cell.y, width)
					reserved_hit = (idx < 0 or idx >= _last_reserved.size() or _last_reserved[idx] != 0)
			if reserved_hit:
				i += 1
				continue

			# Pick monster from EncounterDirector
			var pick: StringName = &""
			if enc != null and enc.has_method("pick_elite_for_anchor"):
				pick = enc.call("pick_elite_for_anchor", floor, i)

			# Spawn
			var e := EliteSpawner.new()
			e.monster_id = pick

			var pos := a.global_transform.origin
			pos.y = _floor_y_at_point(pos, 0.02) + elite_anchor_y_offset_m
			e.global_transform = Transform3D(Basis.IDENTITY, pos)

			pop_root.add_child(e)
			i += 1

	# --- Boss on multiples of 3 ---
	if floor > 0 and (floor % 3) == 0:
		var boss_anchor: Node3D = _find_named_node_recursive("Anchor_Boss")
		if boss_anchor != null:
			# Convert world -> grid cell
			var local_b: Vector3 = gm_floor.transform.affine_inverse() * boss_anchor.global_transform.origin
			var cs_b: float = gm_floor.cell_size.x
			var cbx: int = int(round(local_b.x / cs_b))
			var cbz: int = int(round(local_b.z / cs_b))
			var cell_b: Vector2i = Vector2i(cbx, cbz)

			# Skip if reserved
			var reserved_b := false
			if not _last_reserved.is_empty():
				if cell_b.x < 0 or cell_b.x >= width or cell_b.y < 0 or cell_b.y >= height:
					reserved_b = true
				else:
					var idx_b: int = MazeGen.idx(cell_b.x, cell_b.y, width)
					reserved_b = (idx_b < 0 or idx_b >= _last_reserved.size() or _last_reserved[idx_b] != 0)
			if reserved_b:
				return

			# Determine boss
			var enc2 := get_node_or_null(^"/root/EncounterDirector")
			var boss_id: StringName = &""
			if enc2 != null and enc2.has_method("get_boss_for_floor"):
				boss_id = enc2.call("get_boss_for_floor", floor)

			# Spawn (kept at root like your original code)
			var b := BossSpawner.new()
			b.monster_id = boss_id

			var pos_b := boss_anchor.global_transform.origin
			pos_b.y = _floor_y_at_point(pos_b, 0.02)
			b.global_transform = Transform3D(Basis.IDENTITY, pos_b)
			add_child(b)

	# --- Treasure anchors ---
	var treasure_root: Node = get_node_or_null(^"Anchors/TreasureAnchors")
	if treasure_root != null:
		var ti: int = 0
		for n2: Node in treasure_root.get_children():
			var ta: Node3D = n2 as Node3D
			if ta == null:
				continue
			var t: TreasureSpawner = TreasureSpawner.new()
			if treasure_chest_scene != null:
				t.chest_scene = treasure_chest_scene
			var pos2: Vector3 = _snap_to_floor_anchor(ta.global_transform.origin, treasure_anchor_y_offset_m)
			t.global_transform = Transform3D(Basis.IDENTITY, pos2)
			pop_root.add_child(t)
			ti += 1



func _snap_to_floor_anchor(p: Vector3, y_off: float = 0.0) -> Vector3:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var from: Vector3 = p + Vector3(0, 3.0, 0)
	var to:   Vector3 = p + Vector3(0, -6.0, 0)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 1
	q.collide_with_bodies = true
	q.collide_with_areas = false
	var hit: Dictionary = space.intersect_ray(q)
	if hit.has("position"):
		var hp: Vector3 = hit["position"]
		hp.y += y_off
		return hp
	return Vector3(p.x, _floor_top_y + y_off, p.z)
	
func _floor_y_at_point(base_world_pos: Vector3, cushion: float = 0.02) -> float:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var from: Vector3 = base_world_pos + Vector3(0, 3.0, 0)
	var to:   Vector3 = base_world_pos + Vector3(0, -6.0, 0)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 1
	q.collide_with_bodies = true
	q.collide_with_areas = false
	var hit: Dictionary = space.intersect_ray(q)
	if hit.has("position"):
		return float(hit["position"].y) + cushion
	return _floor_top_y + cushion

func _snap_to_floor_surface(p: Vector3, cushion: float = 0.02) -> Vector3:
	return Vector3(p.x, _floor_y_at_point(p, cushion), p.z)
