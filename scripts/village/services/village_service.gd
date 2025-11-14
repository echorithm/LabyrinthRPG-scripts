# res://scripts/village/services/village_service.gd
extends Node
class_name VillageService
##
## Bootstrap + full village feature service.
## - Vmap generation is delegated to BootstrapVmap.ensure(...)
## - Snapshot (grid) kept validated in-memory
## - Buildings/NPC/staff live in _village save; activation computed here
## - Adds ADR-aligned upgrade pipeline (gold + shards) via buildings_catalog.json
##

# ── deps ─────────────────────────────────────────────────────────────────────
const _Save := preload("res://scripts/village/persistence/village_save_utils.gd")
const SaveManager := preload("res://persistence/SaveManager.gd")
const NPCXp := preload("res://scripts/village/services/NPCXpService.gd")
const TimeSvc := preload("res://persistence/services/time_service.gd")
const XpTuning := preload("res://scripts/rewards/XpTuning.gd")

# ADR data
const BUILDINGS_PATH := "res://data/village/buildings_catalog.json"

# ── exports ──────────────────────────────────────────────────────────────────
@export var ring_radius: int = 4
@export var base_tile_catalog_path: NodePath
@export var seed_service_path: NodePath
@export var debug_logging: bool = true
@export var default_slot: int = 0

# ── signals (compat + new) ───────────────────────────────────────────────────
signal snapshot_changed(snap: Dictionary)
signal building_placed(instance_id: StringName, q: int, r: int)
signal building_changed(instance_id: StringName)
signal activation_changed(instance_id: StringName, active: bool)
signal npc_assigned(instance_id: StringName, npc_id: StringName)
signal building_upgraded(instance_id: StringName, new_rarity: StringName)
signal stash_gold_changed(slot: int)

# ── state ────────────────────────────────────────────────────────────────────
var _snapshot: Dictionary = {}   # validated vmap snapshot {seed, grid{radius,tiles}, meta?}
var _seed: int = 0
var _slot: int = 1

# save-model state (buildings, npcs, meta; grid normalized to snapshot)
var _village: Dictionary = {}
var _by_instance: Dictionary = {} # StringName -> Dictionary (row)

# ── ready ────────────────────────────────────────────────────────────────────
func _ready() -> void:
	if not is_in_group("VillageService"):
		add_to_group("VillageService")

	# Load only if the menu/flow has already set the slot.
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	var s_meta: int = (int(tree.get_meta("current_slot")) if tree and tree.has_meta("current_slot") else 0)
	if s_meta > 0:
		load_slot(s_meta)  # this calls _bootstrap_or_load() internally

	NPCXp.set_xp_curve_provider(Callable(XpTuning, "xp_to_next"))

# ---------------------------- Compatibility API ----------------------------- #

func load_slot(slot: int = 0) -> void:
	if debug_logging: print("[VillageService] load_slot | slot=", slot)
	_slot = max(1, int(slot))
	_bootstrap_or_load()
	_load_or_bootstrap_village()

func save_slot(slot: int = 0) -> bool:
	if debug_logging: print("[VillageService] save_slot | slot=", slot)
	var ok := _save_village_only()
	var ok2 := save_snapshot(_snapshot)
	return ok and ok2

# ------------------------------- Public API --------------------------------- #

func get_snapshot() -> Dictionary:
	return _snapshot

func seed() -> int:
	return _seed

func radius() -> int:
	var g_any: Variant = _snapshot.get("grid", {})
	var g: Dictionary = (g_any if (g_any is Dictionary) else {}) as Dictionary
	return int(g.get("radius", ring_radius))

## Persist (possibly modified) snapshot using canonical Provider path.
func save_snapshot(snap: Dictionary) -> bool:
	var paths: VillageMapPaths = VillageMapPaths.new(_slot)
	var schema: VillageMapSchema = VillageMapSchema.new()
	var builder: VillageMapSnapshotBuilder = VillageMapSnapshotBuilder.new()
	var resolver: TileArtResolver = _make_resolver()
	if resolver == null:
		push_error("[VillageService] save_snapshot: BaseTileCatalog missing; abort")
		return false
	var provider: VillageMapProvider = VillageMapProvider.new(paths, schema, builder, resolver)
	return provider.save_snapshot(_seed, snap)

# ------------------------- Feature APIs (restored) --------------------------- #

## Read-only sync with the currently active vmap on disk (no generation).
func sync_with_active_vmap() -> void:
	var paths: VillageMapPaths = VillageMapPaths.new(_slot)
	var act_path: String = paths.active_seed_path()
	if not FileAccess.file_exists(act_path):
		if debug_logging: print("[VillageService] sync_with_active_vmap: no active seed file")
		return
	var f: FileAccess = FileAccess.open(act_path, FileAccess.READ)
	if f == null:
		return
	var txt: String = f.get_as_text().strip_edges()
	if not txt.is_valid_int():
		return
	var active_seed: int = int(txt)
	var snap_path: String = paths.snapshot_path_for_seed(active_seed)
	if not FileAccess.file_exists(snap_path):
		_seed = active_seed
		return
	var loaded: Dictionary = _read_dict(snap_path)
	if loaded.is_empty():
		_seed = active_seed
		return
	var schema: VillageMapSchema = VillageMapSchema.new()
	_snapshot = schema.validate(loaded)
	_seed = int(_snapshot.get("seed", active_seed))
	_align_save_grid_to_snapshot()
	emit_signal("snapshot_changed", get_snapshot())

