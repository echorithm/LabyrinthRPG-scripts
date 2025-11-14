# Godot 4.5
extends Resource
class_name MonsterRuntime

const DerivedCalc := preload("res://scripts/combat/derive/DerivedCalc.gd")

# -------------------------- Identity / Source --------------------------------
@export var id: int = 0
@export var slug: StringName = &""
@export var display_name: String = ""
@export var scene_path: String = ""
@export var role: String = "trash"
@export var team: String = "enemy"

# Version/caps (carried from catalog)
@export var schema_version: String = ""
@export var version: String = ""
@export var caps: Dictionary = {}             # { crit_chance_cap, crit_multi_cap }

# Gameplay meta
@export var xp_species_mod: float = 1.0
@export var loot_source_id: String = ""
@export var sigil_credit: int = 0
@export var collision_profile: String = ""

# ---------------------------- Allocation -------------------------------------
@export var level_baseline: int = 0           # default to 0 (canonical baseline)
@export var final_level: int = 1              # canonical level (no +1 display bumps)
@export var power_level: int = -1             # optional passthrough from allocator (for audits)

# Base 8 stats (pre/post allocation)
@export var base_stats: Dictionary = {}       # 8-key ints
@export var final_stats: Dictionary = {}      # 8-key ints

# Defenses (normalized)
@export var resist_pct: Dictionary = {
	"L0": 0.0, "L1": 0.0, "L2": 0.0, "L3": 0.0, "L4": 0.0,
	"L5": 0.0, "L6": 0.0, "L7": 0.0, "L8": 0.0, "L9": 0.0
}
@export var armor_flat: Dictionary = { "A0": 0, "A1": 0, "A2": 0, "A3": 0 }

# Abilities
@export var ability_levels: Dictionary = {}           # { ability_id -> level:int }
@export var abilities: Array[Dictionary] = []         # normalized rows
@export var ability_anim_keys: Dictionary = {}        # { ability_id -> animation_key }

# --------------------------- Derived (computed) -------------------------------
@export var hp_max: int = 1
@export var mp_max: int = 0
@export var hp: int = 1
@export var mp: int = 0
@export var stam_max: int = 0
@export var stam: int = 0

@export var p_atk: float = 0.0
@export var m_atk: float = 0.0
@export var defense: float = 0.0
@export var resistance: float = 0.0
@export var crit_chance: float = 0.0
@export var crit_multi: float = 1.0
@export var ctb_speed: float = 1.0

# --------------------------- Battle mutables ---------------------------------
@export var cooldowns: Dictionary = {}
@export var charges: Dictionary = {}
@export var statuses: Array[Dictionary] = []
@export var tags: PackedStringArray = []

@export var ctb_cost_reduction_pct: float = 0.0
@export var on_hit_status_chance_pct: float = 0.0
@export var status_resist_pct: float = 0.0

const DEBUG_MR: bool = true

