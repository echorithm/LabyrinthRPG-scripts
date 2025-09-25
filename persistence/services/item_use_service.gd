extends RefCounted
class_name ItemUseService
## Consume stackable items in RUN.inventory and apply effects (out-of-combat).

const _S := preload("res://persistence/util/save_utils.gd")
const CATALOG_PATH := "res://data/items/catalog.json"

static var _cat_loaded: bool = false
static var _cat: Dictionary = {}   # { items: { id -> entry }, defaults: {...} }

# ---------------- Catalog helpers ----------------
static func _load_catalog() -> void:
	if _cat_loaded:
		return
	_cat_loaded = true
	var fa: FileAccess = FileAccess.open(CATALOG_PATH, FileAccess.READ)
	if fa == null:
		return
	var txt: String = fa.get_as_text()
	fa.close()
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) == TYPE_DICTIONARY:
		_cat = parsed as Dictionary

static func _entry(id_str: String) -> Dictionary:
	_load_catalog()
	var items_any: Variant = _cat.get("items", {})
	var items: Dictionary = (items_any as Dictionary) if items_any is Dictionary else {}
	return (items.get(id_str, {}) as Dictionary) if items.has(id_str) else {}

static func _use_payload(id_str: String) -> Dictionary:
	var e: Dictionary = _entry(id_str)
	return (e.get("use", {}) as Dictionary) if e.has("use") else {}

static func _is_potion(id_str: String) -> bool:
	var e: Dictionary = _entry(id_str)
	return String(e.get("group","")) == "consumable"

# ---------------- Public API ----------------
static func use_first(id_str: String, slot: int = SaveManager.DEFAULT_SLOT) -> Dictionary:
	# Finds the first matching stack, applies effect and decrements.
	var rs: Dictionary = SaveManager.load_run(slot)
	var inv_any: Variant = _S.dget(rs, "inventory", [])
	var inv: Array = (inv_any as Array) if inv_any is Array else []

	var idx: int = _find_first_stack_index(inv, id_str)
	if idx < 0:
		return {"consumed": false, "reason": "not_found"}

	return use_at_index(idx, slot)

static func use_at_index(index: int, slot: int = SaveManager.DEFAULT_SLOT) -> Dictionary:
	var rs: Dictionary = SaveManager.load_run(slot)
	var inv_any: Variant = _S.dget(rs, "inventory", [])
	var inv: Array = (inv_any as Array) if inv_any is Array else []

	if index < 0 or index >= inv.size():
		return {"consumed": false, "reason":"oob"}

	var it_any: Variant = inv[index]
	if typeof(it_any) != TYPE_DICTIONARY:
		return {"consumed": false, "reason":"bad_row"}
	var it: Dictionary = it_any as Dictionary

	# Must be stackable (durability_max==0)
	if int(_S.dget(it, "durability_max", 0)) != 0:
		return {"consumed": false, "reason": "not_stackable"}

	var id_str: String = String(_S.dget(it, "id", ""))
	if id_str.is_empty():
		return {"consumed": false, "reason":"no_id"}
	if not _is_potion(id_str):
		return {"consumed": false, "reason":"not_potion"}

	# Apply effect
	var use: Dictionary = _use_payload(id_str)
	var hp_add: int = int(_S.dget(use, "hp", 0))
	var mp_add: int = int(_S.dget(use, "mp", 0))

	var hp0: int = int(_S.dget(rs, "hp", 0))
	var hp_max: int = int(_S.dget(rs, "hp_max", 0))
	var mp0: int = int(_S.dget(rs, "mp", 0))
	var mp_max: int = int(_S.dget(rs, "mp_max", 0))

	var hp1: int = min(hp_max, hp0 + max(0, hp_add))
	var mp1: int = min(mp_max, mp0 + max(0, mp_add))

	# If neither changes, don’t consume.
	if hp1 == hp0 and mp1 == mp0:
		return {"consumed": false, "reason":"no_effect"}

	rs["hp"] = hp1
	rs["mp"] = mp1

	# Decrement stack (remove row if empty)
	var c: int = int(_S.dget(it, "count", 1)) - 1
	if c > 0:
		it["count"] = c
		inv[index] = it
	else:
		inv.remove_at(index)

	rs["inventory"] = inv
	SaveManager.save_run(rs, slot)

	return {"consumed": true, "hp": (hp1 - hp0), "mp": (mp1 - mp0), "index": index}

# ---------------- Internals ----------------
static func _find_first_stack_index(inv: Array, id_str: String) -> int:
	for i in inv.size():
		var e_any: Variant = inv[i]
		if typeof(e_any) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = e_any as Dictionary
		if String(_S.dget(e, "id","")) != id_str:
			continue
		if int(_S.dget(e, "durability_max", 0)) != 0:
			continue
		return i
	return -1
