# res://scripts/autoload/RunState.gd
extends Node

## Lightweight, typed wrapper over SaveManager.run JSON.
## - Holds a cached mirror of RUN fields.
## - All mutations go through helper methods that SaveManager.save_run().
## - Use reload() after scene loads; use save() only if you batch-mutate.
## - RNG is seeded from run_seed on reload/new run.

signal changed()
signal pools_changed(hp: int, hp_max: int, mp: int, mp_max: int)

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

# --- Character mirrors (from META) + session delta (in RUN) ---
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
	# --- META mirrors: level/xp/xp_needed ---
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl_any: Variant = gs.get("player")
	var pl: Dictionary = (pl_any as Dictionary) if pl_any is Dictionary else {}
	var sb_any: Variant = pl.get("stat_block")
	var sb: Dictionary = (sb_any as Dictionary) if sb_any is Dictionary else {}
	
	# Attributes & unspent points from META
	var attrs_any: Variant = sb.get("attributes", {})
	char_attributes = (attrs_any as Dictionary) if attrs_any is Dictionary else {}
	char_points_unspent = int(pl.get("points_unspent", 0))

	char_level      = int(sb.get("level", 1))
	char_xp_current = int(sb.get("xp_current", 0))
	char_xp_needed  = int(sb.get("xp_needed", 90))

	# --- RUN-scoped session delta (optional, for banking later) ---
	char_xp_delta   = int(_r.get("char_xp_delta", 0))
	
	# read
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
	# write
	_r["run_seed"] = run_seed
	_r["depth"] = max(1, depth)
	_r["furthest_depth_reached"] = max(_r.get("furthest_depth_reached", 1), furthest_depth_reached)

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
	if SaveManager.has_method("start_new_run"):
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
	
func spend_attribute_point(attr: String, slot: int = default_slot) -> bool:
	if char_points_unspent <= 0:
		return false
	if not char_attributes.has(attr):
		return false
	# Load META, mutate, save, then refresh mirrors
	var meta: Dictionary = SaveManager.load_game(slot)
	var player_any: Variant = meta.get("player", {})
	var player: Dictionary = (player_any as Dictionary) if player_any is Dictionary else {}
	var sb_any: Variant = player.get("stat_block", {})
	var sb: Dictionary = (sb_any as Dictionary) if sb_any is Dictionary else {}
	var attrs_any: Variant = sb.get("attributes", {})
	var attrs: Dictionary = (attrs_any as Dictionary) if attrs_any is Dictionary else {}

	attrs[attr] = int(attrs.get(attr, 0)) + 1
	player["points_unspent"] = max(0, int(player.get("points_unspent", 0)) - 1)
	sb["attributes"] = attrs
	player["stat_block"] = sb
	meta["player"] = player

	SaveManager.save_game(meta, slot)

	# Refresh mirrors and notify UI
	reload(slot)
	emit_signal("changed")
	return true

# --- add near the top for convenience ---
func reload_and_broadcast(slot: int = default_slot) -> void:
	reload(slot)        # repull from SaveManager
	emit_signal("changed")
