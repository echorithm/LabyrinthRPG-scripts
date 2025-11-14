extends Node3D
class_name BossSpawner

@export var monster_id: StringName = &"demon_king"
@export var power_level: int = 8
@export var interact_action: StringName = &"interact_action"
@export var debug_logs: bool = true
@export var auto_spawn_visual: bool = true

# --- Extra debug toggles ---
@export var debug_anim: bool = true
@export var debug_vision: bool = false
@export var debug_disable_rotation: bool = false
@export var disable_idle_root_tracks: bool = true
@export var use_anim_auto: bool = true

# Detection (same as EliteSpawner)
@export var vision_range_m: float = 8.0
@export var vision_fov_deg: float = 35.0
@export var proximity_range_m: float = 3.0
@export var require_line_of_sight: bool = true
@export var cam_eye_height: float = 1.6
@export var vision_query_mask: int = 0xFFFFFFFF

# Hysteresis + windup
@export var vision_exit_extra_m: float = 0.75
@export var alert_windup_s: float = 0.35

# CTB bonuses (optional; router can ignore if not used)
@export var player_start_bonus_pct: int = 40
@export var monster_start_bonus_pct: int = 40

# Idle animation (fallback if not using AnimAuto)
@export var idle_anim_candidates: PackedStringArray = PackedStringArray(["IdleNormal","Idle","IdleBattle"])

# Idle rotation (small scan via yaw)
@export var rotate_enabled: bool = true
@export var rotate_interval_s: float = 3.0
@export var rotate_interval_jitter_s: float = 0.8
@export var rotate_amount_min_deg: float = 15.0
@export var rotate_amount_max_deg: float = 55.0
@export var rotate_speed_deg: float = 60.0

# Rotation cadence ("only so often")
@export var rotate_probability: float = 0.6
@export var rotate_dwell_min_s: float = 1.25
@export var rotate_dwell_max_s: float = 3.0

# Big re-orient (75–105°) away from walls
@export var reorient_enabled: bool = true
@export var reorient_interval_min_s: float = 6.0
@export var reorient_interval_max_s: float = 12.0
@export var reorient_deg_min: float = 75.0
@export var reorient_deg_max: float = 105.0
@export var reorient_speed_deg: float = 90.0
@export var reorient_probe_len_m: float = 2.5
@export var reorient_use_open_space_bias: bool = true

# pivot we rotate (so AP root tracks won't fight)
var _yaw_pivot: Node3D = null
var _yaw_accum_rad: float = 0.0

var _router: Node = null
var _player_in_range: Node3D = null
var _armed: bool = true
var _awaiting_finish: bool = false
var _my_path_str: String = ""
var _spawned_visual: Node3D = null

# alert state
var _alerting: bool = false
var _alert_t: float = 0.0

# anim state
var _ap: AnimationPlayer = null
var _idle_name: StringName = &""
var _anim_auto_owns_idle: bool = false

# idle rotation state
var _rot_target_yaw_rad: float = 0.0
var _rot_timer_s: float = 0.0
var _rot_moving: bool = false

# re-orient state
var _reorient_timer_s: float = 0.0
var _reorient_active: bool = false
var _reorient_target_yaw: float = 0.0

# rng
var _rot_rng: RandomNumberGenerator = RandomNumberGenerator.new()

