# res://ui/status/EffectsPanel.gd
extends StatusPanel
class_name EffectsPanel

const StatusEngine := preload("res://scripts/combat/status/StatusEngine.gd")
const StatusService := preload("res://scripts/combat/status/StatusService.gd")

@onready var _list: ItemList = get_node(^"HSplitContainer/ItemList") as ItemList
@onready var _name_lbl: Label = get_node(^"HSplitContainer/VBoxContainer/DetailsBox/Name") as Label
@onready var _stats_lbl: Control = get_node(^"HSplitContainer/VBoxContainer/DetailsBox/Stats") as Control



# --- Debug helpers ---
func _rs() -> Node:
	return get_node_or_null(^"/root/RunState")

const _PFX := "[EffectsPanel] "
static func _keys_preview(d: Dictionary, max_n: int = 8) -> String:
	var ks: Array = d.keys()
	if ks.is_empty():
		return "(empty)"
	var out := PackedStringArray()
	var n: int = min(max_n, ks.size())
	for i in n:
		out.push_back(String(ks[i]))
	return ", ".join(out)

func _log(msg: String) -> void:
	print(_PFX, msg)

# ------------------------------------------------------------------
# Lifecycle / bindings
# ------------------------------------------------------------------
func set_run_slot(slot: int) -> void:
	_slot = max(1, slot)
	_log("set_run_slot -> %d" % _slot)

# Optional: if your BattleUI calls this when a controller is ready
func bind_to_controller(_bc: Node) -> void:
	_log("bind_to_controller()")
	refresh()

# Back-compat: allow callers to push bags in; we forward to the service
func set_status_bags(player_bag: Array, monster_bag: Array = []) -> void:
	_log("set_status_bags() player=%d monster=%d" % [player_bag.size(), monster_bag.size()])
	StatusService.set_player_bag(player_bag)
	StatusService.set_monster_bag(monster_bag)
	refresh()

func on_enter() -> void:
	_log("on_enter() slot=%d" % _slot)
	var rs := _rs()
	if rs and not rs.changed.is_connected(_on_run_changed):
		rs.changed.connect(_on_run_changed)
	refresh()

func on_exit() -> void:
	_log("on_exit()")
	var rs := _rs()
	if rs and rs.changed.is_connected(_on_run_changed):
		rs.changed.disconnect(_on_run_changed)
		
func _on_run_changed() -> void:
	_log("RunState.changed → refreshing Effects")
	refresh()


# ------------------------------------------------------------------
# Render
# ------------------------------------------------------------------
func refresh() -> void:
	if _list == null:
		_log("refresh() aborted: _list is null")
		return

	var player_bag: Array[Dictionary] = StatusService.player_bag()
	var monster_bag: Array[Dictionary] = StatusService.monster_bag()

	_log("refresh() BEGIN  bags: player=%d monster=%d  slot=%d" % [
		player_bag.size(), monster_bag.size(), _slot
	])

	_list.clear()
	_set_details("", "")

	var rows: Array[Dictionary] = []

	# --- Player summary + effects (combat-only) ---
	var sum_p: Dictionary = StatusEngine.summarize(player_bag)
	_log("player summarize -> " + str(sum_p))
	rows.append({
		"kind": "summary",
		"owner": "player",
		"name": "Player — Summary",
		"detail": _format_summary(sum_p)
	})
	for s_any in player_bag:
		if s_any is Dictionary:
			var row := _row_from_status(s_any as Dictionary, "player")
			if not row.is_empty():
				rows.append(row)

	# --- Monster (if provided) ---
	if monster_bag.size() > 0:
		var sum_m: Dictionary = StatusEngine.summarize(monster_bag)
		_log("monster summarize -> " + str(sum_m))
		rows.append({
			"kind": "summary",
			"owner": "monster",
			"name": "Enemy — Summary",
			"detail": _format_summary(sum_m)
		})
		for s2_any in monster_bag:
			if s2_any is Dictionary:
				var row2 := _row_from_status(s2_any as Dictionary, "monster")
				if not row2.is_empty():
					rows.append(row2)

	# --- Long-term run modifiers (village / gear) ---
	_append_run_mod_rows(rows)

	# Fill list
	for r in rows:
		var line := _list_line_for_row(r)
		_list.add_item(line)
		var idx := _list.get_item_count() - 1
		_list.set_item_metadata(idx, r)

	_log("refresh() rows_built=%d list_count=%d" % [rows.size(), _list.get_item_count()])

	# Select first row
	if _list.get_item_count() > 0:
		if not _list.item_selected.is_connected(_on_item_selected):
			_list.item_selected.connect(_on_item_selected)
		_list.select(0)
		_on_item_selected(0)
	else:
		_log("refresh() no rows to select")

