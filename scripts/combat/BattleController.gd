# res://scripts/combat/BattleController.gd
extends Node
class_name BattleController

signal player_turn_ready()
signal turn_event(ev: Dictionary)
signal hud_update(snapshot: Dictionary)
signal battle_finished(result: Dictionary)

@export var debug_logs: bool = true
@export var auto_player: bool = false
@export var auto_monster: bool = true
@export var debug_ctb_tick_log_interval: float = 0.5

const CTBModel := preload("res://scripts/combat/ctb/CTBModel.gd")
const CTBParams := preload("res://scripts/combat/ctb/CTBParams.gd")
const TurnContext := preload("res://scripts/combat/data/TurnContext.gd")
const ActorSnapshot := preload("res://scripts/combat/data/ActorSnapshot.gd")
const AbilityUse := preload("res://scripts/combat/data/AbilityUse.gd")
const ActionResult := preload("res://scripts/combat/data/ActionResult.gd")
const CombatKernel := preload("res://scripts/combat/kernel/CombatKernel.gd")
const RNGService := preload("res://scripts/combat/util/RNGService.gd")
const Events := preload("res://scripts/combat/data/CombatEvents.gd")
const AbilityCatalog := preload("res://persistence/services/ability_catalog_service.gd")
const DefeatFlow := preload("res://persistence/flows/DefeatFlow.gd")
const ResolveTurnPipeline := preload("res://scripts/combat/kernel/pipeline/ResolveTurnPipeline.gd")
const StatusEngine := preload("res://scripts/combat/status/StatusEngine.gd")
const RuntimeReducer := preload("res://scripts/combat/runtime/RuntimeReducer.gd")
const PreUseRules := preload("res://scripts/combat/kernel/pipeline/PreUseRules.gd")
const AbilityXPService := preload("res://persistence/services/ability_xp_service.gd")



var _dbg_tick_accum: float = 0.0
var _in_resolution: bool = false

var _monster: Resource
var _player: Resource
var _params: CTBParams

var _rng: RNGService
var _kernel: CombatKernel = CombatKernel.new()

# CTB state (per actor)
var _ctb_player: CTBModel
var _ctb_monster: CTBModel

# control flags
var _waiting_for_player: bool = false
var _round: int = 1
var _battle_seed: int = 0
var _finished_once: bool = false  # guard against double-finish

# queued player action
var _queued_action: Dictionary = {}  # { kind, ability_id, targets }

# Optional visual bridge
var _anim_bridge: Object = null

# New: for deterministic tie-breaks
var _last_team_turn: StringName = &""   # "player" | "monster"

func setup(monster: Resource, player: Resource, params: CTBParams) -> void:
	_monster = monster
	_player = player
	_params = params
	_battle_seed = _resolve_seed()

	_rng = RNGService.new()
	_rng.seed_from(_battle_seed, 0) # encounter_id=0 placeholder
	print("[BC] Seeded RNG battle_seed=", _battle_seed)

	_ctb_player = CTBModel.new(_params.gauge_size, _params.fill_scale, float(_player.ctb_speed))
	_ctb_monster = CTBModel.new(_params.gauge_size, _params.fill_scale, float(_monster.ctb_speed))

	emit_signal("hud_update", _snapshot())

func apply_start_bonuses(player_pct: int, monster_pct: int) -> void:
	if _ctb_player != null and player_pct != 0:
		_ctb_player.add_delay_raw(-float(_params.gauge_size) * (max(0.0, float(player_pct)) * 0.01))
	if _ctb_monster != null and monster_pct != 0:
		_ctb_monster.add_delay_raw(-float(_params.gauge_size) * (max(0.0, float(monster_pct)) * 0.01))

func begin(payload: Dictionary) -> void:
	var init_mode: String = String(payload.get("initiative", "neutral"))
	CTBModel.apply_initiative(
		init_mode,
		_ctb_player, _ctb_monster,
		float(_player.ctb_speed), float(_monster.ctb_speed),
		_params
	)
	emit_signal("hud_update", _snapshot())
	set_process(true)

