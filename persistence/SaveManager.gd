extends Node


const DEFAULT_SLOT: int = 1

const _S         := preload("res://persistence/util/save_utils.gd")
const _Meta      := preload("res://persistence/schemas/meta_schema.gd")
const _RunSchema := preload("res://persistence/schemas/run_schema.gd")
const _ExitFlow  := preload("res://persistence/flows/ExitSafelyFlow.gd")
const _DefeatFlow:= preload("res://persistence/flows/DefeatFlow.gd")
const _Derived   := preload("res://scripts/combat/derive/DerivedCalc.gd")
const _XpTuning  := preload("res://scripts/rewards/XpTuning.gd")
const _Prog := preload("res://persistence/services/progression_service.gd")

# ------------ Storage paths ------------
static func _meta_path(slot: int) -> String:
	return "user://saves/slot_%d_meta.json" % int(slot)

static func _run_path(slot: int) -> String:
	return "user://saves/slot_%d_run.json" % int(slot)

# ------------ Presence / debug ------------
static func debug_print_presence(slot: int = DEFAULT_SLOT) -> void:
	var mp := _meta_path(slot)
	var rp := _run_path(slot)
	print("[SaveManager] presence: meta=", FileAccess.file_exists(mp), " (", mp, ")",
		" run=", FileAccess.file_exists(rp), " (", rp, ")")

# ------------ Basic IO ------------
static func load_game(slot: int = DEFAULT_SLOT) -> Dictionary:
	var p := _meta_path(slot)
	if not FileAccess.file_exists(p):
		var d := _Meta.defaults()
		save_game(d, slot)
		return d
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return _Meta.defaults()
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	var d: Dictionary = _S.to_dict(parsed)
	return _Meta.migrate(d)

static func save_game(d_in: Dictionary, slot: int = DEFAULT_SLOT) -> void:
	var d := d_in.duplicate(true)
	var p := _meta_path(slot)
	DirAccess.make_dir_recursive_absolute("user://saves")
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(d, "\t"))

static func load_run(slot: int = DEFAULT_SLOT) -> Dictionary:
	var p := _run_path(slot)
	if not FileAccess.file_exists(p):
		var meta := load_game(slot)
		var fresh := _mirror_meta_to_new_run(meta)
		save_run(fresh, slot)
		return fresh
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		var meta2 := load_game(slot)
		var fresh2 := _mirror_meta_to_new_run(meta2)
		save_run(fresh2, slot)
		return fresh2
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	var d: Dictionary = _S.to_dict(parsed)
	# migrate to current run schema (we pass meta schema version but it isn't used here)
	return _RunSchema.migrate(d, int(_S.dget(load_game(slot), "schema_version", 1)))

static func save_run(d_in: Dictionary, slot: int = DEFAULT_SLOT) -> void:
	var d := d_in.duplicate(true)
	var p := _run_path(slot)
	DirAccess.make_dir_recursive_absolute("user://saves")
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(d, "\t"))

static func delete_run(slot: int = DEFAULT_SLOT) -> void:
	var p := _run_path(slot)
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)

# ------------ Small helpers used around codebase ------------
static func run_exists(slot: int = DEFAULT_SLOT) -> bool:
	return FileAccess.file_exists(_run_path(slot))

static func peek_run_depth(slot: int = DEFAULT_SLOT) -> int:
	var rs := load_run(slot)
	return int(_S.dget(rs, "depth", 1))

static func get_current_floor(slot: int = DEFAULT_SLOT) -> int:
	var gs := load_game(slot)
	return int(_S.dget(gs, "current_floor", 1))

static func set_run_floor(depth: int, slot: int = DEFAULT_SLOT) -> void:
	var rs := load_run(slot)
	rs["depth"] = int(depth)
	var far := int(_S.dget(rs, "furthest_depth_reached", int(depth)))
	if depth > far:
		rs["furthest_depth_reached"] = depth
	save_run(rs, slot)

