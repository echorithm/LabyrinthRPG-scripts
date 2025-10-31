# res://persistence/SaveManager.gd
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
const _VillageSave := preload("res://scripts/village/persistence/village_save_utils.gd")
const _NPCGen := preload("res://scripts/village/persistence/npc_generator.gd")
const _NPCSchema := preload("res://scripts/village/persistence/schemas/npc_instance_schema.gd")

const NPC_ARCHETYPES_PATH := "res://data/village/npc_archetypes.json" # legacy roleful gen (kept)
const RECRUITMENT_NAMES_PATH := "res://data/village/recruitment_names.json" # NEW: role-agnostic names

const HIRE_COST_GOLD: int = 100 # per MVP one-pager

static var DEBUG_NPC: bool = true
static func _npc_dbg(msg: String) -> void:
	if DEBUG_NPC:
		print("[SaveManager/NPC] " + msg)

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
		print("[%s][SaveManager.load_run] MISS -> mirror-from-META slot=%d path=%s" % [_ts(), slot, p])

		var d := _Meta.defaults()
		save_game(d, slot)
		return d
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return _Meta.defaults()
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	var d: Dictionary = _S.to_dict(parsed)
	var mig := _Meta.migrate(d)
	# Persist migrations so new tracks (e.g., punch/rest/meditate/cyclone) stick
	if mig != d:
		save_game(mig, slot)
	return mig

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
static func run_award_character_xp(amount: int, slot: int = DEFAULT_SLOT) -> Dictionary:
	var add: int = max(0, amount)
	if add <= 0:
		return { "level": 0, "xp_current": 0, "xp_needed": 0, "points_added": 0, "points_unspent": int(_S.dget(load_run(slot), "points_unspent", 0)) }

	var rs := load_run(slot)
	var sb: Dictionary = _S.to_dict(_S.dget(rs, "player_stat_block", {}))

	var lvl: int = int(_S.dget(sb, "level", 1))
	var cur: int = int(_S.dget(sb, "xp_current", 0))
	var need: int = int(_S.dget(sb, "xp_needed", _XpTuning.xp_to_next(lvl)))

	var levels_gained := 0
	cur += add
	while cur >= need:
		cur -= need
		lvl += 1
		levels_gained += 1
		need = _XpTuning.xp_to_next(lvl)

	# ✅ persist into RUN
	sb["level"] = lvl
	sb["xp_current"] = cur
	sb["xp_needed"]  = need
	rs["player_stat_block"] = sb

	var prev_points: int = int(_S.dget(rs, "points_unspent", 0))
	var points_gain: int = levels_gained * 2
	rs["points_unspent"] = prev_points + points_gain

	save_run(rs, slot)  # ✅ actually save it

	return {
		"level": lvl,
		"xp_current": cur,
		"xp_needed": need,
		"points_added": points_gain,
		"points_unspent": int(rs["points_unspent"])
	}