## Change a tile's base_art_id and persist.
func terraform_tile(q: int, r: int, base_art_id: StringName) -> void:
	_require_snapshot()
	var grid := _grid()
	var tiles: Array = grid.get("tiles", [])
	var idx: int = _find_tile_index(tiles, q, r)
	if idx < 0:
		push_error("[VillageService] terraform_tile: tile not found (%d,%d)" % [q, r]); return
	var t_in: Dictionary = tiles[idx]
	t_in["base_art_id"] = String(base_art_id)

	# validate single-tile roundtrip
	var schema := VillageMapSchema.new()
	var validated: Dictionary = schema.validate({
		"seed": _seed,
		"grid": { "radius": int(grid.get("radius", ring_radius)), "tiles": [t_in] }
	})
	var vtiles: Array = ((validated.get("grid", {}) as Dictionary).get("tiles", []) as Array)
	if vtiles.size() == 1 and vtiles[0] is Dictionary:
		tiles[idx] = (vtiles[0] as Dictionary)
		grid["tiles"] = tiles
		_snapshot["grid"] = grid
	_align_save_grid_to_snapshot()
	_save_both_and_emit_changed(StringName("%s@H_%d_%d" % [String(t_in.get("kind", "")), q, r]))

## Convert a tile to a building-kind, resolve deterministic art, persist.
func place_building(q: int, r: int, building_id: StringName) -> StringName:
	_require_snapshot()
	var grid := _grid()
	var tiles: Array = grid.get("tiles", [])
	var idx: int = _find_tile_index(tiles, q, r)
	if idx < 0:
		push_error("[VillageService] place_building: tile not found (%d,%d)" % [q, r]); return StringName("")
	var t_in: Dictionary = tiles[idx]
	t_in["kind"] = String(building_id)

	# resolve base_art if missing (deterministic)
	if String(t_in.get("base_art_id", "")) == "":
		var resolver := _make_resolver()
		if resolver == null:
			push_error("[VillageService] place_building: missing BaseTileCatalog"); return StringName("")
		var hint: Dictionary = (t_in.get("static", {}) as Dictionary) if (t_in.get("static", {}) is Dictionary) else {}
		var rads: int = int(grid.get("radius", ring_radius))
		var art_id := resolver.resolve_base_art_id(_seed, q, r, String(building_id), hint, rads)
		if art_id == "":
			art_id = String(building_id)
		t_in["base_art_id"] = art_id

	# schema roundtrip for the single tile
	var schema := VillageMapSchema.new()
	var validated: Dictionary = schema.validate({
		"seed": _seed,
		"grid": { "radius": int(grid.get("radius", ring_radius)), "tiles": [t_in] }
	})
	var vtiles: Array = ((validated.get("grid", {}) as Dictionary).get("tiles", []) as Array)
	if vtiles.size() == 1 and vtiles[0] is Dictionary:
		tiles[idx] = (vtiles[0] as Dictionary)

	grid["tiles"] = tiles
	_snapshot["grid"] = grid
	_align_save_grid_to_snapshot()

	# ensure instance row exists/updated
	var instance_id := _instance_id_for(building_id, q, r)
	_ensure_instance_for(instance_id)

	_save_both_and_emit_changed(instance_id, true)
	return instance_id

## Get building instance row (best-effort).
func get_building_instance(instance_id: StringName) -> Dictionary:
	var inst: Dictionary = _by_instance.get(instance_id, {})
	if not inst.is_empty():
		return inst.duplicate(true)
	# reconstruct from tile if not indexed yet
	var qr := _qr_from_instance_id(instance_id)
	if qr == Vector2i.ZERO:
		return {}
	var grid := _grid()
	var tiles: Array = grid.get("tiles", [])
	var idx: int = _find_tile_index(tiles, qr.x, qr.y)
	if idx < 0 or not (tiles[idx] is Dictionary):
		return {}
	var t: Dictionary = tiles[idx]
	return {
		"instance_id": String(instance_id),
		"id": String(t.get("kind", "")),
		"q": qr.x, "r": qr.y,
		"rarity": "COMMON",
		"staff": { "npc_id": "" },
		"connected_to_camp": _any_camp_core_present(),
		"active": false
	}

func get_all_instance_ids() -> Array[String]:
	var out: Array[String] = []
	for k in _by_instance.keys():
		out.append(String(k))
	return out

func set_building_rarity(instance_id: StringName, rarity: StringName) -> void:
	var inst: Dictionary = _by_instance.get(instance_id, {})
	if inst.is_empty():
		return
	inst["rarity"] = String(rarity)
	_update_activation_for(instance_id)
	_save_both_and_emit_changed(instance_id)

