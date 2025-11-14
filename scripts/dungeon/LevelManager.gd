extends Node
class_name LevelManager

const TimeService := preload("res://persistence/services/time_service.gd")

# Toggle on/off from the Inspector
@export var debug_saves: bool = true

# Autoload instance (typed)
@onready var SaveManagerInst: SaveManager = get_node("/root/SaveManager") as SaveManager

# --- Wire up to your DungeonGenerator node (usually the parent "Dungeon") ---
@export var dungeon_path: NodePath

# --- Growth rules ---
@export var size_growth_pct: float = 10.0      # each “up” grows W/H by +10% (ceil)
@export var rooms_inc_every: int = 10          # every +10 in max dimension => +1 to room_attempts & room_max
@export var size_cap: int = 256                # hard cap per side (safety)
@export var keep_sizes_odd: bool = true        # keep sizes odd (grid-friendly)

# --- Optional: auto-open any door tagged with this group after a NEW (forward) level ---
@export var entry_door_group: StringName = &"spawn_entry_door"

# --- Internals ---
var _gen: Node = null
var _entry_should_open: bool = false
var _during_transition: bool = false

var _current_floor: int = 0
var _floors: Array[Dictionary] = []            # stack of floor states

# Baselines captured from floor 0 at startup
var _base_width: int = 0
var _base_height: int = 0
var _base_room_attempts: int = 0
var _base_room_max: int = 0

func _ready() -> void:
	# Resolve generator
	if dungeon_path != NodePath() and has_node(dungeon_path):
		_gen = get_node(dungeon_path)
	else:
		_gen = get_parent()

	if _gen == null:
		push_error("[LevelManager] Could not resolve DungeonGenerator node.")
		return

	# Capture baselines from current generator settings
	_base_width         = int(_safe_get(_gen, "width", 11))
	_base_height        = int(_safe_get(_gen, "height", 11))
	_base_room_attempts = int(_safe_get(_gen, "room_attempts", 1))
	_base_room_max      = int(_safe_get(_gen, "room_max", 1))

	# Initialize floor 0 state from the current generator
	if _floors.is_empty():
		var s0: Dictionary = {
			"seed": int(_safe_get(_gen, "rng_seed", randi())),
			"width": _base_width,
			"height": _base_height,
			"room_attempts": _base_room_attempts,
			"room_max": _base_room_max
		}
		_floors.append(s0)

	scan_and_log_doors()
	call_deferred("_post_ready_sync")
	var lab_dir: String = "res://audio/labyrinth"
	var empty_playlist: Array[AudioStream] = [] as Array[AudioStream]
	var shuffle_tracks: bool = true
	var vol_db: float = -6.0
	var fade_s: float = 0.4
	var bus_name: String = "Master"

	MusicManager.play_folder(
		lab_dir,
		empty_playlist,
		shuffle_tracks,
		vol_db,
		fade_s,
		bus_name
	)

# -------------------------------------------------------------------
# Public API (called by doors or other game logic)
# -------------------------------------------------------------------
func goto_next_level() -> void:
	_current_floor = max(1, _current_floor + 1)

	_ensure_floor_state(_current_floor)
	_apply_state(_floors[_current_floor], false)

	# Persist via SaveManager (source of truth)
	SaveManagerInst.set_run_floor(_current_floor)

	# Mirror into RunState WITHOUT autosave (we just saved via SaveManager)
	if Engine.has_singleton("RunState") or has_node(^"/root/RunState"):
		RunState.set_depth(_current_floor, false)

	# Segment/sigil bookkeeping
	SaveManagerInst.ensure_sigil_segment_for_floor(_current_floor, 4)

	_debug_print_saves("next")

func goto_prev_level() -> void:
	# Floors are 1-based; clamp instead of allowing 0/negatives
	if _current_floor <= 1:
		_current_floor = 1
		return

	_current_floor -= 1
	_apply_state(_floors[_current_floor], true)

	# Persist via SaveManager
	SaveManagerInst.set_run_floor(_current_floor)

	# Mirror into RunState WITHOUT autosave
	if Engine.has_singleton("RunState") or has_node(^"/root/RunState"):
		RunState.set_depth(_current_floor, false)

	SaveManagerInst.ensure_sigil_segment_for_floor(_current_floor, 4)

	_debug_print_saves("prev")

