# res://scripts/dungeon/encounters/EliteSpawner.gd
extends Node3D
class_name EliteSpawner

@export var monster_id: StringName = &"bat"        # now expect a slug; legacy Mxx still works via MonsterCatalog.resolve_slug
@export var start_battle_on_interact: bool = false
@export var interact_action: StringName = &"interact"
@export var player_group: StringName = &"player"

var _spawned: Node3D = null
var _dead: bool = false
var _area: Area3D
var _in_range: bool = false

func _ready() -> void:
	var slug := MonsterCatalog.resolve_slug(monster_id)
	_spawned = MonsterCatalog.instantiate_visual(self, slug)
	if _spawned == null:
		_spawned = _make_fallback_box()
	AnimAuto.play_idle(_spawned)

	# Simple proximity area (press E near the elite)
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
	var co: CollisionObject3D = body as CollisionObject3D
	if co != null and co.is_in_group(player_group):
		_in_range = true

func _on_exit(body: Node) -> void:
	var co: CollisionObject3D = body as CollisionObject3D
	if co != null and co.is_in_group(player_group):
		_in_range = false

func _process(_dt: float) -> void:
	if _dead: return
	if _in_range and (Input.is_action_just_pressed(interact_action) or Input.is_key_pressed(KEY_E)):
		if start_battle_on_interact:
			var slug := MonsterCatalog.resolve_slug(monster_id)
			EncounterRouter.request_encounter({ "enemy": slug, "monster_id": slug, "role": "elite" })
			_dead = true # optional despawn on start
		else:
			_die_now()

func _die_now() -> void:
	_dead = true
	var slug := MonsterCatalog.resolve_slug(monster_id)
	var enc := get_node_or_null(^"/root/EncounterDirector")
	var payload := {
		"role": "elite",
		"monster_id": slug,
		"enemy": slug,
		"world_pos": global_transform.origin,
		"floor": (int(enc.get("_floor")) if enc != null and enc.has_method("get") else -1),
		"triad_id": (int(enc.get("_triad_id")) if enc != null and enc.has_method("get") else -1),
		"run_seed": (int(enc.get("_run_seed")) if enc != null and enc.has_method("get") else 0),
		"pool": (enc.get("_pool") if enc != null and enc.has_method("get") else [])
	}
	print("[Encounter][EliteDefeated] payload=", JSON.stringify(payload, " "))
	# After your existing: print("[Encounter][EliteDefeated] payload=", payload)
	var seed_for_loot: int = int(payload.get("run_seed", 0)) ^ 0xB055
	LootReward.encounter_victory("elite", int(payload.get("floor", 1)), String(payload.get("enemy","elite")), seed_for_loot, 0)

	
	_disable_collision_recursive(self)
	var tw := create_tween()
	tw.tween_property(self, "scale", Vector3(0.0, 0.0, 0.0), 0.35).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
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
	bm.size = Vector3(1.0, 1.8, 1.0)
	mi.mesh = bm
	return mi
