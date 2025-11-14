# Godot 4.5
extends Node
## Fires a full encounter via EncounterRouter with deterministic options.
## Uses SetPowerLevel.roll_power_level(floor) unless you override PL.

const MonsterCatalog  := preload("res://scripts/autoload/MonsterCatalog.gd")
const SetPowerLevel   := preload("res://scripts/dungeon/encounters/SetPowerLevel.gd")

@export var run_seed: int = 12345678
@export var role: String = "trash"                 # "trash" | "elite" | "boss"
@export var randomize_floor: bool = true
@export var floor_min: int = 1
@export var floor_max: int = 30
@export var floor_override: int = 1                # used if randomize_floor = false

@export var force_slug: StringName = &""           # leave empty to pick from pool
@export var power_level_override: int = 0          # > 0 forces PL; else SetPowerLevel

# Optional: reuse an existing in-world visual (Elite/Boss spawners)
@export var use_existing_visual: bool = false
@export var existing_visual_path: NodePath = NodePath()  # path to a Node3D in the scene

# Optional: CTB start bonuses (in %)
@export var ctb_player_bonus_pct: int = 0
@export var ctb_monster_bonus_pct: int = 0

func _ready() -> void:
	var mc: MonsterCatalog = get_node_or_null(^"/root/MonsterCatalog") as MonsterCatalog
	if mc == null:
		mc = MonsterCatalog.new()
		get_tree().get_root().add_child(mc)

	# Seeded RNG for determinism
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _seed_from(["ROUTERKICK", str(run_seed), role])

	# Floor
	var floor_i: int = floor_override
	if randomize_floor:
		var lo: int = max(1, floor_min)
		var hi: int = max(lo, floor_max)
		floor_i = rng.randi_range(lo, hi)

	# Resolve candidate pool
	var pool_key: String = "regular"
	if role == "boss":
		pool_key = "boss"
	var pool: PackedStringArray = mc.slugs_for_role(pool_key, role != "trash")
	if pool.is_empty():
		push_error("[RouterKick] Monster pool empty for role=%s" % role)
		return

	# Choose slug
	var slug: StringName
	if String(force_slug) != "":
		slug = mc.resolve_slug(force_slug)
	else:
		slug = StringName(pool[rng.randi_range(0, pool.size() - 1)])

	# Power level
	var pl: int = power_level_override
	if pl <= 0:
		pl = SetPowerLevel.roll_power_level(floor_i)

	# Build payload for EncounterRouter
	var payload: Dictionary = {
		"encounter_id": 0, # router will assign
		"floor": floor_i,
		"triad_id": 1,     # harmless; EncounterDirector usually sets this
		"cell": Vector2i(-1, -1),
		"world_pos": Vector3.ZERO,
		"em_value": 0,
		"threshold": 0,
		"pool": [],        # informational only
		"enemy": slug,
		"monster_id": slug,
		"role": role,
		"run_seed": run_seed,
		"power_level": pl,
		"ctb_player_bonus_pct": ctb_player_bonus_pct,
		"ctb_monster_bonus_pct": ctb_monster_bonus_pct,
	}

	if use_existing_visual and existing_visual_path != NodePath():
		payload["existing_visual_path"] = String(existing_visual_path)

	# Fire encounter
	print("[RouterKick] request_encounter floor=%d role=%s slug=%s pl=%d seed=%d"
		% [floor_i, role, String(slug), pl, run_seed])

	if has_node(^"/root/EncounterRouter"):
		var router: Node = get_node(^"/root/EncounterRouter")
		router.call("request_encounter", payload, null)
	else:
		push_error("[RouterKick] /root/EncounterRouter missing")

# -------------------- helpers --------------------

func _seed_from(parts: Array[String]) -> int:
	if Engine.has_singleton("DetHash"):
		var DH = Engine.get_singleton("DetHash")
		return int(DH.call("djb2_64", [String(",".join(parts))]))
	return int(hash(",".join(parts)) & 0x7fffffff)
