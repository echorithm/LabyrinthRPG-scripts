extends Node

const DEFAULT_SLOT: int = 1

const _S         := preload("res://persistence/util/save_utils.gd")
const _Meta      := preload("res://persistence/schemas/meta_schema.gd")
const _RunSchema := preload("res://persistence/schemas/run_schema.gd")
const _ExitFlow  := preload("res://persistence/flows/ExitSafelyFlow.gd")
const _DefeatFlow:= preload("res://persistence/flows/DefeatFlow.gd")
const _Derived   := preload("res://scripts/combat/derive/DerivedCalc.gd")
const _XpTuning  := preload("res://scripts/rewards/XpTuning.gd")
const _Prog      := preload("res://persistence/services/progression_service.gd")
const _VillageSave := preload("res://scripts/village/persistence/village_save_utils.gd")

# ---------------- Debug ------------------------------------------------------
static var DEBUG: bool = false

# NEW: guard to break phase-check recursion safely
static var _PHASE_REENTRANT: bool = false

static func set_debug(on: bool) -> void:
	DEBUG = on
	print("[SaveManager] DEBUG = ", on)

static func _dbg(kind: String, slot: int, data: Dictionary = {}) -> void:
	if not DEBUG:
		return
	var payload: String = ("" if data.is_empty() else (" " + JSON.stringify(data)))
	print("[%s][SaveManager.%s] slot=%d%s" % [_ts(), kind, slot, payload])

static func _ensure_dir() -> void:
	# Ensure saves directory exists (log only when created).
	if not DirAccess.dir_exists_absolute("user://saves"):
		var ok: int = DirAccess.make_dir_recursive_absolute("user://saves")
		if DEBUG:
			print("[%s][SaveManager.mkdir] dir=user://saves ok=%s" % [_ts(), str(ok == OK)])

static func _log_open(path: String, mode: String, slot: int, ok: bool) -> void:
	_dbg("open", slot, {"path": path, "mode": mode, "ok": ok})

static func _log_write(path: String, slot: int, bytes: int, keys: int = -1) -> void:
	var d: Dictionary = {"path": path, "bytes": bytes}
	if keys >= 0:
		d["keys"] = keys
	_dbg("write", slot, d)

static func _log_remove(path: String, slot: int, ok: bool) -> void:
	_dbg("remove", slot, {"path": path, "ok": ok})

# ------------ Phase / slot policy -------------------------------------------
static func _in_menu_phase() -> bool:
	# Re-entrancy guard: if a phase check triggers a nested phase check (e.g., via UI that
	# touches SaveManager), conservatively return MENU to avoid recursion.
	if _PHASE_REENTRANT:
		return true

	_PHASE_REENTRANT = true
	var result: bool = true

	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree != null:
		# Prefer a passive meta flag if present (no callbacks into gameplay code).
		if tree.has_meta("in_menu"):
			var mv: Variant = tree.get_meta("in_menu")
			if typeof(mv) == TYPE_BOOL:
				result = bool(mv)
		else:
			var root: Node = tree.get_root()
			var ap: Node = (root.get_node_or_null("AppPhase") if root != null else null)
			if ap != null and ap.has_method("in_menu"):
				var v: Variant = ap.call("in_menu")
				if typeof(v) == TYPE_BOOL:
					result = bool(v)

	_PHASE_REENTRANT = false
	return result

static func _slot_from_tree_or_default() -> int:
	var s: int = DEFAULT_SLOT
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree != null and tree.has_meta("current_slot"):
		var v: Variant = tree.get_meta("current_slot")
		if typeof(v) == TYPE_INT:
			s = max(1, int(v))
	return s

static func _slot_for_read(slot: int) -> int:
	return (slot if slot > 0 else _slot_from_tree_or_default())

static func _slot_for_write(slot: int) -> int:
	# In MENU: honor explicit slot (menu tools), in GAME: use active slot.
	return (_slot_for_read(slot) if _in_menu_phase() else _slot_from_tree_or_default())

# ------------ Storage paths --------------------------------------------------
static func _meta_path(slot: int) -> String:
	return "user://saves/slot_%d_meta.json" % int(slot)

static func _run_path(slot: int) -> String:
	return "user://saves/slot_%d_run.json" % int(slot)

# ------------ Active slot resolver (legacy, kept for compat) -----------------
static func _active_slot(slot: int) -> int:
	if slot > 0:
		if DEBUG:
			print("[%s][SaveManager.slot] arg=%d -> slot=%d" % [_ts(), slot, slot])
		return slot
	var s: int = _slot_from_tree_or_default()
	if DEBUG:
		print("[%s][SaveManager.slot] resolved=%d (tree.meta current_slot)" % [_ts(), s])
	return s

# ------------ Activation + touch (timestamps) --------------------------------
static func set_active_slot(slot: int = DEFAULT_SLOT) -> void:
	var s: int = max(1, slot)
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree != null:
		tree.set_meta("current_slot", s)
	_dbg("set_active_slot", s)

static func touch_slot(slot: int = DEFAULT_SLOT) -> void:
	var s: int = max(1, slot)
	var ts_now: float = float(_S.now_ts())

	var mp: String = _meta_path(s)
	if FileAccess.file_exists(mp):
		var gs: Dictionary = read_game_if_exists(s)
		gs["updated_at"] = ts_now
		save_game(gs, s)

	var rp: String = _run_path(s)
	if FileAccess.file_exists(rp):
		var rs: Dictionary = read_run_if_exists(s)
		rs["updated_at"] = ts_now
		save_run(rs, s)

