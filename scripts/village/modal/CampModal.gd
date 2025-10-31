# res://scripts/village/modal/CampModal.gd
extends "res://ui/common/BaseModal.gd"
class_name CampModalPanel

const SaveMgr := preload("res://persistence/SaveManager.gd")

var _coord: Vector2i
func set_context(coord: Vector2i) -> void:
	_coord = coord

@export var slot: int = 1
var _content: Control
var _btn_close: Button
var _candidates_v: VBoxContainer
var _gold_label: Label
var _restock_label: Label


# Maps the rendered row -> original page index from SaveMgr.get_recruitment_page
var _render_index_map: Array[int] = []

func _ready() -> void:
	super._ready()
	_content = $"Panel/Margin/V/Content"
	_btn_close = $"Panel/Margin/V/Bottom/Close"
	if _btn_close and not _btn_close.pressed.is_connected(_on_close_pressed):
		_btn_close.pressed.connect(_on_close_pressed)
	_build_ui()

func _build_ui() -> void:
	_clear_children(_content)

	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 10)
	_content.add_child(root)

	var title := Label.new()
	title.text = "Camp"
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	title.add_theme_font_size_override("font_size", 22)
	root.add_child(title)

	_gold_label = Label.new()
	_gold_label.add_theme_font_size_override("font_size", 16)
	root.add_child(_gold_label)
	_update_gold_label()

	var sub := Label.new()
	sub.text = "Hire Staff (100g)"
	sub.add_theme_font_size_override("font_size", 16)
	root.add_child(sub)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	root.add_child(row)

	var btn_refresh := Button.new()
	btn_refresh.text = "Refresh Candidates"
	btn_refresh.pressed.connect(_on_refresh_pressed)
	row.add_child(btn_refresh)

	_candidates_v = VBoxContainer.new()
	_candidates_v.add_theme_constant_override("separation", 6)
	root.add_child(_candidates_v)
	
	# Apply timed restock (advances cursor if enough minutes elapsed)
	var restock := SaveMgr.apply_recruitment_restock(slot)

	#Optional: show countdown "Next restock in D:HH:MM"
	_restock_label = Label.new()
	_restock_label.add_theme_font_size_override("font_size", 14)
	_restock_label.modulate = Color(1,1,1,0.9)
	root.add_child(_restock_label)
	_update_restock_label(restock)

	_render_candidates()

func _render_candidates() -> void:
	_clear_children(_candidates_v)
	_render_index_map.clear()

	# Fetch current page (already sliding-windowed in SaveManager)
	var page: Array[Dictionary] = SaveMgr.get_recruitment_page(slot)

	# Debug: show the raw page before filtering out already-hired NPCs
	if SaveMgr.DEBUG_NPC:
		for i in page.size():
			var r: Dictionary = page[i]
			print("[CampModal] prefilter i=", i, " key=", _candidate_key(r))

	# Filter out NPCs already hired (and build source-index map)
	var pair := _filter_out_hired_with_index_map(page)
	var filtered: Array[Dictionary] = pair[0]
	var index_map: Array[int] = pair[1]
	_render_index_map = index_map

	# Debug: show the visible list + mapping back to source indices
	if SaveMgr.DEBUG_NPC:
		for j in filtered.size():
			var r2: Dictionary = filtered[j]
			print("[CampModal] postfilter j=", j, " key=", _candidate_key(r2), " source_idx=", index_map[j])

	# Render list
	var gs := SaveMgr.load_game(slot)
	var gold := int(gs.get("stash_gold", 0))
	var cost := 100

	if filtered.is_empty():
		var empty := Label.new()
		empty.text = "No candidates right now."
		_candidates_v.add_child(empty)
		return

	for i in filtered.size():
		var row: Dictionary = filtered[i]

		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 6)
		_candidates_v.add_child(hb)

		var name := Label.new()
		var race := String(row.get("race","")).capitalize()
		var sex := String(row.get("sex","")).capitalize()
		name.text = "%s  — %s / %s  (Lv 1, %s)" % [
			String(row.get("name","Nameless")),
			race, sex,
			String(row.get("rarity","COMMON"))
		]
		name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hb.add_child(name)

		var btn := Button.new()
		btn.text = "Hire (100g)"
		btn.disabled = gold < cost
		# NOTE: i is the rendered index; _render_index_map[i] translates to source index
		btn.pressed.connect(_on_hire_pressed.bind(i))
		hb.add_child(btn)



