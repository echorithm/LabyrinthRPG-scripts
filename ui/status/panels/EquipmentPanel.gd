# res://scripts/autoload/RunState.gd
# Lightweight, typed wrapper over RUN json (slot-safe).
extends Node

signal changed()
signal pools_changed(hp: int, hp_max: int, mp: int, mp_max: int)

const _Derived := preload("res://scripts/combat/derive/DerivedCalc.gd")

# -------------------------------------------------------------------
# Cached mirrors from RUN (keep shapes stable for UI)
# -------------------------------------------------------------------
var run_seed: int = 0
var depth: int = 1
var furthest_depth_reached: int = 1

var hp_max: int = 30
var hp: int = 30
var mp_max: int = 10
var mp: int = 10
var stam_max: int = 50
var stam: int = 50

var gold: int = 0
var shards: int = 0

var inventory: Array = []           # Array[Dictionary]
var equipment: Dictionary = {}      # slot -> uid
var weapon_tags: Array[String] = [] # copied at run start

# Character mirrors (from RUN)
var char_level: int = 1
var char_xp_current: int = 0
var char_xp_needed: int = 90
var char_xp_delta: int = 0
var char_attributes: Dictionary = {}   # { "STR": int, ... }
var char_points_unspent: int = 0

# Local cache of the current RUN dictionary (never expose directly)
var _r: Dictionary = {}

# Deterministic RNG for any per-session needs
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

# Preferred slot for this autoload. 0 means "resolve via SaveManager.active_slot()".
@export var default_slot: int = 0

func _ready() -> void:
	# Do NOT create files at boot. Only mirror if an active slot already exists.
	var s: int = _resolve_slot(default_slot)
	if SaveManager.run_exists(s) or SaveManager.meta_exists(s):
		reload(s)
	# else wait for initialize_after_slot_chosen(slot)

# Call this once the Main Menu or caller has set SceneTree.meta("current_slot")
# or otherwise decided the slot to use.
func initialize_after_slot_chosen(slot: int) -> void:
	default_slot = max(1, slot)
	reload(default_slot)

# -------------------------------------------------------------------
# Internals: coercers / helpers
# -------------------------------------------------------------------
static func _intv(v: Variant, def: int = 0) -> int:
	if typeof(v) == TYPE_INT:
		return int(v)
	if typeof(v) == TYPE_FLOAT:
		return int(round(float(v)))
	if typeof(v) == TYPE_STRING:
		var s := String(v)
		if s.is_valid_int():
			return int(s.to_int())
	return def

static func _floatv(v: Variant, def: float = 0.0) -> float:
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return float(v)
	if typeof(v) == TYPE_STRING:
		var s := String(v)
		if s.is_valid_float():
			return float(s.to_float())
	return def

static func _dictv(v: Variant) -> Dictionary:
	return (v as Dictionary) if v is Dictionary else {}

static func _to_string_array(v: Variant) -> Array[String]:
	var out: Array[String] = []
	if v is Array:
		for x in (v as Array):
			out.append(String(x))
	elif v is PackedStringArray:
		for x in (v as PackedStringArray):
			out.append(String(x))
	return out

static func _resolve_slot(slot: int) -> int:
	return (slot if slot > 0 else SaveManager.active_slot())

# Normalize inventory row shapes for UI stability
static func _normalize_inv_shape(inv_in: Array) -> Array:
	var out: Array = []
	for any in inv_in:
		if not (any is Dictionary):
			continue
		var it: Dictionary = (any as Dictionary).duplicate(true)
		var opts: Dictionary = _dictv(it.get("opts", {}))

		# Lift/coerce common fields
		if not it.has("durability_max"):
			it["durability_max"] = _intv(opts.get("durability_max", 0), 0)
		else:
			it["durability_max"] = _intv(it["durability_max"], 0)

		if not it.has("durability_current"):
			it["durability_current"] = _intv(opts.get("durability_current", it.get("durability_max", 0)), _intv(it.get("durability_max", 0), 0))
		else:
			it["durability_current"] = _intv(it["durability_current"], _intv(it.get("durability_max", 0), 0))

		it["rarity"] = String(it.get("rarity", String(opts.get("rarity",""))))
		it["ilvl"]   = _intv(it.get("ilvl", _intv(opts.get("ilvl", 1), 1)), 1)
		it["archetype"] = String(it.get("archetype", String(opts.get("archetype",""))))
		it["weight"] = _floatv(it.get("weight", _floatv(opts.get("weight", 0.0), 0.0)), 0.0)

		# Optional affixes: prefer top-level, lift if only in opts
		if not it.has("affixes") and opts.has("affixes"):
			var aff_any: Variant = opts.get("affixes", [])
			if aff_any is Array:
				it["affixes"] = (aff_any as Array).duplicate(true)

		# Count for stackables; gear forced to 1
		it["count"] = _intv(it.get("count", 1), 1)
		if _intv(it.get("durability_max", 0), 0) > 0:
			it["count"] = 1

		out.append(it)
	return out

