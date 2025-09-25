# res://scripts/combat/BattleLoader.gd
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
const PowerAllocator        := preload("res://scripts/combat/allocation/PowerAllocator.gd")
const DerivedCalc           := preload("res://scripts/combat/derive/DerivedCalc.gd")
const CTBParams             := preload("res://scripts/combat/ctb/CTBParams.gd")
const MonsterRuntime        := preload("res://scripts/combat/snapshot/MonsterRuntime.gd")
const PlayerRuntime         := preload("res://scripts/combat/snapshot/PlayerRuntime.gd")
const BattleController      := preload("res://scripts/combat/BattleController.gd")
const BattleUI              := preload("res://scripts/combat/ui/BattleUI.gd")
const AnimationBridgeClass  := preload("res://scripts/combat/ui/AnimationBridge.gd")
const RoleScaling           := preload("res://scripts/combat/RoleScaling.gd")
const RewardService         := preload("res://persistence/services/reward_service.gd")
const LootReward            := preload("res://scripts/Loot/LootReward.gd") # adjust if class_name LootReward exists

# If your AnimationBridge.gd has `class_name AnimationBridge`, this type will resolve.
var _anim_bridge: AnimationBridge = null

var _router: Node = null
var _catalog: MonsterCatalog = null

# --- Nodes created per battle ---
var _anchor: Node3D = null
var _monster_visual: Node3D = null
var _battle_cam: Camera3D = null
var _saved_camera: Camera3D = null

# --- Battle context (for rewards) ---
var _current_monster_slug: StringName = &""
var _current_role: String = "trash"

# --- Spawn/placement tunables ---
@export var desired_distance_m: float = 2.6
@export var min_distance_m: float = 2.4
@export var max_distance_m: float = 4.5

# Corridor sweep
@export var front_back_margin: float = 0.6

# Radial sweep
@export var radial_angle_step_deg: int = 20
@export var radial_ring_scales: PackedFloat32Array = PackedFloat32Array([1.0, 1.25, 1.5, 1.8])

# Ground probing
@export var ground_probe_height: float = 3.0
@export var ground_probe_depth: float  = 6.0
@export var max_floor_delta: float     = 0.9

# Clearance capsule
@export var spawn_clear_radius: float = 0.6
@export var spawn_clear_height: float = 1.8

# Query mask
@export var spawn_query_mask: int = 0xFFFFFFFF

# Line of sight
@export var require_line_of_sight: bool = true
@export var cam_eye_height: float = 1.6

# Monster facing offset
@export var monster_yaw_offset_deg: float = 180.0

# --- BattleCam tuning ---
@export var battle_cam_height: float = 1.0
@export var battle_cam_distance: float = 3.2
@export var battle_cam_side_offset: float = 0.6
@export var battle_cam_fov: float = 60.0
@export var monster_look_height: float = 1.2

# Camera QoL
@export var ignore_overlap_name_fragments: PackedStringArray = PackedStringArray(["FloorTile", "Floor", "Ground"])
@export var camera_wall_clearance: float = 0.25

