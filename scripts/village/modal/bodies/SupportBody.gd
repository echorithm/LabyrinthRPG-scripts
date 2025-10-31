extends VBoxContainer
class_name SupportBody

## Minimal Support UI for Inn / Church / Camp / Guild (later).
## Tabs: Status(0), Services(1)
## Footer actions: [{ id="support_do", label="Use Service", enabled=active }]

const _DBG := "[SupportBody] "
func _log(msg: String) -> void: print(_DBG + msg)

# context
var building_kind: StringName = &""
var instance_id: StringName = &""
var coord: Vector2i = Vector2i.ZERO
var slot: int = 1

# state
var active: bool = true
var stash_gold: int = 0
var effects: Array[Dictionary] = []   # e.g., [{name="Healing Received", value="+8%"}]

var _shell: BuildingModalShell = null
var _current_tab: int = 0

# contract
func bind_shell(shell: BuildingModalShell) -> void:
	_shell = shell

func set_context(kind: StringName, p_instance_id: StringName, p_coord: Vector2i, p_slot: int) -> void:
	building_kind = kind
	instance_id = p_instance_id
	coord = p_coord
	slot = p_slot
	_log("set_context kind=%s iid=%s slot=%d" % [String(kind), String(p_instance_id), p_slot])

func enter(ctx: Dictionary) -> void:
	_apply_ctx(ctx)
	_render_current_tab()

func refresh(ctx: Dictionary) -> void:
	_apply_ctx(ctx)
	_render_current_tab()

func get_tabs() -> PackedStringArray:
	return PackedStringArray(["Status", "Services"])

func on_tab_changed(idx: int) -> void:
	_current_tab = idx
	_render_current_tab()

func get_footer_actions() -> Array[Dictionary]:
	var label := "Use Service"
	var arr: Array[Dictionary] = [
		{ "id": "support_do", "label": label, "enabled": active }
	]
	return arr

func on_primary_action(action_id: StringName) -> void:
	if String(action_id) == "support_do":
		_show_inline_message("Service applied!", 1200)

# internals
func _ready() -> void:
	size_flags_horizontal = Control.SIZE_FILL | Control.SIZE_EXPAND
	size_flags_vertical   = Control.SIZE_FILL | Control.SIZE_EXPAND

func _apply_ctx(ctx: Dictionary) -> void:
	active = bool(ctx.get("active", true))
	stash_gold = int(ctx.get("stash_gold", 0))
	var eff_any: Variant = ctx.get("effects", [])
	var eff: Array[Dictionary] = []
	if eff_any is Array:
		for v in (eff_any as Array):
			if v is Dictionary:
				eff.append(v)
	effects = eff
	_log("ctx active=%s gold=%d effects=%d" % [str(active), stash_gold, effects.size()])

func _render_current_tab() -> void:
	_clear()
	if _current_tab == 0:
		_render_status()
	else:
		_render_services()

func _render_status() -> void:
	var l := Label.new()
	l.text = "Support status — Active: %s — Gold: %d" % [("true" if active else "false"), stash_gold]
	add_child(l)

	if effects.is_empty():
		var e := Label.new(); e.text = "No village effects yet."
		add_child(e)
	else:
		var title := Label.new(); title.text = "Village effects:"
		add_child(title)
		for d in effects:
			var row := Label.new()
			row.text = "• %s: %s" % [String(d.get("name", "")), String(d.get("value", ""))]
			add_child(row)

func _render_services() -> void:
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_FILL | Control.SIZE_EXPAND
	v.size_flags_vertical   = Control.SIZE_FILL | Control.SIZE_EXPAND
	v.add_theme_constant_override("separation", 8)
	add_child(v)

	var hdr := Label.new()
	hdr.text = "Services"
	v.add_child(hdr)

	var hint := Label.new()
	hint.text = "Press the footer to use this building’s service."
	v.add_child(hint)

	var state := Label.new()
	state.text = active if active else "Inactive (needs staff)"
	v.add_child(state)

func _show_inline_message(text: String, ms: int = 1000) -> void:
	var lbl := Label.new()
	lbl.text = text
	add_child(lbl)
	var t := get_tree()
	if t != null:
		await t.create_timer(float(ms) / 1000.0).timeout
	lbl.queue_free()

func _clear() -> void:
	for ch in get_children():
		ch.queue_free()
