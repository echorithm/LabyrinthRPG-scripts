extends Node

@export var catalog_path: String = "res://data/combat/abilities/ability_catalog.json"

var _loaded: bool = false
var _by_id: Dictionary = {}                # ability_id -> Dictionary (entry)
var _order_ids: PackedStringArray = PackedStringArray()

func _ready() -> void:
	_ensure_loaded()

# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------

func ids() -> PackedStringArray:
	_ensure_loaded()
	return _order_ids

func exists(ability_id: StringName) -> bool:
	_ensure_loaded()
	return _by_id.has(String(ability_id))

func entry(ability_id: StringName) -> Dictionary:
	_ensure_loaded()
	var k: String = String(ability_id)
	var v: Variant = _by_id.get(k, {})
	return (v as Dictionary)

func display_name(ability_id: StringName) -> String:
	var e: Dictionary = entry(ability_id)
	return String(e.get("display_name", String(ability_id)))

func is_spell(ability_id: StringName) -> bool:
	var e: Dictionary = entry(ability_id)
	return String(e.get("weapon_type","")) == ""

func base_power(ability_id: StringName) -> int:
	var e: Dictionary = entry(ability_id)
	return int(e.get("base_power", 0))

func ctb_cost(ability_id: StringName) -> int:
	var e: Dictionary = entry(ability_id)
	return int(e.get("ctb_cost", 100))

func resource_costs(ability_id: StringName) -> Dictionary:
	var e: Dictionary = entry(ability_id)
	return {
		"mp_cost":  int(e.get("mp_cost", 0)),
		"stam_cost": int(e.get("stam_cost", 0)),
		"cooldown": int(e.get("cooldown", 0)),
		"charges":  int(e.get("charges", 0)),
	}

func damage_type(ability_id: StringName) -> String:
	var e: Dictionary = entry(ability_id)
	return String(e.get("damage_type", String(e.get("element","physical"))))

func intent_id(ability_id: StringName) -> String:
	var e: Dictionary = entry(ability_id)
	return String(e.get("intent_id",""))

# --- Progression helpers -----------------------------------------------------

func per_level_pct(ability_id: StringName) -> float:
	var e: Dictionary = entry(ability_id)
	var prog_any: Variant = e.get("progression", {})
	if typeof(prog_any) != TYPE_DICTIONARY:
		return 0.0
	var per_any: Variant = (prog_any as Dictionary).get("per_level", {})
	if typeof(per_any) != TYPE_DICTIONARY:
		return 0.0
	var per: Dictionary = per_any as Dictionary
	if per.has("power_pct"):
		return float(per["power_pct"])
	if per.has("heal_pct"):
		return float(per["heal_pct"])
	return 0.0

# Example: base_power * power_scalar_for_level("arc_slash", 11)
func power_scalar_for_level(ability_id: StringName, level: int) -> float:
	var lvl: int = max(1, level)
	var per: float = per_level_pct(ability_id)
	return 1.0 + (float(lvl - 1) * per) * 0.01

func milestones_reached(level: int) -> int:
	return max(0, int(floor(float(max(1, level)) / 5.0)))

func rider_for_level(ability_id: StringName, level: int) -> Dictionary:
	var e: Dictionary = entry(ability_id)
	var prog: Dictionary = (e.get("progression", {}) as Dictionary)
	var r: Dictionary = (prog.get("rider", {}) as Dictionary)
	if r.is_empty():
		return {}

	var ms: int = milestones_reached(level)
	var out: Dictionary = {}
	for k in r.keys():
		out[k] = r[k]

	# Percent scalar fields
	if r.has("base_pct"):
		var base_pct: float = float(r["base_pct"])
		var step: float = float(r.get("per_milestone_pct", 0.0))
		out["pct_at_level"] = base_pct + step * float(ms)

	# Dual tuners (e.g., hit & damage)
	if r.has("base_hit_pct"):
		var bh: float = float(r["base_hit_pct"])
		var sh: float = float(r.get("per_milestone_hit_pct", 0.0))
		out["hit_pct_at_level"] = bh + sh * float(ms)
	if r.has("base_damage_pct"):
		var bd: float = float(r["base_damage_pct"])
		var sd: float = float(r.get("per_milestone_damage_pct", 0.0))
		out["damage_pct_at_level"] = bd + sd * float(ms)

	# Duration steps (every N milestones grant +1 turn)
	if r.has("duration_turns"):
		var dur: int = int(r["duration_turns"])
		var step_every: int = int(r.get("duration_turns_step_every", 9999))
		var extra: int = 0
		if step_every > 0:
			extra = ms / step_every
		out["duration_turns_at_level"] = dur + extra

	return out

func milestone_stat_grant(ability_id: StringName) -> Dictionary:
	var e: Dictionary = entry(ability_id)
	var bias_any: Variant = e.get("stat_bias", {})
	var bias: Dictionary = (bias_any as Dictionary) if typeof(bias_any) == TYPE_DICTIONARY else {}
	var keys: Array[String] = [
		"STR","AGI","DEX","END","INT","WIS","CHA","LCK"
	]
	var weights: Array[float] = []
	var sum_w: float = 0.0
	for k in keys:
		var w: float = float(bias.get(k, 0.0))
		weights.append(w)
		sum_w += w

	var grants: Dictionary = {}
	if sum_w <= 0.0:
		grants["END"] = 10
		return grants

	var target: int = 10
	var base_shares: Array[int] = []
	var remainders: Array[float] = []
	var used: int = 0
	for i in range(keys.size()):
		var exact: float = (weights[i] / sum_w) * float(target)
		var floor_v: int = int(floor(exact))
		base_shares.append(floor_v)
		remainders.append(exact - float(floor_v))
		used += floor_v

	var remaining: int = max(0, target - used)
	var idxs: Array[int] = []
	for i in range(keys.size()):
		idxs.append(i)
	idxs.sort_custom(func(a: int, b: int) -> bool:
		var ra: float = remainders[a]
		var rb: float = remainders[b]
		return (ra > rb) if ra != rb else (keys[a] < keys[b])
	)
	for j in range(remaining):
		var pick: int = idxs[j % idxs.size()]
		base_shares[pick] += 1

	for i in range(keys.size()):
		if base_shares[i] != 0:
			grants[keys[i]] = base_shares[i]
	return grants

# -------------------------------------------------------------------
# Internals
# -------------------------------------------------------------------
func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true

	var f: FileAccess = FileAccess.open(catalog_path, FileAccess.READ)
	if f == null:
		push_error("[AbilityCatalog] Could not open catalog: " + catalog_path)
		return

	var txt: String = f.get_as_text()
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_ARRAY:
		push_error("[AbilityCatalog] JSON root is not an array: " + catalog_path)
		return

	var arr: Array = (parsed as Array)
	for item in arr:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = (item as Dictionary)
		var id: String = String(e.get("ability_id", ""))
		if id == "":
			continue
		_by_id[id] = e

	_order_ids = _sorted_ids()
	print("[AbilityCatalog] Loaded entries=%d" % _by_id.size())

func _sorted_ids() -> PackedStringArray:
	var keys: PackedStringArray = PackedStringArray()
	for k in _by_id.keys():
		keys.append(String(k))
	keys.sort()
	return keys
