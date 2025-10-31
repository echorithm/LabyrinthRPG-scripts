extends StatusPanel
class_name EquipmentPanel

const BODY_TEXT: Color = Color(0.88, 0.88, 0.90, 1.0)

const _S := preload("res://persistence/util/save_utils.gd")
const EquipmentService := preload("res://persistence/services/equipment_service.gd")
const AffixService := preload("res://scripts/items/AffixService.gd")

# UI nodes
var _list: ItemList
var _name: Label
var _stats: Label
var _btn_use: Button
var _btn_unequip: Button

# state
var _slot_order: PackedStringArray = [
	"head","chest","legs","boots",
	"mainhand","offhand","ring1","ring2","amulet"
]
var _selected_slot: String = ""

# -------------------------------------------------------------------
# lifecycle
# -------------------------------------------------------------------
func _ready() -> void:
	_resolve_nodes()
	_style_defaults()

func on_enter() -> void:
	_resolve_nodes()
	_style_defaults()

	# signals
	if _list:
		if not _list.item_selected.is_connected(_on_list_selected):
			_list.item_selected.connect(_on_list_selected)
		if not _list.item_activated.is_connected(_on_list_activated):
			_list.item_activated.connect(_on_list_activated)

	if _btn_use and not _btn_use.pressed.is_connected(_on_use_pressed):
		_btn_use.pressed.connect(_on_use_pressed)
	if _btn_unequip and not _btn_unequip.pressed.is_connected(_on_unequip_pressed):
		_btn_unequip.pressed.connect(_on_unequip_pressed)

	var rs: Node = get_node_or_null(^"/root/RunState")
	if rs and not rs.changed.is_connected(_on_run_changed):
		rs.changed.connect(_on_run_changed)

	refresh()

func on_exit() -> void:
	if _list:
		if _list.item_selected.is_connected(_on_list_selected):
			_list.item_selected.disconnect(_on_list_selected)
		if _list.item_activated.is_connected(_on_list_activated):
			_list.item_activated.disconnect(_on_list_activated)
	if _btn_use and _btn_use.pressed.is_connected(_on_use_pressed):
		_btn_use.pressed.disconnect(_on_use_pressed)
	if _btn_unequip and _btn_unequip.pressed.is_connected(_on_unequip_pressed):
		_btn_unequip.pressed.disconnect(_on_unequip_pressed)
	var rs: Node = get_node_or_null(^"/root/RunState")
	if rs and rs.changed.is_connected(_on_run_changed):
		rs.changed.disconnect(_on_run_changed)

# -------------------------------------------------------------------
# refresh / ui
# -------------------------------------------------------------------
func refresh() -> void:
	if _list == null:
		return

	_list.clear()
	_selected_slot = ""
	if _name:  _name.text = ""
	if _stats: _stats.text = ""
	if _btn_use: _btn_use.disabled = true
	if _btn_unequip: _btn_unequip.disabled = true

	var rs_d: Dictionary = SaveManager.load_run(SaveManager.DEFAULT_SLOT)
	var eq: Dictionary = (_S.dget(rs_d, "equipment", {}) as Dictionary)
	var inv: Array = (_S.dget(rs_d, "inventory", []) as Array)
	var bank: Dictionary = (_S.dget(rs_d, "equipped_bank", {}) as Dictionary)

	for slot_name in _slot_order:
		var uid: String = str(_S.dget(eq, slot_name, ""))
		var row_text: String = ""
		var fg: Color = BODY_TEXT

		if uid.is_empty():
			row_text = "%s: (Empty)" % slot_name.capitalize()
		else:
			var it: Dictionary = _find_item_by_uid(inv, bank, uid)
			if it.is_empty():
				row_text = "%s: (Missing)" % slot_name.capitalize()
			else:
				var id: String = str(_S.dget(it, "id", ""))
				var rar_long: String = str(_S.dget(it, "rarity", ""))
				var base_name: String = ItemNames.display_name(id)
				var pretty: String = base_name
				var aff_any: Variant = _S.dget(it, "affixes", [])
				if aff_any is Array:
					var aff: Array = aff_any as Array
					if aff.size() > 0:
						pretty = AffixService.build_display_name(base_name, aff, _rar_code(rar_long), [id, rar_long])
				row_text = "%s: %s%s" % [
					slot_name.capitalize(),
					pretty,
					("" if rar_long.is_empty() else " (%s)" % rar_long)
				]
				if not rar_long.is_empty():
					fg = ItemNames.rarity_color(rar_long)

		_list.add_item(row_text)
		var idx: int = _list.get_item_count() - 1
		_list.set_item_metadata(idx, slot_name)
		_list.set_item_custom_fg_color(idx, fg)

# helper: resolve item by uid (prefer bank, fallback inventory)
func _find_item_by_uid(inv: Array, bank: Dictionary, uid: String) -> Dictionary:
	if bank.has(uid) and bank[uid] is Dictionary:
		return (bank[uid] as Dictionary).duplicate(true)
	# fallback (shouldn’t be needed normally)
	for it_any in inv:
		if it_any is Dictionary:
			var it: Dictionary = it_any
			if str(_S.dget(it, "uid", "")) == uid:
				return it.duplicate(true)
	return {}

