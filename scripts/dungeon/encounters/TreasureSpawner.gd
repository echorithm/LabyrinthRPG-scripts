extends Node3D
class_name TreasureSpawner

@export var chest_scene: PackedScene            # assign your chest.tscn when ready
@export var interact_action: StringName = &"interact"
@export var player_group: StringName = &"player"
@export var chest_level: String = "common" # "common" or "rare"

var _spawned: Node3D
var _area: Area3D
var _opened: bool = false
var _in_range: bool = false

func _ready() -> void:
	# Visual
	if chest_scene != null:
		_spawned = chest_scene.instantiate() as Node3D
	else:
		_spawned = _make_fallback_box()
	add_child(_spawned)

	# Try to idle (AnimationPlayer with "IdleNormal" recommended)
	AnimAuto.play_idle(_spawned)

	# Proximity area for interact
	_area = Area3D.new()
	_area.collision_layer = 0
	_area.collision_mask = 1
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 1.6
	cs.shape = sph
	_area.add_child(cs)
	add_child(_area)
	_area.body_entered.connect(_on_enter)
	_area.body_exited.connect(_on_exit)

	set_process(true)

func _on_enter(body: Node) -> void:
	var co := body as CollisionObject3D
	if co != null and co.is_in_group(player_group):
		_in_range = true

func _on_exit(body: Node) -> void:
	var co := body as CollisionObject3D
	if co != null and co.is_in_group(player_group):
		_in_range = false

func _process(_dt: float) -> void:
	if _opened:
		return
	if _in_range and (Input.is_action_just_pressed(interact_action) or Input.is_key_pressed(KEY_E)):
		_open_now()

func _open_now() -> void:
	_opened = true
	print("[Treasure] Opened @ ", str(global_transform.origin), " → grant loot (TODO)")
	LootReward.chest_open("common", global_transform.origin) # or "rare"

	_disable_collision_recursive(self)
	var tw := create_tween()
	tw.tween_property(self, "scale", Vector3(0.0, 0.0, 0.0), 0.30).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.finished.connect(queue_free)

func _disable_collision_recursive(n: Node) -> void:
	for c in n.get_children():
		_disable_collision_recursive(c)
	var co := n as CollisionObject3D
	if co != null:
		co.collision_layer = 0
		co.collision_mask = 0

func _make_fallback_box() -> Node3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.9, 0.7, 0.9)
	mi.mesh = bm
	return mi
