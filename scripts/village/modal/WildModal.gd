extends BaseModal
class_name WildModalPanel

signal wants_register_hit_rect(rect: Rect2)
signal wants_unregister_hit_rect(rect: Rect2)

# ---- context ----
var _coord: Vector2i = Vector2i.ZERO

@export var tile_coord: Vector2i = Vector2i.ZERO:
	set(value):
		print("[WildModal] tile_coord.set -> ", value)
		set_context(value)
	get:
		return _coord

func set_context(coord: Vector2i) -> void:
	_coord = coord
	print("[WildModal] set_context -> _coord=", _coord)

# ---- services ----
var _catalog: BaseTileCatalog = null
var _vs: Node = null                           # /root/VillageState (legacy fallback)
var _svc: TileModalService = null              # group: village_modal_service
var _build_art: BuildingArtService = null      # Building art/catalog

# ---- UI refs ----
var _content: HBoxContainer
var _left: VBoxContainer
var _tabs: TabContainer
var _terraform_page: VBoxContainer
var _build_page: VBoxContainer
var _scroll: ScrollContainer
var _grid: GridContainer
var _build_scroll: ScrollContainer
var _build_grid: GridContainer
var _right: VBoxContainer
var _current_name: Label
var _current_tex: TextureRect
var _pending_name: Label
var _pending_tex: TextureRect
var _bottom: HBoxContainer
var _terraform_btn: Button
var _build_btn: Button
var _close_btn: Button

# ---- state ----
var _current_art_id: String = ""
var _pending_art_id: String = ""
var _pending_build_id: String = ""

func _ready() -> void:
	# Let BaseModal set theme, backdrop, etc.
	super._ready()

	print("[WildModal] _ready coord=", _coord)
	_catalog = _find_catalog()
	_vs = get_node_or_null(^"/root/VillageState")
	_svc = _find_modal_service()
	_build_art = _find_building_art_service()
	print("[WildModal] services: catalog=%s  vs=%s  svc=%s  build_art=%s"
		% [str(_catalog), str(_vs), str(_svc), str(_build_art)])

	_cache_ui()
	_log_layout("after _cache_ui")
	_refresh_current()
	_populate_choices()               # Terraform choices (terrain/base art)
	_populate_build_choices()         # Build choices (buildings catalog)
	_update_terraform_enabled()
	_update_build_enabled()
	_log_layout("after populate+enable")