# -------------------------------------------------------------------
# selection & actions
# -------------------------------------------------------------------
func _on_list_selected(row: int) -> void:
	var meta_any: Variant = _list.get_item_metadata(row) if _list else null
	if typeof(meta_any) == TYPE_STRING:
		_selected_slot = str(meta_any)
		_update_buttons_and_details(_selected_slot)

func _on_list_activated(row: int) -> void:
	_on_list_selected(row)
	_on_unequip_pressed()

func _update_buttons_and_details(slot_name: String) -> void:
	if _btn_use: _btn_use.disabled = true  # no slot-using right now
	if _btn_unequip: _btn_unequip.disabled = true
	if _name: _name.text = ""
	if _stats: _stats.text = ""

	if slot_name.is_empty():
		return

	var rs_d: Dictionary = SaveManager.load_run(SaveManager.DEFAULT_SLOT)
	var eq: Dictionary = (_S.dget(rs_d, "equipment", {}) as Dictionary)
	var inv: Array = (_S.dget(rs_d, "inventory", []) as Array)
	var bank: Dictionary = (_S.dget(rs_d, "equipped_bank", {}) as Dictionary)

	var uid: String = str(_S.dget(eq, slot_name, ""))
	if uid.is_empty():
		if _name:  _name.text = "%s: (Empty)" % slot_name.capitalize()
		if _stats: _stats.text = ""
		return

	var it: Dictionary = _find_item_by_uid(inv, bank, uid)
	if it.is_empty():
		if _name:  _name.text = "%s: (Missing)" % slot_name.capitalize()
		if _stats: _stats.text = ""
		return

	# Fill details
	var id: String = str(_S.dget(it, "id", ""))
	var rar: String = str(_S.dget(it, "rarity", ""))
	var ilvl: int = int(_S.dget(it, "ilvl", 1))
	var dmax: int = int(_S.dget(it, "durability_max", 0))
	var dcur: int = int(_S.dget(it, "durability_current", dmax))
	var arch: String = str(_S.dget(it, "archetype", ""))
	var wt: float = float(_S.dget(it, "weight", 0.0))

	# Pretty/flavored name
	var base_name: String = ItemNames.display_name(id)
	var pretty: String = base_name
	var aff_any: Variant = _S.dget(it, "affixes", [])
	if aff_any is Array:
		var aff: Array = aff_any as Array
		if aff.size() > 0:
			pretty = AffixService.build_display_name(base_name, aff, _rar_code(rar), [id, rar])

	if _name:
		_name.text = pretty + ("" if rar.is_empty() else " (%s)" % rar)
		_name.add_theme_color_override("font_color", ItemNames.rarity_color(rar) if not rar.is_empty() else BODY_TEXT)

	if _stats:
		var block: String = "Archetype: %s\nilvl: %d\nDurability: %d / %d\nWeight: %.1f" % [arch, ilvl, dcur, dmax, wt]
		var affix_lines: PackedStringArray = _affix_lines_for_item(it)
		if affix_lines.size() > 0:
			block += "\n\nAffixes:"
			for s in affix_lines:
				block += "\n- " + s
		_stats.text = block

	if _btn_unequip:
		_btn_unequip.disabled = false

# -------------------------------------------------------------------
# buttons
# -------------------------------------------------------------------
func _on_use_pressed() -> void:
	# no slot use for equipment panel yet
	pass

func _on_unequip_pressed() -> void:
	if _selected_slot.is_empty():
		return
	var ok: bool = EquipmentService.unequip_slot(_selected_slot, SaveManager.DEFAULT_SLOT)
	print("[EquipmentPanel] unequip(", _selected_slot, ") -> ", ok)
	_rs_reload_if_present()
	refresh()

# -------------------------------------------------------------------
# misc
# -------------------------------------------------------------------
func _on_run_changed() -> void:
	refresh()

func _resolve_nodes() -> void:
	_list        = get_node_or_null(^"HSplitContainer/ItemList") as ItemList
	_name        = get_node_or_null(^"HSplitContainer/DetailsBox/Name") as Label
	_stats       = get_node_or_null(^"HSplitContainer/DetailsBox/Stats") as Label
	_btn_use     = get_node_or_null(^"HSplitContainer/DetailsBox/HBoxContainer/btn_use") as Button
	_btn_unequip = get_node_or_null(^"HSplitContainer/DetailsBox/HBoxContainer/btn_equip") as Button
	# (The scene shows two buttons; we repurpose the right one as Unequip.)

