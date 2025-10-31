# FILE: scripts/combat/util/RNGService.gd
extends RefCounted
class_name RNGService

# Deterministic RNG with channelized, bagged Bernoulli streams.
# Channels: acc, crit, status, variance, ai_choice, loot

class Bag:
	var seq: PackedByteArray
	var idx: int = 0
	var size: int = 0

	func _init(_seq: PackedByteArray) -> void:
		seq = _seq
		size = _seq.size()
		idx = 0

	func next_bool() -> bool:
		if size == 0:
			return false
		var v: bool = (seq[idx] == 1)
		idx = (idx + 1) % size
		return v

var _seed: int = 0
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

# Bag channels and their nominal probabilities (for logging).
var _bags: Dictionary[StringName, Bag] = {}
var _bag_probs: Dictionary[StringName, float] = {}

# RNGs for non-bag draws (variance, ai_choice weights, etc.)
var _var_rngs: Dictionary[StringName, RandomNumberGenerator] = {}

static func _make_bag(prob: float, size: int = 100) -> Bag:
	var p: float = clampf(prob, 0.0, 1.0)
	var trues: int = int(round(p * float(size)))

	# Build [1..1,0..0]
	var seq := PackedByteArray()
	seq.resize(size)
	for i in range(size):
		seq[i] = 1 if i < trues else 0

	# Deterministic shuffle based on count & size
	var local := RandomNumberGenerator.new()
	local.seed = int(trues * 1315423911) ^ size
	for i in range(size):
		var j: int = local.randi_range(0, size - 1)
		var tmp: int = seq[i]
		seq[i] = seq[j]
		seq[j] = tmp

	return Bag.new(seq)

func seed_from(battle_seed: int, encounter_id: int) -> void:
	_seed = int(battle_seed * 73856093) ^ int(encounter_id * 19349663)
	_rng.seed = _seed
	_bags.clear()
	_bag_probs.clear()
	_var_rngs.clear()

	# Default bag probabilities (callers should override per-use)
	_set_bag_defaults()

	# Dedicated RNG per channel (variance & selections)
	var channels: Array[StringName] = [StringName("acc"), StringName("crit"), StringName("status"),
		StringName("variance"), StringName("ai_choice"), StringName("loot")]
	for c in channels:
		var r := RandomNumberGenerator.new()
		r.seed = _seed ^ int(hash(c))
		_var_rngs[c] = r

func reseed(extra: int) -> void:
	_rng.seed = int(_seed ^ extra)
	for k in _var_rngs.keys():
		var rr: RandomNumberGenerator = _var_rngs[k]
		rr.seed = int(rr.seed ^ extra)

# --- Bag configuration -------------------------------------------------------

func set_bag_prob(channel: StringName, prob: float, size: int = 100) -> void:
	_bag_probs[channel] = clampf(prob, 0.0, 1.0)
	_bags[channel] = _make_bag(_bag_probs[channel], size)

func get_bag_prob(channel: StringName) -> float:
	return _bag_probs.get(channel, 0.0)

func bag_debug_snapshot() -> Dictionary:
	var snap: Dictionary = {}
	for ch in _bags.keys():
		var bag: Bag = _bags[ch]
		var ones: int = 0
		for v in bag.seq:
			if int(v) == 1:
				ones += 1
		snap[String(ch)] = {
			"size": bag.size,
			"success_tokens": ones,
			"idx": bag.idx,
			"p_nominal": _bag_probs.get(ch, -1.0)
		}
	return snap

func _set_bag_defaults() -> void:
	set_bag_prob(StringName("acc"), 0.80)
	set_bag_prob(StringName("crit"), 0.10)
	set_bag_prob(StringName("status"), 0.25)
	set_bag_prob(StringName("ai_choice"), 0.50)
	set_bag_prob(StringName("loot"), 0.50)
	# "variance" is not a Bernoulli bag by default; we use RNG factor for it.
	_bag_probs[StringName("variance")] = 0.0

# --- Channel rolls (bagged) --------------------------------------------------

func roll_acc() -> bool:
	var outcome: bool = false
	var p: float = get_bag_prob(StringName("acc"))
	var bag: Bag = _bags.get(StringName("acc"), null)
	if bag != null:
		outcome = bag.next_bool()
	# We don't have a scalar "roll" for bagged; log -1.0 to indicate token draw.
	CombatTrace.rng(&"acc", p, outcome, -1.0)
	return outcome

func roll_crit() -> bool:
	var outcome: bool = false
	var p: float = get_bag_prob(StringName("crit"))
	var bag: Bag = _bags.get(StringName("crit"), null)
	if bag != null:
		outcome = bag.next_bool()
	CombatTrace.rng(&"crit", p, outcome, -1.0)
	return outcome

func roll_status() -> bool:
	var outcome: bool = false
	var p: float = get_bag_prob(StringName("status"))
	var bag: Bag = _bags.get(StringName("status"), null)
	if bag != null:
		outcome = bag.next_bool()
	CombatTrace.rng(&"status", p, outcome, -1.0)
	return outcome

# Variance is multiplicative jitter around 1.0. You can still log a "hit" for visibility.
func roll_variance_flag() -> bool:
	var p: float = get_bag_prob(StringName("variance"))
	var outcome: bool = true
	CombatTrace.rng(&"variance", p, outcome, -1.0)
	return outcome

# --- Variance / weights / selections ----------------------------------------

func jitter_variance(amount: float, pct_range: float = 0.05) -> float:
	var r: RandomNumberGenerator = _var_rngs[StringName("variance")]
	var factor: float = 1.0 + r.randf_range(-pct_range, pct_range)
	return amount * factor

func pick_ai(weights: PackedFloat32Array) -> int:
	var r: RandomNumberGenerator = _var_rngs[StringName("ai_choice")]
	var total: float = 0.0
	for w in weights:
		total += w
	if total <= 0.0:
		return 0
	var roll: float = r.randf_range(0.0, total)
	var acc: float = 0.0
	for i in range(weights.size()):
		acc += weights[i]
		if roll <= acc:
			return i
	return weights.size() - 1

func roll_loot(prob: float) -> bool:
	set_bag_prob(StringName("loot"), prob)
	var bag: Bag = _bags[StringName("loot")]
	return bag.next_bool()

# ---- small helpers ----
func randf() -> float:
	return _rng.randf()

func randi() -> int:
	return _rng.randi()

func randi_range(a: int, b: int) -> int:
	return _rng.randi_range(a, b)

func choice(arr: Array) -> Variant:
	if arr.is_empty():
		return null
	return arr[randi_range(0, arr.size() - 1)]