# -----------------------------------------------------------------------------
# UI cache/bind (supports both: new Tabs layout and legacy 'Panel/Margin/V')
# -----------------------------------------------------------------------------
func _cache_ui() -> void:
	var root_v := get_node_or_null(^"Panel/Margin/V") as VBoxContainer
	if root_v == null:
		push_error("[WildModal] layout error: Panel/Margin/V not found")
		return

	# --- ensure the whole chain expands ---------------------------------------
	root_v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_v.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var _title := root_v.get_node_or_null(^"Title") as Control
	if _title != null:
		_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_title.size_flags_vertical = 0

		# --- Large X close button in the title bar (mobile-friendly) ----------
		var title_box := _title as BoxContainer
		if title_box != null:
			var close_x := title_box.get_node_or_null(^"CloseX") as Button
			if close_x == null:
				close_x = Button.new()
				close_x.name = "CloseX"
				close_x.text = "✕"
				close_x.focus_mode = Control.FOCUS_NONE
				close_x.custom_minimum_size = Vector2(
					float(min_touch_target_px),
					float(min_touch_target_px)
				)
				close_x.size_flags_horizontal = 0
				close_x.size_flags_vertical = 0
				close_x.mouse_filter = Control.MOUSE_FILTER_STOP
				title_box.add_child(close_x)
				title_box.move_child(close_x, title_box.get_child_count() - 1)

			if not close_x.pressed.is_connected(_on_close_pressed):
				close_x.pressed.connect(_on_close_pressed)

	# --- base sections ---------------------------------------------------------
	_content = root_v.get_node(^"Content") as HBoxContainer
	_bottom  = root_v.get_node(^"Bottom")  as HBoxContainer
	_left    = _content.get_node(^"Left")  as VBoxContainer

	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_left.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# --- Tabs: find or create --------------------------------------------------
	_tabs = _left.get_node_or_null(^"Tabs") as TabContainer
	if _tabs == null:
		_tabs = TabContainer.new()
		_tabs.name = "Tabs"
		_left.add_child(_tabs)
		_left.move_child(_tabs, 0)

	_terraform_page = _tabs.get_node_or_null(^"Terraform") as VBoxContainer
	if _terraform_page == null:
		_terraform_page = VBoxContainer.new()
		_terraform_page.name = "Terraform"
		_tabs.add_child(_terraform_page)

	_build_page = _tabs.get_node_or_null(^"Build") as VBoxContainer
	if _build_page == null:
		_build_page = VBoxContainer.new()
		_build_page.name = "Build"
		_tabs.add_child(_build_page)

	# Adopt stray nodes that might be under Tabs instead of Terraform.
	var stray_scroll_tf := _tabs.get_node_or_null(^"Scroll") as ScrollContainer
	if stray_scroll_tf != null:
		_tabs.remove_child(stray_scroll_tf)
		_terraform_page.add_child(stray_scroll_tf)

	var stray_grid_tf := _tabs.get_node_or_null(^"Grid") as GridContainer
	if stray_grid_tf != null:
		_tabs.remove_child(stray_grid_tf)
		var ensure_scroll_tf := _terraform_page.get_node_or_null(^"Scroll") as ScrollContainer
		if ensure_scroll_tf == null:
			ensure_scroll_tf = ScrollContainer.new()
			ensure_scroll_tf.name = "Scroll"
			_terraform_page.add_child(ensure_scroll_tf)
		ensure_scroll_tf.add_child(stray_grid_tf)

	# Terraform tab: Scroll/Grid (adopt legacy Left/Scroll/Grid if present)
	_scroll = _terraform_page.get_node_or_null(^"Scroll") as ScrollContainer
	if _scroll == null:
		var legacy_scroll := _left.get_node_or_null(^"Scroll") as ScrollContainer
		if legacy_scroll != null:
			legacy_scroll.get_parent().remove_child(legacy_scroll)
			_scroll = legacy_scroll
			_terraform_page.add_child(_scroll)
		else:
			_scroll = ScrollContainer.new()
			_scroll.name = "Scroll"
			_terraform_page.add_child(_scroll)

	_grid = _scroll.get_node_or_null(^"Grid") as GridContainer
	if _grid == null:
		_grid = GridContainer.new()
		_grid.name = "Grid"
		_scroll.add_child(_grid)

	# Build tab: Scroll/Grid (create if missing)
	_build_scroll = _build_page.get_node_or_null(^"Scroll") as ScrollContainer
	if _build_scroll == null:
		_build_scroll = ScrollContainer.new()
		_build_scroll.name = "Scroll"
		_build_page.add_child(_build_scroll)

	_build_grid = _build_scroll.get_node_or_null(^"Grid") as GridContainer
	if _build_grid == null:
		_build_grid = GridContainer.new()
		_build_grid.name = "Grid"
		_build_scroll.add_child(_build_grid)

	# --- Right/preview ---------------------------------------------------------
	_right        = _content.get_node(^"Right") as VBoxContainer
	_current_tex  = _right.get_node(^"CurrentBox/CurrentTex") as TextureRect
	_current_name = _right.get_node(^"CurrentBox/CurrentName") as Label
	_pending_tex  = _right.get_node(^"PreviewBox/PendingTex") as TextureRect
	_pending_name = _right.get_node(^"PreviewBox/PendingName") as Label

	_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_right.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# --- size flags for tabs/pages/scrolls/grids -------------------------------
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_terraform_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_terraform_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_build_page.size_flags_vertical = Control.SIZE_EXPAND_FILL

	for sc in [_scroll, _build_scroll]:
		if sc == null:
			continue
		# No horizontal scrolling; vertical scroll is drag-only with no bar.
		sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
		sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sc.size_flags_vertical = Control.SIZE_EXPAND_FILL

	for g in [_grid, _build_grid]:
		g.columns = 1
		g.add_theme_constant_override("h_separation", 8)
		g.add_theme_constant_override("v_separation", 4)
		g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		g.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# --- Bottom bar ------------------------------------------------------------
	_bottom.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bottom.size_flags_vertical = 0
	_bottom.alignment = BoxContainer.ALIGNMENT_END
	_bottom.add_theme_constant_override("separation", 8)

	if _bottom.get_node_or_null(^"Spacer") == null:
		var spacer := Control.new()
		spacer.name = "Spacer"
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_bottom.add_child(spacer)
		_bottom.move_child(spacer, 0)

	_build_btn     = _bottom.get_node(^"Build")     as Button
	_terraform_btn = _bottom.get_node(^"Terraform") as Button
	_close_btn     = _bottom.get_node(^"Close")     as Button

	if _close_btn.text.strip_edges() == "":
		_close_btn.text = "Close"
	if _build_btn.text.strip_edges() == "":
		_build_btn.text = "Build"
	if _terraform_btn.text.strip_edges() == "":
		_terraform_btn.text = "Terraform"

	var compact := Vector2(104, 40)
	for b in [_close_btn, _build_btn, _terraform_btn]:
		b.size_flags_horizontal = 0
		b.size_flags_vertical = 0
		b.custom_minimum_size = compact
		b.focus_mode = Control.FOCUS_NONE

	# Signals once
	if not _build_btn.pressed.is_connected(_on_build_pressed):
		_build_btn.pressed.connect(_on_build_pressed)
	if not _terraform_btn.pressed.is_connected(_on_terraform_pressed):
		_terraform_btn.pressed.connect(_on_terraform_pressed)
	if not _close_btn.pressed.is_connected(_on_close_pressed):
		_close_btn.pressed.connect(_on_close_pressed)

	# Show Terraform tab by default
	_tabs.current_tab = 0

