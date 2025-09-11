extends Node

# Run meta
var run_seed: int = 0
var depth: int = 1

# Player stats
var hp_max: int = 30
var hp: int = 30
var mp_max: int = 10
var mp: int = 10
var gold: int = 0
var items: Array[StringName] = []

var rng: RandomNumberGenerator = RandomNumberGenerator.new()

func new_run(seed_in: int = 0) -> void:
	if seed_in == 0:
		rng.randomize()
		run_seed = int(rng.seed)
	else:
		run_seed = seed_in
		rng.seed = seed_in
	depth = 1
	gold = 0
	hp = hp_max
	mp = mp_max
	items.clear()

func apply_rewards(rewards: Dictionary) -> void:
	gold += int(rewards.get("gold", 0))
	var heal: int = int(rewards.get("hp", 0))
	if heal > 0:
		hp = min(hp_max, hp + heal)

func as_text() -> String:
	return "Run(seed=%d, depth=%d, gold=%d, hp=%d/%d, mp=%d/%d)" % [run_seed, depth, gold, hp, hp_max, mp, mp_max]
