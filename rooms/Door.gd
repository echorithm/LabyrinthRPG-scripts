extends Node3D
class_name Door

@export var open_angle_deg: float = 100.0
@export var open_time: float = 1.35
@export var close_time: float = 1.35
@export var auto_close_seconds: float = 0.0
@export var input_action: StringName = &"interact"

@export var mesh_path: NodePath = ^"wall_doorway_door"
@export var door_shape_path: NodePath = ^"DoorBody/CollisionShape3D" # kept for backwards-compat, but we now toggle ALL colliders
@export var interact_zone_path: NodePath = ^"InteractZone"

@export var player_group: StringName = &"player"

# Locking / key integration
@export var locked: bool = false
@export var locked_hint: String = "It's locked."
@export var door_group_name: StringName = &"exit_door"   # key calls this group’s unlock()

# Spawn/open behavior
@export var start_open_on_ready: bool = false            # kept for backward-compat (ignored if entry_open_on_ready true)
@export var auto_close_on_ready: bool = false            # if true, auto-closes after auto_close_seconds
@export var entry_open_on_ready: bool = false            # NEW: spawn CLOSED, then animate open on ready (use on entry doors)

# Level travel (handled by LevelManager)
@export_enum("None", "Next", "Prev") var on_open_action: int = 0
@export var level_manager_path: NodePath

var _lm: Node = null
var _is_open: bool = false
var _tween: Tween
var _mesh: Node3D
var _shape: CollisionShape3D
var _zone: Area3D
var _players_in_zone: int = 0
var _level_action_fired: bool = false

func _ready() -> void:
	_mesh  = get_node_or_null(mesh_path) as Node3D
	_shape = get_node_or_null(door_shape_path) as CollisionShape3D
	_zone  = get_node_or_null(interact_zone_path) as Area3D

	if _mesh == null or _zone == null:
		push_error("[Door] Missing nodes. mesh:%s zone:%s (shape optional)" % [_mesh, _zone])
		return

	if _zone and not _zone.body_entered.is_connected(_on_body_enter):
		_zone.body_entered.connect(_on_body_enter)
	if _zone and not _zone.body_exited.is_connected(_on_body_exit):
		_zone.body_exited.connect(_on_body_exit)

	_update_group_membership()
	_set_closed_state()

	_resolve_level_manager()
	validate_setup()

	# ENTRY behavior choices:
	# 1) entry_open_on_ready: spawn CLOSED, then animate open (preferred for new-floor entry doors)
	# 2) start_open_on_ready (legacy): instantly forced open (kept for compat; ignored if entry_open_on_ready is true)
	if not locked:
		if entry_open_on_ready:
			# Defer so children are ready and transforms settled
			call_deferred("animate_open_entry")
		elif start_open_on_ready:
			force_open_unlocked_now()
			if auto_close_on_ready and auto_close_seconds > 0.0:
				var t: Tween = get_tree().create_tween()
				t.tween_interval(auto_close_seconds)
				t.tween_callback(_close)

func _input(e: InputEvent) -> void:
	if _zone == null: return
	if _players_in_zone <= 0: return
	# ignore while level is regenerating
	if _lm != null and _lm.has_method("is_transitioning") and _lm.call("is_transitioning"):
		return

	if e.is_action_pressed(input_action):
		if locked:
			print("[Door] ", locked_hint)
			return

		# If this door triggers level travel, DO NOT tween here (hard-cut to LM)
		if on_open_action != 0 and _lm != null:
			_do_level_action()
			return

		# Cosmetic door behavior (non-travel doors only)
		if _is_open:
			_close()
		else:
			_open()

# ---- Public API --------------------------------------------------------------

func lock() -> void:
	set_locked(true)

func unlock() -> void:
	set_locked(false)

func set_locked(v: bool) -> void:
	locked = v
	if locked:
		_set_closed_state()
		_set_colliders_enabled(true)
	_update_group_membership()

# Instantly open (no tween), used at spawn or by LevelManager (legacy)
func force_open_unlocked_now() -> void:
	_is_open = true
	_level_action_fired = false
	if _tween != null and _tween.is_running():
		_tween.kill()
	_set_colliders_enabled(false)
	if _mesh != null:
		_mesh.rotation_degrees.y = open_angle_deg

