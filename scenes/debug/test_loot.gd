extends Control
class_name TestLoot

##
## TestLoot — interactive loot test harness (Godot 4.5)
## - Choose Floor (1–70), Player Level, Source (Trash/Elite/Boss/Chest)
## - Optional: Monster Level override, Boss charge, Post‑boss shift left, Trials, Seed
## - Runs N deterministic trials (seeded) and shows rarity/category dist, average gold/shards/XP
## - Optional: resolve items and show item ID counts (no gran_on_run_pressed(ting; pure simulation)
##
## Determinism:
##   For trial i, rng_seed := hash(base_seed | floor | source | i). Re-running yields identical results.

# ---------- Imports / dependencies ----------
const SetPL      := preload("res://scripts/dungeon/encounters/SetPowerLevel.gd")
const XpTuning   := preload("res://scripts/rewards/XpTuning.gd")
const ItemResolver := preload("res://scripts/items/ItemResolver.gd")
const LootSystemClass := preload("res://scripts/Loot/LootSystem.gd") # fallback if autoload missing

# ---------- UI nodes ----------
@onready var _root_pad: MarginContainer = MarginContainer.new()
@onready var _col: VBoxContainer = VBoxContainer.new()

@onready var _row1: HBoxContainer = HBoxContainer.new()
@onready var _floor_spin: SpinBox = SpinBox.new()
@onready var _player_spin: SpinBox = SpinBox.new()
@onready var _source_opt: OptionButton = OptionButton.new()

@onready var _row2: HBoxContainer = HBoxContainer.new()
@onready var _trials_spin: SpinBox = SpinBox.new()
@onready var _seed_spin: SpinBox = SpinBox.new()
@onready var _resolve_items_chk: CheckBox = CheckBox.new()
@onready var _samples_spin: SpinBox = SpinBox.new()

@onready var _row3: HBoxContainer = HBoxContainer.new()
@onready var _override_chk: CheckBox = CheckBox.new()
@onready var _override_lvl_spin: SpinBox = SpinBox.new()
@onready var _boss_charge_label: Label = Label.new()
@onready var _boss_charge: HSlider = HSlider.new()
@onready var _post_boss_spin: SpinBox = SpinBox.new()

@onready var _row4: HBoxContainer = HBoxContainer.new()
@onready var _run_btn: Button = Button.new()
@onready var _one_btn: Button = Button.new()
@onready var _clr_btn: Button = Button.new()

@onready var _out: RichTextLabel = RichTextLabel.new()

# ---------- Constants ----------
const SOURCES: PackedStringArray = ["trash","elite","boss","chest"]
const RARITY_ORDER: Array[String] = ["C","U","R","E","A","L","M"]

# ---------- State ----------
var _loot_node: Node = null

# ---------- Lifecycle ----------
func _ready() -> void:
	_build_ui()
	_loot_node = _get_loot_system()
	_update_boss_controls_enabled()

