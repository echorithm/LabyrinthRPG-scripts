extends Node


# -------- Paths / filenames --------
const SAVE_DIR: String = "user://saves"
const DEFAULT_SLOT: int = 1
const META_NAME: String = "slot_%d_meta.json"
const RUN_NAME: String = "slot_%d_run.json"
# Legacy resource saves (optional one-time import)
const LEGACY_META_RES: String = "slot_%d.res"
const LEGACY_RUN_RES: String = "slot_%d_run.res"

# -------- Public flags --------
var request_continue: bool = false

# -------- In-memory mirrors (typed) --------
var meta: Dictionary = {}
var run: Dictionary = {}

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)

# =========================
# Small typed utilities
# =========================
static func dget(d: Dictionary, key: String, def: Variant) -> Variant:
	# Safe defaulting without relying on Dictionary.get()
	if d.has(key):
		return d[key]
	return def

func _meta_path(slot: int) -> String:
	return "%s/%s" % [SAVE_DIR, META_NAME % slot]

func _run_path(slot: int) -> String:
	return "%s/%s" % [SAVE_DIR, RUN_NAME % slot]

func _legacy_meta_path(slot: int) -> String:
	return "%s/%s" % [SAVE_DIR, LEGACY_META_RES % slot]

func _legacy_run_path(slot: int) -> String:
	return "%s/%s" % [SAVE_DIR, LEGACY_RUN_RES % slot]


func _save_json(path: String, data: Dictionary) -> void:
	# Ensure directory exists (e.g., user://saves)
	var dir_path: String = path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir_path)

	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("SaveManager: cannot open for write: " + path + " (err=" + str(FileAccess.get_open_error()) + ")")
		return

	f.store_string(JSON.stringify(data, "  "))
	f.flush() # ensure OS buffer is flushed
	f = null  # close

	# Verify write
	if not FileAccess.file_exists(path):
		push_error("SaveManager: write verification failed (file missing): " + path)

func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var txt: String = f.get_as_text()
	var j: JSON = JSON.new()
	var err: int = j.parse(txt)
	if err != OK:
		# Use instance methods with no args; include err code for clarity
		push_error("SaveManager: JSON parse failed for %s (err=%d, line=%d, msg=%s)" % [
			path, err, j.get_error_line(), j.get_error_message()
		])
		return {}
	var data_any: Variant = j.data
	if data_any is Dictionary:
		return data_any as Dictionary
	return {}

# =========================
# Defaults / Migrations
# =========================
func _default_meta() -> Dictionary:
	var now: int = Time.get_unix_time_from_system()
	return {
		"schema_version": 1,
		"created_at": now,
		"updated_at": now,
		# core floors
		"last_floor": 1,
		"current_floor": 1,
		"previous_floor": 0,
		# non-double-dip (character)
		"highest_claimed_level": 1,
		# player snapshot
		"player": {
			"health": 100,
			"level": 1,
			"highest_claimed_level": 1,
			"skills": [],     # [{id,level,xp,highest_claimed_level,cap,milestones_claimed}]
			"inventory": []   # [{id,count,ilvl,archetype,rarity,affixes,durability_max,durability_current,weight}]
		},
		# world
		"world_flags": {},
		"floor_seeds": {},
		"anchors_unlocked": [1],
		"world_segments": [
			{"segment_id": 1, "drained": false, "boss_sigil": false}
		],
		# penalties
		"penalties": {
			"level_pct": 0.10,
			"skill_xp_pct": 0.15,
			"floor_at_level": 1,
			"floor_at_skill_level": 1
		}
	}

func _default_run(meta_schema: int) -> Dictionary:
	var now: int = Time.get_unix_time_from_system()
	return {
		"schema_version": 1,
		"linked_meta_schema": int(meta_schema),
		"created_at": now,
		"updated_at": now,
		"run_seed": 0,
		"depth": 1,
		"hp_max": 30, "hp": 30,
		"mp_max": 10, "mp": 10,
		"gold": 0,
		"items": [],
		# --- Sigil "pity" session state (per segment) ---
		"sigils_segment_id": 1,
		"sigils_elites_killed_in_segment": 0,
		"sigils_required_elites": 4,
		"sigils_charged": false
	}

