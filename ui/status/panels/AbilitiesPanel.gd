extends StatusPanel
class_name AbilitiesPanel

# Scene nodes (safe lookups)
@onready var _tabs: OptionButton = get_node_or_null(^"%TypeFilter") as OptionButton
@onready var _list: ItemList     = get_node_or_null(^"%List") as ItemList
@onready var _desc: Label        = get_node_or_null(^"%Desc") as Label

func _ready() -> void:
	# If the scene didn't have nodes, create a minimal UI so we don't crash.
	if _tabs == null or _list == null or _desc == null:
		_build_fallback_ui()

	# Ensure tabs exist and are selectable
	if _tabs.get_item_count() == 0:
		_tabs.add_item("Active", 0)
		_tabs.add_item("Passive", 1)

	# Default selection (get_selected_id can be -1 if nothing selected)
	if _tabs.get_selected_id() == -1:
		_tabs.select(0)

	# Connect once
	if not _tabs.item_selected.is_connected(_on_filter_changed):
		_tabs.item_selected.connect(_on_filter_changed)
	if not _list.item_selected.is_connected(_on_item_selected):
		_list.item_selected.connect(_on_item_selected)

func on_enter() -> void:
	# nothing special; signals are already connected in _ready
	pass

func on_exit() -> void:
	# keep connections; panel is reused between tab switches
	pass

func refresh() -> void:
	if _tabs == null or _list == null or _desc == null:
		return

	_list.clear()
	_desc.text = ""

	var rs: Dictionary = SaveManager.load_run(_slot)
	var arr_any: Variant = rs.get("abilities", [])
	var raw: Array = (arr_any as Array) if arr_any is Array else []

	var want_passive: bool = (_tabs.get_selected_id() == 1)

	for i in raw.size():
		var row_any: Variant = raw[i]
		if typeof(row_any) != TYPE_DICTIONARY:
			continue
		var a: Dictionary = row_any

		var is_passive := bool(a.get("is_passive", false))
		if want_passive != is_passive:
			continue

		var name: String = String(a.get("name",""))
		var lvl: int = int(a.get("level", 1))
		var cap: int = int(a.get("cap", lvl))
		var prog: int = int(a.get("progress", 0))
		var to_next: int = int(a.get("to_next", 100))

		var row_text: String = "%s  —  Lv %d  [%d/%d]  CAP:%d" % [name, lvl, prog, to_next, cap]
		_list.add_item(row_text)
		var idx: int = _list.get_item_count() - 1
		_list.set_item_metadata(idx, a)
		if lvl >= cap:
			_list.set_item_custom_fg_color(idx, Color(0.85, 0.80, 0.60))  # optional

	# Auto-select first row (if any) so _on_item_selected has a valid index
	if _list.get_item_count() > 0:
		_list.select(0)
		_on_item_selected(0)

func _on_filter_changed(_idx: int) -> void:
	refresh()

func _on_item_selected(idx: int) -> void:
	if idx < 0 or idx >= _list.get_item_count():
		_desc.text = ""
		return
	var meta_any: Variant = _list.get_item_metadata(idx)
	if typeof(meta_any) != TYPE_DICTIONARY:
		_desc.text = ""
		return
	var a: Dictionary = meta_any

	var cost: int = int(a.get("mp_cost", 0))
	var text: String = String(a.get("short_desc",""))
	if cost > 0:
		text = "[MP %d] %s" % [cost, text]
	_desc.text = text

# --- fallback UI if your .tscn didn’t have the nodes yet -------------------
func _build_fallback_ui() -> void:
	var root := self
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(v)

	_tabs = OptionButton.new()
	_tabs.name = "TypeFilter"
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.add_item("Active", 0)
	_tabs.add_item("Passive", 1)
	v.add_child(_tabs)

	var split := HSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(split)

	_list = ItemList.new()
	_list.name = "List"
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(_list)

	_desc = Label.new()
	_desc.name = "Desc"
	_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_desc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(_desc)
