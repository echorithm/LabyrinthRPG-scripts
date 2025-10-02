extends Control

# Scenes
@export var main_scene: PackedScene

# Services
const _VS := preload("res://persistence/services/village_service.gd")
const _VW := preload("res://persistence/services/village_wallet.gd")
const _BS := preload("res://persistence/services/buff_service.gd") # <— preload so it's always available

# UI roots
var _vbox_root: VBoxContainer
var _lbl_title: Label
var _lbl_stash: Label

# Camp
var _lbl_camp: Label
var _lbl_camp_next: Label
var _btn_camp_upgrade: Button
var _btn_open_stash: Button

# Entrance
var _lbl_entrance: Label
var _floor_list: OptionButton
var _btn_enter: Button
var _btn_dump_state: Button

# Buildings list
var _buildings_box: VBoxContainer
var _building_rows: Dictionary = {}   # id -> { "label":Label, "button":Button }

func _ready() -> void:
	_build_village_panel()
	_refresh_village_panel()

# -------------------------------------------------
# UI BUILD
# -------------------------------------------------
func _build_village_panel() -> void:
	# Scroll root so we don’t overlap anything
	var sc := ScrollContainer.new()
	sc.name = "VillageScroll"
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.anchor_left = 0.0
	sc.anchor_right = 1.0
	sc.anchor_top = 0.0
	sc.anchor_bottom = 1.0
	sc.offset_left = 16
	sc.offset_right = -16
	sc.offset_top = 16
	sc.offset_bottom = -16
	add_child(sc)

	_vbox_root = VBoxContainer.new()
	_vbox_root.name = "VillagePanel"
	_vbox_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_vbox_root.add_theme_constant_override("separation", 6)
	sc.add_child(_vbox_root)

	# Title + stash
	_lbl_title = Label.new()
	_lbl_title.text = "Village (Camp + Dungeon Entrance)"
	_lbl_title.add_theme_font_size_override("font_size", 18)
	_vbox_root.add_child(_lbl_title)

	_lbl_stash = Label.new()
	_vbox_root.add_child(_lbl_stash)

	# --- Camp ---
	var camp_box := VBoxContainer.new()
	camp_box.add_theme_constant_override("separation", 4)
	_vbox_root.add_child(camp_box)

	_lbl_camp = Label.new()
	camp_box.add_child(_lbl_camp)

	_lbl_camp_next = Label.new()
	camp_box.add_child(_lbl_camp_next)

	var camp_btns := HBoxContainer.new()
	camp_box.add_child(camp_btns)

	_btn_camp_upgrade = Button.new()
	_btn_camp_upgrade.text = "Upgrade Camp (stash)"
	_btn_camp_upgrade.pressed.connect(_on_camp_upgrade)
	camp_btns.add_child(_btn_camp_upgrade)

	_btn_open_stash = Button.new()
	_btn_open_stash.text = "Open Stash (placeholder)"
	_btn_open_stash.pressed.connect(func() -> void:
		print("[Village] Stash UI not implemented yet. Gold/Shards only.")
	)
	camp_btns.add_child(_btn_open_stash)

	# --- Dungeon Entrance ---
	var ent_box := VBoxContainer.new()
	ent_box.add_theme_constant_override("separation", 4)
	_vbox_root.add_child(ent_box)

	_lbl_entrance = Label.new()
	_lbl_entrance.text = "Dungeon Entrance"
	ent_box.add_child(_lbl_entrance)

	var ent_row := HBoxContainer.new()
	ent_box.add_child(ent_row)

	_floor_list = OptionButton.new()
	_floor_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ent_row.add_child(_floor_list)

	_btn_enter = Button.new()
	_btn_enter.text = "Enter Labyrinth"
	_btn_enter.pressed.connect(_on_enter_clicked)
	ent_row.add_child(_btn_enter)

	_btn_dump_state = Button.new()
	_btn_dump_state.text = "Print State (buffs & village)"
	_btn_dump_state.pressed.connect(_on_dump_state)
	ent_row.add_child(_btn_dump_state)

	# --- Buildings list (quick test) ---
	_buildings_box = VBoxContainer.new()
	_buildings_box.add_theme_constant_override("separation", 4)
	_vbox_root.add_child(_buildings_box)

	var lbl := Label.new()
	lbl.text = "Buildings (RTS/Services) — quick test"
	_buildings_box.add_child(lbl)

	_building_rows.clear()
	for id_any in _VS.list_all_buildings():
		var id := String(id_any)
		if id == "camp":
			continue

		var row := HBoxContainer.new()
		var tag := Label.new()
		row.add_child(tag)

		var btn := Button.new()
		btn.text = "Upgrade"
		var capture_id := id
		btn.pressed.connect(func() -> void:
			_on_upgrade_building(capture_id)
		)
		row.add_child(btn)

		_buildings_box.add_child(row)
		_building_rows[id] = { "label": tag, "button": btn }