# -------------------------------------------------------------------
# Public: reload/save mirrors
# -------------------------------------------------------------------
func reload(slot: int = default_slot) -> void:
	var s: int = _resolve_slot(slot)
	_r = SaveManager.load_run(s).duplicate(true)

	# Character
	var sb_any: Variant = _r.get("player_stat_block", {})
	var sb: Dictionary = (sb_any as Dictionary) if sb_any is Dictionary else {}
	char_level      = int(sb.get("level", 1))
	char_xp_current = int(sb.get("xp_current", 0))
	char_xp_needed  = int(sb.get("xp_needed", 90))

	var attrs_any: Variant = _r.get("player_attributes", {})
	char_attributes = (attrs_any as Dictionary) if attrs_any is Dictionary else {}
	char_points_unspent = int(_r.get("points_unspent", 0))

	char_xp_delta = int(_r.get("char_xp_delta", 0))

	# Other RUN fields
	run_seed = int(_r.get("run_seed", 0))
	depth = int(_r.get("depth", 1))
	furthest_depth_reached = int(_r.get("furthest_depth_reached", depth))

	hp_max = int(_r.get("hp_max", 30))
	hp     = clampi(int(_r.get("hp", hp_max)), 0, hp_max)
	mp_max = int(_r.get("mp_max", 10))
	mp     = clampi(int(_r.get("mp", mp_max)), 0, mp_max)
	stam_max = int(_r.get("stam_max", 50))
	stam     = clampi(int(_r.get("stam", stam_max)), 0, stam_max)

	gold   = int(_r.get("gold", 0))
	shards = int(_r.get("shards", 0))

	# Inventory / equipment
	var inv_any: Variant = _r.get("inventory", [])
	var inv_raw: Array = (inv_any as Array) if inv_any is Array else []
	inventory = _normalize_inv_shape(inv_raw)

	var eq_any: Variant = _r.get("equipment", {})
	equipment = (eq_any as Dictionary) if eq_any is Dictionary else {}
	weapon_tags = _to_string_array(_r.get("weapon_tags", []))

	# RNG seed
	if run_seed != 0:
		rng.seed = run_seed
	else:
		rng.randomize()

	emit_signal("changed")
	emit_signal("pools_changed", hp, hp_max, mp, mp_max)

func save(slot: int = default_slot) -> void:
	var s: int = _resolve_slot(slot)

	# write mirrors back to RUN (only fields we own)
	_r["run_seed"] = run_seed
	_r["depth"] = max(1, depth)
	_r["furthest_depth_reached"] = max(int(_r.get("furthest_depth_reached", 1)), furthest_depth_reached)

	_r["hp_max"] = hp_max
	_r["hp"]     = clampi(hp, 0, hp_max)
	_r["mp_max"] = mp_max
	_r["mp"]     = clampi(mp, 0, mp_max)
	_r["stam_max"] = stam_max
	_r["stam"]     = clampi(stam, 0, stam_max)

	_r["gold"]   = max(0, gold)
	_r["shards"] = max(0, shards)

	_r["inventory"] = inventory
	_r["equipment"] = equipment
	_r["weapon_tags"] = weapon_tags

	_r["char_xp_delta"] = max(0, char_xp_delta)

	SaveManager.save_run(_r, s)

# -------------------------------------------------------------------
# Convenience API used by UI/gameplay
# -------------------------------------------------------------------
func new_run_from_meta(clear_floor_state: bool = true, slot: int = default_slot) -> void:
	var s: int = _resolve_slot(slot)
	# Route through SaveManager so mirror is canonical
	if SaveManager.has_method("start_or_refresh_run_from_meta"):
		SaveManager.start_or_refresh_run_from_meta(s)
	elif SaveManager.has_method("start_new_run"):
		SaveManager.start_new_run(s, clear_floor_state)
	reload(s)