func assign_staff(instance_id: StringName, npc_id: StringName) -> void:
	# Diagnostic prologue
	var iid_s := String(instance_id)
	var new_id_s := String(npc_id)
	if debug_logging:
		print("[VillageService] assign_staff | iid=%s npc=%s" % [iid_s, new_id_s])

	var inst: Dictionary = _ensure_instance_for(instance_id)
	if inst.is_empty():
		push_error("[VillageService] assign_staff: no instance for %s" % iid_s)
		return

	var role_required := _role_for_kind(String(inst.get("id","")))
	if debug_logging:
		print("[VillageService] assign_staff | role_required=%s" % role_required)

	# ---- Normalize staff dict locally (UI won't wait for disk) --------------
	var staff: Dictionary = (inst.get("staff", {}) as Dictionary) if (inst.get("staff", {}) is Dictionary) else {}
	var prev_staff_id := String(staff.get("npc_id",""))
	staff["npc_id"] = new_id_s
	inst["staff"] = staff
	_by_instance[instance_id] = inst  # cache immediately for UI

	# ---- Update buildings array in our in-memory village --------------------
	var buildings_arr: Array = _get_buildings_array()
	for j in buildings_arr.size():
		var it2_any: Variant = buildings_arr[j]
		if not (it2_any is Dictionary): continue
		var it2: Dictionary = it2_any
		if String(it2.get("instance_id","")) == iid_s:
			it2["staff"] = staff
			buildings_arr[j] = it2
			break

	# Ensure uniqueness: pull this NPC off any other building
	if new_id_s != "":
		for i in buildings_arr.size():
			var it_any: Variant = buildings_arr[i]
			if not (it_any is Dictionary): continue
			var it: Dictionary = it_any
			var iid_other := String(it.get("instance_id",""))
			if iid_other == iid_s: continue
			var st_any: Variant = it.get("staff", {})
			if st_any is Dictionary and String((st_any as Dictionary).get("npc_id","")) == new_id_s:
				var st: Dictionary = st_any
				if debug_logging: print("[VillageService] assign_staff | pulling npc=%s off iid=%s" % [new_id_s, iid_other])
				st["npc_id"] = ""
				it["staff"] = st
				buildings_arr[i] = it
				_by_instance[StringName(iid_other)] = it
				_update_activation_for(StringName(iid_other))

	_village["buildings"] = buildings_arr
	_by_instance[instance_id] = inst

	# ---- Minimal roster shaping (so UI has sane immediate state) ------------
	var roster: Array = (_village.get("npcs", []) as Array) if (_village.get("npcs", []) is Array) else []
	for r_i in roster.size():
		var r_any: Variant = roster[r_i]
		if not (r_any is Dictionary): continue
		var r: Dictionary = r_any
		if String(r.get("id","")) == new_id_s:
			r["assigned_instance_id"] = iid_s
			r["state"] = "STAFFED"
			r["role"] = role_required
			# Seed role_levels entry if missing (tolerate int/dict)
			var rl_any: Variant = r.get("role_levels", {})
			var rl: Dictionary = (rl_any as Dictionary) if (rl_any is Dictionary) else {}
			if not rl.has(role_required):
				rl[role_required] = 1
			r["role_levels"] = rl
			roster[r_i] = r
		elif String(r.get("assigned_instance_id","")) == iid_s and new_id_s == "":
			# Unassign path: clear if we’re unassigning
			r["assigned_instance_id"] = ""
			r["state"] = "IDLE"
			roster[r_i] = r
	_village["npcs"] = roster

	# ---- Activation recompute (local) ---------------------------------------
	var before_active := bool(inst.get("active", false))
	_update_activation_for(instance_id)
	var after_active := bool(_by_instance.get(instance_id, {}).get("active", false))

	# ── CRITICAL ORDERING FIX ────────────────────────────────────────────────
	# Persist our staff change FIRST so NPCXp can discover the building->npc mapping.
	_save_village_only()

	# ── NPC trickle XP boundary (authoritative) ──────────────────────────────
	TimeSvc.realtime_heartbeat(_slot)
	var now_min := get_realtime_minutes()
	if debug_logging:
		print("[VillageService] assign_staff | heartbeat now_min=%.2f slot=%d" % [now_min, _slot])
		print("[VillageService] assign_staff | reassign -> role=%s prev=%s new=%s"
			% [role_required, prev_staff_id, new_id_s])

	NPCXp.on_reassign(
		StringName(role_required),
		StringName(prev_staff_id),
		npc_id,
		now_min,
		_slot
	)

	# NOTE: Do NOT overwrite our roster with disk here; let the merge keep our
	# assigned_instance_id while incorporating NPCXp's time_assigned/xp.

	# ---- Persist + emit ------------------------------------------------------
	_save_both_and_emit_changed(instance_id)
	emit_signal("npc_assigned", instance_id, npc_id)
	if before_active != after_active:
		emit_signal("activation_changed", instance_id, after_active)

func recompute_activation_for_all() -> void:
	var changed: bool = false
	for k in _by_instance.keys():
		var before: bool = bool(_by_instance[k].get("active", false))
		_update_activation_for(k)
		var after: bool = bool(_by_instance[k].get("active", false))
		if before != after:
			emit_signal("activation_changed", k, after)
			changed = true
	_save_both_and_emit_snapshot()
	if changed:
		emit_signal("snapshot_changed", get_snapshot())

func is_instance_active(instance_id: StringName) -> bool:
	var inst: Dictionary = get_building_instance(instance_id)
	return bool(inst.get("active", false))

# ------------------------------- Upgrades ----------------------------------- #

