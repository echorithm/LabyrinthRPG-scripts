# res://ui/status/StatusModal.gd
extends "res://ui/common/BaseModal.gd"
class_name StatusModal

enum Tab { OVERVIEW, EQUIPMENT, WEAPONS, ABILITIES, EFFECTS, LOG, INVENTORY }

@export var slot: int = -1
@export var overview_scene: PackedScene
@export var equipment_scene: PackedScene
@export var weapons_scene: PackedScene
@export var abilities_scene: PackedScene
@export var effects_scene: PackedScene
@export var log_scene: PackedScene
@export var inventory_scene: PackedScene
@export var mobile_fullscreen_threshold: Vector2i = Vector2i(1024, 700) # treat below this as “mobile”
@export var mobile_min_touch_target_px: int = 56                         # min tab/btn height on mobile


# UI refs
var _title: Label
var _tabs: HBoxContainer
var _content: Control
var _close_btn: Button

# panel instances and selection
var _instances: Dictionary = {}
var _active_tab: int = Tab.OVERVIEW

# resolved slot for this modal session
var _resolved_slot: int = 1

func on_opened() -> void:
	_resolved_slot = _resolve_slot()
	_cache_ui()
	_title.text = "Status"
	_build_tabs_if_needed()
	_switch_to(_active_tab)

func on_closed() -> void:
	for p in _instances.values():
		(p as StatusPanel).on_exit()

func _cache_ui() -> void:
	if _panel == null:
		_panel = get_node_or_null(panel_path) as Control
	assert(_panel != null, "StatusModal expects a child Control named 'Panel' or set panel_path.")

	var root := _panel.get_node_or_null(^"Margin/V") as VBoxContainer
	assert(root != null, "Missing 'Panel/Margin/V' path.")

	_title   = root.get_node_or_null(^"Title") as Label
	_tabs    = root.get_node_or_null(^"Tabs") as HBoxContainer
	_content = root.get_node_or_null(^"Content") as Control

	var bottom := root.get_node_or_null(^"Bottom") as HBoxContainer
	if bottom:
		_close_btn = bottom.get_node_or_null(^"Close") as Button
		if _close_btn == null:
			for c in bottom.get_children():
				if c is Button:
					_close_btn = c
					break

	assert(_title != null,   "Missing Label at Panel/Margin/V/Title")
	assert(_tabs != null,    "Missing HBoxContainer at Panel/Margin/V/Tabs")
	assert(_content != null, "Missing Control at Panel/Margin/V/Content")

	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Responsive: bump title size on phones
	var vp: Vector2 = get_viewport_rect().size
	var is_mobile: bool = vp.x < float(fullscreen_threshold.x) or vp.y < float(fullscreen_threshold.y)
	if is_mobile:
		_title.add_theme_font_size_override("font_size", 22)
	else:
		_title.add_theme_font_size_override("font_size", 18)

func _build_tabs_if_needed() -> void:
	if _tabs.get_child_count() == 0:
		var labels: Array[String] = [
			"Overview","Equipment","Weapons","Abilities","Effects","Log","Inventory"
		]
		var group := ButtonGroup.new()
		var vp: Vector2 = get_viewport_rect().size
		var is_mobile: bool = (vp.x < float(mobile_fullscreen_threshold.x)) or (vp.y < float(mobile_fullscreen_threshold.y))
		var target_h: float = float(mobile_min_touch_target_px if is_mobile else 44)

		for i in labels.size():
			var b := Button.new()
			b.text = labels[i]
			b.toggle_mode = true
			b.button_group = group
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.custom_minimum_size = Vector2(0.0, target_h)  # taller touch targets

			# Make long labels behave on narrow screens
			b.clip_text = true
			b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			# Optional: slightly bigger text on mobile tabs
			if is_mobile:
				b.add_theme_font_size_override("font_size", 16)

			b.pressed.connect(_on_tab_pressed.bind(i))
			_tabs.add_child(b)

	# Close button hookup (guard if missing)
	if _close_btn:
		_close_btn.text = "Close"
		_close_btn.custom_minimum_size.y = float(mobile_min_touch_target_px)
		if not _close_btn.pressed.is_connected(close):
			_close_btn.pressed.connect(close)
	else:
		push_warning("[StatusModal] Close button not found; modal can still be closed with Esc/tap outside.")


func _on_tab_pressed(i: int) -> void:
	_switch_to(i)

func _switch_to(tab_i: int) -> void:
	if tab_i < 0: tab_i = 0
	if tab_i > Tab.INVENTORY: tab_i = Tab.INVENTORY

	# Deactivate previous panel
	if _instances.has(_active_tab):
		var prev := _instances[_active_tab] as StatusPanel
		prev.on_exit()
		prev.visible = false

	# Make sure Content behaves
	_content.clip_contents = true
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.size_flags_vertical   = Control.SIZE_EXPAND_FILL

	# Ensure a sensible minimum height, but let BaseModal stretch on phones.
	if _content.custom_minimum_size.y < 360.0:
		_content.custom_minimum_size.y = 360.0

	# Lazy create / reuse
	var p: StatusPanel = _instances.get(tab_i, null)
	if p == null:
		p = _instantiate_panel(tab_i)
		if p == null:
			push_error("[StatusModal] Could not instantiate panel for tab %d" % tab_i)
			return
		_instances[tab_i] = p
		_content.add_child(p)
		_configure_panel_layout(p)

		# pop-up protection
		if not p.wants_register_hit_rect.is_connected(_register_extra_hit_rect):
			p.wants_register_hit_rect.connect(_register_extra_hit_rect)
		if not p.wants_unregister_hit_rect.is_connected(_unregister_extra_hit_rect):
			p.wants_unregister_hit_rect.connect(_unregister_extra_hit_rect)
	else:
		_configure_panel_layout(p)

	# Show & refresh
	p.set_run_slot(_resolved_slot)
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

func _instantiate_panel(tab_i: int) -> StatusPanel:
	var ps: PackedScene = null
	match tab_i:
		Tab.OVERVIEW:  ps = overview_scene
		Tab.EQUIPMENT: ps = equipment_scene
		Tab.WEAPONS:   ps = weapons_scene
		Tab.ABILITIES: ps = abilities_scene
		Tab.EFFECTS:   ps = effects_scene
		Tab.LOG:       ps = log_scene
		Tab.INVENTORY: ps = inventory_scene
		_: ps = overview_scene
	if ps == null:
		push_warning("[StatusModal] PackedScene not assigned for tab %d" % tab_i)
		return null
	var inst := ps.instantiate()
	assert(inst is StatusPanel, "Panel scene must extend StatusPanel.")
	return inst as StatusPanel

func _register_extra_hit_rect(rect: Rect2) -> void:
	_extra_hit_rects.append(rect)

func _unregister_extra_hit_rect(rect: Rect2) -> void:
	for i in range(_extra_hit_rects.size()):
		if _extra_hit_rects[i] == rect:
			_extra_hit_rects.remove_at(i)
			return

func _resolve_slot() -> int:
	if slot > 0:
		return slot
	var rs := get_node_or_null(^"/root/RunState")
	if rs:
		var v: Variant = rs.get("default_slot")
		if v != null and int(v) > 0:
			return int(v)
	return 1