# Optional alias if something calls this name
func request_next_level() -> void:
	goto_next_level()

# -------------------------------------------------------------------
# Internals
# -------------------------------------------------------------------
func _ensure_floor_state(index: int) -> void:
	# Already exists?
	if index < _floors.size() and typeof(_floors[index]) == TYPE_DICTIONARY:
		return

	# Base from previous floor (or baseline if none)
	var prev: Dictionary
	if index - 1 >= 0 and index - 1 < _floors.size() and typeof(_floors[index - 1]) == TYPE_DICTIONARY:
		prev = _floors[index - 1]
	else:
		prev = {
			"seed": int(_safe_get(_gen, "rng_seed", randi())),
			"width": _base_width,
			"height": _base_height,
			"room_attempts": _base_room_attempts,
			"room_max": _base_room_max
		}

	# Grow size
	var prev_w: int = int(prev["width"])
	var prev_h: int = int(prev["height"])
	var new_w: int = int(ceil(float(prev_w) * (1.0 + size_growth_pct * 0.01)))
	var new_h: int = int(ceil(float(prev_h) * (1.0 + size_growth_pct * 0.01)))

	if keep_sizes_odd:
		if (new_w & 1) == 0:
			new_w += 1
		if (new_h & 1) == 0:
			new_h += 1

	new_w = min(size_cap, new_w)
	new_h = min(size_cap, new_h)

	# Bump rooms every +rooms_inc_every in max dimension above baseline
	var max_dim: int = max(new_w, new_h)
	var base_dim: int = max(_base_width, _base_height)
	var increments: int = 0
	if max_dim > base_dim and rooms_inc_every > 0:
		increments = int(floor(float(max_dim - base_dim) / float(rooms_inc_every)))

	var ra: int = _base_room_attempts + increments
	var rm: int = _base_room_max + increments

	var seed_val: int = _fresh_floor_seed()  # deterministic per floor

	var state: Dictionary = {
		"seed": seed_val,
		"width": new_w,
		"height": new_h,
		"room_attempts": ra,
		"room_max": rm
	}

	if index >= _floors.size():
		_floors.resize(index + 1)
	_floors[index] = state

func _apply_state(state: Dictionary, backtracking: bool) -> void:
	if _gen == null:
		return
	_during_transition = true

	_safe_set(_gen, "width", int(state.get("width", _base_width)))
	_safe_set(_gen, "height", int(state.get("height", _base_height)))
	_safe_set(_gen, "room_attempts", int(state.get("room_attempts", _base_room_attempts)))
	_safe_set(_gen, "room_max", int(state.get("room_max", _base_room_max)))

	var seed: int = int(state.get("seed", randi()))
	_safe_set(_gen, "rng_seed", seed)

	if _gen.has_method("_apply_seed"):
		_gen.call("_apply_seed", false)
	if _gen.has_method("_generate_and_paint"):
		_gen.call("_generate_and_paint")

	# 1) Build anchors (elite/treasure) for this floor
	if _gen.has_method("build_anchors_for_floor"):
		_gen.call("build_anchors_for_floor", _current_floor)

	# 2) Start encounter loop for this floor + reset step counting
	var enc := get_node_or_null(^"/root/EncounterDirector")
	if enc != null and _gen.has_method("get_floor_navdata"):
		var navdata: Dictionary = _gen.call("get_floor_navdata")
		var rs: Dictionary = SaveManagerInst.load_run()
		var run_seed: int = int(dget(rs, "run_seed", 0))

		# Reset EncounterDirector with fresh floor state
		enc.call("start_floor", _current_floor, run_seed, navdata)

		# Re-register the player and reset its stepper (so floor 2+ rolls resume)
		var player_path: NodePath = (_gen.get("player_path") as NodePath) if _gen.has_method("get") else NodePath()
		if player_path != NodePath() and _gen.has_node(player_path):
			var player: Node = _gen.get_node(player_path)
			if player != null:
				if enc.has_method("register_player"):
					enc.call("register_player", player)

				var stepper: Node = player.get_node_or_null(^"StepStepper")
				if stepper != null:
					if stepper.has_method("reset_after_floor_change"):
						stepper.call("reset_after_floor_change")
					# Optional: wire a signal if your stepper exposes one
					if stepper.has_signal("stepped") and not stepper.is_connected("stepped", Callable(enc, "on_step")):
						stepper.connect("stepped", Callable(enc, "on_step"))
				elif player.has_method("reset_after_floor_change"):
					player.call("reset_after_floor_change")

	# 3) Populate elites & boss from anchors
	if _gen.has_method("populate_elites_and_boss"):
		_gen.call("populate_elites_and_boss", _current_floor)

	# 3.5) Position player when moving UP (not backtracking)
	if not backtracking:
		_reposition_player_to_up_spawn()

	# 4) Entry door handling
	if _entry_should_open or not backtracking:
		_open_spawn_entry_doors()
	_entry_should_open = false
	_during_transition = false

	# --- NEW: initialize per-floor time service ------------------------------
	var w_now: int = int(state.get("width", _base_width))
	var h_now: int = int(state.get("height", _base_height))
	# Entry bonus can be tuned later; pass 0 for now (deterministic).
	TimeService.begin_floor(_base_width, _base_height, w_now, h_now, rooms_inc_every, _current_floor, 0.0, SaveManager.active_slot())


