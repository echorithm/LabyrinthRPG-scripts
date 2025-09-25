extends RefCounted
class_name GearGen
## Minimal gear generator (v2a): non-stackable items with durability/weight.
## Affixes & stats come later. Rarity is a full name ("Common", "Uncommon", ...).

const _S := preload("res://persistence/util/save_utils.gd")

# Durability schedules (from your tables; compacted)
static func _armor_dmax(archetype: String, ilvl: int) -> int:
	var b := int(ceil(float(max(1, ilvl)) / 5.0))
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
	var b := int(ceil(float(max(1, ilvl)) / 5.0))
	# Power: Sword/Mace; Finesse: Spear/Bow
	if family in ["Sword","Mace"]:
		return [0,120,130,140,155,165,180][b]
	else:
		return [0,100,110,120,130,140,150][b]

# Weights (from your table)
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
		_:       return 8

static func _accessory_weight(slot: String) -> int:
	return 1

# ------------------ Public builders ------------------

static func make_armor(ilvl: int, rarity: String, archetype: String) -> Dictionary:
	var dmax := _armor_dmax(archetype, ilvl)
	return {
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

static func make_weapon(ilvl: int, rarity: String, family: String) -> Dictionary:
	var dmax := _weapon_dmax(family, ilvl)
	return {
		"id": _weapon_id(family),
		"count": 1,
		"ilvl": ilvl,
		"archetype": family, # temporary; you may want Power/Finesse later
		"rarity": rarity,
		"affixes": [],
		"durability_max": dmax,
		"durability_current": dmax,
		"weight": float(_weapon_weight(family))
	}

static func make_accessory(ilvl: int, rarity: String, slot: String) -> Dictionary:
	# Accessories are non-durable in your plan → durability_max=0 would make them stack.
	# We want unique pieces, so give tiny 1 durability (never actually used) or keep 0 but add uid.
	# We'll keep non-durable but unique by adding uid on mirror (ok for now).
	return {
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