func _migrate_meta(d: Dictionary) -> Dictionary:
	var out: Dictionary = d.duplicate(true)

	# schema + timestamps
	var now: int = Time.get_unix_time_from_system()
	var schema: int = int(dget(out, "schema_version", 0))
	if schema <= 0:
		out["schema_version"] = 1
	if not out.has("created_at"):
		out["created_at"] = now
	out["updated_at"] = now

	# floors
	out["last_floor"]     = int(dget(out, "last_floor", 1))
	out["current_floor"]  = max(1, int(dget(out, "current_floor", 1)))
	out["previous_floor"] = max(0, int(dget(out, "previous_floor", 0)))

	# penalties
	var p_any: Variant = dget(out, "penalties", {})
	var p: Dictionary = (p_any as Dictionary) if p_any is Dictionary else {}
	out["penalties"] = {
		"level_pct": float(dget(p, "level_pct", 0.10)),
		"skill_xp_pct": float(dget(p, "skill_xp_pct", 0.15)),
		"floor_at_level": max(1, int(dget(p, "floor_at_level", 1))),
		"floor_at_skill_level": max(1, int(dget(p, "floor_at_skill_level", 1))),
	}

	# anchors & segments
	if not out.has("anchors_unlocked"):
		out["anchors_unlocked"] = [1]
	if not out.has("world_segments"):
		out["world_segments"] = [{"segment_id": 1, "drained": false, "boss_sigil": false}]

	# player block
	var pl_any: Variant = dget(out, "player", {})
	var pl: Dictionary = (pl_any as Dictionary) if pl_any is Dictionary else {}
	pl["health"] = int(dget(pl, "health", 100))
	pl["level"]  = max(1, int(dget(pl, "level", 1)))
	pl["highest_claimed_level"] = max(1, int(dget(pl, "highest_claimed_level", pl["level"])))
	out["highest_claimed_level"] = max(1, int(dget(out, "highest_claimed_level", pl["level"])))

	# skills normalize
	var skills_in_any: Variant = dget(pl, "skills", [])
	var skills_in: Array = (skills_in_any as Array) if skills_in_any is Array else []
	var skills_out: Array = []
	for s_any in skills_in:
		if not (s_any is Dictionary):
			continue
		var sd: Dictionary = s_any as Dictionary
		var lvl: int = max(1, int(dget(sd, "level", 1)))
		var hcl: int = max(1, int(dget(sd, "highest_claimed_level", lvl)))
		var cap: int = max(1, int(dget(sd, "cap", 10)))
		var xp_val: int = int(dget(sd, "xp", 0))
		# milestones normalize to Array[int]
		var m_any: Variant = dget(sd, "milestones_claimed", [0])
		var m_arr: Array = []
		if m_any is PackedInt32Array:
			for i in (m_any as PackedInt32Array):
				m_arr.append(int(i))
		elif m_any is Array:
			for i in (m_any as Array):
				m_arr.append(int(i))
		else:
			m_arr = [0]
		skills_out.append({
			"id": String(dget(sd, "id", "")),
			"level": lvl,
			"xp": xp_val,
			"highest_claimed_level": hcl,
			"cap": cap,
			"milestones_claimed": m_arr
		})
	pl["skills"] = skills_out

	# inventory enrichment
	var inv_in_any: Variant = dget(pl, "inventory", [])
	var inv_in: Array = (inv_in_any as Array) if inv_in_any is Array else []
	var inv_out: Array = []
	var ilvl_guess: int = max(1, int(dget(out, "current_floor", 1)))
	for it_any in inv_in:
		if not (it_any is Dictionary):
			continue
		var it: Dictionary = it_any as Dictionary
		var id_str: String = String(dget(it, "id", ""))
		var count: int = max(1, int(dget(it, "count", 1)))
		var aff_any: Variant = dget(it, "affixes", [])
		var aff_arr: Array = []
		if aff_any is Array:
			for a in (aff_any as Array):
				aff_arr.append(String(a))
		var ii: Dictionary = {
			"id": id_str,
			"count": count,
			"ilvl": int(dget(it, "ilvl", ilvl_guess)),
			"archetype": String(dget(it, "archetype", "Light")),
			"rarity": String(dget(it, "rarity", "Common")),
			"affixes": aff_arr,
			"durability_max": int(dget(it, "durability_max", 100)),
			"durability_current": int(dget(it, "durability_current", 100)),
			"weight": float(dget(it, "weight", 1.0)),
		}
		inv_out.append(ii)
	pl["inventory"] = inv_out
	out["player"] = pl

	# seeds normalize to int->int
	var seeds_any: Variant = dget(out, "floor_seeds", {})
	var seeds_in: Dictionary = (seeds_any as Dictionary) if seeds_any is Dictionary else {}
	var seeds_out: Dictionary = {}
	for k in seeds_in.keys():
		var ki: int = int(k)
		seeds_out[ki] = int(seeds_in[k])
	out["floor_seeds"] = seeds_out

	return out

