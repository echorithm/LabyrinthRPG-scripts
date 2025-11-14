extends Control
class_name MainMenu

const DEBUG: bool = true
const MAX_SLOTS: int = 12

const SaveManager := preload("res://persistence/SaveManager.gd")
const SlotService := preload("res://persistence/services/slot_service.gd")

@export var menu_theme: Theme = preload("res://ui/themes/MenuTheme.tres")
@export var title_text: String = "LabyrinthRPG"
@export var subtitle_text: String = "The depths are Endless!"
@export var accent_color: Color = Color(0.368627, 0.631373, 1.0, 1.0)
@export var enable_quit_button: bool = true
@export var sfx_hover: AudioStream
@export var sfx_click: AudioStream
@export var center_margin_y_px: int = 0

# Main-menu BGM choices
const BGM_PATHS: Array[String] = [
	"res://audio/ui/MainMenu1.wav",
	"res://audio/ui/MainMenu2.wav",
]

# NodePaths
const NP_BG: NodePath = ^"Background"
const NP_CENTER: NodePath = ^"CenterContainer"
const NP_VBOX: NodePath = ^"CenterContainer/MenuButtons"
const NP_BTN_NEW: NodePath = ^"CenterContainer/MenuButtons/btn_new_game"
const NP_BTN_CONT: NodePath = ^"CenterContainer/MenuButtons/btn_continue"
const NP_BTN_LOAD: NodePath = ^"CenterContainer/MenuButtons/btn_load"
const NP_BTN_SETTINGS: NodePath = ^"CenterContainer/MenuButtons/btn_settings"
const NP_BTN_ABOUT: NodePath = ^"CenterContainer/MenuButtons/btn_about"
const NP_MODAL_HOST: NodePath = ^"ModalLayer/ModalHost"
const NP_TITLE: NodePath = ^"CenterContainer/MenuButtons/Title"
const NP_SUBTITLE: NodePath = ^"CenterContainer/MenuButtons/Subtitle"
const NP_FOOTER: NodePath = ^"CenterContainer/MenuButtons/Footer"
const NP_BTN_QUIT: NodePath = ^"CenterContainer/MenuButtons/btn_quit"
const NP_BGM: NodePath = ^"BGM"

# Resolved nodes
var _bg: TextureRect
var _center: Control
var _vbox: VBoxContainer
var _btn_new: Button
var _btn_continue: Button
var _btn_load: Button
var _btn_settings: Button
var _btn_about: Button
var _modal_host: Control
var _title: Label
var _subtitle: Label
var _footer: Label
var _btn_quit: Button
var _sfx_hover_player: AudioStreamPlayer
var _sfx_click_player: AudioStreamPlayer
var _bgm: AudioStreamPlayer

# Scenes
const PATH_SETTINGS: String = "res://ui/menu/SettingsModal.tscn"
const PATH_ABOUT: String = "res://ui/menu/AboutModal.tscn"
const PATH_LOAD: String = "res://ui/menu/LoadGameModal.tscn"
const PATH_NEWGAME: String = "res://ui/menu/new_game/NewGameFlow.tscn"
const PATH_VILLAGE: String = "res://scripts/village/state/VillageHexOverworld2.tscn"
const PATH_LOADING: String = "res://ui/common/LoadingScreen.tscn"

# ---------------- lifecycle ----------------
func _enter_tree() -> void:
	_resolve_nodes()
	if DEBUG:
		print("[MainMenu] _enter_tree scene=", get_scene_file_path(), " vp=", get_viewport_rect().size)

