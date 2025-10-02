# Godot 4.4.1
extends Node
class_name BattleController

signal battle_finished(result: Dictionary)
signal player_turn_ready()
signal turn_event(event: Dictionary)
signal hud_update(snapshot: Dictionary)
signal window_advance() # defined for UI, but we do NOT emit it here (UI should emit on gesture-begin)

const CTBModel       := preload("res://scripts/combat/ctb/CTBModel.gd")
const CTBParams      := preload("res://scripts/combat/ctb/CTBParams.gd")
const ActionResolver := preload("res://scripts/combat/resolve/ActionResolver.gd")
const RewardPipeline := preload("res://scripts/rewards/RewardPipeline.gd")
const RewardsModal := preload("res://ui/RewardsModal.gd")
const XpTuning := preload("res://scripts/rewards/XpTuning.gd")


var _abilities_by_id: Dictionary = {}  # lazy-loaded cache from JSON
const ABILITY_JSON_PATH: String = "res://data/combat/abilities/ability_catalog.json"
var _ability_uses: Dictionary = {}  # { ability_id: int } – counts successful uses this encounter


@export var auto_player: bool = false
@export var auto_monster: bool = false
@export var params: CTBParams

var _encounter_role: String = "regular" # "regular","elite","boss"

var _monster: MonsterRuntime
var _player: PlayerRuntime

var _ctb_player: CTBModel
var _ctb_monster: CTBModel
var _monster_offensive_cost: int = 100

var _encounter_id: int = 0

var _finish_emitted: bool = false

var _entered: bool = false
var _rng: RandomNumberGenerator


# Optional animation hook injected by BattleLoader
var _anim: AnimationBridge = null

enum State { FILLING, PLAYER_TURN, MONSTER_TURN, END }
var _state: int = State.FILLING

func setup(monster: MonsterRuntime, player: PlayerRuntime, ctb_params: CTBParams) -> void:
	_monster = monster
	_player = player
	params = ctb_params

	_ctb_player = CTBModel.new(params.gauge_size, params.fill_scale, _player.ctb_speed)
	_ctb_monster = CTBModel.new(params.gauge_size, params.fill_scale, _monster.ctb_speed)

	_monster_offensive_cost = 100
	for a_any in _monster.abilities:
		var a := a_any as Dictionary
		if a != null and int(a.get("base_power", 0)) > 0:
			_monster_offensive_cost = int(a.get("ctb_cost", 100))
			break

	_rng = RandomNumberGenerator.new()
	_rng.randomize()

	print("[BC] CTB gauge=%d fill=%.2f  speeds  P=%.1f  M=%.1f  mon_cost=%d"
		% [params.gauge_size, params.fill_scale, _player.ctb_speed, _monster.ctb_speed, _monster_offensive_cost])
	print("[BC] P hp=%d/%d p_atk=%.1f def=%.1f  |  M hp=%d/%d p_atk=%.1f def=%.1f"
		% [_player.hp, _player.hp_max, _player.p_atk, _player.defense,
		   _monster.hp, _monster.hp_max, _monster.p_atk, _monster.defense])

	# Start gauges as if the faster side just hit ready (other side gets proportional fill).
	_set_process_enabled()
	_init_ctb_start()
	_emit_hud()
	
func _set_process_enabled() -> void:
	# Node processing is off by default for plain Node; enable it.
	if not is_processing():
		set_process(true)

func set_anim_bridge(b: AnimationBridge) -> void:
	_anim = b
	print("[BC] AnimBridge set? -> %s" % [str(_anim != null)])
	if _anim != null:
		_anim.play_idle()

