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

@export var auto_player: bool = false
@export var auto_monster: bool = false
@export var params: CTBParams

var _encounter_role: String = "regular" # "regular","elite","boss"

var _monster: MonsterRuntime
var _player: PlayerRuntime

var _ctb_player: CTBModel
var _ctb_monster: CTBModel
var _monster_offensive_cost: int = 100

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
	_init_ctb_start()
	_emit_hud()

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
			print("[BC] Unknown action id=%s -> fizzle" % [String(action)])
			_emit_turn_event({"who":"player","type":"fizzle"})
			_consume_player_ctb(100)

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
	else:
		if bool(ev.get("fumble", false)):
			print("[BC] MISS (fumble) P→M roll=1")
		else:
			print("[BC] MISS P→M roll=%d +%d vs AC=%d"
				% [int(ev.get("roll",0)), int(ev.get("atk_bonus",0)), int(ev.get("dc",0))])
				
	# --- Skill XP on HIT only ---
	
	# Player level (from META)
	var meta: Dictionary = SaveManager.load_game()
	var player_dict: Dictionary = (meta.get("player", {}) as Dictionary)
	var sb: Dictionary = (player_dict.get("stat_block", {}) as Dictionary)
	var player_level: int = int(sb.get("level", 1))

	# Target level (prefer monster.final_level; fallback to 1)
	var mlv_any: Variant = _monster.get("final_level")
	var target_level: int = int(mlv_any if mlv_any != null else 1)

	# Temporary S_power from monster.power_level (fallback to 1)
	var plv_any: Variant = _monster.get("power_level")
	var power_level: int = int(plv_any if plv_any != null else 1)
	var s_power: float = max(0.25, float(power_level) / 10.0)

	# Only award skill XP on HIT; ev is the resolver result already computed
	if bool(ev.get("hit", false)):
		var sxp_amt: int = XpTuning.skill_xp_for_hit(player_level, target_level, s_power, _rng)
		if sxp_amt > 0:
			var skill_id: String = String(ev.get("ability_id", "basic_attack"))
			RewardService.grant({"skill_xp": [{"id": skill_id, "xp": sxp_amt}]})

	var sxp_amt: int = XpTuning.skill_xp_for_hit(player_level, target_level, s_power, _rng)
	if sxp_amt > 0:
		var skill_id: String = String(ev.get("ability_id", "basic_attack"))
		RewardService.grant({"skill_xp": [{"id": skill_id, "xp": sxp_amt}]})

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
	_state = State.END
	var outcome_is_victory: bool = (_monster.hp <= 0 and _player.hp > 0)
	var outcome: String = ( "victory" if outcome_is_victory else "defeat" )

	if outcome_is_victory:
		var src: String = ("elite" if _encounter_role == "elite" else ("boss" if _encounter_role == "boss" else "trash"))
		var floor_i: int = SaveManager.get_current_floor(SaveManager.DEFAULT_SLOT)
		var rng_seed: int = SaveManager.get_run_seed(SaveManager.DEFAULT_SLOT)
		var summary: Dictionary = RewardPipeline.encounter_victory(src, floor_i, rng_seed)
		# optional: show UI right here if you prefer rather than via LootReward
		# var modal := RewardsModal.new()
		# add_child(modal)
		# modal.present(summary)
	emit_signal("battle_finished", {
		"outcome": outcome,
		"player_hp": _player.hp,
		"player_mp": _player.mp,
		"monster_slug": _monster.slug,
	})
	queue_free()


	var result: Dictionary = {
		"outcome": outcome,
		"player_hp": _player.hp,
		"player_mp": _player.mp,
		"monster_slug": _monster.slug
	}
	print("[BC] END: %s  P=%d/%d  M=%d/%d" % [outcome, _player.hp, _player.hp_max, _monster.hp, _monster.hp_max])
	emit_signal("battle_finished", result)
	queue_free()



func begin(_payload: Dictionary) -> void:
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
