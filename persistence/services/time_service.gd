# res://persistence/services/time_service.gd
extends RefCounted
class_name TimeService
## Deterministic per-floor time accrual for dungeon steps (RUN).
## Real-time accumulation persisted directly to META (counts while app is closed).

# ---- Tuning (deterministic) -------------------------------------------------
# T_cap = baseline_min + k_area * (area_ratio ^ p) + k_rooms * room_incs [+ boss spice]
const baseline_min: float = 10.0
const k_area: float       = 4.5
const p: float            = 0.60
const k_rooms: float      = 3.0

# E_steps = k_steps * (w*h)^q + k_inc * room_incs
const k_steps: float      = 0.80
const q: float            = 0.85
const k_inc: float        = 6.0

# Optional boss spice (multiples of 3 by default)
const boss_every: int       = 3
const boss_bonus_min: float = 2.0

# ---- Slot resolver ----------------------------------------------------------
static func _slot(s: int) -> int:
	return (s if s > 0 else SaveManager.active_slot())

# ---- Public API: Real-world elapsed time (META-based) -----------------------
## Apply real-world elapsed time to META.time_passed_min based on a persistent anchor timestamp.
## Call once on app boot and optionally on a slow heartbeat (e.g., every 30–60s).
## Returns minutes added on this call.
static func realtime_boot_apply(slot: int = 0, max_backfill_days: int = 14) -> float:
	slot = _slot(slot)

	var now_ts: int = Time.get_unix_time_from_system()
	var meta: Dictionary = SaveManager.load_game(slot)  # META

	var last_ts: int = int(_dgeti(meta, "wall_last_ts", 0))
	var added_min: float = 0.0

	if last_ts > 0 and now_ts > last_ts:
		var delta_sec: int = now_ts - last_ts
		# Cap large gaps to avoid huge jumps from long absences or clock manipulation.
		var max_sec: int = max_backfill_days * 24 * 60 * 60
		if delta_sec > max_sec:
			delta_sec = max_sec
		added_min = float(delta_sec) / 60.0
		_meta_add_minutes(meta, added_min)

	# Always refresh the anchor to "now" (handles first boot or clock going backward)
	meta["wall_last_ts"] = now_ts
	meta["updated_at"] = now_ts
	SaveManager.save_game(meta, slot)
	return added_min

## Optional runtime heartbeat: keeps META fresh during long sessions.
## Returns minutes added on this call (may be 0.0).
static func realtime_heartbeat(slot: int = 0, max_backfill_days: int = 14) -> float:
	return realtime_boot_apply(slot, max_backfill_days)

## Snapshot for UI without writing: returns totals including live (unapplied) elapsed since anchor.
static func realtime_snapshot(slot: int = 0) -> Dictionary:
	slot = _slot(slot)

	var meta: Dictionary = SaveManager.load_game(slot)
	var last_ts: int = int(_dgeti(meta, "wall_last_ts", 0))
	var now_ts: int = Time.get_unix_time_from_system()
	var base_min: float = float(_dgetf(meta, "time_passed_min", 0.0))

	var live_min: float = 0.0
	if last_ts > 0 and now_ts > last_ts:
		live_min = float(now_ts - last_ts) / 60.0

	return {
		"meta_total_min": base_min,
		"unapplied_live_min": live_min,
		"combined_min": base_min + live_min
	}