func _style_defaults() -> void:
	top_level = false
	anchors_preset = Control.PRESET_FULL_RECT
	set_offsets_preset(Control.PRESET_FULL_RECT)
	position = Vector2.ZERO
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical   = Control.SIZE_EXPAND_FILL

	if _list:
		_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_list.size_flags_vertical   = Control.SIZE_EXPAND_FILL

	if _name:
		_name.clip_text = true
		_name.autowrap_mode = TextServer.AUTOWRAP_OFF
	if _stats:
		_stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if _btn_use:
		_btn_use.text = "Use"
		_btn_use.disabled = true
	if _btn_unequip:
		_btn_unequip.text = "Unequip"
		_btn_unequip.disabled = true

func _rs_reload_if_present() -> void:
	var rs: Node = get_node_or_null(^"/root/RunState")
	if rs and rs.has_method("reload"):
		rs.call("reload", SaveManager.DEFAULT_SLOT)

# --- affix formatting -------------------------------------------------
func _format_affix(a: Dictionary) -> String:
	var et: String = str(_S.dget(a, "effect_type", ""))
	var id: String = str(_S.dget(a, "id", et))
	var v: float = float(_S.dget(a, "value", 0.0))
	var units: String = str(_S.dget(a, "units", "")) # often "", sometimes "percent"
	var p_any: Variant = _S.dget(a, "params", {})
	var p: Dictionary = (p_any as Dictionary) if p_any is Dictionary else {}

	var sign: String = "+" if v >= 0.0 else "-"
	var mag: float = absf(v)
	var mag_txt: String = ( "%s%.1f%%" % [sign, mag] ) if units == "percent" else ( "%s%.1f" % [sign, mag] )

	match et:
		"added_damage_elem_flat":
			var elem: String = str(_S.dget(p, "element", "elem")).capitalize()
			return "Added Damage (%s) %s" % [elem, mag_txt]
		"added_damage_phys_flat":
			var phys: String = str(_S.dget(p, "phys_type", "phys")).capitalize()
			return "Added Damage (%s) %s" % [phys, mag_txt]
		"flat_power":                       return "Power %s" % mag_txt
		"school_power_pct":
			var sch: String = str(_S.dget(p, "school", "power")).capitalize()
			return "%s Power %s" % [sch, mag_txt]
		"accuracy_flat":                    return "Accuracy %s" % mag_txt
		"crit_chance_pct":                  return "Crit Chance %s" % mag_txt
		"crit_damage_pct":                  return "Crit Damage %s" % mag_txt
		"on_hit_status_chance_pct":
			var st: String = str(_S.dget(p, "status", "status")).capitalize()
			return "On-Hit %s Chance %s" % [st, mag_txt]
		"life_on_hit_flat":                 return "Life on Hit %s" % mag_txt
		"mana_on_hit_flat":                 return "Mana on Hit %s" % mag_txt
		"ctb_on_kill_pct":                  return "CTB on Kill %s" % mag_txt
		"convert_physical_to_element_pct":
			var e2: String = str(_S.dget(p, "element", "element")).capitalize()
			return "Convert Physical→%s %s" % [e2, mag_txt]
		"def_flat":                         return "Defense %s" % mag_txt
		"res_flat":                         return "Resistance %s" % mag_txt
		"speed_delta_flat":                 return "Speed %s" % mag_txt
		"dodge_chance_pct":                 return "Dodge Chance %s" % mag_txt
		"ctb_cost_reduction_pct":           return "CTB Cost Reduction %s" % mag_txt
		"status_resist_pct":                return "Status Resist %s" % mag_txt
		"element_resist_pct":
			var e: String = str(_S.dget(p, "element", "element")).capitalize()
			return "%s Resist %s" % [e, mag_txt]
		"thorns_pct":                       return "Thorns %s" % mag_txt
		"carry_capacity_flat":              return "Carry Capacity %s" % mag_txt
		"primary_stat_flat":
			var stat: String = str(_S.dget(p, "stat", "STAT")).to_upper()
			return "%s %s" % [stat, mag_txt]
		"skill_xp_gain_pct":                return "Skill XP Gain %s" % mag_txt
		"gold_find_pct":                    return "Gold Find %s" % mag_txt
		"hp_on_kill_flat":                  return "HP on Kill %s" % mag_txt
		"mp_on_kill_flat":                  return "MP on Kill %s" % mag_txt
		"gain_tag":
			var tag: String = str(_S.dget(p, "tag", "")).capitalize()
			return "Grants Tag: %s" % (tag if tag != "" else "Tag")
		_:
			var nice: String = id.replace("_", " ").capitalize()
			return "%s %s" % [nice, mag_txt]

func _affix_lines_for_item(it: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var arr_any: Variant = _S.dget(it, "affixes", [])
	if not (arr_any is Array):
		return out
	for a_any in (arr_any as Array):
		if a_any is Dictionary:
			out.append(_format_affix(a_any as Dictionary))
	return out

static func _rar_code(r_long: String) -> String:
	var m := {
		"Common":"C","Uncommon":"U","Rare":"R","Epic":"E","Ancient":"A","Legendary":"L","Mythic":"M"
	}
	return m.get(r_long, "U")
