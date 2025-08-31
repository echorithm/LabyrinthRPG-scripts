extends Node
class_name LevelManager

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

# -------------------------------------------------------------------
# Public API (called by doors or other game logic)
# -------------------------------------------------------------------
func goto_next_level() -> void:
	_current_floor += 1
	_ensure_floor_state(_current_floor)
	_apply_state(_floors[_current_floor], false)

func goto_prev_level() -> void:
	if _current_floor <= 0:
		_current_floor = 0
		return
	_current_floor -= 1
	_apply_state(_floors[_current_floor], true)

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
		if (new_w & 1) == 0: new_w += 1
		if (new_h & 1) == 0: new_h += 1

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

	# Fresh seed for the new floor (simple RNG; no bit ops to avoid type warnings)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var seed_val: int = int(rng.randi())

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
	if _gen == null: return
	_during_transition = true

	_safe_set(_gen, "width", int(state.get("width", _base_width)))
	_safe_set(_gen, "height", int(state.get("height", _base_height)))
	_safe_set(_gen, "room_attempts", int(state.get("room_attempts", _base_room_attempts)))
	_safe_set(_gen, "room_max", int(state.get("room_max", _base_room_max)))

	var seed: int = int(state.get("seed", randi()))
	_safe_set(_gen, "rng_seed", seed)

	if _gen.has_method("_apply_seed"): _gen.call("_apply_seed", false)
	if _gen.has_method("_generate_and_paint"): _gen.call("_generate_and_paint")

	# Open entry doors if we arrived by opening a door, or when moving forward by default
	if _entry_should_open or not backtracking:
		_open_spawn_entry_doors()
	_entry_should_open = false
	_during_transition = false

func _open_spawn_entry_doors() -> void:
	var list: Array = get_tree().get_nodes_in_group(entry_door_group)
	for n in list:
		if n.has_method("force_open_unlocked_now"):
			n.call("force_open_unlocked_now")

# --- tiny util helpers to avoid Variant inference warnings ---
func _safe_get(o: Object, prop: String, fallback: Variant) -> Variant:
	if o == null: return fallback
	if o.has_method("get"):
		var v: Variant = o.get(prop)
		return v if v != null else fallback
	return fallback

func _safe_set(o: Object, prop: String, v: Variant) -> void:
	if o == null: return
	if o.has_method("set"):
		o.set(prop, v)

func scan_and_log_doors() -> void:
	var doors: Array = get_tree().get_nodes_in_group(&"exit_door")
	print("[LM] exit_door group members: ", doors.size())
	for d in doors:
		if d != null:
			if d.has_method("debug_dump"):
				d.call("debug_dump")
			else:
				print("[LM] door without debug_dump: ", d.get_path())

func set_entry_should_open(v: bool) -> void:
	_entry_should_open = v

func is_transitioning() -> bool:
	return _during_transition
