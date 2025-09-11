extends Node
class_name BattleController

# ---- Tuning / debug ----
@export var confidence_threshold: float = 0.60
@export var debug_logging: bool = true
@export var strict_validate: bool = true
@export var max_log_lines: int = 8

# ---- HUD nodes ----
@onready var overlay: Control              = $CanvasLayer/GestureOverlay as Control
@onready var recognized_label: Label       = $CanvasLayer/HUD/VBox/Recognized as Label
@onready var player_hp_label: Label        = $CanvasLayer/HUD/VBox/PlayerHP as Label
@onready var enemy_hp_label: Label         = $CanvasLayer/HUD/VBox/EnemyHP as Label
@onready var turn_label: Label             = $CanvasLayer/HUD/VBox/TurnOrder as Label
@onready var log_label: Label              = $CanvasLayer/HUD/VBox/Log as Label
@onready var _gesture_overlay: Node        = $CanvasLayer/GestureOverlay

# ---- Data / stats ----
const ActionResolver = preload("res://scripts/combat/ActionResolver.gd")
const Stats          = preload("res://scripts/data/Stats.gd")
const ActionDef      = preload("res://scripts/data/ActionDef.gd")
const FIZZLE_CTB_BASE: int = 120  # tune here (100–120 feels fair)
var _advancing: bool = false       # reentry guard for _advance_to_next_turn()

@export var player_stats: Stats
@export var enemy_stats: Stats  # will be copied from EnemyDef.base_stats when encounter starts

# ---- Runtime state ----
var q: CtbQueue
var player: CtbActor
var enemy: CtbActor
var enemy_def: EnemyDef = null
var _battle_over: bool = false
var _log_lines: Array[String] = []
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

# ---- Utility ----
func _dbg(msg: String) -> void:
	if debug_logging:
		print("[Battle] ", msg)

# Public entry
func begin(payload: Dictionary) -> void:
	_ready_bootstrap(payload)

func _ready() -> void:
	if not Engine.is_editor_hint():
		_ready_bootstrap({})

func _ready_bootstrap(payload: Dictionary) -> void:
	# Ensure recognizer templates exist
	GestureRecognizer._init_default_templates()
	_rng.randomize()
	_dbg("Recognizer templates initialized.")
	_dbg("READY bootstrap. confidence_threshold=%.2f" % confidence_threshold)

	recognized_label.text = "Recognized: —"
	_log_lines.clear()

	_connect_overlay()
	_start_battle(payload)

func _connect_overlay() -> void:
	if overlay.has_signal("stroke_updated"):
		overlay.connect("stroke_updated", Callable(self, "_on_overlay_stroke_updated"))
	if overlay.has_signal("submitted"):
		overlay.connect("submitted", Callable(self, "_on_overlay_submitted"))
	if overlay.has_signal("cleared"):
		overlay.connect("cleared", Callable(self, "_on_overlay_cleared"))
	_dbg("Overlay signals connected? stroke_updated=%s submitted=%s cleared=%s"
		% [str(overlay.has_signal("stroke_updated")), str(overlay.has_signal("submitted")), str(overlay.has_signal("cleared"))])

func _on_overlay_cleared() -> void:
	recognized_label.text = "Recognized: —"
	_dbg("Overlay cleared.")

# ---- Encounter bootstrap ----
func _start_battle(payload: Dictionary) -> void:
	q = CtbQueue.new()

	# Create actors with placeholder pools; we'll seed from Stats next
	player = CtbActor.new(&"player", "Player", 10, 30, 0)
	var enemy_id: StringName = StringName(payload.get("enemy", "skeleton"))
	enemy_def = CombatDB.get_enemy(enemy_id)
	var e_name: String = (enemy_def.display_name if enemy_def != null else "Skeleton")
	enemy = CtbActor.new(enemy_id, e_name, 8, 25, 0)

	# Validate & bind stats; seed HP from Stats
	_bind_stats_and_seed_pools()
	_dump_stats("PLAYER", player_stats)
	_dump_stats("ENEMY", enemy_stats)

	q.add_actor(player)
	q.add_actor(enemy)
	_battle_over = false

	_refresh_hud()
	_log("Encounter started vs %s." % enemy.name)
	_dbg("Start battle: enemy_id=%s name=%s hp=%d/%d" % [String(enemy_id), enemy.name, enemy.hp, enemy.hp_max])

	_advance_to_next_turn()

