extends Node
# Autoload

# --- Tunables ---
@export var start_grace_steps: int = 10
@export var post_battle_grace_steps: int = 8
@export var th_min: int = 100
@export var th_max: int = 140

# Debug
@export var debug_rng: bool = false
@export var debug_rng_steps: bool = false
@export var debug_rng_suppression: bool = false
@export var route_rng_to_battle: bool = true   # when false, SIM-ONLY: just prints payload
@export var rng_sim_only: bool = false          # kept for compatibility

# --- Runtime state ---
var _player: Node3D = null
@onready var _router: Node = get_node_or_null(^"/root/EncounterRouter") as Node

var _floor: int = 1
var _triad_id: int = 1
var _run_seed: int = 0

# Pool is slugs (StringName)
var _pool: Array[StringName] = []
var _boss_id: StringName = &""

# Encounter Meter
var _em: int = 0
var _th: int = 120
var _encounter_cycle: int = 0
var _eligible_step_index: int = 0
var _post_grace_left: int = 0

# Navdata
var _width: int = 0
var _height: int = 0
var _cell_size: float = 4.0
var _grid_xform: Transform3D = Transform3D.IDENTITY
var _reserved: PackedByteArray = PackedByteArray()
var _open: PackedInt32Array = PackedInt32Array()
var _finish_cell: Vector2i = Vector2i(-1, -1)

# Helpers
var _pool_helper: TriadPool = TriadPool.new()
var _encounter_active: bool = false
var _battle_pending: bool = false
var _last_trigger_step_index: int = -1

func _ready() -> void:
	_router = get_node_or_null(^"/root/EncounterRouter")
	if _router != null:
		if not _router.is_connected("encounter_requested", Callable(self, "_on_router_requested")):
			_router.connect("encounter_requested", Callable(self, "_on_router_requested"))
		if not _router.is_connected("encounter_finished", Callable(self, "_on_router_finished")):
			_router.connect("encounter_finished", Callable(self, "_on_router_finished"))

# ---------------- Public API ----------------
func start_floor(floor: int, run_seed: int, navdata: Dictionary) -> void:
	_floor = floor
	_run_seed = run_seed
	_triad_id = TriadPool.triad_id_for_floor(floor)
	_apply_navdata(navdata)

	_pool = _pool_helper.pool_for_triad(_run_seed, _triad_id)                # slugs (StringName)
	_boss_id = _pool_helper.boss_for_triad(_run_seed, _triad_id, _pool)      # slug (StringName)

	_em = 0
	_encounter_cycle = 0
	_eligible_step_index = 0
	_post_grace_left = 0
	_th = _draw_threshold()

	print("[Encounter] Floor=", _floor, " triad=", _triad_id, " pool=", _pool, " boss=", _boss_id, " TH=", _th)
	_rng("start floor=%d triad=%d pool=%s boss=%s TH=%d"
		% [_floor, _triad_id, str(_pool), String(_boss_id), _th])

func set_all_monsters(_list: Array[StringName]) -> void:
	# No-op now; TriadPool pulls from MonsterCatalog directly.
	pass

func get_pool_for_floor(floor: int) -> Array[StringName]:
	var t := TriadPool.triad_id_for_floor(floor)
	return (_pool if t == _triad_id else _pool_helper.pool_for_triad(_run_seed, t))

func get_boss_for_floor(floor: int) -> StringName:
	var t := TriadPool.triad_id_for_floor(floor)
	if t == _triad_id:
		return _boss_id
	var pool := _pool_helper.pool_for_triad(_run_seed, t)
	return _pool_helper.boss_for_triad(_run_seed, t, pool)

func pick_elite_for_anchor(floor: int, anchor_index: int) -> StringName:
	var t := TriadPool.triad_id_for_floor(floor)
	var pool := (_pool if t == _triad_id else _pool_helper.pool_for_triad(_run_seed, t))
	if pool.is_empty():
		return StringName("")
	var seed := DetHash.djb2_64([str(_run_seed), "ELITE_ANCHOR", str(floor), str(anchor_index)])
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	return pool[rng.randi_range(0, pool.size() - 1)]

# Called by the player's StepStepper on new cell
func on_step(cell: Vector2i, world_pos: Vector3) -> void:
	if get_tree().paused or _encounter_active or _battle_pending:
		if debug_rng_suppression:
			_rng("skip step: paused=%s active=%s pending=%s" %
				[str(get_tree().paused), str(_encounter_active), str(_battle_pending)])
		return

	if not _cell_in_bounds(cell):
		if debug_rng_suppression:
			_rng("skip step: OOB cell=%s" % [str(cell)])
		return

	if _is_reserved(cell) or cell == _finish_cell:
		if debug_rng_suppression:
			var why: String = "reserved" if _is_reserved(cell) else "finish_cell"
			_rng("skip step: %s at cell=%s" % [why, str(cell)])
		return

	if _eligible_step_index < start_grace_steps:
		if debug_rng_suppression:
			_rng("skip step: start_grace (%d/%d)" % [_eligible_step_index, start_grace_steps])
		_eligible_step_index += 1
		return

	if _post_grace_left > 0:
		if debug_rng_suppression:
			_rng("skip step: post_battle_grace left=%d" % _post_grace_left)
		_post_grace_left -= 1
		return

	# Deterministic increment + tiny jitter
	var base_raw: int = 8 + ((_floor - 1) % 3 + 1) + ((_floor - 1) / 3) * 3
	var jit_seed: int = DetHash.djb2_64([str(_run_seed), "TRASH_STEP_JITTER", str(_floor), str(_eligible_step_index)])
	var jrng := RandomNumberGenerator.new()
	jrng.seed = jit_seed
	var jitter: int = jrng.randi_range(-1, 1)

	var before: int = _em
	_em += base_raw + jitter
	_eligible_step_index += 1

	if debug_rng_steps:
		_rng("step=%d cell=%s em:%d + (%d + %d) => %d  th=%d"
			% [_eligible_step_index, str(cell), before, base_raw, jitter, _em, _th])
		if (_eligible_step_index % 10) == 0:
			var rem: int = max(0, _th - _em)
			_rng("summary: eligible=%d em=%d th=%d rem=%d post_grace=%d"
				% [_eligible_step_index, _em, _th, rem, _post_grace_left])

	if _em >= _th:
		if _last_trigger_step_index == _eligible_step_index:
			if debug_rng_steps:
				_rng("blocked double-fire @ step=%d" % _eligible_step_index)
			return
		_last_trigger_step_index = _eligible_step_index

		_trigger_battle(cell, world_pos)
		_em = 0
		_encounter_cycle += 1
		_th = _draw_threshold()
		_post_grace_left = post_battle_grace_steps