static func activate_slot(slot: int = DEFAULT_SLOT) -> int:
	var s: int = max(1, slot)
	set_active_slot(s)
	_dbg("activate_slot", s)
	return s

static func activate_and_touch(slot: int = DEFAULT_SLOT) -> int:
	var s: int = activate_slot(slot)
	touch_slot(s)
	return s

# ------------ Presence / debug ----------------------------------------------
static func debug_print_presence(slot: int = DEFAULT_SLOT) -> void:
	slot = _slot_for_read(slot)
	var mp: String = _meta_path(slot)
	var rp: String = _run_path(slot)
	var has_meta: bool = FileAccess.file_exists(mp)
	var has_run: bool = FileAccess.file_exists(rp)
	print("[SaveManager] presence: slot=%d meta=%s (%s) run=%s (%s)" %
		[slot, str(has_meta), mp, str(has_run), rp])

# ------------ Basic IO -------------------------------------------------------
static func load_game(slot: int = DEFAULT_SLOT) -> Dictionary:
	# Writer semantics (migrates/creates) — but never create in MENU.
	slot = _slot_for_write(slot)
	var p: String = _meta_path(slot)
	if not FileAccess.file_exists(p):
		if _in_menu_phase():
			_dbg("load_game_miss_menu_defaults", slot, {"path": p})
			return _Meta.defaults()  # DO NOT save while in MENU
		print("[%s][SaveManager.load_game] MISS -> creating defaults slot=%d path=%s" % [_ts(), slot, p])
		var d_new: Dictionary = _Meta.defaults()
		save_game_allow_create(d_new, slot)
		return d_new
	var f: FileAccess = FileAccess.open(p, FileAccess.READ)
	_log_open(p, "READ", slot, f != null)
	if f == null:
		_dbg("load_game_fallback_defaults", slot, {"path": p})
		return _Meta.defaults()
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	var d2: Dictionary = _S.to_dict(parsed)
	var before_keys: int = d2.size()
	var mig: Dictionary = _Meta.migrate(d2)
	if mig != d2:
		_dbg("migrate_meta", slot, {"path": p, "from_keys": before_keys, "to_keys": mig.size()})
		save_game(mig, slot) # persist migrations so new tracks stick
	else:
		_dbg("load_game_hit", slot, {"path": p, "keys": before_keys})
	return mig

static func save_game(d_in: Dictionary, slot: int = DEFAULT_SLOT) -> void:
	slot = _slot_for_write(slot)
	var d: Dictionary = d_in.duplicate(true)
	d["updated_at"] = Time.get_unix_time_from_system()
	var p: String = _meta_path(slot)

	# Suppress accidental creation while in MENU.
	if _in_menu_phase() and not FileAccess.file_exists(p):
		_dbg("save_game.suppressed_menu_no_file", slot, {"path": p})
		return

	_ensure_dir()
	var f: FileAccess = FileAccess.open(p, FileAccess.WRITE)
	_log_open(p, "WRITE", slot, f != null)
	if f:
		var txt: String = JSON.stringify(d, "\t")
		f.store_string(txt)
		_log_write(p, slot, txt.length(), d.size())

# Explicit: write even if the file doesn't exist and even if we're in MENU.
static func save_game_allow_create(d_in: Dictionary, slot: int = DEFAULT_SLOT) -> void:
	slot = _slot_for_write(slot)
	var d: Dictionary = d_in.duplicate(true)
	d["updated_at"] = Time.get_unix_time_from_system()
	var p: String = _meta_path(slot)
	_ensure_dir()
	var f: FileAccess = FileAccess.open(p, FileAccess.WRITE)
	_log_open(p, "WRITE", slot, f != null)
	if f:
		var txt: String = JSON.stringify(d, "\t")
		f.store_string(txt)
		_log_write(p, slot, txt.length(), d.size())

static func load_run(slot: int = DEFAULT_SLOT) -> Dictionary:
	# Writer semantics (mirror/create) — but never create in MENU.
	slot = _slot_for_write(slot)
	var p: String = _run_path(slot)
	if not FileAccess.file_exists(p):
		if _in_menu_phase():
			_dbg("load_run_miss_menu_empty", slot, {"path": p})
			return {}  # DO NOT create while in MENU
		_dbg("load_run_miss", slot, {"path": p})
		var meta: Dictionary = load_game(slot)
		var fresh: Dictionary = _mirror_meta_to_new_run(meta)
		save_run_allow_create(fresh, slot)
		return fresh
	var f: FileAccess = FileAccess.open(p, FileAccess.READ)
	_log_open(p, "READ", slot, f != null)
	if f == null:
		_dbg("load_run_read_fail_new", slot, {"path": p})
		var meta2: Dictionary = load_game(slot)
		var fresh2: Dictionary = _mirror_meta_to_new_run(meta2)
		save_run_allow_create(fresh2, slot)
		return fresh2
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	var d0: Dictionary = _S.to_dict(parsed)
	# CHANGED: read schema from META non-creating path to avoid nested writer calls.
	var pre_ver: int = int(_S.dget(read_game_if_exists(slot), "schema_version", 1))
	var out: Dictionary = _RunSchema.migrate(d0, pre_ver)
	if out != d0:
		_dbg("migrate_run", slot, {"path": p, "from_keys": d0.size(), "to_keys": out.size(), "meta_schema": pre_ver})
	else:
		_dbg("load_run_hit", slot, {"path": p, "keys": out.size()})
	return out

