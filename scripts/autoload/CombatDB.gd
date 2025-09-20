# File: res://scripts/autoload/CombatDB.gd
# Autoload registry: scans data folders, builds id -> resource maps.

extends Node

var actions: Dictionary[StringName, Resource] = {}
var intents: Dictionary[StringName, Resource] = {}
var enemies: Dictionary[StringName, Resource] = {}

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

func _ready() -> void:
	_rng.randomize()
	_load_folder("res://data/combat/actions", actions)
	_load_folder("res://data/combat/intents", intents)
	_load_folder("res://data/combat/enemies", enemies)
	print("[CombatDB] Loaded: %d actions, %d intents, %d enemies" % [actions.size(), intents.size(), enemies.size()])

func get_action(id: StringName) -> ActionDef:
	var r: Resource = actions.get(id)
	return r as ActionDef

func get_intent(id: StringName) -> IntentDef:
	var r: Resource = intents.get(id)
	return r as IntentDef

func get_enemy(id: StringName) -> EnemyDef:
	var r: Resource = enemies.get(id)
	return r as EnemyDef

func pick_weighted_ids(ids: Array[StringName], weights: PackedInt32Array) -> StringName:
	if ids.is_empty() or weights.is_empty() or ids.size() != int(weights.size()):
		return StringName("")
	var total: int = 0
	for w in weights: total += max(0, w)
	if total <= 0:
		return ids[0]
	var roll: int = _rng.randi_range(0, total - 1)
	var acc: int = 0
	for i in range(ids.size()):
		acc += max(0, weights[i])
		if roll < acc:
			return ids[i]
	return ids[ids.size() - 1]

func _load_folder(path: String, out_map: Dictionary[StringName, Resource]) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	while true:
		var f := d.get_next()
		if f == "":
			break
		if d.current_is_dir():
			continue
		if not (f.ends_with(".tres") or f.ends_with(".res")):
			continue
		var res: Resource = load(path.path_join(f))
		if res == null:
			continue
		if res is ActionDef:
			var a := res as ActionDef
			out_map[a.id] = a
		elif res is IntentDef:
			var it := res as IntentDef
			out_map[it.id] = it
		elif res is EnemyDef:
			var e := res as EnemyDef
			out_map[e.id] = e
	d.list_dir_end()