static func get_run_seed(slot: int = DEFAULT_SLOT) -> int:
	var rs := load_run(slot)
	return int(_S.dget(rs, "run_seed", 0))

# No-op compatibility stub used by LevelManager
static func ensure_sigil_segment_for_floor(_floor: int, _segment_size: int) -> void:
	pass

# ------------ Public flows ------------
# Old call-site compatibility: GameMenu.gd calls commit_run_to_meta(safe_exit, slot)
static func commit_run_to_meta(safe_exit: bool, slot: int = DEFAULT_SLOT) -> void:
	if safe_exit:
		_ExitFlow.execute(slot)
	else:
		_DefeatFlow.execute(slot)

# Explicit convenience wrappers
static func exit_safely(slot: int = DEFAULT_SLOT) -> void:
	_ExitFlow.execute(slot)

static func end_run_defeat(slot: int = DEFAULT_SLOT) -> void:
	_DefeatFlow.execute(slot)

# Start (or repair) a run by mirroring META → RUN
static func start_or_refresh_run_from_meta(slot: int = DEFAULT_SLOT) -> Dictionary:
	var meta := load_game(slot)
	var merged := _mirror_meta_to_new_run(meta)
	save_run(merged, slot)
	return merged

# ------------ Character XP IN RUN (used by rewards) ------------
# SaveManager.gd
static func run_award_character_xp(amount: int, slot: int = DEFAULT_SLOT) -> Dictionary:
	var add: int = max(0, amount)
	if add <= 0:
		# Return a stable empty shape so callers can safely .get(...)
		return { "level": 0, "xp_current": 0, "xp_needed": 0, "points_added": 0, "points_unspent": int(_S.dget(load_run(slot), "points_unspent", 0)) }

	# Load current RUN snapshot
	var rs := load_run(slot)
	var sb: Dictionary = _S.to_dict(_S.dget(rs, "player_stat_block", {}))

	var lvl: int = int(_S.dget(sb, "level", 1))
	var cur: int = int(_S.dget(sb, "xp_current", 0))
	var need: int = int(_S.dget(sb, "xp_needed", _XpTuning.xp_to_next(lvl)))

	# Add and roll levels
	var levels_gained: int = 0
	cur += add
	while cur >= need:
		cur -= need
		lvl += 1
		levels_gained += 1
		need = _XpTuning.xp_to_next(lvl)

	# Compute new run points (but DO NOT save here)
	var prev_run_points: int = int(_S.dget(rs, "points_unspent", 0))
	var points_gain: int = levels_gained * 2
	var rs_points: int = prev_run_points + points_gain

	return {
		"level": lvl,
		"xp_current": cur,
		"xp_needed": need,
		"points_added": points_gain,
		"points_unspent": rs_points
	}