# -----------------------------------------------------------------------------
# Refresh / data
# -----------------------------------------------------------------------------
func _refresh_current() -> void:
	_current_art_id = ""
	_pending_art_id = ""
	_pending_build_id = ""

	var got_from := "none"

	# Authoritative: TileModalService (do NOT auto-fallback if service exists)
	if _svc != null and _svc.has_method("get_tile_at"):
		var t2_any: Variant = _svc.call("get_tile_at", _coord)
		if t2_any is Dictionary:
			var t_svc: Dictionary = t2_any
			_current_art_id = String(t_svc.get("base_art_id", ""))
			got_from = "TileModalService"

	# Only if service is missing entirely, use VillageState.
	if got_from == "none" and _vs != null and _vs.has_method("get_tile"):
		var t_any: Variant = _vs.call("get_tile", _coord)
		if t_any is Dictionary:
			var t_vs: Dictionary = t_any
			_current_art_id = String(t_vs.get("base_art_id", ""))
			got_from = "VillageState"

	print("[WildModal] _refresh_current: got_from=%s  coord=%s  current_art_id='%s'"
		% [got_from, str(_coord), _current_art_id])

	_update_current_preview()
	_update_right_preview()
	_update_terraform_enabled()
	_update_build_enabled()

func _populate_choices() -> void:
	if _catalog == null:
		print("[WildModal] populate: missing catalog")
		return

	# Clear previous terraform choices
	for c in _grid.get_children():
		c.queue_free()

	var ids: Array[String] = []
	var raw_ids: Variant = _catalog.get_ids()
	if raw_ids is PackedStringArray:
		for s in (raw_ids as PackedStringArray):
			ids.append(String(s))
	elif raw_ids is Array:
		for v in (raw_ids as Array):
			ids.append(String(v))

	var rows: Array[Dictionary] = []
	for id in ids:
		var def: BaseTileCatalog.TileDef = _catalog.get_def(id)
		if def.file_path == "":
			continue
		var name := (def.display_name if def.display_name != "" else def.id)
		rows.append({ "id": def.id, "name": name })
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["name"]).naturalnocasecmp_to(String(b["name"])) < 0
	)

	for r in rows:
		var art_id := String(r["id"])
		var name := String(r["name"])
		var tex := _load_thumbnail_for_id(art_id)

		var btn := Button.new()
		btn.name = "Choice_" + art_id
		btn.text = name
		btn.icon = tex
		btn.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
		btn.expand_icon = false
		btn.custom_minimum_size = Vector2(260, 44)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.focus_mode = Control.FOCUS_NONE
		btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		btn.mouse_filter = Control.MOUSE_FILTER_STOP
		btn.flat = false
		btn.pressed.connect(_on_pick.bind(art_id))
		_grid.add_child(btn)

	print("[WildModal] populate: grid children=%d" % [_grid.get_child_count()])

func _populate_build_choices() -> void:
	if _build_art == null:
		print("[WildModal] build populate: missing BuildingArtService")
		return

	# Clear previous build choices
	for c in _build_grid.get_children():
		c.queue_free()

	var ids: Array[String] = _build_art.get_building_ids()
	ids.sort_custom(func(a: String, b: String) -> bool:
		return _build_art.get_display_name(a).naturalnocasecmp_to(_build_art.get_display_name(b)) < 0
	)

	for bid in ids:
		var name: String = _build_art.get_display_name(bid)
		var tex: Texture2D = _load_building_thumbnail(bid)

		var btn := Button.new()
		btn.name = "BuildChoice_" + bid
		btn.text = name
		btn.icon = tex
		btn.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
		btn.expand_icon = false
		btn.custom_minimum_size = Vector2(260, 44)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.focus_mode = Control.FOCUS_NONE
		btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		btn.mouse_filter = Control.MOUSE_FILTER_STOP
		btn.flat = false
		btn.pressed.connect(_on_build_pick.bind(bid))
		_build_grid.add_child(btn)

	print("[WildModal] build populate: grid children=%d" % [_build_grid.get_child_count()])