func _ready() -> void:
	_rot_rng.randomize()

	_router = get_node_or_null(^"/root/EncounterRouter")
	if _router == null:
		push_error("[BossSpawner] EncounterRouter not found.")
	else:
		if not _router.is_connected("encounter_finished", Callable(self, "_on_encounter_finished")):
			_router.connect("encounter_finished", Callable(self, "_on_encounter_finished"))

	add_to_group("boss_spawner")
	add_to_group("encounter_spawner")

	_ensure_interaction_area()

	var vis: Node3D = _find_any_mesh()
	if vis == null and auto_spawn_visual:
		vis = _spawn_visual()
	_spawned_visual = vis

	# Create pivot first and set initial yaw
	_setup_yaw_pivot()
	_yaw_accum_rad = _yaw_from_basis((_yaw_pivot.global_transform.basis if _yaw_pivot != null else global_transform.basis))

	# Try AnimAuto first
	if use_anim_auto:
		var root: Node = (_spawned_visual if _spawned_visual != null else self)
		_anim_auto_owns_idle = AnimAuto.play_idle(root)
		if debug_anim: print("[BossSpawner] AnimAuto.play_idle -> ", str(_anim_auto_owns_idle))

	# Fallback AP control
	if not _anim_auto_owns_idle:
		_ap = _find_anim_player_in(_spawned_visual if _spawned_visual != null else self)
		_resolve_idle_name()
		_try_play_idle_now()
		if disable_idle_root_tracks:
			_disable_root_tracks_for_idle()

	# init rotations
	_rot_target_yaw_rad = _current_yaw_rad()
	_rot_timer_s = _next_rotate_interval()
	_reorient_timer_s = _rand_range(reorient_interval_min_s, reorient_interval_max_s)

	if debug_logs:
		print("[BossSpawner] READY id=", monster_id, " power=", power_level,
			" path=", get_path(), " has_mesh=", vis != null)
	_my_path_str = String(get_path())

	set_physics_process(true)

func _process(_dt: float) -> void:
	# Optional interaction to force-start
	if not _armed or _player_in_range == null:
		return
	if Input.is_action_just_pressed(String(interact_action)):
		_start_battle(_player_in_range, 0, 0)

func _physics_process(dt: float) -> void:
	if not _armed:
		return

	var player := _find_player()
	if player == null:
		_ensure_idle_playing()
		return

	var my_pos: Vector3 = _visual_pos()
	var ply_pos: Vector3 = player.global_transform.origin
	var dist: float = ply_pos.distance_to(my_pos)

	# 1) Proximity trigger -> player advantage
	if dist <= proximity_range_m:
		if debug_logs:
			print("[BossSpawner] proximity trigger (", dist, " m) → player CTB +", player_start_bonus_pct, "%")
		_start_battle(player, player_start_bonus_pct, 0)
		return

	# 2) Vision cone with hysteresis + LoS (rotates with our yaw)
	var inside_cone: bool = (dist <= vision_range_m and _is_in_my_fov(player, my_pos))

	if not inside_cone and _alerting:
		var exit_ok: bool = dist > (vision_range_m + vision_exit_extra_m) or not _is_in_my_fov(player, my_pos)
		if exit_ok:
			_alerting = false
			_alert_t = 0.0
	else:
		if inside_cone:
			if require_line_of_sight and not _has_los(player, my_pos):
				_ensure_idle_playing()
				_update_idle_rotation(dt, player)
				_update_big_reorient(dt, player)
				return

			_alerting = true
			_alert_t += dt
			if _alert_t >= alert_windup_s:
				var player_looking: bool = _is_player_looking_at_me(player, my_pos)
				var t: float = clampf((dist - proximity_range_m) / max(0.001, (vision_range_m - proximity_range_m)), 0.0, 1.0)
				var m_scaled: int = int(round(monster_start_bonus_pct * t))
				var p_bonus: int = 0
				var m_bonus: int = (m_scaled if not player_looking else 0)
				if debug_logs:
					print("[BossSpawner] vision trigger (", dist, " m, looking=", player_looking,
						") → P+", p_bonus, "% M+", m_bonus, "%")
				_start_battle(player, p_bonus, m_bonus)
				return

	# Idle frame: keep idle + rotate/reorient
	_ensure_idle_playing()
	_update_idle_rotation(dt, player)
	_update_big_reorient(dt, player)

# ---------------------------------------------------------------------------------
# Start battle
# ---------------------------------------------------------------------------------