func _init_ctb_start() -> void:
	var G: float = float(params.gauge_size)
	var F: float = params.fill_scale
	var sp: float = max(0.0, _player.ctb_speed)
	var sm: float = max(0.0, _monster.ctb_speed)

	# time for faster side to reach full
	var tmin: float = 0.0
	if sp <= 0.0 and sm <= 0.0:
		tmin = INF
	elif sp >= sm:
		tmin = (G / (sp * F)) if sp > 0.0 else INF
	else:
		tmin = (G / (sm * F)) if sm > 0.0 else INF

	_ctb_player.gauge = clampf(sp * F * tmin, 0.0, G)
	_ctb_monster.gauge = clampf(sm * F * tmin, 0.0, G)
	_ctb_player.ready = (_ctb_player.gauge >= G - 0.001)
	_ctb_monster.ready = (_ctb_monster.gauge >= G - 0.001)

	var pstate: String = "READY" if _ctb_player.ready else "fill"
	var mstate: String = "READY" if _ctb_monster.ready else "fill"
	print("[BC] CTB init: tmin=%.4f  gauges  P=%.1f(%s)  M=%.1f(%s)"
		% [tmin, _ctb_player.gauge, pstate, _ctb_monster.gauge, mstate])

	# Choose starting state (player priority on tie).
	if _ctb_player.ready and not _ctb_monster.ready:
		_state = State.PLAYER_TURN
		print("[BC] CTB: init -> PLAYER_TURN")
		_on_enter_player_turn()
	elif _ctb_monster.ready and not _ctb_player.ready:
		_state = State.MONSTER_TURN
		print("[BC] CTB: init -> MONSTER_TURN")
	elif _ctb_player.ready and _ctb_monster.ready:
		_state = State.PLAYER_TURN
		print("[BC] CTB: player_ready -> enter PLAYER_TURN")
		_on_enter_player_turn()
	else:
		_state = State.FILLING
		print("[BC] CTB: init -> FILLING")

func _process(delta: float) -> void:
	if _state == State.END or _monster == null or _player == null or params == null:
		return

	match _state:
		State.FILLING:
			_tick_ctb(delta)
			_check_ready_to_enter_turn()
		State.PLAYER_TURN:
			# waiting for player input (UI drives)
			pass
		State.MONSTER_TURN:
			_perform_monster_turn()
		_:
			pass

func is_waiting_for_player() -> bool:
	var waiting: bool = (_state == State.PLAYER_TURN)
	print("[BC] is_waiting_for_player? -> %s" % [str(waiting)])
	return waiting

# -----------------------------------------------------------------------------
# CTB helpers
# -----------------------------------------------------------------------------

func _tick_ctb(delta: float) -> void:
	_ctb_player.tick(delta)
	_ctb_monster.tick(delta)

func _check_ready_to_enter_turn() -> void:
	if _ctb_player.ready:
		_state = State.PLAYER_TURN
		print("[BC] CTB: player_ready -> enter PLAYER_TURN")
		emit_signal("player_turn_ready")
	elif _ctb_monster.ready:
		_state = State.MONSTER_TURN
		print("[BC] CTB: monster_ready -> enter MONSTER_TURN")

func _try_end_then_to_filling() -> void:
	if _monster.hp <= 0 or _player.hp <= 0:
		_emit_and_free()
	else:
		_state = State.FILLING

# -----------------------------------------------------------------------------
# Player actions
# -----------------------------------------------------------------------------

func perform_player_basic_attack() -> void:
	commit_player_action(&"basic_attack", {})

func commit_player_action(action_id: StringName, payload: Dictionary) -> void:
	if _state != State.PLAYER_TURN:
		print("[BC] commit_player_action ignored — not in PLAYER_TURN")
		return

	var action: StringName = action_id
	print("[BC] PLAYER action commit id=%s payload=%s" % [String(action), str(payload)])

	match action:
		&"basic_attack":
			_resolve_player_basic()
			_consume_player_ctb(100)
		&"guard":
			_apply_player_guard()
			_consume_player_ctb(100)
		&"fizzle":
			_emit_turn_event({"who":"player","type":"fizzle"})
			_consume_player_ctb(100)
		_:
			# Treat anything else as an ability_id from your catalog.
			_resolve_player_ability(String(action))
	_try_end_then_to_filling()



