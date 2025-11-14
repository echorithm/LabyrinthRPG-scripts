#res://scripts/items/ItemResolver.gd
extends RefCounted
class_name ItemResolver
## Converts LootSystem's loot dictionary into concrete items for RewardService.grant().

const _S := preload("res://persistence/util/save_utils.gd")
const GearGen := preload("res://scripts/items/GearGen.gd")

const WEAPON_SKILLS: PackedStringArray = [
	"arc_slash","thrust","skewer","riposte","guard_break","crush","aimed_shot","piercing_bolt"
]
const ELEMENT_SKILLS: PackedStringArray = [
	"shadow_grasp","curse_mark","heal","purify","firebolt","flame_wall","water_jet","tide_surge","stone_spikes","gust"
]

# -------- deterministic RNG (shared pattern with AffixService) --------
static func _rng_from_tuple(tuple: Array) -> RandomNumberGenerator:
	var s := ""
	for v in tuple: s += str(v) + "|"
	var rng := RandomNumberGenerator.new()
	rng.seed = int(s.hash())
	return rng

# Escape caps by rarity (9-floor steps; M effectively infinite)
static func _escape_cap_for_rarity_letter(r_letter: String) -> int:
	match r_letter:
		"C": return 9
		"U": return 18
		"R": return 27
		"E": return 36
		"A": return 45
		"L": return 54
		"M": return 1_000_000
		_:   return 9

static func resolve(loot: Dictionary) -> Array[Dictionary]:
	# Output shape (per item): { "id": String, "count": int, "opts": Dictionary }
	var out: Array[Dictionary] = []

	var cat: String = String(_S.dget(loot, "category", ""))
	if cat.is_empty():
		return out

	var r_letter: String = String(_S.dget(loot, "rarity", "U")) # C/U/R/E/A/L/M
	var rarity_name: String = _rarity_name_for_letter(r_letter)
	var roll_index: int = int(_S.dget(loot, "roll_index", 0))   # optional decorrelation index

	match cat:
		"health_potion":
			out.append(_mk_stack("potion_health", _count_for_potion(r_letter), rarity_name))
		"mana_potion":
			out.append(_mk_stack("potion_mana", _count_for_potion(r_letter), rarity_name))
		"potion_escape":
			out.append(_mk_escape_stack(r_letter, rarity_name))

		"skill_book":
			var idict := _mk_book(true, r_letter, roll_index)
			if not idict.is_empty():
				out.append(idict)
		"spell_book":
			var idict2 := _mk_book(false, r_letter, roll_index)
			if not idict2.is_empty():
				out.append(idict2)

		"armor":
			var ilvl := SaveManager.get_current_floor()
			var arche := _pick_armor_archetype(ilvl)
			out.append(GearGen.make_armor(ilvl, rarity_name, arche))

		"weapon":
			var ilvl2 := SaveManager.get_current_floor()
			var family := _pick_weapon_family(ilvl2)
			out.append(GearGen.make_weapon(ilvl2, rarity_name, family))

		"accessory":
			var ilvl3 := SaveManager.get_current_floor()
			var slot := "ring" if (ilvl3 % 2 == 0) else "amulet"
			out.append(GearGen.make_accessory(ilvl3, rarity_name, slot))

		_:
			pass

	# Filter any empties and zero-counts
	var filtered: Array[Dictionary] = []
	for it_any in out:
		if typeof(it_any) == TYPE_DICTIONARY:
			var it: Dictionary = it_any
			var c: int = int(_S.dget(it, "count", 0))
			if c > 0:
				filtered.append(it)
	return filtered

# ---------------- internals ----------------

static func _mk_stack(id_str: String, count: int, rarity_name: String, extra_opts: Dictionary = {}) -> Dictionary:
	if count <= 0:
		return {}
	var opts: Dictionary = {
		"ilvl": 1,
		"archetype": "Consumable",
		"rarity": rarity_name,
		"affixes": [],
		"durability_max": 0,
		"durability_current": 0,
		"weight": 0.0
	}
	for k in extra_opts.keys():
		opts[String(k)] = extra_opts[k]

	return {
		"id": id_str,
		"count": count,
		"rarity": rarity_name,
		"opts": opts
	}

static func _mk_escape_stack(r_letter: String, rarity_name: String) -> Dictionary:
	var cap: int = _escape_cap_for_rarity_letter(r_letter)
	var extra := { "escape_cap_floor": cap, "escape_rarity_letter": r_letter }
	return _mk_stack("potion_escape", 1, rarity_name, extra)

static func _mk_book(is_weapon: bool, r_letter: String, roll_index: int) -> Dictionary:
	# Choose a target skill based on RUN state. Commons must target a locked skill; if none, skip.
	var rs: Dictionary = SaveManager.load_run()
	var tracks: Dictionary = _S.to_dict(_S.dget(rs, "skill_tracks", {}))

	var candidates: PackedStringArray = (WEAPON_SKILLS if is_weapon else ELEMENT_SKILLS)
	var locked: PackedStringArray = []
	var unlocked: PackedStringArray = []

	for s in candidates:
		var row: Dictionary = _S.to_dict(_S.dget(tracks, s, {}))
		var is_unlocked: bool = bool(_S.dget(row, "unlocked", false))
		if is_unlocked:
			unlocked.append(s)
		else:
			locked.append(s)

	var tier: String = _book_tier_for_letter(r_letter)
	var id_str: String = "book_weapon_%s" % [tier] if is_weapon else "book_element_%s" % [tier]

	# Deterministic seed: run_id + loot roll index + "book" + family key
	var run_id: String = String(_S.dget(rs, "run_id",
		String(_S.dget(rs, "id", String(_S.dget(rs, "uuid", String(_S.dget(rs, "seed", "0"))))))))
	var family_key := ("weapon" if is_weapon else "element")
	var rng := _rng_from_tuple([run_id, roll_index, "book", family_key])

	var pick: String = ""
	if r_letter == "C":
		# Common must unlock something new; if none available, skip.
		if locked.is_empty():
			return {}
		var idx_c := rng.randi_range(0, locked.size() - 1)
		pick = locked[idx_c]
	else:
		# Higher rarity: pick from locked when available; else from full candidates.
		var pool: PackedStringArray = (locked if not locked.is_empty() else candidates)
		var idx_h := rng.randi_range(0, pool.size() - 1)
		pick = pool[idx_h]

	return {
		"id": id_str,
		"count": 1,
		"rarity": _rarity_name_for_letter(r_letter),
		"opts": {
			"ilvl": 1,
			"archetype": "Consumable",
			"rarity": _rarity_name_for_letter(r_letter),
			"affixes": [],
			"durability_max": 0,
			"durability_current": 0,
			"weight": 0.0,
			"target_skill": pick
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
		"A", "L": return "legendary"
		"M": return "mythic"
		_: return "uncommon"

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