func _start_battle(player: Node3D, player_bonus_pct: int, monster_bonus_pct: int) -> void:
	if _router == null or not _armed:
		return
	_armed = false
	if debug_logs:
		print("[BossSpawner] request encounter id=", monster_id, " power=", power_level)

	var payload: Dictionary = {
		"monster_id": String(monster_id),
		"power_level": power_level,
		"role": "boss",
		"existing_visual_path": _path_of_visual(),
		"requester_path": _my_path_str,
		"ctb_player_bonus_pct": clampi(player_bonus_pct, 0, 100),
		"ctb_monster_bonus_pct": clampi(monster_bonus_pct, 0, 100),
	}
	_awaiting_finish = true
	_router.call("request_encounter", payload, player)

func _on_encounter_finished(result: Dictionary) -> void:
	if not _awaiting_finish:
		return
	var rp: String = String(result.get("requester_path",""))
	if rp != _my_path_str:
		return

	_awaiting_finish = false
	var outcome: String = String(result.get("outcome","defeat"))
	if outcome == "victory":
		mark_defeated_and_cleanup()
	else:
		_armed = true

# ---------------------------------------------------------------------------------
# Detection helpers
# ---------------------------------------------------------------------------------

func _find_player() -> Node3D:
	var arr: Array[Node] = get_tree().get_nodes_in_group(&"player")
	if arr.is_empty():
		arr = get_tree().get_nodes_in_group(&"player_controller")
	if arr.size() > 0:
		return arr[0] as Node3D
	return null

func _visual_pos() -> Vector3:
	var v: Node3D = _find_any_mesh()
	return (v.global_transform.origin if v != null else global_transform.origin)

# FOV uses the same yaw that rotates the rig, so the cone turns with the boss.
func _is_in_my_fov(player: Node3D, my_pos: Vector3) -> bool:
	var my_fwd: Vector3 = _forward_from_yaw(_current_yaw_rad())
	var to_player: Vector3 = (player.global_transform.origin - my_pos); to_player.y = 0.0
	var l2: float = to_player.length_squared()
	if l2 <= 0.0001:
		return true
	var cos_half: float = cos(deg_to_rad(vision_fov_deg))
	var dotv: float = my_fwd.dot(to_player / sqrt(l2))
	if debug_vision:
		print("[BossSpawner] FOV dot=%.3f cos_half=%.3f -> %s" % [dotv, cos_half, str(dotv >= cos_half)])
	return dotv >= cos_half

func _forward_from_yaw(yaw: float) -> Vector3:
	return Vector3(sin(yaw), 0.0, cos(yaw))

func _is_player_looking_at_me(player: Node3D, my_pos: Vector3) -> bool:
	var base: Node3D = player
	var pivot := player.get_node_or_null(^"Pivot") as Node3D
	if pivot != null:
		base = pivot
	var fwd: Vector3 = -base.global_transform.basis.z
	fwd.y = 0.0; fwd = fwd.normalized()
	var to_me: Vector3 = (my_pos - base.global_transform.origin); to_me.y = 0.0
	if to_me.length_squared() <= 0.0001:
		return true
	var ang: float = rad_to_deg(acos(clampf(fwd.dot(to_me.normalized()), -1.0, 1.0)))
	return ang <= 50.0

func _has_los(player: Node3D, my_pos: Vector3) -> bool:
	var eye: Vector3 = player.global_transform.origin + Vector3(0, cam_eye_height, 0)
	var tgt: Vector3 = my_pos + Vector3(0, 1.0, 0)
	var rq := PhysicsRayQueryParameters3D.create(eye, tgt)
	rq.collision_mask = vision_query_mask

	var excludes: Array[RID] = _collect_own_collision_rids()
	var pbody := player as PhysicsBody3D
	if pbody != null:
		excludes.append(pbody.get_rid())
	rq.exclude = excludes

	var space := get_tree().get_root().world_3d.direct_space_state
	var hit: Dictionary = space.intersect_ray(rq)
	if hit.is_empty():
		if debug_vision:
			print("[BossSpawner] LoS: clear")
		return true

	if debug_vision:
		print("[BossSpawner] LoS: blocked by %s" % [str(hit.get("collider","<unknown>"))])

	if hit.has("collider"):
		var obj: Object = hit["collider"]
		var n: Node = obj as Node
		if n != null:
			if n == self or self.is_ancestor_of(n) or n.is_ancestor_of(self):
				return true
	return false

