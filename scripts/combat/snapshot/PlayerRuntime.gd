# Godot 4.5
extends Resource
class_name PlayerRuntime

# --------------------------- Identity / Team ---------------------------------
@export var id: int = 0                         # if you enumerate actors, 0 is fine for solo player
@export var team: String = "player"             # "player" | "enemy" (string for readability)

# --------------------------- Base / Final Stats ------------------------------
@export var base_stats: Dictionary = {}         # 8-key ints {STR,DEX,AGI,END,INT,WIS,LCK,CHA}
@export var final_stats: Dictionary = {}

# --------------------------- Caps --------------------------------------------
@export var caps: Dictionary = {                # { crit_chance_cap, crit_multi_cap }
	"crit_chance_cap": 0.35,
	"crit_multi_cap": 2.5,
}

# --------------------------- Lanes (defense) ---------------------------------
# 10-lane percent-point resists; keys L0..L9; each value in [-90.0, +95.0] (player soft top +80).
@export var resist_pct: Dictionary = {
	"L0": 0.0, "L1": 0.0, "L2": 0.0, "L3": 0.0, "L4": 0.0,
	"L5": 0.0, "L6": 0.0, "L7": 0.0, "L8": 0.0, "L9": 0.0
}
# 4-lane flat armor; keys A0..A3; ints ≥ 0.
@export var armor_flat: Dictionary = { "A0": 0, "A1": 0, "A2": 0, "A3": 0 }

# --------------------------- Derived pools & composites ----------------------
@export var hp_max: int = 1
@export var mp_max: int = 0
@export var stam_max: int = 0
@export var hp: int = 1
@export var mp: int = 0
@export var stam: int = 0

@export var p_atk: float = 0.0
@export var m_atk: float = 0.0
@export var defense: float = 0.0
@export var resistance: float = 0.0
@export var crit_chance: float = 0.0
@export var crit_multi: float = 1.0
@export var ctb_speed: float = 1.0

const ModifierAggregator := preload("res://scripts/combat/snapshot/ModifierAggregator.gd")
const SaveManager := preload("res://persistence/SaveManager.gd")

# --------------------------- Abilities / Cooling -----------------------------
# Symmetric with MonsterRuntime: have both the map and (optionally) resolved defs if you want them cached.
@export var ability_levels: Dictionary = {}     # { ability_id:String -> level:int }
@export var abilities: Array[Dictionary] = []   # normalized ability dicts (optional cache)

@export var cooldowns: Dictionary = {}          # { ability_id -> remaining_turns:int }
@export var charges: Dictionary = {}            # { ability_id -> remaining:int }

# --- Authoritative unlock flags for skills/abilities -------------------------
# Runtime mirror of your out-of-battle skill track. We compress to a bool map in snapshot.
@export var skill_tracks: Dictionary = {}       # { aid:String -> { unlocked:bool, level:int, ... } }

# --------------------------- Statuses & Tags ---------------------------------
@export var statuses: Array[Dictionary] = []    # Array of StatusInstance dicts (id, kind, pct, turns, etc.)
@export var tags: PackedStringArray = []        # runtime/appended tags (weapon, stance, etc.)

# --------------------------- Helper Modifiers --------------------------------
@export var ctb_cost_reduction_pct: float = 0.0         # e.g., -20 => -20% CTB cost
@export var on_hit_status_chance_pct: float = 0.0       # absolute percent points
@export var status_resist_pct: float = 0.0              # vs. status applications

# --------------------------- Builders / Recompute -----------------------------
const DerivedCalc := preload("res://scripts/combat/derive/DerivedCalc.gd")

## Recompute deriveds from current final_stats (and caps).
## If set_current_to_max is true, hp/mp/stam are set to their respective max; otherwise clamp.
func recompute_from_stats(set_current_to_max: bool = false) -> void:
	var d: Dictionary = DerivedCalc.recompute_all(final_stats, caps)
	hp_max     = int(d.get("hp_max", 1))
	mp_max     = int(d.get("mp_max", 0))
	stam_max   = int(d.get("stam_max", 0))
	p_atk      = float(d.get("p_atk", 0.0))
	m_atk      = float(d.get("m_atk", 0.0))
	defense    = float(d.get("defense", 0.0))
	resistance = float(d.get("resistance", 0.0))
	crit_chance= float(d.get("crit_chance", 0.0))
	crit_multi = float(d.get("crit_multi", 1.0))
	ctb_speed  = float(d.get("ctb_speed", 1.0))

	if set_current_to_max:
		hp = hp_max
		mp = mp_max
		stam = stam_max
	else:
		hp = clampi(hp, 0, hp_max)
		mp = clampi(mp, 0, mp_max)
		stam = clampi(stam, 0, stam_max)

