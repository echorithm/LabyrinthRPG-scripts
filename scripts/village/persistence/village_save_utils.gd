# FILE: res://scripts/village/persistence/village_save_utils.gd
# Composite village save utilities (seed + grid + buildings) and legacy vmap helpers.
extends RefCounted
class_name VillageSaveUtils

const _S          := preload("res://persistence/util/save_utils.gd")
const _Schema     := preload("res://scripts/village/persistence/schemas/village_map_schema.gd")
const _NPCSchema  := preload("res://scripts/village/persistence/schemas/npc_instance_schema.gd")
const _EconSchema := preload("res://scripts/village/persistence/schemas/economy_ledger_schema.gd")
const SaveManager := preload("res://persistence/SaveManager.gd")  # used by merge_meta_stackables

const DEFAULT_RADIUS: int = 4

# --- Debug ------------------------------------------------------------
static var DEBUG: bool = false
static func _dbg(msg: String) -> void:
	if DEBUG:
		print("[VillageSave] " + msg)

# -------- composite village (slot-based) ------------------------------------

static func village_path(slot: int) -> String:
	return "user://saves/slot_%d_village.json" % int(slot)

static func _seed_for_slot(slot: int) -> int:
	# Deterministic per-slot, avoid 0.
	var h: int = int(hash("village:%d" % slot)) & 0x7FFFFFFF
	if h == 0:
		h = 1
	return h

static func _contains_axial(a: Array[Dictionary], q: int, r: int) -> bool:
	for t in a:
		if int(t.get("q", 9999)) == q and int(t.get("r", 9999)) == r:
			return true
	return false

static func _minimal_tiles_for_radius(radius: int) -> Array[Dictionary]:
	var tiles: Array[Dictionary] = []
	# ADR-014: authored core
	tiles.append({"q": 0, "r": 0, "kind": "camp_core"})
	tiles.append({"q": 1, "r": 0, "kind": "entrance"})
	# Fill the hex with a neutral base so art can paint immediately
	for q in range(-radius, radius + 1):
		var rmin: int = max(-radius, -q - radius)
		var rmax: int = min(radius, -q + radius)
		for r in range(rmin, rmax + 1):
			if _contains_axial(tiles, q, r):
				continue
			tiles.append({"q": q, "r": r, "kind": "plains"})
	return tiles

static func _bootstrap_default(slot: int, reason: String) -> Dictionary:
	_dbg("bootstrap default for slot=%d (%s)" % [slot, reason])
	var seed: int = _seed_for_slot(slot)
	var grid: Dictionary = {
		"radius": DEFAULT_RADIUS,
		"tiles": _minimal_tiles_for_radius(DEFAULT_RADIUS)
	}
	var out: Dictionary = {
		"seed": seed,
		"grid": grid,                          # pure grid
		"buildings": [],
		"recruitment": {"cursor": 0, "page_size": 3},
		"npcs": [],
		"vendors": {},                         # vendor blocks map instance_id -> vendor_block
		"economy": _EconSchema.validate({}),   # economy ledger block
		"meta": {"created_at": float(Time.get_unix_time_from_system())}
	}
	# Validate + write immediately
	out = _Schema.validate(out)
	save_village(out, slot)
	return out

