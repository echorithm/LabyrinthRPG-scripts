# Godot 4.4.1
extends Node
class_name BattleController

signal battle_finished(result: Dictionary)

const CTBModel := preload("res://scripts/combat/ctb/CTBModel.gd")

@export var auto_player: bool = false
@export var auto_monster: bool = false

@export var params: CTBParams

var _monster: MonsterRuntime
var _player: PlayerRuntime
var _entered: bool = false

var _ctb_player: CTBModel
var _ctb_monster: CTBModel
var _monster_offensive_cost: int = 100

func setup(monster: MonsterRuntime, player: PlayerRuntime, ctb_params: CTBParams) -> void:
	_monster = monster
	_player = player
	params = ctb_params

	_ctb_player = CTBModel.new(params.gauge_size, params.fill_scale, _player.ctb_speed)
	_ctb_monster = CTBModel.new(params.gauge_size, params.fill_scale, _monster.ctb_speed)

	_monster_offensive_cost = 100
	for a_any in _monster.abilities:
		var a := a_any as Dictionary
		if a != null and int(a.get("base_power", 0)) > 0:
			_monster_offensive_cost = int(a.get("ctb_cost", 100))
			break

	print("[BC] CTB gauge=%d fill=%.2f  speeds  P=%.1f  M=%.1f  mon_cost=%d"
		% [params.gauge_size, params.fill_scale, _player.ctb_speed, _monster.ctb_speed, _monster_offensive_cost])
	print("[BC] P hp=%d/%d p_atk=%.1f def=%.1f  |  M hp=%d/%d p_atk=%.1f def=%.1f"
		% [_player.hp, _player.hp_max, _player.p_atk, _player.defense,
		   _monster.hp, _monster.hp_max, _monster.p_atk, _monster.defense])

func _process(delta: float) -> void:
	if _monster == null or _player == null or params == null:
		return

	_ctb_player.tick(delta)
	_ctb_monster.tick(delta)

	# Only act if side is set to auto
	if auto_player and _ctb_player.ready and _monster.hp > 0 and _player.hp > 0:
		_perform_player_attack()
		_ctb_player.consume(100)

	if auto_monster and _ctb_monster.ready and _monster.hp > 0 and _player.hp > 0:
		_perform_monster_attack()
		_ctb_monster.consume(_monster_offensive_cost)

	if _monster.hp <= 0 or _player.hp <= 0:
		_emit_and_free()

func perform_player_basic_attack() -> void:
	# Call this from UI/gestures when player acts
	if _ctb_player.ready and _monster.hp > 0 and _player.hp > 0:
		_perform_player_attack()
		_ctb_player.consume(100)

func _emit_and_free() -> void:
	var outcome: String = "victory" if _monster.hp <= 0 and _player.hp > 0 else "defeat"
	var result: Dictionary = {
		"outcome": outcome,
		"player_hp": _player.hp,
		"player_mp": _player.mp,
		"monster_slug": _monster.slug,
	}
	emit_signal("battle_finished", result)
	queue_free()

func _perform_player_attack() -> void:
	var raw: float = max(1.0, _player.p_atk - _monster.defense * 0.5)
	var dmg: int = int(round(raw))
	_monster.hp = max(0, _monster.hp - dmg)

func _perform_monster_attack() -> void:
	var raw: float = max(1.0, _monster.p_atk - _player.defense * 0.5)
	var dmg: int = int(round(raw))
	_player.hp = max(0, _player.hp - dmg)

func begin(_payload: Dictionary) -> void:
	_enter_if_ready()

func _enter_if_ready() -> void:
	if _entered or _monster == null or _player == null:
		return
	_entered = true