# JSON helpers
static func _read_dict(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return (parsed as Dictionary) if (parsed is Dictionary) else {}

static func _buildings_map() -> Dictionary:
	var d := _read_dict(BUILDINGS_PATH)
	return (d.get("entries", {}) as Dictionary) if (d.get("entries", {}) is Dictionary) else {}

static func _rarity_ladder() -> Array[String]:
	return ["COMMON","UNCOMMON","RARE","EPIC","ANCIENT","LEGENDARY","MYTHIC"]

static func _next_rarity(cur: String) -> String:
	var ladder := _rarity_ladder()
	var i := ladder.find(cur.to_upper())
	return ladder[min(ladder.size()-1, max(0, i + 1))]

# META wallet helpers
static func _row_dmax(d: Dictionary) -> int:
	if d.has("durability_max"): return int(d.get("durability_max", 0))
	if d.has("opts") and d["opts"] is Dictionary:
		return int((d["opts"] as Dictionary).get("durability_max", 0))
	return 0

static func _row_count(d: Dictionary) -> int:
	if d.has("count"): return int(d.get("count", 1))
	if d.has("opts") and d["opts"] is Dictionary:
		return int((d["opts"] as Dictionary).get("count", 1))
	return 1

func _meta_stash_gold() -> int:
	var gs: Dictionary = SaveManager.load_game(_slot)
	return int(gs.get("stash_gold", 0))

func _meta_add_gold(delta: int) -> void:
	var gs: Dictionary = SaveManager.load_game(_slot)
	var cur := int(gs.get("stash_gold", 0))
	gs["stash_gold"] = max(0, cur + delta)
	SaveManager.save_game(gs, _slot)
	emit_signal("stash_gold_changed", _slot)

func _meta_shard_count() -> int:
	var gs: Dictionary = SaveManager.load_game(_slot)
	var pl_any: Variant = gs.get("player", {})
	var pl: Dictionary = (pl_any as Dictionary) if (pl_any is Dictionary) else {}
	var inv_any: Variant = pl.get("inventory", [])
	var inv: Array = (inv_any as Array) if (inv_any is Array) else []
	var total := 0
	for it in inv:
		if it is Dictionary:
			var d: Dictionary = it
			if String(d.get("id", "")) != "currency_shard": continue
			if _row_dmax(d) != 0: continue
			total += _row_count(d)
	return total

func _meta_remove_shards(n: int) -> int:
	var need: int = max(0, n)
	if need <= 0:
		return 0

	var gs: Dictionary = SaveManager.load_game(_slot)
	var pl_any: Variant = gs.get("player", {})
	var pl: Dictionary = (pl_any as Dictionary) if (pl_any is Dictionary) else {}
	var inv_any: Variant = pl.get("inventory", [])
	var inv: Array = (inv_any as Array) if (inv_any is Array) else []

	print("[VillageService] _meta_remove_shards need=%d inv_size=%d" % [need, inv.size()])

	for i in range(inv.size()):
		if need <= 0:
			break

		var v_any: Variant = inv[i]
		if not (v_any is Dictionary):
			continue
		var row: Dictionary = v_any

		var id_s: String = String(row.get("id", ""))
		if id_s != "currency_shard":
			continue
		if _row_dmax(row) != 0:
			continue  # never touch gear/durable rows

		var have: int = _row_count(row)
		var take: int = min(have, need)
		var remain_i: int = have - take

		# write back count while preserving row shape
		if row.has("count"):
			row["count"] = remain_i
		elif row.has("opts") and row["opts"] is Dictionary:
			var o_any: Variant = row["opts"]
			var o: Dictionary = o_any
			o["count"] = remain_i
			row["opts"] = o
		else:
			row["count"] = remain_i

		if remain_i > 0:
			inv[i] = row
		else:
			inv.remove_at(i)
			i -= 1

		need -= take
		print("[VillageService] _meta_remove_shards consumed=%d remain_stack=%d need_now=%d" % [take, remain_i, need])

	pl["inventory"] = inv
	gs["player"] = pl
	SaveManager.save_game(gs, _slot)

	var removed: int = max(0, n - need)
	print("[VillageService] _meta_remove_shards removed=%d" % removed)
	return removed

func get_upgrade_info(instance_id: StringName) -> Dictionary:
	var inst := get_building_instance(instance_id)
	if inst.is_empty():
		return {
			"current_rarity": "COMMON",
			"upgrade_requirements": {"gold":0,"shards":0,"quest_gate":""},
			"disabled": true,
			"reasons": ["Missing building."]
		}

	var connected := bool(inst.get("connected_to_camp", false))
	var staffed := String((inst.get("staff",{}) as Dictionary).get("npc_id","")) != ""
	var rarity_cur := String(inst.get("rarity", "COMMON")).to_upper()
	var rarity_next := _next_rarity(rarity_cur)

	# read ADR rarity_unlocks for this kind and next rarity
	var kind := String(inst.get("id", ""))
	var bmap := _buildings_map()
	var ru_step: Dictionary = {}
	for k in bmap.keys():
		var d_any: Variant = bmap[k]
		if d_any is Dictionary and String((d_any as Dictionary).get("id","")) == kind:
			var ru_any: Variant = (d_any as Dictionary).get("rarity_unlocks", {})
			if ru_any is Dictionary:
				var ru: Dictionary = ru_any
				ru_step = (ru.get(rarity_next, {}) as Dictionary) if (ru.get(rarity_next, {}) is Dictionary) else {}
			break

	var req_gold := int(ru_step.get("gold", 0))
	var req_shards := int(ru_step.get("shards", 0))
	var qgate := String(ru_step.get("quest", ""))

	var reasons: Array[String] = []
	if not connected: reasons.append("Not connected to camp.")
	if not staffed:   reasons.append("No staff assigned.")
	var have_gold := _meta_stash_gold()
	if have_gold < req_gold: reasons.append("Need %d more gold." % (req_gold - have_gold))
	var have_shards := _meta_shard_count()
	if have_shards < req_shards: reasons.append("Need %d more shard(s)." % (req_shards - have_shards))
	if qgate != "": reasons.append("Quest gate: %s" % qgate)

	var disabled := reasons.size() > 0
	if debug_logging:
		print("[VillageService] upgrade_info iid=%s cur=%s -> next=%s gold=%d shards=%d disabled=%s"
			% [String(instance_id), rarity_cur, rarity_next, req_gold, req_shards, str(disabled)])

	return {
		"current_rarity": rarity_cur,
		"upgrade_requirements": { "gold": req_gold, "shards": req_shards, "quest_gate": qgate },
		"disabled": disabled,
		"reasons": reasons
	}

func upgrade(instance_id: StringName) -> Dictionary:
	var info := get_upgrade_info(instance_id)
	if bool(info.get("disabled", true)):
		if debug_logging: print("[VillageService] upgrade ABORT (disabled) iid=%s" % String(instance_id))
		return {"ok": false, "reason": "disabled", "info": info}

	var inst := _ensure_instance_for(instance_id)
	var rarity_cur := String(inst.get("rarity", "COMMON")).to_upper()
	var rarity_next := _next_rarity(rarity_cur)

	var reqs: Dictionary = info.get("upgrade_requirements", {})
	var gold := int(reqs.get("gold", 0))
	var shards := int(reqs.get("shards", 0))

	# Deduct gold
	var have_gold := _meta_stash_gold()
	if have_gold < gold:
		return {"ok": false, "reason": "insufficient_gold", "need": gold - have_gold}
	_meta_add_gold(-gold)

	# Deduct shards (with rollback on failure)
	var removed := _meta_remove_shards(shards)
	if removed != shards:
		_meta_add_gold(+gold)
		return {"ok": false, "reason": "insufficient_shards", "removed": removed}

	# Apply rarity change + persist
	inst["rarity"] = rarity_next
	# write back into array
	var arr: Array = _get_buildings_array()
	for i in arr.size():
		var it_any: Variant = arr[i]
		if it_any is Dictionary and String((it_any as Dictionary).get("instance_id","")) == String(instance_id):
			arr[i] = inst; break
	_village["buildings"] = arr
	_by_instance[instance_id] = inst

	_save_both_and_emit_changed(instance_id)
	emit_signal("building_upgraded", instance_id, StringName(rarity_next))
	emit_signal("stash_gold_changed", _slot)

	if debug_logging:
		print("[VillageService] upgrade OK iid=%s %s -> %s (-%d gold, -%d shards)"
			% [String(instance_id), rarity_cur, rarity_next, gold, shards])

	return {"ok": true, "new_rarity": rarity_next}

# ------------------------------- Internals ---------------------------------- #

func _bootstrap_or_load() -> void:
	# ── IMPORTANT: use per-slot paths everywhere ─────────────────────────────
	var paths: VillageMapPaths = VillageMapPaths.new(_slot)
	var have_active: bool = FileAccess.file_exists(paths.active_seed_path())

	_seed = _read_active_seed_or_pick(paths)

	var snap_path: String = paths.snapshot_path_for_seed(_seed)
	var fresh: bool = (not FileAccess.file_exists(snap_path)) or (not have_active)

	if debug_logging:
		print("[VillageService] start | seed=", _seed, " radius=", ring_radius, " fresh=", fresh, " slot=", _slot)

	var resolver := _make_resolver()
	if resolver == null:
		push_error("[VillageService] ERROR: BaseTileCatalog not found; cannot resolve art IDs")

	if fresh:
		var catalog := _require_catalog()
		if catalog == null:
			push_error("[VillageService] Bootstrap aborted: BaseTileCatalog required for deterministic art")
			_snapshot = {}
			return
		var snap_new: Dictionary = BootstrapVmap.ensure(_seed, ring_radius, catalog, paths)
		_snapshot = snap_new
	else:
		var loaded: Dictionary = _read_dict(snap_path)
		if loaded.is_empty():
			var catalog2 := _require_catalog()
			if catalog2 == null:
				push_error("[VillageService] Fallback build aborted: BaseTileCatalog required")
				_snapshot = {}
			else:
				var snap2: Dictionary = BootstrapVmap.ensure(_seed, ring_radius, catalog2, paths)
				_snapshot = snap2
		else:
			var schema := VillageMapSchema.new()
			_snapshot = schema.validate(loaded)

	if debug_logging:
		var tiles_any: Variant = (_snapshot.get("grid", {}) as Dictionary).get("tiles", [])
		var tile_count: int = (tiles_any as Array).size() if (tiles_any is Array) else 0
		print("[VillageService] ready | tiles=", tile_count, " seed=", _seed, " slot=", _slot)

# ── village save load/normalize ────────────────────────────────────────────── #

func _load_or_bootstrap_village() -> void:
	_village = _Save.load_village(_slot)
	_normalize_grid_in_place()
	_reindex_buildings()
	_align_save_grid_to_snapshot()
	_village["seed"] = _seed
	_save_village_only()

func _save_village_only() -> bool:
	# Always merge with on-disk to avoid losing fields written by other services (e.g., NPCXp).
	var on_disk := _Save.load_village(_slot)  # full shape as currently saved
	var merged: Dictionary = on_disk.duplicate(true)

	# 1) grid is always aligned to _snapshot by this service
	if _village.has("grid") and (_village["grid"] is Dictionary):
		merged["grid"] = _village["grid"]

	# 2) buildings array and instance index
	if _village.has("buildings") and (_village["buildings"] is Array):
		merged["buildings"] = _village["buildings"]

	# 3) npcs roster – DEEP MERGE by id; prefer on-disk role_levels/time_assigned if present
	var ours: Array = (_village.get("npcs", []) as Array) if (_village.get("npcs", []) is Array) else []
	var theirs: Array = (on_disk.get("npcs", []) as Array) if (on_disk.get("npcs", []) is Array) else []
	merged["npcs"] = _merge_npcs(theirs, ours)

	# 4) vendors, economy, recruitment, seed – keep ours when present, else theirs
	for k in ["vendors", "economy", "recruitment", "seed", "meta"]:
		if _village.has(k):
			merged[k] = _village[k]
		elif on_disk.has(k):
			merged[k] = on_disk[k]

	# Update edited_at and preserve created_at
	var meta_any: Variant = merged.get("meta", {})
	var meta: Dictionary = (meta_any as Dictionary) if (meta_any is Dictionary) else {}
	if not meta.has("created_at") and on_disk.has("meta") and (on_disk["meta"] is Dictionary):
		var bmeta: Dictionary = on_disk["meta"]
		if bmeta.has("created_at"): meta["created_at"] = bmeta["created_at"]
	meta["edited_at"] = float(Time.get_unix_time_from_system())
	merged["meta"] = meta

	if debug_logging:
		print("[VillageService] _save_village_only merge -> tiles=",
			int(((merged.get("grid", {}) as Dictionary).get("tiles", []) as Array).size()),
			" buildings=", int((merged.get("buildings", []) as Array).size()),
			" npcs=", int((merged.get("npcs", []) as Array).size()),
			" vendors=", int((merged.get("vendors", {}) as Dictionary).size()),
			" slot=", _slot
		)

	_Save.save_village(merged, _slot)
	_village = merged  # keep in-memory coherent
	return true

func _align_save_grid_to_snapshot() -> void:
	if _snapshot.is_empty():
		return
	var g_any: Variant = _snapshot.get("grid", {})
	var g: Dictionary = (g_any if (g_any is Dictionary) else {}) as Dictionary
	_village["grid"] = {
		"radius": int(g.get("radius", ring_radius)),
		"tiles": (g.get("tiles", []) as Array) if (g.get("tiles", []) is Array) else []
	}

# ── activation / instance helpers ──────────────────────────────────────────── #

func _update_activation_for(instance_id: StringName) -> void:
	var inst: Dictionary = _by_instance.get(instance_id, {})
	if inst.is_empty():
		return
	var has_staff: bool = String(inst.get("staff", {}).get("npc_id", "")) != ""
	var connected: bool = _any_camp_core_present()
	var active_new: bool = has_staff and connected
	inst["connected_to_camp"] = connected
	var active_old: bool = bool(inst.get("active", false))
	inst["active"] = active_new
	_by_instance[instance_id] = inst
	if active_old != active_new:
		emit_signal("activation_changed", instance_id, active_new)

func _ensure_instance_for(instance_id: StringName) -> Dictionary:
	var cur: Dictionary = _by_instance.get(instance_id, {})
	if not cur.is_empty():
		return cur
	var qr := _qr_from_instance_id(instance_id)
	if qr == Vector2i.ZERO:
		return {}
	var grid := _grid()
	var tiles: Array = grid.get("tiles", [])
	var idx := _find_tile_index(tiles, qr.x, qr.y)
	if idx < 0:
		return {}
	var t: Dictionary = tiles[idx]
	var kind := String(t.get("kind", ""))
	if kind == "":
		kind = "building"
	var row: Dictionary = {
		"instance_id": String(instance_id),
		"id": kind,
		"q": qr.x,
		"r": qr.y,
		"rarity": "COMMON",
		"staff": { "npc_id": "" },
		"connected_to_camp": _any_camp_core_present(),
		"active": false
	}
	var arr := _get_buildings_array()
	arr.append(row)
	_village["buildings"] = arr
	_by_instance[instance_id] = row
	return row

func _instance_id_for(building_id: StringName, q: int, r: int) -> StringName:
	return StringName("%s@H_%d_%d" % [String(building_id), q, r])

# ── normalization helpers ──────────────────────────────────────────────────── #

func _grid() -> Dictionary:
	var g_any: Variant = _snapshot.get("grid", {})
	if g_any is Dictionary:
		return (g_any as Dictionary)
	return {"radius": ring_radius, "tiles": []}

func _set_grid(g: Dictionary) -> void:
	_snapshot["grid"] = {
		"radius": int(g.get("radius", ring_radius)),
		"tiles": (g.get("tiles", []) as Array) if (g.get("tiles", []) is Array) else []
	}

func _normalize_grid_in_place() -> void:
	if not _village.has("grid"):
		_align_save_grid_to_snapshot()
	else:
		var g_any: Variant = _village.get("grid", {})
		var g: Dictionary = (g_any if (g_any is Dictionary) else {}) as Dictionary
		_village["grid"] = {
			"radius": int(g.get("radius", ring_radius)),
			"tiles": (g.get("tiles", []) as Array) if (g.get("tiles", []) is Array) else []
		}
	if not _village.has("seed"):
		_village["seed"] = _seed

func _get_buildings_array() -> Array:
	var arr_any: Variant = _village.get("buildings", [])
	if arr_any is Array:
		return arr_any
	var fix: Array = []
	_village["buildings"] = fix
	return fix

func _reindex_buildings() -> void:
	_by_instance.clear()
	var arr: Array = _get_buildings_array()
	for it in arr:
		if it is Dictionary:
			var d: Dictionary = it
			var iid: StringName = StringName(String(d.get("instance_id", "")))
			if iid != StringName(""):
				_by_instance[iid] = d

# --- misc helpers ------------------------------------------------------------- #

func _require_snapshot() -> void:
	if _snapshot.is_empty():
		_bootstrap_or_load()

func _read_active_seed_or_pick(paths: VillageMapPaths) -> int:
	# 1) Per-slot active seed file (authoritative)
	if FileAccess.file_exists(paths.active_seed_path()):
		var f := FileAccess.open(paths.active_seed_path(), FileAccess.READ)
		if f != null:
			var txt: String = f.get_as_text().strip_edges()
			if txt.is_valid_int():
				return int(txt)

	# 2) Seed service (if present)
	var svc := _get_seed_service()
	if svc != null:
		var s := int(svc.get_seed())
		if s != 0:
			return s

	# 3) Deterministic per-slot fallback (stable across runs)
	var h: int = int(hash("village:%d" % int(paths.slot))) & 0x7FFFFFFF
	if h == 0:
		h = 1
	return h

func _get_seed_service() -> HexSeedService:
	var n := (get_node_or_null(seed_service_path) as HexSeedService)
	if n != null:
		return n
	var root := get_tree().get_current_scene()
	if root == null:
		return null
	var q: Array[Node] = []
	q.append(root)
	while not q.is_empty():
		var cur: Node = q.pop_front()
		if cur is HexSeedService:
			return cur as HexSeedService
		for c in (cur.get_children() as Array[Node]):
			q.append(c)
	return null

func _make_resolver() -> TileArtResolver:
	var catalog := _require_catalog()
	if catalog == null:
		return null
	var resolver := TileArtResolver.new()
	resolver.catalog = catalog
	return resolver

func _require_catalog() -> BaseTileCatalog:
	if base_tile_catalog_path != NodePath(""):
		var n := get_node_or_null(base_tile_catalog_path)
		if n is BaseTileCatalog:
			return n as BaseTileCatalog
	var root := get_tree().get_current_scene()
	if root == null:
		return null
	var q: Array[Node] = []
	q.append(root)
	while not q.is_empty():
		var n2: Node = q.pop_front()
		if n2 is BaseTileCatalog:
			return n2 as BaseTileCatalog
		for c in (n2.get_children() as Array[Node]):
			q.append(c)
	return null

static func _find_tile_index(tiles: Array, q: int, r: int) -> int:
	for i in tiles.size():
		var t_any: Variant = tiles[i]
		if t_any is Dictionary:
			var t: Dictionary = t_any
			if int(t.get("q", 999999)) == q and int(t.get("r", 999999)) == r:
				return i
	return -1

static func _qr_from_instance_id(instance_id: StringName) -> Vector2i:
	var s := String(instance_id)
	var at := s.find("@")
	if at == -1: return Vector2i.ZERO
	var tail := s.substr(at + 1)  # "H_q_r"
	if not tail.begins_with("H_"): return Vector2i.ZERO
	var parts := tail.substr(2).split("_")
	if parts.size() != 2: return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))