func _bind_stats_and_seed_pools() -> void:
	# Player Stats: allow default if not provided (for quick tests)
	if player_stats == null:
		player_stats = Stats.new()

	# EnemyDef must be present
	if enemy_def == null:
		_fail_setup("EnemyDef missing."); return
	if enemy_def.base_stats == null:
		_fail_setup("EnemyDef.base_stats missing for %s" % [enemy_def.display_name]); return

	# Copy enemy stats from resource so runtime changes don't mutate the asset
	enemy_stats = enemy_def.base_stats.copy()

	# Seed combat HP pools from derived max_hp()
	var pmax: int = player_stats.max_hp()
	var emax: int = enemy_stats.max_hp()
	player.hp_max = pmax
	player.hp = pmax
	enemy.hp_max = emax
	enemy.hp = emax
	_refresh_hud()

func _fail_setup(msg: String) -> void:
	push_error("[CombatSetup] " + msg)
	_log("[ERROR] " + msg)
	EncounterRouter.finish_encounter({ "result": "error", "reason": msg })
	queue_free()

# ---- Turn loop ----
func _advance_to_next_turn() -> void:
	if _battle_over:
		return

	var now: CtbActor = q.pop_next()
	_dbg("Advance turn: popped=%s" % (now.name if now != null else "null"))
	if now == null:
		return

	if now == player:
		overlay.mouse_filter = Control.MOUSE_FILTER_STOP
		_reset_turn_log()  # soft trim (rolling log)
		_log("Your turn — draw a gesture and Submit.")
	else:
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_enemy_take_turn()

	_refresh_turn_strip(now)

# ---- Overlay input ----
func _on_overlay_stroke_updated(points: Array[Vector2]) -> void:
	if points.size() < 10:
		recognized_label.text = "Recognized: —"
		return

	var res: Dictionary = GestureRecognizer.recognize(points)
	var id: StringName = StringName(res.get("id", StringName("")))
	var conf: float = float(res.get("confidence", 0.0))
	var passes: bool = GestureRecognizer.passes_symbol_filters(id, points)
	var ok: bool = (String(id) != "") and (conf >= confidence_threshold) and passes

	if String(id) == "":
		recognized_label.text = "Recognized: —"
	else:
		recognized_label.text = "Recognized: %s (%.2f) [%s]" % [String(id), conf, ("OK" if ok else "fail")]
	_dbg("stroke_updated: id=%s conf=%.2f pass=%s (threshold=%.2f)"
		% [String(id), conf, str(passes), confidence_threshold])

func _on_overlay_submitted(points: Array[Vector2]) -> void:
	if _battle_over:
		return

	_dbg("SUBMIT: points=%d" % points.size())
	var res: Dictionary = GestureRecognizer.recognize(points)
	var gid: StringName = StringName(res.get("id", StringName("")))
	var conf: float = float(res.get("confidence", 0.0))
	var passes: bool = GestureRecognizer.passes_symbol_filters(gid, points)
	var ok: bool = (String(gid) != "") and (conf >= confidence_threshold) and passes
	_dbg("submit recognize: id=%s conf=%.2f passes=%s ok=%s"
		% [String(gid), conf, str(passes), str(ok)])

	if not ok:
		var fizzle_cost: int = ActionResolver.compute_ctb(player_stats.speed(), FIZZLE_CTB_BASE, 1)
		_damage_enemy(1)
		_log("Player: Fizzle → 1 dmg.")
		_dbg("FIZZLE → chip dmg 1; schedule CTB=120")
		q.schedule(player, fizzle_cost)
		_clear_symbols_and_recognized()
		_check_end()
		_advance_to_next_turn()
		return

	var act: ActionDef = CombatDB.get_action(gid)
	_dbg("Action lookup: id=%s found=%s" % [String(gid), str(act != null)])
	if act == null:
		var keys_any: Array = CombatDB.actions.keys()
		var ids: Array[String] = []
		for k in keys_any:
			ids.append(String(k))
		_dbg("Unknown action id=%s. Known actions: %s" % [String(gid), ", ".join(ids)])
		var unknown_cost: int = ActionResolver.compute_ctb(player_stats.speed(), 100, 1)
		_log("Player: Unknown action.")
		_dbg("Unknown action; schedule CTB=100")
		q.schedule(player, unknown_cost)
		_clear_symbols_and_recognized()
		_advance_to_next_turn()
		return

	_resolve_player_action(act)
	_check_end()
	_advance_to_next_turn()