# ------------ Skill XP IN RUN (used by ability xp + loot) ------------
static func apply_skill_xp_to_run(ability_id: String, add_xp: int, slot: int = DEFAULT_SLOT) -> Dictionary:
	var aid := String(ability_id)
	if aid == "" or add_xp <= 0:
		return {}

	var rs := load_run(slot)
	var st_all: Dictionary = _S.to_dict(_S.dget(rs, "skill_tracks", {}))
	var row: Dictionary = _S.to_dict(_S.dget(st_all, aid, {}))

	# Backfill from META snapshot if missing
	if row.is_empty():
		var gs := load_game(slot)
		var pl := _S.to_dict(_S.dget(gs, "player", {}))
		var mt_all := _S.to_dict(_S.dget(pl, "skill_tracks", {}))
		var mrow := _S.to_dict(_S.dget(mt_all, aid, {}))
		if mrow.is_empty():
			mrow = {
				"level": 1,
				"xp_current": 0,
				"xp_needed": _XpTuning.xp_to_next(1),
				"cap_band": 10,
				"unlocked": false,
				"last_milestone_applied": 0
			}
		row = mrow.duplicate(true)

	var lvl := int(_S.dget(row, "level", 1))
	var cur := int(_S.dget(row, "xp_current", 0))
	var need := int(_S.dget(row, "xp_needed", _XpTuning.xp_to_next(lvl)))
	var cap := int(_S.dget(row, "cap_band", 10))
	var unlocked := bool(_S.dget(row, "unlocked", false))
	var last_ms := int(_S.dget(row, "last_milestone_applied", 0))

	# Suppress if locked or capped
	if (not unlocked) or (lvl >= cap):
		st_all[aid] = row
		rs["skill_tracks"] = st_all
		save_run(rs, slot)
		return row.duplicate(true)

	cur += max(0, add_xp)

	# Level-up loop with milestone stat grants every 5 levels
	var attrs: Dictionary = _S.to_dict(_S.dget(rs, "player_attributes", {}))
	while (lvl < cap) and (cur >= need):
		cur -= need
		lvl += 1
		need = _XpTuning.xp_to_next(lvl)

		# Apply milestone grant at L5,10,15,... once each
		if (lvl % 5 == 0) and (lvl > last_ms):
			var bias: Dictionary = _Prog._stat_bias_for(aid)  # {STR:.., END:.., ...} sums to 10
			for k in bias.keys():
				attrs[k] = int(_S.dget(attrs, k, 0)) + int(bias[k])
			last_ms = lvl

	# Persist updated attrs (and recompute pools if any stat changed)
	rs["player_attributes"] = attrs
	# Recompute pools to reflect new stats immediately
	var hp_max := _Derived.hp_max(attrs, {})
	var mp_max := _Derived.mp_max(attrs, {})
	var stam_max := _Derived.stam_max(attrs, {})
	# Keep current HP/MP/Stam clamped to new max
	rs["hp_max"]   = int(hp_max)
	rs["mp_max"]   = int(mp_max)
	rs["stam_max"] = int(stam_max)
	rs["hp"]   = clampi(int(_S.dget(rs, "hp",   0)), 0, int(hp_max))
	rs["mp"]   = clampi(int(_S.dget(rs, "mp",   0)), 0, int(mp_max))
	rs["stam"] = clampi(int(_S.dget(rs, "stam", 0)), 0, int(stam_max))

	# Write back the skill row
	row["level"] = lvl
	row["xp_current"] = cur
	row["xp_needed"]  = need
	row["last_milestone_applied"] = last_ms
	st_all[aid] = row
	rs["skill_tracks"] = st_all

	save_run(rs, slot)
	return row.duplicate(true)

