# CombatTestController.gd — (keeps your existing battle loop + resolver)
class_name CombatTestController
extends Node

@onready var overlay: GestureOverlay = $CanvasLayer/GestureOverlay as GestureOverlay
@onready var recognized_label: Label = $CanvasLayer/HUD/VBox/Recognized as Label
@onready var player_hp_label: Label = $CanvasLayer/HUD/VBox/PlayerHP as Label
@onready var enemy_hp_label: Label = $CanvasLayer/HUD/VBox/EnemyHP as Label
@onready var turn_label: Label = $CanvasLayer/HUD/VBox/TurnOrder as Label
@onready var log_label: Label = $CanvasLayer/HUD/VBox/Log as Label

@export var confidence_threshold: float = 0.55
@export var loadout: Loadout
@export var enemy_def: EnemyDef
@export var player_stats: Stats
@export var enemy_stats: Stats

var q: CtbQueue
var player: CtbActor
var enemy: CtbActor
var _current: CtbActor
var _awaiting_player_input: bool = false
var _battle_over: bool = false

const LOG_MAX_LINES: int = 8
var _log_lines: Array[String] = []
var _skill_lv_by_action: Dictionary[StringName, int] = {}

func _ready() -> void:
	print("[CombatTest] READY")
	var canvas := get_node_or_null("CanvasLayer") as CanvasLayer
	if canvas:
		canvas.layer = 999
	overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP

	GestureRecognizer.ensure_initialized()
	overlay.submitted.connect(_on_overlay_submitted)
	overlay.cleared.connect(_on_overlay_cleared)
	overlay.stroke_updated.connect(_on_overlay_stroke_updated)

	recognized_label.text = "Recognized: —"
	log_label.text = ""
	_add_demo_buttons()

	if loadout == null:
		loadout = load("res://data/combat/loadouts/starter.tres") as Loadout
	if enemy_def == null:
		enemy_def = load("res://data/combat/enemies/skeleton.tres") as EnemyDef

	if player_stats == null:
		player_stats = Stats.new()
		player_stats.level = 2
		player_stats.endurance = 1
		player_stats.strength = 5
		player_stats.dexterity = 4
		player_stats.agility = 4
		player_stats.intelligence = 3
		player_stats.wisdom = 3
		player_stats.luck = 3

	if enemy_stats == null:
		enemy_stats = Stats.new()
		enemy_stats.level = 1
		enemy_stats.strength = 4
		enemy_stats.dexterity = 2
		enemy_stats.agility = 2
		enemy_stats.endurance = 2
		enemy_stats.intelligence = 1
		enemy_stats.wisdom = 1
		enemy_stats.luck = 2

	_start_battle()

# --- Battle bootstrap / loop (unchanged from our last version) --------------

func _start_battle() -> void:
	print("[CombatTest] Starting battle bootstrap.")
	q = CtbQueue.new()
	var p_hp: int = player_stats.hp_max()
	player = CtbActor.new(&"player", "Player", 10, p_hp, 0)

	var e_name: String
	var e_hp: int
	var e_spd: int
	if enemy_def != null:
		e_name = enemy_def.display_name
		e_hp = enemy_def.hp_max
		e_spd = enemy_def.speed
	else:
		e_name = "Enemy"; e_hp = 20; e_spd = 8
	enemy = CtbActor.new(&"enemy", e_name, e_spd, e_hp, 0)

	q.add_actor(player)
	q.add_actor(enemy)
	_battle_over = false
	_advance_to_next_turn()

func _advance_to_next_turn() -> void:
	if _battle_over:
		return
	var safety := 16
	while safety > 0:
		safety -= 1
		_current = q.pop_next()
		_refresh_hud()

		if _current == player:
			_awaiting_player_input = true
			overlay.mouse_filter = Control.MOUSE_FILTER_STOP
			_log("Your turn — draw a gesture and Submit.")
			_refresh_turn_strip()
			return
		else:
			overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_enemy_take_turn()
			if _check_end(): return
			_refresh_hud()
	print("[CombatTest] WARNING: safety exhausted.")

# --- Input / preview --------------------------------------------------------

func _on_overlay_stroke_updated(points: Array[Vector2]) -> void:
	if points.size() < 10:
		recognized_label.text = "Recognized: —"
		return

	var res: Dictionary = GestureRecognizer.recognize(points)
	var id: StringName = res["id"]
	var conf: float = res["confidence"]
	var passes: bool = GestureRecognizer.passes_symbol_filters(id, points)
	var ok: bool = (conf >= confidence_threshold) and passes

	if String(id).is_empty():
		recognized_label.text = "Recognized: —"
	else:
		recognized_label.text = "Recognized: %s (%.2f) [%s]" % [String(id), conf, ( "OK" if ok else "fail" )]


func _on_overlay_cleared() -> void:
	recognized_label.text = "Recognized: —"

# --- Player action ----------------------------------------------------------