## Build from stats/caps; current pools set to max.
static func from_stats(base_in: Dictionary, final_in: Dictionary, caps_in: Dictionary = {}) -> PlayerRuntime:
	var pr := PlayerRuntime.new()
	pr.base_stats = base_in.duplicate(true)
	pr.final_stats = final_in.duplicate(true)
	if not caps_in.is_empty():
		pr.caps = caps_in.duplicate(true)
	pr.recompute_from_stats(true)
	return pr

# --------------------------- Pools / Costs -----------------------------------
func can_spend_mp(cost: int) -> bool:
	return mp >= max(0, cost)

func can_spend_stam(cost: int) -> bool:
	return stam >= max(0, cost)

func spend_mp(cost: int) -> bool:
	var c: int = int(max(0, cost))
	if mp < c: return false
	mp -= c
	return true

func spend_stam(cost: int) -> bool:
	var c: int = int(max(0, cost))
	if stam < c: return false
	stam -= c
	return true

# --------------------------- Cooldowns / Charges ------------------------------
func set_cooldown(ability_id: String, turns: int) -> void:
	cooldowns[ability_id] = max(0, turns)

func tick_cooldowns() -> void:
	for k in cooldowns.keys():
		cooldowns[k] = max(0, int(cooldowns[k]) - 1)

func charges_left(ability_id: String) -> int:
	return int(charges.get(ability_id, 0))

func spend_charge(ability_id: String) -> bool:
	var cur: int = charges_left(ability_id)
	if cur <= 0: return false
	charges[ability_id] = cur - 1
	return true

# --------------------------- Mutables: Statuses/Tags --------------------------
func add_status(s: Dictionary) -> void:
	statuses.append(s.duplicate(true))

func clear_expired_statuses() -> void:
	var keep: Array[Dictionary] = []
	for s in statuses:
		if s.has("turns") and int(s["turns"]) <= 0:
			continue
		keep.append(s)
	statuses = keep

func add_tag(tag: String) -> void:
	if tag == "":
		return
	if not tags.has(tag):
		tags.append(tag)