func _ready() -> void:
	_resolve_nodes()
	_bootstrap_layout()
	_apply_button_texts()
	_hook_signals()
	_set_phase_menu()
	_apply_menu_theme()
	_build_background()
	_ensure_title_and_footer()
	_ensure_quit_button()
	_detach_footer_to_bottom()

	_decorate_buttons()
	_refresh_continue_enabled()
	_focus_first_usable_button()
	_ensure_sfx()
	_start_bgm()

	await get_tree().process_frame
	_center_menu_exact()
	_debug_layout_snapshot("ready")

	if DEBUG:
		print("[MainMenu] resources exist?",
			" new=", ResourceLoader.exists(PATH_NEWGAME),
			" load=", ResourceLoader.exists(PATH_LOAD),
			" settings=", ResourceLoader.exists(PATH_SETTINGS),
			" about=", ResourceLoader.exists(PATH_ABOUT))
		_debug_dump_slots()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_resolve_nodes()
		if _center != null:
			_center.set_anchors_preset(Control.PRESET_FULL_RECT)
			_center.size = get_viewport_rect().size
		_decorate_buttons()
		_center_menu_exact()
		_debug_layout_snapshot("resized")

# ---------------- node resolving ----------------
func _resolve_nodes() -> void:
	_bg = get_node_or_null(NP_BG) as TextureRect
	_center = get_node_or_null(NP_CENTER) as Control
	_vbox = get_node_or_null(NP_VBOX) as VBoxContainer
	_btn_new = get_node_or_null(NP_BTN_NEW) as Button
	_btn_continue = get_node_or_null(NP_BTN_CONT) as Button
	_btn_load = get_node_or_null(NP_BTN_LOAD) as Button
	_btn_settings = get_node_or_null(NP_BTN_SETTINGS) as Button
	_btn_about = get_node_or_null(NP_BTN_ABOUT) as Button
	_modal_host = get_node_or_null(NP_MODAL_HOST) as Control
	_title = get_node_or_null(NP_TITLE) as Label
	_subtitle = get_node_or_null(NP_SUBTITLE) as Label
	_footer = get_node_or_null(NP_FOOTER) as Label
	_btn_quit = get_node_or_null(NP_BTN_QUIT) as Button
	_bgm = get_node_or_null(NP_BGM) as AudioStreamPlayer

	if DEBUG:
		print("[MainMenu] resolve: bg=", is_instance_valid(_bg),
			" center=", is_instance_valid(_center),
			" vbox=", is_instance_valid(_vbox),
			" new=", is_instance_valid(_btn_new),
			" cont=", is_instance_valid(_btn_continue),
			" load=", is_instance_valid(_btn_load),
			" settings=", is_instance_valid(_btn_settings),
			" about=", is_instance_valid(_btn_about),
			" modal_host=", is_instance_valid(_modal_host),
			" bgm=", is_instance_valid(_bgm))

# ---------------- layout helpers ----------------
func _bootstrap_layout() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size = get_viewport_rect().size

	if _bg != null:
		_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		_bg.offset_left = 0.0
		_bg.offset_top = 0.0
		_bg.offset_right = 0.0
		_bg.offset_bottom = 0.0
		_bg.size = get_viewport_rect().size
		_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_bg.stretch_mode = TextureRect.STRETCH_SCALE
		_bg.modulate = Color(1, 1, 1, 1)

	if _center != null:
		_center.set_anchors_preset(Control.PRESET_FULL_RECT)
		_center.size = get_viewport_rect().size

	if _vbox != null:
		_vbox.layout_mode = 0
		_vbox.anchor_left = 0.5
		_vbox.anchor_right = 0.5
		_vbox.anchor_top = 0.5
		_vbox.anchor_bottom = 0.5
		_vbox.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_vbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if not _vbox.has_theme_constant_override("separation"):
			_vbox.add_theme_constant_override("separation", 18)

	var min_w: float = 360.0
	var min_h: float = 56.0
	var btns: Array[Button] = [] as Array[Button]
	if _btn_new != null: btns.append(_btn_new)
	if _btn_continue != null: btns.append(_btn_continue)
	if _btn_load != null: btns.append(_btn_load)
	if _btn_settings != null: btns.append(_btn_settings)
	if _btn_about != null: btns.append(_btn_about)
	for b: Button in btns:
		b.custom_minimum_size = Vector2(min_w, min_h)
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	if DEBUG and _bg != null:
		print("[MainMenu] bootstrap vp=", get_viewport_rect().size,
			" bg_rect=", _bg.get_rect(), " stretch=", _bg.stretch_mode)