static func load_village(slot: int) -> Dictionary:
	var p: String = VillageSaveUtils.village_path(slot)
	_dbg("load_village slot=%d path=%s" % [slot, p])

	if not FileAccess.file_exists(p):
		_dbg("  file missing -> bootstrap")
		return _bootstrap_default(slot, "file missing")

	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		_dbg("  open failed -> bootstrap")
		return _bootstrap_default(slot, "open failed")

	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		_dbg("  parse failed/non-dict -> bootstrap")
		return _bootstrap_default(slot, "parse failed")

	var src: Dictionary = _S.to_dict(parsed)

	# Normalize expected shape but DON’T clobber data.
	var out: Dictionary = {}
	out["seed"] = int(src.get("seed", 0))

	# Accept either a pure grid or a nested snapshot; always return pure grid.
	var g_any: Variant = src.get("grid", {})
	var grid: Dictionary = {}
	if g_any is Dictionary:
		var gd: Dictionary = g_any
		grid = gd.get("grid") if (gd.has("grid") and gd.get("grid") is Dictionary) else gd

	# Validate minimal structure without changing content of tiles beyond coercion.
	var radius: int = int(grid.get("radius", DEFAULT_RADIUS))
	var tiles_any: Variant = grid.get("tiles", [])
	var tiles: Array[Dictionary] = []
	if tiles_any is Array:
		for v in (tiles_any as Array):
			if v is Dictionary:
				tiles.append(v)
	_dbg("  grid in: radius=%d tiles=%d" % [radius, tiles.size()])

	# Seed repair
	if int(out["seed"]) == 0:
		out["seed"] = _seed_for_slot(slot)

	# If grid empty -> bootstrap minimal and persist
	if tiles.size() == 0:
		_dbg("  empty grid in file -> bootstrap")
		return _bootstrap_default(slot, "empty grid")

	# Run through schema to coerce tiles
	var validated := _Schema.validate({"grid": {"radius": radius, "tiles": tiles}, "seed": int(out["seed"])})
	out["grid"] = validated.get("grid", {"radius": radius, "tiles": tiles})

	var b_any: Variant = src.get("buildings", [])
	out["buildings"] = (b_any as Array) if (b_any is Array) else []
	_dbg("  buildings count=%d" % [(out["buildings"] as Array).size()])

	var npcs_any: Variant = src.get("npcs", [])
	var npcs_in: Array = (npcs_any as Array) if (npcs_any is Array) else []
	var npcs_out: Array[Dictionary] = []
	for row_any in npcs_in:
		if row_any is Dictionary:
			var validated_npc := _NPCSchema.validate(row_any as Dictionary)
			npcs_out.append(validated_npc)
	out["npcs"] = npcs_out
	_dbg("  npcs validated=%d" % [npcs_out.size()])

	# Vendors passthrough (map instance_id -> vendor_block). Validate lightly at service layer.
	var vendors_any: Variant = src.get("vendors", {})
	out["vendors"] = (vendors_any as Dictionary) if (vendors_any is Dictionary) else {}

	# Economy ledger block (sanitized by schema)
	var econ_any: Variant = src.get("economy", {})
	var econ_in: Dictionary = (econ_any as Dictionary) if (econ_any is Dictionary) else {}
	out["economy"] = _EconSchema.validate(econ_in)

	var meta_any: Variant = src.get("meta", {})
	out["meta"] = (meta_any as Dictionary) if (meta_any is Dictionary) else {}
	var rec_any: Variant = src.get("recruitment", {})
	var rec_in: Dictionary = (rec_any as Dictionary) if (rec_any is Dictionary) else {}

	var rec_out: Dictionary = {
		"cursor": int(rec_in.get("cursor", 0)),
		"page_size": int(rec_in.get("page_size", 3)),
		"recruit_last_min_ref": float(rec_in.get("recruit_last_min_ref", 0.0)),
		"recruit_cadence_min": int(rec_in.get("recruit_cadence_min", 720))
	}
	out["recruitment"] = rec_out

	_dbg("load_village done")
	return out

