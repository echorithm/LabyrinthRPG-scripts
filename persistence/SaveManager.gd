extends Node

# =========================
# Paths / filenames
# =========================
const SAVE_DIR: String = "user://saves"
const DEFAULT_SLOT: int = 1
const META_NAME: String = "slot_%d_meta.json"
const RUN_NAME: String = "slot_%d_run.json"
# Legacy resource saves (optional one-time import)
const LEGACY_META_RES: String = "slot_%d.res"
const LEGACY_RUN_RES: String = "slot_%d_run.res"

# =========================
# Modules
# =========================
const _S      := preload("res://persistence/util/save_utils.gd")
const _Meta   := preload("res://persistence/schemas/meta_schema.gd")
const _Run    := preload("res://persistence/schemas/run_schema.gd")
const _Derive := preload("res://scripts/combat/derive/DerivedCalc.gd")

# -------- Public flags --------
var request_continue: bool = false

# -------- In-memory mirrors (typed) --------
var meta: Dictionary = {}
var run: Dictionary = {}

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)

# -------------------------------------------------
# Internal path helpers
# -------------------------------------------------
func _meta_path(slot: int) -> String:
	return "%s/%s" % [SAVE_DIR, META_NAME % slot]

func _run_path(slot: int) -> String:
	return "%s/%s" % [SAVE_DIR, RUN_NAME % slot]

func _legacy_meta_path(slot: int) -> String:
	return "%s/%s" % [SAVE_DIR, LEGACY_META_RES % slot]

func _legacy_run_path(slot: int) -> String:
	return "%s/%s" % [SAVE_DIR, LEGACY_RUN_RES % slot]