func _on_item_selected(idx: int) -> void:
	if idx < 0 or idx >= _list.get_item_count():
		return
	var meta_any: Variant = _list.get_item_metadata(idx)
	if meta_any == null or typeof(meta_any) != TYPE_DICTIONARY:
		return
	var row := meta_any as Dictionary
	var title := String(row.get("name", "Effect"))
	var detail := String(row.get("detail", ""))
	_set_details(title, detail)

# ------------------------------------------------------------------
# Run modifiers (village / gear)
# ------------------------------------------------------------------
func _append_run_mod_rows(rows: Array[Dictionary]) -> void:
	var sm := get_node_or_null(^"/root/SaveManager")
	if sm == null:
		_log("_append_run_mod_rows() SaveManager autoload not found at /root/SaveManager")
		return

	var rs: Dictionary = SaveManager.load_run(_slot)
	var mods_village: Dictionary = (rs.get("mods_village", {}) as Dictionary)
	var mods_affix: Dictionary = (rs.get("mods_affix", {}) as Dictionary)
	var buffs_arr: Array = (rs.get("buffs", []) as Array)

	_log("RUN snapshot: buffs=%d mods_village=%d mods_affix=%d" % [
		buffs_arr.size(), mods_village.size(), mods_affix.size()
	])
	if not mods_village.is_empty():
		_log("  village keys: " + _keys_preview(mods_village))
	if not mods_affix.is_empty():
		_log("  gear keys: " + _keys_preview(mods_affix))

	if not mods_village.is_empty():
		_append_mod_block(rows, mods_village, "Village", buffs_arr)
	if not mods_affix.is_empty():
		_append_mod_block(rows, mods_affix, "Gear", [])

func _append_mod_block(rows: Array[Dictionary], mods: Dictionary, label: String, sources: Array) -> void:
	# Header / summary
	var summary_text := _format_mods_preview(mods, sources)
	rows.append({
		"kind": "summary",
		"owner": label.to_lower(),
		"name": "%s — Summary" % label,
		"detail": summary_text
	})

	# Individual lines
	var keys: Array[String] = []
	for k in mods.keys():
		keys.append(String(k))
	keys.sort()

	for k in keys:
		var v := float(mods.get(k, 0.0))
		var is_pct := k.ends_with("_pct")
		var display_val := _fmt_pct(v) if is_pct else _fmt_num(v)
		var nice := _pretty_mod_name(k)
		var left := "%s  bonus" % label
		var right := "%s  %s" % [nice, display_val]
		rows.append({
			"kind": "mod",
			"owner": label.to_lower(),
			"name": "%s — %s" % [label, nice],
			"detail": "%s\nValue: %s\nId: %s" % [label, display_val, k],
			"line_left": left,
			"line_right": right
		})

func _format_mods_preview(mods: Dictionary, sources: Array) -> String:
	var parts := PackedStringArray()
	var shown := 0
	for k in mods.keys():
		if shown >= 5:
			break
		var kk := String(k)
		var v := float(mods.get(kk, 0.0))
		var is_pct := kk.ends_with("_pct")
		var nice := _pretty_mod_name(kk)
		var piece := "%s %s" % [nice, (_fmt_pct(v) if is_pct else _fmt_num(v))]
		parts.push_back(piece)
		shown += 1
	var suffix := ""
	if sources.size() > 0:
		suffix = " (from %d sources)" % sources.size()
	return "— No notable modifiers —" if parts.is_empty() else (", ".join(parts) + suffix)