func _any_camp_core_present() -> bool:
	var grid := _grid()
	var tiles: Array = grid.get("tiles", [])
	for it in tiles:
		if it is Dictionary and String((it as Dictionary).get("kind", "")) == "camp_core":
			return true
	return false

func _save_both_and_emit_changed(instance_id: StringName, placed: bool = false) -> void:
	_save_village_only()
	save_snapshot(_snapshot)
	if placed:
		var qr := _qr_from_instance_id(instance_id)
		emit_signal("building_placed", instance_id, qr.x, qr.y)
	emit_signal("building_changed", instance_id)
	emit_signal("snapshot_changed", get_snapshot())

func _save_both_and_emit_snapshot() -> void:
	_save_village_only()
	save_snapshot(_snapshot)
	emit_signal("snapshot_changed", get_snapshot())

func get_tile_header(instance_id: StringName) -> Dictionary:
	# Prefer the real instance row if already indexed
	var inst: Dictionary = _by_instance.get(instance_id, {})
	if inst.is_empty():
		# Best-effort: ensure we have a row, then try again
		_ensure_instance_for(instance_id)
		inst = _by_instance.get(instance_id, {})
	if inst.is_empty():
		print("[VillageService] get_tile_header: no instance for %s" % String(instance_id))
		return {
			"display_name": "",
			"rarity": "",
			"connected": false,
			"active": false,
			"badges": [] as Array
		}

	# Normalize fields for the header
	var kind_id := String(inst.get("id", ""))
	var display := kind_id.capitalize().replace("_", " ")
	var rarity_uc := String(inst.get("rarity", "COMMON")).to_upper()
	var connected := bool(inst.get("connected_to_camp", false))
	var active := bool(inst.get("active", false))

	print("[VillageService] get_tile_header -> iid=%s id=%s rarity=%s connected=%s active=%s"
		% [String(instance_id), kind_id, rarity_uc, str(connected), str(active)])

	return {
		"display_name": display,
		"rarity": rarity_uc,   # e.g. COMMON / UNCOMMON / RARE
		"connected": connected,
		"active": active,
		"badges": [] as Array
	}