static func save_run(d_in: Dictionary, slot: int = DEFAULT_SLOT) -> void:
	slot = _slot_for_write(slot)
	var d: Dictionary = d_in.duplicate(true)
	d["updated_at"] = Time.get_unix_time_from_system()
	var p: String = _run_path(slot)

	# Suppress accidental creation while in MENU.
	if _in_menu_phase() and not FileAccess.file_exists(p):
		_dbg("save_run.suppressed_menu_no_file", slot, {"path": p})
		return

	_ensure_dir()
	var f: FileAccess = FileAccess.open(p, FileAccess.WRITE)
	_log_open(p, "WRITE", slot, f != null)
	if f:
		var txt: String = JSON.stringify(d, "\t")
		f.store_string(txt)
		_log_write(p, slot, txt.length(), d.size())

# Explicit: write even if the file doesn't exist and even if we're in MENU.
static func save_run_allow_create(d_in: Dictionary, slot: int = DEFAULT_SLOT) -> void:
	slot = _slot_for_write(slot)
	var d: Dictionary = d_in.duplicate(true)
	d["updated_at"] = Time.get_unix_time_from_system()
	var p: String = _run_path(slot)
	_ensure_dir()
	var f: FileAccess = FileAccess.open(p, FileAccess.WRITE)
	_log_open(p, "WRITE", slot, f != null)
	if f:
		var txt: String = JSON.stringify(d, "\t")
		f.store_string(txt)
		_log_write(p, slot, txt.length(), d.size())

static func delete_run(slot: int = DEFAULT_SLOT) -> void:
	slot = _slot_for_write(slot)
	var p: String = _run_path(slot)
	if FileAccess.file_exists(p):
		var rc: int = DirAccess.remove_absolute(p)
		_log_remove(p, slot, rc == OK)

# ------------ Small helpers used around codebase -----------------------------
static func run_exists(slot: int = DEFAULT_SLOT) -> bool:
	slot = _slot_for_read(slot)
	var ok: bool = FileAccess.file_exists(_run_path(slot))
	_dbg("run_exists", slot, {"ok": ok})
	return ok

# CHANGED: read-only path; safe for UI/menu.
static func peek_run_depth(slot: int = DEFAULT_SLOT) -> int:
	slot = _slot_for_read(slot)
	var rs: Dictionary = read_run_if_exists(slot)
	return int(_S.dget(rs, "depth", 1))

# CHANGED: read-only path; safe for UI/menu.
static func get_current_floor(slot: int = DEFAULT_SLOT) -> int:
	slot = _slot_for_read(slot)
	var gs: Dictionary = read_game_if_exists(slot)
	return int(_S.dget(gs, "current_floor", 1))

static func set_run_floor(depth: int, slot: int = DEFAULT_SLOT) -> void:
	slot = _slot_for_write(slot)
	var rs: Dictionary = load_run(slot)
	var before: int = int(_S.dget(rs, "depth", 1))
	rs["depth"] = int(depth)
	var far: int = int(_S.dget(rs, "furthest_depth_reached", int(depth)))
	if depth > far:
		rs["furthest_depth_reached"] = depth
	_dbg("set_run_floor", slot, {"from": before, "to": depth, "furthest": int(rs["furthest_depth_reached"])})
	save_run(rs, slot)

# CHANGED: read-only path; safe to call from menus.
static func get_run_seed(slot: int = DEFAULT_SLOT) -> int:
	slot = _slot_for_read(slot)
	var rs: Dictionary = read_run_if_exists(slot)
	var seed_i: int = int(_S.dget(rs, "run_seed", 0))
	_dbg("get_run_seed", slot, {"seed": seed_i})
	return seed_i

static func ensure_sigil_segment_for_floor(_floor: int, _segment_size: int) -> void:
	var floor: int = max(1, _floor)
	var SigilMath := preload("res://persistence/services/sigil_math.gd")
	var Sigils := preload("res://persistence/services/sigils_service.gd")
	var required: int = SigilMath.required_for_floor(floor)
	_dbg("sigil.ensure_segment", _slot_from_tree_or_default(), {"floor": floor, "required": required})
	Sigils.ensure_segment_for_floor(floor, required, _slot_from_tree_or_default())

# ------------ Public flows ---------------------------------------------------
static func commit_run_to_meta(safe_exit: bool, slot: int = DEFAULT_SLOT) -> void:
	slot = _slot_for_write(slot)
	_dbg("commit_run_to_meta", slot, {"safe_exit": safe_exit})
	if safe_exit:
		_ExitFlow.execute(slot)
	else:
		_DefeatFlow.execute(slot)

static func exit_safely(slot: int = DEFAULT_SLOT) -> void:
	slot = _slot_for_write(slot)
	_dbg("exit_safely", slot)
	_ExitFlow.execute(slot)

static func end_run_defeat(slot: int = DEFAULT_SLOT) -> void:
	slot = _slot_for_write(slot)
	_dbg("end_run_defeat", slot)
	_DefeatFlow.execute(slot)

static func start_or_refresh_run_from_meta(slot: int = DEFAULT_SLOT) -> Dictionary:
	slot = _slot_for_write(slot)
	_dbg("start_or_refresh_run_from_meta.begin", slot)

	var meta: Dictionary = load_game(slot)
	var merged: Dictionary = _mirror_meta_to_new_run(meta)

	# Lock the run's difficulty code from META at start.
	var diff_code: String = get_difficulty_code(slot)
	merged["difficulty_code"] = diff_code

	# Recompute all RUN thresholds to match the locked code.
	merged = _recompute_run_thresholds_for_code(merged, diff_code)

	save_run_allow_create(merged, slot)
	_dbg("start_or_refresh_run_from_meta.done", slot, {"keys": merged.size()})
	return merged