# --- tiny util helpers to avoid Variant inference warnings ---
func _safe_get(o: Object, prop: String, fallback: Variant) -> Variant:
	if o == null:
		return fallback
	if o.has_method("get"):
		var v: Variant = o.get(prop)
		return v if v != null else fallback
	return fallback

func _safe_set(o: Object, prop: String, v: Variant) -> void:
	if o == null:
		return
	if o.has_method("set"):
		o.set(prop, v)

func scan_and_log_doors() -> void:
	var doors: Array = get_tree().get_nodes_in_group(&"exit_door")
	for d in doors:
		if d != null:
			if d.has_method("debug_dump"):
				d.call("debug_dump")

func set_entry_should_open(v: bool) -> void:
	_entry_should_open = v

func is_transitioning() -> bool:
	return _during_transition

func sync_to_saved_floor() -> void:
	var target: int
	if SaveManager.run_exists():
		target = SaveManager.peek_run_depth()
	else:
		target = SaveManager.get_current_floor()

	# Clamp to at least Floor 1
	if target < 1:
		target = 1

	# Build states up to the target floor and apply it
	while _current_floor < target:
		_current_floor += 1
		_ensure_floor_state(_current_floor)

	_apply_state(_floors[_current_floor], false)
	# Mirror to saves (harmless if already correct)
	SaveManager.set_run_floor(_current_floor)
	
	SaveManagerInst.ensure_sigil_segment_for_floor(_current_floor, 4)
	
	if Engine.has_singleton("RunState") or has_node(^"/root/RunState"):
		RunState.set_depth(_current_floor, false)

func _post_ready_sync() -> void:
	if _gen != null and not _gen.is_node_ready():
		await _gen.ready
	await get_tree().process_frame
	
	_ensure_run_ready(SaveManager.active_slot())

	
	sync_to_saved_floor()
	_debug_print_saves("resume")

func _seg_for_floor(floor: int) -> int:
	return (max(1, floor) - 1) / 3 + 1

static func dget(d: Dictionary, key: String, def: Variant) -> Variant:
	return d[key] if d.has(key) else def

