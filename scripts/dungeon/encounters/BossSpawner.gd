# res://scripts/dungeon/encounters/BossSpawner.gd
extends Node3D
class_name BossSpawner

@export var monster_id: StringName = &"dragon"   # slug preferred; legacy Mxx still works
@export var interact_action: StringName = &"interact"
@export var start_battle_on_interact: bool = false

@export var apply_scale: bool = false
@export var scale_multiplier: float = 1.0

var _spawned: Node3D
var _spawned_orig_scale: Vector3 = Vector3.ONE
var _dead := false

func _ready() -> void:
	var slug := MonsterCatalog.resolve_slug(monster_id)
	_spawned = MonsterCatalog.instantiate_visual(self, slug)
	if _spawned == null:
		_spawned = _make_fallback_box()
	_spawned_orig_scale = _spawned.scale
	if apply_scale:
		_spawned.scale = _spawned_orig_scale * scale_multiplier
	AnimAuto.play_idle(_spawned)
	# snap to floor
	global_transform.origin = _snap_to_floor(global_transform.origin)

func _input(event: InputEvent) -> void:
	if _dead: return
	if event.is_action_pressed(interact_action):
		if start_battle_on_interact:
			var slug := MonsterCatalog.resolve_slug(monster_id)
			EncounterRouter.request_encounter({ "enemy": slug, "monster_id": slug, "role": "boss" })
		else:
			_die_now()

func _die_now() -> void:
	_dead = true
	var slug := MonsterCatalog.resolve_slug(monster_id)
	var enc := get_node_or_null(^"/root/EncounterDirector")
	var payload := {
		"role": "boss",
		"monster_id": slug,
		"enemy": slug,
		"world_pos": global_transform.origin,
		"floor": (int(enc.get("_floor")) if enc != null and enc.has_method("get") else -1),
		"triad_id": (int(enc.get("_triad_id")) if enc != null and enc.has_method("get") else -1),
		"run_seed": (int(enc.get("_run_seed")) if enc != null and enc.has_method("get") else 0),
		"pool": (enc.get("_pool") if enc != null and enc.has_method("get") else [])
	}
	print("[Encounter][BossDefeated] payload=", JSON.stringify(payload, " "))
	# After your existing: print("[Encounter][BossDefeated] payload=", payload)
	var seed_for_loot: int = int(payload.get("run_seed", 0)) ^ 0xB055
	LootReward.encounter_victory("boss", int(payload.get("floor", 1)), String(payload.get("enemy","boss")), seed_for_loot, 0)

	_disable_collision_recursive(self)
	if _spawned:
		_spawned.scale = Vector3(_spawned_orig_scale.x, 0.05, _spawned_orig_scale.z)
	queue_free()

func _disable_collision_recursive(n: Node) -> void:
	for c in n.get_children():
		_disable_collision_recursive(c)
	var co := n as CollisionObject3D
	if co:
		co.collision_layer = 0
		co.collision_mask = 0

func _snap_to_floor(p: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 3, 0), p + Vector3(0, -6, 0))
	q.collision_mask = 1
	q.collide_with_bodies = true
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	if hit.has("position"):
		return Vector3(p.x, float(hit["position"].y) + 0.02, p.z)
	else:
		return p

func _make_fallback_box() -> Node3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.0, 1.8, 1.0)
	mi.mesh = bm
	return mi
