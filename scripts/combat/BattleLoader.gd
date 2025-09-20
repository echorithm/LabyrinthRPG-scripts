extends Node
## In-place battles with the labyrinth as backdrop.

signal battle_started(payload: Dictionary)

# --- Debugging ---
@export var debug_logs: bool = true

func _fmt_v3(v: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [v.x, v.y, v.z]

func _yaw_deg_of(basis: Basis) -> float:
	var f: Vector3 = -basis.z
	f.y = 0.0
	f = f.normalized()
	return rad_to_deg(atan2(f.x, f.z))

func _dbg(msg: String) -> void:
	if debug_logs:
		print(msg)

func _dbg_warn(msg: String) -> void:
	if debug_logs:
		push_warning(msg)

# --- Data / calc deps ---
const PowerAllocator   := preload("res://scripts/combat/allocation/PowerAllocator.gd")
const DerivedCalc      := preload("res://scripts/combat/derive/DerivedCalc.gd")
const CTBParams        := preload("res://scripts/combat/ctb/CTBParams.gd")
const MonsterRuntime   := preload("res://scripts/combat/snapshot/MonsterRuntime.gd")
const PlayerRuntime    := preload("res://scripts/combat/snapshot/PlayerRuntime.gd")
const BattleController := preload("res://scripts/combat/BattleController.gd")
const AnimAuto         := preload("res://scripts/dungeon/encounters/AnimAuto.gd")

var _router: Node = null
var _catalog: MonsterCatalog = null

# --- Nodes created per battle ---
var _anchor: Node3D = null
var _monster_visual: Node3D = null
var _battle_cam: Camera3D = null
var _saved_camera: Camera3D = null

# --- Spawn/placement tunables ---
@export var desired_distance_m: float = 2.6
@export var min_distance_m: float = 2.4
@export var max_distance_m: float = 4.5

# Corridor sweep
@export var front_back_margin: float = 0.6   # keep from kissing the wall

# Radial sweep
@export var radial_angle_step_deg: int = 20
@export var radial_ring_scales: PackedFloat32Array = PackedFloat32Array([1.0, 1.25, 1.5, 1.8])

# Ground probing
@export var ground_probe_height: float = 3.0
@export var ground_probe_depth: float  = 6.0
@export var max_floor_delta: float     = 0.9   # reject wall tops / ceilings

# Clearance capsule
@export var spawn_clear_radius: float = 0.6
@export var spawn_clear_height: float = 1.8

# Query mask for ray/shape tests (default: all layers)
@export var spawn_query_mask: int = 0xFFFFFFFF

# Line of sight
@export var require_line_of_sight: bool = true
@export var cam_eye_height: float = 1.6

# Monster facing offset (deg; add/sub small twists if a model faces 180° off)
@export var monster_yaw_offset_deg: float = 180.0

# --- BattleCam tuning ---
@export var battle_cam_height: float = 1.0
@export var battle_cam_distance: float = 3.2
@export var battle_cam_side_offset: float = 0.6
@export var battle_cam_fov: float = 60.0
@export var monster_look_height: float = 1.2

# Clearance / camera quality-of-life
@export var ignore_overlap_name_fragments: PackedStringArray = PackedStringArray(["FloorTile", "Floor", "Ground"])
@export var camera_wall_clearance: float = 0.25   # meters to pull camera off walls

# ------------------------------------------------------------------------------

func _ready() -> void:
	_router  = get_node_or_null(^"/root/EncounterRouter")
	_catalog = get_node_or_null(^"/root/MonsterCatalog") as MonsterCatalog
	if _router != null and not _router.is_connected("encounter_requested", Callable(self, "_on_encounter_requested")):
		_router.connect("encounter_requested", Callable(self, "_on_encounter_requested"))
	_dbg("[BL] Ready. Router=%s Catalog=%s" % [str(_router), str(_catalog)])

# --------------------------- Encounter entry ---------------------------------

func _on_encounter_requested(payload: Dictionary) -> void:
	if _catalog == null:
		push_error("[BL] MonsterCatalog autoload missing.")
		return

	var slug: StringName = StringName(String(payload.get("monster_id", "")))
	var entry: Dictionary = _catalog.entry(slug)
	if entry.is_empty():
		push_error("[BL] Monster not found: %s" % [String(slug)])
		return

	var power_level: int = int(payload.get("power_level", 1))
	var role: String = String(payload.get("role", "trash"))
	_dbg("[BL] Encounter requested  slug=%s role=%s power=%d payload=%s" % [String(slug), role, power_level, str(payload)])

	# Allocate + snapshot
	var t0: int = Time.get_ticks_msec()
	var alloc: Dictionary = PowerAllocator.allocate(entry, power_level, null)
	var t1: int = Time.get_ticks_msec()
	if alloc.is_empty():
		push_error("[BL] allocation failed.")
		return
	_dbg("[BL] Allocation time=%d ms" % [t1 - t0])

	var mr := MonsterRuntime.new()
	mr.id = int(entry.get("id", 0))
	mr.slug = slug
	mr.display_name = String(entry.get("display_name", String(slug)))
	mr.scene_path = String(entry.get("scene_path", ""))
	mr.role = role
	mr.level_baseline = int(alloc.get("level_baseline", 1))
	mr.final_level = int(alloc.get("final_level", mr.level_baseline))
	mr.base_stats = alloc.get("base_stats", {})
	mr.final_stats = alloc.get("final_stats", {})
	mr.ability_levels = alloc.get("ability_levels", {})
	mr.abilities = alloc.get("abilities", [])
	mr.hp_max = DerivedCalc.hp_max(mr.final_stats, {})
	mr.mp_max = DerivedCalc.mp_max(mr.final_stats, {})
	mr.hp = max(1, mr.hp_max)
	mr.mp = max(0, mr.mp_max)
	mr.p_atk = DerivedCalc.p_atk(mr.final_stats)
	mr.m_atk = DerivedCalc.m_atk(mr.final_stats)
	mr.defense = DerivedCalc.defense(mr.final_stats)
	mr.resistance = DerivedCalc.resistance(mr.final_stats)
	mr.crit_chance = DerivedCalc.crit_chance(mr.final_stats, {})
	mr.crit_multi  = DerivedCalc.crit_multi(mr.final_stats, {})
	mr.ctb_speed   = DerivedCalc.ctb_speed(mr.final_stats)

	var pr: PlayerRuntime = _build_player_runtime()
	if pr.hp <= 0:
		pr.hp = 1

	_log_runtime_stats(mr, pr)

	_dbg("[BL] Start stats  Player HP=%d/%d  Monster(%s) HP=%d/%d lvl=%d role=%s"
		% [pr.hp, pr.hp_max, String(mr.slug), mr.hp, mr.hp_max, mr.final_level, mr.role])

	var player: Node = _find_player(payload)
	if player == null:
		push_error("[BL] Could not find player node.")
		return

	_log_player_state(player)
	_lock_player(player, true)

	var t2: int = Time.get_ticks_msec()
	var anchor := _place_anchor_and_monster(player, mr)
	var t3: int = Time.get_ticks_msec()
	_dbg("[BL] Spawn search time=%d ms" % [t3 - t2])

	if anchor == null:
		_lock_player(player, false)
		push_error("[BL] Could not place monster anchor.")
		return

	var ctrl := BattleController.new()
	anchor.add_child(ctrl)
	ctrl.setup(mr, pr, CTBParams.new())
	ctrl.battle_finished.connect(_on_battle_finished)

	emit_signal("battle_started", payload)
	_dbg("[BL] battle_started emitted.")

# ------------------------------ Player helpers -------------------------------

func _find_player(payload: Dictionary) -> Node:
	if payload.has("player_path"):
		var p := get_node_or_null(String(payload["player_path"]))
		if p != null:
			_dbg("[BL] Found player via payload path.")
			return p
	var arr: Array = get_tree().get_nodes_in_group("player")
	if arr.size() == 0:
		arr = get_tree().get_nodes_in_group("player_controller")
	if arr.size() > 0:
		_dbg("[BL] Found player via group.")
		return arr[0] as Node
	var cam := get_viewport().get_camera_3d()
	if cam != null and cam.get_owner() != null:
		_dbg("[BL] Using current camera owner as player.")
		return cam.get_owner()
	return null

func _log_player_state(player_any: Node) -> void:
	var p3 := player_any as Node3D
	if p3 == null:
		_dbg_warn("[BL] Player is not Node3D; cannot log coords.")
		return

	var pos: Vector3 = p3.global_transform.origin
	var yaw: float = _yaw_deg_of(p3.global_transform.basis)
	var fwd: Vector3 = _get_forward(p3)
	var eye: Vector3 = pos + Vector3(0, cam_eye_height, 0)

	var step_info: String = ""
	if _has_autoload("RunState"):
		var rs := get_node(^"/root/RunState")
		if rs != null:
			var steps_v: Variant = rs.get("steps")
			if steps_v != null:
				step_info = " steps=%s" % [str(steps_v)]
			var seed_v: Variant = rs.get("seed")
			if seed_v != null:
				step_info += " seed=%s" % [str(seed_v)]

	_dbg("[BL] Player pos=%s yaw=%.1f° fwd=%s eye=%s%s"
		% [_fmt_v3(pos), yaw, _fmt_v3(fwd), _fmt_v3(eye), step_info])

func _lock_player(player: Node, locked: bool) -> void:
	_dbg("[BL] %s player control" % [("LOCK" if locked else "UNLOCK")])

	if locked and player.has_method("enter_battle_lock"):
		player.call("enter_battle_lock")
	elif (not locked) and player.has_method("exit_battle_lock"):
		player.call("exit_battle_lock")

	# Hide HUD bits
	var groups: Array = ["look_stick", "dungeon_hud"]
	for g_any in groups:
		var g: String = String(g_any)
		var nodes: Array = get_tree().get_nodes_in_group(g)
		for n_any in nodes:
			var c := n_any as CanvasItem
			if c != null:
				c.visible = not locked
	_dbg("[BL] HUD groups %s hidden=%s" % [str(groups), str(locked)])

# ------------------------ Anchor / spawn / camera ----------------------------

func _place_anchor_and_monster(player: Node, mr: MonsterRuntime) -> Node3D:
	# Creates anchor, finds a safe spawn near the player, spawns the visual,
	# faces both actors appropriately, and positions the battle camera.
	_anchor = Node3D.new()
	_anchor.name = "BattleAnchor"
	get_tree().get_root().add_child(_anchor)
	_dbg("[BL] Anchor created.")

	var player_node := player as Node3D
	if player_node == null:
		_anchor.queue_free(); _anchor = null
		return null

	var forward: Vector3 = _get_forward(player_node)

	# 1) Corridor front/back sweep
	var res: Dictionary = _find_spawn_point_front_sweep(player_node, forward)
	# 2) Radial fallback
	if not bool(res.get("ok", false)):
		res = _find_spawn_point_radial(player_node, forward)
	# 3) Last resort (drop straight ahead); if still not OK, abort encounter
	if not bool(res.get("ok", false)):
		_dbg_warn("[BL] All probes failed — LAST RESORT at min-distance.")
		var excludes: Array[RID] = _collect_excludes_from(player_node)
		res = _last_resort_position(player_node.global_transform.origin, forward, excludes)
		if not bool(res.get("ok", false)):
			_dbg_warn("[BL] Aborting encounter: could not find a safe spawn.")
			_anchor.queue_free(); _anchor = null
			return null

	var pos: Vector3 = res.get("position", player_node.global_transform.origin + forward * desired_distance_m)
	_anchor.global_transform = Transform3D(Basis(), pos)
	_dbg("[BL] Player @ %s  ->  Spawn @ %s  dist=%.2f"
		% [_fmt_v3(player_node.global_transform.origin), _fmt_v3(pos), player_node.global_transform.origin.distance_to(pos)])

	# Spawn monster visual at the anchor position
	_monster_visual = _catalog.instantiate_visual(_anchor, mr.slug)
	if _monster_visual != null:
		var vt: Transform3D = _monster_visual.global_transform
		vt.origin = pos
		_monster_visual.global_transform = vt
		_face_monster_to_player(_monster_visual, player_node)

		# Play battle idle via shared helper (AnimationPlayer or AnimationTree)
		if not AnimAuto.play_battle_idle(_monster_visual):
			_dbg_warn("[BL][anim] Could not play IdleBattle on monster.")
	else:
		_dbg_warn("[BL] No monster visual for slug=%s" % [String(mr.slug)])

	# Face the player toward the monster and set the transient battle camera
	_face_player_to(pos, player_node)
	_position_battle_cam(pos, player_node)

	return _anchor

func _position_battle_cam(target_pos: Vector3, player_node: Node3D) -> void:
	if _battle_cam == null:
		_battle_cam = Camera3D.new()
		_battle_cam.name = "BattleCam"
		_battle_cam.fov = battle_cam_fov
		_battle_cam.near = 0.05
		_battle_cam.far = 200.0
		if _anchor != null:
			_anchor.add_child(_battle_cam)
		else:
			get_tree().get_root().add_child(_battle_cam)

	var ppos: Vector3 = player_node.global_transform.origin
	var dir: Vector3 = (target_pos - ppos).normalized()
	var side: Vector3 = dir.cross(Vector3.UP).normalized()
	var desired_eye: Vector3 = ppos - dir * battle_cam_distance + side * battle_cam_side_offset + Vector3(0, battle_cam_height, 0)

	# Clamp eye with a ray from target towards desired eye
	var space := get_tree().get_root().world_3d.direct_space_state
	var rq := PhysicsRayQueryParameters3D.create(
		target_pos + Vector3(0, monster_look_height, 0),
		desired_eye
	)

	# Exclude player & monster bodies
	var excludes: Array[RID] = _collect_excludes_from(player_node)
	if is_instance_valid(_monster_visual):
		var mv_body := _monster_visual as PhysicsBody3D
		if mv_body != null:
			excludes.append(mv_body.get_rid())
	rq.exclude = excludes
	rq.collision_mask = spawn_query_mask

	var eye: Vector3 = desired_eye
	var hit := space.intersect_ray(rq)
	if not hit.is_empty():
		var hp: Vector3 = hit.get("position", desired_eye)
		var n: Vector3 = hit.get("normal", Vector3.UP).normalized()
		eye = hp + n * camera_wall_clearance
		if debug_logs:
			var blk := "<unknown>"
			if hit.has("collider") and hit["collider"] != null:
				blk = str(hit["collider"])
			_dbg("[BL][cam] clamped by %s  hit=%s -> eye=%s"
				% [blk, _fmt_v3(hp), _fmt_v3(eye)])

	_battle_cam.global_transform = Transform3D(Basis(), eye)
	_battle_cam.look_at(target_pos + Vector3(0, monster_look_height, 0), Vector3.UP)

	_saved_camera = get_viewport().get_camera_3d()
	if _saved_camera != null:
		_saved_camera.current = false
	_battle_cam.current = true

	_dbg("[BL] BattleCam eye=%s fov=%.1f target=%s (saved=%s)"
		% [_fmt_v3(eye), battle_cam_fov, _fmt_v3(target_pos), str(_saved_camera)])

# --------------------------- Facing helpers ----------------------------------

func _face_monster_to_player(monster_node: Node3D, player_node: Node3D) -> void:
	if monster_node == null or player_node == null:
		return
	var mpos: Vector3 = monster_node.global_transform.origin
	var ppos: Vector3 = player_node.global_transform.origin

	# Current yaw (approx) before
	var cur_fwd: Vector3 = -monster_node.global_transform.basis.z
	cur_fwd.y = 0.0
	cur_fwd = cur_fwd.normalized()
	var to_player: Vector3 = (ppos - mpos); to_player.y = 0.0
	var tgt_fwd: Vector3 = to_player.normalized()

	var yaw_before: float = rad_to_deg(atan2(cur_fwd.x, cur_fwd.z))
	var yaw_target: float = rad_to_deg(atan2(tgt_fwd.x, tgt_fwd.z))
	var yaw_after_exp: float = yaw_target + monster_yaw_offset_deg

	# Apply look_at (yaw only) + optional offset
	var look := Vector3(ppos.x, mpos.y, ppos.z)
	monster_node.look_at(look, Vector3.UP)
	if absf(monster_yaw_offset_deg) > 0.001:
		var b := monster_node.global_transform.basis.rotated(Vector3.UP, deg_to_rad(monster_yaw_offset_deg))
		monster_node.global_transform = Transform3D(b.orthonormalized(), mpos)

	# Recompute after
	var new_fwd: Vector3 = -monster_node.global_transform.basis.z
	new_fwd.y = 0.0
	new_fwd = new_fwd.normalized()
	var yaw_after: float = rad_to_deg(atan2(new_fwd.x, new_fwd.z))
	var err: float = fmod(absf(yaw_after - yaw_after_exp), 360.0)
	if err > 180.0:
		err = 360.0 - err
	_dbg("[BL][face-mon] yaw_before=%.1f° yaw_to_player=%.1f° offset=%.1f° yaw_after=%.1f° expected≈%.1f° err≈%.1f°"
		% [yaw_before, yaw_target, monster_yaw_offset_deg, yaw_after, yaw_after_exp, err])

func _face_player_to(target_pos: Vector3, player_node: Node3D) -> void:
	var pivot := player_node.get_node_or_null(^"Pivot") as Node3D
	var base: Node3D = (pivot if pivot != null else player_node)
	var origin: Vector3 = base.global_transform.origin
	var to: Vector3 = (target_pos - origin); to.y = 0.0
	if to.length_squared() < 0.0001:
		return
	var cur_fwd: Vector3 = -base.global_transform.basis.z
	cur_fwd.y = 0.0
	cur_fwd = cur_fwd.normalized()
	var tgt_fwd: Vector3 = to.normalized()
	var dotv: float = clampf(cur_fwd.dot(tgt_fwd), -1.0, 1.0)
	var ang: float = acos(dotv)
	if cur_fwd.cross(tgt_fwd).y < 0.0:
		ang = -ang
	var b := base.global_transform.basis.rotated(Vector3.UP, ang)
	base.global_transform = Transform3D(b.orthonormalized(), origin)
	_dbg("[BL][face-ply] rotate yaw=%.1f° -> target %s" % [rad_to_deg(ang), _fmt_v3(target_pos)])

# --------------------------- Physics helpers ---------------------------------

func _collect_excludes_from(player_node: Node3D) -> Array[RID]:
	var excludes: Array[RID] = []

	# Exclude the player's physics body (CharacterBody3D inherits PhysicsBody3D)
	var body := player_node as PhysicsBody3D
	if body != null:
		excludes.append(body.get_rid())

	# Exclude the player's collision shape too (if present)
	var col := player_node.get_node_or_null(^"CollisionShape3D") as CollisionShape3D
	if col != null and col.shape != null:
		excludes.append(col.shape.get_rid())

	_dbg("[BL] Excludes RIDs count=%d" % [excludes.size()])
	return excludes

func _has_clearance_at(pos: Vector3, excludes: Array[RID]) -> bool:
	var capsule := CapsuleShape3D.new()
	capsule.radius = spawn_clear_radius
	capsule.height = max(0.1, spawn_clear_height)

	var shape_params := PhysicsShapeQueryParameters3D.new()
	shape_params.shape = capsule
	# Center the capsule above the floor contact point.
	shape_params.transform = Transform3D(Basis(), pos + Vector3(0, spawn_clear_height * 0.5, 0))
	shape_params.exclude = excludes
	shape_params.collision_mask = spawn_query_mask

	var space := get_tree().get_root().world_3d.direct_space_state
	var overlaps := space.intersect_shape(shape_params, 16)

	# Filter out floor-like hits; only walls/props should block.
	var blocking: int = 0
	if overlaps.size() > 0:
		for o in overlaps:
			if typeof(o) == TYPE_DICTIONARY:
				var d: Dictionary = o
				if d.has("collider"):
					var n: Node = d["collider"]
					if _is_floor_like(n):
						if debug_logs:
							_dbg("[BL][clearance] floor-ok overlap: %s" % [str(n)])
						continue
					blocking += 1
					if debug_logs:
						_dbg("[BL][clearance] BLOCK by %s" % [str(n)])

	return blocking == 0

func _drop_to_floor_valid(cand: Vector3, player_y: float, excludes: Array[RID]) -> Dictionary:
	var top: Vector3 = cand + Vector3(0, ground_probe_height, 0)
	var bot: Vector3 = cand - Vector3(0, ground_probe_depth, 0)

	var ray := PhysicsRayQueryParameters3D.create(top, bot)
	ray.exclude = excludes
	ray.collision_mask = spawn_query_mask

	var space := get_tree().get_root().world_3d.direct_space_state
	var hit := space.intersect_ray(ray)
	if hit.is_empty():
		return { "ok": false }

	var pos: Vector3 = hit["position"]
	var nrm: Vector3 = Vector3.UP
	if hit.has("normal"):
		nrm = hit["normal"]

	# Reject surfaces that are far from player's floor or too steep (likely wall)
	if absf(pos.y - player_y) > max_floor_delta:
		return { "ok": false, "reason": "floor-delta" }
	if nrm.y < 0.4:
		return { "ok": false, "reason": "steep" }

	return { "ok": true, "position": pos }

func _last_resort_position(origin: Vector3, forward: Vector3, excludes: Array[RID]) -> Dictionary:
	var d: float = clampf(desired_distance_m, min_distance_m, max_distance_m)
	var cand: Vector3 = origin + forward.normalized() * d
	return _drop_to_floor_valid(cand, origin.y, excludes)

# ------------------------ Spawn search strategies ----------------------------

# A) Corridor-friendly sweep (forward, then backward)
func _front_try_dir(origin: Vector3, eye: Vector3, dir_in: Vector3, excludes: Array[RID]) -> Dictionary:
	var dir: Vector3 = dir_in.normalized()
	var space := get_tree().get_root().world_3d.direct_space_state

	var max_d: float = max_distance_m
	var ray := PhysicsRayQueryParameters3D.create(eye, eye + dir * max_d)
	ray.exclude = excludes
	ray.collision_mask = spawn_query_mask
	var hit := space.intersect_ray(ray)

	var target_d: float = desired_distance_m
	if not hit.is_empty():
		var hit_pos: Vector3 = hit["position"]
		var dist: float = hit_pos.distance_to(eye)
		target_d = clampf(dist - front_back_margin, min_distance_m, max_distance_m)
		if debug_logs:
			var col_name: String = "<unknown>"
			if hit.has("collider") and hit["collider"] != null:
				col_name = str(hit["collider"])
			_dbg("[BL][front] wall adjust: eye=%s hit=%s dist=%.2f -> target_d=%.2f collider=%s"
				% [_fmt_v3(eye), _fmt_v3(hit_pos), dist, target_d, col_name])

	var base_cand: Vector3 = origin + dir * target_d
	var drop := _drop_to_floor_valid(base_cand, origin.y, excludes)
	if not bool(drop.get("ok", false)):
		if debug_logs:
			var reason: String = String(drop.get("reason", "bad-floor"))
			_dbg("[BL][front] reject floor: cand=%s reason=%s" % [_fmt_v3(base_cand), reason])
		return { "ok": false }

	var on_floor: Vector3 = drop["position"]
	if not _has_clearance_at(on_floor, excludes):
		_dbg("[BL][front] reject clearance at %s" % [_fmt_v3(on_floor)])
		return { "ok": false }

	if require_line_of_sight:
		var rq := PhysicsRayQueryParameters3D.create(eye, on_floor + Vector3(0, 1.0, 0))
		rq.exclude = excludes
		rq.collision_mask = spawn_query_mask
		var block := space.intersect_ray(rq)
		if not block.is_empty():
			if debug_logs:
				var bpos: Vector3 = block.get("position", eye)
				var bcol: String = "<unknown>"
				if block.has("collider") and block["collider"] != null:
					bcol = str(block["collider"])
				_dbg("[BL][front] reject LOS: eye->%s blocked by %s @ %s"
					% [_fmt_v3(on_floor), bcol, _fmt_v3(bpos)])
			return { "ok": false }

	_dbg("[BL][front] OK d=%.2f pos=%s" % [target_d, _fmt_v3(on_floor)])
	return { "ok": true, "position": on_floor }

func _find_spawn_point_front_sweep(player_node: Node3D, forward: Vector3) -> Dictionary:
	var origin: Vector3 = player_node.global_transform.origin
	var excludes: Array[RID] = _collect_excludes_from(player_node)
	var eye: Vector3 = origin + Vector3(0, cam_eye_height, 0)
	_dbg("[BL] Front/back sweep  origin=%s eye=%s fwd=%s"
		% [_fmt_v3(origin), _fmt_v3(eye), _fmt_v3(forward)])

	var f := _front_try_dir(origin, eye, forward, excludes)
	if bool(f.get("ok", false)):
		return f

	var b := _front_try_dir(origin, eye, -forward, excludes)
	if bool(b.get("ok", false)):
		return b

	return { "ok": false }

# B) Radial ring search around the player
func _find_spawn_point_radial(player_node: Node3D, forward: Vector3) -> Dictionary:
	var origin: Vector3 = player_node.global_transform.origin
	var excludes: Array[RID] = _collect_excludes_from(player_node)
	var space := get_tree().get_root().world_3d.direct_space_state
	var eye: Vector3 = origin + Vector3(0, cam_eye_height, 0)

	var step: int = max(5, radial_angle_step_deg)
	var dirs: Array[Vector3] = []
	for deg in range(0, 360, step):
		var rad: float = deg_to_rad(float(deg))
		var dir: Vector3 = Basis().rotated(Vector3.UP, rad) * forward
		dirs.append(dir.normalized())

	_dbg("[BL] Radial search: step=%d° rings=%s desired=%.2f min=%.2f max=%.2f"
		% [step, str(radial_ring_scales), desired_distance_m, min_distance_m, max_distance_m])

	for i in range(radial_ring_scales.size()):
		var s: float = radial_ring_scales[i]
		var d: float = clampf(desired_distance_m * s, min_distance_m, max_distance_m)
		for j in range(dirs.size()):
			var dir2: Vector3 = dirs[j]
			var cand: Vector3 = origin + dir2 * d

			var drop := _drop_to_floor_valid(cand, origin.y, excludes)
			if not bool(drop.get("ok", false)):
				_dbg("[BL][probe] fail angle=%.1f d=%.2f reason=%s"
					% [rad_to_deg(atan2(dir2.x, dir2.z)), d, String(drop.get("reason", "bad-floor"))])
				continue
			var on_floor: Vector3 = drop["position"]

			if not _has_clearance_at(on_floor, excludes):
				_dbg("[BL][probe] fail angle=%.1f d=%.2f reason=overlap" % [rad_to_deg(atan2(dir2.x, dir2.z)), d])
				continue

			if require_line_of_sight:
				var rq := PhysicsRayQueryParameters3D.create(eye, on_floor + Vector3(0, 1.0, 0))
				rq.exclude = excludes
				rq.collision_mask = spawn_query_mask
				var hit := space.intersect_ray(rq)
				if not hit.is_empty():
					var hpos: Vector3 = hit.get("position", eye)
					var hcol: String = "<unknown>"
					if hit.has("collider") and hit["collider"] != null:
						hcol = str(hit["collider"])
					_dbg("[BL][probe] fail angle=%.1f d=%.2f reason=blocked-LoS by %s @ %s"
						% [rad_to_deg(atan2(dir2.x, dir2.z)), d, hcol, _fmt_v3(hpos)])
					continue

			_dbg("[BL][probe] OK angle=%.1f d=%.2f pos=%s"
				% [rad_to_deg(atan2(dir2.x, dir2.z)), d, _fmt_v3(on_floor)])
			return { "ok": true, "position": on_floor }

	return { "ok": false }

# --------------------------- Runtime snapshots -------------------------------

func _build_player_runtime() -> PlayerRuntime:
	var pr := PlayerRuntime.new()

	# --- 1) Pull HP/MP snapshot from RunState (typed, safe) ---
	var hp_max: int = 30
	var mp_max: int = 10
	var hp: int = 30
	var mp: int = 10

	if _has_autoload("RunState"):
		var rs := get_node(^"/root/RunState")
		var v: Variant = rs.get("hp_max"); if v != null: hp_max = int(v)
		v = rs.get("mp_max"); if v != null: mp_max = int(v)
		v = rs.get("hp"); if v != null: hp = int(v)
		v = rs.get("mp"); if v != null: mp = int(v)

	# --- 2) Build stats from meta (or fallback) ---
	var base_stats: Dictionary = _extract_player_attributes_from_meta()

	# You can later merge equipment/buff bonuses here (from RunState.equipment/buffs).
	var final_stats: Dictionary = base_stats.duplicate()

	# --- 3) Fill runtime + DerivedCalc numbers ---
	pr.base_stats = base_stats.duplicate()
	pr.final_stats = final_stats.duplicate()

	pr.hp_max = max(1, hp_max)
	pr.mp_max = max(0, mp_max)
	pr.hp = clampi(hp, 0, pr.hp_max)
	pr.mp = clampi(mp, 0, pr.mp_max)

	pr.p_atk = DerivedCalc.p_atk(pr.final_stats)
	pr.m_atk = DerivedCalc.m_atk(pr.final_stats)
	pr.defense = DerivedCalc.defense(pr.final_stats)
	pr.resistance = DerivedCalc.resistance(pr.final_stats)
	pr.crit_chance = DerivedCalc.crit_chance(pr.final_stats, {})
	pr.crit_multi  = DerivedCalc.crit_multi(pr.final_stats, {})
	pr.ctb_speed   = DerivedCalc.ctb_speed(pr.final_stats)

	# Optional: debug line to confirm sources
	_dbg("[BL][player-src] hp=%d/%d mp=%d/%d attrs=%s" % [pr.hp, pr.hp_max, pr.mp, pr.mp_max, str(base_stats)])

	return pr


func _has_autoload(name: String) -> bool:
	return get_tree().get_root().has_node("/root/" + name)

# ------------------------------ Finish / cleanup -----------------------------

func _restore_camera_after_battle() -> void:
	if _battle_cam != null:
		_battle_cam.current = false
	if _saved_camera != null:
		_saved_camera.current = true
	_saved_camera = null
	_dbg("[BL] Camera restored.")

func _on_battle_finished(result: Dictionary) -> void:
	_dbg("[BL] battle_finished: %s" % [str(result)])
	_restore_camera_after_battle()

	if _has_autoload("RunState"):
		var rs := get_node(^"/root/RunState")
		if result.has("player_hp"): rs.set("hp", int(result["player_hp"]))
		if result.has("player_mp"): rs.set("mp", int(result["player_mp"]))

	if _router != null:
		_router.call("finish_encounter", result)

	var arr := get_tree().get_nodes_in_group("player")
	if arr.size() > 0:
		_lock_player(arr[0] as Node, false)

	_cleanup_anchor()

func _cleanup_anchor() -> void:
	if is_instance_valid(_monster_visual): _monster_visual.queue_free()
	if is_instance_valid(_battle_cam): _battle_cam.queue_free()
	if is_instance_valid(_anchor): _anchor.queue_free()
	_monster_visual = null
	_battle_cam = null
	_anchor = null
	_dbg("[BL] Anchor & temp nodes cleaned up.")

# ------------------------------- Misc utils ---------------------------------

func _get_forward(n: Node3D) -> Vector3:
	return -n.global_transform.basis.z.normalized()

func _is_floor_like(n: Node) -> bool:
	if n == null:
		return false
	var name_lc := n.name.to_lower()
	for frag in ignore_overlap_name_fragments:
		var f := String(frag).to_lower()
		if f != "" and name_lc.find(f) >= 0:
			return true
	# Optional: if you tag floors with a "floor" group, also treat that as floor-like.
	return n.is_in_group("floor")

func _log_runtime_stats(mr: MonsterRuntime, pr: PlayerRuntime) -> void:
	if not debug_logs:
		return
	_dbg("[BL][stats][monster] slug=%s lvl=%d  hp=%d/%d mp=%d/%d  p_atk=%.1f m_atk=%.1f def=%.1f res=%.1f  crit=%.1f%% x%.2f  ctb=%.1f"
		% [String(mr.slug), mr.final_level, mr.hp, mr.hp_max, mr.mp, mr.mp_max,
		   mr.p_atk, mr.m_atk, mr.defense, mr.resistance,
		   mr.crit_chance * 100.0, mr.crit_multi, mr.ctb_speed])
	_dbg("[BL][stats][monster] base=%s" % [str(mr.base_stats)])
	_dbg("[BL][stats][monster] final=%s" % [str(mr.final_stats)])
	_dbg("[BL][stats][player ] hp=%d/%d mp=%d/%d  p_atk=%.1f m_atk=%.1f def=%.1f res=%.1f  crit=%.1f%% x%.2f  ctb=%.1f"
		% [pr.hp, pr.hp_max, pr.mp, pr.mp_max,
		   pr.p_atk, pr.m_atk, pr.defense, pr.resistance,
		   pr.crit_chance * 100.0, pr.crit_multi, pr.ctb_speed])

func _dict_path_get(d: Dictionary, path: Array[String]) -> Variant:
	var cur: Variant = d
	for key in path:
		if not (cur is Dictionary):
			return null
		var dd := cur as Dictionary
		if not dd.has(key):
			return null
		cur = dd[key]
	return cur

# Try to read attributes from a variety of meta sources:
# - /root/RunMeta, /root/Meta, /root/MetaState, /root/Save, /root/SaveGame, /root/SaveManager
# - /root/RunState.meta (Dictionary)
# Accepts both floats and ints; casts to int.
func _extract_player_attributes_from_meta() -> Dictionary:
	var defaults: Dictionary = {
		"STR": 5, "AGI": 5, "DEX": 5, "END": 5, "INT": 5, "WIS": 5, "CHA": 5, "LCK": 5
	}

	# 1) Probe common autoload names
	var autoload_names: Array[String] = ["RunMeta", "Meta", "MetaState", "Save", "SaveGame", "SaveManager"]
	for name in autoload_names:
		if _has_autoload(name):
			var node: Node = get_node("/root/" + name)
			var candidates: Array[Variant] = [node.get("player"), node.get("meta"), node.get("data")]
			for cand_v: Variant in candidates:
				if cand_v is Dictionary:
					var attrs: Dictionary = _extract_attrs_from_dict(cand_v as Dictionary, defaults, name)
					if not attrs.is_empty():
						return attrs

	# 2) Fallback: RunState.meta
	if _has_autoload("RunState"):
		var rs: Node = get_node(^"/root/RunState")
		var meta_v: Variant = rs.get("meta")
		if meta_v is Dictionary:
			var attrs2: Dictionary = _extract_attrs_from_dict(meta_v as Dictionary, defaults, "RunState.meta")
			if not attrs2.is_empty():
				return attrs2

	_dbg("[BL] Meta attributes not found; using defaults %s" % [str(defaults)])
	return defaults


func _extract_attrs_from_dict(d: Dictionary, defaults: Dictionary, source_name: String) -> Dictionary:
	var try_roots: Array[Dictionary] = []
	try_roots.append(d)

	var player_v: Variant = d.get("player")
	if player_v is Dictionary:
		try_roots.append(player_v as Dictionary)

	var sb_v: Variant = d.get("stat_block")
	if sb_v is Dictionary:
		try_roots.append(sb_v as Dictionary)

	for root in try_roots:
		var stat_block_v: Variant = root.get("stat_block")
		var sb: Dictionary = (stat_block_v as Dictionary) if stat_block_v is Dictionary else root
		var attributes_v: Variant = sb.get("attributes")
		if attributes_v is Dictionary:
			var incoming: Dictionary = attributes_v as Dictionary
			var out: Dictionary = defaults.duplicate()
			for key_any in out.keys():
				var key: String = String(key_any)
				var v: Variant = incoming.get(key)
				if v is float:
					out[key] = int(v as float)
				elif v is int:
					out[key] = int(v)
			_dbg("[BL] Loaded attributes from %s: %s" % [source_name, str(out)])
			return out

	# Not found -> return empty dict so caller can detect failure.
	return {}
