# EconomyUtils.gd
extends RefCounted
class_name EconomyUtils

const ITEMS_PATH := "res://data/items/catalog.json"

static var _items_cache: Dictionary = {}   # { id: dict }
static var _loaded: bool = false

static func _load_items() -> void:
	if _loaded:
		return
	var f := FileAccess.open(ITEMS_PATH, FileAccess.READ)
	if f == null:
		_items_cache = {}
		_loaded = true
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	var root: Dictionary = (parsed as Dictionary) if (parsed is Dictionary) else {}
	var items_any: Variant = root.get("items", {})
	var items: Dictionary = (items_any as Dictionary) if (items_any is Dictionary) else {}
	_items_cache = items
	_loaded = true

static func _itm(id: String) -> Dictionary:
	_load_items()
	var any: Variant = _items_cache.get(id, {})
	return (any as Dictionary) if (any is Dictionary) else {}

static func is_potion_id(id: String) -> bool:
	return id.begins_with("potion_")

# ----- Rarity math (Value multipliers) -----
static func _rarity_value_mult(r: String) -> float:
	var key := r.strip_edges()
	if key.is_empty(): return 1.0
	key = key.to_upper()
	match key:
		"C", "COMMON":     return 1.00
		"U", "UNCOMMON":   return 4.50
		"R", "RARE":       return 18.00
		"E", "EPIC":       return 63.00
		"A", "ANCIENT":    return 189.00
		"L", "LEGENDARY":  return 472.50
		"M", "MYTHIC":     return 945.00
		_:                 return 1.00

static func _rarity_full(r: String) -> String:
	var k := r.strip_edges()
	if k.is_empty(): return "Common"
	k = k.to_upper()
	match k:
		"C","COMMON": return "Common"
		"U","UNCOMMON": return "Uncommon"
		"R","RARE": return "Rare"
		"E","EPIC": return "Epic"
		"A","ANCIENT": return "Ancient"
		"L","LEGENDARY": return "Legendary"
		"M","MYTHIC": return "Mythic"
		_: return "Common"

# ----- BIV + shop factors from catalog -----
static func biv_common(id: String) -> int:
	var it := _itm(id)
	return int(it.get("biv_common", 0))

static func shop_sell_factor(id: String) -> float:
	var it := _itm(id)
	var econ_any: Variant = it.get("economy", {})
	if econ_any is Dictionary:
		var econ: Dictionary = econ_any
		var com_any: Variant = econ.get("COMMON", {})
		if com_any is Dictionary:
			var com: Dictionary = com_any
			if com.has("shop_sell_factor"):
				return float(com["shop_sell_factor"])
	return 1.30  # fallback

static func shop_buy_factor(id: String) -> float:
	var it := _itm(id)
	var econ_any: Variant = it.get("economy", {})
	if econ_any is Dictionary:
		var econ: Dictionary = econ_any
		var com_any: Variant = econ.get("COMMON", {})
		if com_any is Dictionary:
			var com: Dictionary = com_any
			if com.has("shop_buy_factor"):
				return float(com["shop_buy_factor"])
	return 0.35  # fallback

# ----- Public pricing helpers (replace legacy stubs) -----
static func base_price(id: String) -> int:
	# Legacy alias: now returns biv_common(id)
	return biv_common(id)

static func price_for_rarity(id: String, rarity_in: String) -> int:
	var biv := biv_common(id)
	if biv <= 0:
		return 0
	var mult := _rarity_value_mult(rarity_in)
	return int(round(float(biv) * mult))

static func buy_price_vendor(id: String, rarity_in: String) -> int:
	# What the shop charges the player
	var base := price_for_rarity(id, rarity_in)
	if base <= 0:
		return 0
	return int(round(float(base) * shop_sell_factor(id)))

static func sell_price_vendor(id: String, rarity_in: String) -> int:
	# What the shop pays the player
	var base := price_for_rarity(id, rarity_in)
	if base <= 0:
		return 0
	return int(round(float(base) * shop_buy_factor(id)))

# EconomyUtils.gd  (add anywhere near the other helpers)
static func display_name(id: String) -> String:
	var it := _itm(id)
	return String(it.get("display_name", id)).strip_edges()
	
static func group_of(id: String) -> String:
	_load_items()
	var it: Dictionary = _itm(id)
	return String(it.get("group", ""))
	
static func is_treasure_id(id: String) -> bool:
	return group_of(id) == "treasure"
