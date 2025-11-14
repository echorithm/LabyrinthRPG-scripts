# Godot 4.5
extends RefCounted
class_name ModifierAggregator

const CombatMods := preload("res://scripts/combat/data/CombatMods.gd")
const _S := preload("res://persistence/util/save_utils.gd")

const LANE_KEYS: PackedStringArray = [
	"pierce","slash","ranged","blunt","light","dark","fire","water","earth","wind"
]
const PHYS_KEYS: PackedStringArray = ["pierce","slash","ranged","blunt"]

# Canonical deterministic equipment slot order (includes weapon families)
const EQUIP_SLOT_ORDER: PackedStringArray = [
	"head","chest","legs","boots",
	"sword","spear","mace","bow",
	"ring1","ring2","amulet"
]

# ---------------- Public API ----------------

static func for_player(run_slot: int, active_statuses: Array[Dictionary]) -> CombatMods:
	var mods: CombatMods = CombatMods.new()
	var rs: Dictionary = SaveManager.load_run(run_slot)
	_apply_equipment(rs, mods)
	_apply_statuses(active_statuses, mods)
	_apply_village_buffs(rs, mods)
	_apply_global_run_mods(rs, mods) # legacy mirrors (mods_village/mods_affix), harmless if absent
	return mods

static func for_monster(active_statuses: Array[Dictionary]) -> CombatMods:
	var mods: CombatMods = CombatMods.new()
	_apply_statuses(active_statuses, mods)
	return mods

# ---------------- Internals ----------------

static func _apply_equipment(rs: Dictionary, mods: CombatMods) -> void:
	var eq_any: Variant = rs.get("equipment", {})
	var bank_any: Variant = rs.get("equipped_bank", {})
	var eq: Dictionary = (eq_any as Dictionary) if (eq_any is Dictionary) else {}
	var bank: Dictionary = (bank_any as Dictionary) if (bank_any is Dictionary) else {}

	# Deterministic iteration over a fixed slot order
	for slot_key: String in EQUIP_SLOT_ORDER:
		var uid_any: Variant = eq.get(slot_key)
		if uid_any == null:
			continue
		var bank_key: String = String(uid_any)
		var row_any: Variant = bank.get(bank_key)
		if not (row_any is Dictionary):
			continue
		var item: Dictionary = row_any as Dictionary

		var aff_any: Variant = item.get("affixes")
		if aff_any is Array:
			var aff_arr: Array = aff_any as Array
			for a_any in aff_arr:
				if a_any is Dictionary:
					_apply_affix(a_any as Dictionary, mods)

static func _apply_statuses(active_statuses: Array[Dictionary], mods: CombatMods) -> void:
	for s_any in active_statuses:
		if not (s_any is Dictionary):
			continue
		var s: Dictionary = s_any as Dictionary
		var id: String = String(s.get("id", ""))
		var pct: float = float(s.get("pct", 0.0))
		match id:
			"DEF_UP_PCT":
				mods.global_dr_pct += pct
			"HIT_UP_PCT":
				mods.accuracy_add_pct += pct
			"CRIT_UP_PCT":
				mods.crit_chance_add += pct
			"CRIT_MULTI_ADD":
				mods.crit_multi_add += float(s.get("add", pct))
			"PENETRATION_PCT":
				mods.pene_add_pct += pct
			"RESIST_LANE_PCT":
				var lane: String = String(s.get("lane",""))
				if lane in LANE_KEYS:
					mods.resist_add_pct[lane] = float(mods.resist_add_pct.get(lane, 0.0)) + pct
			"ARMOR_LANE_FLAT":
				var pl: String = String(s.get("phys_lane",""))
				if pl in PHYS_KEYS:
					mods.armor_add_flat[pl] = int(mods.armor_add_flat.get(pl, 0)) + int(s.get("flat", 0))
			"DAMAGE_LANE_PCT":
				var l2: String = String(s.get("lane",""))
				if l2 in LANE_KEYS:
					var cur: float = float(mods.lane_damage_mult_pct.get(l2, 0.0))
					mods.lane_damage_mult_pct[l2] = cur + pct
			"IGNITE_ON_HIT":
				mods.extra_riders.append({ "id":"ignite", "chance": pct * 0.01, "stacks": 1, "duration": int(s.get("duration", 3)) })
			"BLEED_ON_HIT":
				mods.extra_riders.append({ "id":"bleed", "chance": pct * 0.01, "stacks": 1, "duration": int(s.get("duration", 3)) })
			_:
				pass

# --- Village snapshot integration (RUN.village_buffs) ---
static func _apply_village_buffs(rs: Dictionary, mods: CombatMods) -> void:
	var vb_any: Variant = rs.get("village_buffs", {})
	if not (vb_any is Dictionary):
		return
	var vb: Dictionary = vb_any as Dictionary

	# Resonance families
	var reso_any: Variant = vb.get("resonance_map", {})
	if reso_any is Dictionary:
		var reso: Dictionary = reso_any as Dictionary
		# Elemental “*” applies to all elements
		if reso.has("element_mod_*_pct"):
			var v_all: float = float(reso["element_mod_*_pct"])
			for lane in ["light","dark","fire","water","earth","wind"]:
				var prev: float = float(mods.lane_damage_mult_pct.get(lane, 0.0))
				mods.lane_damage_mult_pct[lane] = prev + v_all
		if reso.has("on_hit_status_chance_pct"):
			mods.status_on_hit_bias_pct += float(reso["on_hit_status_chance_pct"])

	# CTB floor
	if vb.has("ctb_floor"):
		mods.ctb_floor_min = float(vb.get("ctb_floor", mods.ctb_floor_min))

	# Additive globals (e.g., ward DR)
	var add_any: Variant = vb.get("additive_globals", {})
	if add_any is Dictionary:
		var add: Dictionary = add_any as Dictionary
		if add.has("ward_dr_pct"):
			mods.global_dr_pct += float(add.get("ward_dr_pct", 0.0))