# ---------------------------------------------------------------------------------
# Idle animation helpers
# ---------------------------------------------------------------------------------

func _resolve_idle_name() -> void:
	_idle_name = &""
	if _ap == null:
		return
	for cand in idle_anim_candidates:
		if cand != "" and _ap.has_animation(cand):
			_idle_name = StringName(cand)
			if debug_anim:
				print("[BossSpawner] Idle candidate: ", _idle_name)
			return
	if debug_anim:
		print("[BossSpawner] No idle candidate found")

func _try_play_idle_now() -> void:
	if _ap == null:
		return
	if _ap.current_animation == "SenseLoop":
		if debug_anim: print("[BossSpawner] Stopping SenseLoop autoplay")
		_ap.stop()
	if _ap.has_method("set"):
		_ap.set("autoplay", "")
	if _idle_name == &"":
		_resolve_idle_name()
	if _idle_name != &"":
		var anim := _ap.get_animation(String(_idle_name))
		if anim != null and anim.loop_mode == Animation.LOOP_NONE:
			anim.loop_mode = Animation.LOOP_LINEAR
		_ap.play(String(_idle_name))

func _ensure_idle_playing() -> void:
	if _anim_auto_owns_idle:
		return
	if _ap == null or _idle_name == &"":
		return
	if _ap.current_animation != String(_idle_name) or not _ap.playback_active:
		_ap.play(String(_idle_name))

func _pause_any_non_idle() -> void:
	if _anim_auto_owns_idle:
		return
	if _ap == null:
		return
	if _idle_name != &"":
		_ap.play(String(_idle_name))
	else:
		_ap.stop()

func _disable_root_tracks_for_idle() -> void:
	if _ap == null or _idle_name == &"": return
	var anim: Animation = _ap.get_animation(String(_idle_name))
	if anim == null: return
	var rig: Node3D = _find_rig_root()
	if rig == null: return
	var rig_path: NodePath = rig.get_path()
	for i: int in anim.get_track_count():
		var path: NodePath = anim.track_get_path(i)
		var tt: int = anim.track_get_type(i)
		var is_root: bool = (path == rig_path)
		var is_transform_track: bool = (
			tt == Animation.TYPE_POSITION_3D or
			tt == Animation.TYPE_ROTATION_3D or
			tt == Animation.TYPE_SCALE_3D
		)
		if is_root and is_transform_track:
			anim.track_set_enabled(i, false)

func _find_rig_root() -> Node3D:
	var cur: Node = (_spawned_visual if _spawned_visual != null else _find_any_mesh())
	for _i: int in range(4):
		if cur == null: break
		var n3: Node3D = cur as Node3D
		if n3 != null:
			var name_lc: String = n3.name.to_lower()
			if name_lc.ends_with("_rig"):
				return n3
			if (n3.find_child("Skeleton3D", true, false) is Skeleton3D) and _find_anim_player_in(n3) != null:
				return n3
		cur = cur.get_parent()
	return self

# ---------------------------------------------------------------------------------
# Idle rotation (small scan) — bursty cadence
# ---------------------------------------------------------------------------------