# ------------ Skill XP IN RUN (used by ability xp + loot) ------------
static func apply_skill_xp_to_run(ability_id: String, add_xp: int, slot: int = DEFAULT_SLOT) -> Dictionary:
	var aid: String = String(ability_id)
	if aid.is_empty() or add_xp <= 0:
		return {}

	var rs: Dictionary = load_run(slot)
	var st_all: Dictionary = _S.to_dict(_S.dget(rs, "skill_tracks", {}))
	var row: Dictionary = _S.to_dict(_S.dget(st_all, aid, {}))

	# Backfill from META snapshot if missing
	if row.is_empty():
		var gs: Dictionary = load_game(slot)
		var pl: Dictionary = _S.to_dict(_S.dget(gs, "player", {}))
		var mt_all: Dictionary = _S.to_dict(_S.dget(pl, "skill_tracks", {}))
		var mrow: Dictionary = _S.to_dict(_S.dget(mt_all, aid, {}))
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

	var lvl: int = int(_S.dget(row, "level", 1))
	var cur: int = int(_S.dget(row, "xp_current", 0))
	var need: int = int(_S.dget(row, "xp_needed", _XpTuning.xp_to_next(lvl)))
	var cap: int = int(_S.dget(row, "cap_band", 10))
	var unlocked: bool = bool(_S.dget(row, "unlocked", false))
	var last_ms: int = int(_S.dget(row, "last_milestone_applied", 0))

	# Suppress if locked or capped
	if (not unlocked) or (lvl >= cap):
		st_all[aid] = row
		rs["skill_tracks"] = st_all
		save_run(rs, slot)
		return row.duplicate(true)

	cur += max(0, add_xp)

	# Level-up loop with milestone stat grants every 5 levels
	var attrs: Dictionary = _S.to_dict(_S.dget(rs, "player_attributes", {}))
	var attrs_changed: bool = false

	while (lvl < cap) and (cur >= need):
		cur -= need
		lvl += 1
		need = _XpTuning.xp_to_next(lvl)

		# Apply milestone grant at L5,10,15,... once each
		if (lvl % 5 == 0) and (lvl > last_ms):
			var bias: Dictionary = _Prog._stat_bias_for(aid)  # e.g., {STR:5, END:3, AGI:2}
			var before_attrs: Dictionary = attrs.duplicate(true)
			var sum_applied: int = 0

			for k_any in bias.keys():
				var k: String = String(k_any)
				var add_i: int = int(bias[k_any])
				if add_i != 0:
					attrs[k] = int(_S.dget(attrs, k, 0)) + add_i
					sum_applied += add_i

			# Debug print: shows exactly what happened at milestone time.
			print("[SkillMilestone] aid=", aid, " lvl=", lvl, " bias=", bias, " sum=", sum_applied,
				" attrs_before=", before_attrs, " attrs_after=", attrs)

			if sum_applied != 0:
				attrs_changed = true
			last_ms = lvl

	# Persist updated attrs only if anything changed; then re-derive pools
	if attrs_changed:
		rs["player_attributes"] = attrs

		var hp_max: int = int(_Derived.hp_max(attrs, {}))
		var mp_max: int = int(_Derived.mp_max(attrs, {}))
		var stam_max: int = int(_Derived.stam_max(attrs, {}))

		rs["hp_max"] = hp_max
		rs["mp_max"] = mp_max
		rs["stam_max"] = stam_max

		rs["hp"] = clampi(int(_S.dget(rs, "hp", 0)), 0, hp_max)
		rs["mp"] = clampi(int(_S.dget(rs, "mp", 0)), 0, mp_max)
		rs["stam"] = clampi(int(_S.dget(rs, "stam", 0)), 0, stam_max)

	# Write back the skill row
	row["level"] = lvl
	row["xp_current"] = cur
	row["xp_needed"] = need
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
			# normalize nested opts similarly to RewardService._normalize_item
			if it.has("opts") and it["opts"] is Dictionary:
				var o: Dictionary = (it["opts"] as Dictionary)
				if o.has("ilvl"): o["ilvl"] = int(o["ilvl"])
				if o.has("durability_max"): o["durability_max"] = int(o["durability_max"])
				if o.has("durability_current"): o["durability_current"] = int(o["durability_current"])
				if o.has("weight"): o["weight"] = float(o["weight"])
				it["opts"] = o
			inv_out.append(it)

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
		inv_out = keep
	rs["equipped_bank"] = bank

	# --- NEW: stack the mirrored inventory (non-gear only) ---
	inv_out = _stack_inventory_local(inv_out)
	rs["inventory"] = inv_out

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
	
	print("[%s][SaveManager.mirror] pools hp=%d/%d mp=%d/%d stam=%d/%d gold=%d shards=%d"
	% [_ts(), int(rs.get("hp",0)), int(rs.get("hp_max",0)), int(rs.get("mp",0)), int(rs.get("mp_max",0)), int(rs.get("stam",0)), int(rs.get("stam_max",0)), int(rs.get("gold",0)), int(rs.get("shards",0))])
	



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

	return out

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