# ---- Player & Enemy resolution ----
func _resolve_player_action(act: ActionDef) -> void:
	var skill_lv: int = 1
	var cost: int = ActionResolver.compute_ctb(player_stats.speed(), max(1, act.ctb_cost), skill_lv)

	match act.kind:
		&"heal":
			var amt: int = ActionResolver.compute_heal(player_stats, act.base_power, act.school, skill_lv)
			_heal_actor(player, amt)
			_log("Player: %s (CTB %d) → +%d HP." % [String(act.display_name), cost, amt])
			_dbg("HEAL +%d; schedule CTB=%d" % [amt, cost])
			q.schedule(player, cost)

		&"guard", &"block":
			player.guard = true
			_log("Player: %s (CTB %d) → Guard up." % [String(act.display_name), cost])
			_dbg("GUARD; schedule CTB=%d" % [cost])
			q.schedule(player, cost)

		_:
			var hit: Object = ActionResolver.roll_to_hit(player_stats, enemy_stats, act.to_hit, act.school, act.crit_allowed)
			var ab_p: int = player_stats.accuracy_bonus(act.school)
			_dbg("P action=%s school=%s  CTB base=%d→%d  roll=%d vs AC=%d  hit=%s crit=%s  AB=%d  ENEMY(def=%d,res=%d)"
				% [String(act.display_name), String(act.school), act.ctb_cost, cost,
				   hit.roll, enemy_stats.ac(),
				   str(hit.hit), str(hit.crit), ab_p, enemy_stats.phys_def(), enemy_stats.mag_res()])
			
			var dmg: int = ActionResolver.compute_damage(
				player_stats,
				enemy_stats,
				act.base_power,
				act.school,
				act.crit_allowed,
				hit,
				skill_lv
			)
			if enemy.guard and dmg > 0:
				dmg = int(round(float(dmg) * 0.5))
				enemy.guard = false

			if dmg <= 0:
				_log("Player: %s (CTB %d) → MISS." % [String(act.display_name), cost])
				_dbg("MISS; schedule CTB=%d" % [cost])
			else:
				_damage_enemy(dmg)
				_log("Player: %s (CTB %d) → %d dmg." % [String(act.display_name), cost, dmg])
				_dbg("ATTACK %d dmg; schedule CTB=%d" % [dmg, cost])

			q.schedule(player, cost)

	_clear_symbols_and_recognized()

func _enemy_take_turn() -> void:
	var cost: int = 100
	var skill_lv: int = 1

	if enemy_def != null and enemy_def.intent_ids.size() > 0:
		var intent_id: StringName = CombatDB.pick_weighted_ids(enemy_def.intent_ids, enemy_def.intent_weights)
		var intent: IntentDef = CombatDB.get_intent(intent_id)
		if intent != null:
			cost = ActionResolver.compute_ctb(enemy_stats.speed(), max(1, intent.ctb_cost), skill_lv)

			match intent.kind:
				&"attack":
					var hit: Object = ActionResolver.roll_to_hit(enemy_stats, player_stats, intent.to_hit, intent.school, intent.crit_allowed)
					var ab_e: int = enemy_stats.accuracy_bonus(intent.school)
					_dbg("E intent=%s school=%s  CTB base=%d→%d  roll=%d vs AC=%d  hit=%s crit=%s  AB=%d  PLAYER(def=%d,res=%d)"
						% [String(intent.display_name), String(intent.school), intent.ctb_cost, cost,
						   hit.roll, player_stats.ac(),
						   str(hit.hit), str(hit.crit), ab_e, player_stats.phys_def(), player_stats.mag_res()])
					var dmg: int = ActionResolver.compute_damage(
						enemy_stats,
						player_stats,
						intent.power,
						intent.school,
						intent.crit_allowed,
						hit,
						skill_lv
					)
					if player.guard and dmg > 0:
						dmg = int(round(float(dmg) * 0.5))
						player.guard = false

					if dmg <= 0:
						_log("%s: %s → MISS." % [String(enemy.name), String(intent.display_name)])
						_dbg("ENEMY MISS; schedule CTB=%d" % [cost])
					else:
						_damage_player(dmg)
						_log("%s: %s → %d dmg." % [String(enemy.name), String(intent.display_name), dmg])
						_dbg("ENEMY ATTACK %d dmg; schedule CTB=%d" % [dmg, cost])

				&"heal":
					var amt: int = ActionResolver.compute_heal(enemy_stats, intent.power, intent.school, skill_lv)
					_heal_actor(enemy, amt)
					_log("%s: %s → +%d HP." % [String(enemy.name), String(intent.display_name), amt])
					_dbg("ENEMY HEAL +%d; schedule CTB=%d" % [amt, cost])

				&"guard":
					enemy.guard = true
					_log("%s: %s." % [String(enemy.name), String(intent.display_name)])
					_dbg("ENEMY GUARD; schedule CTB=%d" % [cost])

				&"delay":
					_log("%s: %s (charging…)."% [String(enemy.name), String(intent.display_name)])
					_dbg("ENEMY DELAY; schedule CTB=%d" % [cost])

				_:
					var fdmg: int = 5
					if player.guard:
						fdmg = int(round(float(fdmg) * 0.5))
						player.guard = false
					_damage_player(fdmg)
					_log("%s: Strike → %d dmg." % [String(enemy.name), fdmg])
					_dbg("ENEMY FALLBACK %d dmg; schedule CTB=%d" % [fdmg, cost])
		else:
			var fdmg2: int = 5
			if player.guard:
				fdmg2 = int(round(float(fdmg2) * 0.5))
				player.guard = false
			_damage_player(fdmg2)
			_log("%s: Strike → %d dmg." % [String(enemy.name), fdmg2])
			_dbg("ENEMY NO-INTENT FALLBACK %d dmg; schedule CTB=%d" % [fdmg2, cost])
	else:
		var fdmg3: int = 5
		if player.guard:
			fdmg3 = int(round(float(fdmg3) * 0.5))
			player.guard = false
		_damage_player(fdmg3)
		_log("%s: Chomp → %d dmg." % [String(enemy.name), fdmg3])
		_dbg("ENEMY NO-INTENTS FALLBACK %d dmg; schedule CTB=%d" % [fdmg3, cost])

	q.schedule(enemy, cost)
	_clear_symbols_and_recognized()
	_check_end()
	_advance_to_next_turn()