# -------------------------------------------------
# JSON I/O (atomic with .bak fallback)
# -------------------------------------------------
func _save_json(path: String, data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp: String = path + ".tmp"
	var bak: String = path + ".bak"

	var f: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("SaveManager: cannot open for write: " + tmp + " (err=" + str(FileAccess.get_open_error()) + ")")
		return
	f.store_string(JSON.stringify(data, "  "))
	f.flush()
	f = null

	# Rotate backup
	if FileAccess.file_exists(path):
		if FileAccess.file_exists(bak):
			DirAccess.remove_absolute(bak)
		var r1 := DirAccess.rename_absolute(path, bak)
		if r1 != OK:
			push_warning("SaveManager: could not rotate backup: " + str(r1))

	# Atomic replace
	var ok := DirAccess.rename_absolute(tmp, path)
	if ok != OK:
		push_error("SaveManager: rename failed: " + tmp + " -> " + path + " (err=" + str(ok) + ")")

func _load_json(path: String) -> Dictionary:
	var d := _parse_json_file(path)
	if d.is_empty():
		var bak := _parse_json_file(path + ".bak")
		if not bak.is_empty():
			push_warning("SaveManager: recovered from backup for " + path)
			return bak
	return d

# =========================
# Load / Save API
# =========================
func exists(slot: int = DEFAULT_SLOT) -> bool:
	return FileAccess.file_exists(_meta_path(slot))

func run_exists(slot: int = DEFAULT_SLOT) -> bool:
	return FileAccess.file_exists(_run_path(slot))

func load_game(slot: int = DEFAULT_SLOT) -> Dictionary:
	var mp: String = _meta_path(slot)
	if FileAccess.file_exists(mp):
		meta = _Meta.migrate(_load_json(mp))
		return meta

	# legacy import path (optional)
	var lmp: String = _legacy_meta_path(slot)
	if FileAccess.file_exists(lmp):
		_import_legacy_game(slot)
		meta = _Meta.migrate(_load_json(mp))
		return meta

	# create defaults
	meta = _Meta.defaults()
	_save_json(mp, meta)
	return meta

func save_game(d: Dictionary, slot: int = DEFAULT_SLOT) -> void:
	# Always normalize/migrate before save
	d["updated_at"] = _S.now_ts()
	meta = _Meta.migrate(d)
	_save_json(_meta_path(slot), meta)

func load_run(slot: int = DEFAULT_SLOT) -> Dictionary:
	# Need current meta schema to link
	var mschema: int = int(_S.dget(load_game(slot), "schema_version", _Meta.LATEST_VERSION))
	var rp: String = _run_path(slot)
	if FileAccess.file_exists(rp):
		run = _Run.migrate(_load_json(rp), mschema)
		return run

	# legacy import path (optional)
	var lrp: String = _legacy_run_path(slot)
	if FileAccess.file_exists(lrp):
		_import_legacy_run(slot)
		run = _Run.migrate(_load_json(rp), mschema)
		return run

	# create defaults
	run = _Run.defaults(mschema)
	_save_json(rp, run)
	return run

func save_run(d: Dictionary, slot: int = DEFAULT_SLOT) -> void:
	var mschema: int = int(_S.dget(load_game(slot), "schema_version", _Meta.LATEST_VERSION))
	d["updated_at"] = _S.now_ts()
	run = _Run.migrate(d, mschema)
	_save_json(_run_path(slot), run)

# =========================
# Floor helpers (META)
# =========================
func get_current_floor(slot: int = DEFAULT_SLOT) -> int:
	return int(_S.dget(load_game(slot), "current_floor", 1))

func get_previous_floor(slot: int = DEFAULT_SLOT) -> int:
	return int(_S.dget(load_game(slot), "previous_floor", 0))

func get_last_floor(slot: int = DEFAULT_SLOT) -> int:
	return int(_S.dget(load_game(slot), "last_floor", 1))

func set_current_floor(floor: int, slot: int = DEFAULT_SLOT) -> void:
	var gs: Dictionary = load_game(slot)
	var cur: int = int(_S.dget(gs, "current_floor", 1))
	if cur != floor:
		gs["previous_floor"] = cur
		gs["current_floor"] = max(1, floor)
		if int(gs["current_floor"]) > int(_S.dget(gs, "last_floor", 1)):
			gs["last_floor"] = int(gs["current_floor"])
	save_game(gs, slot)

func change_floor(delta: int, slot: int = DEFAULT_SLOT) -> int:
	var gs: Dictionary = load_game(slot)
	var cur: int = int(_S.dget(gs, "current_floor", 1))
	var nf: int = max(1, cur + delta)
	gs["previous_floor"] = cur
	gs["current_floor"] = nf
	if nf > int(_S.dget(gs, "last_floor", 1)):
		gs["last_floor"] = nf
	save_game(gs, slot)
	return nf

# ---------- Seeds ----------
func get_or_create_seed(floor: int, slot: int = DEFAULT_SLOT) -> int:
	# Kept for compat; you can ignore if deriving per-run/floor
	var gs: Dictionary = load_game(slot)
	var seeds_any: Variant = _S.dget(gs, "floor_seeds", {})
	var seeds: Dictionary = (seeds_any as Dictionary) if seeds_any is Dictionary else {}
	if seeds.has(floor):
		return int(seeds[floor])
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var s: int = int(rng.randi())
	seeds[floor] = s
	gs["floor_seeds"] = seeds
	save_game(gs, slot)
	return s

# =========================
# Run bridging helpers
# =========================
func peek_run_depth(slot: int = DEFAULT_SLOT) -> int:
	return int(_S.dget(load_run(slot), "depth", 1))

func set_run_floor(target_floor: int, slot: int = DEFAULT_SLOT) -> void:
	var rs: Dictionary = load_run(slot)
	rs["depth"] = max(1, target_floor)
	save_run(rs, slot)
	# mirror to meta for menu/UI
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

# =========================
# Session lifecycle
# =========================
func start_new_run(slot: int = DEFAULT_SLOT, clear_seeds: bool = true) -> void:
	delete_run(slot)
	var gs: Dictionary = load_game(slot)

	# Reset floor position to start
	gs["previous_floor"] = 0
	gs["current_floor"] = 1
	gs["last_floor"] = max(1, int(_S.dget(gs, "last_floor", 1)))
	if clear_seeds:
		gs["floor_seeds"] = {}
	save_game(gs, slot)

	# Build run snapshot from META (Option B)
	var pl: Dictionary = (_S.dget(gs, "player", {}) as Dictionary) if _S.dget(gs, "player", {}) is Dictionary else {}
	var sb: Dictionary = (_S.dget(pl, "stat_block", {}) as Dictionary) if _S.dget(pl, "stat_block", {}) is Dictionary else {}
	var attrs: Dictionary = (_S.dget(sb, "attributes", {}) as Dictionary) if _S.dget(sb, "attributes", {}) is Dictionary else {}

	var stats: Dictionary = {
		"STR": float(_S.dget(attrs, "STR", 8.0)),
		"AGI": float(_S.dget(attrs, "AGI", 8.0)),
		"DEX": float(_S.dget(attrs, "DEX", 8.0)),
		"END": float(_S.dget(attrs, "END", 8.0)),
		"INT": float(_S.dget(attrs, "INT", 8.0)),
		"WIS": float(_S.dget(attrs, "WIS", 8.0)),
		"CHA": float(_S.dget(attrs, "CHA", 8.0)),
		"LCK": float(_S.dget(attrs, "LCK", 8.0)),
	}

	var rs: Dictionary = _Run.defaults(int(_S.dget(gs, "schema_version", _Meta.LATEST_VERSION)))
	# Derived pools from stats
	rs["hp_max"] = _Derive.hp_max(stats, {})
	rs["hp"]     = rs["hp_max"]
	rs["mp_max"] = _Derive.mp_max(stats, {})
	rs["mp"]     = rs["mp_max"]
	rs["stam_max"] = _Derive.stam_max(stats, {}) # simple END/AGI mix, see DerivedCalc
	rs["stam"]     = rs["stam_max"]
	# Snapshot inventory & equipment
	var inv_any: Variant = _S.dget(pl, "inventory", [])
	rs["inventory"] = (inv_any as Array).duplicate(true) if inv_any is Array else []
	var lo: Dictionary = (_S.dget(pl, "loadout", {}) as Dictionary) if _S.dget(pl, "loadout", {}) is Dictionary else {}
	var eq: Dictionary = (_S.dget(lo, "equipment", {}) as Dictionary) if _S.dget(lo, "equipment", {}) is Dictionary else {}
	rs["equipment"] = eq.duplicate(true)
	rs["weapon_tags"] = _S.to_string_array(_S.dget(lo, "weapon_tags", []))

	# Reset session state
	rs["buffs"] = []
	rs["effects"] = []
	rs["action_xp_delta"] = {}

	apply_dict_to_runstate(rs)
	save_run(rs, slot)

# Commit RUN snapshot into META (called on labyrinth exit or defeat)
func commit_run_to_meta(defeated: bool = false, slot: int = DEFAULT_SLOT) -> void:
	var gs: Dictionary = load_game(slot)
	var rs: Dictionary = load_run(slot)

	# Reconcile inventory + equipment (RUN is source of truth for the session)
	var pl: Dictionary = (_S.dget(gs, "player", {}) as Dictionary) if _S.dget(gs, "player", {}) is Dictionary else {}
	pl["inventory"] = (_S.dget(rs, "inventory", []) as Array) if _S.dget(rs, "inventory", []) is Array else []
	var lo: Dictionary = (_S.dget(pl, "loadout", {}) as Dictionary) if _S.dget(pl, "loadout", {}) is Dictionary else {}
	lo["equipment"] = (_S.dget(rs, "equipment", {}) as Dictionary) if _S.dget(rs, "equipment", {}) is Dictionary else {}
	lo["weapon_tags"] = _S.to_string_array(_S.dget(rs, "weapon_tags", []))
	pl["loadout"] = lo

	# Apply action mastery deltas into META skills
	var delta_any: Variant = _S.dget(rs, "action_xp_delta", {})
	var delta: Dictionary = (delta_any as Dictionary) if delta_any is Dictionary else {}
	if not pl.has("skills"):
		pl["skills"] = []
	var skills: Array = (pl["skills"] as Array) if pl["skills"] is Array else []
	# Build quick index by id
	var idx: Dictionary = {}
	for i in range(skills.size()):
		if skills[i] is Dictionary:
			var sid := String(_S.dget(skills[i], "id", ""))
			if not sid.is_empty():
				idx[sid] = i

	for k in delta.keys():
		var id: String = String(k)
		var xp_add: int = int(_S.dget(delta[k], "xp_delta", 0))
		if xp_add <= 0:
			continue
		if idx.has(id):
			var sd: Dictionary = skills[int(idx[id])]
			var cur: int = int(_S.dget(sd, "xp_current", int(_S.dget(sd, "xp", 0))))
			var need: int = int(_S.dget(sd, "xp_needed", 90))
			var lvl: int = int(_S.dget(sd, "level", 1))
			var cap: int = int(_S.dget(sd, "cap", 10))
			# Simple apply: carryover across levels w/ cap check
			var xp_new: int = cur + xp_add
			while xp_new >= need and lvl < cap:
				xp_new -= need
				lvl += 1
				# xp_needed progression policy: your shared curve; keep as-is here
				need = int(round(90.0 * pow(1.13, float(lvl - 1))))
			sd["level"] = lvl
			sd["xp_current"] = xp_new
			sd["xp_needed"] = need
			skills[int(idx[id])] = sd
		else:
			# new line with initial xp
			var lvl := 1
			var need := int(round(90.0 * pow(1.13, float(lvl - 1))))
			var xp_cur := xp_add
			while xp_cur >= need:
				xp_cur -= need
				lvl += 1
				need = int(round(90.0 * pow(1.13, float(lvl - 1))))
			skills.append({
				"id": id, "level": lvl,
				"xp_current": xp_cur, "xp_needed": need,
				"cap": 10, "milestones_claimed": [0]
			})
	pl["skills"] = skills

	# On defeat: current design = lose progress only (no player level drop), skills reset to highest-claimed
	if defeated:
		var sb: Dictionary = (_S.dget(pl, "stat_block", {}) as Dictionary) if _S.dget(pl, "stat_block", {}) is Dictionary else {}
		# Player: lose progress toward level
		sb["xp_current"] = 0
		pl["stat_block"] = sb
		# Skills: set level back to highest-claimed (we don't track per-skill claimed separately yet; keep current level) + zero progress
		for i in range(skills.size()):
			if not (skills[i] is Dictionary):
				continue
			var sd: Dictionary = skills[i]
			# If you later add highest_claimed_level per skill, snap here; for now, drop xp_current only
			sd["xp_current"] = 0
			skills[i] = sd
		pl["skills"] = skills

	gs["player"] = pl
	save_game(gs, slot)

# =========================
# Progression / Death Penalty (META)
# =========================
func claim_character_level(new_level: int, slot: int = DEFAULT_SLOT) -> void:
	var gs: Dictionary = load_game(slot)
	var pl: Dictionary = (_S.dget(gs, "player", {}) as Dictionary) if _S.dget(gs, "player", {}) is Dictionary else {}
	var sb: Dictionary = (_S.dget(pl, "stat_block", {}) as Dictionary) if _S.dget(pl, "stat_block", {}) is Dictionary else {}

	var cur: int = int(_S.dget(sb, "level", 1))
	if new_level > cur:
		sb["level"] = new_level
		# Reset xp_current for the new level; recompute xp_needed
		sb["xp_current"] = 0
		sb["xp_needed"] = int(round(90.0 * pow(1.13, float(new_level - 1))))

	# Anti double-dip mirrors
	var h_meta: int = int(_S.dget(gs, "highest_claimed_level", 1))
	if new_level > h_meta:
		gs["highest_claimed_level"] = new_level

	pl["stat_block"] = sb
	gs["player"] = pl
	save_game(gs, slot)

func claim_skill_level(skill_id: String, new_level: int, slot: int = DEFAULT_SLOT) -> void:
	var gs: Dictionary = load_game(slot)
	var pl: Dictionary = (_S.dget(gs, "player", {}) as Dictionary) if _S.dget(gs, "player", {}) is Dictionary else {}
	var skills_any: Variant = _S.dget(pl, "skills", [])
	var skills: Array = (skills_any as Array) if skills_any is Array else []
	var found: bool = false
	for i in range(skills.size()):
		if not (skills[i] is Dictionary):
			continue
		var sd: Dictionary = skills[i]
		if String(_S.dget(sd, "id", "")) != skill_id:
			continue
		found = true
		var cur: int = int(_S.dget(sd, "level", 1))
		if new_level > cur:
			sd["level"] = new_level
			sd["xp_current"] = 0
			sd["xp_needed"] = int(round(90.0 * pow(1.13, float(new_level - 1))))
		skills[i] = sd
	if not found:
		var need := int(round(90.0 * pow(1.13, 0.0))) # level 1
		skills.append({
			"id": skill_id,
			"level": max(1, new_level),
			"xp_current": 0,
			"xp_needed": need,
			"cap": 10,
			"milestones_claimed": [0],
		})
	pl["skills"] = skills
	gs["player"] = pl
	save_game(gs, slot)

func apply_death_penalties(slot: int = DEFAULT_SLOT) -> void:
	# Current rule per your latest: player loses all progress toward level; skills lose progress toward next level.
	var gs: Dictionary = load_game(slot)
	var pl: Dictionary = (_S.dget(gs, "player", {}) as Dictionary) if _S.dget(gs, "player", {}) is Dictionary else {}
	var sb: Dictionary = (_S.dget(pl, "stat_block", {}) as Dictionary) if _S.dget(pl, "stat_block", {}) is Dictionary else {}

	# Player progress reset
	sb["xp_current"] = 0
	pl["stat_block"] = sb

	# Skills progress reset
	var skills_any: Variant = _S.dget(pl, "skills", [])
	var skills: Array = (skills_any as Array) if skills_any is Array else []
	for i in range(skills.size()):
		if not (skills[i] is Dictionary):
			continue
		var sd: Dictionary = skills[i]
		sd["xp_current"] = 0
		skills[i] = sd
	pl["skills"] = skills

	gs["player"] = pl
	save_game(gs, slot)

# =========================
# Sigil helpers (RUN)
# =========================
func segment_id_for_floor(floor: int) -> int:
	return (max(1, floor) - 1) / 3 + 1

func ensure_sigil_segment_for_floor(floor: int, required_elites: int = 4, slot: int = DEFAULT_SLOT) -> void:
	var seg: int = segment_id_for_floor(floor)
	var rs: Dictionary = load_run(slot)
	var cur_seg: int = int(_S.dget(rs, "sigils_segment_id", 0))
	var req: int = max(1, required_elites)
	if cur_seg != seg:
		rs["sigils_segment_id"] = seg
		rs["sigils_elites_killed_in_segment"] = 0
		rs["sigils_required_elites"] = req
		rs["sigils_charged"] = false
	else:
		if not rs.has("sigils_required_elites"):
			rs["sigils_required_elites"] = req
		if not rs.has("sigils_elites_killed_in_segment"):
			rs["sigils_elites_killed_in_segment"] = 0
		if not rs.has("sigils_charged"):
			rs["sigils_charged"] = false
	save_run(rs, slot)

func notify_elite_killed(slot: int = DEFAULT_SLOT) -> void:
	var rs: Dictionary = load_run(slot)
	var kills: int = int(_S.dget(rs, "sigils_elites_killed_in_segment", 0)) + 1
	rs["sigils_elites_killed_in_segment"] = kills
	var req: int = max(1, int(_S.dget(rs, "sigils_required_elites", 4)))
	if kills >= req:
		rs["sigils_charged"] = true
	save_run(rs, slot)

func is_sigil_charged(slot: int = DEFAULT_SLOT) -> bool:
	var rs: Dictionary = load_run(slot)
	return bool(_S.dget(rs, "sigils_charged", false))

func consume_sigil_charge(slot: int = DEFAULT_SLOT) -> void:
	var rs: Dictionary = load_run(slot)
	rs["sigils_charged"] = false
	rs["sigils_elites_killed_in_segment"] = 0
	save_run(rs, slot)

# =========================
# Bridge RunState <-> JSON dict
# (kept minimal/compatible; extended fields live only in RUN json)
# =========================
func runstate_to_dict() -> Dictionary:
	var schema_meta: int = int(_S.dget(load_game(), "schema_version", _Meta.LATEST_VERSION))
	var items_out: Array[String] = []
	for s in RunState.items:
		items_out.append(String(s))
	return {
		"schema_version": _Run.LATEST_VERSION,
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
	RunState.run_seed = int(_S.dget(r, "run_seed", 0))
	RunState.depth    = int(_S.dget(r, "depth", 1))
	RunState.hp_max   = int(_S.dget(r, "hp_max", 30))
	RunState.hp       = int(_S.dget(r, "hp", RunState.hp_max))
	RunState.mp_max   = int(_S.dget(r, "mp_max", 10))
	RunState.mp       = int(_S.dget(r, "mp", RunState.mp_max))
	RunState.gold     = int(_S.dget(r, "gold", 0))

	var items_any: Variant = _S.dget(r, "items", [])
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
	var gs_dict: Dictionary = _Meta.defaults()
	if res.has_method("get"):
		gs_dict["last_floor"] = int(res.get("last_floor"))
		gs_dict["current_floor"] = int(res.get("current_floor"))
		gs_dict["previous_floor"] = int(res.get("previous_floor"))
		var fs_any: Variant = res.get("floor_seeds")
		if fs_any is Dictionary:
			var out_d: Dictionary = {}
			for k in (fs_any as Dictionary).keys():
				out_d[int(k)] = int((fs_any as Dictionary)[k])
			gs_dict["floor_seeds"] = out_d
	_save_json(_meta_path(slot), _Meta.migrate(gs_dict))

func _import_legacy_run(slot: int) -> void:
	var legacy_path: String = _legacy_run_path(slot)
	var res: Resource = ResourceLoader.load(legacy_path)
	if res == null:
		return
	var mschema: int = int(_S.dget(load_game(slot), "schema_version", _Meta.LATEST_VERSION))
	var rs_dict: Dictionary = _Run.defaults(mschema)
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
	_save_json(_run_path(slot), _Run.migrate(rs_dict, mschema))

# =========================
# Debug helper
# =========================
func debug_print_presence(slot: int = DEFAULT_SLOT) -> void:
	var mp: String = _meta_path(slot)
	var rp: String = _run_path(slot)
	print("[SAVE] meta_exists=", FileAccess.file_exists(mp),
		" run_exists=", FileAccess.file_exists(rp),
		" | meta=", mp, " run=", rp)

# -------------------------------------------------
# Inventory helpers (META – kept for out-of-run changes)
# -------------------------------------------------
func _inv_get(gs: Dictionary) -> Array:
	var pl_any: Variant = _S.dget(gs, "player", {})
	var pl: Dictionary = (pl_any as Dictionary) if pl_any is Dictionary else {}
	var inv_any: Variant = _S.dget(pl, "inventory", [])
	return (inv_any as Array) if inv_any is Array else []

func _inv_set(gs: Dictionary, inv: Array) -> void:
	var pl_any: Variant = _S.dget(gs, "player", {})
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

# NOTE: The following inv_* helpers manipulate META inventory.
# During a RUN, prefer editing run["inventory"] instead (snapshot).
func inv_add(item_id: String, count: int = 1, opts: Dictionary = {}, slot: int = DEFAULT_SLOT) -> void:
	var gs: Dictionary = load_game(slot)
	var inv: Array = _inv_get(gs)

	var ilvl: int = int(_S.dget(opts, "ilvl", int(_S.dget(gs, "current_floor", 1))))
	var archetype: String = String(_S.dget(opts, "archetype", "Light"))
	var rarity: String = String(_S.dget(opts, "rarity", "Common"))
	var aff_in: Variant = _S.dget(opts, "affixes", [])
	var aff: Array = []
	if aff_in is Array:
		for a in (aff_in as Array):
			aff.append(String(a))
	var dmax: int = int(_S.dget(opts, "durability_max", 0))
	var dcur: int = int(_S.dget(opts, "durability_current", dmax))
	var weight: float = float(_S.dget(opts, "weight", 1.0))

	if dmax <= 0:
		# Stackable
		var idx: int = -1
		for i in range(inv.size()):
			if not (inv[i] is Dictionary):
				continue
			var it: Dictionary = inv[i]
			if String(_S.dget(it, "id", "")) == item_id \
			and int(_S.dget(it, "ilvl", ilvl)) == ilvl \
			and String(_S.dget(it, "archetype", "")) == archetype \
			and String(_S.dget(it, "rarity", "")) == rarity \
			and _affix_equal(_S.dget(it, "affixes", []), aff) \
			and int(_S.dget(it, "durability_max", 0)) == 0:
				idx = i
				break
		if idx >= 0:
			var st: Dictionary = inv[idx]
			st["count"] = int(_S.dget(st, "count", 1)) + max(1, count)
			inv[idx] = st
		else:
			inv.append({
				"id": item_id, "count": max(1, count),
				"ilvl": ilvl, "archetype": archetype, "rarity": rarity,
				"affixes": aff, "durability_max": 0, "durability_current": 0, "weight": weight
			})
	else:
		# Non-stackable (assign uid)
		var n: int = max(1, count)
		for _i in range(n):
			var uid: String = _Meta._gen_uid()
			inv.append({
				"id": item_id, "count": 1,
				"ilvl": ilvl, "archetype": archetype, "rarity": rarity,
				"affixes": aff, "durability_max": dmax, "durability_current": dcur, "weight": weight,
				"uid": uid
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
		var dmax: int = int(_S.dget(it, "durability_max", 0))
		if dmax > 0:
			inv.remove_at(index)
		else:
			var c: int = int(_S.dget(it, "count", 1))
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
	var dmax: int = int(_S.dget(it, "durability_max", 0))
	if dmax <= 0:
		return -1
	var cur: int = int(_S.dget(it, "durability_current", dmax))
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
		var w: float = float(_S.dget(it, "weight", 1.0))
		var dmax: int = int(_S.dget(it, "durability_max", 0))
		if dmax > 0:
			total += w
		else:
			total += w * float(int(_S.dget(it, "count", 1)))
	return total

# Add this helper near your other privates
func _parse_json_file(p: String) -> Dictionary:
	if not FileAccess.file_exists(p):
		return {}
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {}
	var txt: String = f.get_as_text()
	var j := JSON.new()
	var err: int = j.parse(txt)
	if err != OK:
		return {}
	var data_any: Variant = j.data
	return (data_any as Dictionary) if data_any is Dictionary else {}
