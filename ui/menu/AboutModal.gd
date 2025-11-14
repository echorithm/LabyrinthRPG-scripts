extends "res://ui/common/BaseModal.gd"
class_name AboutModal

const DEBUG: bool = true
func _dbg(msg: String) -> void:
	if DEBUG:
		print("[AboutModal] ", msg)

# Match NewGameFlow look and feel
const MODAL_W_PCT: float = 0.92
const MODAL_H_PCT: float = 0.78

# Nodes (built on demand)
var _panel_root: MarginContainer
var _vbox: VBoxContainer
var _header: HBoxContainer
var _title: Label

var _content_panel: PanelContainer
var _content_box: VBoxContainer
var _game_title: Label
var _version_lbl: Label
var _blurb: RichTextLabel

var _footer: HBoxContainer
var _btn_close: Button

func _ready() -> void:
	# Use the same theme/sheet structure as NewGameFlow
	modal_theme = preload("res://ui/themes/ModalTheme.tres")
	panel_path = ^"MarginContainer"  # treat MarginContainer as the modal panel
	super._ready()

	_build_shell_if_needed()
	_apply_layout()
	_center_modal_panel()
	_fill_content()

	var vp: Viewport = get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_vp_resized):
		vp.size_changed.connect(_on_vp_resized)

func on_opened() -> void:
	if is_instance_valid(_btn_close):
		_btn_close.grab_focus()
	var panel: Control = get_node_or_null(^"MarginContainer") as Control
	if panel != null:
		_dbg("opened: vp=%s panel_rect=%s" % [str(get_viewport_rect().size), str(panel.get_global_rect())])

# ---------- build ----------
func _build_shell_if_needed() -> void:
	_panel_root = get_node_or_null(^"MarginContainer") as MarginContainer
	if _panel_root == null:
		_panel_root = MarginContainer.new()
		_panel_root.name = "MarginContainer"
		add_child(_panel_root)

	# Outer margins (sheet padding)
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

	# Header (Title)
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
		_title.text = "About"
		_header.add_child(_title)

	# Content sheet
	_content_panel = _vbox.get_node_or_null(^"ContentHost") as PanelContainer
	if _content_panel == null:
		_content_panel = PanelContainer.new()
		_content_panel.name = "ContentHost"
		_content_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_content_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_vbox.add_child(_content_panel)

	_content_box = _content_panel.get_node_or_null(^"Inner") as VBoxContainer
	if _content_box == null:
		_content_box = VBoxContainer.new()
		_content_box.name = "Inner"
		_content_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_content_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if not _content_box.has_theme_constant_override("separation"):
			_content_box.add_theme_constant_override("separation", 10)
		_content_panel.add_child(_content_box)

	_game_title = _content_box.get_node_or_null(^"GameTitle") as Label
	if _game_title == null:
		_game_title = Label.new()
		_game_title.name = "GameTitle"
		_game_title.add_theme_font_size_override("font_size", 26)
		_content_box.add_child(_game_title)

	_version_lbl = _content_box.get_node_or_null(^"VersionLabel") as Label
	if _version_lbl == null:
		_version_lbl = Label.new()
		_version_lbl.name = "VersionLabel"
		_version_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
		_content_box.add_child(_version_lbl)

	_blurb = _content_box.get_node_or_null(^"Blurb") as RichTextLabel
	if _blurb == null:
		_blurb = RichTextLabel.new()
		_blurb.name = "Blurb"
		_blurb.fit_content = true
		_content_box.add_child(_blurb)

	# Footer (right‑aligned Close)
	_footer = _vbox.get_node_or_null(^"Footer") as HBoxContainer
	if _footer == null:
		_footer = HBoxContainer.new()
		_footer.name = "Footer"
		_footer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_footer.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_footer.add_theme_constant_override("separation", 8)
		_vbox.add_child(_footer)

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

	if not _btn_close.pressed.is_connected(_on_close):
		_btn_close.pressed.connect(_on_close)

# ---------- layout / cosmetics ----------
func _apply_layout() -> void:
	# NewGameFlow‑style sheet
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

	# Mobile‑friendly button heights
	var vp: Vector2 = get_viewport_rect().size
	var min_h: float = clamp(vp.y * 0.07, 48.0, 72.0)
	_btn_close.custom_minimum_size.y = min_h

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

	# Constrain inner content sheet to readable size
	_content_panel.custom_minimum_size = Vector2(w - 48.0, h - 140.0)
	_dbg("center modal w=%.0f h=%.0f vp=%s" % [w, h, str(vp)])

func _on_vp_resized() -> void:
	_center_modal_panel()

# ---------- content ----------
func _fill_content() -> void:
	_title.text = "About"
	_game_title.text = "LabyrinthRPG"

	var vi: Dictionary = Engine.get_version_info()
	_version_lbl.text = "Godot %s.%s.%s • %s" % [
		str(vi.get("major", "")),
		str(vi.get("minor", "")),
		str(vi.get("patch", "")),
		str(vi.get("status", ""))
	]

	if _blurb.text.strip_edges().is_empty():
		_blurb.text = "A gesture‑driven dungeon adventure.\n© Echorithm"

func _on_close() -> void:
	close()