func _update_idle_rotation(dt: float, player: Node3D) -> void:
	if debug_disable_rotation or not rotate_enabled or not _armed or _awaiting_finish:
		return
	if _reorient_active:
		return

	var my_pos: Vector3 = _visual_pos()
	var p_dist: float = (player.global_transform.origin - my_pos).length()
	if _alerting or p_dist <= proximity_range_m * 1.25:
		_rot_moving = false
		return

	_rot_timer_s -= dt

	if _rot_moving:
		var cur_yaw: float = _current_yaw_rad()
		var diff: float = _shortest_angle(cur_yaw, _rot_target_yaw_rad)
		var max_step: float = deg_to_rad(rotate_speed_deg) * dt
		if absf(diff) <= max_step:
			_set_yaw_rad(_rot_target_yaw_rad)
			_rot_moving = false
			_rot_timer_s = _rand_range(rotate_dwell_min_s, rotate_dwell_max_s)
		else:
			_set_yaw_rad(cur_yaw + signf(diff) * max_step)
		return

	if _rot_timer_s <= 0.0:
		_rot_timer_s = _next_rotate_interval()
		if _rot_rng.randf() > clampf(rotate_probability, 0.0, 1.0):
			return
		_pick_new_yaw_target_small()
		_rot_moving = true

func _pick_new_yaw_target_small() -> void:
	var step_deg: float = _rot_rng.randf_range(rotate_amount_min_deg, rotate_amount_max_deg)
	if (_rot_rng.randi() & 1) == 0:
		step_deg = -step_deg
	var tgt: float = _current_yaw_rad() + deg_to_rad(step_deg)
	var eps: float = 0.001
	if absf(absf(tgt) - PI) < eps: tgt += signf(tgt) * eps
	_rot_target_yaw_rad = tgt

func _next_rotate_interval() -> float:
	return max(0.1, rotate_interval_s + _rot_rng.randf_range(-rotate_interval_jitter_s, rotate_interval_jitter_s))

# ---------------------------------------------------------------------------------
# Big re-orient (75–105°) away from walls
# ---------------------------------------------------------------------------------

func _update_big_reorient(dt: float, player: Node3D) -> void:
	if debug_disable_rotation or not reorient_enabled or not _armed or _awaiting_finish:
		return

	var my_pos: Vector3 = _visual_pos()
	var p_dist: float = (player.global_transform.origin - my_pos).length()
	if _alerting or p_dist <= proximity_range_m * 1.25:
		_reorient_active = false
		return

	if _reorient_active:
		var cur: float = _current_yaw_rad()
		var diff: float = _shortest_angle(cur, _reorient_target_yaw)
		var step: float = deg_to_rad(reorient_speed_deg) * dt
		if absf(diff) <= step:
			_set_yaw_rad(_reorient_target_yaw)
			_reorient_active = false
			_reorient_timer_s = _rand_range(reorient_interval_min_s, reorient_interval_max_s)
		else:
			_set_yaw_rad(cur + signf(diff) * step)
		return

	_reorient_timer_s -= dt
	if _reorient_timer_s <= 0.0:
		_begin_big_reorient(player)

func _begin_big_reorient(player: Node3D) -> void:
	var step_deg: float = _rand_range(reorient_deg_min, reorient_deg_max)
	var sign_val: float = 1.0
	if reorient_use_open_space_bias:
		var left_ok: float = _open_space_score(+1.0, player)
		var right_ok: float = _open_space_score(-1.0, player)
		sign_val = (1.0 if left_ok >= right_ok else -1.0)
	else:
		sign_val = (1.0 if (_rot_rng.randi() & 1) == 0 else -1.0)

	var tgt: float = _current_yaw_rad() + deg_to_rad(step_deg * sign_val)
	var eps: float = 0.001
	if absf(absf(tgt) - PI) < eps: tgt += signf(tgt) * eps
	_reorient_target_yaw = tgt
	_reorient_active = true