# World/grid helpers
func world_to_cell(world_pos: Vector3) -> Vector2i:
	var local: Vector3 = _grid_xform.affine_inverse() * world_pos
	var cx: int = int(floor(local.x / _cell_size + 0.5))
	var cz: int = int(floor(local.z / _cell_size + 0.5))
	return Vector2i(cx, cz)

func cell_size() -> float:
	return _cell_size

# ---------------- Internals ----------------
func _apply_navdata(nav: Dictionary) -> void:
	_width = int(nav.get("width", 0))
	_height = int(nav.get("height", 0))
	_cell_size = float(nav.get("cell_size", 4.0))
	var xf: Variant = nav.get("grid_transform", Transform3D.IDENTITY)
	_grid_xform = (xf as Transform3D) if xf is Transform3D else Transform3D.IDENTITY
	var res_any: Variant = nav.get("reserved", PackedByteArray())
	_reserved = (res_any as PackedByteArray) if res_any is PackedByteArray else PackedByteArray()
	var open_any: Variant = nav.get("open", PackedInt32Array())
	_open = (open_any as PackedInt32Array) if open_any is PackedInt32Array else PackedInt32Array()
	var fcell_any: Variant = nav.get("finish_cell", Vector2i(-1, -1))
	_finish_cell = (fcell_any as Vector2i) if fcell_any is Vector2i else Vector2i(-1, -1)

func _cell_in_bounds(c: Vector2i) -> bool:
	return (c.x >= 0 and c.x < _width and c.y >= 0 and c.y < _height)

func _is_reserved(c: Vector2i) -> bool:
	if _reserved.size() == 0:
		return false
	var idx: int = c.y * _width + c.x
	if idx < 0 or idx >= _reserved.size():
		return true
	return _reserved[idx] != 0

func _draw_threshold() -> int:
	var seed: int = DetHash.djb2_64([str(_run_seed), "TRASH_TH", str(_floor), str(_encounter_cycle)])
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var th: int = rng.randi_range(th_min, th_max)
	_rng("draw TH (cycle=%d) -> %d (range %d..%d)" % [_encounter_cycle, th, th_min, th_max])
	return th

func _trigger_battle(cell: Vector2i, world_pos: Vector3) -> void:
	# Deterministic pick per encounter (use eligible_step_index as nonce)
	var pick: StringName = _pool_helper.weighted_pick_for_floor(_run_seed, _floor, _pool, _eligible_step_index)

	# Power Level (floor-only, random each encounter)
	var power_level: int = SetPowerLevel.roll_power_level(_floor)

	var payload := {
		"floor": _floor, "triad_id": _triad_id,
		"step_index": _eligible_step_index, "cell": cell, "world_pos": world_pos,
		"em_value": _em, "threshold": _th, "pool": _pool,
		"enemy": pick, "monster_id": pick, "role": "trash",
		"run_seed": _run_seed,
		"power_level": power_level,
	}
	
	print("[Encounter][test] payload=", payload)
	print("[Encounter][test] Rolled power_level=", power_level, " (floor=", _floor, ")")

	_rng("TRIGGER @ step=%d cell=%s pos=%s pick=%s em>=th (%d>=%d) power=%d"
		% [_eligible_step_index, str(cell), str(world_pos), String(pick), _em, _th, power_level])

	if not route_rng_to_battle:
		print("[Encounter][SimOnly] payload=", payload)
		print("[Encounter][SimOnly] Rolled power_level=", power_level, " (floor=", _floor, ")")
		_battle_pending = false
		return

	if _encounter_active or _battle_pending or get_tree().paused:
		return

	_battle_pending = true
	if _router != null and _router.has_method("request_encounter"):
		_router.call("request_encounter", payload, _player)
	else:
		print("[Battle] (router missing) ", payload)
		_battle_pending = false

func _on_router_requested(_payload: Dictionary) -> void:
	_battle_pending = false
	_encounter_active = true
	_rng("router: encounter_requested → pending=false, active=true")

func _on_router_finished(result: Dictionary) -> void:
	_encounter_active = false
	_battle_pending = false
	_rng("router: encounter_finished → result=%s; active=false, pending=false" % [str(result)])

func register_player(p: Node3D) -> void:
	_player = p

func _rng(msg: String) -> void:
	if debug_rng:
		print("[RNG] ", msg)
