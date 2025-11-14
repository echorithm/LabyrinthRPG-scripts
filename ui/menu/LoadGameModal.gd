extends "res://ui/common/BaseModal.gd"
class_name LoadGameModal

const DEBUG: bool = true
func _dbg(msg: String) -> void:
	if DEBUG:
		print("[LoadGameModal] ", msg)

# Look/size like NewGameFlow
const MODAL_W_PCT: float = 0.92
const MODAL_H_PCT: float = 0.78

const SaveManager := preload("res://persistence/SaveManager.gd")
const PATH_VILLAGE: String = "res://scripts/village/state/VillageHexOverworld2.tscn"
const PATH_LOADING: String = "res://ui/common/LoadingScreen.tscn"
const MAX_SLOTS: int = 12

# Nodes
var _panel_root: MarginContainer
var _vbox: VBoxContainer
var _header: HBoxContainer
var _title: Label

var _content_panel: PanelContainer
var _body: Control
var _tree: Tree

var _footer: HBoxContainer
var _btn_delete: Button
var _btn_close: Button
var _btn_load: Button

# State
var _selected_slot: int = -1

func _ready() -> void:
	modal_theme = preload("res://ui/themes/ModalTheme.tres")
	panel_path = ^"MarginContainer"
	super._ready()

	_build_shell_if_needed()
	_apply_layout()
	_center_modal_panel()
	_build_tree_headers()

	var vp: Viewport = get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_vp_resized):
		vp.size_changed.connect(_on_vp_resized)

func on_opened() -> void:
	_rebuild_tree_rows()
	if is_instance_valid(_tree):
		_tree.grab_focus()
	var p: Control = get_node_or_null(^"MarginContainer") as Control
	if p != null:
		_dbg("opened: vp=%s panel_rect=%s" % [str(get_viewport_rect().size), str(p.get_global_rect())])

# ---------- build ----------
func _build_shell_if_needed() -> void:
	_panel_root = get_node_or_null(^"MarginContainer") as MarginContainer
	if _panel_root == null:
		_panel_root = MarginContainer.new()
		_panel_root.name = "MarginContainer"
		add_child(_panel_root)

	_panel_root.add_theme_constant_override("margin_left", 24)
	_panel_root.add_theme_constant_override("margin_right", 24)
	_panel_root.add_theme_constant_override("margin_top", 24)
	_panel_root.add_theme_constant_override("margin_bottom", 24)

	_vbox = _panel_root.get_node_or_null(^"VBoxContainer") as VBoxContainer
	if _vbox == null:
		_vbox = VBoxContainer.new()
		_vbox.name = "VBoxContainer"
		_panel_root.add_child(_vbox)
	if not _vbox.has_theme_constant_override("separation"):
		_vbox.add_theme_constant_override("separation", 16)

	# Header
	_header = _vbox.get_node_or_null(^"Header") as HBoxContainer
	if _header == null:
		_header = HBoxContainer.new()
		_header.name = "Header"
		_header.add_theme_constant_override("separation", 14)
		_vbox.add_child(_header)

	_title = _header.get_node_or_null(^"Title") as Label
	if _title == null:
		_title = Label.new()
		_title.name = "Title"
		_title.text = "Load Game"
		_header.add_child(_title)

	# Content sheet
	_content_panel = _vbox.get_node_or_null(^"ContentHost") as PanelContainer
	if _content_panel == null:
		_content_panel = PanelContainer.new()
		_content_panel.name = "ContentHost"
		_content_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_content_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_vbox.add_child(_content_panel)

	_body = _content_panel.get_node_or_null(^"Body") as Control
	if _body == null:
		_body = Control.new()
		_body.name = "Body"
		_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_body.custom_minimum_size = Vector2(640, 420)
		_content_panel.add_child(_body)

	_tree = _body.get_node_or_null(^"Tree") as Tree
	if _tree == null:
		_tree = Tree.new()
		_tree.name = "Tree"
		_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_tree.custom_minimum_size = Vector2(640, 420)
		_tree.focus_mode = Control.FOCUS_ALL
		_body.add_child(_tree)

	# Footer
	_footer = _vbox.get_node_or_null(^"Footer") as HBoxContainer
	if _footer == null:
		_footer = HBoxContainer.new()
		_footer.name = "Footer"
		_footer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_footer.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_footer.add_theme_constant_override("separation", 8)
		_vbox.add_child(_footer)

	_btn_delete = _footer.get_node_or_null(^"btn_delete") as Button
	if _btn_delete == null:
		_btn_delete = Button.new()
		_btn_delete.name = "btn_delete"
		_btn_delete.text = "Delete"
		_footer.add_child(_btn_delete)

	var spacer: Control = _footer.get_node_or_null(^"spacer") as Control
	if spacer == null:
		spacer = Control.new()
		spacer.name = "spacer"
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_footer.add_child(spacer)

	_btn_close = _footer.get_node_or_null(^"btn_close") as Button
	if _btn_close == null:
		_btn_close = Button.new()
		_btn_close.name = "btn_close"
		_btn_close.text = "Close"
		_footer.add_child(_btn_close)

	_btn_load = _footer.get_node_or_null(^"btn_load") as Button
	if _btn_load == null:
		_btn_load = Button.new()
		_btn_load.name = "btn_load"
		_btn_load.text = "Load"
		_footer.add_child(_btn_load)

	if not _tree.item_selected.is_connected(_on_selected):
		_tree.item_selected.connect(_on_selected)
	if not _tree.item_activated.is_connected(_on_item_activated):
		_tree.item_activated.connect(_on_item_activated)
	if not _btn_close.pressed.is_connected(_on_close_pressed):
		_btn_close.pressed.connect(_on_close_pressed)
	if not _btn_load.pressed.is_connected(_on_load_pressed):
		_btn_load.pressed.connect(_on_load_pressed)
	if not _btn_delete.pressed.is_connected(_on_delete_pressed):
		_btn_delete.pressed.connect(_on_delete_pressed)