func _process(delta: float) -> void:
	if _check_battle_end():
		return
	if _waiting_for_player or _in_resolution:
		return

	# --- Min-time advance to the next ready side (prevents lockstep ties) ---
	var t_p: float = _time_to_ready(_ctb_player)
	var t_m: float = _time_to_ready(_ctb_monster)

	# If neither can progress (rate 0), bail safely
	if t_p == INF and t_m == INF:
		return

	var step: float = min(delta, min(t_p, t_m))
	if step <= 0.0 and not (_ctb_player.ready or _ctb_monster.ready):
		# Nothing to do this frame
		return

	var p_ready_now: bool = _ctb_player.tick(step)
	var m_ready_now: bool = _ctb_monster.tick(step)
	_dbg_ctb_tick(step, p_ready_now, m_ready_now)

	if p_ready_now or m_ready_now:
		emit_signal("hud_update", _snapshot())

	# Decide whose turn when ready (resolve ties fairly)
	if _ctb_player.ready and _ctb_monster.ready:
		var who: StringName = _pick_next_turn()
		if who == &"player":
			_player_turn()
		else:
			_monster_turn()
	elif _ctb_player.ready:
		_player_turn()
	elif _ctb_monster.ready:
		_monster_turn()

func is_waiting_for_player() -> bool:
	return _waiting_for_player

func set_anim_bridge(bridge: Object) -> void:
	_anim_bridge = bridge

# -------- Player flow --------
func _player_turn() -> void:
	_waiting_for_player = true
	_dbg("TURN→PLAYER_READY", {"gauge": _ctb_player.gauge, "ctb_size": _params.gauge_size})
	emit_signal("player_turn_ready")
	if auto_player:
		commit_player_action(&"use_ability", {"ability_id": "arc_slash", "confidence": 1.0})

func commit_player_action(kind: StringName, payload: Dictionary) -> void:
	if not _waiting_for_player:
		return
	_queued_action = {"kind": String(kind)}.merged(payload)
	_dbg("PLAYER_ACTION_COMMIT", _queued_action)
	_waiting_for_player = false
	_resolve_player_action(_queued_action)

func queue_player_action(ability_id: String, targets: Array[int]) -> void:
	commit_player_action(&"use_ability", {"ability_id": ability_id, "targets": targets})