func _apply_button_texts() -> void:
	if _btn_new != null:
		_btn_new.text = "New Game"
		_btn_new.tooltip_text = "Start a new run"
	if _btn_continue != null:
		_btn_continue.text = "Continue"
		_btn_continue.tooltip_text = "Load the most recent slot"
	if _btn_load != null:
		_btn_load.text = "Load Game"
		_btn_load.tooltip_text = "Choose a slot to load"
	if _btn_settings != null:
		_btn_settings.text = "Settings"
		_btn_settings.tooltip_text = "Audio, UI scale, tutorial toggle"
	if _btn_about != null:
		_btn_about.text = "About"
		_btn_about.tooltip_text = "Credits and version"

func _hook_signals() -> void:
	if _btn_new != null and not _btn_new.pressed.is_connected(_on_new_game):
		_btn_new.pressed.connect(_on_new_game)
	if _btn_continue != null and not _btn_continue.pressed.is_connected(_on_continue):
		_btn_continue.pressed.connect(_on_continue)
	if _btn_load != null and not _btn_load.pressed.is_connected(_on_load):
		_btn_load.pressed.connect(_on_load)
	if _btn_settings != null and not _btn_settings.pressed.is_connected(_on_settings):
		_btn_settings.pressed.connect(_on_settings)
	if _btn_about != null and not _btn_about.pressed.is_connected(_on_about):
		_btn_about.pressed.connect(_on_about)

# ---------------- actions ----------------
func _on_new_game() -> void:
	# Open the NewGameFlow as a modal over the main menu,
	# instead of switching the entire scene (avoids blank/grey screen).
	if DEBUG:
		print("\n[MainMenu] New Game modal → ", PATH_NEWGAME)
	_set_phase_menu()
	_spawn_modal(PATH_NEWGAME)

func _on_continue() -> void:
	if DEBUG:
		print("\n[MainMenu] Continue pressed")
	var slot: int = _resolve_continue_slot(1)

	var has_meta: bool = false
	if "meta_exists" in SaveManager:
		has_meta = SaveManager.meta_exists(slot)
	if not has_meta:
		if DEBUG:
			print("[MainMenu] slot ", slot, " missing META → New Game")
		_on_new_game()
		return

	if "activate_and_touch" in SaveManager:
		SaveManager.activate_and_touch(slot)
	else:
		var tree0: SceneTree = get_tree()
		tree0.set_meta("current_slot", slot)

	if DEBUG:
		print("[MainMenu] continue slot=", slot, " → ", PATH_VILLAGE)
	if not ResourceLoader.exists(PATH_VILLAGE):
		_warn_missing_scene(PATH_VILLAGE)
		return
	_set_phase_game()
	_go_via_loading(PATH_VILLAGE)

func _on_load() -> void:
	if DEBUG:
		print("\n[MainMenu] Load Game modal")
	_spawn_modal(PATH_LOAD)

func _on_settings() -> void:
	if DEBUG:
		print("\n[MainMenu] Settings modal")
	_spawn_modal(PATH_SETTINGS)

func _on_about() -> void:
	if DEBUG:
		print("\n[MainMenu] About modal")
	_spawn_modal(PATH_ABOUT)

# ---------------- modal helper ----------------
func _spawn_modal(path: String) -> Node:
	if not ResourceLoader.exists(path):
		if DEBUG:
			print("[MainMenu] MISSING modal path: ", path)
		return null
	var ps: PackedScene = load(path) as PackedScene
	if ps == null:
		return null

	var inst: Node = ps.instantiate()
	if inst is Control and inst.has_method("present"):
		var ctrl: Control = inst as Control
		if _modal_host != null:
			_modal_host.add_child(ctrl)
		else:
			add_child(ctrl)
		(ctrl as Object).call("present", true, true)
		if DEBUG:
			print("[MainMenu] modal(BaseModal) presented: ", ctrl.name)
		return ctrl

	if inst is Window:
		var w: Window = inst as Window
		if _modal_host != null:
			_modal_host.add_child(w)
		else:
			add_child(w)
		if w.size.x < 720 or w.size.y < 480:
			w.size = Vector2i(900, 600)
		w.popup_centered()
		if DEBUG:
			print("[MainMenu] modal(Window) popup: ", w.title)
		return w

	add_child(inst)
	return inst

