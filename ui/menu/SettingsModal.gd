extends "res://ui/common/BaseModal.gd"
class_name SettingsModal

const DEBUG: bool = true
func _dbg(msg: String) -> void:
	if DEBUG:
		print("[SettingsModal] ", msg)

# Match NewGameFlow sheet geometry
const MODAL_W_PCT: float = 0.92
const MODAL_H_PCT: float = 0.78

# Nodes
var _panel_root: MarginContainer
var _vbox: VBoxContainer
var _header: HBoxContainer
var _title: Label

var _content_panel: PanelContainer
var _content_box: VBoxContainer

var _row_music: HBoxContainer
var _row_sfx: HBoxContainer
var _row_ui: HBoxContainer
var _replay: CheckBox

var _footer: HBoxContainer
var _btn_close: Button

func _ready() -> void:
	modal_theme = preload("res://ui/themes/ModalTheme.tres")
	panel_path = ^"MarginContainer"
	super._ready()

	_build_shell_if_needed()
	_apply_layout()
	_center_modal_panel()
	_fill_content()

	var vp: Viewport = get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_vp_resized):
		vp.size_changed.connect(_on_vp_resized)

func on_opened() -> void:
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
		_title.text = "Settings"
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
			_content_box.add_theme_constant_override("separation", 12)
		_content_panel.add_child(_content_box)

	# Rows
	_row_music = _content_box.get_node_or_null(^"MusicRow") as HBoxContainer
	if _row_music == null:
		_row_music = HBoxContainer.new()
		_row_music.name = "MusicRow"
		_row_music.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_row_music.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_row_music.add_theme_constant_override("separation", 10)
		_content_box.add_child(_row_music)

	_row_sfx = _content_box.get_node_or_null(^"SfxRow") as HBoxContainer
	if _row_sfx == null:
		_row_sfx = HBoxContainer.new()
		_row_sfx.name = "SfxRow"
		_row_sfx.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_row_sfx.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_row_sfx.add_theme_constant_override("separation", 10)
		_content_box.add_child(_row_sfx)

	_row_ui = _content_box.get_node_or_null(^"UiScaleRow") as HBoxContainer
	if _row_ui == null:
		_row_ui = HBoxContainer.new()
		_row_ui.name = "UiScaleRow"
		_row_ui.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_row_ui.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_row_ui.add_theme_constant_override("separation", 10)
		_content_box.add_child(_row_ui)

	_replay = _content_box.get_node_or_null(^"chk_replay_tutorial_per_slot") as CheckBox
	if _replay == null:
		_replay = CheckBox.new()
		_replay.name = "chk_replay_tutorial_per_slot"
		_content_box.add_child(_replay)

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
	# Sheet style like NewGameFlow
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

	# Touch-friendly buttons
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
	_panel_root.offset_left  = -w * 0.5
	_panel_root.offset_right =  w * 0.5
	_panel_root.offset_top   = -h * 0.5
	_panel_root.offset_bottom=  h * 0.5

	_content_panel.custom_minimum_size = Vector2(w - 48.0, h - 140.0)
	_dbg("center modal w=%.0f h=%.0f vp=%s" % [w, h, str(vp)])

func _on_vp_resized() -> void:
	_center_modal_panel()

# ---------- content ----------
func _fill_content() -> void:
	_title.text = "Settings"

	_fill_slider_row(_row_music, "Music Volume")
	_fill_slider_row(_row_sfx, "SFX Volume")
	_fill_ui_scale_row(_row_ui)

	_replay.text = "Replay Gesture Tutorial (current slot)"

func _fill_slider_row(row: HBoxContainer, label_text: String) -> void:
	if row.get_child_count() == 0:
		var lbl: Label = Label.new()
		lbl.text = label_text

		var slider: HSlider = HSlider.new()
		slider.min_value = -60.0
		slider.max_value = 0.0
		slider.step = 0.1
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		row.add_child(lbl)
		row.add_child(slider)

func _fill_ui_scale_row(row: HBoxContainer) -> void:
	if row.get_child_count() == 0:
		var lbl: Label = Label.new()
		lbl.text = "UI Scale"

		var opts: OptionButton = OptionButton.new()
		for n: String in ["Small", "Medium", "Large"]:
			opts.add_item(n)
		opts.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

		row.add_child(lbl)
		row.add_child(opts)

func _on_close() -> void:
	close()