func _resolve_player_action(act: Dictionary) -> void:
	var kind: String = String(act.get("kind",""))
	if kind == "fizzle":
		var fc: int = _reduced_ctb_cost(true, "fizzle")
		print("[BC] Fizzle: cost=", fc)
		_play_sfx_key("fizzle.wav")
		emit_signal("turn_event", {"type":"fizzle","who":"player"})
		_in_resolution = true
		_consume_player_ctb(fc)
		_in_resolution = false
		# Upkeep after a fizzle still happens
		_apply_upkeep_and_emit("player")
		emit_signal("turn_event", Events.gauge_advanced(_player.id, fc, int(round(_ctb_player.gauge))))
		emit_signal("turn_event", Events.turn_summary(_player.id, {}, 1))
		_round += 1
		_last_team_turn = &"player"
		return

	var aid: String = String(act.get("ability_id",""))
	if aid == "":
		var fc2: int = _reduced_ctb_cost(true, "fizzle")
		print("[BC] Empty ability -> fizzle: cost=", fc2)
		_play_sfx_key("fizzle.wav")

		emit_signal("turn_event", {"type":"fizzle","who":"player"})
		_in_resolution = true
		_consume_player_ctb(fc2)
		_in_resolution = false
		_apply_upkeep_and_emit("player")
		emit_signal("turn_event", Events.gauge_advanced(_player.id, fc2, int(round(_ctb_player.gauge))))
		emit_signal("turn_event", Events.turn_summary(_player.id, {}, 1))
		_round += 1
		_last_team_turn = &"player"
		return

	# --- Costs (player-side, via RunState) ---
	var rs: Object = get_node_or_null(^"/root/RunState")
	if rs != null and rs.has_method("pay_ability_costs"):
		var pay: Dictionary = rs.call("pay_ability_costs", aid, rs.call("get_slot"))
		if not bool(pay.get("ok", false)):
			var fc3: int = _reduced_ctb_cost(true, "fizzle")
			print("[BC] Cost fail -> fizzle: aid=", aid, " cost=", fc3, " reason=", String(pay.get("reason","")))
			_play_sfx_key("fizzle.wav")
			emit_signal("turn_event", {"type":"item_use_fizzle","who":"player"})
			_in_resolution = true
			_consume_player_ctb(fc3)
			_in_resolution = false
			_apply_upkeep_and_emit("player")
			emit_signal("turn_event", Events.gauge_advanced(_player.id, fc3, int(round(_ctb_player.gauge))))
			emit_signal("turn_event", Events.turn_summary(_player.id, {}, 1))
			_round += 1
			_last_team_turn = &"player"
			return
		# SUCCESS → narrate the cost payment
		_emit_costs_paid_event(_player.id, pay)

	# Tally a use locally
	if _player != null and _player.has_method("skill_usage_add_use"):
		_player.call("skill_usage_add_use", aid)
		print("[BC] skill tally (use+1) ability=", aid)

	var eff_cost: int = _reduced_ctb_cost(true, aid)
	print("[BC] Player use: aid=", aid, " cost=", eff_cost)
	
	var targets: Array[int] = [_monster.id]
	if act.has("targets") and act["targets"] is Array:
		targets = act["targets"] as Array[int]
		
	_award_skill_usage_v2_for(aid, targets)

	var use: AbilityUse = AbilityUse.make(_player.id, targets, aid, _player.tags, float(eff_cost))
	var snaps: Array[ActorSnapshot] = _mk_snaps()
	var attacker_snap: ActorSnapshot = snaps[0]  # 0 = player, 1 = monster

	# Precheck (same rules kernel uses)
	var pre := PreUseRules.new()
	var pre_res: Dictionary = pre.validate_and_prepare(attacker_snap, use)

	if bool(pre_res.get("ok", false)):
		# Safe to announce & play SFX now
		_play_sfx_for(aid)

		# Tally only if it’s actually usable
		if _player != null and _player.has_method("skill_usage_add_use"):
			_player.call("skill_usage_add_use", aid)
			print("[BC] Player use: aid=", aid, " cost=", eff_cost)
	else:
		# Blocked: locked/cd/charges/MP/ST/weapon/etc → fizzle SFX (instant feedback)
		_play_sfx_key("fizzle.wav")
	_in_resolution = true
	var ar: ActionResult = _kernel.resolve(_mk_turn_ctx(), _mk_snaps(), use, _rng, _params) as ActionResult
	_dbg("KERNEL_RESULT", {"outcome": ar.outcome, "deltas": ar.deltas.size(), "events": ar.events.size()})
	_apply_result(ar)
	_consume_player_ctb(eff_cost)
	_in_resolution = false

	# Upkeep between turns
	_apply_upkeep_and_emit("player")

	emit_signal("turn_event", Events.gauge_advanced(_player.id, eff_cost, int(round(_ctb_player.gauge))))
	emit_signal("turn_event", Events.turn_summary(_player.id, {}, ar.events.size()))
	_round += 1
	_last_team_turn = &"player"

	var AS: Object = get_node_or_null(^"/root/AbilityService")
	if AS != null and AS.has_method("on_ability_used"):
		AS.call("on_ability_used", aid, "player")