func _open_space_score(dir_sign: float, player: Node3D) -> float:
	var cur_yaw: float = _current_yaw_rad()
	var test_yaw: float = cur_yaw + deg_to_rad(15.0) * dir_sign
	var fwd: Vector3 = Vector3(sin(test_yaw), 0.0, cos(test_yaw))

	var origin: Vector3 = global_transform.origin + Vector3(0, cam_eye_height, 0)
	var target: Vector3 = origin + fwd * reorient_probe_len_m

	var rq := PhysicsRayQueryParameters3D.create(origin, target)
	rq.collision_mask = vision_query_mask
	var ex: Array[RID] = _collect_own_collision_rids()
	var pbody := player as PhysicsBody3D
	if pbody != null:
		ex.append(pbody.get_rid())
	rq.exclude = ex

	var hit: Dictionary = get_tree().get_root().world_3d.direct_space_state.intersect_ray(rq)
	if hit.is_empty():
		return reorient_probe_len_m
	var pos: Vector3 = hit.get("position", origin)
	return origin.distance_to(pos)

# ---------------------------------------------------------------------------------
# Yaw helpers
# ---------------------------------------------------------------------------------

func _yaw_from_basis(b: Basis) -> float:
	var fwd: Vector3 = -b.z
	return atan2(fwd.x, fwd.z)

func _current_yaw_rad() -> float:
	return _yaw_accum_rad

func _set_yaw_rad(yaw: float) -> void:
	_yaw_accum_rad = yaw
	var pos: Vector3 = (_yaw_pivot.global_transform.origin if _yaw_pivot != null else global_transform.origin)
	var b := Basis().rotated(Vector3.UP, yaw).orthonormalized()
	if _yaw_pivot != null:
		_yaw_pivot.global_transform = Transform3D(b, pos)
	else:
		global_transform = Transform3D(b, pos)

func _shortest_angle(a: float, b: float) -> float:
	var d: float = b - a
	while d <= -PI: d += TAU
	while d >   PI: d -= TAU
	return d

func _rand_range(a: float, b: float) -> float:
	return _rot_rng.randf_range(min(a, b), max(a, b))

# ---------------------------------------------------------------------------------
# Interaction area
# ---------------------------------------------------------------------------------

func _ensure_interaction_area() -> void:
	var area := get_node_or_null(^"InteractArea") as Area3D
	if area == null:
		area = Area3D.new()
		area.name = "InteractArea"
		add_child(area)
		var shape := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 1.6
		shape.shape = sph
		area.add_child(shape)
	area.monitoring = true
	if not area.is_connected("body_entered", Callable(self, "_on_body_entered")):
		area.body_entered.connect(_on_body_entered)
	if not area.is_connected("body_exited", Callable(self, "_on_body_exited")):
		area.body_exited.connect(_on_body_exited)

func _on_body_entered(body: Node) -> void:
	var p := body as Node3D
	if p != null and (p.is_in_group("player") or p.is_in_group("player_controller")):
		_player_in_range = p
		if debug_logs: print("[BossSpawner] player in range")

func _on_body_exited(body: Node) -> void:
	if _player_in_range == body:
		_player_in_range = null
		if debug_logs: print("[BossSpawner] player left")

# ---------------------------------------------------------------------------------
# Visual helpers
# ---------------------------------------------------------------------------------

func _spawn_visual() -> Node3D:
	var catalog := get_node_or_null(^"/root/MonsterCatalog") as MonsterCatalog
	if catalog == null:
		push_warning("[BossSpawner] MonsterCatalog missing; creating fallback box.")
		return _make_fallback_box()

	var slug: StringName = monster_id
	var vis := catalog.instantiate_visual(self, slug)
	if vis == null:
		push_warning("[BossSpawner] Catalog had no visual for %s; using fallback." % String(slug))
		vis = _make_fallback_box()

	if not use_anim_auto:
		_ap = _find_anim_player_in(vis)
		_resolve_idle_name()
		_try_play_idle_now()

	return vis