# -------------------------------------------------
# REFRESH
# -------------------------------------------------
func _refresh_village_panel() -> void:
	# Stash
	var gs := SaveManager.load_game()
	var gold: int = int(gs.get("stash_gold", 0))
	var shards: int = int(gs.get("stash_shards", 0))
	_lbl_stash.text = "Stash — Gold: %d | Shards: %d" % [gold, shards]

	# Camp
	var lvl: int = _VS.get_camp_level()
	var name_now: String = _VS.new().camp_level_name(lvl)
	_lbl_camp.text = "Camp: L%d — %s" % [lvl, name_now]

	var can := _VS.can_upgrade_camp()
	var next_txt: String
	if bool(can.get("can", false)):
		var cost := can["cost"] as Dictionary
		next_txt = "Next: L%d (Cost %d G / %d shards)" % [int(can["level_next"]), int(cost["gold"]), int(cost["shards"])]
	else:
		var c := _VS.new().next_camp_cost(lvl)
		next_txt = "Next: L%d (Cost %d G / %d shards)" % [lvl + 1, int(c["gold"]), int(c["shards"])]
	_lbl_camp_next.text = next_txt
	_btn_camp_upgrade.disabled = not bool(can.get("can", false))

	# Update unlocks that become available by camp level
	_VS.try_unlock_all()

	# Entrance floors picker
	_refresh_floor_list()

	# Buildings rows (labels/buttons)
	_refresh_buildings_ui()

func _refresh_floor_list() -> void:
	_floor_list.clear()
	var floors := _list_entrance_floors()
	for f in floors:
		_floor_list.add_item("Floor %d" % f, f)
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

func _refresh_buildings_ui() -> void:
	for id in _building_rows.keys():
		var row: Dictionary = _building_rows[id]
		var tag: Label = row["label"]
		var btn: Button = row["button"]

		var unlocked := _VS.is_unlocked(id)
		var status := "Unlocked" if unlocked else "Locked"
		var lvl := _VS.get_level(id)
		tag.text = "%s — %s — L%d" % [id.capitalize(), status, lvl]

		var chk := _VS.can_upgrade(id)
		var can := bool(chk.get("can", false))
		btn.disabled = not can

		# Helpful tooltip on why a thing can’t upgrade
		var tip := ""
		if not unlocked:
			tip = "Locked. Raise Camp to unlock."
		elif not can:
			var reason := String(chk.get("reason", ""))
			if reason == "prereq_fail":
				tip = "Upgrade blocked by RTS prereqs (Farms/Trade/Housing)."
			elif reason == "insufficient_funds":
				var cost := chk.get("cost", {}) as Dictionary
				tip = "Need %d Gold / %d Shards in stash." % [int(cost.get("gold",0)), int(cost.get("shards",0))]
			else:
				tip = "Cannot upgrade."
		btn.tooltip_text = tip

# -------------------------------------------------
# ACTIONS
# -------------------------------------------------
func _on_camp_upgrade() -> void:
	var res := _VS.upgrade("camp")
	# Rebuild buffs if a run is active
	if SaveManager.run_exists():
		_BS.rebuild_run_buffs()
	print("[Village] Camp upgrade result: ", res)
	_refresh_village_panel()

func _on_enter_clicked() -> void:
	if _floor_list.item_count == 0:
		return
	var floor := _floor_list.get_selected_id()
	if floor <= 0:
		return
	SaveManager.start_or_refresh_run_from_meta()
	SaveManager.set_run_floor(floor)
	# Make sure run picks up village/equipment buffs
	_BS.on_run_start()
	if main_scene != null:
		get_tree().change_scene_to_packed(main_scene)

func _on_upgrade_building(id: String) -> void:
	var res := _VS.upgrade(id)
	print("[VillageUI] ", id, " upgrade: ", res)
	# Rebuild buffs if a run is active (so mods_village updates immediately)
	if SaveManager.run_exists():
		_BS.rebuild_run_buffs()
	_refresh_village_panel()

func _on_dump_state() -> void:
	# Rebuild first so what we print is current
	if SaveManager.run_exists():
		_BS.rebuild_run_buffs()

	# META
	var gs := SaveManager.load_game()
	var gold: int = int(gs.get("stash_gold", 0))
	var shards: int = int(gs.get("stash_shards", 0))
	var v: Dictionary = (gs.get("village", {}) as Dictionary)
	var camp_level: int = int(v.get("camp_level", 0))
	var unlocked: Dictionary = (v.get("unlocked", {}) as Dictionary)
	var buildings: Dictionary = (v.get("buildings", {}) as Dictionary)
	var rts: Dictionary = (buildings.get("rts", {}) as Dictionary)
	var services: Dictionary = (buildings.get("services", {}) as Dictionary)

	# RUN
	var has_run := SaveManager.run_exists()
	var run: Dictionary = SaveManager.load_run() if has_run else {}
	var buffs: Array = (run.get("buffs", []) as Array) if has_run else []
	var mods_affix: Dictionary = (run.get("mods_affix", {}) as Dictionary) if has_run else {}
	var mods_village: Dictionary = (run.get("mods_village", {}) as Dictionary) if has_run else {}
	var weapon_tags: Array = (run.get("weapon_tags", []) as Array) if has_run else []
	var depth: int = int(run.get("depth", 0)) if has_run else 0
	var seed: int = int(run.get("run_seed", 0)) if has_run else 0

	var floors := _list_entrance_floors()

	print_rich("[b][Village][/b] stash_gold=", gold, " shards=", shards)
	print_rich("  camp_level=", camp_level)
	print_rich("  unlocked=", unlocked)
	print_rich("  rts=", rts)
	print_rich("  services=", services)

	if has_run:
		print_rich("[b][Run][/b] depth=", depth, " seed=", seed)
		print_rich("  buffs=", buffs)
		print_rich("  mods_affix=", mods_affix)
		print_rich("  mods_village=", mods_village)
		print_rich("  weapon_tags=", weapon_tags)
	else:
		print_rich("[b][Run][/b] (no active run)")

	print_rich("[b][Entrance Floors][/b] ", floors)