# ---------- SaveManager: village section (merge-safe, slot-safe) ----------

# ---------- SaveManager: village section (merge-safe, slot-safe) ----------

static func village_path(slot: int = DEFAULT_SLOT) -> String:
	var _slot: int = max(1, slot)
	return _VillageSave.village_path(_slot)

static func load_village(slot: int = DEFAULT_SLOT) -> Dictionary:
	var _slot: int = max(1, slot)
	return _VillageSave.load_village(_slot)  # ← full shape

# Merge d_in into existing full snapshot on disk (grid and/or other fields)
static func save_village(d_in: Dictionary, slot: int = DEFAULT_SLOT) -> void:
	var _slot: int = max(1, slot)
	var cur := _VillageSave.load_village(_slot)
	var merged := _merge_village(cur, d_in)
	_VillageSave.save_village(merged, _slot)  # ← full writer

# Capture-from-node returns a (grid-only) snapshot; overlay only grid into full save.
static func capture_village_from(node: Node, slot: int = DEFAULT_SLOT) -> Dictionary:
	var _slot: int = max(1, slot)
	var cur := _VillageSave.load_village(_slot)
	var from_node := _VillageSave.write_from_node(node, _slot) # now non-writing
	var grid_any: Variant = from_node.get("grid", {})
	if grid_any is Dictionary:
		cur["grid"] = grid_any
	_VillageSave.save_village(cur, _slot)
	return cur

# Apply-to-node may change the in-memory node; persist only grid returned by apply (if any).
static func apply_village_to(node: Node, slot: int = DEFAULT_SLOT) -> Dictionary:
	var _slot: int = max(1, slot)
	var cur := _VillageSave.load_village(_slot)
	var applied := _VillageSave.apply_to_node(node, _slot) # non-writing; returns dict
	var grid_any: Variant = applied.get("grid", {})
	if grid_any is Dictionary:
		cur["grid"] = grid_any
	_VillageSave.save_village(cur, _slot)
	return cur

# Add/append NPC but keep everything else intact.
static func add_npc_to_village(npc: Dictionary, slot: int = DEFAULT_SLOT) -> Dictionary:
	_npc_dbg("add_npc_to_village slot=%d id=%s role=%s" %
		[slot, String(npc.get("id","")), String(npc.get("role",""))])
	var _slot: int = max(1, slot)
	var snap := _VillageSave.load_snapshot(_slot)
	var npcs_any: Variant = snap.get("npcs", [])
	var npcs: Array = (npcs_any as Array) if (npcs_any is Array) else []
	var typed: Array[Dictionary] = []
	for r in npcs:
		if r is Dictionary: typed.append(r as Dictionary)
	typed.append(npc)
	snap["npcs"] = typed
	_VillageSave.save_snapshot(snap, _slot)
	_npc_dbg("add_npc_to_village done -> count=%d (path=%s)" % [typed.size(), _VillageSave.path(_slot)])
	return snap

static func generate_and_add_npcs_from_archetypes(archetypes_path: String, role: String, levels: Array[int], seed: int, slot: int = DEFAULT_SLOT) -> Array[Dictionary]:
	_npc_dbg("generate_and_add_npcs_from_archetypes role=%s count=%d seed=%d slot=%d" %
		[role, levels.size(), seed, slot])
	var _slot: int = max(1, slot)
	var arch := _NPCGen._read_archetypes(archetypes_path)
	var rows: Array[Dictionary] = _NPCGen.generate_many_from(arch, role, levels, seed)
	if rows.is_empty():
		_npc_dbg("  generated 0")
		return []
	var snap := _VillageSave.load_snapshot(_slot)
	var cur_any: Variant = snap.get("npcs", [])
	var cur: Array = (cur_any as Array) if (cur_any is Array) else []
	var out: Array[Dictionary] = []
	for r in cur:
		if r is Dictionary: out.append(r as Dictionary)
	for row in rows: out.append(row)
	snap["npcs"] = out
	_VillageSave.save_snapshot(snap, _slot)
	_npc_dbg("  appended=%d total_now=%d" % [rows.size(), out.size()])
	return rows

