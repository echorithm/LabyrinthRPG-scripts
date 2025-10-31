extends RefCounted
class_name InventoryService
## Inventory & equipment helpers backed by SaveManager (META JSON).
## - Items are dictionaries normalized by MetaSchema.
## - Stackable: durability_max == 0 (has "count")
## - Non-stackable: durability_max > 0 (has unique "uid")
## - Equipment slots store the full item dict (removed from inventory).
##   Unequip puts the item back into inventory (merging if stackable).

const _S     := preload("res://persistence/util/save_utils.gd")
const _Meta  := preload("res://persistence/schemas/meta_schema.gd")

const DEFAULT_SLOT: int = 1

# -------------------------------------------------
# Public: Queries
# -------------------------------------------------
static func list_inventory(slot: int = DEFAULT_SLOT) -> Array:
	## Returns a COPY of the player's inventory array (safe to iterate).
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _pl(gs)
	var inv_any: Variant = _S.dget(pl, "inventory", [])
	var inv: Array = (inv_any as Array) if inv_any is Array else []
	return inv.duplicate(true)

static func list_equipment(slot: int = DEFAULT_SLOT) -> Dictionary:
	## Returns a COPY of equipment dict (slot_name -> item dict or null).
	var gs: Dictionary = SaveManager.load_game(slot)
	var eq: Dictionary = _equipment(_pl(gs))
	return eq.duplicate(true)

static func total_weight(include_equipped: bool = true, slot: int = DEFAULT_SLOT) -> float:
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _pl(gs)
	var total: float = 0.0

	var inv: Array = _inv(pl)
	for it_any in inv:
		if it_any is Dictionary:
			var it: Dictionary = it_any
			var w: float = float(_S.dget(it, "weight", 1.0))
			var dmax: int = int(_S.dget(it, "durability_max", 0))
			if dmax > 0:
				total += w
			else:
				total += w * float(int(_S.dget(it, "count", 1)))

	if include_equipped:
		var eq: Dictionary = _equipment(pl)
		for k in eq.keys():
			var e_any: Variant = eq[k]
			if e_any is Dictionary:
				var e: Dictionary = e_any
				total += float(_S.dget(e, "weight", 1.0))
	return total

# -------------------------------------------------
# Public: Inventory mutation
# -------------------------------------------------
static func add(item_id: String, count: int = 1, opts: Dictionary = {}, slot: int = DEFAULT_SLOT) -> void:
	## Add stackable or non-stackable items with optional overrides in `opts`.
	## opts: { ilvl:int, archetype:String, rarity:String, affixes:Array[String], durability_max:int, durability_current:int, weight:float }
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _pl(gs)
	var inv: Array = _inv(pl)

	# Normalize an item entry using MetaSchema rules.
	var ilvl_guess: int = int(_S.dget(gs, "current_floor", 1))
	var proto: Dictionary = {
		"id": item_id,
		"count": max(1, count),
		"ilvl": int(_S.dget(opts, "ilvl", ilvl_guess)),
		"archetype": String(_S.dget(opts, "archetype", "Light")),
		"rarity": String(_S.dget(opts, "rarity", "Common")),
		"affixes": _S.to_string_array(_S.dget(opts, "affixes", [])),
		"durability_max": int(_S.dget(opts, "durability_max", 0)),
		"durability_current": int(_S.dget(opts, "durability_current", int(_S.dget(opts, "durability_max", 0)))),
		"weight": float(_S.dget(opts, "weight", 1.0)),
	}
	proto = _normalize_item(proto, ilvl_guess)

	var dmax: int = int(_S.dget(proto, "durability_max", 0))
	if dmax <= 0:
		# Stackable merge
		var idx: int = _find_stack(inv, proto)
		if idx >= 0:
			var st: Dictionary = inv[idx]
			st["count"] = int(_S.dget(st, "count", 1)) + max(1, count)
			inv[idx] = st
		else:
			inv.append(proto)
	else:
		# Non-stackable: append N copies (each normalized with uid)
		var n: int = max(1, count)
		for _i in range(n):
			# ensure unique uid per copy
			var copy: Dictionary = proto.duplicate(true)
			copy["uid"] = _gen_uid_if_missing(copy)
			copy["count"] = 1
			inv.append(copy)

	pl["inventory"] = inv
	_save_pl(gs, pl, slot)

static func remove_at(index: int, count: int = 1, slot: int = DEFAULT_SLOT) -> void:
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _pl(gs)
	var inv: Array = _inv(pl)
	if index < 0 or index >= inv.size():
		return

	var it_any: Variant = inv[index]
	if not (it_any is Dictionary):
		inv.remove_at(index)
	else:
		var it: Dictionary = it_any
		var dmax: int = int(_S.dget(it, "durability_max", 0))
		if dmax > 0:
			inv.remove_at(index) # non-stackable: remove entry
		else:
			var c: int = int(_S.dget(it, "count", 1))
			var new_c: int = c - max(1, count)
			if new_c > 0:
				it["count"] = new_c
				inv[index] = it
			else:
				inv.remove_at(index)

	pl["inventory"] = inv
	_save_pl(gs, pl, slot)

static func damage_at(index: int, amount: int, remove_when_broken: bool = true, slot: int = DEFAULT_SLOT) -> int:
	## Returns new durability_current, or -1 if not applicable.
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _pl(gs)
	var inv: Array = _inv(pl)
	if index < 0 or index >= inv.size():
		return -1
	var it_any: Variant = inv[index]
	if not (it_any is Dictionary):
		return -1
	var it: Dictionary = it_any
	var dmax: int = int(_S.dget(it, "durability_max", 0))
	if dmax <= 0:
		return -1
	var cur: int = int(_S.dget(it, "durability_current", dmax))
	cur = max(0, cur - max(0, amount))
	it["durability_current"] = cur
	inv[index] = it
	if remove_when_broken and cur <= 0:
		inv.remove_at(index)
	pl["inventory"] = inv
	_save_pl(gs, pl, slot)
	return cur