func _resolve_player_basic() -> void:
	var ev := ActionResolver.resolve_basic_physical(
		_player.final_stats, {"p_atk": _player.p_atk, "defense": _player.defense},
		_monster.final_stats, {"p_atk": _monster.p_atk, "defense": _monster.defense},
		false,
		_player.crit_multi,
		_rng,
		"player",
		&"basic_attack"
	)

	if bool(ev.get("hit", false)):
		var dmg: int = int(ev.get("dmg", 0))
		_monster.hp = max(0, _monster.hp - dmg)
		print("[BC] HIT P→M roll=%d +%d vs AC=%d  crit=%s  dmg=%d  Mhp=%d/%d"
			% [int(ev.get("roll",0)), int(ev.get("atk_bonus",0)), int(ev.get("dc",0)),
			   str(ev.get("crit", false)), dmg, _monster.hp, _monster.hp_max])

		# animation: monster took a hit
		if _anim != null:
			_anim.play_player_hit()

		# --- Skill XP (provisional, only on HIT) ---
		var AbilityXPService := preload("res://persistence/services/ability_xp_service.gd")
		var floor_i: int = SaveManager.get_current_floor(SaveManager.DEFAULT_SLOT)
		var is_crit: bool = bool(ev.get("crit", false))
		var kills: int = (1 if _monster.hp <= 0 else 0)
		var ctx := {
			"floor": floor_i,
			"cooldown": 0,
			"mana_cost": 0,
			"stam_cost": 0,
			"hits": 1,
			"crits": (1 if is_crit else 0),
			"kills": kills,
			"elite_kill": (kills == 1 and _encounter_role == "elite"),
			"boss_kill": (kills == 1 and _encounter_role == "boss"),
			"overkill_ratio": 0.0
		}
		if _encounter_id > 0:
			AbilityXPService.award_on_use_provisional(_encounter_id, "basic_attack", ctx, SaveManager.DEFAULT_SLOT)
	else:
		if bool(ev.get("fumble", false)):
			print("[BC] MISS (fumble) P→M roll=1")
		else:
			print("[BC] MISS P→M roll=%d +%d vs AC=%d"
				% [int(ev.get("roll",0)), int(ev.get("atk_bonus",0)), int(ev.get("dc",0))])

	_emit_turn_event(ev)
	_emit_hud()


func _apply_player_guard() -> void:
	_player.guard_active = true
	_player.guard_pending_clear_on_next_turn = true
	print("[BC] STATUS: Guard applied to player (consumed on next incoming hit or next turn start)")
	_emit_turn_event({"who":"player","type":"guard_apply"})
	_emit_hud()

func _consume_player_ctb(cost: int) -> void:
	_ctb_player.consume(max(0, cost))
	print("[BC] Player CTB consumed cost=%d -> gauge=%.1f" % [cost, _ctb_player.gauge])

# -----------------------------------------------------------------------------
# Monster turn
# -----------------------------------------------------------------------------

func _perform_monster_turn() -> void:
	var ability: Dictionary = _pick_monster_offensive_ability()
	var aid: String = _ability_id_of(ability)
	var scaling: String = String(ability.get("scaling", "power"))
	var kind: String = _ability_kind(scaling)
	var anim_key: String = String(ability.get("animation_key", "Attack01"))
	var cost: int = int(ability.get("ctb_cost", _monster_offensive_cost))

	print("[BC] MON action ability=%s kind=%s anim=%s cost=%d"
		% [aid, kind, anim_key, cost])

	# animation: monster action (Attack01 etc.)
	if _anim != null:
		_anim.play_monster_action(anim_key)

	var ev := ActionResolver.resolve_attack(
		_monster.final_stats, {"p_atk": _monster.p_atk, "m_atk": _monster.m_atk, "defense": _monster.defense, "resistance": _monster.resistance},
		_player.final_stats, {"p_atk": _player.p_atk, "m_atk": _player.m_atk, "defense": _player.defense, "resistance": _player.resistance},
		_player.guard_active,
		_monster.crit_multi,
		_rng,
		"monster",
		StringName(aid),
		kind,
		anim_key
	)

	if bool(ev.get("hit", false)):
		var dmg: int = int(ev.get("dmg", 0))
		if bool(ev.get("consumed_guard", false)):
			_player.guard_active = false
			_player.guard_pending_clear_on_next_turn = false
			_emit_turn_event({"who":"player","type":"guard_consume"})
			print("[BC] STATUS: Guard consumed by incoming hit")
		_player.hp = max(0, _player.hp - dmg)
		print("[BC] HIT M→P %s roll=%d +%d vs %s=%d  crit=%s  dmg=%d  PHP=%d/%d"
			% [aid, int(ev.get("roll",0)), int(ev.get("atk_bonus",0)),
			   ("AC" if ev.get("kind","physical") == "physical" else "RC"),
			   int(ev.get("dc",0)), str(ev.get("crit", false)),
			   dmg, _player.hp, _player.hp_max])
	else:
		if bool(ev.get("fumble", false)):
			print("[BC] MISS (fumble) M→P %s roll=1" % [aid])
		else:
			print("[BC] MISS M→P %s roll=%d +%d vs %s=%d"
				% [aid, int(ev.get("roll",0)), int(ev.get("atk_bonus",0)),
				   ("AC" if ev.get("kind","physical") == "physical" else "RC"),
				   int(ev.get("dc",0))])

	_emit_turn_event(ev)
	_emit_hud()

	_ctb_monster.consume(cost)
	print("[BC] Monster CTB consumed cost=%d -> gauge=%.1f" % [cost, _ctb_monster.gauge])
	_try_end_then_to_filling()