func _on_refresh_pressed() -> void:
	print("[CampModal] refresh button pressed")
	SaveMgr.refresh_recruitment_page(slot)
	var restock := SaveMgr.apply_recruitment_restock(slot)
	_update_restock_label(restock)
	_render_candidates()

func _on_hire_pressed(rendered_index: int) -> void:
	print("[CampModal] hire pressed rendered_index=", rendered_index)
	# Translate rendered row -> original page index
	var source_index := rendered_index
	if rendered_index >= 0 and rendered_index < _render_index_map.size():
		source_index = _render_index_map[rendered_index]
	print("[CampModal] hire source_index (page index)=", source_index, " map=", _render_index_map)


	var hired: Dictionary = SaveMgr.hire_candidate(source_index, slot)

	# IMPORTANT: Do NOT advance the page here. hire_candidate() already bumps the
	# recruitment cursor by ONE so only the hired slot is replaced on the page.
	# Calling refresh_recruitment_page() would jump by page_size (3) → whole new page.

	_update_gold_label()

	# If you're showing the timed-restock countdown, update it:
	#if "apply_recruitment_restock" in SaveMgr:
	#	var restock := SaveMgr.apply_recruitment_restock(slot)
	#	if has_method("_update_restock_label"):
	#		_update_restock_label(restock)

	# Re-render the current page to show the two remaining + the single new replacement
	_render_candidates()

func _on_close_pressed() -> void:
	close()

func _update_gold_label() -> void:
	var gs := SaveMgr.load_game(slot)
	var gold := int(gs.get("stash_gold", 0))
	_gold_label.text = "Stash Gold: %d" % gold

func _clear_children(n: Node) -> void:
	for c in n.get_children():
		c.queue_free()

# ---------- Filtering helpers ----------
static func _candidate_key(d: Dictionary) -> String:
	var id_s := String(d.get("id", ""))
	if id_s != "":
		return id_s
	var seed := String(d.get("appearance_seed", ""))
	var name := String(d.get("name",""))
	var race := String(d.get("race",""))
	var sex  := String(d.get("sex",""))
	return "%s|%s|%s|%s" % [seed, name, race, sex]

# Returns [filtered_list, index_map] where index_map[i] = original_index_in_page
func _filter_out_hired_with_index_map(page: Array[Dictionary]) -> Array:
	var village := SaveMgr.load_village(slot)
	var owned_keys: Dictionary = {}
	var npcs_any: Variant = village.get("npcs", [])
	if npcs_any is Array:
		for v in (npcs_any as Array):
			if v is Dictionary:
				owned_keys[_candidate_key(v as Dictionary)] = true

	var filtered: Array[Dictionary] = []
	var index_map: Array[int] = []
	for i in page.size():
		var row_any := page[i]
		if not (row_any is Dictionary):
			continue
		var row: Dictionary = row_any
		var key := _candidate_key(row)
		if not owned_keys.has(key):
			filtered.append(row)
			index_map.append(i)

	return [filtered, index_map]

func _update_restock_label(restock_info: Dictionary) -> void:
	if _restock_label == null:
		return
	var remain_min: float = float(restock_info.get("remain_min", 0.0))
	var cadence: int = int(restock_info.get("cadence_min", 720))

	var total_min: int = int(ceil(remain_min))
	var days: int = total_min / (60 * 24)
	var rem_after_days: int = total_min - days * 60 * 24
	var hours: int = rem_after_days / 60
	var mins: int = rem_after_days - hours * 60

	_restock_label.text = "Next timed restock in %dd:%02dh:%02dm (every %dh)" % [
		days, hours, mins, int(cadence / 60)
	]
