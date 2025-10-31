extends VBoxContainer
class_name VendorBody

signal request_buy(item_id: StringName, qty: int, rarity: String)
signal request_sell(item_id: StringName, qty: int, rarity: String)

const _DBG := "[VendorBody] "
func _log(msg: String) -> void: print(_DBG + msg)

var building_kind: StringName = &""
var instance_id: StringName = &""
var coord: Vector2i = Vector2i.ZERO
var slot: int = 1

# Contract-facing state (strictly typed)
var stock: Array[Dictionary] = []      # BUY
var sellables: Array[Dictionary] = []  # SELL
var stash_gold: int = 0
var active: bool = true

var _shell: BuildingModalShell = null
var _current_tab: int = 0

func bind_shell(shell: BuildingModalShell) -> void:
	_shell = shell
	_log("bind_shell -> ok")

func set_context(kind: StringName, p_instance_id: StringName, p_coord: Vector2i, p_slot: int) -> void:
	building_kind = kind
	instance_id = p_instance_id
	coord = p_coord
	slot = p_slot
	_log("set_context kind=%s iid=%s slot=%d" % [String(kind), String(p_instance_id), p_slot])

func enter(ctx: Dictionary) -> void:
	_log("enter()")
	size_flags_horizontal = Control.SIZE_FILL | Control.SIZE_EXPAND
	size_flags_vertical   = Control.SIZE_FILL | Control.SIZE_EXPAND
	_refresh_from_ctx(ctx)
	_render_current_tab()
	_log("enter() -> rendered tab %d" % _current_tab)

func refresh(ctx: Dictionary) -> void:
	_log("refresh()")
	_refresh_from_ctx(ctx)
	_render_current_tab()
	_log("refresh() -> rendered tab %d" % _current_tab)

func get_tabs() -> PackedStringArray:
	return PackedStringArray(["Status", "Buy", "Sell"])

func on_tab_changed(idx: int) -> void:
	_current_tab = idx
	_log("on_tab_changed -> %d" % idx)
	_render_current_tab()

func get_footer_actions() -> Array[Dictionary]:
	var arr: Array[Dictionary] = [
		{ "id": "open_feature", "label": "Open Shop", "enabled": active }
	]
	_log("get_footer_actions -> %d action(s), enabled=%s" % [arr.size(), str(active)])
	return arr

# --- internals ---------------------------------------------------------------
func _ready() -> void:
	size_flags_horizontal = Control.SIZE_FILL | Control.SIZE_EXPAND
	size_flags_vertical   = Control.SIZE_FILL | Control.SIZE_EXPAND
	_log("_ready()")

func _refresh_from_ctx(ctx: Dictionary) -> void:
	var st_any: Array = ctx.get("stock", []) as Array
	var se_any: Array = ctx.get("sellables", []) as Array

	var st: Array[Dictionary] = []
	for v in st_any:
		if v is Dictionary:
			st.append(v)
	var se: Array[Dictionary] = []
	for v in se_any:
		if v is Dictionary:
			se.append(v)

	stock = st
	sellables = se
	stash_gold = int(ctx.get("stash_gold", 0))
	active = bool(ctx.get("active", true))

	_log("ctx -> stock=%d sellables=%d gold=%d active=%s"
		% [stock.size(), sellables.size(), stash_gold, str(active)])

func _render_current_tab() -> void:
	_clear()
	match _current_tab:
		0: _render_status()
		1: _render_buy()
		2: _render_sell()
		_: _render_status()

func _render_status() -> void:
	var l := Label.new()
	l.text = "Vendor status — Gold: %d — Active: %s" % [stash_gold, ("true" if active else "false")]
	add_child(l)

	var h := HBoxContainer.new()
	h.size_flags_horizontal = Control.SIZE_FILL
	var hint := Label.new()
	hint.text = "Tip: Use the footer to jump to Buy."
	h.add_child(hint)
	add_child(h)
	_log("_render_status done")

