extends Node3D

@export var arena_scene: PackedScene = preload("res://art/monsters/Monster_test.tscn")
@export var player_path: NodePath = ^"../Player"
@export var spawn_anchor_path: NodePath = ^"Anchor_Spawn"
@export var mob_anchor_path: NodePath = ^"Anchor_Mob"

# Pick which monster to spawn here (or swap at runtime via set_monster())
@export var monster_scene: PackedScene = preload("res://art/monsters/battle_bee/battle_bee.tscn")

# Playback config
@export var repeats_per_clip: int = 5
@export var gap_between_repeats: float = 0.0
@export var gap_between_clips: float = 0.25
@export var auto_start: bool = true
@export var label_path: NodePath = ^"..HUD/Cords"

var _label: Label

var _arena: Node3D
var _mob: Node3D
var _ap: AnimationPlayer
var _names: Array[String] = []
var _idx: int = 0
var _repeats_left: int = 0
var _timer: Timer

func _ready() -> void:
	if arena_scene:
		_arena = arena_scene.instantiate() as Node3D
		add_child(_arena)

	var player: Node3D = get_node_or_null(player_path) as Node3D
	var spawn_anchor: Node3D = _arena.get_node_or_null(spawn_anchor_path) as Node3D if _arena else null
	if player and spawn_anchor:
		player.global_transform = spawn_anchor.global_transform
		
	_label = get_node_or_null(label_path) as Label
	if _label == null:
		push_warning("Label not found at: %s" % label_path)

	_spawn_monster()

	_timer = Timer.new()
	_timer.one_shot = true
	_timer.autostart = false
	_timer.timeout.connect(_on_timer_timeout)
	add_child(_timer)

	if auto_start:
		_begin_first_clip()

func _spawn_monster() -> void:
	if is_instance_valid(_mob):
		_mob.queue_free()
	_mob = null
	_ap = null

	if not monster_scene:
		push_warning("No monster_scene assigned.")
		return

	_mob = monster_scene.instantiate() as Node3D
	add_child(_mob)

	var mob_anchor: Node3D = _arena.get_node_or_null(mob_anchor_path) as Node3D if _arena else null
	if mob_anchor:
		_mob.global_transform = mob_anchor.global_transform

	_ap = _mob.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if not _ap:
		push_warning("AnimationPlayer not found under spawned monster.")
		return

	_names = _collect_ordered_clips(_ap)
	_idx = 0

	if not _ap.animation_finished.is_connected(_on_anim_finished):
		_ap.animation_finished.connect(_on_anim_finished)

func _collect_ordered_clips(ap: AnimationPlayer) -> Array[String]:
	var attacks: Array[String] = []
	var others: Array[String] = []

	for lib_key: StringName in ap.get_animation_library_list():
		var lib: AnimationLibrary = ap.get_animation_library(lib_key)
		if lib == null:
			continue
		for clip_name: StringName in lib.get_animation_list():
			var full: String = "%s/%s" % [str(lib_key), str(clip_name)]
			if str(lib_key).begins_with("Attack"):
				attacks.append(full)
			else:
				others.append(full)

	var rx := RegEx.new()
	rx.compile("^Attack(\\d+)$")

	attacks.sort_custom(func(a: String, b: String) -> bool:
		var ak: String = a.get_slice("/", 0)
		var bk: String = b.get_slice("/", 0)

		var ar: RegExMatch = rx.search(ak)
		var br: RegExMatch = rx.search(bk)

		var ai: int = 0
		var bi: int = 0
		if ar: ai = int(ar.get_string(1))
		if br: bi = int(br.get_string(1))
		return ai < bi
	)

	others.sort()
	return attacks + others

func _begin_first_clip() -> void:
	if not _ap or _names.is_empty():
		return
	_idx = 0
	_repeats_left = repeats_per_clip
	_play_current()

func _play_current() -> void:
	if not _ap or _names.is_empty():
		return

	var full_name: String = _names[_idx % _names.size()]
	_ap.play(full_name)
	_update_label(full_name)
	print(full_name)

	var lib_key: String = full_name.get_slice("/", 0)
	var clip: String = full_name.get_slice("/", 1)

	var lib: AnimationLibrary = _ap.get_animation_library(lib_key)
	var anim: Animation = lib.get_animation(clip) if lib else null

	var length: float
	if anim:
		length = max(0.016, anim.length)
	else:
		length = 1.0

	var pad: float
	if _repeats_left > 1:
		pad = gap_between_repeats
	else:
		pad = gap_between_clips

	_timer.start(length + pad)

func _advance_index() -> void:
	_idx += 1
	_repeats_left = repeats_per_clip

func _on_anim_finished(_anim_name: StringName) -> void:
	if _timer.time_left > 0.0:
		_timer.stop()
	if _repeats_left > 1:
		_repeats_left -= 1
		_play_current()
	else:
		_advance_index()
		_play_current()

func _on_timer_timeout() -> void:
	if _repeats_left > 1:
		_repeats_left -= 1
		_play_current()
	else:
		_advance_index()
		_play_current()

func set_monster(new_scene: PackedScene) -> void:
	monster_scene = new_scene
	_spawn_monster()
	_begin_first_clip()

func _update_label(full_name: String) -> void:
	if _label == null:
		return
	var lib_key: String = full_name.get_slice("/", 0)   # e.g. "Attack01"
	var clip: String = full_name.get_slice("/", 1)      # e.g. "Take 001"
	var rep_idx: int = (repeats_per_clip - _repeats_left + 1)
	if rep_idx < 1: 
		rep_idx = 1
	if rep_idx > repeats_per_clip:
		rep_idx = repeats_per_clip
	_label.text = "Anim: %s / %s  (repeat %d/%d)" % [lib_key, clip, rep_idx, repeats_per_clip]
	print("Anim: %s / %s  (repeat %d/%d)" % [lib_key, clip, rep_idx, repeats_per_clip])