# ---------------- helpers ----------------
func _go_via_loading(target_path: String) -> void:
	var tree: SceneTree = get_tree()
	tree.set_meta("loading_target_path", target_path)
	var has_loading: bool = ResourceLoader.exists(PATH_LOADING)
	if has_loading:
		tree.change_scene_to_file(PATH_LOADING)
	else:
		tree.change_scene_to_file(target_path)

func _resolve_continue_slot(default_slot: int) -> int:
	if "last_played_slot_or_default" in SlotService:
		var s1: int = int(SlotService.last_played_slot_or_default(default_slot))
		return (s1 if s1 > 0 else default_slot)

	var tree: SceneTree = get_tree()
	if tree.has_meta("current_slot"):
		var v: Variant = tree.get_meta("current_slot")
		if typeof(v) == TYPE_INT and int(v) > 0:
			return int(v)

	var best_slot: int = default_slot
	var best_ts: float = -1.0

	if "list_present_slots" in SaveManager and "read_game_if_exists" in SaveManager:
		var present: Array[int] = SaveManager.list_present_slots(MAX_SLOTS)
		for s: int in present:
			var gm: Dictionary = SaveManager.read_game_if_exists(s)
			if gm.is_empty():
				continue
			var ts_v: Variant = gm.get("updated_at", -1)
			var ts: float = 0.0
			if typeof(ts_v) == TYPE_FLOAT:
				ts = float(ts_v)
			elif typeof(ts_v) == TYPE_INT:
				ts = float(int(ts_v))
			if ts > best_ts:
				best_ts = ts
				best_slot = s
	return best_slot

func _warn_missing_scene(path: String) -> void:
	push_warning("[MainMenu] Missing scene: " + path)

func _set_phase_menu() -> void:
	var ap: Node = get_node_or_null(^"/root/AppPhase")
	if ap != null and ap.has_method("to_menu"):
		ap.call("to_menu")

func _set_phase_game() -> void:
	var ap: Node = get_node_or_null(^"/root/AppPhase")
	if ap != null and ap.has_method("to_game"):
		ap.call("to_game")

# ---------------- exact centering ----------------
func _center_menu_exact() -> void:
	if _vbox == null:
		return
	_vbox.layout_mode = 0
	_vbox.anchor_left = 0.5
	_vbox.anchor_right = 0.5
	_vbox.anchor_top = 0.5
	_vbox.anchor_bottom = 0.5

	var vp: Vector2 = get_viewport_rect().size
	var min_sz: Vector2 = _vbox.get_combined_minimum_size()
	var w: float = clamp(min_sz.x, 320.0, vp.x - 32.0)
	var h: float = clamp(min_sz.y, 120.0, vp.y - 96.0)

	_vbox.offset_left = -w * 0.5
	_vbox.offset_right =  w * 0.5

	var top: float = -h * 0.5 + float(center_margin_y_px)
	var min_top: float = -(vp.y * 0.5) + 24.0
	if top < min_top:
		top = min_top
	_vbox.offset_top = top
	_vbox.offset_bottom = top + h

	if DEBUG:
		print("[MainMenuDBG] center_exact min=", min_sz, " vp=", vp, " w=", w, " h=", h,
			" offsets(L/T/R/B)=", _vbox.offset_left, ",", _vbox.offset_top, ",", _vbox.offset_right, ",", _vbox.offset_bottom)

# ---------------- debug helpers ----------------
func _rect_info(c: Control) -> String:
	var r: Rect2 = c.get_global_rect()
	return "pos=" + str(r.position) + " size=" + str(r.size)