# -------- Monster flow --------
func _monster_turn() -> void:
	var AI := load("res://scripts/combat/ai/MonsterAI.gd")
	var act: Dictionary = AI.new().pick_action(_monster, _player, _rng)

	var aid: String = String(act.get("ability_id", "arc_slash"))
	var targets: Array[int] = (act.get("targets", [_player.id]) as Array)

	var anim_key: String = ""
	if _monster != null and _monster.has_method("get_anim_key"):
		anim_key = _monster.get_anim_key(aid)
	if anim_key == "":
		var row_cat: Dictionary = AbilityCatalog.get_by_id(aid)
		anim_key = String(row_cat.get("animation_key", ""))

	if _anim_bridge != null and anim_key != "":
		print("[BC] Monster anim for ", aid, " -> ", anim_key)
		_anim_bridge.call_deferred("play_action", anim_key)
	else:
		print("[BC] No anim key for ", aid, " (bridge=", _anim_bridge != null, ")")
		
	print("[SFXDBG] Monster will play SFX for aid=", aid)
	_play_sfx_for(aid)

	var ctb_cost: int = _ctb_cost_for(aid)
	print("[BC] Monster use: aid=", aid, " cost=", ctb_cost)

	var use: AbilityUse = AbilityUse.make(_monster.id, targets, aid, _monster.tags, float(ctb_cost))
	_in_resolution = true
	var ar: ActionResult = _kernel.resolve(_mk_turn_ctx(), _mk_snaps(), use, _rng, _params) as ActionResult
	_dbg("KERNEL_RESULT", {"who":"monster", "outcome": ar.outcome, "deltas": ar.deltas.size(), "events": ar.events.size()})
	_apply_result(ar)
	_ctb_monster.consume(ctb_cost)
	_in_resolution = false

	# Upkeep between turns
	_apply_upkeep_and_emit("monster")

	emit_signal("turn_event", Events.gauge_advanced(_monster.id, ctb_cost, int(round(_ctb_monster.gauge))))
	emit_signal("turn_event", Events.turn_summary(_monster.id, {}, ar.events.size()))
	_last_team_turn = &"monster"

# -------- Helpers --------

# Reducer-driven result application.
# Order:
# 1) Emit events (UI/telemetry).
# 2) RuntimeReducer.apply(...) mutates runtimes + persists statuses + returns flags.
# 3) Play animation only if reducer detected actual monster damage.
func _apply_result(ar: ActionResult) -> void:
	# 1) Emit events (do NOT apply statuses here; reducer handles it)
	for e in ar.events:
		emit_signal("turn_event", e)

	# 2) Reduce into runtimes
	var flags := RuntimeReducer.apply(ar, _player, _monster)
	var monster_took_damage := bool(flags.get("monster_took_damage", false))
	var merged_any := bool(flags.get("merged_tallies", false))
	if merged_any:
		print("[BC] merged skill tallies (via reducer)")

	# 3) Animation: only when monster actually took damage
	if monster_took_damage:
		if _anim_bridge != null and _anim_bridge.has_method("play_hit"):
			print("[BC] Monster took damage → play_hit()")
			_anim_bridge.call_deferred("play_hit")
		elif _anim_bridge != null and _anim_bridge.has_method("play_player_hit"):
			print("[BC] Monster took damage → play_player_hit()")
			_anim_bridge.call_deferred("play_player_hit")

	emit_signal("hud_update", _snapshot())
	_check_battle_end()

