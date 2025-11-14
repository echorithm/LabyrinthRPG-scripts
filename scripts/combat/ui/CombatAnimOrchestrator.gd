extends Node
class_name CombatAnimOrchestrator

@export var battle_controller_path: NodePath
@export var battlers_root_path: NodePath   # parent that holds all battler instances

var _ctl: Node
var _battlers_root: Node
var _bridge_by_actor: Dictionary[int, AnimationBridge] = {}

# Optional: small FX hooks for player feedback
@export var screen_fx_path: NodePath
@export var camera_path: NodePath

var _screen_fx: Node
var _camera: Camera3D
var _last_ability_by_actor: Dictionary = {}

func _ready() -> void:
	_ctl = get_node_or_null(battle_controller_path)
	_battlers_root = get_node_or_null(battlers_root_path)
	_screen_fx = get_node_or_null(screen_fx_path)
	_camera = get_node_or_null(camera_path) as Camera3D

	_map_bridges()

	# Connect to your controller’s signals (rename if yours differ)
	# Expected payloads:
	# ability_started(actor_id:int, ability_id:String, animation_key:String)
	# ability_impact(attacker_id:int, targets:Array[int], hit_mask:Array[bool], crit_mask:Array[bool])
	# actor_died(actor_id:int)
	if _ctl:
		_ctl.ability_started.connect(_on_ability_started)
		_ctl.ability_impact.connect(_on_ability_impact)
		_ctl.actor_died.connect(_on_actor_died)

func _map_bridges() -> void:
	_bridge_by_actor.clear()
	if _battlers_root == null:
		return
	for child in _battlers_root.get_children():
		# Expect each battler to expose actor_id:int and have/host an AnimationBridge
		if not child.has_method("get_actor_id"):
			continue
		var actor_id: int = child.get_actor_id()
		var bridge := child.get_node_or_null(^"AnimationBridge") as AnimationBridge
		if bridge == null:
			bridge = AnimationBridge.new()
			child.add_child(bridge)
			bridge.owner = child.get_owner()
			bridge.setup(child)
		_bridge_by_actor[actor_id] = bridge

func _on_ability_started(actor_id: int, _ability_id: String, animation_key: String) -> void:
	var bridge := _bridge_by_actor.get(actor_id, null) as AnimationBridge
	if bridge:
		bridge.play_action(animation_key)

	# Track the last ability for this actor so we can reference it at impact time.
	_last_ability_by_actor[actor_id] = _ability_id

	# Play start SFX
	var sfx := get_node_or_null(^"/root/CombatAudioService") as CombatAudioService
	if sfx != null:
		sfx.play_for_ability(_ability_id, false)

func _on_ability_impact(_attacker_id: int, targets: Array[int], hit_mask: Array[bool], _crit_mask: Array[bool]) -> void:
	for i: int in range(targets.size()):
		if i < hit_mask.size() and hit_mask[i]:
			var tgt_id: int = targets[i]
			var bridge := _bridge_by_actor.get(tgt_id, null) as AnimationBridge
			if bridge:
				bridge.play_hit()
			_maybe_player_feedback(tgt_id)  # existing behavior
			break

	# Impact SFX: reuse the last ability fired by this attacker (simple + robust)
	var ability_any: Variant = _last_ability_by_actor.get(_attacker_id, "")
	var ability_id: String = String(ability_any)
	if ability_id != "":
		var sfx := get_node_or_null(^"/root/CombatAudioService") as CombatAudioService
		if sfx != null:
			sfx.play_for_ability(ability_id, false)

func _on_actor_died(actor_id: int) -> void:
	var bridge := _bridge_by_actor.get(actor_id, null) as AnimationBridge
	if bridge:
		bridge.play_die_and_hold()

func _maybe_player_feedback(target_id: int) -> void:
	# If the target is a player, do light feedback. Replace predicate as needed.
	var is_player := _is_player_actor(target_id)
	if not is_player:
		return
	if _screen_fx and _screen_fx.has_method("flash_red"):
		_screen_fx.flash_red(0.08, 0.15)
	if _camera and _camera.has_method("shake"):
		_camera.shake(0.25, 0.2)

func _is_player_actor(actor_id: int) -> bool:
	# TODO: wire to your runtime/party registry. Default: assume <1000 are players.
	return actor_id >= 0 and actor_id < 1000