# ---------- UI construction ----------
func _build_ui() -> void:
	self.name = "TestLoot"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS

	_root_pad.add_theme_constant_override("margin_left",  12)
	_root_pad.add_theme_constant_override("margin_right", 12)
	_root_pad.add_theme_constant_override("margin_top",   12)
	_root_pad.add_theme_constant_override("margin_bottom",12)
	add_child(_root_pad)
	_root_pad.add_child(_col)
	_col.add_theme_constant_override("separation", 8)
	_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_col.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Row 1: floor, player level, source
	_row1.add_theme_constant_override("separation", 8)
	_col.add_child(_row1)

	var floor_lbl := Label.new()
	floor_lbl.text = "Floor"
	_row1.add_child(floor_lbl)
	_floor_spin.min_value = 1
	_floor_spin.max_value = 70
	_floor_spin.step = 1
	_floor_spin.value = 1
	_floor_spin.custom_minimum_size = Vector2(90, 0)
	_row1.add_child(_floor_spin)

	var player_lbl := Label.new()
	player_lbl.text = "Player Lv"
	_row1.add_child(player_lbl)
	_player_spin.min_value = 1
	_player_spin.max_value = 99
	_player_spin.step = 1
	_player_spin.value = 1
	_player_spin.custom_minimum_size = Vector2(90, 0)
	_row1.add_child(_player_spin)

	var source_lbl := Label.new()
	source_lbl.text = "Source"
	_row1.add_child(source_lbl)
	_source_opt.custom_minimum_size = Vector2(140, 0)
	for s in SOURCES:
		_source_opt.add_item(s.capitalize(), _source_opt.item_count)
	_row1.add_child(_source_opt)
	_source_opt.item_selected.connect(func(_idx: int) -> void:
		_update_boss_controls_enabled()
	)

	# Row 2: trials, seed, resolve items, sample rows
	_row2.add_theme_constant_override("separation", 8)
	_col.add_child(_row2)

	var trials_lbl := Label.new()
	trials_lbl.text = "Trials"
	_row2.add_child(trials_lbl)
	_trials_spin.min_value = 1
	_trials_spin.max_value = 100000
	_trials_spin.step = 1
	_trials_spin.value = 500
	_trials_spin.custom_minimum_size = Vector2(100, 0)
	_row2.add_child(_trials_spin)

	var seed_lbl := Label.new()
	seed_lbl.text = "Seed Base"
	_row2.add_child(seed_lbl)
	_seed_spin.min_value = -2147483648
	_seed_spin.max_value =  2147483647
	_seed_spin.step = 1
	_seed_spin.value = _default_seed()
	_seed_spin.custom_minimum_size = Vector2(160, 0)
	_row2.add_child(_seed_spin)

	_resolve_items_chk.text = "Resolve Items"
	_resolve_items_chk.button_pressed = false
	_row2.add_child(_resolve_items_chk)

	var samples_lbl := Label.new()
	samples_lbl.text = "Print First N"
	_row2.add_child(samples_lbl)
	_samples_spin.min_value = 0
	_samples_spin.max_value = 100
	_samples_spin.step = 1
	_samples_spin.value = 8
	_samples_spin.custom_minimum_size = Vector2(110, 0)
	_row2.add_child(_samples_spin)

	# Row 3: monster level override, boss charge, post-boss shift
	_row3.add_theme_constant_override("separation", 8)
	_col.add_child(_row3)

	_override_chk.text = "Override Monster Lv"
	_override_chk.button_pressed = false
	_row3.add_child(_override_chk)
	_override_chk.toggled.connect(func(_on: bool) -> void:
		_override_lvl_spin.editable = _override_chk.button_pressed
	)

	_override_lvl_spin.min_value = 1
	_override_lvl_spin.max_value = 150
	_override_lvl_spin.step = 1
	_override_lvl_spin.value = 1
	_override_lvl_spin.editable = false
	_override_lvl_spin.custom_minimum_size = Vector2(100, 0)
	_row3.add_child(_override_lvl_spin)

	_boss_charge_label.text = "Boss Charge"
	_row3.add_child(_boss_charge_label)
	_boss_charge.min_value = 0.0
	_boss_charge.max_value = 1.0
	_boss_charge.step = 0.01
	_boss_charge.value = 0.0
	_boss_charge.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_row3.add_child(_boss_charge)

	var post_lbl := Label.new()
	post_lbl.text = "Post‑boss Shift Left"
	_row3.add_child(post_lbl)
	_post_boss_spin.min_value = 0
	_post_boss_spin.max_value = 12
	_post_boss_spin.step = 1
	_post_boss_spin.value = 0
	_post_boss_spin.custom_minimum_size = Vector2(140, 0)
	_row3.add_child(_post_boss_spin)

	# Row 4: run buttons
	_row4.add_theme_constant_override("separation", 8)
	_col.add_child(_row4)

	_run_btn.text = "Run Trials"
	_run_btn.custom_minimum_size = Vector2(160, 0)
	_row4.add_child(_run_btn)
	_run_btn.pressed.connect(_on_run_pressed)

	_one_btn.text = "Sample One"
	_one_btn.custom_minimum_size = Vector2(140, 0)
	_row4.add_child(_one_btn)
	_one_btn.pressed.connect(_on_one_pressed)

	_clr_btn.text = "Clear Output"
	_clr_btn.custom_minimum_size = Vector2(140, 0)
	_row4.add_child(_clr_btn)
	_clr_btn.pressed.connect(func() -> void:
		_out.clear()
	)

	# Output area
	_out.bbcode_enabled = true
	_out.scroll_active = true
	_out.fit_content = false
	_out.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_out.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_out.custom_minimum_size = Vector2(0, 280)
	_col.add_child(_out)

