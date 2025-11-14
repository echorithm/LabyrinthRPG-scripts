extends VBoxContainer
class_name TrainerBody

signal request_unlock(skill_id: StringName)
signal request_raise_cap(skill_id: StringName)

const LOG := true
const _DBG := "[TrainerBody] "

static func _log(msg: String) -> void:
	if LOG:
		print(_DBG + msg)

static func _s(v: Variant) -> String:
	var t := typeof(v)
	if t == TYPE_DICTIONARY or t == TYPE_ARRAY:
		return JSON.stringify(v, "\t")
	return str(v)

static func _psa_to_str(psa: PackedStringArray) -> String:
	var arr: Array[String] = []
	for s in psa:
		arr.append(s)
	return "[" + ", ".join(arr) + "]"

var _shell: Node = null
var _kind: StringName = &"trainer"
var _instance_id: StringName = &""
var _coord: Vector2i = Vector2i.ZERO
var _slot: int = 1

# UI
var _tabs := PackedStringArray(["Status", "Training"])
var _status_root: VBoxContainer
var _train_root: VBoxContainer

# State last ctx
var _ctx: Dictionary = {}

func bind_shell(shell: Node) -> void:
	_shell = shell
	_log("bind_shell -> ok shell=%s path=%s" % [str(shell), shell.get_path()])

func set_context(kind: StringName, iid: StringName, coord: Vector2i, slot: int) -> void:
	_kind = kind
	_instance_id = iid
	_coord = coord
	_slot = max(1, slot)
	_log("set_context kind=%s iid=%s coord=%s slot=%d" % [String(kind), String(iid), str(coord), _slot])

func enter(ctx: Dictionary) -> void:
	_log("enter() ctx_in=%s" % _s(ctx))
	_build_ui_if_needed()
	refresh(ctx)

func get_tabs() -> PackedStringArray:
	return _tabs

func on_tab_changed(idx: int) -> void:
	var tab_name := "Status" if idx == 0 else ("Training" if idx == 1 else "Other")
	_log("on_tab_changed -> %d (%s)" % [idx, tab_name])
	_show_status(idx == 0)
	_show_training(idx == 1)

func get_footer_actions() -> Array[Dictionary]:
	var any_trainable := false
	var skills_any: Variant = _ctx.get("skills", [])
	var skills_arr: Array = skills_any if (skills_any is Array) else []
	for s in skills_arr:
		if s is Dictionary:
			var d: Dictionary = s
			if bool(d.get("can_unlock", false)) or bool(d.get("can_raise_cap", false)):
				any_trainable = true
				break
	var arr: Array[Dictionary] = [
		{ "id": "start_training", "label": "Training", "enabled": any_trainable }
	]
	_log("get_footer_actions -> any_trainable=%s skills_count=%d" % [str(any_trainable), skills_arr.size()])
	return arr

func get_ctx_key() -> String:
	return "training"

func refresh(ctx: Dictionary) -> void:
	_ctx = ctx if ctx is Dictionary else {}
	_log("refresh() -> ctx keys=%s raw=%s" % [_psa_to_str(PackedStringArray(_ctx.keys())), _s(_ctx)])
	_update_status()
	_update_training()

# ---- UI build ----
func _build_ui_if_needed() -> void:
	if is_instance_valid(_status_root):
		return

	_log("_build_ui_if_needed() parent=%s path=%s tree=%s" % [str(get_parent()), get_path(), str(get_tree())])

	_status_root = VBoxContainer.new()
	_status_root.name = "StatusRoot"
	_status_root.size_flags_vertical = Control.SIZE_EXPAND | Control.SIZE_FILL
	add_child(_status_root)

	_train_root = VBoxContainer.new()
	_train_root.name = "TrainingRoot"
	_train_root.visible = false
	_train_root.size_flags_vertical = Control.SIZE_EXPAND | Control.SIZE_FILL
	add_child(_train_root)

	var t1 := Label.new()
	t1.text = "Trainer Overview"
	t1.add_theme_font_size_override("font_size", 16)
	_status_root.add_child(t1)

	_status_root.add_child(_kv("Connected", "—"))
	_status_root.add_child(_kv("Active", "—"))
	_status_root.add_child(_kv("Staffed", "—"))
	_status_root.add_child(_kv("Rarity", "—"))
	_status_root.add_child(_kv("Target Cap", "—"))
	_status_root.add_child(_kv("Gold", "—"))
	_status_root.add_child(_kv("Shards", "—"))

	var t2 := Label.new()
	t2.text = "Skills"
	t2.add_theme_font_size_override("font_size", 16)
	_train_root.add_child(t2)

	var hint := Label.new()
	hint.text = "• Common: unlock skills\n• Higher rarity: raise cap (10 → 20 → 30 ...)"
	_train_root.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.name = "SkillScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND | Control.SIZE_FILL
	var list := VBoxContainer.new()
	list.name = "SkillList"
	list.size_flags_horizontal = Control.SIZE_EXPAND | Control.SIZE_FILL
	scroll.add_child(list)
	_train_root.add_child(scroll)

