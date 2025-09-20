extends Control

@export var main_scene: PackedScene
@export var combat_scene: PackedScene

@onready var _btn_new: Button = %NewButton
@onready var _btn_continue: Button = %ContinueButton
@onready var _btn_combat: Button = %CombatButton

func _ready() -> void:
	_btn_new.text = "New Dungeon"
	_btn_combat.text = "Combat"
	_btn_new.pressed.connect(_on_new)
	_btn_continue.pressed.connect(_on_continue)
	_btn_combat.pressed.connect(_on_combat)
	_refresh_continue()
	visibility_changed.connect(_refresh_continue)  # refresh when the menu becomes visible again
	SaveManager.debug_print_presence()


	print("[RUN] exists=", SaveManager.run_exists(),
		" depth=", SaveManager.peek_run_depth(),
		" current_floor(persistent)=", SaveManager.get_current_floor())

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

func _on_new() -> void:
	SaveManager.request_continue = false

	# Preferred: one-call helper (exists in the JSON SaveManager I gave you)
	if SaveManager.has_method("start_new_run"):
		SaveManager.start_new_run(true)  # true = clear floor_seeds
	else:
		# Fallback for older SaveManager: do it manually with Dictionaries
		SaveManager.delete_run()
		var gs: Dictionary = SaveManager.load_game()
		gs["previous_floor"] = 0
		gs["current_floor"] = 1
		var last_floor: int = 1
		if gs.has("last_floor"):
			last_floor = int(gs["last_floor"])
		gs["last_floor"] = max(1, last_floor)
		gs["floor_seeds"] = {}  # reset seeds for a fresh run
		SaveManager.save_game(gs)

		RunState.new_run()          # resets depth=1, hp/mp, seed
		SaveManager.save_current_run()

	get_tree().change_scene_to_packed(main_scene)


func _on_continue() -> void:
	SaveManager.request_continue = true
	# Make sure RunState (hp/mp/gold/items) matches the saved run before loading scene
	if SaveManager.run_exists() and SaveManager.has_method("load_current_run"):
		SaveManager.load_current_run()
	get_tree().change_scene_to_packed(main_scene)

func _on_combat() -> void:
	if combat_scene != null:
		get_tree().change_scene_to_packed(combat_scene)
