extends RefCounted
class_name GearGen
## Minimal gear generator (v2b): non-stackable items with durability/weight + affixes.

const _S := preload("res://persistence/util/save_utils.gd")
const AffixService := preload("res://scripts/items/AffixService.gd")

# Durability schedules
static func _armor_dmax(archetype: String, ilvl: int) -> int:
	var b: int = int(ceil(float(max(1, ilvl)) / 5.0))
	match archetype:
		"Light":
			return [0,90,100,110,120,130,140][b]
		"Heavy":
			return [0,130,145,160,175,190,205][b]
		"Mage":
			return [0,100,110,120,135,145,155][b]
		_:
			return 110

static func _weapon_dmax(family: String, ilvl: int) -> int:
	var b: int = int(ceil(float(max(1, ilvl)) / 5.0))
	if family in ["Sword","Mace"]:
		return [0,120,130,140,155,165,180][b]
	else:
		return [0,100,110,120,130,140,150][b]

# Weights
static func _armor_weight(archetype: String) -> int:
	match archetype:
		"Light": return 6
		"Heavy": return 12
		"Mage":  return 8
		_:       return 8

static func _weapon_weight(family: String) -> int:
	match family:
		"Sword": return 8
		"Mace":  return 10
		"Spear": return 7
		"Bow":   return 5
		_:      return 8

static func _accessory_weight(_slot: String) -> int:
	return 1

# ------------------ Public builders ------------------
static func make_armor(ilvl: int, rarity: String, archetype: String, seed_tuple: Array = []) -> Dictionary:
	var dmax: int = max(1, _armor_dmax(archetype, ilvl))
	var row := {
		"id": _armor_id(archetype),
		"count": 1,
		"ilvl": ilvl,
		"archetype": archetype,
		"rarity": rarity,
		"affixes": [],
		"durability_max": dmax,
		"durability_current": dmax,
		"weight": float(_armor_weight(archetype))
	}
	# Roll affixes
	row["affixes"] = AffixService.roll_affixes(ilvl, _rar(rarity), _armor_slot_hint(archetype), row["id"], seed_tuple)
	return row

static func make_weapon(ilvl: int, rarity: String, family: String, seed_tuple: Array = []) -> Dictionary:
	var dmax: int = max(1, _weapon_dmax(family, ilvl))
	var row := {
		"id": _weapon_id(family),
		"count": 1,
		"ilvl": ilvl,
		"archetype": family,
		"rarity": rarity,
		"affixes": [],
		"durability_max": dmax,
		"durability_current": dmax,
		"weight": float(_weapon_weight(family))
	}
	row["affixes"] = AffixService.roll_affixes(ilvl, _rar(rarity), "mainhand", row["id"], seed_tuple)
	return row

static func make_accessory(ilvl: int, rarity: String, slot: String, seed_tuple: Array = []) -> Dictionary:
	var row := {
		"id": _accessory_id(slot),
		"count": 1,
		"ilvl": ilvl,
		"archetype": "Accessory",
		"rarity": rarity,
		"affixes": [],
		"durability_max": 0,
		"durability_current": 0,
		"weight": float(_accessory_weight(slot))
	}
	# Godot uses Python-style ternary, not C-style.
	var pool_slot := "amulet" if slot.to_lower() == "amulet" else "ring"
	row["affixes"] = AffixService.roll_affixes(ilvl, _rar(rarity), pool_slot, row["id"], seed_tuple)
	return row

# ------------------ IDs ------------------
static func _armor_id(archetype: String) -> String:
	match archetype:
		"Heavy": return "armor_heavy"
		"Mage":  return "armor_mage"
		_:      return "armor_light"

static func _weapon_id(family: String) -> String:
	match family:
		"Spear": return "weapon_spear"
		"Mace":  return "weapon_mace"
		"Bow":   return "weapon_bow"
		_:      return "weapon_sword"

static func _accessory_id(slot: String) -> String:
	match slot.to_lower():
		"amulet": return "amulet_generic"
		_:        return "ring_generic"

# ------------------ locals ------------------
static func _rar(r: String) -> String:
	# Accept long names ("Common") or short codes already ("U", etc.)
	if r.length() == 1:
		return r
	var m: Dictionary = {
		"Common":"C","Uncommon":"U","Rare":"R","Epic":"E","Ascended":"A","Legendary":"L","Mythic":"M"
	}
	return String(_S.dget(m, r, "U"))

static func _armor_slot_hint(_archetype: String) -> String:
	# We don't know exact slot at creation; use a generic armor pool (chest).
	return "chest"
