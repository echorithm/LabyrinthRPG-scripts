extends RefCounted
class_name ShopResolver
## ADR-aligned, rule-driven "what a shop offers" builder.
## Offers ALL tiers up to current building rarity.

const _SaveVillage := preload("res://scripts/village/persistence/village_save_utils.gd")
const EconomyUtils := preload("res://scripts/village/util/EconomyUtils.gd")

const ITEMS_PATH := "res://data/items/catalog.json"
const BUILDINGS_PATH := "res://data/village/buildings_catalog.json"

# ----------------------------- File IO ---------------------------------------

static func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return (parsed as Dictionary) if (parsed is Dictionary) else {}

static func _items_map() -> Dictionary:
	var d: Dictionary = _load_json(ITEMS_PATH)
	var m: Dictionary = (d.get("items", {}) as Dictionary) if (d.get("items", {}) is Dictionary) else {}
	print("[ShopResolver] IO ok -> %s keys=%d" % [ITEMS_PATH, m.size()])
	print("[ShopResolver] items_map size=%d" % m.size())
	return m

static func _buildings_map() -> Dictionary:
	var d: Dictionary = _load_json(BUILDINGS_PATH)
	var m: Dictionary = (d.get("entries", {}) as Dictionary) if (d.get("entries", {}) is Dictionary) else {}
	print("[ShopResolver] IO ok -> %s keys=%d" % [BUILDINGS_PATH, m.size()])
	print("[ShopResolver] buildings_map size=%d" % m.size())
	return m

# ----------------------------- Village helpers --------------------------------

static func _village_building_row(instance_id: StringName, slot: int) -> Dictionary:
	var snap: Dictionary = _SaveVillage.load_village(slot)
	var arr_any: Variant = snap.get("buildings", [])
	var arr: Array = (arr_any as Array) if (arr_any is Array) else []
	var iid := String(instance_id)
	for v in arr:
		if v is Dictionary:
			var d := v as Dictionary
			if String(d.get("instance_id", "")) == iid:
				return d
	return {}

static func current_rarity(instance_id: StringName, slot: int) -> String:
	var row := _village_building_row(instance_id, slot)
	var r := String(row.get("rarity", "COMMON"))
	if r.is_empty():
		return "COMMON"
	return r.to_upper()

static func building_kind(instance_id: StringName, slot: int) -> String:
	var row := _village_building_row(instance_id, slot)
	return String(row.get("id", ""))

# ----------------------------- ADR helpers ------------------------------------

static func _rarity_order(r: String) -> int:
	match r.to_upper():
		"COMMON", "C": return 0
		"UNCOMMON", "U": return 1
		"RARE", "R": return 2
		"EPIC", "E": return 3
		"ANCIENT", "A": return 4
		"LEGENDARY", "L": return 5
		"MYTHIC", "M": return 6
		_: return 0

static func _rarity_full(r: String) -> String:
	match r.to_upper():
		"C", "COMMON": return "Common"
		"U", "UNCOMMON": return "Uncommon"
		"R", "RARE": return "Rare"
		"E", "EPIC": return "Epic"
		"A", "ANCIENT": return "Ancient"
		"L", "LEGENDARY": return "Legendary"
		"M", "MYTHIC": return "Mythic"
		_: return "Common"

static func _tiers_up_to(ord_cap: int) -> Array[String]:
	var all: Array[String] = ["COMMON","UNCOMMON","RARE","EPIC","ANCIENT","LEGENDARY","MYTHIC"]
	var out: Array[String] = []
	for i in range(min(ord_cap + 1, all.size())):
		out.append(all[i])
	return out

# ----------------------------- Public API -------------------------------------

static func build_buy_list(instance_id: StringName, slot: int = 1) -> Array[Dictionary]:
	## Returns ADR-driven list of what the vendor sells:
	## [{ id, name, rarity, price }]
	var kind := building_kind(instance_id, slot)
	var rarity := current_rarity(instance_id, slot)
	var cap_ord := _rarity_order(rarity)
	var bmap := _buildings_map()
	var imap := _items_map()

	print("[ShopResolver] build_buy_list iid=%s kind=%s rarity=%s(ord=%d) slot=%d" % [
		String(instance_id), kind, rarity, cap_ord, slot
	])

	# Find building entry by id-kind in catalog
	var entry: Dictionary = {}
	for k in bmap.keys():
		var d_any: Variant = bmap[k]
		if not (d_any is Dictionary):
			continue
		var d: Dictionary = d_any
		if String(d.get("id", "")) == kind:
			entry = d
			break
	print("[ShopResolver] building entry found? %s" % str(not entry.is_empty()))

	# Read sells_groups from building commerce
	var sells_groups: Array[String] = []
	var comm_any: Variant = entry.get("commerce", {})
	if comm_any is Dictionary:
		var comm: Dictionary = comm_any
		var sg_any: Variant = comm.get("COMMON", {}).get("sells_groups", [])
		if sg_any is Array:
			for g in (sg_any as Array):
				if typeof(g) == TYPE_STRING:
					sells_groups.append(String(g))
	print("[ShopResolver] sells_groups= %s count=%d" % [str(sells_groups), sells_groups.size()])

	# Gather items by group and by item economy hints
	var out: Array[Dictionary] = []
	var total_considered := 0
	var total_accepted := 0

	for id_s in imap.keys():
		var it_any: Variant = imap[id_s]
		if not (it_any is Dictionary):
			continue
		var it: Dictionary = it_any
		total_considered += 1

		var group := String(it.get("group", ""))
		if not sells_groups.has(group):
			continue

		# Optional item economy filter (sells_at)
		var allowed := true
		var econ_any: Variant = it.get("economy", {})
		if econ_any is Dictionary:
			var econ: Dictionary = econ_any
			var com_any: Variant = econ.get("COMMON", {})
			if com_any is Dictionary:
				var com: Dictionary = com_any
				if com.has("sells_at") and com["sells_at"] is Array:
					var lst: Array = com["sells_at"]
					var found := false
					for v in lst:
						if typeof(v) == TYPE_STRING and String(v) == kind.replace("_lab","").replace("_", ""):
							found = true
							break
					allowed = found
		if not allowed:
			continue

		# Base unit from pricebook (0 => not for sale)
		var unit := EconomyUtils.base_price(String(id_s))
		if unit <= 0:
			continue

		# For each tier up to current rarity, add a row
		var tiers: Array[String] = _tiers_up_to(cap_ord)
		var name := String(it.get("display_name", id_s))
		for t in tiers:
			out.append({
				"id": String(id_s),
				"name": name,
				"rarity": _rarity_full(t),
				"price": unit
			})
			total_accepted += 1

	print("[ShopResolver] build_buy_list -> total_items=%d considered=%d accepted=%d out=%d"
		% [imap.size(), total_considered, total_accepted, out.size()])
	return out

static func build_sell_list(slot: int = 1) -> Array[String]:
	# For now: ADR only allows selling potions to Alchemist. TradeService further filters.
	return ["potion_"]
