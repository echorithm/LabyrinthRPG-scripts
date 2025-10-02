extends MenuButton

@export var show_settings: bool = false
@export var show_quit: bool = true

@export var status_modal_scene: PackedScene = preload("res://ui/status/StatusModal.tscn")
const MAIN_MENU_SCENE: String = "res://scenes/TestingMenu.tscn"

func _ready() -> void:
	if text.is_empty():
		text = "≡"
	flat = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	anchors_preset = Control.PRESET_TOP_RIGHT
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 12)
	_build_menu()
	var p: PopupMenu = get_popup()
	if not p.id_pressed.is_connected(_on_menu_id_pressed):
		p.id_pressed.connect(_on_menu_id_pressed)

func _build_menu() -> void:
	var p: PopupMenu = get_popup()
	p.clear()
	var id: int = 100
	p.add_item("Status", id); id += 1
	if show_settings:
		p.add_separator()
		p.add_item("Settings", id); id += 1
	if show_quit:
		p.add_separator()
		p.add_item("Quit to Main Menu", id); id += 1

func _on_menu_id_pressed(id: int) -> void:
	var p := get_popup()
	var idx: int = p.get_item_index(id)
	var label: String = p.get_item_text(idx)
	p.hide()
	match label:
		"Status":
			_open_status()
		"Settings":
			pass
		"Quit to Main Menu":
			_confirm_quit_to_menu()
		_:
			pass

func _confirm_quit_to_menu() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "Quit to Main Menu?"
	dlg.dialog_text = "This will safely bank your run progress and return to the main menu."
	dlg.get_ok_button().text = "Quit"
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.confirmed.connect(_do_quit_to_menu)
	add_child(dlg)
	dlg.popup_centered()

func _do_quit_to_menu() -> void:
	var ExitSafelyFlow := preload("res://persistence/flows/ExitSafelyFlow.gd")
	ExitSafelyFlow.execute(SaveManager.DEFAULT_SLOT)
	get_tree().paused = false
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)

func _open_status() -> void:
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
