# res://ui/hud/GameMenu.gd
extends MenuButton

@export var show_settings: bool = false
@export var show_quit: bool = false

# Assign in Inspector if you want; falls back to preload().
@export var status_modal_scene: PackedScene = preload("res://ui/status/StatusModal.tscn")

func _ready() -> void:
	# Visuals / placement
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

	print("[GameMenu] ready; popup items=", p.item_count)

func _build_menu() -> void:
	var p: PopupMenu = get_popup()
	p.clear()
	var id: int = 0
	p.add_item("Status", id);    id += 1
	#p.add_item("Inventory", id); id += 1
	if show_settings:
		p.add_separator()
		p.add_item("Settings", id); id += 1
	if show_quit:
		p.add_separator()
		p.add_item("Quit to Village", id); id += 1

func _on_menu_id_pressed(id: int) -> void:
	var p: PopupMenu = get_popup()
	var label: String = p.get_item_text(id)
	print("[GameMenu] pressed id=", id, " label=", label)
	p.hide()

	match label:
		"Status":
			_open_status()
		"Inventory":
			#built into Status now.
			pass
		"Settings":
			# TODO: open settings modal
			pass
		_:
			pass

func _open_status() -> void:
	# Suspend inventory layer if present
	var inv_ork: Node = get_node_or_null("/root/InventoryOrchestrator")
	if inv_ork and inv_ork.has_method("suspend"):
		inv_ork.call("suspend", "status_open")

	# Create a top canvas layer so status is guaranteed above everything
	var layer := CanvasLayer.new()
	layer.name = "StatusUILayer"
	layer.layer = 10000                  # > 9999 used by inventory
	layer.follow_viewport_enabled = true

	var parent: Node = get_tree().current_scene if get_tree().current_scene else get_tree().root
	parent.add_child(layer)

	# Instantiate the modal inside this layer
	var scene: PackedScene = status_modal_scene
	if scene == null:
		push_error("[GameMenu] status_modal_scene not assigned.")
		layer.queue_free()
		return

	var sm_inst := scene.instantiate()
	if not (sm_inst is StatusModal):
		push_error("[GameMenu] Status scene must use StatusModal.gd at root.")
		layer.queue_free()
		return

	var sm: StatusModal = sm_inst as StatusModal
	layer.add_child(sm)

	# Make sure Content doesn't swallow tab clicks (also set in scene if you like)
	if sm.has_method("_cache_ui"):
		# _cache_ui runs in on_opened, but this is a belt-and-suspenders guard:
		sm.call_deferred("_cache_ui")

	sm.slot = SaveManager.DEFAULT_SLOT
	sm.present()

	# On close: resume inventory & free the layer (and modal)
	sm.closed.connect(func() -> void:
		if inv_ork and inv_ork.has_method("resume"):
			inv_ork.call("resume")
		layer.queue_free()
	)


func _open_inventory() -> void:
	# Preferred: call the autoload orchestrator
	var inv: Node = get_node_or_null("/root/InventoryOrchestrator")
	if inv and inv.has_method("open"):
		print("[GameMenu] invoking InventoryOrchestrator.open()")
		inv.call("open")
	else:
		push_warning("[GameMenu] InventoryOrchestrator not found; trying direct modal…")
		# Fallback path kept for backward compatibility
		var modal: Node = get_node_or_null("/root/InventoryOrchestrator/InventoryUILayer/InventoryUIRoot/InventoryModal")
		if modal and modal.has_method("present"):
			modal.call("present")
		else:
			push_error("[GameMenu] Inventory modal not found")