func _debug_layout_snapshot(stage: String) -> void:
	if not DEBUG:
		return
	var vp: Vector2 = get_viewport_rect().size
	print("[MainMenu] snapshot=", stage, " vp=", vp)
	if _bg != null:
		var tex: Texture2D = _bg.texture
		var tinfo: String = "null"
		if tex != null:
			tinfo = tex.get_class() + "(" + str(tex.get_width()) + "x" + str(tex.get_height()) + ")"
		print("  BG rect=", _rect_info(_bg), " tex=", tinfo, " expand=", _bg.expand_mode, " stretch=", _bg.stretch_mode)
	if _center != null:
		print("  CENTER rect=", _rect_info(_center))
	if _vbox != null:
		var sep: int = (_vbox.get_theme_constant("separation") if _vbox.has_theme_constant_override("separation") else 8)
		print("  VBOX rect=", _rect_info(_vbox), " sep=", sep, " child_count=", _vbox.get_child_count(), " layout_mode=", int(_vbox.layout_mode))
	var btns: Array[Button] = _collect_buttons()
	var i: int = 0
	for b: Button in btns:
		print("    btn[", i, "] ", b.name, " rect=", _rect_info(b), " min=", b.custom_minimum_size, " vis=", b.visible, " dis=", b.disabled)
		i += 1

# ---------------- theme + decor ----------------
func _apply_menu_theme() -> void:
	if menu_theme != null:
		theme = menu_theme
		if DEBUG:
			print("[MainMenu] theme applied")

func _build_background() -> void:
	if _bg == null:
		if DEBUG:
			print("[MainMenu] no Background TextureRect found")
		return

	var grad: Gradient = Gradient.new()
	grad.colors = PackedColorArray([
		Color(0.16, 0.17, 0.20, 1.0),
		Color(0.02, 0.025, 0.03, 1.0)
	])
	grad.offsets = PackedFloat32Array([0.0, 1.0])

	var gt: GradientTexture2D = GradientTexture2D.new()
	gt.gradient = grad
	gt.fill = GradientTexture2D.FILL_LINEAR
	gt.fill_from = Vector2(0.5, 0.0)
	gt.fill_to = Vector2(0.5, 1.0)
	gt.width = 16
	gt.height = 16

	_bg.texture = gt
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.offset_left = 0.0
	_bg.offset_top = 0.0
	_bg.offset_right = 0.0
	_bg.offset_bottom = 0.0
	_bg.size = get_viewport_rect().size
	_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg.stretch_mode = TextureRect.STRETCH_SCALE
	_bg.modulate = Color(1, 1, 1, 1)

	var vignette: ColorRect = get_node_or_null(^"Vignette") as ColorRect
	if vignette == null:
		var cr: ColorRect = ColorRect.new()
		cr.name = "Vignette"
		cr.color = Color(0, 0, 0, 0.22)
		cr.anchors_preset = Control.PRESET_FULL_RECT
		cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(cr)
		move_child(cr, 1)

	if DEBUG:
		var tex2: Texture2D = _bg.texture
		print("[MainMenu] background set: tex=", (tex2.get_class() if tex2 != null else "null"),
			" size=", (Vector2(tex2.get_width(), tex2.get_height()) if tex2 != null else Vector2.ZERO),
			" bg_rect=", _rect_info(_bg), " vignette=true")

func _ensure_title_and_footer() -> void:
	if _vbox == null:
		return

	if _title == null:
		var t: Label = Label.new()
		t.name = "Title"
		t.text = title_text
		t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		t.add_theme_font_size_override("font_size", 38)
		_vbox.add_child(t)
		_vbox.move_child(t, 0)
		_title = t
		if DEBUG:
			print("[MainMenu] created Title")

	if _subtitle == null:
		var s: Label = Label.new()
		s.name = "Subtitle"
		s.text = subtitle_text
		s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		s.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		s.add_theme_font_size_override("font_size", 18)
		s.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
		_vbox.add_child(s)
		_vbox.move_child(s, 1)
		_subtitle = s
		if DEBUG:
			print("[MainMenu] created Subtitle")

	if _footer == null:
		var f: Label = Label.new()
		f.name = "Footer"
		var ver: String = str(ProjectSettings.get_setting("application/config/version", "0.1.0"))
		f.text = "v" + ver
		f.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		f.add_theme_font_size_override("font_size", 14)
		f.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
		_vbox.add_child(f)
		_footer = f
		if DEBUG:
			print("[MainMenu] created Footer ver=", ver)

	if not _vbox.has_theme_constant_override("separation"):
		_vbox.add_theme_constant_override("separation", 18)

	var spacer: Control = _vbox.get_node_or_null(^"Spacer") as Control
	if spacer == null:
		var sp: Control = Control.new()
		sp.name = "Spacer"
		sp.custom_minimum_size.y = 6.0
		_vbox.add_child(sp)
		_vbox.move_child(sp, 2)