# ------------ Character XP IN RUN (used by rewards) --------------------------
static func run_award_character_xp(amount: int, slot: int = DEFAULT_SLOT) -> Dictionary:
	slot = _slot_for_write(slot)
	var add: int = max(0, amount)
	if add <= 0:
		_dbg("run_award_character_xp.skip", slot, {"amount": amount})
		return { "level": 0, "xp_current": 0, "xp_needed": 0, "points_added": 0, "points_unspent": int(_S.dget(load_run(slot), "points_unspent", 0)) }

	var rs: Dictionary = load_run(slot)
	var sb: Dictionary = _S.to_dict(_S.dget(rs, "player_stat_block", {}))

	var lvl: int = int(_S.dget(sb, "level", 1))
	var cur: int = int(_S.dget(sb, "xp_current", 0))
	var need: int = int(_S.dget(sb, "xp_needed", _Prog.xp_to_next(lvl)))

	var before := {"lvl": lvl, "cur": cur, "need": need}
	var levels_gained: int = 0
	cur += add
	while cur >= need:
		cur -= need
		lvl += 1
		levels_gained += 1
		need = _Prog.xp_to_next(lvl)

	sb["level"] = lvl
	sb["xp_current"] = cur
	sb["xp_needed"]  = need
	rs["player_stat_block"] = sb

	var prev_points: int = int(_S.dget(rs, "points_unspent", 0))
	var points_gain: int = levels_gained * 2
	rs["points_unspent"] = prev_points + points_gain

	save_run(rs, slot)
	_dbg("run_award_character_xp", slot, {"amount": add, "before": before, "after": {"lvl": lvl, "cur": cur, "need": need}, "levels": levels_gained, "points_add": points_gain, "points_unspent": int(rs["points_unspent"])})

	return {
		"level": lvl,
		"xp_current": cur,
		"xp_needed": need,
		"points_added": points_gain,
		"points_unspent": int(rs["points_unspent"])
	}

# ---------------- Skill XP IN RUN (used by ability xp + loot) ----------------
static func apply_skill_xp_to_run(ability_id: String, add_xp: int, slot: int = DEFAULT_SLOT) -> Dictionary:
	slot = _slot_for_write(slot)
	var aid: String = String(ability_id)
	if aid.is_empty() or add_xp <= 0:
		_dbg("apply_skill_xp_to_run.skip", slot, {"aid": aid, "add": add_xp})
		return {}

	var rs: Dictionary = load_run(slot)
	var st_all: Dictionary = _S.to_dict(_S.dget(rs, "skill_tracks", {}))
	var row: Dictionary = _S.to_dict(_S.dget(st_all, aid, {}))
	var created_from_meta: bool = false

	# Backfill from META snapshot if missing
	if row.is_empty():
		var gs: Dictionary = load_game(slot)
		var pl: Dictionary = _S.to_dict(_S.dget(gs, "player", {}))
		var mt_all: Dictionary = _S.to_dict(_S.dget(pl, "skill_tracks", {}))
		var mrow: Dictionary = _S.to_dict(_S.dget(mt_all, aid, {}))
		if mrow.is_empty():
			mrow = {
				"level": 1, "xp_current": 0, "xp_needed": _Prog.xp_to_next(1),
				"cap_band": 10, "unlocked": false, "last_milestone_applied": 0
			}
		row = mrow.duplicate(true)
		created_from_meta = true

	# Always normalize threshold using the RUN difficulty (via ProgressionService.xp_to_next).
	var lvl: int = int(_S.dget(row, "level", 1))
	row["xp_needed"] = _Prog.xp_to_next(lvl)

	var cur: int = int(_S.dget(row, "xp_current", 0))
	var need: int = int(_S.dget(row, "xp_needed", _Prog.xp_to_next(lvl)))
	var cap: int = int(_S.dget(row, "cap_band", 10))
	var unlocked: bool = bool(_S.dget(row, "unlocked", false))
	var last_ms: int = int(_S.dget(row, "last_milestone_applied", 0))

	if (not unlocked) or (lvl >= cap):
		st_all[aid] = row
		rs["skill_tracks"] = st_all
		save_run(rs, slot)
		_dbg("apply_skill_xp_to_run.blocked", slot, {"aid": aid, "unlocked": unlocked, "lvl": lvl, "cap": cap})
		return row.duplicate(true)

	var before := {"lvl": lvl, "cur": cur, "need": need}
	cur += max(0, add_xp)

	var attrs: Dictionary = _S.to_dict(_S.dget(rs, "player_attributes", {}))
	var attrs_changed: bool = false

	while (lvl < cap) and (cur >= need):
		cur -= need
		lvl += 1
		need = _Prog.xp_to_next(lvl)
		if (lvl % 5 == 0) and (lvl > last_ms):
			var bias: Dictionary = _Prog._stat_bias_for(aid)
			var sum_applied: int = 0
			for k_any in bias.keys():
				var k: String = String(k_any)
				var add_i: int = int(bias[k_any])
				if add_i != 0:
					attrs[k] = int(_S.dget(attrs, k, 0)) + add_i
					sum_applied += add_i
			if sum_applied != 0:
				attrs_changed = true
			last_ms = lvl
			_dbg("apply_skill_xp_to_run.milestone", slot, {"aid": aid, "lvl": lvl, "bias": bias})

	if attrs_changed:
		rs["player_attributes"] = attrs
		var hp_max: int = int(_Derived.hp_max(attrs, {}))
		var mp_max: int = int(_Derived.mp_max(attrs, {}))
		var stam_max: int = int(_Derived.stam_max(attrs, {}))
		rs["hp_max"] = hp_max; rs["mp_max"] = mp_max; rs["stam_max"] = stam_max
		rs["hp"] = clampi(int(_S.dget(rs, "hp", 0)), 0, hp_max)
		rs["mp"] = clampi(int(_S.dget(rs, "mp", 0)), 0, mp_max)
		rs["stam"] = clampi(int(_S.dget(rs, "stam", 0)), 0, stam_max)

	row["level"] = lvl
	row["xp_current"] = cur
	row["xp_needed"] = need
	row["last_milestone_applied"] = last_ms
	st_all[aid] = row
	rs["skill_tracks"] = st_all

	save_run(rs, slot)
	_dbg("apply_skill_xp_to_run", slot, {"aid": aid, "add": add_xp, "created_from_meta": created_from_meta, "before": before, "after": {"lvl": lvl, "cur": cur, "need": need}, "attrs_changed": attrs_changed})
	return row.duplicate(true)

