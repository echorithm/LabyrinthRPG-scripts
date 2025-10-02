extends StatusPanel
class_name InventoryPanel

const BODY_TEXT: Color = Color(0.88, 0.88, 0.90, 1.0)

var _list: ItemList
var _name: Label
var _stats: Label
var _row_menu: PopupMenu
var _btn_use: Button
var _btn_equip: Button
var _popup_rect: Rect2 = Rect2()

# -------------------------------------------------------
# Lifecycle
# -------------------------------------------------------
func _ready() -> void:
	_resolve_nodes()
	_ensure_layout()
	_build_row_menu_if_missing()

func on_enter() -> void:
	_resolve_nodes()
	_build_row_menu_if_missing()
	_ensure_layout()

	# List signals
	if _list:
		if not _list.item_selected.is_connected(_on_item_selected):
			_list.item_selected.connect(_on_item_selected)
			print("[InventoryPanel] connected: ItemList.item_selected")
		if not _list.item_activated.is_connected(_on_item_activated):
			_list.item_activated.connect(_on_item_activated)
			print("[InventoryPanel] connected: ItemList.item_activated")

	# Row menu (optional)
	if _row_menu and not _row_menu.id_pressed.is_connected(_on_row_menu_id):
		_row_menu.id_pressed.connect(_on_row_menu_id)
		print("[InventoryPanel] connected: RowMenu.id_pressed")

	# Buttons
	if _btn_use and not _btn_use.pressed.is_connected(_on_use_pressed):
		_btn_use.pressed.connect(_on_use_pressed)
		print("[InventoryPanel] connected: btn_use.pressed")
	if _btn_equip and not _btn_equip.pressed.is_connected(_on_equip_pressed):
		_btn_equip.pressed.connect(_on_equip_pressed)
		print("[InventoryPanel] connected: btn_equip.pressed")

	# RunState changed
	var rs_node: Node = _rs()
	if rs_node and not rs_node.changed.is_connected(_on_run_changed):
		rs_node.changed.connect(_on_run_changed)
		print("[InventoryPanel] connected: RunState.changed")

	await get_tree().process_frame
	_fit_split_to_width()
	refresh()

func on_exit() -> void:
	if _list:
		if _list.item_selected.is_connected(_on_item_selected):
			_list.item_selected.disconnect(_on_item_selected)
		if _list.item_activated.is_connected(_on_item_activated):
			_list.item_activated.disconnect(_on_item_activated)

	if _row_menu and _row_menu.id_pressed.is_connected(_on_row_menu_id):
		_row_menu.id_pressed.disconnect(_on_row_menu_id)

	if _btn_use and _btn_use.pressed.is_connected(_on_use_pressed):
		_btn_use.pressed.disconnect(_on_use_pressed)
	if _btn_equip and _btn_equip.pressed.is_connected(_on_equip_pressed):
		_btn_equip.pressed.disconnect(_on_equip_pressed)

	var rs_node: Node = _rs()
	if rs_node and rs_node.changed.is_connected(_on_run_changed):
		rs_node.changed.disconnect(_on_run_changed)

	if _popup_rect.size != Vector2.ZERO:
		emit_signal("wants_unregister_hit_rect", _popup_rect)
		_popup_rect = Rect2()

# -------------------------------------------------------
# Refresh
# -------------------------------------------------------
func refresh() -> void:
	_ensure_layout()
	_fit_split_to_width()

	if _list == null:
		push_warning("[InventoryPanel] ItemList not found; skipping refresh.")
		return

	_list.clear()
	if _name:  _name.text = ""
	if _stats: _stats.text = ""

	var inv: Array = _get_inventory()
	for i: int in range(inv.size()):
		var row_any: Variant = inv[i]
		if typeof(row_any) != TYPE_DICTIONARY:
			continue
		var it: Dictionary = row_any

		var id: String = String(it.get("id", ""))
		var qty: int = int(it.get("count", 1))
		var dmax: int = int(it.get("durability_max", 0))
		var rarity: String = String(it.get("rarity", ""))
		var name_txt: String = ItemNames.display_name(id)

		var suffix: String = ""
		if not rarity.is_empty():
			suffix = " (%s)" % rarity.substr(0, 1).to_upper()
		if dmax == 0:
			suffix += " ×%d" % qty

		var row_text: String = "%s%s" % [name_txt, suffix]
		_list.add_item(row_text)

		var idx: int = _list.get_item_count() - 1
		_list.set_item_metadata(idx, i)

		if not rarity.is_empty():
			_list.set_item_custom_fg_color(idx, ItemNames.rarity_color(rarity))