func _detach_footer_to_bottom() -> void:
	if _footer == null or _center == null:
		return
	var current_parent: Node = _footer.get_parent()
	if current_parent != _center:
		current_parent.remove_child(_footer)
		_center.add_child(_footer)
		if DEBUG:
			print("[MainMenuDBG] footer reparented to CenterContainer")

	_footer.anchor_left = 0.5
	_footer.anchor_right = 0.5
	_footer.anchor_top = 1.0
	_footer.anchor_bottom = 1.0
	_footer.offset_left = -240.0
	_footer.offset_right = 240.0
	_footer.offset_top = -36.0
	_footer.offset_bottom = -12.0
	_footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if DEBUG:
		print("[MainMenuDBG] footer bottom-center rect=", _rect_info(_footer))

# ---------------- buttons + focus ----------------
func _collect_buttons() -> Array[Button]:
	var out: Array[Button] = [] as Array[Button]
	if _btn_new != null:
		out.append(_btn_new)
	if _btn_continue != null and _btn_continue.visible:
		out.append(_btn_continue)
	if _btn_load != null:
		out.append(_btn_load)
	if _btn_settings != null:
		out.append(_btn_settings)
	if _btn_about != null:
		out.append(_btn_about)
	if _btn_quit != null:
		out.append(_btn_quit)
	return out

func _decorate_buttons() -> void:
	var btns: Array[Button] = _collect_buttons()
	var vp: Vector2 = get_viewport_rect().size
	var min_w: float = max(360.0, vp.x * 0.28)
	var min_h: float = 56.0

	for b: Button in btns:
		b.custom_minimum_size = Vector2(min_w, min_h)
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		b.focus_mode = Control.FOCUS_ALL

		if not b.mouse_entered.is_connected(_on_btn_hover_enter):
			b.mouse_entered.connect(_on_btn_hover_enter.bind(b))
		if not b.mouse_exited.is_connected(_on_btn_hover_exit):
			b.mouse_exited.connect(_on_btn_hover_exit.bind(b))
		if not b.focus_entered.is_connected(_on_btn_focus_enter):
			b.focus_entered.connect(_on_btn_focus_enter.bind(b))
		if not b.focus_exited.is_connected(_on_btn_focus_exit):
			b.focus_exited.connect(_on_btn_focus_exit.bind(b))
		if not b.pressed.is_connected(_on_btn_press_fx):
			b.pressed.connect(_on_btn_press_fx.bind(b))

	var n: int = btns.size()
	for i: int in range(n):
		var up: Button = btns[(i - 1 + n) % n]
		var dn: Button = btns[(i + 1) % n]
		btns[i].focus_neighbor_top = up.get_path()
		btns[i].focus_neighbor_bottom = dn.get_path()
		btns[i].focus_neighbor_left = btns[i].get_path()
		btns[i].focus_neighbor_right = btns[i].get_path()

	if DEBUG:
		print("[MainMenu] decorate_buttons min_w=", min_w, " min_h=", min_h, " count=", n)

func _focus_first_usable_button() -> void:
	var btns: Array[Button] = _collect_buttons()
	for b: Button in btns:
		if not b.disabled:
			b.grab_focus()
			if DEBUG:
				print("[MainMenu] initial focus → ", b.text)
			return

