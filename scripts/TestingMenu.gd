extends Control

@export var main_scene: PackedScene
@export var combat_scene: PackedScene

@onready var _btn_new: Button       = %NewButton
@onready var _btn_continue: Button  = %ContinueButton
@onready var _btn_combat: Button    = %CombatButton

# Dynamically created testing helpers
var _tp_row: HBoxContainer
var _tp_list: OptionButton
var _btn_tp: Button
var _btn_exit_safe: Button
var _btn_exit_death: Button

func _ready() -> void:
	_btn_new.text = "New Dungeon"
	_btn_combat.text = "Combat"
	_btn_new.pressed.connect(_on_new)
	_btn_continue.pressed.connect(_on_continue)
	_btn_combat.pressed.connect(_on_combat)
	visibility_changed.connect(_refresh_continue)  # refresh when the menu becomes visible again
	SaveManager.debug_print_presence()
	

	print("[RUN] exists=", SaveManager.run_exists(),
		" depth=", SaveManager.peek_run_depth(),
		" current_floor(persistent)=", SaveManager.get_current_floor())

	_build_testing_row()
	_refresh_continue()
	_refresh_teleport_list()

func _build_testing_row() -> void:
	# Creates a simple row at the bottom for Teleport & End-Run actions
	_tp_row = HBoxContainer.new()
	_tp_row.name = "TestingRow"
	_tp_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tp_row.anchor_left = 0.0
	_tp_row.anchor_right = 1.0
	_tp_row.anchor_top = 1.0
	_tp_row.anchor_bottom = 1.0
	_tp_row.offset_left = 16
	_tp_row.offset_right = -16
	_tp_row.offset_top = -48
	_tp_row.offset_bottom = -16
	add_child(_tp_row)

	_tp_list = OptionButton.new()
	_tp_list.name = "TeleportList"
	_tp_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tp_row.add_child(_tp_list)

	_btn_tp = Button.new()
	_btn_tp.text = "Teleport"
	_btn_tp.pressed.connect(_on_teleport_pressed)
	_tp_row.add_child(_btn_tp)

	_btn_exit_safe = Button.new()
	_btn_exit_safe.text = "Safe Exit"
	_btn_exit_safe.pressed.connect(_on_end_run_safe)
	_tp_row.add_child(_btn_exit_safe)

	_btn_exit_death = Button.new()
	_btn_exit_death.text = "Die Here"
	_btn_exit_death.pressed.connect(_on_end_run_death)
	_tp_row.add_child(_btn_exit_death)

func _refresh_continue() -> void:
	var has_meta: bool = SaveManager.exists()
	var has_run: bool = SaveManager.run_exists()

	if has_meta or has_run:
		var f: int = SaveManager.get_current_floor()
		if f <= 0 and has_run:
			f = SaveManager.peek_run_depth()
		_btn_continue.disabled = false
		_btn_continue.text = "Continue Dungeon (Floor %d)" % [max(1, f)]
	else:
		_btn_continue.disabled = true
		_btn_continue.text = "Continue Dungeon (No Save)"

	# Enable/disable teleport and end-run helpers
	var enabled: bool = has_meta or has_run
	_btn_tp.disabled = not enabled
	_btn_exit_safe.disabled = not enabled
	_btn_exit_death.disabled = not enabled
	_tp_list.disabled = not enabled

func _refresh_teleport_list() -> void:
	_tp_list.clear()

	var unlocked: Array[int] = _list_unlocked_floors()
	for i in unlocked.size():
		var floor: int = unlocked[i]
		_tp_list.add_item("Floor %d" % floor, floor)

	# Try to select current floor if present
	var cur: int = 1
	if SaveManager.run_exists():
		cur = SaveManager.peek_run_depth()
	else:
		if SaveManager.exists():
			cur = SaveManager.get_current_floor()
	for i in range(_tp_list.item_count):
		if _tp_list.get_item_id(i) == cur:
			_tp_list.select(i)
			break