func _on_overlay_submitted(points: Array[Vector2]) -> void:
	if _battle_over or not _awaiting_player_input:
		return

	var res: Dictionary = GestureRecognizer.recognize(points)
	var gid: StringName = res["id"]
	var conf: float = res["confidence"]
	var passes: bool = GestureRecognizer.passes_symbol_filters(gid, points)
	print("[Recognize] id=%s conf=%.2f passes=%s" % [String(gid), conf, str(passes)])


	var action_id: StringName = loadout.fallback_id
	if conf >= confidence_threshold and not String(gid).is_empty() and GestureRecognizer.passes_symbol_filters(gid, points):
		action_id = loadout.action_id_for_gesture(gid)

	var act: ActionDef = CombatDB.get_action(action_id)
	if act == null:
		_log("Unknown action '%s' — fizzle.".format([String(action_id)]))
		overlay.clear_stroke()
		return

	_awaiting_player_input = false
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_resolve_player_action(act)

	var ctb_cost: int = ActionResolver.compute_ctb(player.speed, act.ctb_cost, 1, 1.0)
	q.schedule(player, ctb_cost)
	overlay.clear_stroke()

	if _check_end(): return
	_refresh_hud()
	_advance_to_next_turn()

# --- Resolver-backed action handling (same as your current version) ---------
func _resolve_player_action(act: ActionDef) -> void:
	var skill_lv: int = _skill_lv_by_action.get(act.id, 1)
	match act.kind:
		&"attack":
			var hit: ActionResolver.HitResult = ActionResolver.roll_to_hit(player_stats, enemy_stats, act.to_hit, act.school, act.crit_allowed)
			var dmg: int = ActionResolver.compute_damage(player_stats, enemy_stats, act.base_power, act.school, act.crit_allowed, hit, skill_lv)
			if enemy.guard:
				dmg = int(round(float(dmg) * 0.5))
				enemy.guard = false
			_damage_enemy(dmg)
			if not hit.hit:
				_log("Player: %s → miss" % [act.display_name])
			else:
				var tag := " (CRIT!)" if hit.crit else ""
				_log("Player: %s → %d dmg%s" % [act.display_name, dmg, tag])
		&"heal":
			var heal_amt: int = ActionResolver.compute_heal(player_stats, act.base_power, act.school, skill_lv)
			_heal_actor(player, heal_amt)
			_log("Player: %s → +%d HP" % [act.display_name, heal_amt])
		&"block":
			player.guard = true
			_log("Player: %s → Guard up" % [act.display_name])
		_:
			_log("Player: Gesture fizzles (CTB %d)" % [act.ctb_cost])

# --- Enemy turn (unchanged from your last patched version) ------------------
func _enemy_take_turn() -> void:
	var intent_id: StringName = StringName("")
	if enemy_def != null:
		intent_id = CombatDB.pick_weighted_ids(enemy_def.intent_ids, enemy_def.intent_weights)
	var intent: IntentDef = CombatDB.get_intent(intent_id)

	if intent == null:
		var cost: int = 100
		var base_dmg: int = 5
		var dmg_fb: int = base_dmg
		if player.guard:
			dmg_fb = int(round(float(base_dmg) * 0.5))
			player.guard = false
		_damage_player(dmg_fb)
		_log("%s: Swipe → %d dmg" % [enemy.name, dmg_fb])
		q.schedule(enemy, cost)
		return

	match intent.kind:
		&"attack":
			var hit: ActionResolver.HitResult = ActionResolver.roll_to_hit(enemy_stats, player_stats, intent.to_hit, intent.school, intent.crit_allowed)
			var dmg: int = ActionResolver.compute_damage(enemy_stats, player_stats, intent.base_power, intent.school, intent.crit_allowed, hit, 1)
			if player.guard:
				dmg = int(round(float(dmg) * 0.5))
				player.guard = false
			_damage_player(dmg)
			if not hit.hit:
				_log("%s: %s → miss" % [enemy.name, intent.display_name])
			else:
				var tag := " (CRIT!)" if hit.crit else ""
				_log("%s: %s → %d dmg%s" % [enemy.name, intent.display_name, dmg, tag])
		&"guard":
			enemy.guard = true
			_log("%s: %s → Guard up" % [enemy.name, intent.display_name])
		&"heal":
			var heal_amt: int = ActionResolver.compute_heal(enemy_stats, intent.base_power, intent.school, 1)
			_heal_enemy(heal_amt)
			_log("%s: %s → +%d HP" % [enemy.name, intent.display_name, heal_amt])
		_:
			_log("%s hesitates…" % [enemy.name])

	var ctb_cost: int = ActionResolver.compute_ctb(enemy.speed, intent.ctb_cost, 1, 1.0)
	q.schedule(enemy, ctb_cost)

# --- HP / end / HUD ---------------------------------------------------------
func _damage_enemy(amount: int) -> void:
	enemy.hp = max(0, enemy.hp - max(0, amount))