# --- Staffing query API ------------------------------------------------------ #

func get_building_staffing(instance_id: StringName) -> Dictionary:
	# Resolve building + role
	var inst := get_building_instance(instance_id)
	if inst.is_empty():
		if debug_logging:
			print("[VillageService] get_building_staffing: no instance for ", String(instance_id))
		return { "role_required": "INNKEEPER", "current_npc_id": StringName(""), "roster": [] }

	var kind := String(inst.get("id",""))
	var role_required := _role_for_kind(kind)

	# Current assignment (if any)
	var staff_any: Variant = inst.get("staff", {})
	var current_id: StringName = StringName("")
	if staff_any is Dictionary:
		current_id = StringName(String((staff_any as Dictionary).get("npc_id", "")))

	# Load roster from village save
	var snap := _Save.load_village(_slot)
	var npcs_any: Variant = snap.get("npcs", [])
	var rows: Array = (npcs_any as Array) if (npcs_any is Array) else []

	var roster: Array[Dictionary] = []

	for v in rows:
		if not (v is Dictionary):
			continue
		var n: Dictionary = v

		var id_s := String(n.get("id",""))
		if id_s == "":
			continue

		var state_s := String(n.get("state","IDLE"))
		var assigned_iid := String(n.get("assigned_instance_id",""))

		var is_current := (id_s == String(current_id))
		var is_dead := (state_s == "DEAD")
		var is_unassigned := (assigned_iid == "")

		# Roster shows only UNASSIGNED candidates (the modal shows 'current' separately)
		if is_dead: continue
		if is_current: continue
		if not is_unassigned: continue

		# ── SAFE ROLE LEVEL EXTRACTION ─────────────────────────────────────────
		var role_level_i: int = 0
		var rl_map_any: Variant = n.get("role_levels", {})

		if rl_map_any is Dictionary:
			var rl_map: Dictionary = rl_map_any
			var track_any: Variant = rl_map.get(role_required, 0)
			if track_any is int:
				role_level_i = int(track_any)
				if debug_logging:
					print("[VillageService] staffing(role=", role_required, ") npc=", id_s, " level=int(", role_level_i, ")")
			elif track_any is Dictionary:
				var track: Dictionary = track_any
				role_level_i = int(track.get("level", 0))
				if debug_logging:
					print("[VillageService] staffing(role=", role_required, ") npc=", id_s, " level=dict(", role_level_i, ")")
			else:
				role_level_i = 0
				if debug_logging:
					print("[VillageService] staffing(role=", role_required, ") npc=", id_s, " level=absent/other -> 0")
		else:
			# Legacy/invalid shapes – treat as no progress in this role
			role_level_i = 0
			if debug_logging:
				print("[VillageService] staffing(role=", role_required, ") npc=", id_s, " role_levels not a dict -> 0")

		roster.append({
			"id": id_s,
			"name": String(n.get("name","—")),
			"role_level": role_level_i
		})

	if debug_logging:
		print("[VillageService] get_building_staffing iid=", String(instance_id),
			" role=", role_required, " roster=", roster.size(), " current=", String(current_id))

	return {
		"role_required": role_required,
		"current_npc_id": current_id,
		"roster": roster
	}