# --------------------------- Factory -----------------------------------------
# res://scripts/combat/snapshot/MonsterRuntime.gd
static func from_alloc(mc: Dictionary, alloc: Dictionary, role_s: String = "trash") -> MonsterRuntime:
	var rt: MonsterRuntime = MonsterRuntime.new()

	# Identity/meta
	rt.id = int(mc.get("id", 0))
	rt.slug = StringName(String(mc.get("slug", "")))
	rt.display_name = String(mc.get("display_name", String(rt.slug)))
	rt.scene_path = String(mc.get("scene_path", ""))
	rt.role = role_s
	rt.team = "enemy"

	rt.schema_version = String(mc.get("schema_version", ""))
	rt.version = String(mc.get("version", ""))

	# Caps + meta
	rt.caps = (mc.get("caps", {}) as Dictionary).duplicate(true)
	rt.xp_species_mod = float(mc.get("xp_species_mod", 1.0))
	rt.loot_source_id = String(mc.get("loot_source_id", ""))
	rt.sigil_credit = int(mc.get("sigil_credit", 0))
	rt.collision_profile = String(mc.get("collision_profile", ""))

	# Allocation (canonicalize baseline/final)
	rt.level_baseline = int(alloc.get("level_baseline", int(mc.get("level_baseline", 0))))
	rt.base_stats = (alloc.get("base_stats", {}) as Dictionary).duplicate(true)
	rt.final_stats = (alloc.get("final_stats", {}) as Dictionary).duplicate(true)

	# Optional PL passthrough for audits/debug
	if alloc.has("power_level"):
		rt.power_level = int(alloc["power_level"])

	# Final level: prefer allocator's value; else compute from PL; else fallback to baseline
	if alloc.has("final_level"):
		rt.final_level = int(alloc["final_level"])
	elif rt.power_level >= 0:
		var levels_from_pl: int = int(floor(float(rt.power_level) * 0.20))
		rt.final_level = max(1, rt.level_baseline + levels_from_pl)
	else:
		rt.final_level = max(1, rt.level_baseline)

	# Defenses
	var stats_block: Dictionary = (mc.get("stats", {}) as Dictionary)
	var rb := preload("res://scripts/combat/derive/DefenseLaneBuilder.gd")
	var built: Dictionary = rb.build_for_monster(stats_block)
	rt.resist_pct = (built.get("resist_pct", {}) as Dictionary).duplicate(true)
	rt.armor_flat = (built.get("armor_flat", {}) as Dictionary).duplicate(true)

	# Abilities (rows) from alloc; if empty, fall back to catalog rows
	rt.abilities = _to_dict_array(alloc.get("abilities", []))
	if rt.abilities.is_empty():
		rt.abilities = _to_dict_array(mc.get("abilities", []))

	# Seed ability levels:
	#  - prefer explicit map from alloc
	#  - otherwise derive per row's `skill_level_baseline` + optional allocator bonus
	var levels_from_alloc: Dictionary = (alloc.get("ability_levels", {}) as Dictionary)
	var ability_level_bonus: int = int(alloc.get("ability_level_bonus", 0))
	var lvl_map: Dictionary = {} as Dictionary
	if not levels_from_alloc.is_empty():
		for k_any in levels_from_alloc.keys():
			lvl_map[String(k_any)] = int(levels_from_alloc[k_any])
	else:
		for row_any in rt.abilities:
			if not (row_any is Dictionary):
				continue
			var row: Dictionary = row_any as Dictionary
			var aid: String = String(row.get("ability_id", ""))
			if aid == "":
				continue
			var base_lvl: int = int(row.get("skill_level_baseline", 1))
			lvl_map[aid] = max(1, base_lvl + ability_level_bonus)
	rt.ability_levels = lvl_map

	# Build animation key lookup (alloc rows preferred)
	var map_from_alloc: Dictionary = _extract_anim_keys(rt.abilities)
	if map_from_alloc.size() == 0:
		var cat_rows: Array[Dictionary] = _to_dict_array(mc.get("abilities", []))
		map_from_alloc = _extract_anim_keys(cat_rows)
	rt.ability_anim_keys = map_from_alloc
	print("[MonsterRuntime] ", rt.display_name, " anim_keys=", rt.ability_anim_keys)

	# Deriveds via DerivedCalc
	var derived: Dictionary = DerivedCalc.recompute_all(rt.final_stats, rt.caps)
	rt.hp_max = int(derived.get("hp_max", 1))
	rt.mp_max = int(derived.get("mp_max", 0))
	rt.p_atk = float(derived.get("p_atk", 0.0))
	rt.m_atk = float(derived.get("m_atk", 0.0))
	rt.defense = float(derived.get("defense", 0.0))
	rt.resistance = float(derived.get("resistance", 0.0))
	rt.crit_chance = float(derived.get("crit_chance", 0.0))
	rt.crit_multi = float(derived.get("crit_multi", 1.0))
	rt.ctb_speed = float(derived.get("ctb_speed", 1.0))
	rt.stam_max = int(derived.get("stam_max", 0))

	# Fill current pools
	rt.hp = rt.hp_max
	rt.mp = rt.mp_max
	rt.stam = rt.stam_max

	if DEBUG_MR:
		var pl_note: String = (", pl=" + str(rt.power_level)) if rt.power_level >= 0 else ""
		print_rich("[color=cyan][MR][/color] ", rt.display_name,
			" | baseline=", rt.level_baseline,
			" | final=", rt.final_level,
			pl_note
		)

	return rt


# --------------------------- Convenience -------------------------------------
func get_anim_key(ability_id: String) -> String:
	if ability_id == "":
		return ""
	if ability_anim_keys.has(ability_id):
		return String(ability_anim_keys[ability_id])
	return ""

# --------------------------- Snapshot (for kernel) ----------------------------
func to_actor_snapshot() -> Dictionary:
	return {
		"id": id,
		"team": team,

		# Canonical level fields
		"level": final_level,
		"final_level": final_level,
		"level_baseline": level_baseline,
		"power_level": power_level,  # optional; -1 if not provided

		"stats_total": final_stats.duplicate(true),
		"derived": {
			"hp_max": hp_max, "mp_max": mp_max, "stam_max": stam_max,
			"p_atk": p_atk, "m_atk": m_atk,
			"defense": defense, "resistance": resistance,
			"crit_chance": crit_chance, "crit_multi": crit_multi,
			"ctb_speed": ctb_speed
		},
		"resist_pct": resist_pct.duplicate(true),
		"armor_flat": armor_flat.duplicate(true),
		"pools": { "hp": hp, "mp": mp, "stam": stam },
		"caps": caps.duplicate(true),
		"abilities": ability_levels.duplicate(true),
		"statuses": statuses.duplicate(true),
		"tags": tags.duplicate(),
		"cooldowns": cooldowns.duplicate(true),
		"charges": charges.duplicate(true),
		"helpers": {
			"ctb_cost_reduction_pct": ctb_cost_reduction_pct,
			"on_hit_status_chance_pct": on_hit_status_chance_pct,
			"status_resist_pct": status_resist_pct
		}
	}

# --------------------------- small utils -------------------------------------
static func _to_dict_array(v: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if v is Array:
		for e in (v as Array):
			if e is Dictionary:
				out.append((e as Dictionary).duplicate(true))
	return out

static func _extract_anim_keys(rows: Array[Dictionary]) -> Dictionary:
	var m: Dictionary = {}
	for row_any in rows:
		if not (row_any is Dictionary):
			continue
		var row: Dictionary = row_any as Dictionary
		var aid: String = String(row.get("ability_id", ""))
		if aid == "":
			continue
		var key: String = String(row.get("animation_key", ""))
		if key != "":
			m[aid] = key
	return m
