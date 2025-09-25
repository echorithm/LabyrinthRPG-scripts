extends RefCounted
class_name ItemResolver
## Converts LootSystem's loot dictionary into concrete items for RewardService.grant().

const _S := preload("res://persistence/util/save_utils.gd")
const GearGen := preload("res://scripts/items/GearGen.gd")

static func resolve(loot: Dictionary) -> Array[Dictionary]:
	# Output shape (per item): { "id": String, "count": int, "opts": Dictionary }
	var out: Array[Dictionary] = []

	var cat: String = String(_S.dget(loot, "category", ""))
	if cat.is_empty():
		return out

	var r_letter: String = String(_S.dget(loot, "rarity", "U")) # C/U/R/E/A/L/M
	var rarity_name: String = _rarity_name_for_letter(r_letter)

	match cat:
		"health_potion":
			out.append(_mk_stack("potion_health", _count_for_potion(r_letter), rarity_name))
		"mana_potion":
			out.append(_mk_stack("potion_mana", _count_for_potion(r_letter), rarity_name))
		"potion_escape":
			if r_letter != "C":
				out.append(_mk_stack("potion_escape", 1, rarity_name))

		"skill_book":
			if _allows_books(loot):
				out.append(_mk_book(true, r_letter))
		"spell_book":
			if _allows_books(loot):
				out.append(_mk_book(false, r_letter))

		"armor":
			var ilvl := SaveManager.get_current_floor(SaveManager.DEFAULT_SLOT)
			var arche := _pick_armor_archetype(ilvl)
			out.append(GearGen.make_armor(ilvl, rarity_name, arche))

		"weapon":
			var ilvl := SaveManager.get_current_floor(SaveManager.DEFAULT_SLOT)
			var family := _pick_weapon_family(ilvl)
			out.append(GearGen.make_weapon(ilvl, rarity_name, family))

		"accessory":
			var ilvl := SaveManager.get_current_floor(SaveManager.DEFAULT_SLOT)
			var slot := "ring" if (ilvl % 2 == 0) else "amulet"   # <-- fixed ternary
			out.append(GearGen.make_accessory(ilvl, rarity_name, slot))

		_:
			pass

	# Filter any empties
	var filtered: Array[Dictionary] = []
	for it_any in out:
		if typeof(it_any) == TYPE_DICTIONARY:
			var it: Dictionary = it_any
			if int(_S.dget(it, "count", 0)) > 0:
				filtered.append(it)
	return filtered

# ---------------- internals ----------------

static func _mk_stack(id_str: String, count: int, rarity_name: String) -> Dictionary:
	if count <= 0:
		return {}
	return {
		"id": id_str,
		"count": count,
		"opts": {
			"ilvl": 1,
			"archetype": "Consumable",
			"rarity": rarity_name,
			"affixes": [],
			"durability_max": 0,
			"durability_current": 0,
			"weight": 0.0
		}
	}

static func _mk_book(is_weapon: bool, r_letter: String) -> Dictionary:
	var tier: String = _book_tier_for_letter(r_letter)
	var id_str: String = "book_weapon_%s" % [tier] if is_weapon else "book_element_%s" % [tier]
	return {
		"id": id_str,
		"count": 1,
		"opts": {
			"ilvl": 1,
			"archetype": "Consumable",
			"rarity": _rarity_name_for_letter(r_letter),
			"affixes": [],
			"durability_max": 0,
			"durability_current": 0,
			"weight": 0.0
		}
	}

static func _count_for_potion(r_letter: String) -> int:
	match r_letter:
		"R": return 2
		"E", "A", "L", "M": return 3
		_: return 1

static func _rarity_name_for_letter(r_letter: String) -> String:
	match r_letter:
		"C": return "Common"
		"U": return "Uncommon"
		"R": return "Rare"
		"E": return "Epic"
		"A": return "Ancient"
		"L": return "Legendary"
		"M": return "Mythic"
		_:   return "Uncommon"

static func _book_tier_for_letter(r_letter: String) -> String:
	match r_letter:
		"C": return "common"
		"U": return "uncommon"
		"R": return "rare"
		"E": return "epic"
		"A", "L", "M": return "legendary"
		_: return "uncommon"

static func _allows_books(loot: Dictionary) -> bool:
	var src: String = String(_S.dget(loot, "source", ""))
	var r: String = String(_S.dget(loot, "rarity", "U"))
	var allowed_by_src := {
		"trash": false,
		"elite": true,
		"boss": true,
		"common_chest": true,
		"rare_chest": true
	}
	if not bool(allowed_by_src.get(src, false)):
		return false
	return r != "C"

static func _pick_armor_archetype(ilvl: int) -> String:
	var b := int(ceil(float(max(1, ilvl)) / 5.0))
	match b % 3:
		0: return "Heavy"
		1: return "Light"
		2: return "Mage"
	return "Light"

static func _pick_weapon_family(ilvl: int) -> String:
	match ilvl % 4:
		0: return "Sword"
		1: return "Spear"
		2: return "Bow"
		_: return "Mace"
