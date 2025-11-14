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
@export var route_rng_to_battle: bool = true     # when false, SIM-ONLY: just prints payload
@export var rng_sim_only: bool = false           # kept for compatibility

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
var _pending_rewards: bool = false
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
	_pending_rewards = false
	_encounter_active = false
	_battle_pending = false

	print("[Encounter] Floor=", _floor, " triad=", _triad_id, " pool=", _pool, " boss=", _boss_id, " TH=", _th)
	_rng("start floor=%d triad=%d pool=%s boss=%s TH=%d"
		% [_floor, _triad_id, str(_pool), String(_boss_id), _th])

func is_busy() -> bool:
	# Used by spawners to avoid double-firing.
	return _encounter_active or _battle_pending or _pending_rewards or get_tree().paused

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

# Manual trigger from Elite/Boss spawners. Reuses existing in-world visual.
func request_manual_encounter_with_visual(monster_id: StringName, role: String, visual: Node3D) -> void:
	if is_busy():
		return
	var power_level: int = SetPowerLevel.roll_power_level(_floor)
	var payload := {
		"floor": _floor,
		"triad_id": _triad_id,
		"cell": Vector2i(-1, -1),
		"world_pos": visual.global_transform.origin if visual else Vector3.ZERO,
		"em_value": 0,
		"threshold": _th,
		"pool": _pool,
		"enemy": monster_id,
		"monster_id": monster_id,
		"role": role,                     # "elite" or "boss"
		"run_seed": _run_seed,
		"power_level": power_level,
		"existing_visual": visual,        # <-- important: reuse placed mesh
	}
	_rng("MANUAL ENCOUNTER role=%s monster=%s power=%d" % [role, String(monster_id), power_level])
	_fire_payload(payload)

# Called by the player's StepStepper on new cell
func on_step(cell: Vector2i, world_pos: Vector3) -> void:
	if get_tree().paused or _encounter_active or _battle_pending or _pending_rewards:
		if debug_rng_suppression:
			_rng("skip step: paused=%s active=%s pending=%s rewards=%s" %
				[str(get_tree().paused), str(_encounter_active), str(_battle_pending), str(_pending_rewards)])
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
	_rng("TRIGGER @ step=%d cell=%s pos=%s pick=%s em>=th (%d>=%d) power=%d"
		% [_eligible_step_index, str(cell), str(world_pos), String(pick), _em, _th, power_level])

	_fire_payload(payload)

func _fire_payload(payload: Dictionary) -> void:
	if not route_rng_to_battle:
		print("[Encounter][SimOnly] payload=", payload)
		_battle_pending = false
		return
	if _encounter_active or _battle_pending or get_tree().paused or _pending_rewards:
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
	# BattleLoader finished; keep RNG blocked until rewards close.
	_encounter_active = false
	_battle_pending = false
	_pending_rewards = true
	_rng("router: encounter_finished → result=%s; awaiting rewards" % [str(result)])

	# ----- commit/discard ability XP by encounter outcome -----
	var enc_id: int = int(result.get("encounter_id", 0))
	var out_s: String = String(result.get("outcome",""))
	var AbilityXPService := preload("res://persistence/services/ability_xp_service.gd")
	var skill_xp_list: Array = []
	if enc_id > 0:
		if out_s == "victory":
		# --- Build victory context for the new API ---
		# Player level from RUN
			var p_level: int = 1
			var rs: Dictionary = SaveManager.load_run()
			if rs is Dictionary:
				var sb: Dictionary = (rs.get("player_stat_block", {}) as Dictionary)
				p_level = int(sb.get("level", 1))

			# Map role string -> int code (XpTuning.Role: TRASH=0, ELITE=1, BOSS=2)
			var role_str := String(result.get("role", "trash")).to_lower()
			var role_code: int = 0
			if role_str == "elite":
				role_code = 1
			elif role_str == "boss":
				role_code = 2

			# Monster level from the BattleLoader-enriched result
			var m_level: int = max(1, int(result.get("monster_level", 1)))

			var victory_ctx := {
				"player_level": p_level,
				"allies_count": 1,  # when party/NPC allies join, divide char XP upstream; skill XP remains per-actor
				 "enemies": [ { "monster_level": m_level, "role": role_code } ]
			}

			# New signature: (encounter_id, victory_ctx, slot)
			skill_xp_list = AbilityXPService.commit_encounter(enc_id, victory_ctx, SaveManager.active_slot())
		else:
			AbilityXPService.discard_encounter(enc_id, SaveManager.active_slot())

	result["skill_xp"] = skill_xp_list


	# Present rewards (if the modal exists), then resume RNG + grace.
	var modal := get_node_or_null(^"/root/RewardsModal")
	if modal != null and modal.has_method("present") and modal.has_signal("closed"):
		modal.call("present", result)
		await modal.closed
	else:
		await get_tree().create_timer(0.25).timeout

	# Clean up defeated spawner if this was an elite/boss victory.
	_cleanup_defeated_spawner(result)

	_pending_rewards = false
	_post_grace_left = post_battle_grace_steps
	_rng("rewards closed → post_grace=%d" % [_post_grace_left])


func register_player(p: Node3D) -> void:
	_player = p

# -------- defeat cleanup (optional but handy) --------
func _cleanup_defeated_spawner(result: Dictionary) -> void:
	if String(result.get("outcome","")) != "victory":
		return
	var slug := String(result.get("monster_slug",""))
	if slug == "":
		return

	# Find nearest spawner that matches monster_id; then mark defeated.
	var best: Node3D = null
	var best_d2 := INF
	var player_pos := _player.global_transform.origin if _player else Vector3.ZERO

	# Prefer nodes in "encounter_spawner" group (if you used it)
	var candidates: Array = get_tree().get_nodes_in_group(&"encounter_spawner")
	if candidates.is_empty():
		# fallback: search whole tree for scripts that expose monster_id
		candidates = get_tree().get_root().find_children("*", "Node3D", true, false)

	for n in candidates:
		if not (n is Node3D):
			continue
		var ok := false
		if n.has_method("get"):
			var mid: String = ""
			if n.has_method("get_monster_id"):
				mid = _coerce_slug(n.call("get_monster_id"))
			elif n.has_method("get") and n.has_method("set"):
				# try reading exported var
				var v: Variant = n.get("monster_id")
				mid = _coerce_slug(v)

			ok = (mid == slug)
		if not ok:
			continue
		var d2: float = (n.global_transform.origin - player_pos).length_squared()
		if d2 < best_d2:
			best_d2 = d2
			best = n

	if best and best.has_method("mark_defeated_and_cleanup"):
		best.call("mark_defeated_and_cleanup")

# ---------------- utils ----------------
func _rng(msg: String) -> void:
	if debug_rng:
		print("[RNG] ", msg)
		
static func _coerce_slug(v: Variant) -> String:
	if v is String:
		return v
	if v is StringName:
		return String(v as StringName)
	# Fallback: safe textual representation
	return str(v)