# -------------------------------------------------------
# Internals
# -------------------------------------------------------
func _resolve_nodes() -> void:
	_list       = get_node_or_null(^"HSplitContainer/ItemList") as ItemList
	_name       = get_node_or_null(^"HSplitContainer/DetailsBox/Name") as Label
	_stats      = get_node_or_null(^"HSplitContainer/DetailsBox/Stats") as Label
	_row_menu   = get_node_or_null(^"RowMenu") as PopupMenu
	_btn_use    = get_node_or_null(^"HSplitContainer/DetailsBox/HBoxContainer/btn_use") as Button
	_btn_equip  = get_node_or_null(^"HSplitContainer/DetailsBox/HBoxContainer/btn_equip") as Button

	if _list == null:      _list      = find_child("ItemList",  true, false) as ItemList
	if _name == null:      _name      = find_child("Name",      true, false) as Label
	if _stats == null:     _stats     = find_child("Stats",     true, false) as Label
	if _row_menu == null:  _row_menu  = find_child("RowMenu",   true, false) as PopupMenu
	if _btn_use == null:   _btn_use   = find_child("btn_use",   true, false) as Button
	if _btn_equip == null: _btn_equip = find_child("btn_equip", true, false) as Button

func _build_row_menu_if_missing() -> void:
	if _row_menu == null:
		_row_menu = PopupMenu.new()
		_row_menu.name = "RowMenu"
		add_child(_row_menu)
	_row_menu.hide_on_item_selection = true
	_row_menu.hide_on_checkable_item_selection = true
	_row_menu.exclusive = false
	_row_menu.transient = true

# -------------------------------------------------------
# Selection / actions
# -------------------------------------------------------
func _on_item_selected(row: int) -> void:
	print("[InventoryPanel] _on_item_selected row=", row)
	if _list == null:
		return
	var meta_any: Variant = _list.get_item_metadata(row)
	if typeof(meta_any) != TYPE_INT:
		print("[InventoryPanel] item_selected: metadata not int →", meta_any)
		return
	var run_index: int = int(meta_any)
	print("[InventoryPanel] selected run_index=", run_index)
	_update_buttons_and_details(run_index)
	_show_row_menu(row)

func _on_item_activated(row: int) -> void:
	print("[InventoryPanel] _on_item_activated row=", row)
	_on_item_selected(row)
	if _row_menu and _row_menu.get_item_count() >= 2:
		var can_use: bool = not _row_menu.is_item_disabled(0)
		var can_eq: bool  = not _row_menu.is_item_disabled(1)
		print("[InventoryPanel] activated: can_use=", can_use, " can_equip=", can_eq)
		if can_use:
			_on_use_pressed()
		elif can_eq:
			_on_equip_pressed()
	else:
		print("[InventoryPanel] activated: row menu not ready")