func _apply_layout() -> void:
	# Sheet look
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.059, 0.063, 0.078, 0.94)
	sb.border_color = Color(1, 1, 1, 0.12)
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.corner_radius_top_left = 12
	sb.corner_radius_top_right = 12
	sb.corner_radius_bottom_left = 12
	sb.corner_radius_bottom_right = 12
	sb.shadow_color = Color(0, 0, 0, 0.55)
	sb.shadow_size = 18
	sb.shadow_offset = Vector2(0, 6)
	_content_panel.add_theme_stylebox_override("panel", sb)

	# Button heights for touch
	var vp: Vector2 = get_viewport_rect().size
	var min_h: float = clamp(vp.y * 0.07, 48.0, 72.0)
	_btn_delete.custom_minimum_size.y = min_h
	_btn_close.custom_minimum_size.y = min_h
	_btn_load.custom_minimum_size.y = min_h

func _center_modal_panel() -> void:
	if _panel_root == null:
		return
	var vp: Vector2 = get_viewport_rect().size
	var w: float = clamp(vp.x * MODAL_W_PCT, 540.0, vp.x - 24.0)
	var h: float = clamp(vp.y * MODAL_H_PCT, 420.0, vp.y - 24.0)

	_panel_root.anchor_left = 0.5
	_panel_root.anchor_right = 0.5
	_panel_root.anchor_top = 0.5
	_panel_root.anchor_bottom = 0.5
	_panel_root.offset_left = -w * 0.5
	_panel_root.offset_right =  w * 0.5
	_panel_root.offset_top =  -h * 0.5
	_panel_root.offset_bottom =  h * 0.5

	_content_panel.custom_minimum_size = Vector2(w - 48.0, h - 140.0)
	_dbg("center modal w=%.0f h=%.0f vp=%s" % [w, h, str(vp)])

func _on_vp_resized() -> void:
	_center_modal_panel()

# ---------- tree content ----------
func _build_tree_headers() -> void:
	_title.text = "Load Game"

	_tree.columns = 3
	_tree.set_column_titles_visible(true)
	_tree.set_column_title(0, "Slot")
	_tree.set_column_title(1, "Summary")
	_tree.set_column_title(2, "Last Played")
	_tree.set_column_expand(0, false)
	_tree.set_column_custom_minimum_width(0, 120)
	_tree.set_column_expand(1, true)
	_tree.set_column_expand(2, true)

