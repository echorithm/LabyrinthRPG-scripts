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
const ProgressionService := preload("res://persistence/services/progression_service.gd")

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
var inventory: Array[Dictionary] = []   # Array[Dictionary]
var equipment: Dictionary = {}          # {slot:String -> uid:String|null}
var weapon_tags: Array[String] = []     # tags copied at run-start

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
@export var default_slot: int = 0

func _ready() -> void:
	var app: Node = get_node_or_null(^"/root/AppPhase")
	var in_game: bool = (app != null and app.has_method("in_game") and bool(app.call("in_game")))
	# Only touch disk if we already have a META or we are entering game.
	if in_game or SaveManager.meta_exists(default_slot):
		reload(default_slot)
	else:
		rng.randomize()
		emit_signal("changed")
		emit_signal("pools_changed", hp, hp_max, mp, mp_max)

# -------------------------------------------------------------------
# Small locals (typed converters)
# -------------------------------------------------------------------
static func _intv(v: Variant, def: int = 0) -> int:
	if typeof(v) == TYPE_INT:
		return int(v)
	if typeof(v) == TYPE_FLOAT:
		return int(round(float(v)))
	if typeof(v) == TYPE_STRING:
		var s: String = String(v)
		if s.is_valid_int():
			return int(s.to_int())
	return def

static func _floatv(v: Variant, def: float = 0.0) -> float:
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return float(v)
	if typeof(v) == TYPE_STRING:
		var s: String = String(v)
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