static func generate_weighted_npcs_to_village(archetypes_path: String, total: int, seed: int, slot: int = DEFAULT_SLOT) -> Array[Dictionary]:
	_npc_dbg("generate_weighted_npcs_to_village total=%d seed=%d slot=%d" % [total, seed, slot])
	var _slot: int = max(1, slot)
	var arch := _NPCGen._read_archetypes(archetypes_path)
	var rows: Array[Dictionary] = _NPCGen.generate_weighted_pool(arch, total, seed)
	if rows.is_empty():
		_npc_dbg("  generated 0")
		return []
	var snap := _VillageSave.load_snapshot(_slot)
	var cur_any: Variant = snap.get("npcs", [])
	var cur: Array = (cur_any as Array) if (cur_any is Array) else []
	var out: Array[Dictionary] = []
	for r in cur:
		if r is Dictionary: out.append(r as Dictionary)
	for row in rows: out.append(row)
	snap["npcs"] = out
	_VillageSave.save_snapshot(snap, _slot)
	_npc_dbg("  appended=%d total_now=%d" % [rows.size(), out.size()])
	return rows

static func _village_seed(slot: int) -> int:
	var _slot: int = max(1, slot)
	var snap := _VillageSave.load_snapshot(_slot)
	return int(_S.dget(snap, "seed", 1))

static func _get_recruitment(slot: int) -> Dictionary:
	var _slot: int = max(1, slot)
	# IMPORTANT: read the FULL village save; snapshot schema drops 'recruitment'
	var snap := _VillageSave.load_village(_slot)
	var rec_any: Variant = snap.get("recruitment", {})
	if rec_any is Dictionary:
		var rec: Dictionary = rec_any
		return {
			"cursor": int(rec.get("cursor", 0)),
			"page_size": int(rec.get("page_size", 3)),
			"recruit_last_min_ref": float(rec.get("recruit_last_min_ref", 0.0)),
			"recruit_cadence_min": int(rec.get("recruit_cadence_min", 720))
		}
	# Fallback defaults
	return { "cursor": 0, "page_size": 3, "recruit_last_min_ref": 0.0, "recruit_cadence_min": 720 }


# --- Replace the whole method in SaveManager.gd with this ---
static func _set_recruitment(rec: Dictionary, slot: int) -> void:
	var _slot: int = max(1, slot)
	var snap := _VillageSave.load_village(_slot)

	# Read existing (so we can preserve cadence + last_ref)
	var cur_any: Variant = snap.get("recruitment", {})
	var cur: Dictionary = (cur_any as Dictionary) if (cur_any is Dictionary) else {
		"cursor": 0, "page_size": 3, "recruit_last_min_ref": 0.0, "recruit_cadence_min": 720
	}

	# Merge: only override fields provided in 'rec', preserve others
	var merged := {
		"cursor": int(_S.dget(rec, "cursor", int(_S.dget(cur, "cursor", 0)))),
		"page_size": int(_S.dget(rec, "page_size", int(_S.dget(cur, "page_size", 3)))),
		"recruit_last_min_ref": float(_S.dget(rec, "recruit_last_min_ref", float(_S.dget(cur, "recruit_last_min_ref", 0.0)))),
		"recruit_cadence_min": int(_S.dget(rec, "recruit_cadence_min", int(_S.dget(cur, "recruit_cadence_min", 720))))
	}

	if DEBUG_NPC:
		_npc_dbg("_set_recruitment MERGE slot=%d | before={cursor=%d, page_size=%d, last=%.2f, cad=%d} -> after={cursor=%d, page_size=%d, last=%.2f, cad=%d}" % [
			_slot,
			int(_S.dget(cur, "cursor", 0)),
			int(_S.dget(cur, "page_size", 3)),
			float(_S.dget(cur, "recruit_last_min_ref", 0.0)),
			int(_S.dget(cur, "recruit_cadence_min", 720)),
			int(_S.dget(merged, "cursor", 0)),
			int(_S.dget(merged, "page_size", 3)),
			float(_S.dget(merged, "recruit_last_min_ref", 0.0)),
			int(_S.dget(merged, "recruit_cadence_min", 720))
		])

	snap["recruitment"] = merged
	_VillageSave.save_village(snap, _slot)