func _migrate_run(d: Dictionary, meta_schema: int) -> Dictionary:
	var out: Dictionary = d.duplicate(true)
	var now: int = Time.get_unix_time_from_system()
	if int(dget(out, "schema_version", 0)) <= 0:
		out["schema_version"] = 1
	out["linked_meta_schema"] = int(meta_schema)
	out["updated_at"] = now
	if not out.has("created_at"):
		out["created_at"] = now
	out["depth"] = max(1, int(dget(out, "depth", 1)))
	out["run_seed"] = int(dget(out, "run_seed", 0))
	out["hp_max"] = int(dget(out, "hp_max", 30))
	out["hp"] = int(dget(out, "hp", out["hp_max"]))
	out["mp_max"] = int(dget(out, "mp_max", 10))
	out["mp"] = int(dget(out, "mp", out["mp_max"]))
	out["gold"] = int(dget(out, "gold", 0))
	if not out.has("items"):
		out["items"] = []
	# Sigil fields (backfill)
	if not out.has("sigils_segment_id"): out["sigils_segment_id"] = 1
	if not out.has("sigils_elites_killed_in_segment"): out["sigils_elites_killed_in_segment"] = 0
	if not out.has("sigils_required_elites"): out["sigils_required_elites"] = 4
	if not out.has("sigils_charged"): out["sigils_charged"] = false
	return out

# =========================
# Load / Save API
# =========================
func exists(slot: int = DEFAULT_SLOT) -> bool:
	return FileAccess.file_exists(_meta_path(slot))

func run_exists(slot: int = DEFAULT_SLOT) -> bool:
	return FileAccess.file_exists(_run_path(slot))

func load_game(slot: int = DEFAULT_SLOT) -> Dictionary:
	if FileAccess.file_exists(_meta_path(slot)):
		meta = _migrate_meta(_load_json(_meta_path(slot)))
		return meta
	# legacy import (optional)
	if FileAccess.file_exists(_legacy_meta_path(slot)):
		_import_legacy_game(slot)
		meta = _migrate_meta(_load_json(_meta_path(slot)))
		return meta
	meta = _migrate_meta(_default_meta())
	_save_json(_meta_path(slot), meta)
	return meta

func save_game(d: Dictionary, slot: int = DEFAULT_SLOT) -> void:
	d["updated_at"] = Time.get_unix_time_from_system()
	meta = _migrate_meta(d)
	_save_json(_meta_path(slot), meta)