static func _pretty_mod_name(id_s: String) -> String:
	match id_s:
		"flat_power": return "Flat Power"
		"school_power_pct": return "School Power"
		"accuracy_flat": return "Accuracy"
		"crit_chance_pct": return "Crit Chance"
		"crit_damage_pct": return "Crit Damage"
		"life_on_hit_flat": return "Life on Hit"
		"mana_on_hit_flat": return "Mana on Hit"
		"ctb_on_kill_pct": return "CTB on Kill"
		"durability_loss_reduction_pct": return "Durability Loss"
		"def_flat": return "Defense"
		"res_flat": return "Resistance"
		"speed_delta_flat": return "Speed"
		"dodge_chance_pct": return "Dodge Chance"
		"ctb_cost_reduction_pct": return "CTB Cost"
		"status_resist_pct", "status_resist_poison_pct": return "Status Resist"
		"element_resist_fire_pct": return "Fire Resist"
		"thorns_pct": return "Thorns"
		"carry_capacity_flat": return "Carry Capacity"
		"primary_lck_flat": return "Luck"
		"skill_xp_gain_pct": return "Skill XP Gain"
		"gold_find_pct": return "Gold Find"
		_: 
			var s := id_s.replace("_pct","").replace("_flat","").replace("_"," ")
			return s.capitalize()

# ------------------------------------------------------------------
# Combat status formatting
# ------------------------------------------------------------------
static func _row_from_status(s: Dictionary, owner: String) -> Dictionary:
	var id_s := String(s.get("id",""))
	if id_s == "":
		return {}
	var kind_s := String(s.get("kind",""))
	var pct := float(s.get("pct", 0.0))
	var turns := int(s.get("turns", 0))
	var display := _pretty_status_name(id_s)
	var line_left := "%s  %s" % [owner.capitalize(), ("BUFF" if kind_s == "buff" else "DEBUFF")]
	var line_right := "%s  %s  (%dt)" % [display, _fmt_pct(pct), turns]
	return {
		"kind": "effect",
		"owner": owner,
		"name": "%s — %s" % [owner.capitalize(), display],
		"detail": "Type: %s\nStrength: %s\nTurns left: %d\nId: %s" % [
			kind_s, _fmt_pct(pct), turns, id_s
		],
		"line_left": line_left,
		"line_right": line_right
	}

static func _pretty_status_name(id_s: String) -> String:
	match id_s:
		"def_up": return "Defense Up"
		"res_up": return "Resistance Up"
		"enemy_hit_down": return "Enemy Hit Down"
		"agi_down": return "AGI Down"
		"mark_amplify_next_hit": return "Marked"
		_: return id_s.capitalize()

static func _format_summary(sum: Dictionary) -> String:
	var parts := PackedStringArray()
	var def_up := float(sum.get("def_up_pct", 0.0))
	var res_up := float(sum.get("res_up_pct", 0.0))
	var hit_dn := float(sum.get("enemy_hit_down_pct", 0.0))
	var agi_dn := float(sum.get("agi_down_pct", 0.0))
	var mark   := float(sum.get("mark_amp_pct", 0.0))
	if def_up != 0.0:
		parts.push_back("Defense " + _fmt_pct(def_up))
	if res_up != 0.0:
		parts.push_back("Resistance " + _fmt_pct(res_up))
	if hit_dn != 0.0:
		parts.push_back("Enemy Hit " + _fmt_pct(-absf(hit_dn)))
	if agi_dn != 0.0:
		parts.push_back("Enemy AGI " + _fmt_pct(-absf(agi_dn)))
	if mark != 0.0:
		parts.push_back("Mark (next hit) " + _fmt_pct(mark))
	return "— No notable modifiers —" if parts.is_empty() else ", ".join(parts)

func _list_line_for_row(r: Dictionary) -> String:
	if String(r.get("kind","")) == "summary":
		return String(r.get("name","Summary")) + " — " + String(r.get("detail",""))
	var left := String(r.get("line_left",""))
	var right := String(r.get("line_right",""))
	return left if right == "" else "%s    —    %s" % [left, right]

func _set_details(title: String, body: String) -> void:
	if _name_lbl:
		_name_lbl.text = title
	if _stats_lbl:
		if _stats_lbl is Label:
			(_stats_lbl as Label).text = body
		elif _stats_lbl is RichTextLabel:
			var r := _stats_lbl as RichTextLabel
			r.bbcode_enabled = false
			r.text = body

static func _fmt_num(v: float, decimals: int = 1) -> String:
	var mag := String.num(absf(v), decimals)
	return ("+" + mag) if v >= 0.0 else ("-" + mag)

static func _fmt_pct(v: float, decimals: int = 1) -> String:
	return _fmt_num(v, decimals) + "%"