static func save_village(d_in: Dictionary, slot: int) -> void:
	_dbg("save_village slot=%d" % [slot])
	# Expect { seed:int, grid:{radius,tiles}, buildings:Array, vendors:Dictionary, economy:Dictionary, meta:Dictionary }
	var seed: int = int(d_in.get("seed", 0))
	if seed == 0:
		seed = _seed_for_slot(slot)

	var grid_in_any: Variant = d_in.get("grid", {})
	var grid_in: Dictionary = (grid_in_any as Dictionary) if (grid_in_any is Dictionary) else {}
	# Ensure tiles non-empty before validation
	var tiles_any: Variant = grid_in.get("tiles", [])
	var tiles_arr: Array = (tiles_any as Array) if (tiles_any is Array) else []
	if tiles_arr.size() == 0:
		grid_in["radius"] = int(grid_in.get("radius", DEFAULT_RADIUS))
		grid_in["tiles"] = _minimal_tiles_for_radius(int(grid_in.get("radius")))

	var buildings: Array = (d_in.get("buildings", []) as Array) if (d_in.get("buildings", []) is Array) else []
	var meta: Dictionary = (d_in.get("meta", {}) as Dictionary) if (d_in.get("meta", {}) is Dictionary) else {}

	var rec_any2: Variant = d_in.get("recruitment", {})
	var rec_in2: Dictionary = (rec_any2 as Dictionary) if (rec_any2 is Dictionary) else {}
	var rec_out2: Dictionary = {
		"cursor": int(rec_in2.get("cursor", 0)),
		"page_size": int(rec_in2.get("page_size", 3)),
		"recruit_last_min_ref": float(rec_in2.get("recruit_last_min_ref", 0.0)),
		"recruit_cadence_min": int(rec_in2.get("recruit_cadence_min", 720))
	}

	var npcs_any: Variant = d_in.get("npcs", [])
	var npcs_in: Array = (npcs_any as Array) if (npcs_any is Array) else []
	var npcs_out: Array[Dictionary] = []
	for row_any in npcs_in:
		if row_any is Dictionary:
			npcs_out.append(_NPCSchema.validate(row_any as Dictionary))

	var vendors_any: Variant = d_in.get("vendors", {})
	var vendors_map: Dictionary = (vendors_any as Dictionary) if (vendors_any is Dictionary) else {}

	var econ_any2: Variant = d_in.get("economy", {})
	var econ_out: Dictionary = _EconSchema.validate((econ_any2 as Dictionary) if (econ_any2 is Dictionary) else {})

	# Validate grid via schema to keep it consistent with renderer.
	var validated := _Schema.validate({"seed": seed, "grid": grid_in})
	var grid_out: Dictionary = validated.get("grid", grid_in)

	var out: Dictionary = {
		"seed": seed,
		"grid": grid_out,
		"buildings": buildings,
		"npcs": npcs_out,
		"vendors": vendors_map,
		"economy": econ_out,
		"meta": meta,
		"recruitment": rec_out2
	}

	_dbg("WRITE village.json | tiles=%d buildings=%d npcs=%d vendors=%d seed=%d"
	% [
		int(((out.get("grid", {}) as Dictionary).get("tiles", []) as Array).size()),
		int((out.get("buildings", []) as Array).size()),
		int((out.get("npcs", []) as Array).size()),
		int((out.get("vendors", {}) as Dictionary).size()),
		int(out.get("seed", 0))
	])

	var p: String = VillageSaveUtils.village_path(slot)
	_dbg("  writing path=%s tiles=%d buildings=%d npcs=%d vendors=%d ledger=%d" % [
		p,
		int(((out.get("grid", {}) as Dictionary).get("tiles", []) as Array).size()),
		int((out.get("buildings", []) as Array).size()),
		int((out.get("npcs", []) as Array).size()),
		int((out.get("vendors", {}) as Dictionary).size()),
		int(((out.get("economy", {}) as Dictionary).get("ledger", []) as Array).size())
	])

	DirAccess.make_dir_recursive_absolute("user://saves")
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(out, "\t"))
		_dbg("save_village OK")
	else:
		_dbg("save_village FAILED to open")

# -------- legacy vmap snapshot (by seed) ------------------------------------

static func path(slot: int) -> String:
	# kept for backward-compat; not used by VillageService
	return "user://saves/slot_%d_village.json" % int(slot)

static func exists(slot: int) -> bool:
	return FileAccess.file_exists(VillageSaveUtils.village_path(slot))

# NOTE: legacy map snapshot helpers still available for editor/tools:

static func load_snapshot(slot: int) -> Dictionary:
	var p: String = VillageSaveUtils.village_path(slot)
	_dbg("load_snapshot slot=%d path=%s" % [slot, p])
	if not FileAccess.file_exists(p):
		_dbg("  missing -> defaults()")
		return _Schema.defaults()
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		_dbg("  open failed -> defaults()")
		return _Schema.defaults()
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	var d_in: Dictionary = _S.to_dict(parsed)
	var out := _Schema.validate(d_in)
	_dbg("load_snapshot -> tiles=%d" %
		[int(((out.get("grid", {}) as Dictionary).get("tiles", []) as Array).size())])
	return out

static func save_snapshot(d_in: Dictionary, slot: int) -> void:
	_dbg("WARNING save_snapshot(): merging GRID ONLY into full village to preserve npcs/vendors (slot=%d)" % slot)

	# Legacy callers expect to write ONLY the grid. Merge into full village.
	var base := load_village(slot)  # full structure ({seed, grid, buildings, npcs, ...})

	# Validate incoming grid with the map schema first
	var validated := _Schema.validate(d_in)
	var grid_any: Variant = (validated.get("grid", {}) if (validated.has("grid")) else {})
	var grid_in: Dictionary = (grid_any as Dictionary) if (grid_any is Dictionary) else {}

	# Keep everything else from base; overlay the grid only.
	var out := base.duplicate(true)
	out["grid"] = grid_in

	# Ensure seed present (some legacy writers pass it; if not, keep base/derive)
	if validated.has("seed"):
		out["seed"] = int(validated.get("seed", int(out.get("seed", _seed_for_slot(slot)))))

	save_village(out, slot)  # ← writes the full shape without dropping npcs/vendors/etc.
	_dbg("save_snapshot (merge-safe) slot=%d tiles=%d npcs=%d" % [
		slot,
		int(((out.get("grid", {}) as Dictionary).get("tiles", []) as Array).size()),
		int((out.get("npcs", []) as Array).size())
	])