# ---- Public API: Deterministic per-floor accrual (RUN) ----------------------
static func begin_floor(
		bw: int, bh: int,
		w: int, h: int,
		rooms_inc_every: int,
		floor_index: int,
		entry_bonus_min: float = 0.0,
		slot: int = 0
	) -> Dictionary:
	slot = _slot(slot)

	# Compute room increments the same way LevelManager does.
	var base_dim: int = max(bw, bh)
	var max_dim: int = max(w, h)
	var room_incs: int = 0
	if rooms_inc_every > 0 and max_dim > base_dim:
		room_incs = int(floor(float(max_dim - base_dim) / float(rooms_inc_every)))

	# Area ratio vs. baseline
	var bwbh: int = max(1, bw * bh)
	var area_ratio: float = float(w * h) / float(bwbh)

	# Per-floor cap (minutes)
	var cap: float = baseline_min + k_area * pow(area_ratio, p) + k_rooms * float(room_incs)
	if boss_every > 0 and floor_index > 0:
		if (floor_index % boss_every) == 0:
			cap += boss_bonus_min

	# Expected steps, clamped
	var steps_exp: float = k_steps * pow(float(w * h), q) + k_inc * float(room_incs)
	if steps_exp < 1.0:
		steps_exp = 1.0

	var step_value: float = cap / steps_exp

	# Persist into RUN (lazy defaults; no schema edit required)
	var run: Dictionary = SaveManager.load_run(slot)
	# Mirrors (for UI/telemetry if desired)
	run["last_floor_T_cap_min"] = cap
	run["last_floor_E_steps"] = steps_exp
	run["last_floor_step_value_min"] = step_value
	# Accumulators (initialize if missing)
	var a0: float = float(_dgetf(run, "floor_time_accum_min", 0.0))
	var total0: float = float(_dgetf(run, "run_time_total_min", 0.0))
	# Optional entry bonus goes into the floor accumulator, clamped
	var bonus: float = max(0.0, entry_bonus_min)
	var a1: float = min(cap, a0 + bonus)
	run["floor_time_accum_min"] = a1
	run["run_time_total_min"] = total0
	# Update timestamp and save
	run["updated_at"] = Time.get_unix_time_from_system()
	SaveManager.save_run(run, slot)

	return {
		"T_cap_min": cap,
		"E_steps": steps_exp,
		"step_value_min": step_value,
		"room_incs": room_incs,
		"area_ratio": area_ratio
	}

static func on_step(is_in_battle: bool, slot: int = 0) -> void:
	slot = _slot(slot)

	# Do not accrue during battles.
	if is_in_battle:
		return
	var run: Dictionary = SaveManager.load_run(slot)
	var cap: float = float(_dgetf(run, "last_floor_T_cap_min", 0.0))
	var a: float = float(_dgetf(run, "floor_time_accum_min", 0.0))
	var v: float = float(_dgetf(run, "last_floor_step_value_min", 0.0))
	if cap <= 0.0 or v <= 0.0:
		# Nothing configured for this floor; ignore.
		return
	a = min(cap, a + v)
	run["floor_time_accum_min"] = a
	run["updated_at"] = Time.get_unix_time_from_system()
	SaveManager.save_run(run, slot)

## Banks the current floor accumulator into run total and resets the floor accumulator.
## Returns the amount that was moved from floor -> total on this call.
static func commit_and_reset(slot: int = 0) -> float:
	slot = _slot(slot)

	var run: Dictionary = SaveManager.load_run(slot)
	var a: float = float(_dgetf(run, "floor_time_accum_min", 0.0))
	var total: float = float(_dgetf(run, "run_time_total_min", 0.0))
	total += a
	run["run_time_total_min"] = total
	run["floor_time_accum_min"] = 0.0
	run["updated_at"] = Time.get_unix_time_from_system()
	SaveManager.save_run(run, slot)
	return a

## Convenience: read the live RUN numbers for UI/telemetry.
static func snapshot(slot: int = 0) -> Dictionary:
	slot = _slot(slot)

	var run: Dictionary = SaveManager.load_run(slot)
	return {
		"run_time_total_min": float(_dgetf(run, "run_time_total_min", 0.0)),
		"floor_time_accum_min": float(_dgetf(run, "floor_time_accum_min", 0.0)),
		"last_floor_T_cap_min": float(_dgetf(run, "last_floor_T_cap_min", 0.0)),
		"last_floor_E_steps": float(_dgetf(run, "last_floor_E_steps", 0.0)),
		"last_floor_step_value_min": float(_dgetf(run, "last_floor_step_value_min", 0.0))
	}

# ---- Small helpers ----------------------------------------------------------
static func _meta_add_minutes(meta: Dictionary, add_min: float) -> void:
	var base: float = float(_dgetf(meta, "time_passed_min", 0.0))
	var addv: float = max(0.0, add_min)
	if addv <= 0.0:
		return
	meta["time_passed_min"] = base + addv

static func _dgetf(d: Dictionary, k: String, def: float) -> float:
	if not d.has(k):
		return def
	var v: Variant = d[k]
	if v is float:
		return float(v)
	if v is int:
		return float(v)
	if v is String:
		var s := String(v)
		if s.is_valid_float():
			return float(s.to_float())
	return def

static func _dgeti(d: Dictionary, k: String, def: int) -> int:
	if not d.has(k):
		return def
	var v: Variant = d[k]
	if v is int:
		return int(v)
	if v is float:
		return int(v)
	if v is String:
		var s := String(v)
		if s.is_valid_int():
			return int(s.to_int())
	return def