func _apply_upkeep_and_emit(actor_side: String) -> void:
	# Build the pipeline instance (pure narration + cooldown deltas).
	var rtp: ResolveTurnPipeline = ResolveTurnPipeline.new()
	rtp.debug_upkeep = true

	# Build the live runtime list the pipeline expects.
	var all_runtimes: Array[Object] = []
	if _player != null:
		all_runtimes.append(_player)
	if _monster != null:
		all_runtimes.append(_monster)

	# Use _round as the upkeep tick marker for readable logs.
	var upkeep := rtp.apply_upkeep(_round, all_runtimes, _rng)

	# 1) Emit upkeep narration events BEFORE applying state changes.
	for e in upkeep.events:
		if e is Dictionary:
			print("[EVENT] ", JSON.stringify(e))
			turn_event.emit(e)

	# 2) Apply upkeep deltas via reducer (authoritative state mutation).
	var applied_delta_count: int = 0
	if upkeep.deltas is Array and upkeep.deltas.size() > 0:
		print("[BC] Applying upkeep deltas: ", upkeep.deltas.size())
		for d in upkeep.deltas:
			if d is Dictionary:
				var ar: ActionResult = ActionResult.ok_result("upkeep", [d], [])
				_apply_result(ar)
				applied_delta_count += 1

	# 3) REAL ticking/decay (mutating) using your static StatusEngine.
	var se_pack: Dictionary = StatusEngine.tick_all(_player, _monster)
	var real_events: Array = se_pack.get("events", [])
	var real_deltas: Array = se_pack.get("deltas", [])

	# Normalize engine events:
	# - Drop "status_expired" entirely (pipeline already narrated removal).
	# - Pass through status_tick (dot/hot) unchanged.
	for e2_untyped in real_events:
		if not (e2_untyped is Dictionary):
			continue
		var e2: Dictionary = e2_untyped
		var t: String = String(e2.get("type",""))

		if t == "status_expired":
			# No-op: ResolveTurnPipeline already emitted status_removed
			continue
		else:
			print("[EVENT] ", JSON.stringify(e2))
			turn_event.emit(e2)

	# Apply real deltas via reducer.
	for d2_untyped in real_deltas:
		if not (d2_untyped is Dictionary):
			continue
		var d2: Dictionary = d2_untyped
		var ar2: ActionResult = ActionResult.ok_result("upkeep", [d2], [])
		_apply_result(ar2)
		applied_delta_count += 1

	# 4) Refresh HUD and check for finish AFTER mutations.
	emit_signal("hud_update", _snapshot())
	_check_battle_end()

	print("[BC] Upkeep complete after %s turn; narr_events=%d, applied_deltas=%d"
		% [actor_side, int(upkeep.events.size() + real_events.size()), applied_delta_count])



func _emit_costs_paid_event(actor_id: int, pay: Dictionary) -> void:
	var mp: int = int(pay.get("mp", 0))
	var stam: int = int(pay.get("stam", 0))
	var charges: int = int(pay.get("charges", 0))
	var cooldown: int = int(pay.get("cooldown", 0))
	emit_signal("turn_event", Events.costs_paid(actor_id, mp, stam, charges, cooldown))

func _ctb_cost_for(ability_id: String) -> int:
	if ability_id == "fizzle" or ability_id == "":
		return 60
	return AbilityCatalog.ctb_cost(ability_id)

func _reduced_ctb_cost(actor_is_player: bool, ability_id: String) -> int:
	var base: float = float(_ctb_cost_for(ability_id))
	var pct: float = (float(_player.ctb_cost_reduction_pct) if actor_is_player else float(_monster.ctb_cost_reduction_pct))
	var mult: float = clamp(1.0 - pct * 0.01, 0.05, 4.0)

	const CTB_FLOOR_MULT := 0.55
	var scaled: float = base * mult
	var floored: float = base * CTB_FLOOR_MULT
	# floor instead of round — makes 104 * 0.96 => 99 (visible discount)
	var final_cost: int = max(1, int(max(floored, scaled)))

	_dbg("CTB_COST", {
		"ability": ability_id, "base": base,
		"pct_red": pct, "mult": mult,
		"floor_mult": CTB_FLOOR_MULT, "final": final_cost
	})
	return final_cost


func _consume_player_ctb(cost: int) -> void:
	if _ctb_player == null:
		return
	var c: int = max(1, int(cost))
	var g_before: float = _ctb_player.gauge

	_ctb_player.consume(c)

	var g_after: float = _ctb_player.gauge
	if is_equal_approx(g_before, g_after):
		var forced: float = max(0.0, g_before - float(c))
		_ctb_player.gauge = forced
		if forced < float(_params.gauge_size):
			_ctb_player.ready = false
		_dbg("CTB_FORCE_CONSUME", {"cost": c, "g_before": g_before, "g_after": _ctb_player.gauge, "ready": _ctb_player.ready})
	else:
		_dbg("CTB_CONSUME", {"cost": c, "g_before": g_before, "g_after": g_after, "ready": _ctb_player.ready})