# ------------ Internals: build a new RUN from META ---------------------------
static func _mirror_meta_to_new_run(gs: Dictionary) -> Dictionary:
	var meta: Dictionary = _Meta.migrate(gs)

	var ts_now: int = _S.now_ts()
	var rs: Dictionary = {
		"schema_version": _RunSchema.LATEST_VERSION,
		"created_at": float(ts_now),
		"updated_at": ts_now,

		"depth": int(_S.dget(meta, "current_floor", 1)),
		"furthest_depth_reached": int(_S.dget(meta, "highest_floor_reached", 1)),
		"run_seed": _fresh_run_seed(),

		# Pools (we fill after attributes)
		"hp_max": 0, "hp": 0,
		"mp_max": 0, "mp": 0,
		"stam_max": 0, "stam": 0,

		# Currencies + carryables
		"gold": 0,
		"shards": 0,
		"inventory": [],
		"equipment": {
			"head": null, "chest": null, "legs": null, "boots": null,
			"sword": null, "spear": null, "mace": null, "bow": null,
			"ring1": null, "ring2": null, "amulet": null
		},
		"equipped_bank": {},
		"weapon_tags": [],

		"buffs": [], "effects": [],

		"player_stat_block": { "level": 1, "xp_current": 0, "xp_needed": 90 },
		"skill_tracks": {},

		"skill_xp_delta": {},
		"ability_use_counts": {},
		"ability_xp_pending": {},
		"action_skills": {},

		"points_unspent": int(_S.dget(_S.to_dict(_S.dget(meta, "player", {})), "points_unspent", 0)),
	}

	# --- META snapshots ---
	var pl_meta: Dictionary = _S.to_dict(_S.dget(meta, "player", {}))
	var sb_meta: Dictionary = _S.to_dict(_S.dget(pl_meta, "stat_block", {}))
	var attrs_meta: Dictionary = _S.to_dict(_S.dget(sb_meta, "attributes", {}))
	var lo_meta: Dictionary = _S.to_dict(_S.dget(pl_meta, "loadout", {}))
	var eq_meta: Dictionary = _S.to_dict(_S.dget(lo_meta, "equipment", {}))
	var tracks_meta: Dictionary = _S.to_dict(_S.dget(pl_meta, "skill_tracks", {}))

	# --- Attributes -> RUN + derived pools ---
	var attrs_run: Dictionary = {}
	for k in ["STR","AGI","DEX","END","INT","WIS","CHA","LCK"]:
		attrs_run[k] = int(_S.dget(attrs_meta, k, 8))
	rs["player_attributes"] = attrs_run
	rs["points_unspent"] = int(_S.dget(pl_meta, "points_unspent", 0))

	var hpM: int = int(_Derived.hp_max(attrs_run, {}))
	var mpM: int = int(_Derived.mp_max(attrs_run, {}))
	var stM: int = int(_Derived.stam_max(attrs_run, {}))
	rs["hp_max"] = hpM; rs["hp"] = hpM
	rs["mp_max"] = mpM; rs["mp"] = mpM
	rs["stam_max"] = stM; rs["stam"] = stM

	# --- On-hand currencies ---
	rs["gold"]   = int(_S.dget(pl_meta, "onhand_gold", 0))
	rs["shards"] = int(_S.dget(pl_meta, "onhand_shards", 0))

	# --- Inventory (deep copy; normalize numerics) ---
	var inv_src_any: Variant = _S.dget(pl_meta, "inventory", [])
	var inv_src: Array = (inv_src_any as Array) if inv_src_any is Array else []
	var inv_out: Array = []
	for it_any in inv_src:
		if it_any is Dictionary:
			var it: Dictionary = (it_any as Dictionary).duplicate(true)
			if it.has("count"): it["count"] = int(it["count"])
			if it.has("ilvl"): it["ilvl"] = int(it["ilvl"])
			if it.has("durability_max"): it["durability_max"] = int(it["durability_max"])
			if it.has("durability_current"): it["durability_current"] = int(it["durability_current"])
			if it.has("weight"): it["weight"] = float(it["weight"])
			if it.has("opts") and it["opts"] is Dictionary:
				var o: Dictionary = (it["opts"] as Dictionary)
				if o.has("ilvl"): o["ilvl"] = int(o["ilvl"])
				if o.has("durability_max"): o["durability_max"] = int(o["durability_max"])
				if o.has("durability_current"): o["durability_current"] = int(o["durability_current"])
				if o.has("weight"): o["weight"] = float(o["weight"])
				it["opts"] = o
			inv_out.append(it)

	# --- Equipment (META stores FULL ITEM DICTS) → RUN (uids + bank) ---
	var bank: Dictionary = {}
	var eq_run: Dictionary = rs["equipment"] as Dictionary
	var SLOT_ORDER: PackedStringArray = [
		"head","chest","legs","boots","sword","spear","mace","bow","ring1","ring2","amulet"
	]
	for s in SLOT_ORDER:
		var row_any: Variant = eq_meta.get(s, null)
		if not (row_any is Dictionary):
			eq_run[s] = null
			continue
		var row: Dictionary = (row_any as Dictionary).duplicate(true)
		var uid: String = String(_S.dget(row, "uid", ""))
		if uid.is_empty():
			var rng := RandomNumberGenerator.new()
			rng.randomize()
			var a: int = int(Time.get_ticks_usec()) & 0x7FFFFFFF
			var b: int = int(rng.randi() & 0x7FFFFFFF)
			uid = "u%08x%08x" % [a, b]
			row["uid"] = uid
		bank[uid] = row
		eq_run[s] = uid

	rs["equipped_bank"] = bank
	rs["equipment"] = eq_run

	# --- Stack the mirrored inventory (non-gear only) ---
	inv_out = _stack_inventory_local(inv_out)
	rs["inventory"] = inv_out

	# --- Character XP snapshot ---
	var lvl_i: int = int(_S.dget(sb_meta, "level", 1))
	rs["player_stat_block"] = {
		"level": lvl_i,
		"xp_current": int(_S.dget(sb_meta, "xp_current", 0)),
		"xp_needed": int(_S.dget(sb_meta, "xp_needed", _XpTuning.xp_to_next(lvl_i))),
	}

	# --- Skills mirror ---
	var st_out: Dictionary = {}
	for id_any in tracks_meta.keys():
		var rowm: Dictionary = _S.to_dict(tracks_meta[id_any])
		var rlvl: int = int(_S.dget(rowm, "level", 1))
		st_out[String(id_any)] = {
			"level": max(1, rlvl),
			"xp_current": int(_S.dget(rowm, "xp_current", 0)),
			"xp_needed": int(_S.dget(rowm, "xp_needed", _XpTuning.xp_to_next(rlvl))),
			"cap_band": int(_S.dget(rowm, "cap_band", 10)),
			"unlocked": bool(_S.dget(rowm, "unlocked", false)),
			"last_milestone_applied": int(_S.dget(rowm, "last_milestone_applied", 0))
		}
	rs["skill_tracks"] = st_out

	print("[%s][SaveManager.mirror] pools hp=%d/%d mp=%d/%d stam=%d/%d gold=%d shards=%d"
		% [_ts(), int(rs.get("hp",0)), int(rs.get("hp_max",0)),
		   int(rs.get("mp",0)), int(rs.get("mp_max",0)),
		   int(rs.get("stam",0)), int(rs.get("stam_max",0)),
		   int(rs.get("gold",0)), int(rs.get("shards",0))])

	_dbg("mirror_summary", _slot_from_tree_or_default(), {
		"attrs": attrs_run,
		"inv_count": inv_out.size(),
		"bank_count": bank.size(),
		"equip_keys": (rs["equipment"] as Dictionary).keys().size(),
		"tracks": st_out.size()
	})

	return rs