# ---------- Helpers ----------
func _get_loot_system() -> Node:
	# Prefer autoload singleton at /root/LootSystem; else instantiate a local copy (loads JSON on _ready).
	var n: Node = get_tree().root.get_node_or_null(^"/root/LootSystem")
	if n != null:
		return n
	var inst: Node = LootSystemClass.new()
	add_child(inst)
	return inst

func _default_seed() -> int:
	var root: Node = get_tree().root
	var sm: Node = root.get_node_or_null(^"/root/SaveManager")
	if sm != null and sm.has_method("get_run_seed"):
		var slot: int = 1
		if sm.has_meta("DEFAULT_SLOT"):
			var mv: Variant = sm.get_meta("DEFAULT_SLOT")
			if mv is int:
				slot = int(mv)
		return int(sm.call("get_run_seed", slot))
	# deterministic fallback for editor
	return 123456789

func _source_str() -> String:
	var idx: int = _source_opt.get_selected()   # <- use index
	if idx < 0:
		return "trash"
	return _source_opt.get_item_text(idx).to_lower()

func _inc(d: Dictionary, k: String, by: int) -> void:
	var cur: int = 0
	if d.has(k):
		cur = int(d[k])
	d[k] = cur + by

func _update_boss_controls_enabled() -> void:
	var src: String = _source_str()
	var boss: bool = (src == "boss")
	_boss_charge.editable = boss
	_boss_charge_label.modulate = (Color(1,1,1) if boss else Color(1,1,1,0.5))

# ---------- Actions ----------
func _on_run_pressed() -> void:
	var trials: int = int(_trials_spin.value)
	var base_seed: int = int(_seed_spin.value)
	var floor_i: int = int(_floor_spin.value)
	var player_lvl: int = int(_player_spin.value)
	var src: String = _source_str()
	var post_shift: int = int(_post_boss_spin.value)
	var use_override: bool = _override_chk.button_pressed
	var monster_lvl: int = int(_override_lvl_spin.value) if use_override else 0
	var charge: float = float(_boss_charge.value) if src == "boss" else -1.0
	var do_resolve: bool = _resolve_items_chk.button_pressed
	var print_n: int = int(_samples_spin.value)

	var summary := _run_trials(trials, base_seed, floor_i, player_lvl, src, monster_lvl, post_shift, charge, do_resolve, print_n)
	_out.append_text(summary + "\n")
	print(summary)  # <-- also send to Output

func _on_one_pressed() -> void:
	_trials_spin.value = 1
	_samples_spin.value = 1
	_on_run_pressed()