func _refresh_continue_enabled() -> void:
	if _btn_continue == null:
		return
	var slot: int = _resolve_continue_slot(1)
	var has_meta: bool = false
	if "meta_exists" in SaveManager:
		has_meta = SaveManager.meta_exists(slot)
	_btn_continue.disabled = not has_meta
	_btn_continue.visible = has_meta
	if DEBUG:
		print("[MainMenu] continue -> slot=", slot, " has_meta=", has_meta, " visible=", _btn_continue.visible)

# --- Micro-animation + SFX
func _ensure_sfx() -> void:
	if sfx_hover != null and _sfx_hover_player == null:
		var p1: AudioStreamPlayer = AudioStreamPlayer.new()
		p1.name = "SFXHover"
		p1.stream = sfx_hover
		add_child(p1)
		_sfx_hover_player = p1
	if sfx_click != null and _sfx_click_player == null:
		var p2: AudioStreamPlayer = AudioStreamPlayer.new()
		p2.name = "SFXClick"
		p2.stream = sfx_click
		add_child(p2)
		_sfx_click_player = p2

func _on_btn_hover_enter(b: Button) -> void:
	_play_hover_tween(b, true)
	if _sfx_hover_player != null:
		_sfx_hover_player.play()

func _on_btn_hover_exit(b: Button) -> void:
	_play_hover_tween(b, false)

func _on_btn_focus_enter(b: Button) -> void:
	_play_focus_tween(b, true)

func _on_btn_focus_exit(b: Button) -> void:
	_play_focus_tween(b, false)

func _on_btn_press_fx(b: Button) -> void:
	if _sfx_click_player != null:
		_sfx_click_player.play()

func _play_hover_tween(b: Button, hovered: bool) -> void:
	var to_scale: Vector2 = Vector2(1.03, 1.03) if hovered else Vector2.ONE
	var tw: Tween = create_tween()
	tw.tween_property(b, "scale", to_scale, 0.08).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func _play_focus_tween(b: Button, focused: bool) -> void:
	var to_scale: Vector2 = Vector2(1.02, 1.02) if focused else Vector2.ONE
	var tw: Tween = create_tween()
	tw.tween_property(b, "scale", to_scale, 0.06).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

# ---------------- quit visibility ----------------
func _ensure_quit_button() -> void:
	if _btn_quit == null:
		return
	var on_android: bool = OS.get_name() == "Android"
	_btn_quit.visible = enable_quit_button and (not on_android)
	if DEBUG:
		print("[MainMenu] quit visible=", _btn_quit.visible, " on_android=", on_android)

# ---------------- BGM ----------------
func _start_bgm() -> void:
	var paths: Array[String] = [
		"res://audio/ui/MainMenu1.wav",
		"res://audio/ui/MainMenu2.wav",
	]
	var shuffle_tracks: bool = true
	var vol_db: float = 0.0
	var fade_s: float = 0.4
	var bus_name: String = "Master"

	# play_stream_paths(paths, shuffle, volume_db, fade_seconds, bus)
	MusicManager.play_stream_paths(
		paths,
		shuffle_tracks,
		vol_db,
		fade_s,
		bus_name
	)

# ---------------- debug (slots) ----------------
func _debug_dump_slots() -> void:
	var used: Array[int] = []
	if "list_used_slots" in SlotService:
		used = SlotService.list_used_slots()
	elif "list_present_slots" in SaveManager:
		used = SaveManager.list_present_slots(MAX_SLOTS)
	print("[MainMenu] used slots=", used)

	for s: int in used:
		var gm: Dictionary = {}
		if "read_game_if_exists" in SaveManager:
			gm = SaveManager.read_game_if_exists(s)
		if gm.is_empty():
			print("[MainMenu]  slot ", s, " (no meta)")
			continue
		var player: Dictionary = (gm.get("player", {}) as Dictionary)
		var sb: Dictionary = (player.get("stat_block", {}) as Dictionary)
		print("[MainMenu]  slot ", s, " level=", int(sb.get("level", 1)))