# --------------------------- Snapshot (for kernel) ----------------------------
## Build an immutable snapshot dictionary consumed by the kernel.
## Also prints which skills are considered unlocked vs locked.
func to_actor_snapshot() -> Dictionary:
	# 1) Compress skill_tracks → skills_unlocked { aid:String -> bool }
	var skills_unlocked: Dictionary = {}
	var unlocked_ids := PackedStringArray()
	var locked_ids := PackedStringArray()
	var total_skills: int = 0

	if typeof(skill_tracks) == TYPE_DICTIONARY:
		var keys: Array = skill_tracks.keys()
		for i in keys.size():
			var k_any: Variant = keys[i]
			var aid: String = String(k_any)
			var entry_any: Variant = skill_tracks.get(aid)
			if typeof(entry_any) == TYPE_DICTIONARY:
				var d: Dictionary = entry_any as Dictionary
				var is_unlocked: bool = bool(d.get("unlocked", false))
				skills_unlocked[aid] = is_unlocked
				total_skills += 1
				if is_unlocked:
					unlocked_ids.append(aid)
				else:
					locked_ids.append(aid)
			else:
				print("[PlayerRuntime] WARN skill_tracks entry malformed: aid=", aid, " value_type=", typeof(entry_any))

	# 2) Filter ability_levels → only unlocked
	var abilities_out: Dictionary = {}
	if typeof(ability_levels) == TYPE_DICTIONARY:
		var akeys: Array = ability_levels.keys()
		for i in akeys.size():
			var a_any: Variant = akeys[i]
			var aid2: String = String(a_any)
			var allowed: bool = true
			if not skills_unlocked.is_empty():
				allowed = bool(skills_unlocked.get(aid2, false))
			if allowed:
				abilities_out[aid2] = int(ability_levels[aid2])

	print("[PlayerRuntime] to_actor_snapshot skills: total=", total_skills, " unlocked=", unlocked_ids.size(), " locked=", locked_ids.size())
	if unlocked_ids.size() > 0:
		print("[PlayerRuntime] unlocked ids: ", unlocked_ids)
	if locked_ids.size() > 0:
		print("[PlayerRuntime] locked ids: ", locked_ids, "  (locked means \"unlocked\": false in run.json)")

	# 3) Build mods (pure) from RUN + statuses (slot-safe)
	var mods_obj := ModifierAggregator.for_player(SaveManager.active_slot(), statuses)

	# Core offense/defense you already had:
	var mods_dict: Dictionary = {
		"accuracy_add_pct": mods_obj.accuracy_add_pct,
		"evasion_add_pct": mods_obj.evasion_add_pct,
		"crit_chance_add": mods_obj.crit_chance_add,
		"crit_multi_add": mods_obj.crit_multi_add,
		"pene_add_pct": mods_obj.pene_add_pct,
		"lane_damage_mult_pct": mods_obj.lane_damage_mult_pct.duplicate(),
		"added_flat_universal": mods_obj.added_flat_universal,
		"added_flat_by_lane": mods_obj.added_flat_by_lane.duplicate(),
		"school_power_pct": mods_obj.school_power_pct.duplicate(),
		"resist_add_pct": mods_obj.resist_add_pct.duplicate(),
		"armor_add_flat": mods_obj.armor_add_flat.duplicate(),
		"global_dr_pct": mods_obj.global_dr_pct,
		"extra_riders": mods_obj.extra_riders.duplicate(true),
		"convert_phys_to_element": mods_obj.convert_phys_to_element.duplicate()
	}

	# NEW: CTB knobs + sustain/reflect/status fields for pipelines
	mods_dict["ctb_speed_add"] = mods_obj.ctb_speed_add
	mods_dict["ctb_cost_mult"] = mods_obj.ctb_cost_mult
	mods_dict["ctb_floor_min"] = mods_obj.ctb_floor_min
	mods_dict["ctb_on_kill_pct"] = mods_obj.ctb_on_kill_pct

	mods_dict["on_hit_hp_flat"] = mods_obj.on_hit_hp_flat
	mods_dict["on_hit_mp_flat"] = mods_obj.on_hit_mp_flat
	mods_dict["hp_on_kill_flat"] = mods_obj.hp_on_kill_flat
	mods_dict["mp_on_kill_flat"] = mods_obj.mp_on_kill_flat

	mods_dict["thorns_pct"] = mods_obj.thorns_pct
	mods_dict["status_resist_pct"] = mods_obj.status_resist_pct.duplicate()
	mods_dict["status_on_hit_bias_pct"] = mods_obj.status_on_hit_bias_pct
	mods_dict["gain_tags"] = mods_obj.gain_tags.duplicate()

	return {
		"id": id,
		"team": team,
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

		"abilities": abilities_out,
		"statuses": statuses.duplicate(true),
		"tags": tags.duplicate(),
		"cooldowns": cooldowns.duplicate(true),
		"charges": charges.duplicate(true),

		"skill_tracks": skill_tracks.duplicate(true),
		"helpers": {
			"ctb_cost_reduction_pct": ctb_cost_reduction_pct,
			"on_hit_status_chance_pct": on_hit_status_chance_pct,
			"status_resist_pct": status_resist_pct,
			"skills_unlocked": skills_unlocked
		},

		"mods": mods_dict
	}

# --- Skill Usage (per-battle; cleared after rewards) -------------------------
# NOTE: keep untyped outer map to avoid nested-typed Dictionary issues.
var _skill_usage: Dictionary = {}  # ability_id:String -> SkillUsageRow (or compatible Dictionary)

