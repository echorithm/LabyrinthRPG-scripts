extends Node
class_name TradeService
## ADR rule-driven transactions.
## - Buy list via ShopResolver (no saved stock or counts).
## - BUY unit price  = round(BIV_COMMON * RarityValueMult * shop_sell_factor)
## - SELL unit price = round(BIV_COMMON * RarityValueMult * shop_buy_factor)
## - Per-row rarity purchase & sell supported.
## - Uses items catalog `biv_common` & per-item economy factors.

const _S := preload("res://persistence/util/save_utils.gd")
const SaveManager := preload("res://persistence/SaveManager.gd")
const InventoryService := preload("res://persistence/services/inventory_service.gd")
const VendorsService := preload("res://scripts/village/services/VendorsService.gd")
const _SaveVillage := preload("res://scripts/village/persistence/village_save_utils.gd")
const LedgerSchema := preload("res://scripts/village/persistence/schemas/economy_ledger_schema.gd")
const ShopResolver := preload("res://scripts/village/services/ShopResolver.gd")

const DEFAULT_SLOT: int = 1
const ITEMS_PATH := "res://data/items/catalog.json"

# ─────────────────────────────── Rarity helpers ──────────────────────────────
static func _rarity_full(r: String) -> String:
	var key: String = r.strip_edges()
	if key.is_empty():
		return "Common"
	key = key.to_upper()
	match key:
		"C", "COMMON":
			return "Common"
		"U", "UNCOMMON":
			return "Uncommon"
		"R", "RARE":
			return "Rare"
		"E", "EPIC":
			return "Epic"
		"A", "ANCIENT":
			return "Ancient"
		"L", "LEGENDARY":
			return "Legendary"
		"M", "MYTHIC":
			return "Mythic"
		_:
			return "Common"

# Economy value multipliers (DBZ chain)
static func _rarity_value_mult(r: String) -> float:
	var f: String = _rarity_full(r)
	match f:
		"Common":
			return 1.00
		"Uncommon":
			return 4.50
		"Rare":
			return 18.00
		"Epic":
			return 63.00
		"Ancient":
			return 189.00
		"Legendary":
			return 472.50
		"Mythic":
			return 945.00
		_:
			return 1.00

# Treat anything starting with "potion_" as a potion (covers Escape Potion)
static func _is_potion_or_escape(id: String) -> bool:
	return id.begins_with("potion_")

# ─────────────────────────────── Items catalog IO ────────────────────────────
static func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return (parsed as Dictionary) if (parsed is Dictionary) else {}

static func _items_root() -> Dictionary:
	var root := _load_json(ITEMS_PATH)
	var items_any: Variant = root.get("items", {})
	return (items_any as Dictionary) if (items_any is Dictionary) else {}

static func _item_def(id: String) -> Dictionary:
	var items := _items_root()
	var row_any: Variant = items.get(id, {})
	return (row_any as Dictionary) if (row_any is Dictionary) else {}

static func _display_name(id: String) -> String:
	var d := _item_def(id)
	return String(d.get("display_name", id))

static func _group_of(id: String) -> String:
	var d := _item_def(id)
	return String(d.get("group", ""))

static func _biv_common(id: String) -> int:
	var d := _item_def(id)
	return int(d.get("biv_common", 0))

static func _economy_factors(id: String) -> Dictionary:
	var d := _item_def(id)
	var eco_any: Variant = d.get("economy", {})
	var eco: Dictionary = (eco_any as Dictionary) if (eco_any is Dictionary) else {}
	var com_any: Variant = eco.get("COMMON", {})
	var com: Dictionary = (com_any as Dictionary) if (com_any is Dictionary) else {}
	var sell_factor := float(com.get("shop_sell_factor", 1.30)) # vendor sells to player
	var buy_factor  := float(com.get("shop_buy_factor", 0.35))  # vendor buys from player
	return { "sell": sell_factor, "buy": buy_factor }

static func _buy_price_vendor(id: String, rarity: String) -> int:
	var base_i: int = _biv_common(id)
	if base_i <= 0:
		return 0
	var r_mult: float = _rarity_value_mult(rarity)
	var factors: Dictionary = _economy_factors(id)
	var shop_sell_factor := float(factors.get("sell", 1.30))
	return int(round(float(base_i) * r_mult * shop_sell_factor))

static func _sell_price_vendor(id: String, rarity: String) -> int:
	var base_i: int = _biv_common(id)
	if base_i <= 0:
		return 0
	var r_mult: float = _rarity_value_mult(rarity)
	var factors: Dictionary = _economy_factors(id)
	var shop_buy_factor := float(factors.get("buy", 0.35))
	return int(round(float(base_i) * r_mult * shop_buy_factor))