# --- local helper used only during META→RUN mirror ---
static func _stack_inventory_local(inv_in: Array) -> Array:
	var is_gear_local: Callable = func(it: Dictionary) -> bool:
		var dmax: int = int(it.get("durability_max", 0))
		if it.has("opts") and it["opts"] is Dictionary:
			dmax = max(dmax, int((it["opts"] as Dictionary).get("durability_max", 0)))
		return dmax > 0

	var stack_key_local: Callable = func(it: Dictionary) -> String:
		if is_gear_local.call(it):
			return ""
		var id_str: String = String(it.get("id", ""))
		var rarity: String = String(it.get("rarity", ""))

		var opts_in: Dictionary = {}
		if it.has("opts") and it["opts"] is Dictionary:
			var o: Dictionary = (it["opts"] as Dictionary)
			var aff_out: Array = []
			if o.has("affixes") and (o["affixes"] is Array):
				for a in (o["affixes"] as Array):
					aff_out.append(a)
			opts_in = {
				"archetype": String(o.get("archetype", "")),
				"ilvl": int(o.get("ilvl", 0)),
				"rarity": String(o.get("rarity", rarity)),
				"affixes": aff_out
			}

		var key_dict: Dictionary = { "id": id_str, "rarity": rarity, "opts": opts_in }
		return JSON.stringify(key_dict)

	var out: Array = []
	var by_key: Dictionary = {}

	for it_any in inv_in:
		if not (it_any is Dictionary):
			continue
		var it: Dictionary = (it_any as Dictionary).duplicate(true)

		# gear passthrough
		if is_gear_local.call(it):
			out.append(it)
			continue

		var key: String = String(stack_key_local.call(it))
		if key == "":
			out.append(it)
			continue

		var add_count: int = max(1, int(it.get("count", 1)))
		if by_key.has(key):
			var row: Dictionary = by_key[key]
			row["count"] = int(row.get("count", 1)) + add_count
		else:
			it["count"] = add_count
			by_key[key] = it

	for k in by_key.keys():
		out.append(by_key[k])

	if DEBUG:
		print("[%s][SaveManager.stack] in=%d out=%d unique=%d"
			% [_ts(), inv_in.size(), out.size(), by_key.keys().size()])

	return out

static func _fresh_run_seed() -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var a := int(Time.get_ticks_usec())
	var b := rng.randi()
	var seed_v: int = int((int(a) << 32) | int(b & 0xFFFFFFFF))
	if DEBUG:
		print("[%s][SaveManager.seed] a=%d b=%d -> %d" % [_ts(), a, b, seed_v])
	return seed_v