func add_character_xp(amount: int, autosave: bool = true, slot: int = default_slot) -> void:
	var a: int = max(0, amount)
	if a == 0:
		return
	char_xp_delta += a
	if autosave:
		save(slot)
	emit_signal("changed")

# Pools & currencies
func set_hp(value: int, autosave: bool = true, slot: int = default_slot) -> void:
	hp = clampi(value, 0, hp_max)
	if autosave: save(slot)
	emit_signal("pools_changed", hp, hp_max, mp, mp_max)

func heal_hp(amount: int, autosave: bool = true, slot: int = default_slot) -> void:
	if amount <= 0: return
	hp = min(hp_max, hp + amount)
	if autosave: save(slot)
	emit_signal("pools_changed", hp, hp_max, mp, mp_max)

func set_mp(value: int, autosave: bool = true, slot: int = default_slot) -> void:
	mp = clampi(value, 0, mp_max)
	if autosave: save(slot)
	emit_signal("pools_changed", hp, hp_max, mp, mp_max)

func spend_mp(amount: int, autosave: bool = true, slot: int = default_slot) -> bool:
	var a: int = max(0, amount)
	if a == 0 or mp < a:
		return false
	mp -= a
	if autosave: save(slot)
	emit_signal("pools_changed", hp, hp_max, mp, mp_max)
	return true

func add_gold(amount: int, autosave: bool = true, slot: int = default_slot) -> void:
	var a: int = max(0, amount)
	if a == 0: return
	gold += a
	if autosave: save(slot)
	emit_signal("changed")

func add_shards(amount: int, autosave: bool = true, slot: int = default_slot) -> void:
	var a: int = max(0, amount)
	if a == 0: return
	shards += a
	if autosave: save(slot)
	emit_signal("changed")

# Depth helpers
func set_depth(new_depth: int, autosave: bool = true, slot: int = default_slot) -> void:
	depth = max(1, new_depth)
	furthest_depth_reached = max(furthest_depth_reached, depth)
	if autosave: save(slot)
	emit_signal("changed")

# Inventory helpers (RUN-scoped)
func run_inventory() -> Array:
	return inventory

func set_run_inventory(inv: Array, autosave: bool = true, slot: int = default_slot) -> void:
	inventory = _normalize_inv_shape(inv)
	if autosave: save(slot)
	emit_signal("changed")

func set_equipment(eq: Dictionary, autosave: bool = true, slot: int = default_slot) -> void:
	equipment = eq
	if autosave: save(slot)
	emit_signal("changed")

# Attribute points (RUN-scoped; pools re-derived)
func spend_attribute_point(attr: String, slot: int = default_slot) -> bool:
	var s: int = _resolve_slot(slot)
	var rs: Dictionary = SaveManager.load_run(s)
	var points: int = int(rs.get("points_unspent", 0))
	if points <= 0:
		return false

	var attrs_any: Variant = rs.get("player_attributes", {})
	var attrs: Dictionary = (attrs_any as Dictionary) if attrs_any is Dictionary else {}
	if not attrs.has(attr):
		return false

	attrs[attr] = int(attrs.get(attr, 0)) + 1
	rs["player_attributes"] = attrs
	rs["points_unspent"] = max(0, points - 1)

	var hpM: int = int(_Derived.hp_max(attrs, {}))
	var mpM: int = int(_Derived.mp_max(attrs, {}))
	var stM: int = int(_Derived.stam_max(attrs, {}))

	var old_hp: int = int(rs.get("hp", hpM))
	var old_hpM: int = int(rs.get("hp_max", hpM))
	var old_mp: int = int(rs.get("mp", mpM))
	var old_mpM: int = int(rs.get("mp_max", mpM))
	var old_sm: int = int(rs.get("stam", stM))
	var old_smM: int = int(rs.get("stam_max", stM))

	rs["hp_max"] = hpM
	rs["mp_max"] = mpM
	rs["stam_max"] = stM

	var hp_ratio := (float(old_hp) / float(max(1, old_hpM)))
	var mp_ratio := (float(old_mp) / float(max(1, old_mpM)))
	var sm_ratio := (float(old_sm) / float(max(1, old_smM)))
	rs["hp"] = clampi(int(round(hp_ratio * hpM)), 0, hpM)
	rs["mp"] = clampi(int(round(mp_ratio * mpM)), 0, mpM)
	rs["stam"] = clampi(int(round(sm_ratio * stM)), 0, stM)

	SaveManager.save_run(rs, s)
	reload(s)
	emit_signal("changed")
	emit_signal("pools_changed", hp, hp_max, mp, mp_max)
	return true