static func _potion_row_canonical(id: String, rarity_in: String, count: int) -> Dictionary:
	var rarity: String = _rarity_full(rarity_in)
	return {
		"count": float(max(1, count)),
		"equipable": false,
		"id": id,
		"opts": {
			"affixes": [],
			"archetype": "Consumable",
			"durability_current": 0.0,
			"durability_max": 0.0,
			"ilvl": 1.0,
			"rarity": rarity,
			"weight": 0.0
		},
		"rarity": rarity
	}

# ───────────────────────────────── Quotes ────────────────────────────────────
static func quote_buy(instance_id: StringName, item_id: String, count: int, slot: int = DEFAULT_SLOT, rarity_in: String = "Common") -> Dictionary:
	if not VendorsService.is_active(instance_id, slot):
		return {"total": 0, "unit": 0}
	var c: int = max(1, count)
	var offer: Dictionary = _find_offer(instance_id, item_id, slot)
	if offer.is_empty():
		return {"total": 0, "unit": 0}
	var rarity: String = String(offer.get("rarity", rarity_in))
	var unit: int = _buy_price_vendor(item_id, rarity)
	var total: int = unit * c
	return {"total": total, "unit": unit}

static func quote_sell(item_id: String, count: int, rarity_in: String = "Common") -> Dictionary:
	if not _is_potion_or_escape(item_id):
		return {"total": 0, "unit": 0}
	var c: int = max(1, count)
	var unit: int = _sell_price_vendor(item_id, rarity_in)
	var total: int = unit * c
	return {"total": total, "unit": unit}

# ───────────────────────────────── Actions ───────────────────────────────────
static func buy(instance_id: StringName, item_id: String, count: int, slot: int = DEFAULT_SLOT, rarity_in: String = "Common") -> Dictionary:
	if not VendorsService.is_active(instance_id, slot):
		return {"ok": false, "reason": "vendor_inactive"}

	var c: int = max(1, count)

	# Validate this id is offered (and get the line’s rarity)
	var offer: Dictionary = _find_offer(instance_id, item_id, slot)
	if offer.is_empty():
		return {"ok": false, "reason": "not_for_sale"}
	var rarity: String = String(offer.get("rarity", rarity_in))

	var unit: int = _buy_price_vendor(item_id, rarity)
	if unit <= 0:
		return {"ok": false, "reason": "no_price"}

	var total: int = unit * c

	# Wallet check
	var gs: Dictionary = SaveManager.load_game(slot)
	var stash_gold: int = int(_S.dget(gs, "stash_gold", 0))
	if stash_gold < total:
		return {"ok": false, "reason": "insufficient_gold", "needed": total - stash_gold}

	# Deduct
	gs["stash_gold"] = stash_gold - total
	SaveManager.save_game(gs, slot)

	# Add to inventory (potions/escape are stackable consumables)
	if _is_potion_or_escape(item_id):
		var pl: Dictionary = _S.to_dict(_S.dget(gs, "player", {}))
		var inv_any: Variant = _S.dget(pl, "inventory", [])
		var inv: Array = (inv_any as Array) if (inv_any is Array) else []
		inv.append(_potion_row_canonical(item_id, rarity, c))
		pl["inventory"] = inv
		gs["player"] = pl
		SaveManager.save_game(gs, slot)
		_SaveVillage.merge_meta_stackables(slot)
	else:
		InventoryService.add(item_id, c, {}, slot) # non-potions if any later

	_append_ledger("BUY", String(instance_id), item_id, c, unit, total, slot)
	print("[TradeService] buy OK id=%s rarity=%s unit=%d x%d total=%d gold_left=%d"
		% [item_id, rarity, unit, c, total, int(_S.dget(SaveManager.load_game(slot), "stash_gold", 0))])
	return {"ok": true, "gold_spent": total, "unit_price": unit}