# Internal guard to ensure finish_encounter is emitted once
var _finish_sent: bool = false
var _existing_visual_mode: bool = false
var _existing_visual_path: NodePath = NodePath()

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
	_current_role = role
	_current_monster_slug = slug
	_finish_sent = false

	_existing_visual_mode = false
	_existing_visual_path = NodePath()
	if payload.has("existing_visual_path"):
		_existing_visual_path = NodePath(String(payload["existing_visual_path"]))
		_existing_visual_mode = true

	_dbg("[BL] Encounter requested  slug=%s role=%s power=%d payload=%s" % [String(slug), role, power_level, str(payload)])

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

	# Role-based difficulty: elites +30%, bosses +50%
	var role_lc: String = role.to_lower()
	if role_lc == "elite" or role_lc == "boss":
		RoleScaling.apply(mr, role_lc)
		_dbg("[BL] RoleScaling applied role=%s → final_stats=%s" % [role_lc, str(mr.final_stats)])

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
	var p_bonus: int = int(payload.get("ctb_player_bonus_pct", 0))
	var m_bonus: int = int(payload.get("ctb_monster_bonus_pct", 0))
	if p_bonus > 0 or m_bonus > 0:
		ctrl.apply_start_bonuses(p_bonus, m_bonus)
	ctrl.battle_finished.connect(_on_battle_finished)

	# UI
	var ui := BattleUI.new()
	get_tree().get_root().add_child(ui)
	ui.set_controller(ctrl)
	_dbg("[BL] BattleUI attached to controller.")

	# --- Attach animation bridge to monster visual + idle now ---
	var bridge := _attach_animation_bridge(_monster_visual)
	if bridge != null and ctrl.has_method("set_anim_bridge"):
		ctrl.set_anim_bridge(bridge)
		print("[BC] AnimBridge set? -> true")

	emit_signal("battle_started", payload)
	_dbg("[BL] battle_started emitted.")

# ------------------------------ Player helpers -------------------------------

func _find_player(payload: Dictionary) -> Node:
	if payload.has("player_path"):
		var p := get_node_or_null(String(payload["player_path"]))
		if p != null:
			_dbg("[BL] Found player via payload path.")
			return p
	var arr: Array[Node] = get_tree().get_nodes_in_group("player")
	if arr.size() == 0:
		arr = get_tree().get_nodes_in_group("player_controller")
	if arr.size() > 0:
		_dbg("[BL] Found player via group.")
		return arr[0]
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

	# Player lock/unlock (unchanged)
	if locked and player.has_method("enter_battle_lock"):
		player.call("enter_battle_lock")
	elif (not locked) and player.has_method("exit_battle_lock"):
		player.call("exit_battle_lock")

	# 1) Generic HUD groups → toggle visibility as before
	var hud_groups: Array[String] = ["dungeon_hud"]
	for g in hud_groups:
		var nodes_h: Array = get_tree().get_nodes_in_group(g)
		for n_any in nodes_h:
			var c := n_any as CanvasItem
			if c != null:
				c.visible = not locked

	# 2) Virtual sticks → call their explicit hook so they remain hidden after battle
	#    (Look stick is in "look_stick"; Move stick we’ll put in "move_stick" via export.)
	var stick_groups: Array[String] = ["look_stick", "move_stick"]
	for sg in stick_groups:
		var nodes_s: Array = get_tree().get_nodes_in_group(sg)
		for n in nodes_s:
			if n.has_method("on_hud_locked"):
				n.call("on_hud_locked", locked)
			else:
				# Fallback: just hide during battle; do NOT force-show after.
				var ci := n as CanvasItem
				if ci != null:
					if locked:
						ci.visible = false

	_dbg("[BL] HUD groups %s; sticks %s  hidden=%s"
		% [str(hud_groups), str(stick_groups), str(locked)])


# ------------------------ Anchor / spawn / camera ----------------------------