static func exists(slot: int = DEFAULT_SLOT) -> bool:
	slot = _slot_for_read(slot)
	var ok: bool = FileAccess.file_exists(_meta_path(slot))
	_dbg("exists_meta", slot, {"ok": ok})
	return ok

static func meta_exists(slot: int = DEFAULT_SLOT) -> bool:
	slot = _slot_for_read(slot)
	var ok: bool = FileAccess.file_exists(_meta_path(slot))
	_dbg("meta_exists", slot, {"ok": ok})
	return ok

# ---------- SaveManager: village section (merge-safe, slot-safe) -------------
static func village_path(slot: int = DEFAULT_SLOT) -> String:
	slot = _slot_for_write(slot)
	var p: String = _VillageSave.village_path(slot)
	_dbg("village_path", slot, {"path": p})
	return p

static func load_village(slot: int = DEFAULT_SLOT) -> Dictionary:
	slot = _slot_for_write(slot)
	if _in_menu_phase():
		_dbg("village.load.suppressed_in_menu", slot)
		return {}  # DO NOT create on menu entry
	_dbg("village.load", slot)
	return _VillageSave.load_village(slot)

# Merge d_in into existing full snapshot on disk (grid and/or other fields)
static func save_village(d_in: Dictionary, slot: int = DEFAULT_SLOT) -> void:
	slot = _slot_for_write(slot)
	if _in_menu_phase():
		_dbg("village.save.suppressed_in_menu", slot, {"in_keys": d_in.size()})
		return
	var cur: Dictionary = _VillageSave.load_village(slot)
	var merged: Dictionary = _merge_village(cur, d_in)
	_dbg("village.save", slot, {"in_keys": d_in.size(), "cur_keys": cur.size(), "merged_keys": merged.size()})
	_VillageSave.save_village(merged, slot)

# Capture-from-node returns a (grid-only) snapshot; overlay only grid into full save.
static func capture_village_from(node: Node, slot: int = DEFAULT_SLOT) -> Dictionary:
	slot = _slot_for_write(slot)
	if _in_menu_phase():
		_dbg("village.capture.suppressed_in_menu", slot)
		return {}
	var cur: Dictionary = _VillageSave.load_village(slot)
	var from_node: Dictionary = _VillageSave.write_from_node(node, slot)
	var grid_any: Variant = from_node.get("grid", {})
	if grid_any is Dictionary:
		cur["grid"] = grid_any
	_dbg("village.capture_from_node", slot, {"grid_written": grid_any is Dictionary})
	_VillageSave.save_village(cur, slot)
	return cur

# Apply-to-node may change the in-memory node; persist only grid returned by apply (if any).
static func apply_village_to(node: Node, slot: int = DEFAULT_SLOT) -> Dictionary:
	slot = _slot_for_write(slot)
	if _in_menu_phase():
		_dbg("village.apply.suppressed_in_menu", slot)
		return {}
	var cur: Dictionary = _VillageSave.load_village(slot)
	var applied: Dictionary = _VillageSave.apply_to_node(node, slot)
	var grid_any: Variant = applied.get("grid", {})
	if grid_any is Dictionary:
		cur["grid"] = grid_any
	_dbg("village.apply_to_node", slot, {"grid_written": grid_any is Dictionary})
	_VillageSave.save_village(cur, slot)
	return cur

# ---- merge utility ----------------------------------------------------------
static func _merge_village(base: Dictionary, incoming: Dictionary) -> Dictionary:
	var out := {} as Dictionary
	for k in base.keys(): out[k] = base[k]
	for k in incoming.keys(): out[k] = incoming[k]
	if not incoming.has("npcs"): out["npcs"] = base.get("npcs", [])
	if not incoming.has("recruitment"): out["recruitment"] = base.get("recruitment", {"cursor":0,"page_size":3})
	if not incoming.has("seed"): out["seed"] = int(base.get("seed", 1))
	if not incoming.has("vendors"): out["vendors"] = base.get("vendors", {})
	if not incoming.has("grid") and base.has("grid"): out["grid"] = base["grid"]
	var npcs_any: Variant = out.get("npcs", [])
	out["npcs"] = (npcs_any as Array) if (npcs_any is Array) else []
	var vend_any: Variant = out.get("vendors", {})
	out["vendors"] = (vend_any as Dictionary) if (vend_any is Dictionary) else {}
	var meta := (out.get("meta", {}) as Dictionary) if (out.get("meta", {}) is Dictionary) else {}
	if not meta.has("created_at") and base.has("meta"):
		var bmeta := base["meta"] as Dictionary
		if bmeta.has("created_at"): meta["created_at"] = bmeta["created_at"]
	meta["edited_at"] = Time.get_unix_time_from_system()
	out["meta"] = meta
	return out

# ------------ Misc -----------------------------------------------------------
static func _ts() -> String:
	return "%d.%03d" % [Time.get_unix_time_from_system(), int(Time.get_ticks_msec() % 1000)]

static func get_difficulty_code(slot: int = DEFAULT_SLOT) -> String:
	slot = _slot_for_read(slot)
	var gs: Dictionary = load_game(slot)
	var settings: Dictionary = (_S.to_dict(gs.get("settings", {})) as Dictionary)
	var c: String = String(settings.get("difficulty", "C")).substr(0, 1).to_upper()
	if c not in ["C","U","R","E","A","L","M"]:
		c = "C"
	_dbg("get_difficulty_code", slot, {"code": c})
	return c