static func write_from_node(village_node: Node, slot: int) -> Dictionary:
	_dbg("write_from_node slot=%d node=%s" % [slot, str(village_node)])

	var snap: Dictionary = {}
	if village_node == null:
		snap = _Schema.defaults()
	elif village_node.has_method("build_map_snapshot"):
		snap = village_node.call("build_map_snapshot")
	elif village_node.has_method("build_grid_save"):
		snap = village_node.call("build_grid_save")
	else:
		snap = _Schema.defaults()

	# IMPORTANT: do NOT write here. Caller will merge+save.
	return _Schema.validate(snap)

static func apply_to_node(village_node: Node, slot: int) -> Dictionary:
	_dbg("apply_to_node slot=%d node=%s" % [slot, str(village_node)])
	var snap: Dictionary = load_snapshot(slot)
	if village_node != null:
		if village_node.has_method("apply_map_snapshot"):
			village_node.call("apply_map_snapshot", snap)
		elif village_node.has_method("apply_grid_save"):
			village_node.call("apply_grid_save", snap)
	return snap

static func debug_print_presence(slot: int) -> void:
	var p: String = VillageSaveUtils.village_path(slot)
	print("[VillageSave] presence=", FileAccess.file_exists(p), " (", p, ")")

# --- META inventory maintenance ---------------------------------------------

static func _is_potion_id(id: String) -> bool:
	return id.begins_with("potion_")

static func _rarity_full(r: String) -> String:
	var key := r.strip_edges()
	if key.is_empty():
		return "Common"
	key = key.to_upper()
	match key:
		"C", "COMMON":     return "Common"
		"U", "UNCOMMON":   return "Uncommon"
		"R", "RARE":       return "Rare"
		"E", "EPIC":       return "Epic"
		"A", "ANCIENT":    return "Ancient"
		"L", "LEGENDARY":  return "Legendary"
		"M", "MYTHIC":     return "Mythic"
		_:                 return "Common"

static func _as_canonical_potion(d: Dictionary) -> Dictionary:
	var id := String(d.get("id",""))
	if id == "" or not _is_potion_id(id):
		return d

	# Extract from either shape
	var rarity := "Common"
	var ilvl := 1
	var count := 1
	var affixes: Array = []
	if d.has("opts") and d["opts"] is Dictionary:
		var o: Dictionary = d["opts"]
		rarity = _rarity_full(String(o.get("rarity","Common")))
		ilvl = int(o.get("ilvl", 1))
		count = int(d.get("count", 1))
		affixes = (o.get("affixes", []) as Array) if (o.get("affixes", []) is Array) else []
	else:
		rarity = _rarity_full(String(d.get("rarity","Common")))
		ilvl = int(d.get("ilvl", 1))
		count = int(d.get("count", 1))
		if d.has("affixes") and d["affixes"] is Array:
			affixes = d["affixes"]

	# Align with ItemResolver: consumables use ilvl 1, zero weight
	return {
		"count": float(max(1, count)),
		"equipable": false,
		"id": id,
		"opts": {
			"affixes": affixes,
			"archetype": "Consumable",
			"durability_current": 0.0,
			"durability_max": 0.0,
			"ilvl": 1.0,
			"rarity": rarity,
			"weight": 0.0
		},
		"rarity": rarity
	}

static func _is_stackable_row(d: Dictionary) -> bool:
	if d.is_empty():
		return false
	var equipable: bool = bool(d.get("equipable", false))
	var dmax: int = 0
	if d.has("durability_max"):
		dmax = int(d.get("durability_max", 0))
	elif d.has("opts") and d["opts"] is Dictionary:
		dmax = int((d["opts"] as Dictionary).get("durability_max", 0))
	return (not equipable) and dmax == 0

static func _row_count(d: Dictionary) -> int:
	if d.has("count"):
		return int(d.get("count", 1))
	if d.has("opts") and d["opts"] is Dictionary:
		return int((d["opts"] as Dictionary).get("count", 1))
	return 1