static func sell(item_id: String, count: int, slot: int = DEFAULT_SLOT, rarity_selected: String = "Common") -> Dictionary:
	if not _is_potion_or_escape(item_id):
		return {"ok": false, "reason": "unsupported_sell"}

	var c: int = max(1, count)

	# Price from rarity
	var unit: int = _sell_price_vendor(item_id, rarity_selected)
	if unit <= 0:
		return {"ok": false, "reason": "no_value"}
	var total: int = unit * c

	# Remove by rarity
	var removed: int = _meta_remove_item_by_rarity(item_id, c, rarity_selected, slot)
	if removed != c:
		return {"ok": false, "reason": "insufficient_items_for_rarity", "removed": removed}

	# Add gold
	var gs: Dictionary = SaveManager.load_game(slot)
	var stash_gold: int = int(_S.dget(gs, "stash_gold", 0))
	gs["stash_gold"] = stash_gold + total
	SaveManager.save_game(gs, slot)

	_append_ledger("SELL", "", item_id, c, unit, total, slot)
	print("[TradeService] sell OK id=%s rarity=%s unit=%d x%d total=%d" % [item_id, rarity_selected, unit, c, total])
	return {"ok": true, "gold_gained": total, "unit_price": unit}

# ─────────────────────────────── Read APIs for UI ────────────────────────────
func get_stock(instance_id: StringName, slot: int = DEFAULT_SLOT) -> Array[Dictionary]:
	# Derived offers (already includes one line per rarity up to building rarity)
	var offers: Array[Dictionary] = ShopResolver.build_buy_list(instance_id, slot)

	var out: Array[Dictionary] = []
	for it in offers:
		var id: String = String(it.get("id", ""))
		if id == "":
			continue
		var rarity_text: String = String(it.get("rarity", "Common"))
		var unit_price: int = _buy_price_vendor(id, rarity_text)
		if unit_price <= 0:
			continue
		out.append({
			"id": StringName(id),
			"name": String(it.get("name", id)),
			"rarity": rarity_text,
			"price": unit_price,
			"count": 1
		})
	print("[TradeService] get_stock iid=%s offers_in=%d stock_out=%d" % [String(instance_id), offers.size(), out.size()])
	return out

# Vendor-aware sellables list:
# - Alchemist: potions (by rarity)
# - Marketplace: treasures (no rarity)
func get_sellables_for(instance_id: StringName, slot: int = DEFAULT_SLOT) -> Array[Dictionary]:
	var kind := _kind_from_instance_id(instance_id)

	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _S.to_dict(_S.dget(gs, "player", {}))
	var inv_any: Variant = _S.dget(pl, "inventory", [])
	var inv: Array = (inv_any as Array) if (inv_any is Array) else []

	var out: Array[Dictionary] = []

	if kind == "alchemist" or kind == "alchemist_lab":
		# POTIONS — split by rarity
		var counts: Dictionary = {}  # "id|rarity" -> total
		for it in inv:
			if not (it is Dictionary):
				continue
			var d: Dictionary = it
			if _row_dmax(d) != 0:
				continue
			var id_s := String(_S.dget(d, "id", ""))
			if id_s == "" or not _is_potion_or_escape(id_s):
				continue
			var rarity_text: String = "Common"
			var opts_any: Variant = _S.dget(d, "opts", {})
			if (opts_any is Dictionary) and (String(_S.dget(opts_any, "rarity", "")) != ""):
				rarity_text = _rarity_full(String(_S.dget(opts_any, "rarity", "")))
			var key := id_s + "|" + rarity_text
			counts[key] = int(counts.get(key, 0)) + _row_count(d)

		for key in counts.keys():
			var parts: PackedStringArray = String(key).split("|")
			var id_s: String = parts[0]
			var rarity_text: String = "Common"
			if parts.size() > 1:
				rarity_text = String(parts[1])
			var unit: int = _sell_price_vendor(id_s, rarity_text)
			out.append({
				"id": StringName(id_s),
				"name": _display_name(id_s),
				"rarity": rarity_text,
				"price": unit,
				"count": int(counts[key])
			})
		return out

	if kind == "marketplace":
		# TREASURES — summed by id (no rarity)
		var counts_t: Dictionary = {} # id -> total
		for it in inv:
			if not (it is Dictionary):
				continue
			var d: Dictionary = it
			if _row_dmax(d) != 0:
				continue
			var id_s := String(_S.dget(d, "id", ""))
			if id_s == "" or _group_of(id_s) != "treasure":
				continue
			counts_t[id_s] = int(counts_t.get(id_s, 0)) + _row_count(d)

		for id_s in counts_t.keys():
			var unit_t: int = _sell_price_vendor(String(id_s), "Common") # treasures have no rarity
			out.append({
				"id": StringName(String(id_s)),
				"name": _display_name(String(id_s)),
				"rarity": "Common",
				"price": unit_t,
				"count": int(counts_t[id_s])
			})
		return out

	# Other buildings: nothing sellable by default
	return out

