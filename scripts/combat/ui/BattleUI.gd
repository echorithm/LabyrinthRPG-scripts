extends CanvasLayer
class_name BattleUI

@export var confidence_threshold: float = 0.60

var controller: BattleController
var overlay: GestureOverlay
var hud: BattleHUD
var feed: ActionFeed

var _cleared_for_this_turn: bool = false

func _ready() -> void:
	layer = 80

	var root := Control.new()
	root.name = "BattleUIRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	hud = BattleHUD.new()
	hud.name = "BattleHUD"
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.offset_top = 8
	hud.offset_left = 8
	hud.offset_right = -8
	root.add_child(hud)

	feed = ActionFeed.new()
	feed.name = "ActionFeed"
	feed.anchor_left = 0.0
	feed.anchor_right = 1.0
	feed.anchor_top = 0.0
	feed.anchor_bottom = 1.0
	feed.offset_left = 8
	feed.offset_right = -8
	feed.offset_top = 140
	feed.offset_bottom = -8
	add_child(feed) # keep feed above dungeon HUD but below overlay

	overlay = GestureOverlay.new()
	overlay.name = "GestureOverlay"
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.visible = false
	add_child(overlay)

	overlay.submitted.connect(_on_overlay_submitted)
	overlay.cleared.connect(_on_overlay_cleared)
	overlay.stroke_updated.connect(_on_overlay_stroke_updated)

	GestureRecognizer.ensure_initialized()

	# Start with an initial window so pre-player events show.
	if feed != null:
		feed.begin_new_window()
		print("[Feed] New window (startup)")

	_post_assign_controller()

func set_controller(c: BattleController) -> void:
	controller = c
	_post_assign_controller()

func _post_assign_controller() -> void:
	if controller == null:
		return

	# Connect (idempotent)
	if not controller.is_connected("player_turn_ready", Callable(self, "_on_player_turn_ready")):
		controller.player_turn_ready.connect(_on_player_turn_ready)
	if not controller.is_connected("turn_event", Callable(self, "_on_turn_event")):
		controller.turn_event.connect(_on_turn_event)
	if not controller.is_connected("hud_update", Callable(self, "_on_hud_update")):
		controller.hud_update.connect(_on_hud_update)
	if not controller.is_connected("battle_finished", Callable(self, "_on_battle_finished")):
		controller.battle_finished.connect(_on_battle_finished)

	controller.auto_player = false
	controller.auto_monster = true

	# --- Late attach fix: if the controller already entered PLAYER_TURN,
	# the original signal was missed; re-show the overlay immediately.
	if controller.has_method("is_waiting_for_player"):
		var waiting: bool = controller.is_waiting_for_player()
		print("[UI] attach: controller waiting_for_player=%s" % [str(waiting)])
		if waiting:
			_on_player_turn_ready()

func _on_player_turn_ready() -> void:
	# Show overlay but DO NOT clear feed yet.
	_cleared_for_this_turn = false
	print("[UI] PlayerTurn: overlay shown (waiting for first stroke to clear)")
	if overlay != null:
		overlay.visible = true
		overlay.mouse_filter = Control.MOUSE_FILTER_STOP

func _on_overlay_stroke_updated(_points: Array[Vector2]) -> void:
	# First stroke during this turn => clear feed NOW.
	if not _cleared_for_this_turn:
		if feed != null:
			feed.begin_new_window()
			print("[Feed] New window (on gesture begin)")
		_cleared_for_this_turn = true

func _on_overlay_submitted(points: Array[Vector2]) -> void:
	if controller == null or overlay == null:
		return

	var res: Dictionary = GestureRecognizer.recognize(points)
	var gid: StringName = StringName(res.get("id", StringName("")))
	var conf: float = float(res.get("confidence", 0.0))
	var passes: bool = GestureRecognizer.passes_symbol_filters(gid, points)
	var ok: bool = (String(gid) != "") and (conf >= confidence_threshold) and passes

	var action_id: StringName = &"fizzle"
	match gid:
		&"slash":
			action_id = &"basic_attack"
		&"block":
			action_id = &"guard"
		_:
			action_id = &"fizzle"

	print("[UI] Gesture submitted id=%s conf=%.2f passes=%s -> action=%s"
		% [String(gid), conf, str(passes), String(action_id)])

	controller.commit_player_action(action_id, {
		"gesture_id": String(gid),
		"confidence": conf
	})

	overlay.clear_stroke()
	overlay.visible = false

func _on_overlay_cleared() -> void:
	pass

func _on_turn_event(ev: Dictionary) -> void:
	if feed != null:
		feed.append_event(ev)

func _on_hud_update(snapshot: Dictionary) -> void:
	if hud != null:
		hud.set_snapshot(snapshot)

func _on_battle_finished(_result: Dictionary) -> void:
	print("[UI] battle_finished received — tearing down BattleUI")
	queue_free()