func load_run(slot: int = DEFAULT_SLOT) -> Dictionary:
	if FileAccess.file_exists(_run_path(slot)):
		run = _migrate_run(_load_json(_run_path(slot)), int(dget(load_game(slot), "schema_version", 1)))
		return run
	# legacy import (optional)
	if FileAccess.file_exists(_legacy_run_path(slot)):
		_import_legacy_run(slot)
		run = _migrate_run(_load_json(_run_path(slot)), int(dget(load_game(slot), "schema_version", 1)))
		return run
	run = _migrate_run(_default_run(int(dget(load_game(slot), "schema_version", 1))), int(dget(load_game(slot), "schema_version", 1)))
	_save_json(_run_path(slot), run)
	return run

func save_run(d: Dictionary, slot: int = DEFAULT_SLOT) -> void:
	d["updated_at"] = Time.get_unix_time_from_system()
	run = _migrate_run(d, int(dget(load_game(slot), "schema_version", 1)))
	_save_json(_run_path(slot), run)

# =========================
# Public helpers (same names you used)
# =========================
func get_current_floor(slot: int = DEFAULT_SLOT) -> int:
	return int(dget(load_game(slot), "current_floor", 1))

func get_previous_floor(slot: int = DEFAULT_SLOT) -> int:
	return int(dget(load_game(slot), "previous_floor", 0))

func get_last_floor(slot: int = DEFAULT_SLOT) -> int:
	return int(dget(load_game(slot), "last_floor", 1))

func set_current_floor(floor: int, slot: int = DEFAULT_SLOT) -> void:
	var gs: Dictionary = load_game(slot)
	var cur: int = int(dget(gs, "current_floor", 1))
	if cur != floor:
		gs["previous_floor"] = cur
		gs["current_floor"] = max(1, floor)
		if int(gs["current_floor"]) > int(dget(gs, "last_floor", 1)):
			gs["last_floor"] = int(gs["current_floor"])
	save_game(gs, slot)

func change_floor(delta: int, slot: int = DEFAULT_SLOT) -> int:
	var gs: Dictionary = load_game(slot)
	var cur: int = int(dget(gs, "current_floor", 1))
	var nf: int = max(1, cur + delta)
	gs["previous_floor"] = cur
	gs["current_floor"] = nf
	if nf > int(dget(gs, "last_floor", 1)):
		gs["last_floor"] = nf
	save_game(gs, slot)
	return nf

func get_or_create_seed(floor: int, slot: int = DEFAULT_SLOT) -> int:
	var gs: Dictionary = load_game(slot)
	var seeds_any: Variant = dget(gs, "floor_seeds", {})
	var seeds: Dictionary = (seeds_any as Dictionary) if seeds_any is Dictionary else {}
	if seeds.has(floor):
		return int(seeds[floor])
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	var s: int = int(rng.randi())
	seeds[floor] = s
	gs["floor_seeds"] = seeds
	save_game(gs, slot)
	return s

# --- Run helpers / bridging to RunState ---
func peek_run_depth(slot: int = DEFAULT_SLOT) -> int:
	return int(dget(load_run(slot), "depth", 1))

func set_run_floor(target_floor: int, slot: int = DEFAULT_SLOT) -> void:
	var rs: Dictionary = load_run(slot)
	rs["depth"] = max(1, target_floor)
	save_run(rs, slot)
	# mirror depth to meta (menus that read meta stay correct)
	set_current_floor(int(rs["depth"]), slot)

func save_current_run(slot: int = DEFAULT_SLOT) -> void:
	var rs: Dictionary = runstate_to_dict()
	save_run(rs, slot)

func load_current_run(slot: int = DEFAULT_SLOT) -> void:
	var rs: Dictionary = load_run(slot)
	apply_dict_to_runstate(rs)

func delete_run(slot: int = DEFAULT_SLOT) -> void:
	var p: String = _run_path(slot)
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)