# ------------------------------- BUY TAB ------------------------------------
func _render_buy() -> void:
	_clear()

	var title := Label.new()
	title.text = "Buy"
	title.size_flags_vertical = 0 # don't let the title expand
	add_child(title)

	# Scroll container fills remaining space (Godot 4 API)
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	sc.clip_contents = true
	sc.size_flags_horizontal = Control.SIZE_FILL | Control.SIZE_EXPAND
	sc.size_flags_vertical   = Control.SIZE_FILL | Control.SIZE_EXPAND
	add_child(sc)

	# Rows inside the scroller
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_FILL | Control.SIZE_EXPAND
	rows.size_flags_vertical   = Control.SIZE_FILL | Control.SIZE_EXPAND
	rows.add_theme_constant_override("separation", 8)
	sc.add_child(rows)

	if stock.is_empty():
		var empty := Label.new()
		empty.text = "No items for sale."
		rows.add_child(empty)
		_log("_render_buy -> empty")
		return

	for row in stock:
		var id := StringName(String(row.get("id", "")))
		var name := String(row.get("name", String(id)))
		var rarity_text := String(row.get("rarity", "Common"))
		var unit_price := int(row.get("price", 0))
		var available := int(row.get("count", 1))

		var hb := HBoxContainer.new()
		hb.size_flags_horizontal = Control.SIZE_FILL
		hb.custom_minimum_size.y = 28.0

		var lbl := Label.new()
		lbl.text = "%s [%s] — %d gold (x%d available)" % [name, rarity_text, unit_price, available]
		lbl.size_flags_horizontal = Control.SIZE_FILL | Control.SIZE_EXPAND

		var qty := SpinBox.new()
		qty.min_value = 1
		qty.max_value = max(1, available)
		qty.step = 1
		qty.value = 1
		qty.custom_minimum_size.x = 72.0

		var btn := Button.new()
		btn.text = "Buy 1 (%d g)" % unit_price
		btn.disabled = (not active) or (available <= 0) or (unit_price > stash_gold)
		btn.custom_minimum_size.x = 96.0

		var update := func() -> void:
			var q := int(qty.value)
			var total := unit_price * q
			var ok_stock := q <= available
			var ok_gold := total <= stash_gold
			btn.text = "Buy %d (%d g)" % [q, total]
			btn.disabled = (not active) or (available <= 0) or (not ok_stock) or (not ok_gold)

		qty.value_changed.connect(func(_v: float) -> void: update.call())

		btn.pressed.connect(func() -> void:
			var q2 := int(qty.value)
			_log("BUY pressed id=%s qty=%d unit=%d stash=%d" % [String(id), q2, unit_price, stash_gold])
			emit_signal("request_buy", id, q2, rarity_text)
		)

		hb.add_child(lbl)
		hb.add_child(qty)
		hb.add_child(btn)
		rows.add_child(hb)

	_log("_render_buy -> rows=%d (scrollable)" % stock.size())

# ------------------------------- SELL TAB -----------------------------------
func _render_sell() -> void:
	var title := Label.new()
	title.text = "Sell"
	title.size_flags_vertical = 0
	add_child(title)

	# Scroll container fills remaining space
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	sc.clip_contents = true
	sc.size_flags_horizontal = Control.SIZE_FILL | Control.SIZE_EXPAND
	sc.size_flags_vertical   = Control.SIZE_FILL | Control.SIZE_EXPAND
	add_child(sc)

	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_FILL | Control.SIZE_EXPAND
	rows.size_flags_vertical   = Control.SIZE_FILL | Control.SIZE_EXPAND
	rows.add_theme_constant_override("separation", 8)
	sc.add_child(rows)

	if sellables.is_empty():
		var empty := Label.new()
		empty.text = "Nothing to sell."
		rows.add_child(empty)
		_log("_render_sell -> empty")
		return

	for row in sellables:
		var id := StringName(String(row.get("id", "")))
		var name := String(row.get("name", String(id)))
		var rarity_text := String(row.get("rarity", "Common"))
		var unit := int(row.get("price", 0))
		var have := int(row.get("count", 1))

		var hb := HBoxContainer.new()
		hb.size_flags_horizontal = Control.SIZE_FILL
		hb.custom_minimum_size.y = 28.0

		var lbl := Label.new()
		lbl.text = "%s [%s] — %d gold (x%d owned)" % [name, rarity_text, unit, have]
		lbl.size_flags_horizontal = Control.SIZE_FILL | Control.SIZE_EXPAND

		var qty := SpinBox.new()
		qty.min_value = 1
		qty.max_value = max(1, have)
		qty.step = 1
		qty.value = min(1, have)
		qty.custom_minimum_size.x = 72.0

		var btn := Button.new()
		btn.text = "Sell 1 (%d g)" % unit
		btn.disabled = (not active) or (have <= 0)
		btn.custom_minimum_size.x = 112.0

		var update := func() -> void:
			var q := int(qty.value)
			var total := unit * q
			var ok_have := q <= have
			btn.text = "Sell %d (%d g)" % [q, total]
			var dis := (not active) or (have <= 0) or (not ok_have)
			if btn.disabled != dis:
				_log("sell row %s -> q=%d total=%d ok_have=%s disabled->%s"
					% [String(id), q, total, str(ok_have), str(dis)])
			btn.disabled = dis

		qty.value_changed.connect(func(_v: float) -> void: update.call())

		btn.pressed.connect(func() -> void:
			var q2 := int(qty.value)
			_log("SELL pressed id=%s qty=%d unit=%d rarity=%s" % [String(id), q2, unit, rarity_text])
			emit_signal("request_sell", id, q2, rarity_text)
		)

		hb.add_child(lbl)
		hb.add_child(qty)
		hb.add_child(btn)
		rows.add_child(hb)

	_log("_render_sell -> rows=%d (scrollable)" % sellables.size())

# ------------------------------- utils --------------------------------------
func _emit_buy(id: StringName, qty: int, rarity: String) -> void:
	_log("request_buy id=%s qty=%d rarity=%s" % [String(id), qty, rarity])
	emit_signal("request_buy", id, qty, rarity)

func _emit_sell(id: StringName, qty: int, rarity: String) -> void:
	_log("request_sell id=%s qty=%d rarity=%s" % [String(id), qty, rarity])
	emit_signal("request_sell", id, qty, rarity)

func _clear() -> void:
	for ch in get_children():
		ch.queue_free()
