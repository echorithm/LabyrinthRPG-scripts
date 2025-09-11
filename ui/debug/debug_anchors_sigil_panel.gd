extends Control
class_name DebugAnchorsSigilPanel
## A small, self-constructing debug UI to inspect anchors/segments/sigil and poke them.
## Drop this Control anywhere (even empty scene). It builds its own VBox with buttons.

const _ASeg := preload("res://persistence/services/anchor_segment_service.gd")
const _Sig  := preload("res://persistence/services/sigil_service.gd")

@export var slot: int = 1

var _info: Label
var _sig: Label

func _ready() -> void:
	name = "DebugAnchorsSigilPanel"
	set_anchors_preset(Control.LAYOUT_FULL_RECT)

	var root := VBoxContainer.new()
	root.anchor_left = 0; root.anchor_top = 0
	root.anchor_right = 1; root.anchor_bottom = 1
	root.grow_horizontal = Control.GROW_DIRECTION_BOTH
	root.grow_vertical = Control.GROW_DIRECTION_BOTH
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root)

	var title := Label.new()
	title.text = "World Anchors / Segments / Sigil"
	title.add_theme_font_size_override("font_size", 18)
	root.add_child(title)

	_info = Label.new()
	_info.text = ""
	root.add_child(_info)

	var hb := HBoxContainer.new()
	root.add_child(hb)

	var b_unlock := Button.new()
	b_unlock.text = "Unlock Anchor (Current Segment Start)"
	b_unlock.pressed.connect(_on_unlock_anchor)
	hb.add_child(b_unlock)

	var b_toggle_drained := Button.new()
	b_toggle_drained.text = "Toggle Segment Drained"
	b_toggle_drained.pressed.connect(_on_toggle_drained)
	hb.add_child(b_toggle_drained)

	var b_toggle_boss := Button.new()
	b_toggle_boss.text = "Toggle Boss Sigil"
	b_toggle_boss.pressed.connect(_on_toggle_boss)
	hb.add_child(b_toggle_boss)

	_sig = Label.new()
	_sig.text = ""
	root.add_child(_sig)

	var hb2 := HBoxContainer.new()
	root.add_child(hb2)

	var b_kill := Button.new()
	b_kill.text = "+1 Elite Kill"
	b_kill.pressed.connect(_on_elite_kill)
	hb2.add_child(b_kill)

	var b_consume := Button.new()
	b_consume.text = "Consume Sigil Charge"
	b_consume.pressed.connect(_on_consume)
	hb2.add_child(b_consume)

	var b_refresh := Button.new()
	b_refresh.text = "Refresh"
	b_refresh.pressed.connect(_refresh)
	root.add_child(b_refresh)

	_refresh()

func _refresh() -> void:
	var cur_floor: int = SaveManager.get_current_floor(slot)
	var seg_id: int = _ASeg.segment_id_for_floor(cur_floor)

	var anchors: Array = _ASeg.list_anchors(slot)
	var seg: Dictionary = _ASeg.get_segment(seg_id, slot)

	_info.text = "Floor=%d | Segment=%d [%d..%d]\nAnchors=%s\nSegment: drained=%s, boss_sigil=%s" % [
		cur_floor, seg_id, _ASeg.segment_start_floor(seg_id), _ASeg.segment_end_floor(seg_id),
		str(anchors), str(bool(seg.get("drained", false))), str(bool(seg.get("boss_sigil", false)))
	]

	_S_refresh_sigil()

func _S_refresh_sigil() -> void:
	var cur_floor: int = SaveManager.get_current_floor(slot)
	_Sig.ensure_segment_for_floor(cur_floor, 4, slot)
	var pr: Dictionary = _Sig.get_progress(slot)
	_sig.text = "Sigil: segment=%d, kills=%d/%d, charged=%s" % [
		int(pr.get("segment_id", 0)), int(pr.get("kills", 0)),
		int(pr.get("required", 0)), str(bool(pr.get("charged", false)))
	]

func _on_unlock_anchor() -> void:
	var cur_floor: int = SaveManager.get_current_floor(slot)
	var start_f: int = _ASeg.unlock_anchor_for_floor(cur_floor, slot)
	print("[DBG] Unlocked anchor at floor ", start_f)
	_refresh()

func _on_toggle_drained() -> void:
	var cur_floor: int = SaveManager.get_current_floor(slot)
	var seg: Dictionary = _ASeg.get_segment(_ASeg.segment_id_for_floor(cur_floor), slot)
	seg["drained"] = not bool(seg.get("drained", false))
	_ASeg.set_segment(seg, slot)
	_refresh()

func _on_toggle_boss() -> void:
	var cur_floor: int = SaveManager.get_current_floor(slot)
	var seg: Dictionary = _ASeg.get_segment(_ASeg.segment_id_for_floor(cur_floor), slot)
	seg["boss_sigil"] = not bool(seg.get("boss_sigil", false))
	_ASeg.set_segment(seg, slot)
	_refresh()

func _on_elite_kill() -> void:
	_Sig.notify_elite_killed(slot)
	_S_refresh_sigil()

func _on_consume() -> void:
	_Sig.consume_charge(slot)
	_S_refresh_sigil()