# Back-compat wrapper (prefer get_sellables_for from call sites)
func get_sellables(_slot: int = DEFAULT_SLOT) -> Array[Dictionary]:
	return []

func get_stash_gold(slot: int = DEFAULT_SLOT) -> int:
	var gs: Dictionary = SaveManager.load_game(slot)
	return int(_S.dget(gs, "stash_gold", 0))

func is_vendor_active(instance_id: StringName, slot: int = DEFAULT_SLOT) -> bool:
	return VendorsService.is_active(instance_id, slot)

# ───────────────────────────────── Internals ─────────────────────────────────
static func _find_offer(instance_id: StringName, item_id: String, slot: int) -> Dictionary:
	var offers: Array[Dictionary] = ShopResolver.build_buy_list(instance_id, slot)
	for it in offers:
		if String(it.get("id", "")) == item_id:
			return it
	return {}

static func _append_ledger(op: String, vendor: String, id: String, count: int, unit_price: int, total: int, slot: int) -> void:
	var snap: Dictionary = _SaveVillage.load_village(slot)
	var econ_any: Variant = snap.get("economy", {})
	var econ: Dictionary = LedgerSchema.validate((econ_any as Dictionary) if (econ_any is Dictionary) else {})

	var row: Dictionary = {
		"ts": Time.get_unix_time_from_system(),
		"op": op, "vendor": vendor, "id": id,
		"count": count, "unit_price": unit_price, "total": total
	}
	var lg_any: Variant = econ.get("ledger", [])
	var lg: Array = (lg_any as Array) if (lg_any is Array) else []
	lg.append(row)
	econ["ledger"] = lg

	if op == "BUY":
		econ["spent_gold_total"] = int(econ.get("spent_gold_total", 0)) + total
	elif op == "SELL":
		econ["earned_gold_total"] = int(econ.get("earned_gold_total", 0)) + total

	snap["economy"] = LedgerSchema.validate(econ)
	_SaveVillage.save_village(snap, slot)

# Inventory shape helpers
static func _row_dmax(d: Dictionary) -> int:
	if d.has("durability_max"):
		return int(d.get("durability_max", 0))
	if d.has("opts") and d["opts"] is Dictionary:
		return int((d["opts"] as Dictionary).get("durability_max", 0))
	return 0

static func _row_count(d: Dictionary) -> int:
	if d.has("count"):
		return int(d.get("count", 1))
	if d.has("opts") and d["opts"] is Dictionary:
		return int((d["opts"] as Dictionary).get("count", 1))
	return 1

# META inventory helpers (remove exact rarity)
static func _meta_remove_item_by_rarity(item_id: String, count: int, rarity: String, slot: int) -> int:
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _S.to_dict(_S.dget(gs, "player", {}))
	var inv_any: Variant = _S.dget(pl, "inventory", [])
	var inv: Array = (inv_any as Array) if (inv_any is Array) else []
	var need: int = max(0, count)
	if need == 0:
		return 0

	var want_rarity: String = _rarity_full(rarity)

	var i: int = 0
	while i < inv.size():
		if need <= 0:
			break

		var v_any: Variant = inv[i]
		if not (v_any is Dictionary):
			i += 1
			continue
		var row: Dictionary = v_any

		if String(_S.dget(row, "id", "")) != item_id:
			i += 1
			continue
		if _row_dmax(row) != 0:
			i += 1
			continue # gear not allowed

		var row_rarity: String = "Common"
		var opts_any: Variant = _S.dget(row, "opts", {})
		if (opts_any is Dictionary) and (String(_S.dget(opts_any, "rarity", "")) != ""):
			row_rarity = _rarity_full(String(_S.dget(opts_any, "rarity", "")))
		if row_rarity != want_rarity:
			i += 1
			continue

		var have: int = _row_count(row)
		var take: int = min(have, need)
		var remain: int = have - take

		if row.has("count"):
			row["count"] = remain
		elif row.has("opts") and row["opts"] is Dictionary:
			var o_any: Variant = row["opts"]
			var o: Dictionary = o_any
			o["count"] = remain
			row["opts"] = o
		else:
			row["count"] = remain

		if remain > 0:
			inv[i] = row
			i += 1
		else:
			inv.remove_at(i)

		need -= take

	pl["inventory"] = inv
	gs["player"] = pl
	SaveManager.save_game(gs, slot)
	return count - need

static func _kind_from_instance_id(iid: StringName) -> String:
	var s := String(iid)
	var at := s.find("@")
	if at <= 0:
		return s
	return s.substr(0, at)  # e.g. "marketplace", "alchemist_lab"