func _rebuild_tree_rows() -> void:
	_tree.clear()
	var root: TreeItem = _tree.create_item()

	var slots: Array[int] = []
	if "list_used_slots" in SlotService:
		slots = SlotService.list_used_slots()
	elif "list_present_slots" in SaveManager:
		slots = SaveManager.list_present_slots(MAX_SLOTS)
	_dbg("slots=" + str(slots))

	for s: int in slots:
		var gm: Dictionary = {}
		if "read_game_if_exists" in SaveManager:
			gm = SaveManager.read_game_if_exists(s)
		if gm.is_empty():
			continue

		var player: Dictionary = (gm.get("player", {}) as Dictionary)
		var sb: Dictionary = (player.get("stat_block", {}) as Dictionary)
		var lvl: int = int(sb.get("level", 1))
		var diff: String = String((gm.get("settings", {}) as Dictionary).get("difficulty", "U")).to_upper()

		var ts_v: Variant = gm.get("updated_at", 0)
		var ts: float = 0.0
		if typeof(ts_v) == TYPE_FLOAT:
			ts = float(ts_v)
		elif typeof(ts_v) == TYPE_INT:
			ts = float(int(ts_v))
		var last_played: String = _fmt_time(ts)

		var it: TreeItem = _tree.create_item(root)
		it.set_text(0, "Slot %d" % s)
		it.set_text(1, "Lv %d • Diff %s" % [lvl, diff])
		it.set_text(2, last_played)
		it.set_metadata(0, s)

		# Difficulty color on summary + little color chip in slot column
		var col: Color = _difficulty_color(diff)
		if it.has_method("set_custom_color"):
			it.set_custom_color(1, col)
		elif it.has_method("set_custom_fg_color"):
			it.set_custom_fg_color(1, col)
		var chip: Texture2D = _color_chip(col, 12)
		if chip != null:
			it.set_icon(0, chip)

# ---------- events ----------
func _on_selected() -> void:
	var item: TreeItem = _tree.get_selected()
	_selected_slot = (int(item.get_metadata(0)) if item != null else -1)
	_dbg("select slot=" + str(_selected_slot))

func _on_item_activated() -> void:
	_on_load_pressed()

func _on_close_pressed() -> void:
	close()

func _on_load_pressed() -> void:
	if _selected_slot <= 0:
		_dbg("load: no slot selected")
		return

	var tree: SceneTree = get_tree()

	# Make the selected slot active and bump its META timestamp.
	if "activate_and_touch" in SaveManager:
		SaveManager.activate_and_touch(_selected_slot)
	else:
		tree.set_meta("current_slot", _selected_slot)

	# Flip to GAME before loading and ensure unpaused.
	var ap: Node = get_node_or_null(^"/root/AppPhase")
	if ap != null and ap.has_method("to_game"):
		ap.call("to_game")
	if tree.paused:
		tree.paused = false

	_dbg("load slot=" + str(_selected_slot))
	_go_via_loading(PATH_VILLAGE)
	close()  # safe after scene change

func _on_delete_pressed() -> void:
	if _selected_slot <= 0:
		return
	SlotService.delete_slot(_selected_slot)
	_selected_slot = -1
	_rebuild_tree_rows()

# ---------- utils ----------
func _fmt_time(ts: float) -> String:
	if ts <= 0.0:
		return ""
	return Time.get_datetime_string_from_unix_time(int(ts), true)

func _go_via_loading(target_path: String) -> void:
	var tree: SceneTree = get_tree()
	tree.set_meta("loading_target_path", target_path)
	var has_loading: bool = ResourceLoader.exists(PATH_LOADING)
	if has_loading:
		tree.change_scene_to_file(PATH_LOADING)
	else:
		tree.change_scene_to_file(target_path)

func _difficulty_color(key: String) -> Color:
	var k: String = key.strip_edges().to_upper()
	match k:
		"C", "COMMON":   return Color.hex(0xbfc3c7ff) # gray
		"U", "UNCOMMON": return Color.hex(0x67c37bff) # green
		"R", "RARE":     return Color.hex(0x5aa0ffff) # blue
		"E", "EPIC":     return Color.hex(0xb277ffff) # purple
		"A", "ANCIENT":  return Color.hex(0xe7a64bff) # orange
		"L", "LEGENDARY":return Color.hex(0xffc342ff) # gold
		"M", "MYTHIC":   return Color.hex(0xff6bd3ff) # pink
		_:               return Color.WHITE

func _color_chip(c: Color, s: int = 10) -> Texture2D:
	var img: Image = Image.create(max(1, s), max(1, s), false, Image.FORMAT_RGBA8)
	img.fill(c)
	return ImageTexture.create_from_image(img)
