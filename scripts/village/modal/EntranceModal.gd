# res://scripts/village/modal/EntranceModal.gd
extends "res://ui/common/BaseModal.gd"
class_name EntranceModalPanel

@export var main_scene: PackedScene   # Set this in EntranceModal.tscn

# Context
var _coord: Vector2i
func set_context(c: Vector2i) -> void:
	_coord = c

# Cached nodes
var _content: Control
var _btn_close: Button
var _floor_list: OptionButton
var _btn_enter: Button

func _ready() -> void:
	super._ready()
	_content = $"Panel/Margin/V/Content"
	_btn_close = $"Panel/Margin/V/Bottom/Close"

	var title := $"Panel/Margin/V/Title" as Label
	if title:
		title.text = "Dungeon Entrance"

	if _btn_close and not _btn_close.pressed.is_connected(_on_close_pressed):
		_btn_close.pressed.connect(_on_close_pressed)

	_build_ui()
	_refresh()

# ---------------- UI ----------------

func _build_ui() -> void:
	_clear_children(_content)

	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 6)
	_content.add_child(v)

	var blurb := Label.new()
	blurb.text = "Entrance tile. Choose a floor and enter the labyrinth."
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD
	v.add_child(blurb)

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 6)
	v.add_child(row)

	_floor_list = OptionButton.new()
	_floor_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_floor_list)

	_btn_enter = Button.new()
	_btn_enter.text = "Enter Labyrinth"
	_btn_enter.disabled = true
	_btn_enter.pressed.connect(_on_enter_clicked)
	row.add_child(_btn_enter)

	var hint := Label.new()
	hint.text = "Unlocked teleports appear every 3 floors once you’ve reached them."
	hint.modulate = Color(1, 1, 1, 0.7)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	v.add_child(hint)

func _refresh() -> void:
	_floor_list.clear()
	var floors := _list_entrance_floors()
	for f in floors:
		_floor_list.add_item("Floor %d" % f, f)
	_btn_enter.disabled = _floor_list.item_count == 0
	if _floor_list.item_count > 0:
		_floor_list.select(_floor_list.item_count - 1)

func _list_entrance_floors() -> Array[int]:
	var out: Array[int] = [1]
	var gs := SaveManager.load_game()
	var max_t: int = 1
	if gs.has("highest_teleport_floor"):
		max_t = max(1, int(gs["highest_teleport_floor"]))
	var f := 4
	while f <= max_t:
		out.append(f)
		f += 3
	return out

# ---------------- Actions ----------------

func _on_enter_clicked() -> void:
	if _floor_list.item_count == 0:
		return
	var floor: int = _floor_list.get_selected_id()
	if floor <= 0:
		return

	SaveManager.start_or_refresh_run_from_meta()
	SaveManager.set_run_floor(floor)
	var _BS := preload("res://persistence/services/buff_service.gd")
	_BS.on_run_start()

	# Ensure not paused for the next scene
	if get_tree().paused:
		get_tree().paused = false

	if main_scene != null:
		get_tree().call_deferred("change_scene_to_packed", main_scene)
	else:
		push_warning("[EntranceModalPanel] main_scene not assigned; cannot enter.")

	_close_modal_deferred()

func _on_close_pressed() -> void:
	close()

# ---------------- Helpers ----------------

func _close_modal_deferred() -> void:
	var svc: Node = _find_modal_service()
	if svc != null and svc.has_method("close_current"):
		svc.call_deferred("close_current")

func _find_modal_service() -> Node:
	var nodes: Array[Node] = get_tree().get_nodes_in_group("village_modal_service")
	return nodes[0] if nodes.size() > 0 else null

func _clear_children(n: Node) -> void:
	for c in n.get_children():
		c.queue_free()