func _show_status(show: bool) -> void:
	if is_instance_valid(_status_root):
		_status_root.visible = show
	if is_instance_valid(_train_root):
		_train_root.visible = not show

func _show_training(show: bool) -> void:
	if is_instance_valid(_train_root):
		_train_root.visible = show
	if is_instance_valid(_status_root):
		_status_root.visible = not show

func _kv(k: String, v: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.custom_minimum_size.y = 22
	var lk := Label.new(); lk.text = k + ":"
	var lv := Label.new(); lv.text = v; lv.name = "v_" + k.replace(" ", "_")
	lk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lk)
	row.add_child(lv)
	return row

func _set_status_val(key: String, val: String) -> void:
	if not is_instance_valid(_status_root): return
	var node := _status_root.get_node_or_null("v_" + key.replace(" ", "_")) as Label
	if node != null:
		node.text = val

# ---- painters ----
func _update_status() -> void:
	var connected: bool = bool(_ctx.get("connected", false))
	var active: bool = bool(_ctx.get("active", false))
	var staffed: bool = bool(_ctx.get("staffed", false))
	var rarity: String = String(_ctx.get("trainer_rarity","COMMON"))
	var target_cap: int = int(_ctx.get("target_cap", 10))
	var gold_ctx: int = int(_ctx.get("stash_gold", -1))
	var shards_ctx: int = int(_ctx.get("stash_shards", -1))

	var gold_fb := _peek_stash_gold_fallback()
	var shards_fb := _peek_stash_shards_fallback()
	var gold_disp := gold_ctx if gold_ctx >= 0 else gold_fb
	var shards_disp := shards_ctx if shards_ctx >= 0 else shards_fb

	_log("_update_status -> conn=%s active=%s staffed=%s rarity=%s target_cap=%d gold(ctx=%d fb=%d disp=%d) shards(ctx=%d fb=%d disp=%d)"
		% [str(connected), str(active), str(staffed), rarity, target_cap,
		   gold_ctx, gold_fb, gold_disp, shards_ctx, shards_fb, shards_disp])

	_set_status_val("Connected", _tf(connected))
	_set_status_val("Active", _tf(active))
	_set_status_val("Staffed", _tf(staffed))
	_set_status_val("Rarity", rarity)
	_set_status_val("Target Cap", str(target_cap))
	_set_status_val("Gold", str(gold_disp))
	_set_status_val("Shards", str(shards_disp))

func _update_training() -> void:
	var scroll := _train_root.get_node_or_null("SkillScroll") as ScrollContainer
	if scroll == null:
		_log("_update_training -> no scroll")
		return
	var list := scroll.get_node("SkillList") as VBoxContainer
	for c in list.get_children():
		c.queue_free()

	var skills_any: Variant = _ctx.get("skills", [])
	var skills: Array = skills_any if (skills_any is Array) else []
	_log("_update_training -> skills=%d raw=%s" % [skills.size(), _s(skills)])

	if skills.is_empty():
		var empty := Label.new()
		empty.text = "No skills available for this trainer."
		list.add_child(empty)
		return

	for s in skills:
		if not (s is Dictionary):
			continue
		var d: Dictionary = s
		_log("  paint skill row -> %s" % _s(d))

		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND | Control.SIZE_FILL

		var name := Label.new()
		var skill_id: String = String(d.get("id",""))
		name.text = skill_id.capitalize().replace("_"," ")
		name.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var info := Label.new()
		var level: int = int(d.get("level",1))
		var cap_band: int = int(d.get("cap_band",10))
		var unlocked: bool = bool(d.get("unlocked", false))
		info.text = "Lv %d  Cap %d  %s" % [level, cap_band, ("Unlocked" if unlocked else "Locked")]

		var unlock_cost: Dictionary = (d.get("unlock_cost", {}) as Dictionary) if (d.get("unlock_cost", {}) is Dictionary) else {"gold":0,"shards":0}
		var raise_cost: Dictionary = (d.get("raise_cost", {}) as Dictionary) if (d.get("raise_cost", {}) is Dictionary) else {"gold":0,"shards":0}

		var can_unlock: bool = bool(d.get("can_unlock", false))
		var can_raise: bool = bool(d.get("can_raise_cap", false))

		var btn_unlock := Button.new()
		btn_unlock.text = "Unlock" + _fmt_cost_suffix(unlock_cost)
		btn_unlock.disabled = not can_unlock
		if not can_unlock:
			btn_unlock.tooltip_text = _reason_text(String(d.get("cant_unlock_reason","")))
		btn_unlock.pressed.connect(_emit_unlock.bind(StringName(skill_id)))

		var btn_raise := Button.new()
		btn_raise.text = "Raise Cap" + _fmt_cost_suffix(raise_cost)
		btn_raise.disabled = not can_raise
		if not can_raise:
			btn_raise.tooltip_text = _reason_text(String(d.get("cant_raise_reason","")))
		btn_raise.pressed.connect(_emit_raise_cap.bind(StringName(skill_id)))

		row.add_child(name)
		row.add_child(info)
		row.add_child(btn_unlock)
		row.add_child(btn_raise)
		list.add_child(row)