# ------------ Internals: build a new RUN from META ------------
static func _mirror_meta_to_new_run(gs: Dictionary) -> Dictionary:
	var meta: Dictionary = _Meta.migrate(gs)

	var ts_now: int = _S.now_ts()
	var rs: Dictionary = {
		"schema_version": 4,
		"created_at": float(ts_now),
		"updated_at": ts_now,

		"depth": int(_S.dget(meta, "current_floor", 1)),
		"furthest_depth_reached": int(_S.dget(meta, "highest_floor_reached", 1)),
		"run_seed": _fresh_run_seed(),

		# Pools
		"hp_max": 0, "hp": 0,
		"mp_max": 0, "mp": 0,
		"stam_max": 0, "stam": 0,

		# Currencies + carryables
		"gold": 0,
		"shards": 0,
		"inventory": [],
		"equipment": {
			"head": null, "chest": null, "legs": null, "boots": null,
			"mainhand": null, "offhand": null, "ring1": null, "ring2": null, "amulet": null
		},
		"equipped_bank": {},              # <--- important
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

	# META bits
	var pl_meta: Dictionary = _S.to_dict(_S.dget(meta, "player", {}))
	var sb_meta: Dictionary = _S.to_dict(_S.dget(pl_meta, "stat_block", {}))
	var attrs_meta: Dictionary = _S.to_dict(_S.dget(sb_meta, "attributes", {}))
	var lo_meta: Dictionary = _S.to_dict(_S.dget(pl_meta, "loadout", {}))
	var eq_meta: Dictionary = _S.to_dict(_S.dget(lo_meta, "equipment", {}))
	var tracks_meta: Dictionary = _S.to_dict(_S.dget(pl_meta, "skill_tracks", {}))

	# Attributes -> RUN + pools
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

	# Currencies (policy: copy on-hand)
	rs["gold"]   = int(_S.dget(pl_meta, "onhand_gold", 0))
	rs["shards"] = int(_S.dget(pl_meta, "onhand_shards", 0))

	# Inventory (deep copy; coerce ints)
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
			inv_out.append(it)
	rs["inventory"] = inv_out

	# Equipment + tags
	var eq_norm: Dictionary = {
		"head": null, "chest": null, "legs": null, "boots": null,
		"mainhand": null, "offhand": null, "ring1": null, "ring2": null, "amulet": null
	}
	for k in eq_norm.keys():
		eq_norm[k] = eq_meta.get(k, null)
	rs["equipment"] = eq_norm
	rs["weapon_tags"] = _S.to_string_array(_S.dget(lo_meta, "weapon_tags", []))

	# Build equipped_bank by matching uids in eq to items in inventory; remove matched from inv
	var bank: Dictionary = {}
	if not inv_out.is_empty():
		var keep: Array = []
		for it_any2 in inv_out:
			if not (it_any2 is Dictionary):
				continue
			var row: Dictionary = it_any2
			var uid_str: String = String(_S.dget(row, "uid", ""))
			var is_equipped: bool = false
			if not uid_str.is_empty():
				for sk in eq_norm.keys():
					var slot_uid_any: Variant = eq_norm[sk]
					if slot_uid_any != null and String(slot_uid_any) == uid_str:
						is_equipped = true
						break
			if is_equipped:
				bank[uid_str] = row
			else:
				keep.append(row)
		rs["inventory"] = keep
	rs["equipped_bank"] = bank

	# Character XP snapshot
	var lvl_i: int = int(_S.dget(sb_meta, "level", 1))
	rs["player_stat_block"] = {
		"level": lvl_i,
		"xp_current": int(_S.dget(sb_meta, "xp_current", 0)),
		"xp_needed": int(_S.dget(sb_meta, "xp_needed", _XpTuning.xp_to_next(lvl_i))),
	}

	# Skills mirror
	var st_out: Dictionary = {}
	for id_any in tracks_meta.keys():
		var rowm := _S.to_dict(tracks_meta[id_any])
		var rlvl := int(_S.dget(rowm, "level", 1))
		st_out[String(id_any)] = {
			"level": max(1, rlvl),
			"xp_current": int(_S.dget(rowm, "xp_current", 0)),
			"xp_needed": int(_S.dget(rowm, "xp_needed", _XpTuning.xp_to_next(rlvl))),
			"cap_band": int(_S.dget(rowm, "cap_band", 10)),
			"unlocked": bool(_S.dget(rowm, "unlocked", false)),
			"last_milestone_applied": int(_S.dget(rowm, "last_milestone_applied", 0))
		}
	rs["skill_tracks"] = st_out

	return rs


static func _fresh_run_seed() -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	# 64-bit-ish mix
	var a := int(Time.get_ticks_usec())
	var b := rng.randi()
	return int((int(a) << 32) | int(b & 0xFFFFFFFF))

static func exists(slot: int = DEFAULT_SLOT) -> bool:
	# "Does a META save file exist?"
	return FileAccess.file_exists(_meta_path(slot))

static func meta_exists(slot: int = DEFAULT_SLOT) -> bool:
	# Alias with a clearer name (optional)
	return FileAccess.file_exists(_meta_path(slot))