func _snapshot() -> Dictionary:
	var m_name: String = ""
	var m_level: int = 0
	if _monster != null:
		# MonsterRuntime has these exported fields
		m_name = String(_monster.display_name)
		m_level = int(_monster.final_level)

	return {
		"player": {
			"hp": _player.hp, "hp_max": _player.hp_max,
			"mp": _player.mp, "mp_max": _player.mp_max,
			"stam": _player.stam, "stam_max": _player.stam_max
		},
		"monster": {
			"hp": _monster.hp, "hp_max": _monster.hp_max,
			"name": m_name, "level": m_level
		},
		"ctb": {
			"p": {"gauge": _ctb_player.gauge, "size": float(_params.gauge_size), "ready": _ctb_player.ready},
			"m": {"gauge": _ctb_monster.gauge, "size": float(_params.gauge_size), "ready": _ctb_monster.ready}
		}
	}

func _mk_turn_ctx() -> TurnContext:
	var ctb: Dictionary = {
		"p": {"ready": _ctb_player.ready, "gauge": _ctb_player.gauge},
		"m": {"ready": _ctb_monster.ready, "gauge": _ctb_monster.gauge}
	}
	var order: Array[int] = [_player.id, _monster.id]
	return TurnContext.from_ids("battle", "encounter", _battle_seed, _round, ctb, order)

func _mk_snaps() -> Array[ActorSnapshot]:
	return [ActorSnapshot.from_runtime(_player), ActorSnapshot.from_runtime(_monster)]

func _resolve_seed() -> int:
	var rs: Object = get_node_or_null(^"/root/RunState")
	if rs != null:
		var base: int = int(rs.get("run_seed"))
		return (base ^ 0xC0B47) + 17
	return randi()

func _check_battle_end() -> bool:
	if _finished_once:
		return true
	if _player.hp <= 0:
		_emit_finish("defeat")
		return true
	if _monster.hp <= 0:
		_emit_finish("victory")
		return true
	return false

func _emit_finish(outcome: String) -> void:
	if _finished_once:
		return
	_finished_once = true

	emit_signal("turn_event", Events.battle_end(outcome, _round))

	if _anim_bridge != null:
		if outcome == "victory":
			if _anim_bridge.has_method("play_die_and_hold"):
				print("[BC] outcome=victory -> play_die_and_hold on monster")
				_anim_bridge.call_deferred("play_die_and_hold")
		elif outcome == "defeat":
			if _anim_bridge.has_method("play_victory_and_hold"):
				print("[BC] outcome=defeat -> play_victory_and_hold on monster")
				_anim_bridge.call_deferred("play_victory_and_hold")
			elif _anim_bridge.has_method("play_victory"):
				print("[BC] outcome=defeat -> play_victory on monster (compat)")
				_anim_bridge.call_deferred("play_victory")
		elif outcome == "flee":
			if _anim_bridge.has_method("play_victory_and_hold"):
				print("[BC] outcome=flee -> play_victory_and_hold on monster")
				_anim_bridge.call_deferred("play_victory_and_hold")
			elif _anim_bridge.has_method("play_victory"):
				print("[BC] outcome=flee -> play_victory on monster")
				_anim_bridge.call_deferred("play_victory")

	# <<< add encounter_id so victory commit can find the bucket >>>
	var result: Dictionary = {
		"outcome": outcome,
		"player_hp": _player.hp,
		"player_mp": _player.mp,
		"encounter_id": _current_encounter_id()
	}
	emit_signal("battle_finished", result)
	set_process(false)


func _dbg(msg: String, data: Dictionary = {}) -> void:
	if debug_logs:
		print("[BC] ", msg, (("  " + str(data)) if not data.is_empty() else ""))

func _dbg_ctb_tick(delta: float, p_ready_now: bool, m_ready_now: bool) -> void:
	if not debug_logs:
		return
	_dbg_tick_accum += delta
	if _dbg_tick_accum >= debug_ctb_tick_log_interval or p_ready_now or m_ready_now:
		_dbg("CTB", {
			"p": {"g": _ctb_player.gauge, "ready": _ctb_player.ready},
			"m": {"g": _ctb_monster.gauge, "ready": _ctb_monster.ready}
		})
		_dbg_tick_accum = 0.0

