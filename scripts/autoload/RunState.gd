# res://scripts/autoload/RunState.gd
extends Node

## Lightweight, typed wrapper over SaveManager.run JSON.
## - Holds a cached mirror of RUN fields.
## - All mutations go through helper methods that SaveManager.save_run().
## - Use reload() after scene loads; use save() only if you batch-mutate.
## - RNG is seeded from run_seed on reload/new run.

signal changed()
signal pools_changed(hp: int, hp_max: int, mp: int, mp_max: int)

const _Derived := preload("res://scripts/combat/derive/DerivedCalc.gd")

# --- Canonical fields (cached from RUN) ---
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

# Inventory/equipment snapshots (arrays/dicts per RunSchema v3+)
var inventory: Array = []           # Array[Dictionary]
var equipment: Dictionary = {}      # {slot:String -> uid:String|null}
var weapon_tags: Array[String] = [] # tags copied at run-start

# Local cache of the current RUN dictionary (never expose directly)
var _r: Dictionary = {}

# RNG seeded from run_seed for any per-battle/per-floor rolls you keep here
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

# --- Character mirrors (from RUN) + session delta (in RUN) ---
var char_level: int = 1
var char_xp_current: int = 0
var char_xp_needed: int = 90
var char_xp_delta: int = 0  # RUN-scoped; banked to META on safe exit
var char_attributes: Dictionary = {}   # { "STR": int, ... }
var char_points_unspent: int = 0

# Preferred save slot (UI can override as needed)
@export var default_slot: int = 1

func _ready() -> void:
	reload(default_slot)

# -------------------------------------------------------------------
# Sync helpers
# -------------------------------------------------------------------
func reload(slot: int = default_slot) -> void:
	_r = SaveManager.load_run(slot).duplicate(true)

	# --- Character from RUN ---
	var sb_any: Variant = _r.get("player_stat_block", {})
	var sb: Dictionary = (sb_any as Dictionary) if sb_any is Dictionary else {}
	char_level      = int(sb.get("level", 1))
	char_xp_current = int(sb.get("xp_current", 0))
	char_xp_needed  = int(sb.get("xp_needed", 90))

	var attrs_any: Variant = _r.get("player_attributes", {})
	char_attributes = (attrs_any as Dictionary) if attrs_any is Dictionary else {}
	char_points_unspent = int(_r.get("points_unspent", 0))

	# --- RUN-scoped session delta (optional) ---
	char_xp_delta = int(_r.get("char_xp_delta", 0))

	# --- read other RUN fields ---
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

	var inv_any: Variant = _r.get("inventory", [])
	inventory = (inv_any as Array) if inv_any is Array else []
	var eq_any: Variant = _r.get("equipment", {})
	equipment = (eq_any as Dictionary) if eq_any is Dictionary else {}
	weapon_tags = _to_string_array(_r.get("weapon_tags", []))

	# RNG
	if run_seed != 0:
		rng.seed = run_seed
	else:
		rng.randomize()

	emit_signal("changed")
	emit_signal("pools_changed", hp, hp_max, mp, mp_max)

func save(slot: int = default_slot) -> void:
	# write mirrors back into RUN (only fields we own)
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

	SaveManager.save_run(_r, slot)

# -------------------------------------------------------------------
# Lifecycle helpers
# -------------------------------------------------------------------
func new_run_from_meta(clear_floor_state: bool = true, slot: int = default_slot) -> void:
	# Use SaveManager route so RUN defaults & derived pools are created consistently.
	if SaveManager.has_method("start_or_refresh_run_from_meta"):
		SaveManager.start_or_refresh_run_from_meta(slot)
	elif SaveManager.has_method("start_new_run"):
		SaveManager.start_new_run(slot, clear_floor_state)
	reload(slot)

func add_character_xp(amount: int, autosave: bool = true, slot: int = default_slot) -> void:
	var a: int = max(0, amount)
	if a == 0:
		return
	char_xp_delta += a
	if autosave:
		save(slot)
	emit_signal("changed")

# -------------------------------------------------------------------
# Pool & currency convenience
# -------------------------------------------------------------------
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

# -------------------------------------------------------------------
# Depth helpers
# -------------------------------------------------------------------
func set_depth(new_depth: int, autosave: bool = true, slot: int = default_slot) -> void:
	depth = max(1, new_depth)
	furthest_depth_reached = max(furthest_depth_reached, depth)
	if autosave: save(slot)
	emit_signal("changed")

# -------------------------------------------------------------------
# Inventory helpers (thin, RUN-scoped)
# -------------------------------------------------------------------
func run_inventory() -> Array:
	return inventory

func set_run_inventory(inv: Array, autosave: bool = true, slot: int = default_slot) -> void:
	inventory = inv
	if autosave: save(slot)
	emit_signal("changed")

func set_equipment(eq: Dictionary, autosave: bool = true, slot: int = default_slot) -> void:
	equipment = eq
	if autosave: save(slot)
	emit_signal("changed")

# -------------------------------------------------------------------
# Attribute allocation (RUN-scoped; pools re-derived)
# -------------------------------------------------------------------
func spend_attribute_point(attr: String, slot: int = default_slot) -> bool:
	# load latest RUN
	var rs: Dictionary = SaveManager.load_run(slot)
	var points: int = int(rs.get("points_unspent", 0))
	if points <= 0:
		return false

	var attrs_any: Variant = rs.get("player_attributes", {})
	var attrs: Dictionary = (attrs_any as Dictionary) if attrs_any is Dictionary else {}
	if not attrs.has(attr):
		return false

	# apply
	attrs[attr] = int(attrs.get(attr, 0)) + 1
	rs["player_attributes"] = attrs
	rs["points_unspent"] = max(0, points - 1)

	# re-derive pools from new attributes
	var hpM: int = int(_Derived.hp_max(attrs, {}))
	var mpM: int = int(_Derived.mp_max(attrs, {}))
	var stM: int = int(_Derived.stam_max(attrs, {}))

	# preserve ratios (gentle)
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

	# save + refresh mirrors
	SaveManager.save_run(rs, slot)
	reload(slot)
	emit_signal("changed")
	emit_signal("pools_changed", hp, hp_max, mp, mp_max)
	return true

# --- convenience ---
func reload_and_broadcast(slot: int = default_slot) -> void:
	reload(slot)
	emit_signal("changed")

# -------------------------------------------------------------------
# Debug
# -------------------------------------------------------------------
func as_text() -> String:
	return "Run(seed=%d, depth=%d/%d, gold=%d, shards=%d, hp=%d/%d, mp=%d/%d, stam=%d/%d)" \
		% [run_seed, depth, furthest_depth_reached, gold, shards, hp, hp_max, mp, mp_max, stam, stam_max]

# -------------------------------------------------------------------
# Small locals
# -------------------------------------------------------------------
static func _to_string_array(v: Variant) -> Array[String]:
	var out: Array[String] = []
	if v is Array:
		for x in (v as Array):
			out.append(String(x))
	elif v is PackedStringArray:
		for x in (v as PackedStringArray):
			out.append(String(x))
	return out