# Smoothly opens this door (no level travel). Use for entry doors on new floors.
func animate_open_entry(duration: float = -1.0) -> void:
	if locked or _mesh == null:
		return
	# Ensure we start CLOSED visually before animating
	_set_closed_state()

	_is_open = true
	_level_action_fired = false

	if _tween != null and _tween.is_running():
		_tween.kill()

	_set_colliders_enabled(false)

	var d: float = open_time if duration <= 0.0 else duration
	var tw: Tween = get_tree().create_tween()
	_tween = tw
	tw.tween_property(_mesh, "rotation_degrees:y", open_angle_deg, d)

	if auto_close_seconds > 0.0:
		tw.tween_interval(auto_close_seconds)
		tw.tween_callback(_close)

# ---- Internals ---------------------------------------------------------------

func _update_group_membership() -> void:
	if locked:
		if not is_in_group(door_group_name):
			add_to_group(door_group_name)
	else:
		if is_in_group(door_group_name):
			remove_from_group(door_group_name)

func _open() -> void:
	# Only used for non-travel doors
	if _is_open or _mesh == null:
		return
	# Safety: if someone misconfigured this door to travel, hard-cut instead of tween
	if on_open_action != 0 and _lm != null:
		_do_level_action()
		return

	_is_open = true
	_level_action_fired = false

	if _tween != null and _tween.is_running():
		_tween.kill()

	# Disable ALL door colliders (except anything under InteractZone)
	_set_colliders_enabled(false)

	var tw: Tween = get_tree().create_tween()
	_tween = tw
	tw.tween_property(_mesh, "rotation_degrees:y", open_angle_deg, open_time)

	if auto_close_seconds > 0.0:
		tw.tween_interval(auto_close_seconds)
		tw.tween_callback(_close)

func _do_level_action() -> void:
	if _level_action_fired:
		return
	if locked or _lm == null:
		return

	_level_action_fired = true
	if _lm.has_method("set_entry_should_open"):
		_lm.call("set_entry_should_open", true)

	if on_open_action == 1 and _lm.has_method("goto_next_level"):
		print("[Door] OPEN -> NEXT level")
		_lm.call("goto_next_level")
	elif on_open_action == 2 and _lm.has_method("goto_prev_level"):
		print("[Door] OPEN -> PREV level")
		_lm.call("goto_prev_level")

func _close() -> void:
	if not _is_open or _mesh == null:
		return
	_is_open = false
	if _tween != null and _tween.is_running():
		_tween.kill()

	var tw: Tween = get_tree().create_tween()
	_tween = tw
	tw.tween_property(_mesh, "rotation_degrees:y", 0.0, close_time)
	tw.tween_callback(_enable_collision)

func _enable_collision() -> void:
	_set_colliders_enabled(true)

func _set_closed_state() -> void:
	_is_open = false
	_level_action_fired = false
	if _mesh != null:
		_mesh.rotation_degrees.y = 0.0
	_set_colliders_enabled(true)

func _on_body_enter(b: Node) -> void:
	if b.is_in_group(player_group):
		_players_in_zone += 1

func _on_body_exit(b: Node) -> void:
	if b.is_in_group(player_group):
		_players_in_zone = max(0, _players_in_zone - 1)

func _resolve_level_manager() -> void:
	_lm = null
	if level_manager_path != NodePath() and has_node(level_manager_path):
		_lm = get_node(level_manager_path)
	else:
		# Fallback: walk up looking for a child named "LevelManager"
		var p: Node = get_parent()
		while p != null and _lm == null:
			_lm = p.get_node_or_null("LevelManager")
			p = p.get_parent()

# --- Collider utilities -------------------------------------------------------

func _set_colliders_enabled(enabled: bool) -> void:
	# Toggle all CollisionShape3D under this door, EXCEPT shapes under the InteractZone
	var toggled: int = 0
	var stack: Array[Node] = [self]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		for child: Node in n.get_children():
			stack.push_back(child)
			if child is CollisionShape3D:
				var cs := child as CollisionShape3D
				# skip shapes that belong to the InteractZone subtree
				if _zone != null and _zone.is_ancestor_of(cs):
					continue
				cs.set_deferred("disabled", not enabled)
				toggled += 1
	# legacy single-shape path (kept for consistency)
	if _shape != null and (_zone == null or not _zone.is_ancestor_of(_shape)):
		_shape.set_deferred("disabled", not enabled)

# ---- Debug helpers -----------------------------------------------------------

func validate_setup() -> void:
	var ok_mesh: bool = _mesh != null
	var ok_shape: bool = _shape != null
	var ok_zone: bool = _zone != null
	var ok_lm: bool = _lm != null
	# optional: print or assert here