# -------------------------------------------------
# Public: Equipment
# -------------------------------------------------
static func equip_from_inventory(index: int, slot_name: String, slot: int = DEFAULT_SLOT) -> bool:
	## Moves a non-stackable item from inventory into an equipment slot.
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _pl(gs)
	var inv: Array = _inv(pl)
	if index < 0 or index >= inv.size():
		return false
	var it_any: Variant = inv[index]
	if not (it_any is Dictionary):
		return false
	var it: Dictionary = it_any
	var dmax: int = int(_S.dget(it, "durability_max", 0))
	if dmax <= 0:
		return false # cannot equip stackable
	# ensure uid
	it["uid"] = _gen_uid_if_missing(it)

	var eq: Dictionary = _equipment(pl)
	# Swap: if something already equipped in slot, return it to inventory
	var prior: Variant = _S.dget(eq, slot_name, null)
	if prior is Dictionary:
		var back: Dictionary = prior
		inv.append(back)
	# Move selected item into slot
	eq[slot_name] = it
	inv.remove_at(index)

	pl["inventory"] = inv
	pl["loadout"] = {"equipment": eq, "weapon_tags": _S.to_string_array(_S.dget(_S.to_dict(_S.dget(pl, "loadout", {})), "weapon_tags", []))}
	_save_pl(gs, pl, slot)
	return true

static func unequip_to_inventory(slot_name: String, slot: int = DEFAULT_SLOT) -> bool:
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _pl(gs)
	var eq: Dictionary = _equipment(pl)
	if not eq.has(slot_name):
		return false
	var it_any: Variant = eq[slot_name]
	if it_any == null:
		return false
	if not (it_any is Dictionary):
		return false
	var it: Dictionary = it_any
	eq[slot_name] = null

	var inv: Array = _inv(pl)
	inv.append(it) # non-stackable; keep as separate entry
	pl["inventory"] = inv
	pl["loadout"] = {"equipment": eq, "weapon_tags": _S.to_string_array(_S.dget(_S.to_dict(_S.dget(pl, "loadout", {})), "weapon_tags", []))}
	_save_pl(gs, pl, slot)
	return true

# -------------------------------------------------
# Internal helpers
# -------------------------------------------------
static func _pl(gs: Dictionary) -> Dictionary:
	# Ensure META has the v3 player shape.
	var norm: Dictionary = _Meta.normalize(gs)
	# We DO NOT write to disk here; SaveManager handles saves on mutation.
	return _S.to_dict(_S.dget(norm, "player", {}))

static func _inv(pl: Dictionary) -> Array:
	var inv_any: Variant = _S.dget(pl, "inventory", [])
	return (inv_any as Array) if inv_any is Array else []

static func _equipment(pl: Dictionary) -> Dictionary:
	var lo: Dictionary = _S.to_dict(_S.dget(pl, "loadout", {}))
	var eq: Dictionary = _S.to_dict(_S.dget(lo, "equipment", {}))
	# Backfill missing slots if needed
	if eq.is_empty():
		eq = {
			"head": null, "chest": null, "legs": null, "boots": null,
			"mainhand": null, "offhand": null,
			"ring1": null, "ring2": null, "amulet": null
		}
	return eq

static func _save_pl(gs: Dictionary, pl: Dictionary, slot: int) -> void:
	gs["player"] = pl
	SaveManager.save_game(gs, slot)

static func _normalize_item(it_in: Dictionary, ilvl_guess: int) -> Dictionary:
	# Use MetaSchema normalization so the shape stays consistent.
	return _Meta.normalize({"player": {"inventory": [it_in]}, "current_floor": ilvl_guess}).get("player", {}).get("inventory", [])[0]

static func _find_stack(inv: Array, proto: Dictionary) -> int:
	# Find a compatible stack (no durability, same id/ilvl/archetype/rarity/affixes)
	var pid: String = String(_S.dget(proto, "id", ""))
	var pilvl: int = int(_S.dget(proto, "ilvl", 1))
	var parch: String = String(_S.dget(proto, "archetype", ""))
	var prar: String = String(_S.dget(proto, "rarity", ""))
	var paff: Array[String] = _S.to_string_array(_S.dget(proto, "affixes", []))
	for i in range(inv.size()):
		var it_any: Variant = inv[i]
		if not (it_any is Dictionary):
			continue
		var it: Dictionary = it_any
		if int(_S.dget(it, "durability_max", 0)) != 0:
			continue # not stackable
		if String(_S.dget(it, "id", "")) != pid:
			continue
		if int(_S.dget(it, "ilvl", 1)) != pilvl:
			continue
		if String(_S.dget(it, "archetype", "")) != parch:
			continue
		if String(_S.dget(it, "rarity", "")) != prar:
			continue
		# compare affixes
		var a2: Array[String] = _S.to_string_array(_S.dget(it, "affixes", []))
		if a2.size() != paff.size():
			continue
		var all_match: bool = true
		for j in range(paff.size()):
			if String(a2[j]) != String(paff[j]):
				all_match = false
				break
		if all_match:
			return i
	return -1

static func _gen_uid_if_missing(it: Dictionary) -> String:
	var uid: String = String(_S.dget(it, "uid", ""))
	if uid.is_empty():
		uid = _gen_uid()
	return uid

static func _gen_uid() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var a: int = _S.now_ts() & 0x7FFFFFFF
	var b: int = int(rng.randi() & 0x7FFFFFFF)
	return "u%08x%08x" % [a, b]