# Map building kind -> required role (simple MVP mapping)
static func _role_for_kind(kind: String) -> String:
	match kind:
		"blacksmith":     return "ARTISAN_BLACKSMITH"
		"alchemist_lab":  return "ARTISAN_ALCHEMIST"
		"marketplace":    return "INNKEEPER" # placeholder for vendor/merchant
		# Trainers (any trainer_*): map to a generic or specific trainer role as you prefer
		_:
			if kind.begins_with("trainer_sword"): return "TRAINER_SWORD"
			if kind.begins_with("trainer_spear"): return "TRAINER_SPEAR"
			if kind.begins_with("trainer_mace"):  return "TRAINER_MACE"
			if kind.begins_with("trainer_range"): return "TRAINER_RANGE"
			if kind.begins_with("trainer_support"): return "TRAINER_SUPPORT"
			if kind.begins_with("trainer_fire"):  return "TRAINER_FIRE"
			if kind.begins_with("trainer_water"): return "TRAINER_WATER"
			if kind.begins_with("trainer_wind"):  return "TRAINER_WIND"
			if kind.begins_with("trainer_earth"): return "TRAINER_EARTH"
			if kind.begins_with("trainer_light"): return "TRAINER_LIGHT"
			if kind.begins_with("trainer_dark"):  return "TRAINER_DARK"
			# Default fallback
			return "INNKEEPER"