static func _stack_key_for(dk: Dictionary) -> String:
	var id2: String = String(dk.get("id",""))
	if id2 == "":
		return ""
	if id2.begins_with("potion_") and dk.has("opts") and dk["opts"] is Dictionary:
		var o: Dictionary = dk["opts"]
		var rar: String = String(o.get("rarity","Common"))
		var ilv: int = int(o.get("ilvl", 1))
		return "%s|%s|%d" % [id2, rar, ilv]
	# non-potion stackables: group only by id to preserve prior behavior
	return id2

static func merge_meta_stackables(slot: int) -> void:
	# Work on META (game) save, not village.json
	var gs: Dictionary = SaveManager.load_game(slot)
	if gs.is_empty():
		return

	var player_any: Variant = gs.get("player", {})
	var player: Dictionary = (player_any as Dictionary) if (player_any is Dictionary) else {}

	var inv_any: Variant = player.get("inventory", [])
	var inv: Array = (inv_any as Array) if (inv_any is Array) else []

	# 1) Canonicalize potions to consumable-with-opts shape (ilvl 1, durability 0)
	var canon: Array = []
	for v in inv:
		if not (v is Dictionary):
			continue
		var d: Dictionary = v
		var id: String = String(d.get("id", ""))
		if id == "":
			continue

		if id.begins_with("potion_"):
			# count
			var count_i: int = 1
			if d.has("count"):
				count_i = int(d.get("count", 1))
			elif d.has("opts") and d["opts"] is Dictionary:
				count_i = int((d["opts"] as Dictionary).get("count", 1))

			# rarity (prefer opts.rarity)
			var rarity_s: String = "Common"
			if d.has("rarity"):
				rarity_s = String(d.get("rarity", "Common"))
			if d.has("opts") and d["opts"] is Dictionary:
				var o_any: Variant = d["opts"]
				if typeof(o_any) == TYPE_DICTIONARY:
					var o: Dictionary = o_any
					var r2 := String(o.get("rarity", ""))
					if r2 != "":
						rarity_s = r2

			var row: Dictionary = {
				"count": float(count_i),
				"equipable": false,
				"id": id,
				"opts": {
					"affixes": [],
					"archetype": "Consumable",
					"durability_current": 0.0,
					"durability_max": 0.0,
					"ilvl": 1.0,
					"rarity": rarity_s,
					"weight": 0.0
				},
				"rarity": rarity_s
			}
			canon.append(row)
		else:
			canon.append(d)

	player["inventory"] = canon
	inv = canon

	# 2) Group stackables (potions by id|rarity|ilvl; others by id)
	var totals: Dictionary = {}     # key -> count
	var exemplars: Dictionary = {}  # key -> exemplar row

	for v2 in inv:
		if not (v2 is Dictionary):
			continue
		var d2: Dictionary = v2
		if not _is_stackable_row(d2):
			continue
		var key := _stack_key_for(d2)
		if key == "":
			continue
		totals[key] = int(totals.get(key, 0)) + _row_count(d2)
		if not exemplars.has(key):
			exemplars[key] = d2

	# 3) Rebuild inventory: keep non-stackables; write merged stacks
	var merged: Array = []
	for v3 in inv:
		if not (v3 is Dictionary):
			continue
		var d3: Dictionary = v3
		if _is_stackable_row(d3):
			continue
		merged.append(d3)

	for k in totals.keys():
		var exemplar_any: Variant = exemplars[k]
		if typeof(exemplar_any) != TYPE_DICTIONARY:
			continue
		var exemplar: Dictionary = exemplar_any
		var id3: String = String(exemplar.get("id", ""))
		var count3: int = int(totals[k])

		if id3.begins_with("potion_") and exemplar.has("opts") and exemplar["opts"] is Dictionary:
			var o_ex: Dictionary = exemplar["opts"]
			var rarity_ex: String = String(o_ex.get("rarity", "Common"))
			var row2: Dictionary = {
				"count": float(count3),
				"equipable": false,
				"id": id3,
				"opts": {
					"affixes": (o_ex.get("affixes", []) as Array) if (o_ex.get("affixes", []) is Array) else [],
					"archetype": "Consumable",
					"durability_current": 0.0,
					"durability_max": 0.0,
					"ilvl": 1.0,
					"rarity": rarity_ex,
					"weight": 0.0
				},
				"rarity": rarity_ex
			}
			merged.append(row2)
		else:
			var flat: Dictionary = exemplar.duplicate(true)
			flat["count"] = count3
			flat["equipable"] = bool(flat.get("equipable", false))
			if not flat.has("rarity"):
				flat["rarity"] = "Common"
			merged.append(flat)

	player["inventory"] = merged
	gs["player"] = player
	SaveManager.save_game(gs, slot)