func skill_usage_add_use(ability_id: String) -> void:
	if ability_id.is_empty():
		return
	if not _ability_is_unlocked(ability_id):
		print("[PlayerRuntime] skip use tally (locked) ability=", ability_id)
		return
	var row: Variant = _skill_usage.get(ability_id)
	if row == null:
		var created: SkillUsageRow = SkillUsageRow.new()
		_skill_usage[ability_id] = created
		row = created
	if row is SkillUsageRow:
		(row as SkillUsageRow).add_use()
	else:
		var d: Dictionary = row as Dictionary
		d["uses"] = int(d.get("uses", 0)) + 1
		_skill_usage[ability_id] = d
	print("[PlayerRuntime] add_use ability=", ability_id, " row=", _skill_usage[ability_id])

func skill_usage_add_impact(ability_id: String, hit: bool, crit: bool, damage: int) -> void:
	if ability_id.is_empty():
		return
	if not _ability_is_unlocked(ability_id):
		print("[PlayerRuntime] skip impact tally (locked) ability=", ability_id)
		return
	var row: Variant = _skill_usage.get(ability_id)
	if (row == null) or not (row is SkillUsageRow):
		var tmp: SkillUsageRow = SkillUsageRow.new()
		if row is Dictionary:
			var d0: Dictionary = row as Dictionary
			tmp.uses = int(d0.get("uses", 0))
			tmp.hits = int(d0.get("hits", 0))
			tmp.crits = int(d0.get("crits", 0))
			tmp.total_damage = int(d0.get("total_damage", 0))
		_skill_usage[ability_id] = tmp
		row = tmp
	(row as SkillUsageRow).add_impact(hit, crit, damage)
	print("[PlayerRuntime] add_impact ability=", ability_id, " hit=", hit, " crit=", crit, " dmg=", damage)

func skill_usage_merge_map(map_in: Dictionary) -> void:
	# map_in: ability_id -> (SkillUsageRow or Dictionary{uses,hits,crits,total_damage})
	var keys: Array = map_in.keys()
	for i in keys.size():
		var key_any: Variant = keys[i]
		var aid: String = String(key_any)

		var src: Variant = map_in[aid]
		if src == null:
			continue

		var dst: Variant = _skill_usage.get(aid)
		if dst == null:
			# store as-is (copy dictionaries to avoid aliasing)
			if src is Dictionary:
				var copy_d: Dictionary = (src as Dictionary).duplicate(true)
				_skill_usage[aid] = copy_d
			else:
				_skill_usage[aid] = src
			continue

		# Merge into a SkillUsageRow for consistency
		var su_dst: SkillUsageRow = null
		if dst is SkillUsageRow:
			su_dst = dst as SkillUsageRow
		else:
			var tmp: SkillUsageRow = SkillUsageRow.new()
			var d: Dictionary = dst as Dictionary
			tmp.uses = int(d.get("uses", 0))
			tmp.hits = int(d.get("hits", 0))
			tmp.crits = int(d.get("crits", 0))
			tmp.total_damage = int(d.get("total_damage", 0))
			_skill_usage[aid] = tmp
			su_dst = tmp

		if src is SkillUsageRow:
			su_dst.merge_from(src as SkillUsageRow)
		else:
			var s: Dictionary = src as Dictionary
			su_dst.uses += int(s.get("uses", 0))
			su_dst.hits += int(s.get("hits", 0))
			su_dst.crits += int(s.get("crits", 0))
			su_dst.total_damage += int(s.get("total_damage", 0))

	print("[PlayerRuntime] merge_map entries=", map_in.size(), " now_total=", _skill_usage.size())

func consume_skill_usage() -> Dictionary:
	# Return a copy that BattleLoader can convert into bundle.skill_xp
	var out: Dictionary = {}
	var keys: Array = _skill_usage.keys()
	for i in keys.size():
		var k_any: Variant = keys[i]
		var k: String = String(k_any)
		out[k] = _skill_usage[k]
	print("[PlayerRuntime] consume_skill_usage entries=", out.size())
	_skill_usage.clear()
	return out

func _ability_is_unlocked(aid: String) -> bool:
	if aid == "" or aid == "fizzle":
		return false
	if aid == "basic_attack" or aid == "guard":
		return true
	if typeof(skill_tracks) != TYPE_DICTIONARY:
		return false
	var entry_any: Variant = skill_tracks.get(aid)
	if typeof(entry_any) != TYPE_DICTIONARY:
		return false
	return bool((entry_any as Dictionary).get("unlocked", false))