# ---------- Core simulation ----------
func _run_trials(
		trials: int,
		base_seed: int,
		floor_i: int,
		player_lvl: int,
		src: String,
		monster_lvl_override: int,
		post_shift_left: int,
		boss_charge: float,
		resolve_items: bool,
		print_first_n: int
	) -> String:

	# Aggregates
	var rar_ct: Dictionary = {}
	var cat_ct: Dictionary = {}
	var item_ct: Dictionary = {}
	for r in RARITY_ORDER:
		rar_ct[r] = 0

	var gold_sum: int = 0
	var shards_sum: int = 0
	var xp_sum: int = 0

	# Target-level stats
	var tl_min: int =  1_000_000
	var tl_max: int = -1_000_000
	var tl_sum: int = 0

	var lines: Array[String] = []

	for i in trials:
		# Deterministic seed per trial
		var seed_str := "%d|%d|%s|%d" % [base_seed, floor_i, src, i]
		var rng_seed: int = int(String(seed_str).hash())

		# Deterministic target level used by LootSystem for this trial
		var t_lvl_trial: int = _trial_target_level_for(src, floor_i, rng_seed, monster_lvl_override)
		if t_lvl_trial < tl_min: tl_min = t_lvl_trial
		if t_lvl_trial > tl_max: tl_max = t_lvl_trial
		tl_sum += t_lvl_trial

		# Build ctx for LootSystem (pass the same target level)
		var ctx: Dictionary = {
			"rng_seed": rng_seed,
			"player_level": player_lvl,
			"post_boss_encounters_left": post_shift_left,
			"target_level": t_lvl_trial
		}
		if src == "boss" and boss_charge >= 0.0:
			ctx["boss_charge_factor"] = clampf(boss_charge, 0.0, 1.0)

		# Roll loot
		var loot: Dictionary = _roll_loot(src, floor_i, ctx)

		# Aggregate rarity
		var rarity: String = String(loot.get("rarity", "U"))
		_inc(rar_ct, rarity, 1)

		# Category (distinguish "shards only" when pre-roll hit)
		var category: String = String(loot.get("category", ""))
		if category.is_empty():
			var sh: int = int(loot.get("shards", 0))
			category = "shards_only" if sh > 0 else "none"
		_inc(cat_ct, category, 1)

		# Currency sums
		var g: int = int(loot.get("gold", 0))
		var s: int = int(loot.get("shards", 0))
		gold_sum += g
		shards_sum += s

		# Character XP preview (dry; do not grant). Use the SAME trial level.
		var xp_add: int = 0
		if src != "chest":
			var wiggle_rng := RandomNumberGenerator.new()
			var cxp_seed_str := "%d|%d|%s|cxp" % [base_seed, i, src]
			wiggle_rng.seed = int(String(cxp_seed_str).hash())
			xp_add = XpTuning.char_xp_for_victory(player_lvl, t_lvl_trial, src, rarity, wiggle_rng)
		xp_sum += xp_add

		# Optionally resolve items
		if resolve_items:
			var items_arr: Array = ItemResolver.resolve(loot)
			for it_any in items_arr:
				if it_any is Dictionary:
					var it: Dictionary = it_any
					var id_str: String = String(it.get("id", ""))
					var count_i: int = int(it.get("count", 1))
					_inc(item_ct, id_str, count_i)

		# Print sample rows
		if i < print_first_n:
			var line := "[b]%s[/b] F%d → rarity=%s, cat=%s, gold=%d, shards=%d" % [
				src.capitalize(), floor_i, rarity, category, g, s
			]
			if src == "boss" and boss_charge > 0.0:
				line += "  (charge=%.2f)" % boss_charge
			if monster_lvl_override > 0:
				line += "  (monster_lv=%d)" % monster_lvl_override
			else:
				line += "  (trial_lv=%d)" % t_lvl_trial
			if src != "chest" and xp_add > 0:
				line += "  [xp=%d]" % xp_add
			lines.append(line)

	# Summary text
	var trials_f: float = float(trials)
	var gold_avg: float = (float(gold_sum) / trials_f) if trials > 0 else 0.0
	var shards_avg: float = (float(shards_sum) / trials_f) if trials > 0 else 0.0
	var xp_avg: float = (float(xp_sum) / trials_f) if trials > 0 else 0.0

	var header := "[center][b]Loot Trials[/b][/center]\n"
	header += "Source: [b]%s[/b]   Floor: [b]%d[/b]   Player Lv: [b]%d[/b]\n" % [src.capitalize(), floor_i, player_lvl]

	var tl_avg: float = (float(tl_sum) / float(max(1, trials)))
	header += "Target Lv Range: [b]%d[/b]…[b]%d[/b]   Avg: [b]%.2f[/b]\n" % [tl_min, tl_max, tl_avg]
	if monster_lvl_override > 0:
		header += "Override Monster Lv: [b]%d[/b]\n" % monster_lvl_override
	if src == "boss" and boss_charge > 0.0:
		header += "Charge: [b]%.2f[/b]\n" % boss_charge
	header += "Trials: [b]%d[/b]\n" % trials

	var rar_lines: Array[String] = []
	var total_rolled: int = trials
	for r in RARITY_ORDER:
		var c: int = int(rar_ct.get(r, 0))
		var pct: float = (100.0 * float(c) / float(max(1, total_rolled)))
		rar_lines.append("  %s: %d (%.1f%%)" % [r, c, pct])

	var cat_lines: Array[String] = []
	var keys: Array = cat_ct.keys()
	keys.sort()
	for k_any in keys:
		var k: String = String(k_any)
		var v: int = int(cat_ct[k_any])
		var pct2: float = (100.0 * float(v) / float(max(1, total_rolled)))
		cat_lines.append("  %s: %d (%.1f%%)" % [k, v, pct2])

	var sb: String = ""
	sb += header
	sb += "[b]Rarities:[/b]\n"
	for rl in rar_lines:
		sb += rl + "\n"
	sb += "[b]Categories:[/b]\n"
	for cl in cat_lines:
		sb += cl + "\n"
	sb += "[b]Averages:[/b]  gold=%.2f   shards=%.2f   xp=%.2f\n" % [gold_avg, shards_avg, xp_avg]

	if resolve_items and item_ct.size() > 0:
		sb += "[b]Items (counts):[/b]\n"
		var ikeys: Array = item_ct.keys()
		ikeys.sort()
		for id_any in ikeys:
			var id_str: String = String(id_any)
			var cnt: int = int(item_ct[id_any])
			sb += "  %s x%d\n" % [id_str, cnt]

	if lines.size() > 0:
		sb += "\n[b]Samples:[/b]\n"
		for ln in lines:
			sb += ln + "\n"

	return sb