func _on_new() -> void:
	SaveManager.request_continue = false

	# New run start
	if SaveManager.has_method("start_new_run"):
		SaveManager.start_new_run(true)  # clear seeds (legacy path; harmless with new schema)
	else:
		# very old fallback
		SaveManager.delete_run()
		var gs: Dictionary = SaveManager.load_game()
		gs["previous_floor"] = 0
		gs["current_floor"] = 1
		gs["last_floor"] = 1
		
		SaveManager.save_game(gs)
		RunState.new_run()
		SaveManager.save_current_run()

	# Load run state into memory before scene swap
	if SaveManager.has_method("load_current_run"):
		SaveManager.load_current_run()

	_refresh_teleport_list()
	get_tree().change_scene_to_packed(main_scene)

func _on_continue() -> void:
	SaveManager.request_continue = true
	if SaveManager.run_exists() and SaveManager.has_method("load_current_run"):
		SaveManager.load_current_run()
	get_tree().change_scene_to_packed(main_scene)

func _on_combat() -> void:
	if combat_scene != null:
		get_tree().change_scene_to_packed(combat_scene)

# --- Teleport & End-Run actions ---

func _on_teleport_pressed() -> void:
	if _tp_list.item_count == 0:
		return
	var floor: int = _tp_list.get_selected_id()
	if floor <= 0:
		return

	# Ensure a run exists; if not, start one quickly
	if not SaveManager.run_exists():
		if SaveManager.has_method("start_new_run"):
			SaveManager.start_new_run(true)
		else:
			var gs: Dictionary = SaveManager.load_game()
			gs["previous_floor"] = 0
			gs["current_floor"] = 1
			gs["last_floor"] = 1
			gs["floor_seeds"] = {}
			SaveManager.save_game(gs)
			RunState.new_run()
			SaveManager.save_current_run()

	# Prefer TeleportService if present (handles drained logic & segment)
	if Engine.has_singleton("TeleportService") or ClassDB.class_exists("TeleportService"):
		if TeleportService.teleport_to(floor):
			print("[Teleport] Jumped to floor ", floor)
		else:
			print("[Teleport] Not unlocked: ", floor)
	else:
		# Fallback: manually set floor; SaveManager.set_run_floor updates furthest_depth_reached
		SaveManager.set_run_floor(floor)
		print("[Teleport] (fallback) Jumped to floor ", floor)

	# Mirror to in-memory RunState if available
	if SaveManager.has_method("load_current_run"):
		SaveManager.load_current_run()

	_refresh_continue()

func _on_end_run_safe() -> void:
	# Safe exit: mirror run → meta, auto-deposit currencies (as per refactor)
	if SaveManager.has_method("end_run"):
		SaveManager.end_run(false)
	else:
		SaveManager.commit_run_to_meta(false)
	# After ending a run, update UI
	_refresh_continue()
	_refresh_teleport_list()
	print("[Run] Ended (safe exit).")

func _on_end_run_death() -> void:
	# Death: keep equipped only, lose inventory & unbanked currencies, reset progress
	if SaveManager.has_method("end_run"):
		SaveManager.end_run(true)
	else:
		SaveManager.commit_run_to_meta(true)
		if SaveManager.has_method("apply_death_penalties"):
			SaveManager.apply_death_penalties()
	# After ending a run, update UI
	_refresh_continue()
	_refresh_teleport_list()
	print("[Run] Ended (death).")

# --- helpers ---

func _list_unlocked_floors() -> Array[int]:
	# Prefer TeleportService (aware of highest_teleport_floor); otherwise compute from META.
	if Engine.has_singleton("TeleportService") or ClassDB.class_exists("TeleportService"):
		return TeleportService.list_unlocked()
	var out: Array[int] = [1]
	var gs: Dictionary = SaveManager.load_game()
	var max_t: int = 1
	if gs.has("highest_teleport_floor"):
		max_t = max(1, int(gs["highest_teleport_floor"]))
	var f: int = 4
	while f <= max_t:
		out.append(f)
		f += 3
	return out