func _place_anchor_and_monster(player: Node, mr: MonsterRuntime) -> Node3D:
	var player_node := player as Node3D
	if player_node == null:
		return null

	# --- Existing-visual mode (Elite/Boss): use the provided mesh and do NOT move it.
	if _existing_visual_mode and _existing_visual_path != NodePath():
		var given: Node3D = _node3d_from_path(_existing_visual_path)
		if given == null:
			_dbg_warn("[BL] existing_visual_path not found; falling back to dynamic anchor.")
		else:
			var rig_root: Node3D = _rig_root_from(given)
			_monster_visual = rig_root
			_anchor = rig_root  # attach BattleCam + controller here
			_dbg("[BL] Using rig root as anchor: %s" % [String(rig_root.get_path())])

			var pos: Vector3 = rig_root.global_transform.origin
			_face_monster_to_player(rig_root, player_node)
			_face_player_to(pos, player_node)
			_position_battle_cam(pos, player_node)
			return _anchor

	# --- Default RNG mode: create transient anchor and spawn a visual from catalog
	_anchor = Node3D.new()
	_anchor.name = "BattleAnchor"
	get_tree().get_root().add_child(_anchor)
	_dbg("[BL] Anchor created.")

	var forward: Vector3 = _get_forward(player_node)
	var res: Dictionary = _find_spawn_point_front_sweep(player_node, forward)
	if not bool(res.get("ok", false)):
		res = _find_spawn_point_radial(player_node, forward)
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

	_monster_visual = _catalog.instantiate_visual(_anchor, mr.slug)
	if _monster_visual != null:
		var vt: Transform3D = _monster_visual.global_transform
		vt.origin = pos
		_monster_visual.global_transform = vt
		_face_monster_to_player(_monster_visual, player_node)
	else:
		_dbg_warn("[BL] No monster visual for slug=%s" % [String(mr.slug)])

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

	var cur_fwd: Vector3 = -monster_node.global_transform.basis.z
	cur_fwd.y = 0.0
	cur_fwd = cur_fwd.normalized()
	var to_player: Vector3 = (ppos - mpos); to_player.y = 0.0
	var tgt_fwd: Vector3 = to_player.normalized()

	var yaw_before: float = rad_to_deg(atan2(cur_fwd.x, cur_fwd.z))
	var yaw_target: float = rad_to_deg(atan2(tgt_fwd.x, tgt_fwd.z))
	var yaw_after_exp: float = yaw_target + monster_yaw_offset_deg

	var look := Vector3(ppos.x, mpos.y, ppos.z)
	monster_node.look_at(look, Vector3.UP)
	if absf(monster_yaw_offset_deg) > 0.001:
		var b := monster_node.global_transform.basis.rotated(Vector3.UP, deg_to_rad(monster_yaw_offset_deg))
		monster_node.global_transform = Transform3D(b.orthonormalized(), mpos)

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

	var body := player_node as PhysicsBody3D
	if body != null:
		excludes.append(body.get_rid())

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
	shape_params.transform = Transform3D(Basis(), pos + Vector3(0, spawn_clear_height * 0.5, 0))
	shape_params.exclude = excludes
	shape_params.collision_mask = spawn_query_mask

	var space := get_tree().get_root().world_3d.direct_space_state
	var overlaps: Array = space.intersect_shape(shape_params, 16)

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

	# --- Read pools directly from RUN (source of truth mid-run)
	var rs: Dictionary = SaveManager.load_run()
	var hp_max: int = int(rs.get("hp_max", 30))
	var mp_max: int = int(rs.get("mp_max", 10))
	var hp: int     = int(rs.get("hp", hp_max))
	var mp: int     = int(rs.get("mp", mp_max))

	# --- Attributes from META (persistent)
	var base_stats: Dictionary = _extract_player_attributes_from_meta()
	var final_stats: Dictionary = base_stats.duplicate()

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

	_dbg("[BL][player-src] hp=%d/%d mp=%d/%d attrs=%s"
		% [pr.hp, pr.hp_max, pr.mp, pr.mp_max, str(base_stats)])
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
	print("[BL] battle_finished: %s" % [str(result)])

	# Play Die before cleanup (if bridge exists)
	var bridge: AnimationBridge = null
	if _anchor != null:
		bridge = _anchor.get_node_or_null(^"AnimationBridge") as AnimationBridge
	if bridge != null:
		print("[BL] outcome '%s' -> ask AnimBridge to play & wait" % [String(result.get("outcome",""))])
		bridge.play_die_and_wait()
		await get_tree().create_timer(0.8).timeout

	_restore_camera_after_battle()

	# Unlock player HUD/control
	var player := _find_player({})
	_lock_player(player, false)

	# --- Rewards on victory ---
	var outcome: String = String(result.get("outcome", "defeat"))
	if outcome == "victory":
		var loot_pack: Dictionary = _roll_and_grant_victory_rewards(_current_monster_slug, _current_role)
		var receipt: Dictionary = loot_pack.get("receipt", {})
		await _show_rewards_modal(receipt)
		
	# --- Persist player pools back into RUN so the overworld reflects battle outcome
	var rs_save: Dictionary = SaveManager.load_run()
	if result.has("player_hp"):
		rs_save["hp"] = clampi(int(result["player_hp"]), 0, int(rs_save.get("hp_max", 30)))
	if result.has("player_mp"):
		rs_save["mp"] = clampi(int(result["player_mp"]), 0, int(rs_save.get("mp_max", 10)))
	SaveManager.save_run(rs_save)

	_cleanup_after_battle(String(result.get("outcome","defeat")))
	print("[BL] Anchor & temp nodes cleaned up.")

	# Tell the world the encounter is finished (unblocks RNG loop) — ONCE
	if not _finish_sent:
		var router := get_node_or_null(^"/root/EncounterRouter")
		if router != null and router.has_method("finish_encounter"):
			_finish_sent = true
			router.call("finish_encounter", result)
			