func start_new_run(slot: int = DEFAULT_SLOT, clear_seeds: bool = true) -> void:
	delete_run(slot)
	var gs: Dictionary = load_game(slot)
	gs["previous_floor"] = 0
	gs["current_floor"] = 1
	gs["last_floor"] = max(1, int(dget(gs, "last_floor", 1)))
	if clear_seeds:
		gs["floor_seeds"] = {}
	save_game(gs, slot)
	RunState.new_run()
	save_current_run(slot)
	
# ---------------- Progression / Death Penalty (META) ----------------

func claim_character_level(new_level: int, slot: int = DEFAULT_SLOT) -> void:
	var gs: Dictionary = load_game(slot)
	var pl_any: Variant = dget(gs, "player", {})
	var pl: Dictionary = (pl_any as Dictionary) if pl_any is Dictionary else {}
	var cur: int = int(dget(pl, "level", 1))
	if new_level > cur:
		pl["level"] = new_level
	# anti double-dip
	var h_pl: int = int(dget(pl, "highest_claimed_level", 1))
	var h_meta: int = int(dget(gs, "highest_claimed_level", 1))
	if new_level > h_pl:
		pl["highest_claimed_level"] = new_level
	if new_level > h_meta:
		gs["highest_claimed_level"] = new_level
	gs["player"] = pl
	save_game(gs, slot)

func claim_skill_level(skill_id: String, new_level: int, slot: int = DEFAULT_SLOT) -> void:
	var gs: Dictionary = load_game(slot)
	var pl: Dictionary = (dget(gs, "player", {}) as Dictionary) if dget(gs, "player", {}) is Dictionary else {}
	var skills_any: Variant = dget(pl, "skills", [])
	var skills: Array = (skills_any as Array) if skills_any is Array else []

	var found: bool = false
	for i in range(skills.size()):
		if not (skills[i] is Dictionary): continue
		var sd: Dictionary = skills[i]
		if String(dget(sd, "id", "")) != skill_id: continue
		found = true
		var cur: int = int(dget(sd, "level", 1))
		if new_level > cur:
			sd["level"] = new_level
		var hc: int = int(dget(sd, "highest_claimed_level", 1))
		if new_level > hc:
			sd["highest_claimed_level"] = new_level
		skills[i] = sd
	if not found:
		skills.append({
			"id": skill_id,
			"level": max(1, new_level),
			"xp": 0,
			"highest_claimed_level": max(1, new_level),
			"cap": 10,
			"milestones_claimed": [0],
		})

	pl["skills"] = skills
	gs["player"] = pl
	save_game(gs, slot)

func apply_death_penalties(slot: int = DEFAULT_SLOT) -> void:
	var gs: Dictionary = load_game(slot)
	var p: Dictionary = (dget(gs, "penalties", {}) as Dictionary) if dget(gs, "penalties", {}) is Dictionary else {}
	var pl: Dictionary = (dget(gs, "player", {}) as Dictionary) if dget(gs, "player", {}) is Dictionary else {}

	# Character
	var level: int = int(dget(pl, "level", 1))
	var hc_pl: int = int(dget(pl, "highest_claimed_level", level))
	var lvl_pct: float = float(dget(p, "level_pct", 0.10))
	var floor_lvl: int = int(dget(p, "floor_at_level", 1))
	var level_loss: int = int(round(level * lvl_pct))
	var new_level: int = max(level - level_loss, floor_lvl, hc_pl)
	pl["level"] = new_level

	# Skills
	var skills_any: Variant = dget(pl, "skills", [])
	var skills: Array = (skills_any as Array) if skills_any is Array else []
	var xp_pct: float = float(dget(p, "skill_xp_pct", 0.15))
	var floor_skill: int = int(dget(p, "floor_at_skill_level", 1))
	for i in range(skills.size()):
		if not (skills[i] is Dictionary): continue
		var sd: Dictionary = skills[i]
		var xp: int = int(dget(sd, "xp", 0))
		var xp_loss: int = int(round(float(xp) * xp_pct))
		sd["xp"] = max(0, xp - xp_loss)
		var lvl: int = int(dget(sd, "level", 1))
		var hc: int = int(dget(sd, "highest_claimed_level", lvl))
		if lvl < floor_skill: lvl = floor_skill
		if lvl < hc: lvl = hc
		sd["level"] = lvl
		skills[i] = sd
	pl["skills"] = skills

	gs["player"] = pl
	save_game(gs, slot)

	