# ---- merge utility -----------------------------------------------------------
# Merge 'incoming' into 'base' without dropping sections not present in incoming.
# Also normalizes some known shapes.
static func _merge_village(base: Dictionary, incoming: Dictionary) -> Dictionary:
	var out := {} as Dictionary

	# Start with base (what’s already on disk)
	for k in base.keys():
		out[k] = base[k]

	# Then overlay only the provided fields in incoming
	for k in incoming.keys():
		out[k] = incoming[k]

	# Ensure sections are preserved if absent in incoming
	if not incoming.has("npcs"):
		out["npcs"] = base.get("npcs", [])
	if not incoming.has("recruitment"):
		out["recruitment"] = base.get("recruitment", {"cursor":0,"page_size":3})
	if not incoming.has("seed"):
		out["seed"] = int(base.get("seed", 1))
	if not incoming.has("vendors"):
		out["vendors"] = base.get("vendors", {})
	if not incoming.has("grid") and base.has("grid"):
		out["grid"] = base["grid"]

	# Normalization: array/dict types
	var npcs_any: Variant = out.get("npcs", [])
	out["npcs"] = (npcs_any as Array) if (npcs_any is Array) else []
	var vend_any: Variant = out.get("vendors", {})
	out["vendors"] = (vend_any as Dictionary) if (vend_any is Dictionary) else {}

	# Metadata timestamps (optional)
	var meta := (out.get("meta", {}) as Dictionary) if (out.get("meta", {}) is Dictionary) else {}
	if not meta.has("created_at") and base.has("meta"):
		var bmeta := base["meta"] as Dictionary
		if bmeta.has("created_at"): meta["created_at"] = bmeta["created_at"]
	meta["edited_at"] = Time.get_unix_time_from_system()
	out["meta"] = meta

	return out


# Deterministic candidate page (not persisted as rows; re-generated each time)
static func get_recruitment_page(slot: int = DEFAULT_SLOT) -> Array[Dictionary]:
	var rec := _get_recruitment(slot)
	var page_size: int = int(_S.dget(rec, "page_size", 3))
	page_size = max(1, page_size)

	var cursor: int = int(_S.dget(rec, "cursor", 0))
	cursor = max(0, cursor)

	var seed_base: int = _village_seed(slot)

	# Sliding-window math over a FIXED-LENGTH generated array
	var offset: int = cursor % page_size                # 0..page_size-1
	var page_index: int = cursor - offset               # start of the current page
	var page_seed: int = int((seed_base ^ 0x9E3779B9) + page_index * 2654435761) & 0x7FFFFFFF

	# IMPORTANT: Keep gen_total CONSTANT regardless of offset
	var gen_total: int = page_size + (page_size - 1)    # e.g., 5 when page_size=3

	if DEBUG_NPC:
		_npc_dbg("recruit_page(size=%d cursor=%d offset=%d page_index=%d seed=%d gen_total=%d FIXED)"
			% [page_size, cursor, offset, page_index, page_seed, gen_total])

	# Deterministic block for this page_index; slide window by 'offset'
	var rows_all: Array[Dictionary] = _NPCGen.generate_hire_page_from_file(RECRUITMENT_NAMES_PATH, gen_total, page_seed)

	# Slice stable window: indices [offset .. offset+page_size-1]
	var out: Array[Dictionary] = []
	var start_i: int = clampi(offset, 0, max(0, rows_all.size() - page_size))
	var end_i: int = min(rows_all.size(), start_i + page_size)

	for i in range(start_i, end_i):
		var row_any := rows_all[i]
		if row_any is Dictionary:
			out.append(_NPCSchema.validate(row_any as Dictionary))

	if DEBUG_NPC:
		_npc_dbg("recruit_page -> rows_all=%d, window=[%d..%d), returned=%d"
			% [rows_all.size(), start_i, end_i, out.size()])

	return out