func _cleanup_after_battle(outcome: String) -> void:
	# Always remove transient nodes (camera/bridge/controller live under _anchor).
	if is_instance_valid(_battle_cam): _battle_cam.queue_free()
	_battle_cam = null

	# Existing-visual mode (Elite/Boss): only despawn on victory.
	if _existing_visual_mode:
		if outcome == "victory":
			if is_instance_valid(_monster_visual):
				_monster_visual.queue_free()
		# Keep spawner mesh on defeat (do nothing).
		_monster_visual = null
		_anchor = null
		_existing_visual_mode = false
		_existing_visual_path = NodePath()
		_dbg("[BL] Cleanup (existing-visual): outcome=%s" % outcome)
		return

	# RNG/transient: free everything.
	if is_instance_valid(_monster_visual): _monster_visual.queue_free()
	if is_instance_valid(_anchor): _anchor.queue_free()
	_monster_visual = null
	_anchor = null
	_dbg("[BL] Cleanup (transient): outcome=%s" % outcome)

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

func _extract_player_attributes_from_meta() -> Dictionary:
	var defaults: Dictionary = {
		"STR": 5, "AGI": 5, "DEX": 5, "END": 5, "INT": 5, "WIS": 5, "CHA": 5, "LCK": 5
	}

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
	return {}

# --------------------------- Animation resolve/attach ------------------------

# BFS for AnimationPlayer anywhere under 'root'
func _find_anim_player_in(root: Node) -> AnimationPlayer:
	if root == null:
		return null

	var q: Array[Node] = []
	q.push_back(root)

	while q.size() > 0:
		var n: Node = q.pop_front()
		var ap: AnimationPlayer = n as AnimationPlayer
		if ap != null:
			print("[AnimBridge][scan] found AnimationPlayer at: ", ap.get_path())
			return ap

		var child_count: int = n.get_child_count()
		for i in range(child_count):
			var c: Node = n.get_child(i)
			q.push_back(c)

	return null

# Try the visual; if not found, walk up to 2 parents and scan each subtree.
func _resolve_anim_context(start: Node) -> Dictionary:
	var cur: Node = start
	for depth in range(3):
		if cur == null:
			break
		print("[AnimBridge][scan] probing node: ", cur.get_path())
		var ap := _find_anim_player_in(cur)
		if ap != null:
			var root3d := cur as Node3D
			if root3d == null and cur.get_parent() is Node3D:
				root3d = cur.get_parent() as Node3D
			print("[AnimBridge][scan] resolved root3d=", (root3d if root3d!=null else "null"), " ap=", ap)
			return {"root": root3d, "ap": ap}
		cur = cur.get_parent()
	return {}