# -------------------------
# New helpers for fair CTB
# -------------------------

func _time_to_ready(ctb: CTBModel) -> float:
	# Use CTBModel.time_to_ready() if you added it; otherwise compute here.
	if ctb.ready:
		return 0.0
	var rate: float = ctb.ctb_speed * ctb.fill_scale * maxf(0.0, ctb.speed_mult)
	if rate <= 0.0:
		return INF
	var need: float = float(ctb.gauge_size) - ctb.gauge
	if need <= 0.0:
		return 0.0
	return need / rate

func _pick_next_turn() -> StringName:
	# 1) Greater overflow wins
	var p_over: float = _ctb_player.gauge - float(_ctb_player.gauge_size)
	var m_over: float = _ctb_monster.gauge - float(_ctb_monster.gauge_size)
	if absf(p_over - m_over) > 0.0001:
		return &"player" if p_over > m_over else &"monster"

	# 2) Higher CTB speed wins
	var ps: float = float(_player.ctb_speed)
	var ms: float = float(_monster.ctb_speed)
	if absf(ps - ms) > 0.0001:
		return &"player" if ps > ms else &"monster"

	# 3) Alternate from last actor
	if _last_team_turn == &"player":
		return &"monster"
	if _last_team_turn == &"monster":
		return &"player"

	# 4) First tie → let monster go to prove the loop yields
	return &"monster"

# Ends the battle immediately without rewards (default outcome: "flee").
func force_finish_early(outcome: String = "flee") -> void:
	_emit_finish(outcome) # Reuses the built-in finish guard + cleanup

func _play_sfx_for(aid: String) -> void:
	var row_any: Variant = AbilityCatalog.get_by_id(aid)
	if typeof(row_any) != TYPE_DICTIONARY:
		print("[SFXDBG] AbilityCatalog row NOT FOUND for '", aid, "'")
		return
	var row: Dictionary = row_any
	var key: String = String(row.get("sound_key", ""))
	print("[SFXDBG] ability='", aid, "' sound_key='", key, "'")
	if key == "":
		print("[SFXDBG] Empty sound_key → skipping")
		return

	var svc := get_node_or_null(^"/root/CombatAudioService")
	if svc == null:
		print("[SFXDBG] CombatAudioService NOT found at /root — check Autoload name/path")
		return

	# Flip on service-side debug logging (safe even if already true)
	svc.set("debug_logs", true)
	print("[SFXDBG] Calling CombatAudioService.play_for_ability(aid='", aid, "')")
	svc.call("play_for_ability", aid, false)

func _play_sfx_key(key: String) -> void:
	var svc := get_node_or_null(^"/root/CombatAudioService")
	if svc != null:
		svc.call("play_key", key, false)

func _award_skill_usage_v2_for(aid: String, targets: Array[int]) -> void:
	# MVP: single-enemy battles — credit all player uses to enemy_index 0.
	if aid == "":
		return
	var enc_id: int = _current_encounter_id()
	if enc_id <= 0:
		return
	AbilityXPService.award_on_use_provisional(enc_id, aid, { "enemy_index": 0 })

func _current_encounter_id() -> int:
	# Try the router first
	var enc_id: int = 0
	var router := get_node_or_null(^"/root/EncounterRouter")
	if router != null:
		if router.has_method("get_current_encounter_id"):
			var v_any: Variant = router.call("get_current_encounter_id")
			if v_any is int: enc_id = int(v_any)
		elif router.has_method("peek_current_encounter_id"):
			var v2: Variant = router.call("peek_current_encounter_id")
			if v2 is int: enc_id = int(v2)

	# Fallback: derive a stable positive id from this battle's seed
	if enc_id <= 0:
		var n64: int = int(_battle_seed)
		var pos32: int = int(abs(n64)) % 2147483647
		enc_id = (pos32 if pos32 != 0 else 1)
	return enc_id
