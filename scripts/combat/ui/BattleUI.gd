extends CanvasLayer
class_name BattleUI

## Lightweight bridge that shows your GestureOverlay during the player's turn,
## calls GestureRecognizer, and commits the action to BattleController.

@export var confidence_threshold: float = 0.60

var controller: BattleController
var overlay: GestureOverlay

func _ready() -> void:
	layer = 80  # above dungeon HUD
	# Fullscreen container
	var root := Control.new()
	root.name = "BattleUIRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# Your GestureOverlay
	overlay = GestureOverlay.new()
	overlay.name = "GestureOverlay"
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.visible = false
	root.add_child(overlay)

	# Wire overlay signals
	overlay.submitted.connect(_on_overlay_submitted)
	overlay.cleared.connect(_on_overlay_cleared)
	overlay.stroke_updated.connect(_on_overlay_stroke_updated)

	# Make sure recognizer is ready
	GestureRecognizer.ensure_initialized()

	# If controller was assigned before _ready, attach now.
	_post_assign_controller()

func set_controller(c: BattleController) -> void:
	controller = c
	_post_assign_controller()

func _post_assign_controller() -> void:
	if controller == null: return
	# Listen for CTB's "it's your turn now"
	if not controller.is_connected("player_turn_ready", Callable(self, "_on_player_turn_ready")):
		controller.player_turn_ready.connect(_on_player_turn_ready)
	# Safety: ensure CTB is not auto-playing the player
	controller.auto_player = false
	controller.auto_monster = true

func _on_player_turn_ready() -> void:
	# Show overlay and accept input
	if overlay != null:
		overlay.visible = true
		overlay.mouse_filter = Control.MOUSE_FILTER_STOP

func _on_overlay_submitted(points: Array[Vector2]) -> void:
	if controller == null or overlay == null:
		return

	# Recognize + gate
	var res: Dictionary = GestureRecognizer.recognize(points)
	var gid: StringName = StringName(res.get("id", StringName("")))
	var conf: float = float(res.get("confidence", 0.0))
	var passes: bool = GestureRecognizer.passes_symbol_filters(gid, points)
	var ok: bool = (String(gid) != "") and (conf >= confidence_threshold) and passes

	# MVP mapping: any valid gesture commits a basic attack (CTB 100).
	# You can expand this to map "slash" -> melee, "block" -> guard, etc.
	if ok:
		# If you later add ability CTB costs, pass that instead of 100.
		controller.commit_player_action(100)
	else:
		# If you want a fizzle/do-nothing, just resume timeline without spending CTB.
		# For now, we’ll still consume a basic action so turns move along.
		controller.commit_player_action(100)

	# Hide and clear
	overlay.clear_stroke()
	overlay.visible = false

func _on_overlay_cleared() -> void:
	# No-op for now
	pass

func _on_overlay_stroke_updated(_points: Array[Vector2]) -> void:
	# If you want on-the-fly hints, do it here.
	pass