# ---- HP / HUD helpers ----
func _damage_enemy(amount: int) -> void:
	var before: int = enemy.hp
	enemy.hp = clampi(enemy.hp - max(0, amount), 0, enemy.hp_max)
	_refresh_hud()
	_dbg("Damage enemy: %d -> %d (-%d)" % [before, enemy.hp, amount])

func _damage_player(amount: int) -> void:
	var before: int = player.hp
	player.hp = clampi(player.hp - max(0, amount), 0, player.hp_max)
	_refresh_hud()
	_dbg("Damage player: %d -> %d (-%d)" % [before, player.hp, amount])

func _heal_actor(target: CtbActor, amount: int) -> void:
	var before: int = target.hp
	target.hp = clampi(target.hp + max(0, amount), 0, target.hp_max)
	_refresh_hud()
	_dbg("Heal %s: %d -> %d (+%d)" % [target.name, before, target.hp, amount])

func _check_end() -> void:
	if enemy.hp <= 0:
		_battle_over = true
		_log("Victory!")
		_dbg("Finish encounter: victory")
		EncounterRouter.finish_encounter({ "result": "victory" })
	elif player.hp <= 0:
		_battle_over = true
		_log("Defeat…")
		_dbg("Finish encounter: defeat")
		EncounterRouter.finish_encounter({ "result": "defeat" })

func _refresh_hud() -> void:
	player_hp_label.text = "Player HP: %d / %d" % [player.hp, player.hp_max]
	enemy_hp_label.text = "%s HP: %d / %d" % [enemy.name, enemy.hp, enemy.hp_max]

func _refresh_turn_strip(current: CtbActor) -> void:
	var now_name: String = (current.name if current != null else "-")
	var list_any: Array = q.peek_next(6, current)  # unknown static type from queue; cast below
	var list: Array[CtbActor] = []
	for i in list_any:
		list.append(i as CtbActor)

	var next_names: Array[String] = []
	for a in list:
		next_names.append(a.name)
	turn_label.text = "Now: %s    Next: %s" % [now_name, ", ".join(next_names)]
	_dbg("Turn strip: now=%s next=[%s]" % [now_name, ", ".join(next_names)])

# ---- Logging & UI reset ----
func _log(line: String) -> void:
	_log_lines.append(line)
	var overflow: int = _log_lines.size() - max_log_lines
	if overflow > 0:
		_log_lines = _log_lines.slice(overflow, _log_lines.size())
	log_label.text = "\n".join(_log_lines)

func _reset_turn_log() -> void:
	if _log_lines.size() > max_log_lines:
		_log_lines = _log_lines.slice(_log_lines.size() - max_log_lines, _log_lines.size())
		log_label.text = "\n".join(_log_lines)
	# else keep prior lines visible

func _clear_symbols_and_recognized() -> void:
	if is_instance_valid(_gesture_overlay) and _gesture_overlay.has_method("clear_stroke"):
		_gesture_overlay.call("clear_stroke")
	if is_instance_valid(recognized_label):
		recognized_label.text = ""

func _dump_stats(tag: String, s: Stats) -> void:
	if not debug_logging: return
	_dbg("%s STATS  L=%d  HPmax=%d  SPD=%d  AC=%d  DEF=%d  RES=%d  AB[pwr]=%d  AB[fin]=%d  AB[arc]=%d  AB[div]=%d  Crit%%=%.1f  Crit×=%.2f"
		% [tag,
		   s.level, s.max_hp(), s.speed(), s.ac(), s.phys_def(), s.mag_res(),
		   s.accuracy_bonus(&"power"), s.accuracy_bonus(&"finesse"),
		   s.accuracy_bonus(&"arcane"), s.accuracy_bonus(&"divine"),
		   s.crit_chance() * 100.0, s.crit_mult()])
