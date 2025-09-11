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
# JSON I/O
# -------------------------------------------------
func _save_json(path: String, data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("SaveManager: cannot open for write: " + path + " (err=" + str(FileAccess.get_open_error()) + ")")
		return
	f.store_string(JSON.stringify(data, "  "))
	f.flush()
	f = null
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
		push_error("SaveManager: JSON parse failed for %s (err=%d, line=%d, msg=%s)" % [
			path, err, j.get_error_line(), j.get_error_message()
		])
		return {}
	var data_any: Variant = j.data
	return (data_any as Dictionary) if data_any is Dictionary else {}

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

func start_new_run(slot: int = DEFAULT_SLOT, clear_seeds: bool = true) -> void:
	delete_run(slot)
	var gs: Dictionary = load_game(slot)
	gs["previous_floor"] = 0
	gs["current_floor"] = 1
	gs["last_floor"] = max(1, int(_S.dget(gs, "last_floor", 1)))
	if clear_seeds:
		gs["floor_seeds"] = {}
	save_game(gs, slot)
	RunState.new_run()
	save_current_run(slot)

# =========================
# Progression / Death Penalty (META)
# =========================
func claim_character_level(new_level: int, slot: int = DEFAULT_SLOT) -> void:
	var gs: Dictionary = load_game(slot)
	var pl: Dictionary = (_S.dget(gs, "player", {}) as Dictionary) if _S.dget(gs, "player", {}) is Dictionary else {}
	var cur: int = int(_S.dget(pl, "level", 1))
	if new_level > cur:
		pl["level"] = new_level
	# Anti double-dip
	var h_pl: int = int(_S.dget(pl, "highest_claimed_level", 1))
	var h_meta: int = int(_S.dget(gs, "highest_claimed_level", 1))
	if new_level > h_pl:
		pl["highest_claimed_level"] = new_level
	if new_level > h_meta:
		gs["highest_claimed_level"] = new_level
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
		var hc: int = int(_S.dget(sd, "highest_claimed_level", 1))
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
	var p: Dictionary = (_S.dget(gs, "penalties", {}) as Dictionary) if _S.dget(gs, "penalties", {}) is Dictionary else {}
	var pl: Dictionary = (_S.dget(gs, "player", {}) as Dictionary) if _S.dget(gs, "player", {}) is Dictionary else {}

	# Character
	var level: int = int(_S.dget(pl, "level", 1))
	var hc_pl: int = int(_S.dget(pl, "highest_claimed_level", level))
	var lvl_pct: float = float(_S.dget(p, "level_pct", 0.10))
	var floor_lvl: int = int(_S.dget(p, "floor_at_level", 1))
	var level_loss: int = int(round(level * lvl_pct))
	var new_level: int = max(level - level_loss, floor_lvl, hc_pl)
	pl["level"] = new_level

	# Skills
	var skills_any: Variant = _S.dget(pl, "skills", [])
	var skills: Array = (skills_any as Array) if skills_any is Array else []
	var xp_pct: float = float(_S.dget(p, "skill_xp_pct", 0.15))
	var floor_skill: int = int(_S.dget(p, "floor_at_skill_level", 1))
	for i in range(skills.size()):
		if not (skills[i] is Dictionary):
			continue
		var sd: Dictionary = skills[i]
		var xp: int = int(_S.dget(sd, "xp", 0))
		var xp_loss: int = int(round(float(xp) * xp_pct))
		sd["xp"] = max(0, xp - xp_loss)
		var lvl: int = int(_S.dget(sd, "level", 1))
		var hc: int = int(_S.dget(sd, "highest_claimed_level", lvl))
		if lvl < floor_skill:
			lvl = floor_skill
		if lvl < hc:
			lvl = hc
		sd["level"] = lvl
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
# Inventory helpers (temporary, will move to InventoryService soon)
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
		# Non-stackable
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