func _load_thumbnail_for_id(art_id: String) -> Texture2D:
	var def: BaseTileCatalog.TileDef = _catalog.get_def(art_id)
	if def.file_path == "":
		return null
	var res: Resource = load(def.file_path)
	if not (res is Texture2D):
		return null
	var t := res as Texture2D
	var img := t.get_image()
	if img == null:
		return t
	var max_dim: int = max(img.get_width(), img.get_height())
	if max_dim > 48:
		var scale := 40.0 / float(max_dim)
		var new_w: int = int(round(float(img.get_width()) * scale))
		var new_h: int = int(round(float(img.get_height()) * scale))
		var clone := img.duplicate()
		clone.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)
		var resized := ImageTexture.create_from_image(clone)
		return resized
	return t

func _load_building_thumbnail(bid: String) -> Texture2D:
	if _build_art == null:
		return null
	var path: String = _build_art.get_art_path(bid)
	if path == "":
		return null
	var res: Resource = load(path)
	if not (res is Texture2D):
		return null
	var t := res as Texture2D
	var img := t.get_image()
	if img == null:
		return t
	var max_dim: int = max(img.get_width(), img.get_height())
	if max_dim > 48:
		var scale := 40.0 / float(max_dim)
		var new_w: int = int(round(float(img.get_width()) * scale))
		var new_h: int = int(round(float(img.get_height()) * scale))
		var clone := img.duplicate()
		clone.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)
		return ImageTexture.create_from_image(clone)
	return t

# -----------------------------------------------------------------------------
# Preview helpers
# -----------------------------------------------------------------------------
func _update_current_preview() -> void:
	_set_named_preview(_current_name, _current_tex, _current_art_id)

func _update_right_preview() -> void:
	# Show pending terraform art if set, else pending build, else current.
	var id_to_show := _pending_art_id
	if id_to_show == "":
		id_to_show = _pending_build_id
	if id_to_show == "":
		id_to_show = _current_art_id
	_set_named_preview(_pending_name, _pending_tex, id_to_show)

func _set_named_preview(lbl: Label, texr: TextureRect, art_id: String) -> void:
	if lbl == null or texr == null:
		return
	if _catalog == null and _build_art == null:
		lbl.text = (art_id if art_id != "" else "—")
		texr.texture = null
		return

	var shown: String = "—"
	var tex: Texture2D = null

	# Prefer BaseTileCatalog for terraform ids; fall back to building catalog.
	if _catalog != null:
		var def: BaseTileCatalog.TileDef = _catalog.get_def(art_id)
		if def != null and (def.id != "" or def.display_name != ""):
			shown = (def.display_name if def.display_name != "" else (def.id if def.id != "" else "—"))
			if def.file_path != "":
				var res: Resource = load(def.file_path)
				if res is Texture2D:
					tex = res as Texture2D

	if tex == null and _build_art != null:
		if art_id != "":
			shown = _build_art.get_display_name(art_id)
			var p: String = _build_art.get_art_path(art_id)
			if p != "":
				var res2: Resource = load(p)
				if res2 is Texture2D:
					tex = res2 as Texture2D

	lbl.text = shown
	texr.texture = tex
	print("[WildModal] preview -> id='%s' shown='%s' tex=%s" % [art_id, shown, str(tex)])

func _update_terraform_enabled() -> void:
	if _terraform_btn == null:
		return
	var disabled := (_pending_art_id == "" or _pending_art_id == _current_art_id)
	_terraform_btn.disabled = disabled
	print("[WildModal] terraform enabled=", not disabled, " (current='", _current_art_id, "' pending='", _pending_art_id, "')")

func _update_build_enabled() -> void:
	if _build_btn == null:
		return
	var disabled: bool = (_pending_build_id == "")
	_build_btn.disabled = disabled
	print("[WildModal] build enabled=", not disabled, " (pending_build='", _pending_build_id, "')")

# -----------------------------------------------------------------------------
# Choice handling
# -----------------------------------------------------------------------------
func _on_pick(art_id: String) -> void:
	_pending_art_id = art_id
	_pending_build_id = ""  # clear build selection when picking terraform
	print("[WildModal] pick -> pending='", _pending_art_id, "'")
	_update_right_preview()
	_update_terraform_enabled()
	_update_build_enabled()

