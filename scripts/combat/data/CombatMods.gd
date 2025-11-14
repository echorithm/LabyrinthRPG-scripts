# Godot 4.5
extends RefCounted
class_name CombatMods

const LANE_KEYS: PackedStringArray = [
	"pierce","slash","ranged","blunt","light","dark","fire","water","earth","wind"
]
const PHYS_KEYS: PackedStringArray = ["pierce","slash","ranged","blunt"]
const SCHOOLS: PackedStringArray = ["power","finesse","arcane","divine","support"]

# ---------------- Offense/Defense deltas (already COMBINED) ----------------
var attrs_add: Dictionary
var resist_add_pct: Dictionary                 # lane -> +/-%
var armor_add_flat: Dictionary                 # phys lane -> int

var accuracy_add_pct: float = 0.0              # +% absolute points
var evasion_add_pct: float = 0.0               # defender-side dodge (subtract from accuracy)
var crit_chance_add: float = 0.0               # +% absolute points
var crit_multi_add: float = 0.0                # + to multiplier (e.g., +0.20)
var pene_add_pct: float = 0.0                  # +% penetration
var lane_damage_mult_pct: Dictionary           # lane -> +/-%

# Added flat damage before defense (applied per lane in AttackPipeline)
var added_flat_universal: float = 0.0
var added_flat_by_lane: Dictionary             # lane -> flat int (pre-defense)

# School multipliers (applied to the school scalar)
var school_power_pct: Dictionary               # school -> +% (e.g., {"arcane": 12.0})

# Global defense and extras
var global_dr_pct: float = 0.0
var thorns_pct: float = 0.0
var status_resist_pct: Dictionary              # status_id -> +% resist (e.g., {"poison": 20.0})

# Turn economy / costs
var ctb_speed_add: float = 0.0
var ctb_cost_mult: float = 1.0                 # < 1.0 reduces cost
var ctb_floor_min: float = 1.0                 # lower-bound floor (from village, etc.)
var resource_cost_delta: Dictionary            # { "mp": int, "stam": int }

# Kill/on-hit utilities
var ctb_on_kill_pct: float = 0.0
var hp_on_kill_flat: int = 0
var mp_on_kill_flat: int = 0
var on_hit_hp_flat: int = 0
var on_hit_mp_flat: int = 0

# Status/rider helpers
var extra_riders: Array[Dictionary] = []
var status_on_hit_bias_pct: float = 0.0        # global +% to rider chances

# Converters & tags
var convert_phys_to_element: Dictionary        # { "element": String, "pct": float } strongest wins
var gain_tags: Array[String] = []

# Durability knobs (used by DurabilityService)
var durability_loss_reduction_pct: float = 0.0

func _init() -> void:
	attrs_add = {
		"STR": 0, "AGI": 0, "DEX": 0, "END": 0, "INT": 0, "WIS": 0, "CHA": 0, "LCK": 0
	}
	resist_add_pct = {}
	for k in LANE_KEYS: resist_add_pct[k] = 0.0
	armor_add_flat = {}
	for k2 in PHYS_KEYS: armor_add_flat[k2] = 0
	lane_damage_mult_pct = {}
	added_flat_by_lane = {}
	school_power_pct = {}
	for s in SCHOOLS: school_power_pct[s] = 0.0
	status_resist_pct = {}
	resource_cost_delta = {"mp": 0, "stam": 0}
	convert_phys_to_element = {}

func clone() -> CombatMods:
	var c := CombatMods.new()
	c.attrs_add = attrs_add.duplicate()
	c.resist_add_pct = resist_add_pct.duplicate()
	c.armor_add_flat = armor_add_flat.duplicate()
	c.accuracy_add_pct = accuracy_add_pct
	c.evasion_add_pct = evasion_add_pct
	c.crit_chance_add = crit_chance_add
	c.crit_multi_add = crit_multi_add
	c.pene_add_pct = pene_add_pct
	c.lane_damage_mult_pct = lane_damage_mult_pct.duplicate()
	c.added_flat_universal = added_flat_universal
	c.added_flat_by_lane = added_flat_by_lane.duplicate()
	c.school_power_pct = school_power_pct.duplicate()
	c.global_dr_pct = global_dr_pct
	c.thorns_pct = thorns_pct
	c.status_resist_pct = status_resist_pct.duplicate()
	c.ctb_speed_add = ctb_speed_add
	c.ctb_cost_mult = ctb_cost_mult
	c.ctb_floor_min = ctb_floor_min
	c.resource_cost_delta = resource_cost_delta.duplicate()
	c.ctb_on_kill_pct = ctb_on_kill_pct
	c.hp_on_kill_flat = hp_on_kill_flat
	c.mp_on_kill_flat = mp_on_kill_flat
	c.on_hit_hp_flat = on_hit_hp_flat
	c.on_hit_mp_flat = on_hit_mp_flat
	c.extra_riders = extra_riders.duplicate(true)
	c.status_on_hit_bias_pct = status_on_hit_bias_pct
	c.convert_phys_to_element = convert_phys_to_element.duplicate()
	c.gain_tags = gain_tags.duplicate()
	c.durability_loss_reduction_pct = durability_loss_reduction_pct
	return c
