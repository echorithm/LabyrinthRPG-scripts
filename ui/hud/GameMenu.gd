extends MenuButton

@export var show_settings: bool = false
@export var show_quit: bool = true
@export var show_gesture_test: bool = true   # NEW: expose in editor for quick toggle

@export var status_modal_scene: PackedScene = preload("res://ui/status/StatusModal.tscn")
@export_range(10, 72, 1) var desktop_font_size: int = 32
@export_range(10, 72, 1) var mobile_font_size: int = 48

const MAIN_MENU_SCENE: String = "res://scripts/village/state/VillageHexOverworld2.tscn"
const GESTURE_TEST_SCENE: String = "res://scripts/tools/GestureTest.tscn"  # NEW

func _ready() -> void:
	if text.is_empty():
		text = "≡"
	flat = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL

	# Visibility protection during battle toggles
	if not is_in_group("game_menu"):
		add_to_group("game_menu")

	# Treat "mobile" as small viewport; adjust to taste.
	var is_small_screen: bool = get_viewport_rect().size.x <= 900.0

	# 1) Move farther from the top-right corner (margin in pixels).
	var edge_margin: int = 30 if is_small_screen else 24
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, edge_margin)

	# 2) Make the button bigger on small screens + larger hamburger text.
	var fs: int = mobile_font_size if is_small_screen else desktop_font_size
	add_theme_font_size_override("font_size", fs)

	# Ensure the control is big enough for the larger glyph.
	custom_minimum_size = Vector2(fs * 2, fs * 2)

	_build_menu()

	# Configure popup ONCE.
	var popup: PopupMenu = get_popup()
	if is_small_screen:
		popup.add_theme_font_size_override("font_size", 24)

	if not popup.id_pressed.is_connected(_on_menu_id_pressed):
		popup.id_pressed.connect(_on_menu_id_pressed)

	# Keep the label in sync right before showing the menu.
	if not popup.about_to_popup.is_connected(_build_menu):
		popup.about_to_popup.connect(_build_menu)

func _build_menu() -> void:
	var p: PopupMenu = get_popup()
	p.clear()
	var id: int = 100
	p.add_item("Status", id); id += 1

	if show_gesture_test:
		p.add_separator()
		p.add_item("Gesture Test", id); id += 1   # NEW

	if show_settings:
		p.add_separator()
		p.add_item("Settings", id); id += 1

	if show_quit:
		p.add_separator()
		var flee_or_quit: String = "Flee" if _is_in_battle() else "Quit to Main Menu"
		p.add_item(flee_or_quit, id); id += 1

func _on_menu_id_pressed(id: int) -> void:
	var p: PopupMenu = get_popup()
	var idx: int = p.get_item_index(id)
	var label: String = p.get_item_text(idx)
	p.hide()
	match label:
		"Status":
			_open_status()
		"Gesture Test":
			_open_gesture_test()    # NEW
		"Settings":
			pass
		"Quit to Main Menu":
			_confirm_quit_to_menu()
		"Flee":
			_confirm_flee()
		_:
			pass

# -----------------------------
# Dev: Gesture Test launcher
# -----------------------------
func _open_gesture_test() -> void:
	# Record the current scene file so the test scene can return.
	var tree: SceneTree = get_tree()
	var cur: Node = tree.current_scene
	var return_path: String = ""
	if is_instance_valid(cur):
		# If the current scene is not a file-backed scene, fall back to main menu.
		return_path = cur.scene_file_path
	if return_path.is_empty():
		return_path = MAIN_MENU_SCENE
	tree.set_meta("return_scene_path", return_path)
	tree.paused = false
	tree.change_scene_to_file(GESTURE_TEST_SCENE)

# -----------------------------
# Quit (out of combat) handling
# -----------------------------
func _confirm_quit_to_menu() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "Quit to Main Menu?"
	dlg.dialog_text = "This will safely bank your run progress and return to the main menu."
	dlg.get_ok_button().text = "Quit"
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	dlg.confirmed.connect(_do_quit_to_menu)
	add_child(dlg)
	dlg.popup_centered()

func _do_quit_to_menu() -> void:
	var ExitSafelyFlow := preload("res://persistence/flows/ExitSafelyFlow.gd")
	ExitSafelyFlow.execute(SaveManager.active_slot())
	get_tree().paused = false
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)

# -----------------------------
# Flee (in-combat) handling
# -----------------------------
func _confirm_flee() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "Flee from Battle?"
	dlg.dialog_text = "You will escape this encounter with no rewards."
	dlg.get_ok_button().text = "Flee"
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	dlg.confirmed.connect(_do_flee)
	add_child(dlg)
	dlg.popup_centered()

func _do_flee() -> void:
	var ctrl := _get_active_battle_controller()
	if ctrl == null:
		_confirm_quit_to_menu()
		return

	# Prefer the controller’s guarded early-finish (emits battle_end, stops processing).
	if ctrl.has_method("force_finish_early"):
		ctrl.call("force_finish_early", "flee")
		return

	# Fallback: emit battle_finished directly (legacy path).
	var rs: Dictionary = SaveManager.load_run()
	var flee_result := {
		"outcome": "flee",
		"player_hp": int(rs.get("hp", 0)),
		"player_mp": int(rs.get("mp", 0)),
	}
	ctrl.emit_signal("battle_finished", flee_result)

func _is_in_battle() -> bool:
	var arr: Array = get_tree().get_nodes_in_group("battle_controller")
	for n in arr:
		if is_instance_valid(n):
			return true
	return false

func _get_active_battle_controller() -> Object:
	var arr: Array = get_tree().get_nodes_in_group("battle_controller")
	for n in arr:
		if is_instance_valid(n):
			return n
	return null

# -----------------------------
# Status modal
# -----------------------------
func _open_status() -> void:
	var rs := get_node_or_null(^"/root/RunState")
	if rs:
		if rs.has_method("force_refresh_now"):
			rs.call("force_refresh_now")
		elif rs.has_method("reload"):
			rs.call("reload")
		else:
			var _tmp := SaveManager.load_run()
			if rs.has_signal("changed"):
				rs.emit_signal("changed")
	var inv_ork: Node = get_node_or_null("/root/InventoryOrchestrator")
	if inv_ork and inv_ork.has_method("suspend"):
		inv_ork.call("suspend", "status_open")

	var layer := CanvasLayer.new()
	layer.name = "StatusUILayer"
	layer.layer = 10000
	layer.follow_viewport_enabled = true

	var parent: Node = get_tree().current_scene if get_tree().current_scene else get_tree().root
	parent.add_child(layer)

	var scene: PackedScene = status_modal_scene
	if scene == null:
		push_error("[GameMenu] status_modal_scene not assigned.")
		layer.queue_free()
		return

	var sm_inst := scene.instantiate()
	layer.add_child(sm_inst)

	if sm_inst.has_method("_cache_ui"):
		sm_inst.call_deferred("_cache_ui")

	if sm_inst.has_method("present"):
		sm_inst.call_deferred("present")

	if sm_inst.has_signal("closed"):
		sm_inst.connect("closed", func() -> void:
			if inv_ork and inv_ork.has_method("resume"):
				inv_ork.call("resume")
			layer.queue_free()
		)