func _debug_print_saves(context: String) -> void:
	if not debug_saves:
		return

	# --- META (Dictionary) ---
	var gs: Dictionary = SaveManagerInst.load_game()
	var prev: int = int(dget(gs, "previous_floor", 0))
	var cur: int = int(dget(gs, "current_floor", 1))
	var last: int = int(dget(gs, "last_floor", 1))
	var schema_meta: int = int(dget(gs, "schema_version", 1))

	# Anchors
	var anchors_any: Variant = dget(gs, "anchors_unlocked", [])
	var anchors_arr: Array = (anchors_any as Array) if anchors_any is Array else []
	var anchors_strs: Array[String] = []
	for a in anchors_arr:
		anchors_strs.append(str(int(a)))

	# Segments
	var seg_any: Variant = dget(gs, "world_segments", [])
	var seg_arr: Array = (seg_any as Array) if seg_any is Array else []
	var seg_lines: Array[String] = []
	for s_any in seg_arr:
		if not (s_any is Dictionary):
			continue
		var sd: Dictionary = s_any as Dictionary
		var sid: int = int(dget(sd, "segment_id", 1))
		var drained: bool = bool(dget(sd, "drained", false))
		var boss: bool = bool(dget(sd, "boss_sigil", false))
		seg_lines.append("id=%d drained=%s boss=%s" % [sid, str(drained), str(boss)])

	# Penalties
	var p_any: Variant = dget(gs, "penalties", {})
	var p: Dictionary = (p_any as Dictionary) if p_any is Dictionary else {}
	var lvl_pct: float = float(dget(p, "level_pct", 0.10))
	var skill_pct: float = float(dget(p, "skill_xp_pct", 0.15))
	var floor_lvl: int = int(dget(p, "floor_at_level", 1))
	var floor_skill: int = int(dget(p, "floor_at_skill_level", 1))

	# Seeds (sorted)
	var seeds_any: Variant = dget(gs, "floor_seeds", {})
	var seeds: Dictionary = (seeds_any as Dictionary) if seeds_any is Dictionary else {}
	var keys_int: Array[int] = []
	for k in seeds.keys():
		keys_int.append(int(k))
	keys_int.sort()
	var parts: Array[String] = []
	for k in keys_int:
		parts.append("%d:%d" % [k, int(seeds[k])])

	# --- RUN (Dictionary) ---
	var rs: Dictionary = SaveManagerInst.load_run()
	var run_depth: int = int(dget(rs, "depth", 1))
	var run_seed: int = int(dget(rs, "run_seed", 0))
	var hp_max: int = int(dget(rs, "hp_max", 30))
	var hp: int = int(dget(rs, "hp", hp_max))
	var mp_max: int = int(dget(rs, "mp_max", 10))
	var mp: int = int(dget(rs, "mp", mp_max))
	var gold: int = int(dget(rs, "gold", 0))

func _open_spawn_entry_doors() -> void:
	var list: Array = get_tree().get_nodes_in_group(entry_door_group)
	for n in list:
		if n == null:
			continue
		if n.has_method("animate_open_entry"):
			n.call_deferred("animate_open_entry")  # smooth open on arrival
		elif n.has_method("force_open_unlocked_now"):
			n.call_deferred("force_open_unlocked_now")  # fallback

func _fresh_floor_seed() -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	# Mix in run_seed + time so two entries close in time still differ per run
	var t_usec: int = int(Time.get_ticks_usec())
	var run_seed: int = SaveManager.get_run_seed()
	var hi: int = int((t_usec ^ (run_seed << 1)) & 0xFFFFFFFF)
	var lo: int = int((run_seed ^ (t_usec << 1)) & 0xFFFFFFFF)
	return int((hi << 32) | lo)

func _reposition_player_to_up_spawn() -> void:
	if _gen == null:
		return

	# Resolve player from generator's exported path if available
	var player_path: NodePath = (_gen.get("player_path") as NodePath) if _gen.has_method("get") else NodePath()
	var player: Node3D = null
	if player_path != NodePath() and _gen.has_node(player_path):
		player = _gen.get_node(player_path) as Node3D
	else:
		# Fallback: try a common path/name
		player = _gen.find_child("Player", true, false) as Node3D

	if player == null:
		return

	# Preferred: by node name under the placed stair room
	var stairs: Node = _gen.find_child("Stair_Room_Down", true, false)
	var target: Node3D = null
	if stairs != null:
		target = stairs.get_node_or_null(^"Anchor_Spawn_Up") as Node3D

	# Fallback: by group if you tag it (recommended): "anchor_spawn_up"
	if target == null:
		var list: Array = get_tree().get_nodes_in_group(&"anchor_spawn_up")
		if list.size() > 0:
			target = list[0] as Node3D

	if target == null:
		return

	# Move & orient player
	player.global_position = target.global_position
	# Optional: match facing from the anchor
	player.global_rotation = target.global_rotation

	# If CharacterBody3D, clear motion
	if "velocity" in player:
		player.set("velocity", Vector3.ZERO)

func _ensure_run_ready(slot: int = 0) -> void:
	slot = (slot if slot > 0 else SaveManager.active_slot())
	if not SaveManager.run_exists(slot):
		if SaveManager.has_method("start_or_refresh_run_from_meta"):
			SaveManager.start_or_refresh_run_from_meta(slot)
		else:
			SaveManager.load_run(slot)
		if Engine.has_singleton("RunState") or has_node(^"/root/RunState"):
			RunState.reload(slot)