static func refresh_recruitment_page(slot: int = DEFAULT_SLOT) -> void:
	var rec_before := _get_recruitment(slot)
	var page_size: int = int(_S.dget(rec_before, "page_size", 3))
	var cursor_before: int = int(_S.dget(rec_before, "cursor", 0))
	var rec := rec_before.duplicate(true)
	rec["cursor"] = cursor_before + page_size
	_set_recruitment(rec, slot)
	var rec_after := _get_recruitment(slot)
	_npc_dbg("refresh_recruitment_page: cursor %d -> %d (page_size=%d)"
		% [cursor_before, int(_S.dget(rec_after, "cursor", 0)), page_size])

# Hire by index in current page: 0..page_size-1 (enforces 100g, advances cursor)
static func hire_candidate(index: int, slot: int = DEFAULT_SLOT) -> Dictionary:
	var page: Array[Dictionary] = get_recruitment_page(slot)
	if index < 0 or index >= page.size():
		_npc_dbg("hire_candidate index out of range: %d size=%d" % [index, page.size()])
		return {}

	# Gold gate from META stash
	var meta := load_game(slot)
	var stash_gold := int(meta.get("stash_gold", 0))
	if stash_gold < HIRE_COST_GOLD:
		_npc_dbg("hire_candidate blocked: need %d, have %d" % [HIRE_COST_GOLD, stash_gold])
		return {}

	# Deduct gold and persist
	meta["stash_gold"] = max(0, stash_gold - HIRE_COST_GOLD)
	save_game(meta, slot)

	var hire: Dictionary = _NPCSchema.validate(page[index])

	# Append to village npcs[]
	var snap := _VillageSave.load_village(slot)
	var npcs_any: Variant = snap.get("npcs", [])
	var npcs: Array = (npcs_any as Array) if (npcs_any is Array) else []
	var typed: Array[Dictionary] = []
	for r in npcs:
		if r is Dictionary:
			typed.append(r as Dictionary)
	typed.append(hire)
	snap["npcs"] = typed
	_VillageSave.save_village(snap, slot)

	# --- NEW BEHAVIOR: Do NOT slide the cursor on hire ---
	# Keep the current 3-candidate pool stable. The UI already filters out the newly hired NPC,
	# so you will see the remaining 2 until manual refresh or timed restock.
	var rec_before := _get_recruitment(slot)
	var cursor_before: int = int(_S.dget(rec_before, "cursor", 0))
	var page_size: int = int(_S.dget(rec_before, "page_size", 3))
	# Preserve cadence + last_ref by writing back the same recruitment state (no cursor change)
	_set_recruitment({
		"cursor": cursor_before,
		"page_size": page_size
	}, slot)

	if DEBUG_NPC:
		_npc_dbg("hire_candidate: cursor stays at %d (page_size=%d). Hired id=%s, name='%s'. Remaining visible candidates should drop by 1 (UI filter)." % [
			cursor_before, page_size, String(hire.get("id","")), String(hire.get("name",""))
		])
		_npc_dbg("hired '%s' (id=%s) -> npcs now=%d (-%d gold)" % [
			String(hire.get("name","")), String(hire.get("id","")), typed.size(), HIRE_COST_GOLD
		])

	return hire