func _find_anim_player_in(root: Node) -> AnimationPlayer:
	if root == null:
		return null
	var q: Array[Node] = [root]
	while q.size() > 0:
		var n: Node = q.pop_front() as Node
		var ap: AnimationPlayer = n as AnimationPlayer
		if ap != null:
			return ap
		for i: int in range(n.get_child_count()):
			q.push_back(n.get_child(i))
	return null

func _find_any_mesh() -> Node3D:
	var q: Array[Node] = [self]
	while q.size() > 0:
		var n: Node = q.pop_back() as Node
		if n is MeshInstance3D or n is Sprite3D:
			return n as Node3D
		for i: int in range(n.get_child_count()):
			q.push_back(n.get_child(i))
	return null

func _make_fallback_box() -> Node3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.2, 2.2, 1.2)
	mi.mesh = bm
	add_child(mi)
	return mi

# Prefer rig root path (has AnimationPlayer/Skeleton3D) for better rotation in battle.
func _path_of_visual() -> String:
	var vis: Node3D = _find_any_mesh()
	if vis == null:
		return _my_path_str
	var cur: Node = vis
	for _i: int in range(4):
		if cur == null:
			break
		var n3: Node3D = cur as Node3D
		if n3 != null:
			var name_lc: String = n3.name.to_lower()
			if name_lc.ends_with("_rig"):
				return String(n3.get_path())
			var has_skel: bool = (n3.find_child("Skeleton3D", true, false) is Skeleton3D)
			var ap := _find_anim_player_in(n3)
			if has_skel and ap != null:
				return String(n3.get_path())
		cur = cur.get_parent()
	return String(vis.get_path())

# ---------------------------------------------------------------------------------
# API for EncounterDirector
# ---------------------------------------------------------------------------------

func get_monster_id() -> StringName:
	return monster_id

func mark_defeated_and_cleanup() -> void:
	var cs := get_node_or_null(^"CollisionShape3D") as CollisionShape3D
	if cs != null: cs.disabled = true
	var tw := create_tween()
	tw.tween_property(self, "scale", Vector3(0,0,0), 0.35).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await tw.finished
	if debug_logs:
		print("[BossSpawner] despawn after victory")
	queue_free()

# ---------------------------------------------------------------------------------
# Collision + pivot helpers
# ---------------------------------------------------------------------------------

func _collect_own_collision_rids() -> Array[RID]:
	var out: Array[RID] = []
	var q: Array[Node] = [self]
	while q.size() > 0:
		var n: Node = q.pop_front() as Node
		var co: CollisionObject3D = n as CollisionObject3D
		if co != null:
			out.append(co.get_rid())
		for i: int in range(n.get_child_count()):
			q.push_back(n.get_child(i))
	return out

func _setup_yaw_pivot() -> void:
	var rig: Node3D = null
	var cur: Node = (_spawned_visual if _spawned_visual != null else _find_any_mesh())
	for _i: int in range(4):
		if cur == null: break
		var n3: Node3D = cur as Node3D
		if n3 != null:
			var name_lc: String = n3.name.to_lower()
			if name_lc.ends_with("_rig") or ((n3.find_child("Skeleton3D", true, false) is Skeleton3D) and _find_anim_player_in(n3) != null):
				rig = n3
				break
		cur = cur.get_parent()
	if rig == null:
		return

	if rig.get_parent() != null and rig.get_parent().name == "YawPivot":
		_yaw_pivot = rig.get_parent() as Node3D
		return

	_yaw_pivot = Node3D.new()
	_yaw_pivot.name = "YawPivot"
	_yaw_pivot.transform = rig.transform
	add_child(_yaw_pivot)

	var rig_parent: Node = rig.get_parent()
	if rig_parent == self:
		remove_child(rig)
	else:
		rig_parent.remove_child(rig)

	_yaw_pivot.add_child(rig)
	rig.transform = Transform3D.IDENTITY
