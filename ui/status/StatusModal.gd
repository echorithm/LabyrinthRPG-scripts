# res://ui/status/StatusModal.gd
extends "res://ui/common/BaseModal.gd"
class_name StatusModal

enum Tab { OVERVIEW, EQUIPMENT, WEAPONS, ABILITIES, EFFECTS, LOG, INVENTORY }

@export var slot: int = 0
@export var overview_scene: PackedScene
@export var equipment_scene: PackedScene
@export var weapons_scene: PackedScene
@export var abilities_scene: PackedScene
@export var effects_scene: PackedScene
@export var log_scene: PackedScene
@export var inventory_scene: PackedScene

# UI refs (resolved in on_opened)
var _title: Label
var _tabs: HBoxContainer
var _content: Control
var _close_btn: Button

# panel instances and selection
var _instances: Dictionary = {}            # Tab -> StatusPanel
var _active_tab: int = Tab.OVERVIEW

# -------------------- BaseModal hooks --------------------

func on_opened() -> void:
	_cache_ui()                   # use inherited _panel from BaseModal
	_title.text = "Status"
	_build_tabs_if_needed()
	_switch_to(Tab.OVERVIEW)

func on_closed() -> void:
	for p in _instances.values():
		(p as StatusPanel).on_exit()

# -------------------- UI wiring --------------------

func _cache_ui() -> void:
	# Ensure panel exists (from BaseModal)
	if _panel == null:
		_panel = get_node_or_null(panel_path) as Control
	assert(_panel != null, "StatusModal expects a child Control named 'Panel' or set panel_path.")

	var root := _panel.get_node_or_null(^"Margin/V") as VBoxContainer
	assert(root != null, "Missing 'Panel/Margin/V' path.")

	_title   = root.get_node_or_null(^"Title") as Label
	_tabs    = root.get_node_or_null(^"Tabs") as HBoxContainer
	_content = root.get_node_or_null(^"Content") as Control

	# Close button: be forgiving on path and type
	var bottom := root.get_node_or_null(^"Bottom") as HBoxContainer
	if bottom:
		_close_btn = bottom.get_node_or_null(^"Close") as Button
		if _close_btn == null:
			# fallback: find first Button child under Bottom
			for c in bottom.get_children():
				if c is Button:
					_close_btn = c
					break

	# Final sanity
	assert(_title != null,   "Missing Label at Panel/Margin/V/Title")
	assert(_tabs != null,    "Missing HBoxContainer at Panel/Margin/V/Tabs")
	assert(_content != null, "Missing Control at Panel/Margin/V/Content")
	# _close_btn may still be null; we guard where we use it.
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _build_tabs_if_needed() -> void:
	if _tabs.get_child_count() == 0:
		var labels: Array[String] = [
			"Overview","Equipment","Weapons","Abilities","Effects","Log","Inventory"
		]
		for i in labels.size():
			var b := Button.new()
			b.text = labels[i]
			b.toggle_mode = true
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.pressed.connect(_on_tab_pressed.bind(i))
			_tabs.add_child(b)

	# Close button hookup (guard if missing)
	if _close_btn:
		_close_btn.text = "Close"
		if not _close_btn.pressed.is_connected(close):
			_close_btn.pressed.connect(close)
	else:
		push_warning("[StatusModal] Close button not found; modal can still be closed with Esc/tap outside.")

func _on_tab_pressed(i: int) -> void:
	_switch_to(i)

# -------------------- Tab/panel management --------------------

func _switch_to(tab_i: int) -> void:
	if _active_tab == tab_i and _instances.has(tab_i):
		return

	# Deactivate previous panel
	if _instances.has(_active_tab):
		(_instances[_active_tab] as StatusPanel).on_exit()

	# Make sure Content behaves (one-time-ish)
	_content.clip_contents = true
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	if _content.custom_minimum_size.y < 320.0:
		_content.custom_minimum_size.y = 320.0  # prevents VBox collapse

	# Hide existing children (keep alive)
	for c in _content.get_children():
		(c as Control).visible = false

	# Lazy create / reuse
	var p: StatusPanel = _instances.get(tab_i, null)
	if p == null:
		p = _instantiate_panel(tab_i)
		_instances[tab_i] = p
		_content.add_child(p)
		_configure_panel_layout(p)

		# Let panels protect popups (click-outside-to-close)
		if not p.wants_register_hit_rect.is_connected(_register_extra_hit_rect):
			p.wants_register_hit_rect.connect(_register_extra_hit_rect)
		if not p.wants_unregister_hit_rect.is_connected(_unregister_extra_hit_rect):
			p.wants_unregister_hit_rect.connect(_unregister_extra_hit_rect)
	else:
		_configure_panel_layout(p)

	# Show & refresh
	p.set_run_slot(slot)
	p.visible = true
	p.on_enter()
	p.refresh()

	# Toggle buttons
	for i in _tabs.get_child_count():
		var b := _tabs.get_child(i) as Button
		b.button_pressed = (i == tab_i)

	_active_tab = tab_i


func _configure_panel_layout(panel: Control) -> void:
	panel.top_level = false
	panel.position = Vector2.ZERO
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	# (No offsets/anchors hacks for Title/Tabs/Bottom—VBox handles them)




func _instantiate_panel(tab_i: int) -> StatusPanel:
	var ps: PackedScene
	match tab_i:
		Tab.OVERVIEW:  ps = overview_scene
		Tab.EQUIPMENT: ps = equipment_scene
		Tab.WEAPONS:   ps = weapons_scene
		Tab.ABILITIES: ps = abilities_scene
		Tab.EFFECTS:   ps = effects_scene
		Tab.LOG:       ps = log_scene
		Tab.INVENTORY: ps = inventory_scene
		_: ps = overview_scene
	var inst := ps.instantiate()
	assert(inst is StatusPanel, "Panel scene must extend StatusPanel.")
	return inst as StatusPanel

# -------------------- Click-outside protection for panel popups ------------

func _register_extra_hit_rect(rect: Rect2) -> void:
	# _extra_hit_rects is provided by BaseModal
	_extra_hit_rects.append(rect)

func _unregister_extra_hit_rect(rect: Rect2) -> void:
	for i in range(_extra_hit_rects.size()):
		if _extra_hit_rects[i] == rect:
			_extra_hit_rects.remove_at(i)
			return