static func ensure_role_level(npc_id: StringName, role: String, at_least: int, slot: int = DEFAULT_SLOT) -> void:
	var snap: Dictionary = _VillageSave.load_village(slot)
	var npcs_any: Variant = snap.get("npcs", [])
	var npcs: Array = (npcs_any as Array) if (npcs_any is Array) else []
	var out: Array[Dictionary] = []

	for row_any in npcs:
		if not (row_any is Dictionary):
			continue
		var row: Dictionary = row_any
		if String(row.get("id","")) == String(npc_id):
			var rl_any: Variant = row.get("role_levels", {})
			var rl: Dictionary = (rl_any as Dictionary) if (rl_any is Dictionary) else {}

			var v_any: Variant = rl.get(role, null)
			if v_any is int:
				var lv: int = max(at_least, int(v_any))
				rl[role] = {
					"level": lv,
					"xp_current": int(0),
					"xp_to_next": int(_XpTuning.xp_to_next(lv)),
					"previous_xp": int(0),
					"time_assigned": null
				}
			elif v_any is Dictionary:
				var d: Dictionary = v_any
				var cur_level: int = int(d.get("level", 1))
				d["level"] = max(at_least, cur_level)
				d["xp_to_next"] = int(d.get("xp_to_next", _XpTuning.xp_to_next(int(d["level"]))))
				if not d.has("xp_current"): d["xp_current"] = int(0)
				if not d.has("previous_xp"): d["previous_xp"] = int(0)
				if not d.has("time_assigned"): d["time_assigned"] = null
				rl[role] = d
			else:
				var lv2: int = max(1, at_least)
				rl[role] = {
					"level": lv2,
					"xp_current": int(0),
					"xp_to_next": int(_XpTuning.xp_to_next(lv2)),
					"previous_xp": int(0),
					"time_assigned": null
				}
			row["role_levels"] = rl
		out.append(row)

	snap["npcs"] = out
	_VillageSave.save_village(snap, slot)

# --- Timed recruitment restock (driven by meta.time_passed_min) --------------

static func apply_recruitment_restock(slot: int = DEFAULT_SLOT) -> Dictionary:
	var meta := load_game(slot)
	var m_now: float = float(meta.get("time_passed_min", 0.0))

	var v := _VillageSave.load_village(slot)
	var rec_any: Variant = v.get("recruitment", {})
	var rec: Dictionary = (rec_any as Dictionary) if (rec_any is Dictionary) else {"cursor": 0, "page_size": 3}

	var cadence: int = int(rec.get("recruit_cadence_min", 720))
	if cadence <= 0: cadence = 720

	var m_ref: float = float(rec.get("recruit_last_min_ref", m_now))
	var delta: float = max(0.0, m_now - m_ref)
	var ticks: int = int(floor(delta / float(cadence)))
	var page_size: int = int(rec.get("page_size", 3))
	var cursor_before: int = int(rec.get("cursor", 0))

	if ticks > 0:
		rec["cursor"] = cursor_before + (ticks * page_size)
		rec["recruit_last_min_ref"] = m_ref + float(ticks * cadence)
		v["recruitment"] = rec
		_VillageSave.save_village(v, slot)
		_npc_dbg("apply_recruitment_restock: ticks=%d cursor %d -> %d delta=%.2f m_ref=%.2f now=%.2f cadence=%d"
			% [ticks, cursor_before, int(rec["cursor"]), delta, m_ref, m_now, cadence])
	else:
		# Persist first-time ref
		if not rec.has("recruit_last_min_ref"):
			rec["recruit_last_min_ref"] = m_ref
			v["recruitment"] = rec
			_VillageSave.save_village(v, slot)
		_npc_dbg("apply_recruitment_restock: ticks=0 cursor=%d delta=%.2f m_ref=%.2f now=%.2f cadence=%d"
			% [cursor_before, delta, m_ref, m_now, cadence])

	var used: float = float(ticks * cadence)
	var remainder: float = max(0.0, delta - used)
	var remain_min: float = max(0.0, float(cadence) - remainder)

	return {
		"ticks": ticks,
		"remain_min": remain_min,
		"cadence_min": cadence,
		"cursor": int(rec.get("cursor", cursor_before)),
		"page_size": page_size
	}

static func _ts() -> String:
	return "%d.%03d" % [Time.get_unix_time_from_system(), int(Time.get_ticks_msec() % 1000)]
