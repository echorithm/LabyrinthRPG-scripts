extends Node
class_name HexSeedService

enum SeedMode { AUTO_RANDOM, FIXED }

@export var seed_mode: SeedMode = SeedMode.AUTO_RANDOM
@export var fixed_seed: int = 123456789
@export var debug_logging: bool = true

var _seed: int = 0
var _initialized: bool = false

func _ready() -> void:
	_choose_seed()

func _choose_seed() -> void:
	if _initialized:
		return
	if seed_mode == SeedMode.FIXED:
		_seed = fixed_seed
	else:
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		_seed = int((int(Time.get_ticks_usec()) << 1) ^ int(rng.randi()))
	_initialized = true

func get_seed() -> int:
	if not _initialized:
		_choose_seed()
	return _seed

# Stable-ish hash for (q,r) using the seed.
func hash_qr(q: int, r: int) -> int:
	var h: int = get_seed()
	h ^= (q * 73856093)
	h ^= (r * 19349663)
	h ^= (q + r) * 83492791
	h ^= (h >> 16)
	return abs(h)

func roll_index(q: int, r: int, count: int) -> int:
	if count <= 0:
		return 0
	return hash_qr(q, r) % count