# ---------------- Sigil helpers (RUN) ----------------

func segment_id_for_floor(floor: int) -> int:
	return (max(1, floor) - 1) / 3 + 1

func ensure_sigil_segment_for_floor(floor: int, required_elites: int = 4, slot: int = DEFAULT_SLOT) -> void:
	var seg: int = segment_id_for_floor(floor)
	var rs: Dictionary = load_run(slot)
	var cur_seg: int = int(dget(rs, "sigils_segment_id", 0))
	var req: int = max(1, required_elites)

	if cur_seg != seg:
		rs["sigils_segment_id"] = seg
		rs["sigils_elites_killed_in_segment"] = 0
		rs["sigils_required_elites"] = req
		rs["sigils_charged"] = false
	else:
		# Make sure keys exist even if we didn't change segment
		if not rs.has("sigils_required_elites"): rs["sigils_required_elites"] = req
		if not rs.has("sigils_elites_killed_in_segment"): rs["sigils_elites_killed_in_segment"] = 0
		if not rs.has("sigils_charged"): rs["sigils_charged"] = false

	save_run(rs, slot)

func notify_elite_killed(slot: int = DEFAULT_SLOT) -> void:
	var rs: Dictionary = load_run(slot)
	var kills: int = int(dget(rs, "sigils_elites_killed_in_segment", 0)) + 1
	rs["sigils_elites_killed_in_segment"] = kills
	var req: int = max(1, int(dget(rs, "sigils_required_elites", 4)))
	if kills >= req:
		rs["sigils_charged"] = true
	save_run(rs, slot)

func is_sigil_charged(slot: int = DEFAULT_SLOT) -> bool:
	var rs: Dictionary = load_run(slot)
	return bool(dget(rs, "sigils_charged", false))

func consume_sigil_charge(slot: int = DEFAULT_SLOT) -> void:
	var rs: Dictionary = load_run(slot)
	rs["sigils_charged"] = false
	rs["sigils_elites_killed_in_segment"] = 0
	save_run(rs, slot)


# --- Bridge RunState <-> JSON dict ---
func runstate_to_dict() -> Dictionary:
	var schema_meta: int = int(dget(load_game(), "schema_version", 1))

	# Convert Array[StringName] -> Array[String] for JSON
	var items_out: Array[String] = []
	for s in RunState.items:
		items_out.append(String(s))

	return {
		"schema_version": 1,
		"linked_meta_schema": schema_meta,
		"run_seed": RunState.run_seed,
		"depth": RunState.depth,
		"hp_max": RunState.hp_max,
		"hp": RunState.hp,
		"mp_max": RunState.mp_max,
		"mp": RunState.mp,
		"gold": RunState.gold,
		"items": items_out
	}


func apply_dict_to_runstate(r: Dictionary) -> void:
	RunState.run_seed = int(dget(r, "run_seed", 0))
	RunState.depth    = int(dget(r, "depth", 1))
	RunState.hp_max   = int(dget(r, "hp_max", 30))
	RunState.hp       = int(dget(r, "hp", RunState.hp_max))
	RunState.mp_max   = int(dget(r, "mp_max", 10))
	RunState.mp       = int(dget(r, "mp", RunState.mp_max))
	RunState.gold     = int(dget(r, "gold", 0))

	# Items: JSON is Array of strings; RunState expects Array[StringName]
	var items_any: Variant = dget(r, "items", [])
	var src: Array = (items_any as Array) if items_any is Array else []
	var typed_items: Array[StringName] = []
	for v in src:
		typed_items.append(StringName(String(v)))
	RunState.items = typed_items

	if RunState.run_seed != 0:
		RunState.rng.seed = RunState.run_seed

