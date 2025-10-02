extends CanvasLayer
class_name BattleUI

const GestureRecognizer := preload("res://scripts/combat/ui/GestureRecognizer.gd")

@export var confidence_threshold: float = 0.60

var controller: BattleController
var overlay: GestureOverlay
var hud: BattleHUD
var feed: ActionFeed
var _diag_label: Label

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
		
	_diag_label = Label.new()
	_diag_label.name = "GestureDiag"
	_diag_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_diag_label.offset_left = 8
	_diag_label.offset_top = 88
	_diag_label.offset_right = -8
	_diag_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_diag_label.text = "gesture: —"
	root.add_child(_diag_label)

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

func _on_overlay_stroke_updated(points: Array[Vector2]) -> void:
	# First stroke → start new feed window
	if not _cleared_for_this_turn:
		if feed != null:
			feed.begin_new_window()
			print("[Feed] New window (on gesture begin)")
		_cleared_for_this_turn = true

	# --- DIAGNOSTIC PREVIEW ---
	if _diag_label != null:
		var rid: StringName = StringName("")
		var conf: float = 0.0
		var gates_ok := false
		var mapped: StringName = StringName("")
		var exists_in_catalog := false
		var will_fizzle := true
		var state_ok := (controller != null and controller.is_waiting_for_player())

		if points.size() >= 2:
			var res: Dictionary = GestureRecognizer.recognize(points)
			rid = StringName(res.get("id", StringName("")))
			conf = float(res.get("confidence", 0.0))
			gates_ok = GestureRecognizer.passes_symbol_filters(rid, points)

			# Map gesture -> ability id (or special actions)
			mapped = _gesture_to_ability_id(rid)
			if String(mapped) == "":
				if rid == &"arc_slash":  mapped = &"basic_attack"
				elif rid == &"block": mapped = &"guard"
				else: mapped = &"fizzle"

			# Check catalog for ability ids only
			var mapped_s := String(mapped)
			if mapped_s != "basic_attack" and mapped_s != "guard" and mapped_s != "fizzle":
				# Use your service that reads ability_catalog.json once
				exists_in_catalog = (AbilityCatalogService.get_by_id(mapped_s).size() > 0)
			else:
				exists_in_catalog = true

			will_fizzle = (
				String(mapped) == "fizzle"
				or conf < confidence_threshold
				or not gates_ok
				or not exists_in_catalog
				or not state_ok
			)

		var col := (Color(1,0.35,0.35) if will_fizzle else Color(0.45,1,0.55))
		_diag_label.add_theme_color_override("font_color", col)

		_diag_label.text = "gesture=%s  conf=%.0f%%  gates=%s  mapped→%s  catalog=%s  state=%s  %s" % [
			String(rid),
			conf * 100.0,
			("OK" if gates_ok else "NO"),
			String(mapped),
			("OK" if exists_in_catalog else "MISSING"),
			("PLAYER_TURN" if state_ok else "WAIT"),
			("FIZZLE" if will_fizzle else "READY")
		]


func _on_overlay_submitted(points: Array[Vector2]) -> void:
	if controller == null or overlay == null:
		return

	var res: Dictionary = GestureRecognizer.recognize(points)
	var gid: StringName = StringName(res.get("id", StringName("")))
	var conf: float = float(res.get("confidence", 0.0))
	var passes: bool = GestureRecognizer.passes_symbol_filters(gid, points)
	var ok: bool = (String(gid) != "") and (conf >= confidence_threshold) and passes

	var action_id: StringName = &"fizzle"
	if ok:
		var mapped: StringName = _gesture_to_ability_id(gid)
		if String(mapped) != "":
			action_id = mapped
		else:
			match gid:
				&"arc_slash":
					action_id = &"basic_attack"
				&"block":
					action_id = &"guard"
				_:
					action_id = &"fizzle"
	else:
		action_id = &"fizzle"

	var status_str := "ok" if ok else "failed"
	print("[UI] Gesture %s id=%s conf=%.2f passes=%s -> action=%s"
		% [status_str, String(gid), conf, str(passes), String(action_id)])

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
	
func _gesture_to_ability_id(gid: StringName) -> StringName:
	match gid:
		# SWORD
		&"slash", &"sword_arc":
			return &"arc_slash"
		&"riposte", &"riposte_check":
			return &"riposte"

		# SPEAR
		&"thrust", &"spear_thrust":
			return &"thrust"
		&"skewer", &"spear_skewer":
			return &"skewer"

		# MACE
		&"crush", &"mace_crush":
			return &"crush"
		&"guard_break", &"mace_guard_break":
			return &"guard_break"

		# BOW
		&"aimed_shot", &"bow_chevron":
			return &"aimed_shot"
		&"piercing_bolt", &"bow_horizontal":
			return &"piercing_bolt"

		# LIGHT
		&"heal", &"light_caret":
			return &"heal"
		&"purify", &"light_triangle":
			return &"purify"

		# DARK
		&"shadow_grasp", &"dark_hook":
			return &"shadow_grasp"
		&"curse_mark", &"dark_diamond":
			return &"curse_mark"

		# FIRE
		&"firebolt", &"fire_downcaret":
			return &"firebolt"
		&"flame_wall", &"fire_inverted_u":
			return &"flame_wall"

		# WATER
		&"water_jet", &"water_tilde":
			return &"water_jet"
		&"tide_surge", &"water_u":
			return &"tide_surge"

		# EARTH
		&"stone_spikes", &"earth_zigzag":
			return &"stone_spikes"
		&"bulwark", &"earth_square":
			return &"bulwark"

		# WIND
		&"gust", &"wind_arc":
			return &"gust"

		# DEFENSE
		&"block", &"block_vertical":
			return &"block"
		_:
			return StringName("")