func _damage_player(amount: int) -> void:
	player.hp = max(0, player.hp - max(0, amount))

func _heal_actor(a: CtbActor, amount: int) -> void:
	a.hp = min(a.hp_max, a.hp + max(0, amount))

func _heal_enemy(amount: int) -> void:
	enemy.hp = min(enemy.hp_max, enemy.hp + max(0, amount))

func _check_end() -> bool:
	if enemy.hp <= 0:
		_battle_over = true
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_log("Victory!")
		_refresh_hud()
		return true
	if player.hp <= 0:
		_battle_over = true
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_log("Defeat...")
		_refresh_hud()
		return true
	return false

func _refresh_hud() -> void:
	player_hp_label.text = "Player HP: %d / %d" % [player.hp, player.hp_max]
	enemy_hp_label.text  = "%s HP: %d / %d" % [enemy.name, enemy.hp, enemy.hp_max]
	_refresh_turn_strip()

func _refresh_turn_strip() -> void:
	var now_name: String = (_current.name if _current != null else "-")
	var list: Array[CtbActor] = q.peek_next(6, _current)
	var next_names: Array[String] = []
	for a in list:
		next_names.append(a.name)
	var next_str := ""
	for i in range(next_names.size()):
		if i > 0: next_str += ", "
		next_str += next_names[i]
	turn_label.text = "Now: %s    Next: %s" % [now_name, next_str]

# --- Tiny logger ------------------------------------------------------------
func _log(msg: String) -> void:
	_log_lines.append(msg)
	if _log_lines.size() > LOG_MAX_LINES:
		_log_lines = _log_lines.slice(_log_lines.size() - LOG_MAX_LINES, LOG_MAX_LINES)
	log_label.text = "\n".join(_log_lines)

# --- Demo buttons & strokes (∧ / ▲ / — / |) --------------------------------
func _add_demo_buttons() -> void:
	var vbox := $CanvasLayer/HUD/VBox as VBoxContainer
	var row := HBoxContainer.new()
	row.name = "DemoButtons"
	row.modulate = Color(1, 1, 1, 0.9)
	row.add_theme_constant_override("separation", 6)

	_add_demo_button(row, "Slash —", &"slash")
	_add_demo_button(row, "Block |", &"block")
	_add_demo_button(row, "Heal ∧", &"heal_caret")
	_add_demo_button(row, "Fire ▲", &"fire_triangle")
	_add_demo_button(row, "Aimed >", &"aimed")
	_add_demo_button(row, "Riposte ✓", &"riposte")
	_add_demo_button(row, "Clear", &"clear")

	vbox.add_child(row)


func _add_demo_button(parent: HBoxContainer, label: String, which: StringName) -> void:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(0, 24)
	b.pressed.connect(func() -> void:
		match which:
			&"clear":
				overlay.clear_stroke()
			_:
				var unit: Array[Vector2] = _make_demo_points(which)
				var pts: Array[Vector2] = _to_overlay_space(unit)
				overlay.show_demo(pts, false)
	)
	parent.add_child(b)

func _to_overlay_space(unit: Array[Vector2]) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var margin := Vector2(24, 110)
	var size := overlay.size - margin * 2.0
	for p in unit:
		out.append(margin + Vector2(p.x * size.x, p.y * size.y))
	return out

func _interp_unit(anchors: Array[Vector2], sub: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if anchors.is_empty():
		return out
	for i in range(anchors.size() - 1):
		var a := anchors[i]
		var b := anchors[i + 1]
		out.append(a)
		for s in range(1, sub):
			var t := float(s) / float(sub)
			out.append(a.lerp(b, t))
	out.append(anchors[anchors.size() - 1])
	return out

func _make_demo_points(which: StringName) -> Array[Vector2]:
	if which == &"slash":
		return _interp_unit([Vector2(0.08, 0.55), Vector2(0.92, 0.55)], 28)
	if which == &"block":
		return _interp_unit([Vector2(0.52, 0.14), Vector2(0.52, 0.90)], 28)
	if which == &"heal_caret":
		return _interp_unit([Vector2(0.25, 0.80), Vector2(0.50, 0.30), Vector2(0.75, 0.80)], 14)
	if which == &"fire_triangle":
		return _interp_unit([Vector2(0.30, 0.80), Vector2(0.70, 0.80), Vector2(0.50, 0.35), Vector2(0.30, 0.80)], 10)
	if which == &"aimed":
		# Right-pointing chevron: up-right to rightmost apex, then down-left
		return _interp_unit([
			Vector2(0.28, 0.46),  # start left/top-ish
			Vector2(0.74, 0.54),  # apex (rightmost)
			Vector2(0.28, 0.72)   # end left/bottom-ish
		], 16)

	if which == &"riposte":
		# short down-right then long up-right
		return _interp_unit([
			Vector2(0.30, 0.55), Vector2(0.40, 0.65), Vector2(0.80, 0.30)
		], 16)
	return [Vector2(0.5, 0.5)]