# =========================
# Legacy one-time import (optional)
# =========================
func _import_legacy_game(slot: int) -> void:
	var legacy_path: String = _legacy_meta_path(slot)
	var res: Resource = ResourceLoader.load(legacy_path)
	if res == null:
		return
	var gs_dict: Dictionary = _default_meta()
	if res.has_method("get"):
		gs_dict["last_floor"] = int(res.get("last_floor"))
		gs_dict["current_floor"] = int(res.get("current_floor"))
		gs_dict["previous_floor"] = int(res.get("previous_floor"))
		var fs_any: Variant = res.get("floor_seeds")
		if fs_any is Dictionary:
			var out: Dictionary = {}
			for k in (fs_any as Dictionary).keys():
				out[int(k)] = int((fs_any as Dictionary)[k])
			gs_dict["floor_seeds"] = out
	_save_json(_meta_path(slot), _migrate_meta(gs_dict))

func _import_legacy_run(slot: int) -> void:
	var legacy_path: String = _legacy_run_path(slot)
	var res: Resource = ResourceLoader.load(legacy_path)
	if res == null:
		return
	var rs_dict: Dictionary = _default_run(1)
	if res.has_method("get"):
		rs_dict["run_seed"] = int(res.get("run_seed"))
		rs_dict["depth"] = int(res.get("depth"))
		rs_dict["hp_max"] = int(res.get("hp_max"))
		rs_dict["hp"] = int(res.get("hp"))
		rs_dict["mp_max"] = int(res.get("mp_max"))
		rs_dict["mp"] = int(res.get("mp"))
		rs_dict["gold"] = int(res.get("gold"))
		var items_any: Variant = res.get("items")
		if items_any is Array:
			rs_dict["items"] = (items_any as Array).duplicate()
	_save_json(_run_path(slot), _migrate_run(rs_dict, 1))
	
func debug_print_presence(slot: int = DEFAULT_SLOT) -> void:
	var mp: String = _meta_path(slot)
	var rp: String = _run_path(slot)
	print("[SAVE] meta_exists=", FileAccess.file_exists(mp),
		  " run_exists=", FileAccess.file_exists(rp),
		  " | meta=", mp, " run=", rp)

# ---------- Inventory helpers (META -> player.inventory) ----------

func _inv_get(gs: Dictionary) -> Array:
	var pl_any: Variant = dget(gs, "player", {})
	var pl: Dictionary = (pl_any as Dictionary) if pl_any is Dictionary else {}
	var inv_any: Variant = dget(pl, "inventory", [])
	return (inv_any as Array) if inv_any is Array else []

func _inv_set(gs: Dictionary, inv: Array) -> void:
	var pl_any: Variant = dget(gs, "player", {})
	var pl: Dictionary = (pl_any as Dictionary) if pl_any is Dictionary else {}
	pl["inventory"] = inv
	gs["player"] = pl

func _affix_equal(a_any: Variant, b: Array) -> bool:
	var a: Array = (a_any as Array) if a_any is Array else []
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if String(a[i]) != String(b[i]):
			return false
	return true