static func set_difficulty_code(code: String, slot: int = DEFAULT_SLOT) -> void:
	slot = _slot_for_write(slot)
	var c: String = String(code).substr(0, 1).to_upper()
	if c not in ["C","U","R","E","A","L","M"]:
		c = "C"

	var gs: Dictionary = load_game(slot)
	var settings: Dictionary = (_S.to_dict(gs.get("settings", {})) as Dictionary)
	settings["difficulty"] = c
	gs["settings"] = settings

	# Recompute META thresholds (character + skills) for the new difficulty.
	gs = _recompute_meta_thresholds_for_code(gs, c)

	save_game(gs, slot)
	_dbg("set_difficulty_code", slot, {"code": c})

static func ensure_run_difficulty_locked_on_run_start(slot: int = DEFAULT_SLOT) -> void:
	slot = _slot_for_write(slot)
	var rs: Dictionary = load_run(slot)
	var cur: String = String(rs.get("difficulty_code", ""))
	if cur.length() != 1:
		rs["difficulty_code"] = get_difficulty_code(slot)
		save_run(rs, slot)
		_dbg("lock_run_difficulty", slot, {"code": rs["difficulty_code"]})

static func get_run_difficulty_code(slot: int = DEFAULT_SLOT) -> String:
	slot = _slot_for_read(slot)
	var rs: Dictionary = read_run_if_exists(slot)  # read-only; safe for menu tooling
	var c: String = String(rs.get("difficulty_code", "")).substr(0, 1).to_upper()
	if c not in ["C","U","R","E","A","L","M"]:
		c = get_difficulty_code(slot)
	_dbg("get_run_difficulty_code", slot, {"code": c})
	return c

# ---------- Non-creating accessors (use in autoloads / main menu boot) -------
static func read_game_if_exists(slot: int = DEFAULT_SLOT) -> Dictionary:
	slot = _slot_for_read(slot)
	var p: String = _meta_path(slot)
	if not FileAccess.file_exists(p):
		_dbg("read_game_if_exists.miss", slot, {"path": p})
		return {}
	var f: FileAccess = FileAccess.open(p, FileAccess.READ)
	_log_open(p, "READ", slot, f != null)
	if f == null:
		_dbg("read_game_if_exists.open_failed", slot, {"path": p})
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	var d: Dictionary = _S.to_dict(parsed)
	_dbg("read_game_if_exists.hit", slot, {"keys": d.size()})
	return _Meta.migrate(d)

static func read_run_if_exists(slot: int = DEFAULT_SLOT) -> Dictionary:
	slot = _slot_for_read(slot)
	var p: String = _run_path(slot)
	if not FileAccess.file_exists(p):
		_dbg("read_run_if_exists.miss", slot, {"path": p})
		return {}
	var f: FileAccess = FileAccess.open(p, FileAccess.READ)
	_log_open(p, "READ", slot, f != null)
	if f == null:
		_dbg("read_run_if_exists.open_failed", slot, {"path": p})
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	var d: Dictionary = _S.to_dict(parsed)
	var out: Dictionary = _RunSchema.migrate(d, int(_S.dget(read_game_if_exists(slot), "schema_version", 1)))
	_dbg("read_run_if_exists.hit", slot, {"keys": out.size()})
	return out

static func list_present_slots(max_slots: int = 12) -> Array[int]:
	var out: Array[int] = []
	for i in range(1, max_slots + 1):
		if FileAccess.file_exists(_meta_path(i)) or FileAccess.file_exists(_run_path(i)):
			out.append(i)
	if DEBUG:
		print("[%s][SaveManager.list_present_slots] -> %s" % [_ts(), str(out)])
	return out

# Return the currently active slot (SceneTree.meta("current_slot") if set; else DEFAULT_SLOT).
static func active_slot() -> int:
	return _slot_from_tree_or_default()

# Recompute META thresholds (character + all skills) for a given code.
static func _recompute_meta_thresholds_for_code(gs_in: Dictionary, code: String) -> Dictionary:
	var gs: Dictionary = gs_in.duplicate(true)
	var pl: Dictionary = _S.to_dict(gs.get("player", {}))
	var sb: Dictionary = _S.to_dict(pl.get("stat_block", {}))
	var lvl: int = int(sb.get("level", 1))
	sb["xp_needed"] = int(_XpTuning.xp_to_next_level_v2(lvl, code))
	pl["stat_block"] = sb

	var st_in: Dictionary = _S.to_dict(pl.get("skill_tracks", {}))
	var st_out: Dictionary = {}
	for k_any in st_in.keys():
		var k: String = String(k_any)
		var row: Dictionary = _S.to_dict(st_in[k])
		var rlvl: int = int(row.get("level", 1))
		row["xp_needed"] = int(_XpTuning.xp_to_next_level_v2(rlvl, code))
		st_out[k] = row

	pl["skill_tracks"] = st_out
	gs["player"] = pl
	return gs

# Recompute RUN thresholds (character + all skills) for a given code.
static func _recompute_run_thresholds_for_code(run_in: Dictionary, code: String) -> Dictionary:
	var rs: Dictionary = run_in.duplicate(true)

	var sb: Dictionary = _S.to_dict(_S.dget(rs, "player_stat_block", {}))
	var lvl: int = int(_S.dget(sb, "level", 1))
	sb["xp_needed"] = int(_XpTuning.xp_to_next_level_v2(lvl, code))
	rs["player_stat_block"] = sb

	var st_in: Dictionary = _S.to_dict(_S.dget(rs, "skill_tracks", {}))
	for k_any in st_in.keys():
		var k: String = String(k_any)
		var row: Dictionary = _S.to_dict(st_in[k])
		var rlvl: int = int(_S.dget(row, "level", 1))
		row["xp_needed"] = int(_XpTuning.xp_to_next_level_v2(rlvl, code))
		st_in[k] = row
	rs["skill_tracks"] = st_in

	return rs