func _update_buttons_and_details(selected_run_index: int) -> void:
	var inv: Array = _get_inventory()

	var stats_txt: String = ""
	var can_use: bool = false
	var can_equip: bool = false

	if selected_run_index >= 0 and selected_run_index < inv.size():
		var row_any: Variant = inv[selected_run_index]
		if typeof(row_any) == TYPE_DICTIONARY:
			var row: Dictionary = row_any
			var id: String = String(row.get("id", ""))
			var dmax: int = int(row.get("durability_max", 0))
			var qty: int = int(row.get("count", 1))
			var ilvl: int = int(row.get("ilvl", 1))
			var rar: String = String(row.get("rarity", ""))
			var arch: String = String(row.get("archetype", ""))
			var wt: float = float(row.get("weight", 0.0))
			var opts: Dictionary = (row.get("opts", {}) as Dictionary)

			if _name:
				var ncolor: Color = ItemNames.rarity_color(rar) if not rar.is_empty() else BODY_TEXT
				_name.text = ItemNames.display_name(id) + ("" if rar.is_empty() else " (%s)" % rar)
				_name.add_theme_color_override("font_color", ncolor)

			if dmax == 0:
				# Stackable: consumables/books
				if id.begins_with("potion_"):
					stats_txt = "Type: Consumable\nQty: %d\nWeight: %.1f" % [qty, wt]
					can_use = true
				elif id.begins_with("book_"):
					var target: String = String(opts.get("target_skill", ""))
					stats_txt = "Type: Book\nQty: %d\nRarity: %s%s\nWeight: %.1f" % [
						qty, rar, ("" if target.is_empty() else "\nTarget: " + target), wt
					]
					can_use = true
				else:
					stats_txt = "Type: Stackable\nQty: %d\nWeight: %.1f" % [qty, wt]
			else:
				var cur: int = int(row.get("durability_current", dmax))
				stats_txt = "Type: Gear\nArchetype: %s\nilvl: %d\nDurability: %d / %d\nWeight: %.1f" % [
					arch, ilvl, cur, dmax, wt
				]
				can_equip = true

	if _stats:
		_stats.text = stats_txt

	# RowMenu (optional)
	if _row_menu:
		_row_menu.clear()
		_row_menu.add_item("Use", 1)
		_row_menu.add_item("Equip", 2)
		_row_menu.set_item_disabled(0, not can_use)
		_row_menu.set_item_disabled(1, not can_equip)

	# Buttons
	if _btn_use:
		_btn_use.disabled = not can_use
	if _btn_equip:
		_btn_equip.disabled = not can_equip

func _show_row_menu(row: int) -> void:
	if _row_menu == null or _list == null:
		return
	var list_grect: Rect2 = _list.get_global_rect()
	var item_rect_local: Rect2 = _list.get_item_rect(row)
	var item_top_global: Vector2 = list_grect.position + item_rect_local.position
	var popup_pos: Vector2 = Vector2(list_grect.end.x + 10.0, item_top_global.y)

	_row_menu.position = popup_pos
	_row_menu.popup()

	_popup_rect = Rect2(_row_menu.position, _row_menu.size)
	emit_signal("wants_register_hit_rect", _popup_rect)

func _on_row_menu_id(id: int) -> void:
	print("[InventoryPanel] _on_row_menu_id id=", id)
	match id:
		1: _on_use_pressed()
		2: _on_equip_pressed()
		_: print("[InventoryPanel] row menu: unknown id=", id)

func _on_use_pressed() -> void:
	if _list == null:
		return
	var sel: PackedInt32Array = _list.get_selected_items()
	if sel.is_empty():
		return
	var run_index: int = int(_list.get_item_metadata(sel[0]))
	var rc: Dictionary = ItemUseService.use_at_index(run_index, _get_slot())
	print("[InventoryPanel] use_at_index → ", rc)
	if bool(rc.get("consumed", false)):
		_rs_reload_if_present()
		refresh()

func _on_equip_pressed() -> void:
	if _list == null:
		return

	var sel: PackedInt32Array = _list.get_selected_items()
	if sel.is_empty():
		print("[InventoryPanel] Equip pressed but no selection.")
		return

	var list_row: int = int(sel[0])
	var meta_any: Variant = _list.get_item_metadata(list_row)
	var run_index: int = (int(meta_any) if typeof(meta_any) == TYPE_INT else -1)
	if run_index < 0:
		print("[InventoryPanel] Equip aborted: invalid run_index from list metadata →", meta_any)
		return

	# Validate the selected item is equippable (non-stackable gear)
	var slot_i: int = _get_slot()
	var rsd: Dictionary = SaveManager.load_run(slot_i)
	var inv: Array = (rsd.get("inventory", []) as Array)
	if run_index >= inv.size() or run_index < 0:
		print("[InventoryPanel] Equip aborted: run_index out of bounds →", run_index)
		return

	var row_any: Variant = inv[run_index]
	if typeof(row_any) != TYPE_DICTIONARY:
		print("[InventoryPanel] Equip aborted: not a Dictionary row at index →", run_index)
		return

	var row: Dictionary = row_any
	var id_str: String = String(row.get("id", ""))
	var uid_dbg: String = String(row.get("uid", ""))
	var dmax_dbg: int = int(row.get("durability_max", 0))

	# HARD GUARD: only allow gear (durability_max > 0)
	if dmax_dbg <= 0:
		print("[InventoryPanel] Equip blocked: not gear → id=", id_str, " dmax=", dmax_dbg)
		return

	print("[InventoryPanel] Equip request → row=", list_row,
		" run_index=", run_index, " id=", id_str, " uid=", uid_dbg, " dmax=", dmax_dbg)

	var rc: Dictionary = EquipmentService.equip_from_run_index(run_index, "mainhand", slot_i)
	print("[InventoryPanel] EquipmentService.equip_from_run_index(mainhand) → ", rc)

	if bool(rc.get("ok", false)):
		_rs_reload_if_present()
		refresh()
	else:
		var err: String = String(rc.get("error", ""))
		if not err.is_empty():
			push_warning("[InventoryPanel] Equip failed: " + err)