func _on_build_pick(bid: String) -> void:
	_pending_build_id = bid
	_pending_art_id = ""  # clear terraform selection when picking build
	print("[WildModal] build pick -> pending='", _pending_build_id, "'")
	# Update preview with building info
	if _pending_name != null:
		_pending_name.text = (_build_art.get_display_name(bid) if _build_art != null else bid)
	if _pending_tex != null:
		_pending_tex.texture = _load_building_thumbnail(bid)
	_update_right_preview()
	_update_build_enabled()
	_update_terraform_enabled()

func _on_terraform_pressed() -> void:
	if _pending_art_id == "" or _pending_art_id == _current_art_id:
		print("[WildModal] terraform pressed with no-op (pending empty or same)")
		return
	print("[WildModal] Terraform button clicked at ", _coord, " pending='", _pending_art_id, "' current='", _current_art_id, "'")

	if _svc != null:
		_svc.apply_terraform(_coord, _pending_art_id)
		print("[WildModal] terraform via service OK -> closing")
		_on_close_pressed()
		return

	# Legacy fallback (rarely used now)
	if _vs != null:
		if _vs.has_method("set_tile_art"):
			_vs.call("set_tile_art", _coord, _pending_art_id)
		if _vs.has_method("save_current"):
			_vs.call("save_current")

	_current_art_id = _pending_art_id
	_pending_art_id = ""
	_update_current_preview()
	_update_right_preview()
	_update_terraform_enabled()
	_update_build_enabled()

func _on_build_pressed() -> void:
	if _pending_build_id == "":
		print("[WildModal] Build pressed with no selection")
		return
	print("[WildModal] Build button clicked at ", _coord, " pending='", _pending_build_id, "'")
	if _svc != null:
		_svc.apply_build(_coord, _pending_build_id)
		print("[WildModal] build via service OK -> closing")
		_on_close_pressed()
		return
	print("[WildModal] WARN: no TileModalService; build aborted")

func _on_close_pressed() -> void:
	print("[WildModal] close pressed")
	# BaseModal.close() handles backdrop, pause, and emits "closed"
	close()

# -----------------------------------------------------------------------------
# Finds
# -----------------------------------------------------------------------------
func _find_catalog() -> BaseTileCatalog:
	var n: Node = get_node_or_null(^"/root/BaseTileCatalog")
	if n is BaseTileCatalog:
		return n as BaseTileCatalog
	var root: Node = get_tree().get_current_scene()
	if root == null:
		return null
	var q: Array[Node] = []
	q.append(root)
	while not q.is_empty():
		var it: Node = q.pop_front() as Node
		if it is BaseTileCatalog:
			return it as BaseTileCatalog
		for c in it.get_children():
			q.append(c)
	return null

func _find_building_art_service() -> BuildingArtService:
	var root := get_tree().get_current_scene()
	if root == null:
		return null
	var q: Array[Node] = []
	q.append(root)
	while not q.is_empty():
		var it: Node = q.pop_front()
		if it is BuildingArtService:
			return it as BuildingArtService
		for c in it.get_children():
			q.append(c)
	return null

func _find_modal_service() -> TileModalService:
	var g: Array[Node] = get_tree().get_nodes_in_group("village_modal_service")
	if g.size() > 0 and g[0] is TileModalService:
		return g[0] as TileModalService
	var root := get_tree().get_current_scene()
	if root == null:
		return null
	var q: Array[Node] = []
	q.append(root)
	while not q.is_empty():
		var it: Node = q.pop_front()
		if it is TileModalService:
			return it as TileModalService
		for c in it.get_children():
			q.append(c)
	return null

# -----------------------------------------------------------------------------
# debug helpers
# -----------------------------------------------------------------------------
func _log_layout(when: String) -> void:
	if _content == null:
		return
	print("[WildModal] layout(%s): content.size=%s left.size=%s right.size=%s bottom.size=%s" %
		[when, str(_content.size), str(_left.size), str(_right.size), str(_bottom.size)])
	print("  terraform.grid.children=%d  terraform.grid.size=%s" %
		[_grid.get_child_count(), str(_grid.size)])
	print("  build.grid.children=%d      build.grid.size=%s" %
		[_build_grid.get_child_count(), str(_build_grid.size)])
	print("  buttons: build='%s' tform='%s' close='%s' | widths=(%d, %d, %d)" %
		[_build_btn.text, _terraform_btn.text, _close_btn.text,
		 int(_build_btn.size.x), int(_terraform_btn.size.x), int(_close_btn.size.x)])