# Convenience
func reload_and_broadcast(slot: int = default_slot) -> void:
	reload(slot)
	emit_signal("changed")

# Text dump (optional)
func as_text() -> String:
	return "Run(seed=%d, depth=%d/%d, gold=%d, shards=%d, hp=%d/%d, mp=%d/%d, stam=%d/%d)" \
		% [run_seed, depth, furthest_depth_reached, gold, shards, hp, hp_max, mp, mp_max, stam, stam_max]

# Slot getter for code that asks this autoload
func get_slot() -> int:
	return _resolve_slot(default_slot)

# Costs & heals
func ability_costs(ability_id: String) -> Dictionary:
	return AbilityCatalogService.costs(ability_id)

func can_pay_costs(need_mp: int, need_stam: int) -> bool:
	return (mp >= need_mp) and (stam >= need_stam)

func pay_costs(need_mp: int, need_stam: int, autosave: bool = true, slot: int = default_slot) -> Dictionary:
	if mp < need_mp:
		return { "ok": false, "reason": "mp" }
	if stam < need_stam:
		return { "ok": false, "reason": "stam" }
	mp   = max(0, mp - need_mp)
	stam = max(0, stam - need_stam)
	if autosave:
		save(slot)
	emit_signal("pools_changed", hp, hp_max, mp, mp_max)
	return { "ok": true }

func compute_heal_amount(ability_id: String) -> int:
	var aid: String = String(ability_id)
	if aid.is_empty():
		return 0
	var lvl: int = AbilityService.level(aid, get_slot())
	var WIS: int = int(char_attributes.get("WIS", 8))
	var out: Dictionary = HealMath.compute_full_from_id(aid, lvl, WIS, hp, hp_max)
	return int(out.get("healed", 0))

func apply_heal_ability(aid: String, slot: int = default_slot) -> Dictionary:
	var A: Dictionary = AbilityCatalogService.get_by_id(aid)
	if A.is_empty():
		return {"ok": false, "reason": "bad_id"}

	var costs: Dictionary = AbilityCatalogService.costs(aid)
	var mp_cost: int = int(costs.get("mp", 0))

	var s: int = _resolve_slot(slot)
	var rs: Dictionary = SaveManager.load_run(s)
	var hp0: int = int(rs.get("hp", 0))
	var hpM: int = int(rs.get("hp_max", 0))
	var mp0: int = int(rs.get("mp", 0))
	if hpM <= 0:
		return {"ok": false, "reason": "no_target"}
	if mp0 < mp_cost:
		return {"ok": false, "reason": "mp"}

	var attrs: Dictionary = (rs.get("player_attributes", {}) as Dictionary)
	var WIS: int = int(attrs.get("WIS", 8))
	var lvl: int = AbilityService.level(aid, s)

	var h: Dictionary = HealMath.compute_full_from_id(aid, lvl, WIS, hp0, hpM)
	var healed: int = int(h.get("healed", 0))
	var mp_after: int = max(0, mp0 - mp_cost)

	rs["hp"] = clampi(hp0 + healed, 0, hpM)
	rs["mp"] = mp_after
	rs["updated_at"] = Time.get_unix_time_from_system()
	SaveManager.save_run(rs, s)

	reload(s)  # keep HUD in sync

	return {"ok": true, "healed": healed, "hp": rs["hp"], "mp": rs["mp"]}

func pay_ability_costs(ability_id: String, slot: int = default_slot) -> Dictionary:
	var costs: Dictionary = AbilityCatalogService.costs(ability_id)
	var need_mp: int = int(costs.get("mp", 0))
	var need_stam: int = int(costs.get("stam", 0))

	var s: int = _resolve_slot(slot)
	var rs: Dictionary = SaveManager.load_run()
	var have_mp: int = int(rs.get("mp", mp))
	var have_stam: int = int(rs.get("stam", stam))

	if have_mp < need_mp:
		return {"ok": false, "reason": "mp"}
	if have_stam < need_stam:
		return {"ok": false, "reason": "stam"}

	rs["mp"] = have_mp - need_mp
	rs["stam"] = have_stam - need_stam
	rs["updated_at"] = Time.get_unix_time_from_system()
	SaveManager.save_run(rs, s)

	reload(s)  # keep mirrors & HUD in sync
	return {"ok": true, "mp": rs["mp"], "stam": rs["stam"]}