func _pick_monster_offensive_ability() -> Dictionary:
	for a_any in _monster.abilities:
		var a := a_any as Dictionary
		if a != null and int(a.get("base_power", 0)) > 0:
			return a
	return {"ability_id":"basic_claw","scaling":"power","animation_key":"Attack01","ctb_cost":_monster_offensive_cost}

func _ability_id_of(a: Dictionary) -> String:
	var s: String = String(a.get("ability_id", ""))
	if s == "":
		s = String(a.get("id", ""))  # normalized/fallback
	return s

func _ability_kind(scaling: String) -> String:
	return "magical" if scaling.to_lower() == "arcane" else "physical"

# -----------------------------------------------------------------------------
# HUD + Finish
# -----------------------------------------------------------------------------

func _emit_turn_event(ev: Dictionary) -> void:
	emit_signal("turn_event", ev)

func _emit_hud() -> void:
	var snap := {
		"player": { "hp": _player.hp, "hp_max": _player.hp_max, "mp": _player.mp, "mp_max": _player.mp_max },
		"monster": { "hp": _monster.hp, "hp_max": _monster.hp_max, "mp": _monster.mp, "mp_max": _monster.mp_max }
	}
	emit_signal("hud_update", snap)

func _emit_and_free() -> void:
	if _finish_emitted:
		return
	_finish_emitted = true
	_state = State.END

	var victory: bool = (_monster.hp <= 0 and _player.hp > 0)
	var outcome: String = ("victory" if victory else "defeat")

	var result: Dictionary = {
		"outcome": outcome,
		"player_hp": _player.hp,
		"player_mp": _player.mp,
		"monster_hp": _monster.hp,
		"encounter_id": _encounter_id,
		"role": _encounter_role,
	}

	# IMPORTANT: keep controller lean; do not grant loot/char XP here.
	# But DO settle/record skill XP now so progress is never lost.
	if victory:
		var floor_i: int = SaveManager.get_current_floor(SaveManager.DEFAULT_SLOT)
		var rs_for_lvl: Dictionary = SaveManager.load_run(SaveManager.DEFAULT_SLOT)
		var sb_any: Variant = rs_for_lvl.get("player_stat_block", {})
		var sb: Dictionary = (sb_any as Dictionary) if sb_any is Dictionary else {}
		var player_level: int = int(sb.get("level", 1))
		var target_level: int = floor_i
		var role_s: String = _encounter_role

		var rng := RandomNumberGenerator.new()
		rng.randomize()

		# We'll also mirror what we applied into RUN.skill_xp_delta for the modal.
		var deltas: Dictionary = {}
		var applied_rows: Array = []

		for id_any in _ability_uses.keys():
			var aid: String = String(id_any)
			var uses: int = int(_ability_uses.get(aid, 0))
			if uses <= 0:
				continue
			var add_xp: int = XpTuning.skill_xp_for_victory(uses, player_level, target_level, role_s, rng)
			if add_xp <= 0:
				continue

			var after_row: Dictionary = SaveManager.apply_skill_xp_to_run(aid, add_xp, SaveManager.DEFAULT_SLOT)
			applied_rows.append({ "id": aid, "xp": add_xp, "after": after_row })
			deltas[aid] = int(deltas.get(aid, 0)) + add_xp

			print("[BC] Victory XP -> %s +%d (uses=%d, role=%s, pL=%d tL=%d) after=%s"
				% [aid, add_xp, uses, role_s, player_level, target_level, str(after_row)])

		# Persist the per-encounter deltas so UI can display them.
		if not deltas.is_empty():
			var rs := SaveManager.load_run(SaveManager.DEFAULT_SLOT)
			var accum: Dictionary = rs.get("skill_xp_delta", {}) as Dictionary
			for k in deltas.keys():
				accum[k] = int(accum.get(k, 0)) + int(deltas[k])
			rs["skill_xp_delta"] = accum
			SaveManager.save_run(rs, SaveManager.DEFAULT_SLOT)

		# Optional: include for listeners (BattleLoader could merge into receipt if desired)
		if applied_rows.size() > 0:
			result["skill_xp_applied"] = applied_rows

	# 🔔 ALWAYS emit, even if something above throws in the future.
	print("[BC] EMIT battle_finished outcome=%s hp=%d mp=%d mhp=%d" % [outcome, _player.hp, _player.mp, _monster.hp])
	emit_signal("battle_finished", result)




