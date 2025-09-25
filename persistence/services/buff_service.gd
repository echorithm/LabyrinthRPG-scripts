extends RefCounted
class_name BuffService
## Unified buff pipeline:
## - META.permanent_blessings        (Array[String] or Array[Dictionary{id}])
## - META.queued_blessings_next_run  (moved into RUN on start)
## - RUN.buffs                       (Array[String] runtime toggles/boons)
## - Equipment affixes               (derived → buff ids; recomputed each call)

const _S    := preload("res://persistence/util/save_utils.gd")
const _Meta := preload("res://persistence/schemas/meta_schema.gd")

const DEFAULT_SLOT: int = 1

# Call this at the start of a run (or when returning to village then re-entering).
static func on_run_start(slot: int = DEFAULT_SLOT) -> void:
	var gs: Dictionary = SaveManager.load_game(slot)
	var rs: Dictionary = SaveManager.load_run(slot)

	# 1) Move queued blessings (next-run) from META → RUN.buffs, then clear the queue in META.
	var queued_ids: Array[String] = _extract_buff_ids(_S.dget(gs, "queued_blessings_next_run", []))
	var run_buffs: Array[String] = _extract_buff_ids(_S.dget(rs, "buffs", []))
	for id in queued_ids:
		if not run_buffs.has(id):
			run_buffs.append(id)
	gs["queued_blessings_next_run"] = []
	rs["buffs"] = run_buffs
	SaveManager.save_game(gs, slot)
	SaveManager.save_run(rs, slot)

	# 2) Immediately rebuild buffs so equipment affixes are reflected.
	rebuild_run_buffs(slot)

# Rebuild RUN.buffs by combining: permanent META + current RUN buffs + equipment affixes (derived).
static func rebuild_run_buffs(slot: int = DEFAULT_SLOT) -> Array[String]:
	var gs: Dictionary = SaveManager.load_game(slot)
	var rs: Dictionary = SaveManager.load_run(slot)

	var meta_perm: Array[String] = _extract_buff_ids(_S.dget(gs, "permanent_blessings", []))
	var run_ids:   Array[String] = _extract_buff_ids(_S.dget(rs, "buffs", []))
	var eq_ids:    Array[String] = _derive_equipment_affix_buffs(rs, gs)

	var union: Array[String] = []
	for id in meta_perm:
		if not union.has(id): union.append(id)
	for id in run_ids:
		if not union.has(id): union.append(id)
	for id in eq_ids:
		if not union.has(id): union.append(id)

	rs["buffs"] = union
	SaveManager.save_run(rs, slot)
	return union

# ---- helpers ----

static func _extract_buff_ids(src_any: Variant) -> Array[String]:
	# Accept either Array[String] or Array[Dictionary]{ id = String }
	var out: Array[String] = []
	if src_any is Array:
		for v in (src_any as Array):
			match typeof(v):
				TYPE_STRING:
					var s := String(v)
					if not s.is_empty() and not out.has(s):
						out.append(s)
				TYPE_DICTIONARY:
					var d: Dictionary = v
					var id: String = String(_S.dget(d, "id", ""))
					if not id.is_empty() and not out.has(id):
						out.append(id)
				_:
					pass
	return out

static func _derive_equipment_affix_buffs(rs: Dictionary, gs: Dictionary) -> Array[String]:
	# For now, treat each affix string on equipped items as a buff id (1:1).
	# Looks up equipped uids in RUN.inventory first; falls back to META.player.inventory as safety.
	var out: Array[String] = []
	var eq_any: Variant = _S.dget(rs, "equipment", {})
	var eq: Dictionary = (eq_any as Dictionary) if eq_any is Dictionary else {}

	# Build quick uid→item indices for RUN and META
	var run_inv: Array = []
	var rinv_any: Variant = _S.dget(rs, "inventory", [])
	if rinv_any is Array: run_inv = rinv_any as Array

	var meta_inv: Array = []
	var pl: Dictionary = (_S.dget(gs, "player", {}) as Dictionary) if _S.dget(gs, "player", {}) is Dictionary else {}
	var pinv_any: Variant = _S.dget(pl, "inventory", [])
	if pinv_any is Array: meta_inv = pinv_any as Array

	var uid_map_run: Dictionary = {}
	for i in range(run_inv.size()):
		var row_any: Variant = run_inv[i]
		if row_any is Dictionary:
			var uid: String = String(_S.dget(row_any, "uid", ""))
			if not uid.is_empty():
				uid_map_run[uid] = i
	var uid_map_meta: Dictionary = {}
	for i in range(meta_inv.size()):
		var row_any: Variant = meta_inv[i]
		if row_any is Dictionary:
			var uid: String = String(_S.dget(row_any, "uid", ""))
			if not uid.is_empty():
				uid_map_meta[uid] = i

	# Collect affixes from each equipped slot
	for slot_name in ["head","chest","legs","boots","mainhand","offhand","ring1","ring2","amulet"]:
		var uid_any: Variant = eq.get(slot_name, null)
		if uid_any == null: continue
		var uid: String = String(uid_any)
		if uid.is_empty(): continue

		var row: Dictionary = {}
		if uid_map_run.has(uid):
			row = run_inv[int(uid_map_run[uid])]
		elif uid_map_meta.has(uid):
			row = meta_inv[int(uid_map_meta[uid])]
		else:
			continue

		var dmax: int = int(_S.dget(row, "durability_max", 0))
		if dmax <= 0:
			continue # ignore stackables in equipment by mistake

		var aff: Array[String] = _S.to_string_array(_S.dget(row, "affixes", []))
		for a in aff:
			if not a.is_empty() and not out.has(a):
				out.append(a)

	return out