func _on_run_changed() -> void:
	refresh()

# -------------------------------------------------------
# Layout
# -------------------------------------------------------
func _ensure_layout() -> void:
	top_level = false
	anchors_preset = Control.PRESET_FULL_RECT
	set_offsets_preset(Control.PRESET_FULL_RECT)
	position = Vector2.ZERO
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical   = Control.SIZE_EXPAND_FILL

	var split: HSplitContainer = find_child("HSplitContainer", true, false) as HSplitContainer
	if split:
		split.top_level = false
		split.anchors_preset = Control.PRESET_FULL_RECT
		split.set_offsets_preset(Control.PRESET_FULL_RECT)
		split.position = Vector2.ZERO
		split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		split.size_flags_vertical   = Control.SIZE_EXPAND_FILL

	if _list:
		_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_list.size_flags_vertical   = Control.SIZE_EXPAND_FILL
		_list.size_flags_stretch_ratio = 1.0
		if _list.custom_minimum_size == Vector2.ZERO:
			_list.custom_minimum_size = Vector2(280, 320)

	var details: Control = find_child("DetailsBox", true, false) as Control
	if details:
		details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		details.size_flags_vertical   = Control.SIZE_EXPAND_FILL
		details.size_flags_stretch_ratio = 2.0
		if details.custom_minimum_size.x < 360.0:
			details.custom_minimum_size.x = 360.0

	if _name:
		_name.clip_text = true
		_name.autowrap_mode = TextServer.AUTOWRAP_OFF
	if _stats:
		_stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		if _stats.custom_minimum_size.y < 140.0:
			_stats.custom_minimum_size.y = 140.0

func _fit_split_to_width() -> void:
	var split: HSplitContainer = find_child("HSplitContainer", true, false) as HSplitContainer
	if split == null:
		return
	var w: float = max(1.0, float(size.x))
	var left_min: float = 280.0
	var right_min: float = 360.0
	var desired_left: int = int(clampi(int(round(w * 0.35)), int(left_min), int(w - right_min)))
	split.split_offset = desired_left

# -------------------------------------------------------
# Data access
# -------------------------------------------------------
func _get_slot() -> int:
	if _slot >= 1:
		return _slot
	var rs_node: Node = get_node_or_null("/root/RunState")
	if rs_node and rs_node.has_variable("default_slot"):
		return int(rs_node.get("default_slot"))
	return 1

func _get_inventory() -> Array:
	var rs_node: Node = _rs()
	if rs_node and rs_node.has_method("run_inventory"):
		var any: Variant = rs_node.call("run_inventory")
		return (any as Array) if any is Array else []
	# fallback
	var run_d: Dictionary = SaveManager.load_run(_get_slot())
	var inv_any: Variant = run_d.get("inventory", [])
	return (inv_any as Array) if inv_any is Array else []

func _rs_reload_if_present() -> void:
	var rs_node: Node = _rs()
	if rs_node and rs_node.has_method("reload"):
		rs_node.call("reload", _get_slot())

func _rs() -> Node:
	return get_node_or_null("/root/RunState")