# Attach AnimationBridge, wire it, play Idle immediately, and return it.
func _attach_animation_bridge(monster_visual: Node3D) -> AnimationBridge:
	print("[AnimBridge] attach requested for visual: ",
		(monster_visual.get_path() if monster_visual!=null else "null"))
	if monster_visual == null:
		_anim_bridge = null
		return null

	var ctx := _resolve_anim_context(monster_visual)
	var root3d := ctx.get("root") as Node3D
	var ap := ctx.get("ap") as AnimationPlayer

	if root3d == null or ap == null:
		push_warning("[AnimBridge] No AnimationPlayer reachable from %s (root=%s, ap=%s)"
			% [str(monster_visual.name), str(root3d), str(ap)])
		_anim_bridge = null
		return null

	ap.playback_active = true
	print("[AnimBridge] using root=", root3d.name, " ap=", ap.name,
		" (active=", str(ap.playback_active), ")")

	var bridge := AnimationBridgeClass.new()
	bridge.name = "AnimationBridge"
	if _anchor != null:
		_anchor.add_child(bridge)
	else:
		add_child(bridge)

	bridge.setup(root3d, ap) # (Node3D, AnimationPlayer)
	print("[AnimBridge] setup() ok -> ", bridge)
	bridge.play_idle()

	_anim_bridge = bridge
	print("[BL] AnimationBridge attached to ", root3d.name, " (AP path=", ap.get_path(), ")")
	return bridge

# ------------------------------ Rewards (MVP) --------------------------------

# Translate loot -> RewardService.grant() and return both.
func _roll_and_grant_victory_rewards(enemy_slug: StringName, role_source: String) -> Dictionary:
	var enc := get_node_or_null(^"/root/EncounterDirector")
	var floor_i: int = 1
	var run_seed: int = 0
	if enc != null and enc.has_method("get"):
		var v: Variant = enc.get("_floor"); if v != null: floor_i = int(v)
		v = enc.get("_run_seed"); if v != null: run_seed = int(v)

	var source: String = role_source.to_lower()
	if source != "elite" and source != "boss":
		source = "trash"

	# Prefer display name for UI
	var mc := get_node_or_null(^"/root/MonsterCatalog") as MonsterCatalog
	var enemy_name: String = (mc.display_name(enemy_slug) if mc != null else String(enemy_slug))

	# --- instantiate LootReward and call instance method ---
	var loot_api := LootReward.new()
	var loot: Dictionary = loot_api.encounter_victory(source, floor_i, enemy_name, run_seed, 0)

	# Map loot -> RewardService.grant
	var bundle: Dictionary = _bundle_from_loot(loot)
	var receipt: Dictionary = RewardService.grant(bundle)
	return {"loot": loot, "receipt": receipt}

func _bundle_from_loot(loot: Dictionary) -> Dictionary:
	var out: Dictionary = {
		"gold": int(loot.get("gold", 0)),
		"hp": 0,
		"mp": 0,
		"items": [],      # Array[Dictionary] {id,count,opts}
		"skill_xp": []    # Array[Dictionary] {id,xp}
	}

	# shards as an inventory currency item
	var shards: int = int(loot.get("shards", 0))
	if shards > 0:
		(out["items"] as Array).append({"id":"currency_shard", "count": shards, "opts": { "rarity": "Common" }})

	# category -> simple item ids (MVP mapping; replace with your real item table later)
	var cat: String = String(loot.get("category",""))
	var rarity: String = String(loot.get("rarity","U"))
	var item_id: String = ""
	match cat:
		"health_potion": item_id = "potion_health"
		"mana_potion":   item_id = "potion_mana"
		"potion_escape": item_id = "potion_escape"
		"weapon":        item_id = "weapon_generic"
		"armor":         item_id = "armor_generic"
		"accessory":     item_id = "accessory_generic"
		"skill_book":    item_id = "book_skill_generic"
		"spell_book":    item_id = "book_spell_generic"
		_: item_id = ""

	if item_id != "":
		(out["items"] as Array).append({"id": item_id, "count": 1, "opts": {"rarity": rarity}})

	# simple skill xp by source/rarity (MVP numbers)
	var src: String = String(loot.get("source","trash"))
	var xp: int = 0
	match src:
		"trash": xp = 3
		"elite": xp = 8
		"boss":  xp = 20
		_: xp = 3
	if xp > 0:
		(out["skill_xp"] as Array).append({"id":"combat_mastery", "xp": xp})

	return out