# ---- intents ----
func _emit_unlock(skill_id: StringName) -> void:
	_log("emit: request_unlock -> %s" % String(skill_id))
	emit_signal("request_unlock", skill_id)

func _emit_raise_cap(skill_id: StringName) -> void:
	_log("emit: request_raise_cap -> %s" % String(skill_id))
	emit_signal("request_raise_cap", skill_id)

# ---- utils ----
static func _tf(b: bool) -> String:
	return "Yes" if b else "No"

static func _fmt_cost_suffix(cost: Dictionary) -> String:
	var g: int = int(cost.get("gold", 0))
	var s: int = int(cost.get("shards", 0))
	if g <= 0 and s <= 0:
		return " (free)"
	if g > 0 and s > 0:
		return " (%dg, %ds)" % [g, s]
	if g > 0:
		return " (%dg)" % g
	return " (%ds)" % s

static func _reason_text(reason: String) -> String:
	match reason:
		"TRAINER_INACTIVE": return "Trainer must be connected, active, and staffed."
		"ALREADY_UNLOCKED": return "This skill is already unlocked."
		"RARITY_TOO_LOW": return "Increase trainer rarity to unlock this skill."
		"INSUFFICIENT_FUNDS": return "Not enough gold or shards."
		"AT_CAP_FOR_RARITY": return "Already at the cap for current rarity."
		"LOCKED": return "Unlock the skill first."
		_: return ""

# Display-only fallback readers (so you see values even if ctx misses them)
func _peek_stash_gold_fallback() -> int:
	var v := get_node_or_null("/root/VillageService")
	_log("_peek_stash_gold_fallback: have VillageService=%s has(get_stash_gold)=%s" % [str(v != null), str(v != null and v.has_method("get_stash_gold"))])
	if v != null and v.has_method("get_stash_gold"):
		var g := int(v.call("get_stash_gold"))
		_log("  via VillageService -> %d" % g)
		return g
	var p := get_node_or_null("/root/PersistenceService")
	_log("  have PersistenceService=%s has(get_stash_gold)=%s" % [str(p != null), str(p != null and p.has_method("get_stash_gold"))])
	if p != null and p.has_method("get_stash_gold"):
		var g2 := int(p.call("get_stash_gold"))
		_log("  via PersistenceService -> %d" % g2)
		return g2
	_log("  -> 0")
	return 0

func _peek_stash_shards_fallback() -> int:
	var v := get_node_or_null("/root/VillageService")
	_log("_peek_stash_shards_fallback: have VillageService=%s has(get_stash_shards)=%s" % [str(v != null), str(v != null and v.has_method("get_stash_shards"))])
	if v != null and v.has_method("get_stash_shards"):
		var s := int(v.call("get_stash_shards"))
		_log("  via VillageService -> %d" % s)
		return s
	var p := get_node_or_null("/root/PersistenceService")
	_log("  have PersistenceService=%s has(get_stash_shards)=%s" % [str(p != null), str(p != null and p.has_method("get_stash_shards"))])
	if p != null and p.has_method("get_stash_shards"):
		var s2 := int(p.call("get_stash_shards"))
		_log("  via PersistenceService -> %d" % s2)
		return s2
	_log("  -> 0")
	return 0
