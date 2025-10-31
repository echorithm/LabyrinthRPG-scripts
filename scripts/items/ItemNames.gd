extends Node

@export var catalog_path: String = "res://data/items/catalog.json"

var _names: Dictionary = {}
var _loaded: bool = false

func _ready() -> void:
	_load_if_needed()

func display_name(id_str: String) -> String:
	_load_if_needed()
	var e_any: Variant = _names.get(id_str, {})
	if typeof(e_any) != TYPE_DICTIONARY:
		return id_str
	var e: Dictionary = e_any as Dictionary
	return String(e.get("display_name", id_str))

func ctb_cost_for(id_str: String) -> int:
	_load_if_needed()
	var e_any: Variant = _names.get(id_str, {})
	if typeof(e_any) != TYPE_DICTIONARY:
		var defs_any: Variant = _names.get("_defaults", {})
		var defs: Dictionary = (defs_any as Dictionary) if defs_any is Dictionary else {}
		return int(defs.get("ctb_cost", 100))
	var e: Dictionary = e_any as Dictionary
	return int(e.get("ctb_cost", int((_names.get("_defaults", {}) as Dictionary).get("ctb_cost", 100))))

func _load_if_needed() -> void:
	if _loaded:
		return
	_loaded = true

	var fa: FileAccess = FileAccess.open(catalog_path, FileAccess.READ)
	if fa == null:
		push_error("ItemNames: missing catalog at %s" % catalog_path)
		return
	var txt: String = fa.get_as_text()
	fa.close()

	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("ItemNames: catalog json invalid.")
		return

	var d: Dictionary = parsed as Dictionary
	var defs_any: Variant = d.get("defaults", {})
	var defs: Dictionary = (defs_any as Dictionary) if defs_any is Dictionary else {}

	_names.clear()
	_names["_defaults"] = defs

	var items_any: Variant = d.get("items", {})
	var items: Dictionary = (items_any as Dictionary) if items_any is Dictionary else {}
	for k_any in items.keys():
		var k: String = String(k_any)
		var e_any: Variant = items[k_any]
		if typeof(e_any) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = e_any as Dictionary
		var row: Dictionary = {}
		row["display_name"] = String(e.get("display_name", k))
		row["group"] = String(e.get("group", "misc"))
		row["stackable"] = bool(e.get("stackable", bool(defs.get("stackable", true))))
		row["weight"] = float(e.get("weight", float(defs.get("weight", 0.0))))
		row["ctb_cost"] = int(e.get("ctb_cost", int(defs.get("ctb_cost", 100))))
		_names[k] = row

func get_display(id_str: String, opts: Dictionary = {}) -> String:
	# Friendly name, optionally with rarity suffix if provided.
	var base := display_name(id_str)
	var r := String(opts.get("rarity", ""))
	return base if r.is_empty() else "%s (%s)" % [base, r]

# UI helper: rarity letter/name → Color
static func rarity_color(r: String) -> Color:
	var key := r.strip_edges().to_upper()
	match key:
		"C", "COMMON":     return Color.hex(0xbfc3c7ff) # gray
		"U", "UNCOMMON":   return Color.hex(0x67c37bff) # green
		"R", "RARE":       return Color.hex(0x5aa0ffff) # blue
		"E", "EPIC":       return Color.hex(0xb277ffff) # purple
		"A", "ANCIENT":    return Color.hex(0xe7a64bff) # orange
		"L", "LEGENDARY":  return Color.hex(0xffc342ff) # gold
		"M", "MYTHIC":     return Color.hex(0xff6bd3ff) # pink
		_:                 return Color.WHITE
