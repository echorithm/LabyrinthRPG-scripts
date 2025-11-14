# res://scripts/combat/BattleLoader.gd
extends Node
## In-place battles with the labyrinth as backdrop.

signal battle_started(payload: Dictionary)

var _ctrl: BattleController = null
var _pr: PlayerRuntime = null

# --- Debugging ---
@export var debug_logs: bool = true

var _current_monster_display_name: String = ""

# --- Fixpack-0 knobs ---
@export var anchor_exclusion_extra_radius_m: float = 0.30    # keep RNG trash away from elite/treasure anchors
@export var flee_cooldown_steps: int = 6                     # step-based grace after FLEE

func _fmt_v3(v: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [v.x, v.y, v.z]

func _yaw_deg_of(basis: Basis) -> float:
	var f: Vector3 = -basis.z
	f.y = 0.0
	f = f.normalized()
	return rad_to_deg(atan2(f.x, f.z))

func _dbg(msg: String, data: Dictionary = {}) -> void:
	if debug_logs:
		print("[BL] ", msg, (("  " + str(data)) if not data.is_empty() else ""))
	var gl := get_node_or_null(^"/root/GameLog")
	if gl != null:
		gl.call("info", "combat", msg, data)

func _dbg_warn(msg: String, data: Dictionary = {}) -> void:
	if debug_logs:
		push_warning(msg)
	var gl := get_node_or_null(^"/root/GameLog")
	if gl != null:
		gl.call("warn", "combat", msg, data)

func _dbg_error(msg: String, data: Dictionary = {}) -> void:
	push_error(msg)
	var gl := get_node_or_null(^"/root/GameLog")
	if gl != null:
		gl.call("error", "combat", msg, data)

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
const LootReward            := preload("res://scripts/Loot/LootReward.gd")
const LootLog               := preload("res://scripts/Loot/LootLog.gd")

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
var _current_monster_level: int = 1

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
	_dbg("BattleLoader ready")

# --------------------------- Encounter entry ---------------------------------

func _on_encounter_requested(payload: Dictionary) -> void:
	if _catalog == null:
		_dbg_error("[BL] MonsterCatalog autoload missing.")
		return

	var slug: StringName = StringName(String(payload.get("monster_id", "")))
	var mc_snapshot: Dictionary = _catalog.snapshot(slug)
	if mc_snapshot.is_empty():
		_dbg_error("[BL] Monster not found: %s" % [String(slug)])
		return

	var power_level: int = int(payload.get("power_level", 1))
	var role: String = String(payload.get("role", "trash"))
	_current_role = role
	var cms: CombatMusicService = get_node_or_null(^"/root/CombatMusicService") as CombatMusicService
	if cms != null:
		cms.start_combat(_current_role)
	_current_monster_slug = slug
	_finish_sent = false

	_existing_visual_mode = false
	_existing_visual_path = NodePath()
	if payload.has("existing_visual_path"):
		_existing_visual_path = NodePath(String(payload["existing_visual_path"]))
		_existing_visual_mode = true

	var t0: int = Time.get_ticks_msec()
	# PowerAllocator expects a raw-ish entry, but passing the snapshot is OK:
	# it re-normalizes via MonsterSchema inside.
	var alloc: Dictionary = PowerAllocator.allocate(mc_snapshot, power_level, null)
	var t1: int = Time.get_ticks_msec()
	if alloc.is_empty():
		_dbg_error("[BL] allocation failed.")
		return

	_current_monster_level = int(alloc.get("final_level", 1))

	# Build Monster runtime with caps/resists/armor carried through
	var mr: MonsterRuntime = MonsterRuntime.from_alloc(mc_snapshot, alloc, role)
	_current_monster_display_name = mr.display_name
	_current_monster_level = mr.final_level

	# Build Player runtime (stats from RUN + caps from mods), then clamp pools
	var pr: PlayerRuntime = _build_player_runtime()
	if pr.hp <= 0:
		pr.hp = 1

	_log_runtime_stats(mr, pr)

	# Role-based difficulty: elites +30%, bosses +50%
	var role_lc: String = role.to_lower()
	if role_lc == "elite" or role_lc == "boss":
		RoleScaling.apply(mr, role_lc)
		_dbg("RoleScaling applied", {"role": role_lc, "hp_max": mr.hp_max, "p_atk": mr.p_atk, "m_atk": mr.m_atk})

	var Rarity := preload("res://scripts/combat/rarity/MonsterRarityService.gd")
	var r_code: String = Rarity.apply_power_by_level(mr, mr.final_level)
	_dbg("Rarity band", { "level": mr.final_level, "code": r_code, "name": Rarity.rarity_name_for_code(r_code) })

	var player: Node = _find_player(payload)
	if player == null:
		_dbg_error("[BL] Could not find player node.")
		return

	_log_player_state(player)
	_lock_player(player, true)

	var t2: int = Time.get_ticks_msec()
	var anchor := _place_anchor_and_monster(player, mr)
	var t3: int = Time.get_ticks_msec()

	if anchor == null:
		_lock_player(player, false)
		_dbg_error("[BL] Could not place monster anchor.")
		return

	var ctrl := BattleController.new()
	anchor.add_child(ctrl)
	ctrl.add_to_group("battle_controller")
	ctrl.setup(mr, pr, CTBParams.new())
	_pr = pr
	_ctrl = ctrl
	var p_bonus: int = int(payload.get("ctb_player_bonus_pct", 0))
	var m_bonus: int = int(payload.get("ctb_monster_bonus_pct", 0))
	if p_bonus > 0 or m_bonus > 0:
		ctrl.apply_start_bonuses(p_bonus, m_bonus)
	ctrl.battle_finished.connect(_on_battle_finished)

	# UI
	var ui := BattleUI.new()
	get_tree().get_root().add_child(ui)
	ui.set_controller(ctrl)

	# --- Attach animation bridge to monster visual + idle now ---
	var bridge := _attach_animation_bridge(_monster_visual)
	if bridge != null and ctrl.has_method("set_anim_bridge"):
		ctrl.set_anim_bridge(bridge)

	if ctrl.has_method("begin"):
		ctrl.begin(payload)

	# Log encounter
	_dbg("Encounter begin", {
		"slug": String(slug),
		"display": mr.display_name,
		"role": role,
		"alloc_ms": (t1 - t0),
		"spawn_ms": (t3 - t2),
		"ctb": {"player_speed": pr.ctb_speed, "monster_speed": mr.ctb_speed}
	})

	emit_signal("battle_started", payload)

# ------------------------------ Player helpers -------------------------------

func _find_player(payload: Dictionary) -> Node:
	if payload.has("player_path"):
		var p := get_node_or_null(String(payload["player_path"]))
		if p != null:
			return p
	var arr: Array[Node] = get_tree().get_nodes_in_group("player")
	if arr.size() == 0:
		arr = get_tree().get_nodes_in_group("player_controller")
	if arr.size() > 0:
		return arr[0]
	var cam := get_viewport().get_camera_3d()
	if cam != null and cam.get_owner() != null:
		return cam.get_owner()
	return null

func _log_player_state(player_any: Node) -> void:
	var p3 := player_any as Node3D
	if p3 == null:
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

	_dbg("Player state", {"pos": _fmt_v3(pos), "yaw": yaw, "eye": _fmt_v3(eye), "fwd": _fmt_v3(fwd)})

func _lock_player(player: Node, locked: bool) -> void:
	# Player lock/unlock (unchanged)
	if locked and player.has_method("enter_battle_lock"):
		player.call("enter_battle_lock")
	elif (not locked) and player.has_method("exit_battle_lock"):
		player.call("exit_battle_lock")

	# 1) Generic HUD groups → toggle visibility as before, but never hide nodes in group 'game_menu'
	var hud_groups: Array[String] = ["dungeon_hud"]
	for g in hud_groups:
		var nodes_h: Array = get_tree().get_nodes_in_group(g)
		for n_any in nodes_h:
			var ci := n_any as CanvasItem
			if ci == null:
				continue
			var keep_visible: bool = n_any.is_in_group("game_menu") or (n_any.name == "GameMenu")
			ci.visible = (not locked) or keep_visible

	# 2) Virtual sticks
	var stick_groups: Array[String] = ["look_stick", "move_stick"]
	for sg in stick_groups:
		var nodes_s: Array = get_tree().get_nodes_in_group(sg)
		for n in nodes_s:
			if n.has_method("on_hud_locked"):
				n.call("on_hud_locked", locked)
			else:
				var ci2 := n as CanvasItem
				if ci2 != null and locked:
					ci2.visible = false

	_dbg(("HUD locked" if locked else "HUD unlocked"))

# ------------------------ Anchor / spawn / camera ----------------------------

func _place_anchor_and_monster(player: Node, mr: MonsterRuntime) -> Node3D:
	var player_node := player as Node3D
	if player_node == null:
		return null

	# --- Existing-visual mode (Elite/Boss)
	if _existing_visual_mode and _existing_visual_path != NodePath():
		var given: Node3D = _node3d_from_path(_existing_visual_path)
		if given == null:
			_dbg_warn("[BL] existing_visual_path not found; falling back to dynamic anchor.")
		else:
			var rig_root: Node3D = _rig_root_from(given)
			_monster_visual = rig_root
			_anchor = rig_root
			var pos: Vector3 = rig_root.global_transform.origin
			# Fixpack-0: enforce unit scale deterministically
			_force_unit_scale(rig_root)
			_face_monster_to_player(rig_root, player_node)
			_face_player_to(pos, player_node)
			_position_battle_cam(pos, player_node)
			_dbg("Anchor(existing_visual)", {"pos": _fmt_v3(pos)})
			var RarityEV := preload("res://scripts/combat/rarity/MonsterRarityService.gd")
			var changedEV: int = RarityEV.reskin_visual_for_level(_monster_visual, mr.final_level)
			if changedEV > 0:
				_dbg("Rarity reskin applied", { "changed_meshes": changedEV, "level": mr.final_level })
			return _anchor

	# --- Default RNG mode
	_anchor = Node3D.new()
	_anchor.name = "BattleAnchor"
	get_tree().get_root().add_child(_anchor)

	var forward: Vector3 = _get_forward(player_node)

	var res_front: Dictionary = _find_spawn_point_front_sweep(player_node, forward)
	if bool(res_front.get("ok", false)):
		var pos_f: Vector3 = res_front.get("position", player_node.global_transform.origin + forward * desired_distance_m)
		if _is_in_anchor_no_go(pos_f):
			res_front = {"ok": false}
		else:
			_dbg("Spawn(front)", {"pos": _fmt_v3(pos_f)})
			_anchor.global_transform = Transform3D(Basis(), pos_f)

	if not bool(res_front.get("ok", false)):
		var res_rad: Dictionary = _find_spawn_point_radial(player_node, forward)
		if bool(res_rad.get("ok", false)):
			var pos_r: Vector3 = res_rad.get("position", player_node.global_transform.origin + forward * desired_distance_m)
			if _is_in_anchor_no_go(pos_r):
				res_rad = {"ok": false}
			else:
				_dbg("Spawn(radial)", {"pos": _fmt_v3(pos_r)})
				_anchor.global_transform = Transform3D(Basis(), pos_r)

		if not bool(res_rad.get("ok", false)):
			_dbg_warn("[BL] All probes failed — LAST RESORT at min-distance.")
			var excludes: Array[RID] = _collect_excludes_from(player_node)
			var res_lr: Dictionary = _last_resort_position(player_node.global_transform.origin, forward, excludes)
			if not bool(res_lr.get("ok", false)):
				_dbg_warn("[BL] Aborting encounter: could not find a safe spawn.")
				_anchor.queue_free(); _anchor = null
				return null
			var pos_l: Vector3 = res_lr["position"]
			if _is_in_anchor_no_go(pos_l):
				_dbg_warn("[BL] Aborting encounter: last-resort spot blocked by anchor no-go.")
				_anchor.queue_free(); _anchor = null
				return null
			_dbg("Spawn(last_resort)", {"pos": _fmt_v3(pos_l)})
			_anchor.global_transform = Transform3D(Basis(), pos_l)

	var pos_final: Vector3 = _anchor.global_transform.origin
	_monster_visual = _catalog.instantiate_visual(_anchor, mr.slug)
	var Rarity := preload("res://scripts/combat/rarity/MonsterRarityService.gd")
	var changed: int = Rarity.reskin_visual_for_level(_monster_visual, mr.final_level)
	if changed > 0:
		_dbg("Rarity reskin applied", { "changed_meshes": changed, "level": mr.final_level })

	if _monster_visual != null:
		var vt: Transform3D = _monster_visual.global_transform
		vt.origin = pos_final
		# Fixpack-0: enforce unit scale deterministically
		vt.basis = vt.basis.orthonormalized()
		_monster_visual.global_transform = vt
		_face_monster_to_player(_monster_visual, player_node)
	else:
		_dbg_warn("[BL] No monster visual for slug=%s" % [String(mr.slug)])

	_face_player_to(pos_final, player_node)
	_position_battle_cam(pos_final, player_node)

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
			_dbg("Camera eye adjusted (wall)", {"blocker": blk, "eye": _fmt_v3(eye)})

	_battle_cam.global_transform = Transform3D(Basis(), eye)
	_battle_cam.look_at(target_pos + Vector3(0, monster_look_height, 0), Vector3.UP)

	var saved: Camera3D = get_viewport().get_camera_3d()
	_saved_camera = saved
	if _saved_camera != null:
		_saved_camera.current = false
	_battle_cam.current = true

	var gl := get_node_or_null(^"/root/GameLog")
	if gl != null:
		gl.call("info", "camera", "Battle camera positioned",
			{"eye": _fmt_v3(eye), "target": _fmt_v3(target_pos), "fov": _battle_cam.fov})

# --------------------------- Facing helpers ----------------------------------

func _face_monster_to_player(monster_node: Node3D, player_node: Node3D) -> void:
	if monster_node == null or player_node == null:
		return
	var mpos: Vector3 = monster_node.global_transform.origin
	var ppos: Vector3 = player_node.global_transform.origin
	var old_basis: Basis = monster_node.global_transform.basis
	var scale_vec: Vector3 = old_basis.get_scale()
	var look := Vector3(ppos.x, mpos.y, ppos.z)
	monster_node.look_at(look, Vector3.UP)
	var b: Basis = monster_node.global_transform.basis
	if absf(monster_yaw_offset_deg) > 0.001:
		b = b.rotated(Vector3.UP, deg_to_rad(monster_yaw_offset_deg))
	b = b.scaled(scale_vec)
	monster_node.global_transform = Transform3D(b, mpos)

func _face_player_to(target_pos: Vector3, player_node: Node3D) -> void:
	var pivot := player_node.get_node_or_null(^"Pivot") as Node3D
	var base: Node3D = (pivot if pivot != null else player_node)
	var origin: Vector3 = base.global_transform.origin
	var to: Vector3 = (target_pos - origin); to.y = 0.0
	if to.length_squared() < 0.0001:
		return
	var old_basis: Basis = base.global_transform.basis
	var scale_vec: Vector3 = old_basis.get_scale()
	var cur_fwd: Vector3 = -old_basis.z; cur_fwd.y = 0.0; cur_fwd = cur_fwd.normalized()
	var tgt_fwd: Vector3 = to.normalized()
	var dotv: float = clampf(cur_fwd.dot(tgt_fwd), -1.0, 1.0)
	var ang: float = acos(dotv)
	if cur_fwd.cross(tgt_fwd).y < 0.0:
		ang = -ang
	var rot_only := old_basis.orthonormalized().rotated(Vector3.UP, ang)
	var new_basis := rot_only.scaled(scale_vec)
	base.global_transform = Transform3D(new_basis, origin)

# --------------------------- Physics helpers ---------------------------------

func _collect_excludes_from(player_node: Node3D) -> Array[RID]:
	var excludes: Array[RID] = []
	var body := player_node as PhysicsBody3D
	if body != null:
		excludes.append(body.get_rid())
	var col := player_node.get_node_or_null(^"CollisionShape3D") as CollisionShape3D
	if col != null and col.shape != null:
		excludes.append(col.shape.get_rid())
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
						continue
					blocking += 1
					if debug_logs:
						_dbg("Spawn blocked (clearance)", {"at": _fmt_v3(pos), "by": str(n)})
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
		return {"ok": false}
	var pos: Vector3 = hit["position"]
	var nrm: Vector3 = Vector3.UP
	if hit.has("normal"):
		nrm = hit["normal"]
	if absf(pos.y - player_y) > max_floor_delta:
		return {"ok": false, "reason": "floor-delta"}
	if nrm.y < 0.4:
		return {"ok": false, "reason": "steep"}
	return {"ok": true, "position": pos}

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
			_dbg("Front sweep: wall", {"collider": col_name, "dist": dist, "target_d": target_d})
	var base_cand: Vector3 = origin + dir * target_d
	var drop := _drop_to_floor_valid(base_cand, origin.y, excludes)
	if not bool(drop.get("ok", false)):
		if debug_logs:
			_dbg("Front sweep: bad floor", {"reason": String(drop.get("reason", "bad-floor"))})
		return {"ok": false}
	var on_floor: Vector3 = drop["position"]
	if not _has_clearance_at(on_floor, excludes):
		return {"ok": false}
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
				_dbg("LOS blocked", {"by": bcol, "at": _fmt_v3(bpos)})
			return {"ok": false}
	return {"ok": true, "position": on_floor}

func _find_spawn_point_front_sweep(player_node: Node3D, forward: Vector3) -> Dictionary:
	var origin: Vector3 = player_node.global_transform.origin
	var excludes: Array[RID] = _collect_excludes_from(player_node)
	var eye: Vector3 = origin + Vector3(0, cam_eye_height, 0)
	var f := _front_try_dir(origin, eye, forward, excludes)
	if bool(f.get("ok", false)):
		if _is_in_anchor_no_go(f["position"]):
			return {"ok": false}
		return f
	var b := _front_try_dir(origin, eye, -forward, excludes)
	if bool(b.get("ok", false)):
		if _is_in_anchor_no_go(b["position"]):
			return {"ok": false}
		return b
	return {"ok": false}

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
	for i in range(radial_ring_scales.size()):
		var s: float = radial_ring_scales[i]
		var d: float = clampf(desired_distance_m * s, min_distance_m, max_distance_m)
		for j in range(dirs.size()):
			var dir2: Vector3 = dirs[j]
			var cand: Vector3 = origin + dir2 * d
			var drop := _drop_to_floor_valid(cand, origin.y, excludes)
			if not bool(drop.get("ok", false)):
				continue
			var on_floor: Vector3 = drop["position"]
			if _is_in_anchor_no_go(on_floor):
				continue
			if not _has_clearance_at(on_floor, excludes):
				continue
			if require_line_of_sight:
				var rq := PhysicsRayQueryParameters3D.create(eye, on_floor + Vector3(0, 1.0, 0))
				rq.exclude = excludes
				rq.collision_mask = spawn_query_mask
				var hit := space.intersect_ray(rq)
				if not hit.is_empty():
					continue
			return {"ok": true, "position": on_floor}
	return {"ok": false}

# --------------------------- Runtime snapshots -------------------------------

func _build_player_runtime() -> PlayerRuntime:
	var rs: Dictionary = SaveManager.load_run()

	# 1) Gather base stats from RUN
	var base_stats: Dictionary = _extract_player_attributes_from_run()

	# 2) Compute caps from mods (defaults if none present)
	var mods := _merge_mods(rs)
	var caps := _caps_from_mods(mods)

	# 3) Build runtime and recompute deriveds (sets pools to max)
	var pr := PlayerRuntime.from_stats(base_stats, base_stats, caps)

	# 4) Apply passives/affixes on top of deriveds (keeps caps clamping)
	var nums := _apply_passives(pr.final_stats, mods, caps)
	pr.p_atk = nums.p_atk
	pr.m_atk = nums.m_atk
	pr.defense = nums.defense
	pr.resistance = nums.resistance
	pr.crit_chance = nums.crit_chance
	pr.crit_multi  = nums.crit_multi
	pr.ctb_speed   = nums.ctb_speed

	# NEW: surface CTB reduction% to the runtime (used by BattleController)
	pr.ctb_cost_reduction_pct = float(nums.get("ctb_cost_reduction_pct", 0.0))
	# Optional: status helpers if you want them mirrored on runtime/UI
	pr.on_hit_status_chance_pct = float(nums.get("on_hit_status_chance_pct", 0.0))
	pr.status_resist_pct = float(nums.get("status_resist_pct", 0.0))

	# 5) Restore current pools from RUN (clamped to max)
	pr.hp = clampi(int(rs.get("hp", pr.hp_max)),   0, pr.hp_max)
	pr.mp = clampi(int(rs.get("mp", pr.mp_max)),   0, pr.mp_max)
	pr.stam = clampi(int(rs.get("stam", pr.stam_max)), 0, pr.stam_max)

	_dbg("Player runtime", {
		"hp": [pr.hp, pr.hp_max], "mp": [pr.mp, pr.mp_max], "st": [pr.stam, pr.stam_max],
		"p_atk": pr.p_atk, "m_atk": pr.m_atk, "def": pr.defense, "res": pr.resistance,
		"crit": [pr.crit_chance, pr.crit_multi], "ctb_speed": pr.ctb_speed,
		"ctb_cost_reduction_pct": pr.ctb_cost_reduction_pct
	})

	# 6) Wire skills/unlocks from RUN ✅
	_apply_skill_tracks_and_abilities(pr, rs)

	return pr

func _extract_player_attributes_from_run() -> Dictionary:
	var defaults: Dictionary = {
		"STR": 8, "AGI": 8, "DEX": 8, "END": 8,
		"INT": 8, "WIS": 8, "CHA": 8, "LCK": 8
	}
	var rs: Dictionary = SaveManager.load_run()
	var pa_any: Variant = rs.get("player_attributes")
	if pa_any is Dictionary:
		var pa: Dictionary = pa_any as Dictionary
		var out: Dictionary = {}
		out["STR"] = int(pa.get("STR", defaults["STR"]))
		out["AGI"] = int(pa.get("AGI", defaults["AGI"]))
		out["DEX"] = int(pa.get("DEX", defaults["DEX"]))
		out["END"] = int(pa.get("END", defaults["END"]))
		out["INT"] = int(pa.get("INT", defaults["INT"]))
		out["WIS"] = int(pa.get("WIS", defaults["WIS"]))
		out["CHA"] = int(pa.get("CHA", defaults["CHA"]))
		out["LCK"] = int(pa.get("LCK", defaults["LCK"]))
		return out
	return defaults.duplicate(true)

func _has_autoload(name: String) -> bool:
	return get_tree().get_root().has_node("/root/" + name)

# ------------------------------ Finish / cleanup -----------------------------

func _restore_camera_after_battle() -> void:
	if _battle_cam != null:
		_battle_cam.current = false
	if _saved_camera != null:
		_saved_camera.current = true
	_saved_camera = null
	_dbg("Camera restored")

func _on_battle_finished(result: Dictionary) -> void:
	# Outcome first
	var outcome: String = String(result.get("outcome", "defeat"))
	var cms2: CombatMusicService = get_node_or_null(^"/root/CombatMusicService") as CombatMusicService
	if cms2 != null:
		cms2.on_battle_outcome(outcome)
	_dbg("Battle finished(raw)", {"outcome": outcome, "result": result})

	# Enrich result for downstream listeners
	result["monster_level"] = _current_monster_level
	result["monster_display_name"] = _current_monster_display_name
	result["monster_slug"] = String(_current_monster_slug)
	result["role"] = _current_role

	# 1) Monster animation while player locked (unchanged) ...
	var bridge: AnimationBridge = null
	if _anchor != null:
		bridge = _anchor.get_node_or_null(^"AnimationBridge") as AnimationBridge
	if bridge != null:
		match outcome:
			"victory":
				bridge.play_die_and_wait()
				await get_tree().create_timer(0.8).timeout
			"flee":
				if bridge.has_method("play_victory_and_hold"):
					bridge.play_victory_and_hold()
				elif bridge.has_method("play_victory"):
					bridge.play_victory()
				await get_tree().create_timer(0.8).timeout
			_:
				await get_tree().create_timer(0.6).timeout

	# 2) Route encounter finish to EncounterRouter **BEFORE** loot so Orchestrator can commit SXP.
	var router := get_node_or_null(^"/root/EncounterRouter")
	if outcome == "victory" and router != null and router.has_method("finish_encounter"):
		router.call("finish_encounter", result)
		_finish_sent = true
		await get_tree().process_frame

	# 3) Victory rewards via loot path (single source of truth)
	if outcome == "victory":
		var floor_i2: int = SaveManager.get_current_floor()
		var run_seed: int = SaveManager.get_run_seed()
		var src: String = (_current_role if (_current_role == "elite" or _current_role == "boss") else "trash")

		# Optional sigil bookkeeping (unchanged)
		var Sigils := preload("res://persistence/services/sigils_service.gd")
		if _current_role == "elite":
			Sigils.notify_elite_killed()

		var boss_charge_factor: float = -1.0
		if _current_role == "boss" and is_instance_valid(_anchor):
			if _anchor.has_method("get_charged_factor"):
				var f_any: Variant = _anchor.call("get_charged_factor")
				if f_any is float: boss_charge_factor = float(f_any)

		# Try to peek an encounter_id for deterministic wiggle seeding
		var encounter_id: int = 0
		if result.has("encounter_id"):
			encounter_id = int(result["encounter_id"])
		elif router != null:
			var candidates: PackedStringArray = ["encounter_id", "current_encounter_id", "_encounter_id"]
			for k in candidates:
				if router.has_method("get"):
					var v_any: Variant = router.get(k)
					if v_any is int:
						encounter_id = int(v_any)
						break
			if encounter_id == 0 and router.has_method("peek_current_encounter_id"):
				var peek_any: Variant = router.call("peek_current_encounter_id")
				if peek_any is int:
					encounter_id = int(peek_any)
			if encounter_id == 0 and router.has_method("get_current_encounter_id"):
				var get_any: Variant = router.call("get_current_encounter_id")
				if get_any is int:
					encounter_id = int(get_any)

		# 🔹 NEW: harvest per-ability rows from AbilityXPService (_pending) for this encounter
		var sxp_rows: Array[Dictionary] = _collect_player_skill_usage_for_rewards(encounter_id)

		# Roll & grant loot (loot path will present the modal)
		var lr := LootReward.new()
		get_tree().root.add_child(lr)
		if _current_role == "boss":
			lr.set_meta("boss_charge_factor", boss_charge_factor)

		var pack: Dictionary = await lr.encounter_victory(
			src,
			floor_i2,
			String(_current_monster_slug),
			run_seed,
			0,                               # post_boss_shift_left
			sxp_rows,                        # ← computed rows (modal will show them)
			_current_monster_display_name,
			_current_monster_level,
			_current_role,
			boss_charge_factor,
			{"encounter_id": encounter_id}
		)
		lr.queue_free()

		# After loot is granted, consume the sigil charge on boss victory
		if _current_role == "boss":
			Sigils.consume_charge()

	# 4) Restore camera and unlock movement (unchanged)
	_restore_camera_after_battle()
	var player := _find_player({})
	_lock_player(player, false)

	# 5) Persist HP/MP into RUN (unchanged)
	var rs_save: Dictionary = SaveManager.load_run()
	if result.has("player_hp"):
		rs_save["hp"] = clampi(int(result["player_hp"]), 0, int(rs_save.get("hp_max", 30)))
	if result.has("player_mp"):
		rs_save["mp"] = clampi(int(result["player_mp"]), 0, int(rs_save.get("mp_max", 10)))
	SaveManager.save_run(rs_save)
	_dbg("Run pools saved", {"hp": rs_save.get("hp", 0), "mp": rs_save.get("mp", 0)})

	# Refresh RunState mirrors (unchanged)
	var rs_node: Node = get_node_or_null(^"/root/RunState")
	if rs_node and rs_node.has_method("reload_and_broadcast"):
		rs_node.call("reload_and_broadcast")
	elif rs_node and rs_node.has_method("reload"):
		rs_node.call("reload")

	# Ensure Router finish once for non-victory outcomes too (unchanged)
	if router != null and router.has_method("finish_encounter") and not _finish_sent:
		router.call("finish_encounter", result)
		_finish_sent = true

	# defeat branch (unchanged)
	if outcome == "defeat":
		var DefeatFlow := preload("res://persistence/flows/DefeatFlow.gd")
		DefeatFlow.execute()
		get_tree().paused = false
		get_tree().change_scene_to_file("res://scripts/village/state/VillageHexOverworld2.tscn")

	_dbg("Battle finished(done)", {"outcome": outcome})

func _cleanup_after_battle(outcome: String) -> void:
	if is_instance_valid(_battle_cam): _battle_cam.queue_free()
	_battle_cam = null

	# Existing-visual mode (Elite/Boss)
	if _existing_visual_mode:
		if outcome == "victory":
			if is_instance_valid(_monster_visual):
				_monster_visual.queue_free()
		_monster_visual = null
		_anchor = null
		_existing_visual_mode = false
		_existing_visual_path = NodePath()
		return

	# RNG/transient: free everything.
	if is_instance_valid(_monster_visual): _monster_visual.queue_free()
	if is_instance_valid(_anchor): _anchor.queue_free()
	_monster_visual = null
	_anchor = null

func _cleanup_anchor() -> void:
	if is_instance_valid(_monster_visual): _monster_visual.queue_free()
	if is_instance_valid(_battle_cam): _battle_cam.queue_free()
	if is_instance_valid(_anchor): _anchor.queue_free()
	_monster_visual = null
	_battle_cam = null
	_anchor = null

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
	_dbg("Monster runtime", {
		"display": mr.display_name, "role": mr.role,
		"hp": [mr.hp, mr.hp_max], "mp": [mr.mp, mr.mp_max],
		"p_atk": mr.p_atk, "m_atk": mr.m_atk,
		"def": mr.defense, "res": mr.resistance,
		"crit": [mr.crit_chance, mr.crit_multi],
		"ctb_speed": mr.ctb_speed
	})

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
	return defaults

func _extract_attrs_from_dict(d: Dictionary, defaults: Dictionary, _source_name: String) -> Dictionary:
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
			return out
	return {}

# --------------------------- Animation resolve/attach ------------------------

func _find_anim_player_in(root: Node) -> AnimationPlayer:
	if root == null:
		return null
	var q: Array[Node] = []
	q.push_back(root)
	while q.size() > 0:
		var n: Node = q.pop_front()
		var ap: AnimationPlayer = n as AnimationPlayer
		if ap != null:
			return ap
		var child_count: int = n.get_child_count()
		for i in range(child_count):
			var c: Node = n.get_child(i)
			q.push_back(c)
	return null

func _resolve_anim_context(start: Node) -> Dictionary:
	var cur: Node = start
	for _depth in range(3):
		if cur == null:
			break
		var ap := _find_anim_player_in(cur)
		if ap != null:
			var root3d := cur as Node3D
			if root3d == null and cur.get_parent() is Node3D:
				root3d = cur.get_parent() as Node3D
			return {"root": root3d, "ap": ap}
		cur = cur.get_parent()
	return {}

# Attach AnimationBridge, wire it, play Idle immediately, and return it.
func _attach_animation_bridge(monster_visual: Node3D) -> AnimationBridge:
	if monster_visual == null:
		_anim_bridge = null
		return null
	var ctx := _resolve_anim_context(monster_visual)
	var root3d := ctx.get("root") as Node3D
	var ap := ctx.get("ap") as AnimationPlayer
	if root3d == null or ap == null:
		_dbg_warn("[AnimBridge] No AnimationPlayer reachable from %s (root=%s, ap=%s)"
			% [str(monster_visual.name), str(root3d), str(ap)])
		_anim_bridge = null
		return null
	ap.playback_active = true
	var bridge := AnimationBridgeClass.new()
	bridge.name = "AnimationBridge"
	if _anchor != null:
		_anchor.add_child(bridge)
	else:
		add_child(bridge)
	bridge.setup(root3d, ap) # (Node3D, AnimationPlayer)
	bridge.play_idle()
	_anim_bridge = bridge
	return bridge

# ------------------------------ Rewards (MVP) --------------------------------

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
	var mc := get_node_or_null(^"/root/MonsterCatalog") as MonsterCatalog
	var enemy_name: String = (mc.display_name(enemy_slug) if mc != null else String(enemy_slug))
	var loot_api := LootReward.new()
	get_tree().root.add_child(loot_api)
	var pack: Dictionary = await loot_api.encounter_victory(source, floor_i, enemy_name, run_seed, 0)
	loot_api.queue_free()
	var loot: Dictionary = (pack.get("loot", pack) as Dictionary)
	var receipt: Dictionary = (pack.get("receipt", {}) as Dictionary)
	if receipt.is_empty():
		receipt = {
			"gold": int(loot.get("gold", 0)),
			"shards": int(loot.get("shards", 0)),
			"items": loot.get("items", []),
			"hp": 0, "mp": 0,
			"skill_xp_applied": []
		}
	var gl := get_node_or_null(^"/root/GameLog")
	if gl != null:
		gl.call("info", "reward", "Loot bundle", {"gold": receipt.get("gold", 0), "shards": receipt.get("shards", 0)})
	return {"loot": loot, "receipt": receipt}

func _bundle_from_loot(loot: Dictionary) -> Dictionary:
	var out: Dictionary = {
		"gold": int(loot.get("gold", 0)),
		"hp": 0,
		"mp": 0,
		"items": [],      # Array[Dictionary] {id,count,opts}
		"skill_xp": []    # Array[Dictionary] {id,xp}
	}
	var shards: int = int(loot.get("shards", 0))
	if shards > 0:
		(out["items"] as Array).append({"id":"currency_shard", "count": shards, "opts": { "rarity": "Common" }})
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

func _rig_root_from(start_any: Node) -> Node3D:
	var cur: Node = start_any
	for _step: int in range(4):
		if cur == null:
			break
		var n3: Node3D = cur as Node3D
		if n3 != null:
			var name_lc: String = n3.name.to_lower()
			if name_lc.ends_with("_rig"):
				return n3
			var has_skel: bool = (n3.find_child("Skeleton3D", true, false) is Skeleton3D)
			var ap: AnimationPlayer = _find_anim_player_in(n3)
			if has_skel and ap != null:
				return n3
		cur = cur.get_parent()
	return (start_any as Node3D)

func _node3d_from_path(p: NodePath) -> Node3D:
	var n: Node = get_node_or_null(p)
	return n as Node3D

# --- add near top of file ---
static func _merge_mods(rs: Dictionary) -> Dictionary:
	var A: Dictionary = (rs.get("mods_affix", {}) as Dictionary)
	var V: Dictionary = (rs.get("mods_village", {}) as Dictionary)
	var out: Dictionary = {}
	for k in A.keys(): out[k] = float(A[k])
	for k in V.keys(): out[k] = float(out.get(k, 0.0)) + float(V[k])
	return out

static func _apply_passives(stats: Dictionary, mods: Dictionary, caps: Dictionary) -> Dictionary:
	var p_atk := DerivedCalc.p_atk(stats)
	var m_atk := DerivedCalc.m_atk(stats)
	var defense := DerivedCalc.defense(stats)
	var resistance := DerivedCalc.resistance(stats)
	var crit_ch := DerivedCalc.crit_chance(stats, caps)
	var crit_mul := DerivedCalc.crit_multi(stats, caps)
	var ctb_spd := DerivedCalc.ctb_speed(stats)

	# Flats/% from mods
	p_atk += float(mods.get("flat_power", 0.0))
	m_atk += float(mods.get("flat_power", 0.0))
	crit_ch += float(mods.get("crit_chance_pct", 0.0)) * 0.01
	crit_mul += float(mods.get("crit_damage_pct", 0.0)) * 0.01
	defense     += float(mods.get("def_flat", 0.0))
	resistance  += float(mods.get("res_flat", 0.0))

	# NEW: CTB speed additive
	ctb_spd += float(mods.get("ctb_speed_add", 0.0))

	# Caps
	var cc_cap: float = float(caps.get("crit_chance_cap", 0.35))
	var cm_cap: float = float(caps.get("crit_multi_cap", 2.5))

	return {
		"p_atk": p_atk, "m_atk": m_atk,
		"defense": defense, "resistance": resistance,
		"crit_chance": clampf(crit_ch, 0.0, cc_cap),
		"crit_multi": clampf(crit_mul, 1.0, cm_cap),
		"ctb_speed": ctb_spd,
		"ctb_cost_reduction_pct": float(mods.get("ctb_cost_reduction_pct", 0.0)),
		"on_hit_status_chance_pct": float(mods.get("on_hit_status_chance_pct", 0.0)),
		"status_resist_pct": float(mods.get("status_resist_pct", 0.0))
	}

static func _caps_from_mods(mods: Dictionary) -> Dictionary:
	var base_cc: float = 0.35
	var base_cm: float = 2.5
	var add_cc: float = float(mods.get("crit_chance_cap_add", 0.0)) * 0.01
	var add_cm: float = float(mods.get("crit_multi_cap_add", 0.0)) * 0.01
	var out: Dictionary = {
		"crit_chance_cap": clampf(base_cc + add_cc, 0.0, 0.95),
		"crit_multi_cap":  max(1.0, base_cm + add_cm),
	}
	return out

func _collect_player_skill_usage_for_rewards(encounter_id: int) -> Array[Dictionary]:
	# Returns rows like [{ id:"arc_slash", xp: 30 }, ...] for RewardService.grant()
	var out: Array[Dictionary] = []
	if encounter_id <= 0:
		return out

	const AbilityXPService := preload("res://persistence/services/ability_xp_service.gd")
	const ProgressionService := preload("res://persistence/services/progression_service.gd")
	const XpTuning := preload("res://scripts/rewards/XpTuning.gd")

	# Player level for Δ-scaling
	var snap := ProgressionService.get_character_snapshot()
	var p_level: int = int(snap.get("level", 1))

	# Build the single-enemy descriptor (multi-enemy later)
	var role_enum: int = XpTuning.Role.TRASH
	match _current_role:
		"elite": role_enum = XpTuning.Role.ELITE
		"boss":  role_enum = XpTuning.Role.BOSS
		_:       role_enum = XpTuning.Role.TRASH
	var enemies: Array = [{ "monster_level": max(1, _current_monster_level), "role": role_enum }]

	# Compute + clear the pending bucket; Orchestrator-commit (if it ran) will have cleared it already.
	out = AbilityXPService.compute_rows_and_clear(encounter_id, {
		"player_level": p_level,
		"allies_count": 1,
		"enemies": enemies
	})

	if not out.is_empty():
		_dbg("Skill XP rows (fallback)", {"rows": out})
	return out

# --- Skills/unlocks wiring ----------------------------------------------------

## Normalize skill_tracks and ability_levels from the RUN into PlayerRuntime.
static func _apply_skill_tracks_and_abilities(pr: PlayerRuntime, rs: Dictionary) -> void:
	# Accept a few shapes for robustness:
	# rs["skill_tracks"]       : { aid -> {unlocked:bool, level:int, ...} }
	# rs["skills"]             : same as above (legacy key)
	# rs["ability_levels"]     : { aid -> level:int } (legacy fallback)
	# cooldowns/charges (optional): { aid -> int }

	var tracks_any: Variant = rs.get("skill_tracks", rs.get("skills"))
	var levels_any: Variant = rs.get("ability_levels")

	# 1) Primary: tracks → authoritative unlock + levels
	if typeof(tracks_any) == TYPE_DICTIONARY:
		var tracks: Dictionary = tracks_any as Dictionary
		var out_tracks: Dictionary = {}
		var out_levels: Dictionary = {}

		var keys: Array = tracks.keys()
		for i in keys.size():
			var k_any: Variant = keys[i]
			var aid: String = String(k_any)

			var v_any: Variant = tracks.get(aid)
			if typeof(v_any) != TYPE_DICTIONARY:
				continue
			var d: Dictionary = v_any as Dictionary

			var unlocked: bool = bool(d.get("unlocked", false))
			var lvl: int = int(d.get("level", 0))

			out_tracks[aid] = {
				"unlocked": unlocked,
				"level": lvl,
				"xp_current": int(d.get("xp_current", 0)),
				"xp_needed": int(d.get("xp_needed", 0)),
				"cap_band": int(d.get("cap_band", 0)),
				"last_milestone_applied": int(d.get("last_milestone_applied", 0))
			}
			out_levels[aid] = lvl

		pr.skill_tracks = out_tracks
		pr.ability_levels = out_levels

	# 2) Fallback: bare levels (no tracks present)
	elif typeof(levels_any) == TYPE_DICTIONARY:
		pr.skill_tracks = {}
		pr.ability_levels = (levels_any as Dictionary).duplicate(true)

	else:
		pr.skill_tracks = {}
		pr.ability_levels = {}

	# Optional: restore cooldowns/charges if persisted
	var cds_any: Variant = rs.get("cooldowns")
	if typeof(cds_any) == TYPE_DICTIONARY:
		pr.cooldowns = (cds_any as Dictionary).duplicate(true)

	var chg_any: Variant = rs.get("charges")
	if typeof(chg_any) == TYPE_DICTIONARY:
		pr.charges = (chg_any as Dictionary).duplicate(true)

# --------------------------- Fixpack-0 helpers -------------------------------

func _force_unit_scale(n: Node3D) -> void:
	if n == null:
		return
	var t: Transform3D = n.global_transform
	n.global_transform = Transform3D(t.basis.orthonormalized(), t.origin)

func _is_in_anchor_no_go(pos: Vector3) -> bool:
	var ar := get_node_or_null(^"/root/AnchorRegistry")
	if ar == null:
		return false
	if not ar.has_method("is_point_in_no_spawn"):
		return false
	var floor_i: int = SaveManager.get_current_floor()
	return bool(ar.call("is_point_in_no_spawn", floor_i, pos, anchor_exclusion_extra_radius_m))

func _get_run_steps() -> int:
	var rs := get_node_or_null(^"/root/RunState")
	if rs != null:
		var sv: Variant = rs.get("steps")
		if sv is int:
			return int(sv)
		if sv is float:
			return int(sv)
	return 0

# res://scripts/combat/BattleLoader.gd

func cleanup_battle_visuals() -> void:
	# Hide first (no one-frame corpse), then free and null refs.
	var n: Node = _monster_visual
	if is_instance_valid(n):
		_hide_tree(n)
		n.queue_free()
	_monster_visual = null

	var a: Node = _anchor
	if is_instance_valid(a):
		_hide_tree(a)
		a.queue_free()
	_anchor = null

	if is_instance_valid(_battle_cam):
		_battle_cam.queue_free()
	_battle_cam = null

	
func _hide_tree(n: Node) -> void:
	var stack: Array[Node] = [n]
	while stack.size() > 0:
		var cur: Node = stack.pop_back()
		if cur is Node3D:
			(cur as Node3D).visible = false
		elif cur is CanvasItem:
			(cur as CanvasItem).visible = false
		for i: int in cur.get_child_count():
			stack.push_back(cur.get_child(i))