func begin(_payload: Dictionary) -> void:
	# Capture encounter context if provided (from router)
	if typeof(_payload) == TYPE_DICTIONARY:
		var p: Dictionary = _payload
		_encounter_id = int(p.get("encounter_id", 0))
		var role_s: String = String(p.get("role",""))
		if role_s != "":
			_encounter_role = role_s
	emit_signal("turn_event", {"who":"system","type":"battle_begin","encounter_id":_encounter_id,"role":_encounter_role})
	_enter_if_ready()

func _enter_if_ready() -> void:
	if _entered or _monster == null or _player == null:
		return
	_entered = true

func _on_enter_player_turn() -> void:
	# One-time clear if Guard was set to expire at turn start
	if _player.guard_pending_clear_on_next_turn:
		_player.guard_active = false
		_player.guard_pending_clear_on_next_turn = false
		print("[BC] STATUS: Guard expired at player turn start")
		_emit_turn_event({"who":"player","type":"guard_expire_turn"})
	_emit_hud()
	emit_signal("player_turn_ready")

func apply_start_bonuses(player_pct: int, monster_pct: int) -> void:
	if params == null or _ctb_player == null or _ctb_monster == null:
		return
	var G: float = float(params.gauge_size)
	var p_add: float = G * clampf(float(player_pct), 0.0, 100.0) / 100.0
	var m_add: float = G * clampf(float(monster_pct), 0.0, 100.0) / 100.0

	_ctb_player.gauge = clampf(_ctb_player.gauge + p_add, 0.0, G)
	_ctb_monster.gauge = clampf(_ctb_monster.gauge + m_add, 0.0, G)
	_ctb_player.ready = (_ctb_player.gauge >= G - 0.001)
	_ctb_monster.ready = (_ctb_monster.gauge >= G - 0.001)

	# If we’re still in FILLING, re-check for entry.
	if _state == State.FILLING:
		_check_ready_to_enter_turn()
	_emit_hud()