func inv_add(item_id: String, count: int = 1, opts: Dictionary = {}, slot: int = DEFAULT_SLOT) -> void:
	var gs: Dictionary = load_game(slot)
	var inv: Array = _inv_get(gs)

	var ilvl: int = int(dget(opts, "ilvl", int(dget(gs, "current_floor", 1))))
	var archetype: String = String(dget(opts, "archetype", "Light"))
	var rarity: String = String(dget(opts, "rarity", "Common"))
	var aff_in: Variant = dget(opts, "affixes", [])
	var aff: Array = []
	if aff_in is Array:
		for a in (aff_in as Array):
			aff.append(String(a))
	var dmax: int = int(dget(opts, "durability_max", 0))
	var dcur: int = int(dget(opts, "durability_current", dmax))
	var weight: float = float(dget(opts, "weight", 1.0))

	if dmax <= 0:
		# Stackable
		var idx: int = -1
		for i in range(inv.size()):
			if not (inv[i] is Dictionary):
				continue
			var it: Dictionary = inv[i]
			if String(dget(it, "id", "")) == item_id \
			and int(dget(it, "ilvl", ilvl)) == ilvl \
			and String(dget(it, "archetype", "")) == archetype \
			and String(dget(it, "rarity", "")) == rarity \
			and _affix_equal(dget(it, "affixes", []), aff) \
			and int(dget(it, "durability_max", 0)) == 0:
				idx = i
				break
		if idx >= 0:
			var st: Dictionary = inv[idx]
			st["count"] = int(dget(st, "count", 1)) + max(1, count)
			inv[idx] = st
		else:
			inv.append({
				"id": item_id, "count": max(1, count),
				"ilvl": ilvl, "archetype": archetype, "rarity": rarity,
				"affixes": aff, "durability_max": 0, "durability_current": 0, "weight": weight
			})
	else:
		# Non-stackable: add N copies with durability
		var n: int = max(1, count)
		for _i in range(n):
			inv.append({
				"id": item_id, "count": 1,
				"ilvl": ilvl, "archetype": archetype, "rarity": rarity,
				"affixes": aff, "durability_max": dmax, "durability_current": dcur, "weight": weight
			})

	_inv_set(gs, inv)
	save_game(gs, slot)

func inv_remove(index: int, count: int = 1, slot: int = DEFAULT_SLOT) -> void:
	var gs: Dictionary = load_game(slot)
	var inv: Array = _inv_get(gs)
	if index < 0 or index >= inv.size():
		return
	if not (inv[index] is Dictionary):
		inv.remove_at(index)
	else:
		var it: Dictionary = inv[index]
		var dmax: int = int(dget(it, "durability_max", 0))
		if dmax > 0:
			# Non-stackable: remove the entry
			inv.remove_at(index)
		else:
			var c: int = int(dget(it, "count", 1))
			var new_c: int = c - max(1, count)
			if new_c > 0:
				it["count"] = new_c
				inv[index] = it
			else:
				inv.remove_at(index)
	_inv_set(gs, inv)
	save_game(gs, slot)

func inv_damage(index: int, amount: int, remove_when_broken: bool = true, slot: int = DEFAULT_SLOT) -> int:
	var gs: Dictionary = load_game(slot)
	var inv: Array = _inv_get(gs)
	if index < 0 or index >= inv.size():
		return -1
	if not (inv[index] is Dictionary):
		return -1
	var it: Dictionary = inv[index]
	var dmax: int = int(dget(it, "durability_max", 0))
	if dmax <= 0:
		return -1
	var cur: int = int(dget(it, "durability_current", dmax))
	cur = max(0, cur - max(0, amount))
	it["durability_current"] = cur
	inv[index] = it
	if remove_when_broken and cur <= 0:
		inv.remove_at(index)
	_inv_set(gs, inv)
	save_game(gs, slot)
	return cur

func inv_total_weight(slot: int = DEFAULT_SLOT) -> float:
	var gs: Dictionary = load_game(slot)
	var inv: Array = _inv_get(gs)
	var total: float = 0.0
	for it_any in inv:
		if not (it_any is Dictionary):
			continue
		var it: Dictionary = it_any
		var w: float = float(dget(it, "weight", 1.0))
		var dmax: int = int(dget(it, "durability_max", 0))
		if dmax > 0:
			total += w # non-stackable = 1
		else:
			total += w * float(int(dget(it, "count", 1)))
	return total