# --- Realtime helper (typed) ------------------------------------------------- #

func get_realtime_minutes() -> float:
	# Read unified realtime minutes from TimeSvc, tolerating both Dict or Object snapshots.
	var now_min: float = 0.0
	var rt: Variant = TimeSvc.realtime_snapshot(_slot)
	if rt is Dictionary:
		now_min = float((rt as Dictionary).get("combined_min", 0.0))
	elif rt is Object:
		if rt.has_method("get"):
			var v: Variant = rt.call("get", "combined_min")
			if (v is float) or (v is int):
				now_min = float(v)
		elif rt.has_method("combined_min"):
			var v2: Variant = rt.call("combined_min")
			if (v2 is float) or (v2 is int):
				now_min = float(v2)
	return now_min

# --- Deep merge helper (typed) ---------------------------------------------- #

static func _merge_npcs(theirs: Array, ours: Array) -> Array:
	# theirs = on-disk (often contains NPCXp fields like time_assigned)
	# ours   = in-memory (contains our latest assignment intentions)
	var by_id_disk: Dictionary = {}
	for it in theirs:
		if it is Dictionary:
			var d: Dictionary = it
			by_id_disk[String(d.get("id",""))] = d
	var by_id_mem: Dictionary = {}
	for it2 in ours:
		if it2 is Dictionary:
			var d2: Dictionary = it2
			by_id_mem[String(d2.get("id",""))] = d2

	var union_ids: Array[String] = []
	for k in by_id_disk.keys():
		union_ids.append(String(k))
	for k2 in by_id_mem.keys():
		var s := String(k2)
		if union_ids.find(s) == -1: union_ids.append(s)

	var out: Array = []
	for id_s in union_ids:
		var a: Dictionary = (by_id_disk.get(id_s, {}) as Dictionary) if (by_id_disk.has(id_s)) else {}
		var b: Dictionary = (by_id_mem.get(id_s, {}) as Dictionary) if (by_id_mem.has(id_s)) else {}
		var row: Dictionary = {}
		if not a.is_empty():
			row = a.duplicate(true)
		elif not b.is_empty():
			row = b.duplicate(true)
		else:
			continue

		# Assigned instance/state/role – take our intent, then normalize state unless DEAD
		if b.has("assigned_instance_id"):
			row["assigned_instance_id"] = b["assigned_instance_id"]
		var is_dead := (String(row.get("state","")) == "DEAD") or (String(b.get("state","")) == "DEAD")
		if is_dead:
			row["state"] = "DEAD"
		else:
			var assigned := String(row.get("assigned_instance_id",""))
			row["state"] = "STAFFED" if assigned != "" else "IDLE"
		if b.has("role") and String(b["role"]) != "":
			row["role"] = String(b["role"])

		# role_levels – prefer on-disk richness (time_assigned/xp), but ensure our slot exists
		var rl_disk_any: Variant = row.get("role_levels", {})
		var rl_disk: Dictionary = (rl_disk_any as Dictionary) if (rl_disk_any is Dictionary) else {}
		var rl_mem_any: Variant = b.get("role_levels", {})
		if rl_mem_any is Dictionary:
			var rl_mem: Dictionary = rl_mem_any
			for rk in rl_mem.keys():
				if not rl_disk.has(rk):
					rl_disk[rk] = rl_mem[rk]
				else:
					var va: Variant = rl_disk[rk]
					var vb: Variant = rl_mem[rk]
					if (va is int) and (vb is Dictionary):
						rl_disk[rk] = vb
					elif (va is Dictionary) and (vb is int):
						var d: Dictionary = va
						d["level"] = max(int(d.get("level", 1)), int(vb))
						rl_disk[rk] = d
					elif (va is Dictionary) and (vb is Dictionary):
						var d2: Dictionary = va
						# Fill missing fields from mem if disk is sparse (rare)
						if (not d2.has("time_assigned") or d2["time_assigned"] == null) and vb.has("time_assigned"):
							var t: Variant = vb["time_assigned"]
							if (t is float) or (t is int): d2["time_assigned"] = float(t)
						if not d2.has("previous_xp") and vb.has("previous_xp"): d2["previous_xp"] = vb["previous_xp"]
						if not d2.has("xp_current") and vb.has("xp_current"): d2["xp_current"] = vb["xp_current"]
						if not d2.has("xp_to_next") and vb.has("xp_to_next"): d2["xp_to_next"] = vb["xp_to_next"]
						rl_disk[rk] = d2
		row["role_levels"] = rl_disk

		out.append(row)
	return out