func _resolve_player_ability(ability_id: String) -> void:
	var a: Dictionary = _get_ability_def(ability_id)
	if a.is_empty():
		print("[BC] Unknown ability id=%s -> fizzle" % ability_id)
		_emit_turn_event({"who":"player","type":"fizzle","ability_id":ability_id})
		_consume_player_ctb(100) # consume on fizzle
		_emit_hud()
		return

	# --- Gate: require unlocked in RUN ---
	var rs := SaveManager.load_run(SaveManager.DEFAULT_SLOT)
	var st_all: Dictionary = (rs.get("skill_tracks", {}) as Dictionary)
	var st_row: Dictionary = (st_all.get(ability_id, {}) as Dictionary)
	var is_unlocked: bool = bool(st_row.get("unlocked", false))
	if not is_unlocked:
		print("[BC] Ability '%s' is LOCKED -> fizzle" % ability_id)
		_emit_turn_event({"who":"player","type":"fizzle_locked","ability_id":ability_id})
		_consume_player_ctb(100) # consume on fizzle
		_emit_hud()
		return

	var level_i: int = max(1, int(st_row.get("level", 1)))

	# Per-level scaling (+power_pct% per level above 1)
	var base_power: float = float(a.get("base_power", 0.0))
	var per_level: Dictionary = (a.get("progression", {}) as Dictionary).get("per_level", {}) as Dictionary
	var power_pct: float = float(per_level.get("power_pct", 0.0)) # e.g. 0.5
	var power_mult: float = 1.0 + (power_pct * 0.01) * float(level_i - 1)

	# Rider milestones every 5 levels (optional)
	var rider_def: Dictionary = ((a.get("progression", {}) as Dictionary).get("rider", {}) as Dictionary)
	var rider_base_pct: float = float(rider_def.get("base_pct", 0.0))
	var rider_step_pct: float = float(rider_def.get("per_milestone_pct", 0.0))
	var rider_turns: int = int(rider_def.get("duration_turns", 0))
	var milestones: int = int(floor(float(level_i) / 5.0))
	var rider_pct: float = rider_base_pct + rider_step_pct * float(milestones)

	var to_hit: bool = bool(a.get("to_hit", true))
	var scaling: String = String(a.get("scaling", "power"))
	var element: String = String(a.get("element", "physical"))
	var anim_key: String = String(a.get("animation_key", ""))
	var cost: int = int(a.get("ctb_cost", 100))

	print("[BC] Ability '%s' lv=%d base=%.1f mult=%.3f rider=%.1f%%"
		% [ability_id, level_i, base_power, power_mult, rider_pct])

	if to_hit:
		var kind: String = _ability_kind_from_scaling_element(scaling, element)
		if _anim != null and anim_key != "":
			_anim.play_monster_action(anim_key)

		# pass scaling knobs to resolver (back-compat safe)
		var ev: Dictionary = ActionResolver.resolve_attack(
			_player.final_stats,
			{"p_atk": _player.p_atk, "m_atk": _player.m_atk, "defense": _player.defense, "resistance": _player.resistance},
			_monster.final_stats,
			{"p_atk": _monster.p_atk, "m_atk": _monster.m_atk, "defense": _monster.defense, "resistance": _monster.resistance},
			false,
			_player.crit_multi,
			_rng,
			"player",
			StringName(ability_id),
			kind,
			anim_key,
			{ "power_mult": power_mult, "rider": { "type": String(rider_def.get("type","")), "pct": rider_pct, "duration_turns": rider_turns } }
		)

		if bool(ev.get("hit", false)):
			var dmg: int = int(ev.get("dmg", 0))
			_monster.hp = max(0, _monster.hp - dmg)
			print("[BC] HIT P→M (%s) roll=%d +%d vs %s=%d  crit=%s  dmg=%d  Mhp=%d/%d"
				% [ability_id, int(ev.get("roll",0)), int(ev.get("atk_bonus",0)),
				   ("AC" if ev.get("kind","physical") == "physical" else "RC"),
				   int(ev.get("dc",0)), str(ev.get("crit", false)),
				   dmg, _monster.hp, _monster.hp_max])
			if _anim != null:
				_anim.play_player_hit()

			var used: int = int(_ability_uses.get(ability_id, 0))
			_ability_uses[ability_id] = used + 1
		else:
			if bool(ev.get("fumble", false)):
				print("[BC] MISS (fumble) P→M %s roll=1" % [ability_id])
			else:
				print("[BC] MISS P→M %s roll=%d +%d vs %s=%d"
					% [ability_id, int(ev.get("roll",0)), int(ev.get("atk_bonus",0)),
					   ("AC" if ev.get("kind","physical") == "physical" else "RC"),
					   int(ev.get("dc",0))])
		_emit_turn_event(ev)
	else:
		var used2: int = int(_ability_uses.get(ability_id, 0))
		_ability_uses[ability_id] = used2 + 1
		_emit_turn_event({"who":"player","type":"ability_used","ability_id":ability_id,"kind":"support","placeholder":true})

	_emit_hud()
	_consume_player_ctb(cost)



func _ability_kind_from_scaling_element(scaling: String, element: String) -> String:
	# Physical if weapon/power/finesse/physical; magical otherwise.
	var s := scaling.to_lower()
	var e := element.to_lower()
	if e == "physical":
		return "physical"
	if s == "power" or s == "finesse":
		return "physical"
	# arcane/divine/support or elemental → magical resolution numbers
	return "magical"

func _get_ability_def(ability_id: String) -> Dictionary:
	if _abilities_by_id.has(ability_id):
		return _abilities_by_id[ability_id] as Dictionary

	# Lazy load from JSON (once)
	if _abilities_by_id.is_empty():
		var arr := _load_ability_json()
		for any in arr:
			if any is Dictionary:
				var d: Dictionary = any
				var id: String = String(d.get("ability_id",""))
				if id != "":
					_abilities_by_id[id] = d

	if _abilities_by_id.has(ability_id):
		return _abilities_by_id[ability_id] as Dictionary
	return {}

func _load_ability_json() -> Array:
	var out: Array = []
	if not ResourceLoader.exists(ABILITY_JSON_PATH):
		print("[BC] ability_catalog.json missing at ", ABILITY_JSON_PATH)
		return out
	var f: FileAccess = FileAccess.open(ABILITY_JSON_PATH, FileAccess.READ)
	if f == null:
		print("[BC] cannot open ", ABILITY_JSON_PATH)
		return out
	var txt: String = f.get_as_text()
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) == TYPE_ARRAY:
		return (parsed as Array)
	print("[BC] ability_catalog.json parse error (expected Array)")
	return out