# Normalize inventory rows to a stable, UI-friendly shape.
# - Coerces numeric fields to ints/floats
# - Lifts common fields from opts.* to top-level if missing
# - Ensures gear (dmax>0) has count=1
static func _normalize_inv_shape(inv_in: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for any in inv_in:
		if not (any is Dictionary):
			continue
		var it: Dictionary = (any as Dictionary).duplicate(true)

		var opts: Dictionary = _dictv(it.get("opts", {}))

		# Lift fields if not present
		if not it.has("durability_max"):
			it["durability_max"] = _intv(opts.get("durability_max", 0), 0)
		else:
			it["durability_max"] = _intv(it["durability_max"], 0)

		if not it.has("durability_current"):
			it["durability_current"] = _intv(opts.get("durability_current", it.get("durability_max", 0)), _intv(it.get("durability_max", 0), 0))
		else:
			it["durability_current"] = _intv(it["durability_current"], _intv(it.get("durability_max", 0), 0))

		if not it.has("rarity") and opts.has("rarity"):
			it["rarity"] = String(opts.get("rarity", ""))
		else:
			it["rarity"] = String(it.get("rarity", ""))

		if not it.has("ilvl") and opts.has("ilvl"):
			it["ilvl"] = _intv(opts.get("ilvl", 1), 1)
		else:
			it["ilvl"] = _intv(it.get("ilvl", 1), 1)

		if not it.has("archetype") and opts.has("archetype"):
			it["archetype"] = String(opts.get("archetype", ""))
		else:
			it["archetype"] = String(it.get("archetype", ""))

		if not it.has("weight") and opts.has("weight"):
			it["weight"] = _floatv(opts.get("weight", 0.0), 0.0)
		else:
			it["weight"] = _floatv(it.get("weight", 0.0), 0.0)

		# Optional affixes may live either place; prefer top-level if present, else lift.
		if not it.has("affixes") and opts.has("affixes"):
			var aff_any: Variant = opts.get("affixes", [])
			if aff_any is Array:
				it["affixes"] = (aff_any as Array).duplicate(true)

		# Count coercion (stackables can arrive as floats)
		it["count"] = _intv(it.get("count", 1), 1)

		# Gear always count=1
		if _intv(it.get("durability_max", 0), 0) > 0:
			it["count"] = 1

		out.append(it)
	return out

# -------------------------------------------------------------------
# Skill-track XP re-derivation (unifies curve across all writers)
# -------------------------------------------------------------------
func _rederive_skill_tracks_xp_needed(slot: int) -> void:
	var rs: Dictionary = SaveManager.load_run(slot)
	var player_any: Variant = rs.get("player", {})
	var player: Dictionary = (player_any as Dictionary) if player_any is Dictionary else {}
	var st_any: Variant = player.get("skill_tracks", {})
	var st: Dictionary = (st_any as Dictionary) if st_any is Dictionary else {}

	var changed: bool = false
	for key_any in st.keys():
		var key: String = String(key_any)
		var tr_any: Variant = st.get(key, {})
		if not (tr_any is Dictionary):
			continue
		var tr: Dictionary = (tr_any as Dictionary)
		var lvl: int = int(tr.get("level", 1))
		# Use the same provider the character uses; it is difficulty-aware.
		var want_needed: int = int(ProgressionService.xp_to_next(lvl))
		var have_needed: int = int(tr.get("xp_needed", want_needed))
		if have_needed != want_needed:
			tr["xp_needed"] = want_needed
			st[key] = tr
			changed = true

	if changed:
		player["skill_tracks"] = st
		rs["player"] = player
		SaveManager.save_run(rs, slot)

# -------------------------------------------------------------------
# Sync helpers
# -------------------------------------------------------------------
func reload(slot: int = default_slot) -> void:
	# Before mirroring fields, force-sanitize all skill track xp_needed
	_rederive_skill_tracks_xp_needed(slot)

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

	# Inventory/equipment (normalized)
	var inv_any: Variant = _r.get("inventory", [])
	var inv_raw: Array = (inv_any as Array) if inv_any is Array else []
	inventory = _normalize_inv_shape(inv_raw)

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
func run_inventory() -> Array[Dictionary]:
	return inventory

func set_run_inventory(inv: Array, autosave: bool = true, slot: int = default_slot) -> void:
	inventory = _normalize_inv_shape(inv)  # keep shape consistent on writes too
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

	var hp_ratio: float = (float(old_hp) / float(max(1, old_hpM)))
	var mp_ratio: float = (float(old_mp) / float(max(1, old_mpM)))
	var sm_ratio: float = (float(old_sm) / float(max(1, old_smM)))
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

# --- Convenience: which slot are we using? ---
func get_slot() -> int:
	return int(default_slot)  # BattleController can call RunState.get_slot()

# --- Costs for any ability ---
func ability_costs(ability_id: String) -> Dictionary:
	return AbilityCatalogService.costs(ability_id)  # { mp, stam, cooldown }

# --- Can we pay these costs from RUN pools? ---
func can_pay_costs(need_mp: int, need_stam: int) -> bool:
	return (mp >= need_mp) and (stam >= need_stam)

# --- Deduct costs atomically, save, and broadcast. Returns { ok, reason? } ---
func pay_costs(need_mp: int, need_stam: int, autosave: bool = true) -> Dictionary:
	if mp < need_mp:
		return { "ok": false, "reason": "mp" }
	if stam < need_stam:
		return { "ok": false, "reason": "stam" }
	mp   = max(0, mp - need_mp)
	stam = max(0, stam - need_stam)
	if autosave:
		save(default_slot)
	emit_signal("pools_changed", hp, hp_max, mp, mp_max)
	return { "ok": true }

# --- Heal math placed here so BC stays thin ---
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

	# Costs
	var costs: Dictionary = AbilityCatalogService.costs(aid)
	var mp_cost: int = int(costs.get("mp", 0))

	# Load RUN
	var rs: Dictionary = SaveManager.load_run(slot)
	var hp0: int = int(rs.get("hp", 0))
	var hpM: int = int(rs.get("hp_max", 0))
	var mp0: int = int(rs.get("mp", 0))
	if hpM <= 0:
		return {"ok": false, "reason": "no_target"}
	if mp0 < mp_cost:
		return {"ok": false, "reason": "mp"}

	# Inputs for HealMath
	var attrs: Dictionary = (rs.get("player_attributes", {}) as Dictionary)
	var WIS: int = int(attrs.get("WIS", 8))
	var lvl: int = AbilityService.level(aid, slot)

	var h: Dictionary = HealMath.compute_full_from_id(aid, lvl, WIS, hp0, hpM)
	var healed: int = int(h.get("healed", 0))
	var mp_after: int = max(0, mp0 - mp_cost)

	rs["hp"] = clampi(hp0 + healed, 0, hpM)
	rs["mp"] = mp_after
	rs["updated_at"] = Time.get_unix_time_from_system()
	SaveManager.save_run(rs, slot)

	reload(slot)  # keep HUD in sync

	return {"ok": true, "healed": healed, "hp": rs["hp"], "mp": rs["mp"]}

func pay_ability_costs(ability_id: String, slot: int = default_slot) -> Dictionary:
	var costs: Dictionary = AbilityCatalogService.costs(ability_id)
	var need_mp: int = int(costs.get("mp", 0))
	var need_stam: int = int(costs.get("stam", 0))

	var rs: Dictionary = SaveManager.load_run(slot)
	var have_mp: int = int(rs.get("mp", mp))
	var have_stam: int = int(rs.get("stam", stam))

	if have_mp < need_mp:
		return {"ok": false, "reason": "mp"}
	if have_stam < need_stam:
		return {"ok": false, "reason": "stam"}

	rs["mp"] = have_mp - need_mp
	rs["stam"] = have_stam - need_stam
	rs["updated_at"] = Time.get_unix_time_from_system()
	SaveManager.save_run(rs, slot)

	reload(slot)  # keep mirrors & HUD in sync

	return {"ok": true, "mp": rs["mp"], "stam": rs["stam"]}

func set_stam(value: int, autosave: bool = true, slot: int = default_slot) -> void:
	stam = clampi(value, 0, stam_max)
	if autosave: save(slot)
	emit_signal("pools_changed", hp, hp_max, mp, mp_max)

func add_stam(amount: int, autosave: bool = true, slot: int = default_slot) -> void:
	if amount <= 0: return
	stam = min(stam_max, stam + amount)
	if autosave: save(slot)
	emit_signal("pools_changed", hp, hp_max, mp, mp_max)
