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

@export var overlay_menu_safe_margin_px: int = 180

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

	# Overlay input policy
	overlay.submit_on_release = true
	overlay.min_points_to_submit = GestureRecognizer.MIN_INPUT_POINTS
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_apply_overlay_safe_margin() # <-- carve menu zone now

	overlay.submitted.connect(_on_overlay_submitted)
	overlay.cleared.connect(_on_overlay_cleared)
	overlay.stroke_updated.connect(_on_overlay_stroke_updated)

	GestureRecognizer.ensure_initialized()

	# Start with an initial window so pre-player events show.
	if feed != null:
		feed.begin_new_window()

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

	# Late attach fix
	if controller.has_method("is_waiting_for_player"):
		var waiting: bool = controller.is_waiting_for_player()
		if waiting:
			_on_player_turn_ready()

func _on_player_turn_ready() -> void:
	# Show overlay but DO NOT clear feed yet.
	_cleared_for_this_turn = false

	if overlay != null:
		_apply_overlay_safe_margin()  # ensure safe zone is applied each time
		overlay.visible = true
		overlay.mouse_filter = Control.MOUSE_FILTER_STOP

func _on_overlay_stroke_updated(points: Array[Vector2]) -> void:
	# First stroke → start new feed window
	if not _cleared_for_this_turn:
		if feed != null:
			feed.begin_new_window()
		_cleared_for_this_turn = true

	# --- DIAGNOSTIC PREVIEW ---
	if _diag_label != null:
		var rid: StringName = StringName("")
		var conf: float = 0.0
		var gates_ok := false
		var mapped: StringName = StringName("")
		var exists_in_catalog := false
		var known_by_player := true # default permissive if we cannot verify
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
				if rid == &"arc_slash":
					mapped = &"basic_attack"
				elif rid == &"block":
					mapped = &"guard"
				else:
					mapped = &"fizzle"

			# Check catalog and player-known for ability ids only
			var mapped_s := String(mapped)
			if mapped_s != "basic_attack" and mapped_s != "guard" and mapped_s != "fizzle":
				exists_in_catalog = (AbilityCatalogService.get_by_id(mapped_s).size() > 0)
				known_by_player = _player_knows_ability(mapped_s)
			else:
				exists_in_catalog = true
				known_by_player = true

			will_fizzle = (
				String(mapped) == "fizzle"
				or conf < confidence_threshold
				or not gates_ok
				or not exists_in_catalog
				or not known_by_player
				or not state_ok
			)

		var col := (Color(1,0.35,0.35) if will_fizzle else Color(0.45,1,0.55))
		_diag_label.add_theme_color_override("font_color", col)

		_diag_label.text = "gesture=%s  conf=%.0f%%  gates=%s  mapped→%s  catalog=%s  known=%s  state=%s  %s" % [
			String(rid),
			conf * 100.0,
			("OK" if gates_ok else "NO"),
			String(mapped),
			("OK" if exists_in_catalog else "MISSING"),
			("YES" if known_by_player else "NO"),
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
	var mapped: StringName = _gesture_to_ability_id(gid)

	var mapped_s := String(mapped)
	var exists_in_catalog := false
	var known_by_player := true # default permissive for specials
	if mapped_s != "" and mapped_s != "basic_attack" and mapped_s != "guard" and mapped_s != "fizzle":
		exists_in_catalog = (AbilityCatalogService.get_by_id(mapped_s).size() > 0)
		known_by_player = _player_knows_ability(mapped_s)
	else:
		exists_in_catalog = true
		known_by_player = true

	var ok: bool = (
		mapped_s != ""
		and conf >= confidence_threshold
		and passes
		and exists_in_catalog
		and known_by_player
	)

	if ok:
		controller.commit_player_action(&"use_ability", {
			"ability_id": mapped_s,
			"gesture_id": String(gid),
			"confidence": conf
		})
	else:
		if exists_in_catalog and not known_by_player:
			_show_unlearned_toast(mapped_s)
		controller.commit_player_action(&"fizzle", {
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
	queue_free()

func _gesture_to_ability_id(gid: StringName) -> StringName:
	# 1) Pass-through: if the gesture id already exists as an ability id, use it.
	var s := String(gid)
	if s != "":
		if AbilityCatalogService.get_by_id(s).size() > 0:
			return gid

	# 2) Legacy/alias names (kept for old templates & backwards compat)
	match gid:
		# SWORD
		&"arc_slash", &"slash", &"sword_arc": return &"arc_slash"
		&"riposte", &"riposte_check":         return &"riposte"
		# SPEAR
		&"thrust", &"spear_thrust":           return &"thrust"
		&"skewer", &"spear_skewer":           return &"skewer"
		# MACE
		&"crush", &"mace_crush":              return &"crush"
		&"guard_break", &"mace_guard_break":  return &"guard_break"
		# BOW
		&"aimed_shot", &"bow_chevron":        return &"aimed_shot"
		&"piercing_bolt", &"bow_horizontal":  return &"piercing_bolt"
		# LIGHT
		&"heal", &"light_caret":              return &"heal"
		&"purify", &"light_triangle":         return &"purify"
		# DARK
		&"shadow_grasp", &"dark_hook":        return &"shadow_grasp"
		&"curse_mark", &"dark_diamond":       return &"curse_mark"
		# FIRE
		&"firebolt", &"fire_downcaret":       return &"firebolt"
		&"flame_wall", &"fire_inverted_u":    return &"flame_wall"
		# WATER
		&"water_jet", &"water_tilde":         return &"water_jet"
		&"tide_surge", &"water_u":            return &"tide_surge"
		# EARTH
		&"stone_spikes", &"earth_zigzag":     return &"stone_spikes"
		&"bulwark", &"earth_square":          return &"bulwark"
		# WIND
		&"gust", &"wind_arc":                 return &"gust"
		# DEFENSE
		&"block", &"block_vertical":          return &"block"
		# Unarmed / Utility
		&"cyclone":                           return &"cyclone"
		&"punch":                             return &"punch"
		&"rest":                              return &"rest"
		&"meditate":                          return &"meditate"
		_:
			return StringName("")   # leave as fizzle if truly unknown

func _apply_overlay_safe_margin() -> void:
	# Reserve a right-side strip for the Game Menu to stay clickable.
	# Overlay covers the rest of the screen.
	if overlay == null:
		return
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.offset_left = 0
	overlay.offset_top = 0
	overlay.offset_bottom = 0
	overlay.offset_right = -max(0, overlay_menu_safe_margin_px)

# --- NEW HELPERS -----------------------------------------------------------

## UI-side check: consult RunState snapshot.skill_tracks[aid].unlocked when available.
func _player_knows_ability(aid: String) -> bool:
	if aid == "" or aid == "fizzle":
		return true

	# Specials always allowed
	if aid == "basic_attack" or aid == "guard":
		return true

	var rs: Node = get_node_or_null(^"/root/RunState")
	if rs != null:
		# Preferred: explicit unlocked map in player snapshot (helpers.skills_unlocked)
		if rs.has_method("get_player_snapshot"):
			var snap_any: Variant = rs.call("get_player_snapshot")
			if typeof(snap_any) == TYPE_DICTIONARY:
				var snap: Dictionary = snap_any as Dictionary

				# A) helpers.skills_unlocked
				var helpers_any: Variant = snap.get("helpers")
				if typeof(helpers_any) == TYPE_DICTIONARY:
					var helpers: Dictionary = helpers_any as Dictionary
					var unlocked_any: Variant = helpers.get("skills_unlocked")
					if typeof(unlocked_any) == TYPE_DICTIONARY:
						var unlocked: Dictionary = unlocked_any as Dictionary
						if unlocked.has(aid):
							return bool(unlocked[aid])

				# B) raw skill_tracks[aid].unlocked (UI convenience)
				var tracks_any: Variant = snap.get("skill_tracks")
				if typeof(tracks_any) == TYPE_DICTIONARY:
					var tracks: Dictionary = tracks_any as Dictionary
					if tracks.has(aid):
						var entry: Variant = tracks[aid]
						if typeof(entry) == TYPE_DICTIONARY:
							return bool((entry as Dictionary).get("unlocked", false))

		# C) Back-compat: fall back to runtime ability_levels>0
		if rs.has_method("get_player_runtime"):
			var pr_any: Variant = rs.call("get_player_runtime")
			if typeof(pr_any) != TYPE_NIL:
				var levels_any: Variant = pr_any.get("ability_levels") if pr_any is Object else null
				if typeof(levels_any) == TYPE_DICTIONARY:
					var levels: Dictionary = levels_any as Dictionary
					return levels.has(aid) and int(levels[aid]) > 0

	# Unknown environment → conservative allow; kernel still enforces lock.
	return true

func _show_unlearned_toast(aid: String) -> void:
	if hud != null and hud.has_method("show_toast"):
		hud.call("show_toast", "Ability not learned: %s" % aid)