# Minimal modal to show a receipt (UI MVP)
func _show_rewards_modal(receipt: Dictionary) -> void:
	var modal := Control.new()
	modal.name = "RewardsModal"
	modal.set_anchors_preset(Control.PRESET_CENTER_TOP)
	modal.anchor_left = 0.5; modal.anchor_right = 0.5
	modal.anchor_top = 0.0; modal.anchor_bottom = 0.0
	modal.offset_left = -220; modal.offset_right = 220
	modal.offset_top = 40; modal.offset_bottom = 0

	var panel := Panel.new()
	panel.custom_minimum_size = Vector2(440, 220)
	panel.add_theme_constant_override("panel", 8)
	modal.add_child(panel)

	var vb := VBoxContainer.new()
	vb.anchor_right = 1.0; vb.anchor_bottom = 1.0
	vb.offset_left = 12; vb.offset_top = 12; vb.offset_right = -12; vb.offset_bottom = -12
	panel.add_child(vb)

	var title := Label.new()
	title.text = "Rewards"
	title.add_theme_font_size_override("font_size", 22)
	vb.add_child(title)

	var lines: Array[String] = []
	lines.append("Gold: %d" % int(receipt.get("gold", 0)))
	lines.append("HP +%d" % int(receipt.get("hp", 0)))
	lines.append("MP +%d" % int(receipt.get("mp", 0)))
	for it_any in (receipt.get("items", []) as Array):
		if it_any is Dictionary:
			var it: Dictionary = it_any
			lines.append("Item: %s x%d" % [String(it.get("id","?")), int(it.get("count",1))])
	for sxp_any in (receipt.get("skill_xp", []) as Array):
		if sxp_any is Dictionary:
			var sx: Dictionary = sxp_any
			lines.append("Skill XP: %s +%d" % [String(sx.get("id","skill")), int(sx.get("xp",0))])

	var details := RichTextLabel.new()
	details.fit_content = true
	details.bbcode_enabled = false
	details.text = "\n".join(lines)
	details.scroll_active = false
	vb.add_child(details)

	var btn := Button.new()
	btn.text = "Continue (Enter)"
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(btn)

	get_tree().get_root().add_child(modal)
	await get_tree().process_frame

	var done := false
	btn.pressed.connect(func(): done = true)
	while not done:
		await get_tree().process_frame
		if Input.is_action_just_pressed("ui_accept"):
			done = true
	modal.queue_free()

# Return the best rig root for rotation/anchoring, starting from any node in the visual.
func _rig_root_from(start_any: Node) -> Node3D:
	var cur: Node = start_any
	for _step: int in range(4): # climb up to 4 parents max
		if cur == null:
			break
		var n3: Node3D = cur as Node3D
		if n3 != null:
			# Heuristics: name *_rig, or contains a Skeleton3D + AnimationPlayer somewhere under it.
			var name_lc: String = n3.name.to_lower()
			if name_lc.ends_with("_rig"):
				return n3
			var has_skel: bool = (n3.find_child("Skeleton3D", true, false) is Skeleton3D)
			var ap: AnimationPlayer = _find_anim_player_in(n3)
			if has_skel and ap != null:
				return n3
		cur = cur.get_parent()
	# Fallback: if the original is Node3D, at least return that.
	return (start_any as Node3D)

# Convenience: unwrap NodePath -> Node3D or null
func _node3d_from_path(p: NodePath) -> Node3D:
	var n: Node = get_node_or_null(p)
	return n as Node3D