# --- Legacy/global mirrors (optional) ---
static func _apply_global_run_mods(rs: Dictionary, mods: CombatMods) -> void:
	var mv_any: Variant = rs.get("mods_village", {})
	var ma_any: Variant = rs.get("mods_affix", {})
	var mv: Dictionary = (mv_any as Dictionary) if (mv_any is Dictionary) else {}
	var ma: Dictionary = (ma_any as Dictionary) if (ma_any is Dictionary) else {}

	if mv.has("global_dr_pct"): mods.global_dr_pct += float(mv["global_dr_pct"])
	if ma.has("global_dr_pct"): mods.global_dr_pct += float(ma["global_dr_pct"])
	if mv.has("accuracy_add_pct"): mods.accuracy_add_pct += float(mv["accuracy_add_pct"])
	if ma.has("accuracy_add_pct"): mods.accuracy_add_pct += float(ma["accuracy_add_pct"])

# --- Affix translation (your defs) ---
static func _apply_affix(a: Dictionary, mods: CombatMods) -> void:
	var effect: String = String(_S.dget(a, "effect_type", ""))
	var value: float = float(_S.dget(a, "value", 0.0))
	var _units: String = String(_S.dget(a, "units", ""))  # often "percent"
	var p: Dictionary = _S.to_dict(a.get("params", {}))

	match effect:
		"flat_power":
			mods.added_flat_universal += value

		"school_power_pct":
			var school: String = String(p.get("school", ""))
			if school != "":
				mods.school_power_pct[school] = float(mods.school_power_pct.get(school, 0.0)) + value

		"accuracy_flat":
			mods.accuracy_add_pct += value

		"crit_chance_pct":
			mods.crit_chance_add += value

		"crit_damage_pct":
			mods.crit_multi_add += value * 0.01

		"added_damage_elem_flat":
			var elem: String = String(p.get("element", ""))
			if elem in LANE_KEYS:
				var cur: float = float(mods.added_flat_by_lane.get(elem, 0.0))
				mods.added_flat_by_lane[elem] = cur + value

		"added_damage_phys_flat":
			var ph: String = String(p.get("phys_type", ""))
			if ph in PHYS_KEYS:
				var cur2: float = float(mods.added_flat_by_lane.get(ph, 0.0))
				mods.added_flat_by_lane[ph] = cur2 + value

		"element_mod_pct":
			var e: String = String(p.get("element", ""))
			if e in LANE_KEYS:
				mods.lane_damage_mult_pct[e] = float(mods.lane_damage_mult_pct.get(e, 0.0)) + value

		"on_hit_status_chance_pct":
			var st: String = String(p.get("status", ""))
			if st != "":
				mods.extra_riders.append({ "id": st, "chance": value * 0.01, "stacks": 1, "duration": 3 })

		"life_on_hit_flat":
			mods.on_hit_hp_flat += int(round(value))

		"mana_on_hit_flat":
			mods.on_hit_mp_flat += int(round(value))

		"ctb_on_kill_pct":
			mods.ctb_on_kill_pct += value

		"durability_loss_reduction_pct":
			mods.durability_loss_reduction_pct += value

		"convert_physical_to_element_pct":
			var el: String = String(p.get("element",""))
			if el in ["light","dark","fire","water","earth","wind"]:
				var prev: float = float(_S.dget(mods.convert_phys_to_element, "pct", 0.0))
				if value > prev:
					mods.convert_phys_to_element = { "element": el, "pct": value }

		"def_flat":
			for ph2 in PHYS_KEYS:
				mods.armor_add_flat[ph2] = int(mods.armor_add_flat.get(ph2, 0)) + int(round(value))

		"res_flat":
			for lane in LANE_KEYS:
				mods.resist_add_pct[lane] = float(mods.resist_add_pct.get(lane, 0.0)) + value

		"element_resist_pct":
			var elr: String = String(p.get("element",""))
			if elr in LANE_KEYS:
				mods.resist_add_pct[elr] = float(mods.resist_add_pct.get(elr, 0.0)) + value

		"speed_delta_flat":
			mods.ctb_speed_add += value

		"dodge_chance_pct":
			mods.evasion_add_pct += value

		"ctb_cost_reduction_pct":
			var mult: float = max(0.0, 1.0 - value * 0.01)
			mods.ctb_cost_mult *= mult

		"status_resist_pct":
			var sid: String = String(p.get("status",""))
			if sid != "":
				mods.status_resist_pct[sid] = float(mods.status_resist_pct.get(sid, 0.0)) + value

		"thorns_pct":
			mods.thorns_pct += value

		"primary_stat_flat":
			var st2: String = String(p.get("stat",""))
			if st2 != "":
				mods.attrs_add[st2] = int(mods.attrs_add.get(st2, 0)) + int(round(value))

		"hp_on_kill_flat":
			mods.hp_on_kill_flat += int(round(value))

		"mp_on_kill_flat":
			mods.mp_on_kill_flat += int(round(value))

		"gain_tag":
			var tag: String = String(p.get("tag",""))
			if tag != "":
				mods.gain_tags.append(tag)

		_:
			pass