# ---------- Engine bridge ----------
func _roll_loot(src: String, floor_i: int, ctx: Dictionary) -> Dictionary:
	# Prefer autoload singleton method call; fallback to instance call.
	# Using call() avoids static typing warnings and keeps compatibility.
	if _loot_node != null and _loot_node.has_method("roll_loot"):
		var res: Variant = _loot_node.call("roll_loot", src, floor_i, ctx)
		if typeof(res) == TYPE_DICTIONARY:
			return res as Dictionary
	# If not available, fail gracefully with an empty loot dict so UI still works.
	return {
		"source": src, "floor": floor_i, "rarity": "U", "category": "",
		"gold": 0, "shards": 0, "pity_used": false, "post_boss_shift_applied": false
	}

# Map PL -> Monster Level
const LV_SCALE: float = 0.2  # level ≈ round(PL/5)

func _trial_target_level_for(src: String, floor_i: int, rng_seed: int, monster_override: int) -> int:
	if monster_override > 0:
		return monster_override

	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed

	# Sample TRASH PL band, then apply role multiplier for elites/bosses
	var band: Vector2i = SetPL.band_for_floor(floor_i)
	var pl: int = rng.randi_range(band.x, band.y)

	match src:
		"elite":
			pl = int(round(float(pl) * SetPL.ELITE_MULT))
		"boss":
			pl = int(round(float(pl) * SetPL.BOSS_MULT))
		"trash", "chest":
			# trash/baseline already in PL; chest handled below
			pass
		_:
			pass

	if src == "chest":
		# Chest uses the same band (already sampled above). If you want a separate roll, resample here.
		# (Most people just keep the same deterministic seed so test view matches LootSystem.)
		# pl remains whatever we rolled above.
		pass

	# Convert PL -> monster level
	var lv: int = int(round(LV_SCALE * float(pl)))
	return max(1, lv)
