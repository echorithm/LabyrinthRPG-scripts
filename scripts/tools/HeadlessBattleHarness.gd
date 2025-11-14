# Godot 4.5
extends Node
## Headless battle harness: fixed floor + slug, but per-trial power level rolls.

const MonsterCatalog  := preload("res://scripts/autoload/MonsterCatalog.gd")
const PowerAllocator  := preload("res://scripts/combat/allocation/PowerAllocator.gd")
const MonsterRuntime  := preload("res://scripts/combat/snapshot/MonsterRuntime.gd")
const PlayerRuntime   := preload("res://scripts/combat/snapshot/PlayerRuntime.gd")
const SetPowerLevel   := preload("res://scripts/dungeon/encounters/SetPowerLevel.gd")

@export var role: String = "trash"               # "trash" | "elite" | "boss"
@export var run_seed: int = 12345678
@export var quit_after: bool = true

# Fixed floor
@export var floor_fixed: int = 4

# Slug selection
@export var force_slug: StringName = &""

# Trials (each trial rolls a new PL and allocates)
@export var trials: int = 10
@export var seed_step: int = 101                 # added per-trial for determinism

func _ready() -> void:
	var mc: MonsterCatalog = get_node_or_null(^"/root/MonsterCatalog") as MonsterCatalog
	if mc == null:
		mc = MonsterCatalog.new()
		get_tree().get_root().add_child(mc)

	# Resolve pool + slug ONCE (fixed across trials)
	var pool_key: String = "regular"
	if role == "boss":
		pool_key = "boss"
	var pool: PackedStringArray = mc.slugs_for_role(pool_key, role != "trash")
	if pool.is_empty():
		push_error("[Harness] Monster pool is empty for role=%s" % role)
		_finish()
		return

	var rng_pick := RandomNumberGenerator.new()
	rng_pick.seed = _seed_from(["HARNESS_PICK", str(run_seed), role])

	var slug: StringName
	if String(force_slug) != "":
		slug = mc.resolve_slug(force_slug)
	else:
		slug = StringName(pool[rng_pick.randi_range(0, pool.size() - 1)])

	var floor_i: int = max(1, floor_fixed)
	var snap: Dictionary = mc.snapshot(slug)
	if snap.is_empty():
		push_error("[Harness] Snapshot empty for slug=%s" % String(slug))
		_finish()
		return

	print_rich("[color=#8888ff][HARNESS][/color] floor=", floor_i,
		" role=", role, " slug=", String(slug), " trials=", trials)

	# Aggregates
	var aggregate_added: Dictionary = {}     # ability_id -> total added across trials
	var pl_hist: Dictionary = {}             # PL -> count

	for t in range(max(1, trials)):
		# Per-trial RNG for PL roll (deterministic by trial)
		var rng_pl := RandomNumberGenerator.new()
		rng_pl.seed = _seed_from(["PL", str(run_seed + t * seed_step), String(slug), str(floor_i)])

		# roll_power_level(floor, a, b, volatility, rng)
		var pl: int = SetPowerLevel.roll_power_level(
			floor_i,
			SetPowerLevel.DEFAULT_A,
			SetPowerLevel.DEFAULT_B,
			SetPowerLevel.DEFAULT_VOLATILITY,
			rng_pl
		)

		# Optional: apply role multiplier if you want elites/bosses even spicier
		# pl = SetPowerLevel.apply_role_mult(pl, role)

		pl_hist[pl] = int(pl_hist.get(pl, 0)) + 1

		# Separate RNG for allocation so PL RNG doesn’t “bleed” into distribution
		var rng_alloc := RandomNumberGenerator.new()
		rng_alloc.seed = _seed_from(["ALLOC", str(run_seed + t * seed_step), String(slug), str(floor_i), str(pl)])

		var alloc: Dictionary = PowerAllocator.allocate(snap, pl, rng_alloc)
		if alloc.is_empty():
			push_error("[Harness] Allocation failed for trial %d" % t)
			continue

		var abilities_arr: Array = alloc.get("abilities", []) as Array
		var levels_map: Dictionary = alloc.get("ability_levels", {}) as Dictionary

		var expected_added: int = _expected_ability_levels_from_pl(pl)
		var dist: Dictionary = {}  # id -> added
		var sum_added: int = 0

		for a_any in abilities_arr:
			if not (a_any is Dictionary):
				continue
			var a: Dictionary = a_any as Dictionary
			var aid: String = String(a.get("id", String(a.get("ability_id",""))))
			if aid == "":
				continue
			var baseline: int = max(1, int(a.get("skill_level_baseline", 1)))
			var final_level: int = int(levels_map.get(aid, baseline))
			var added: int = max(0, final_level - baseline)
			if added > 0:
				dist[aid] = int(dist.get(aid, 0)) + added
				sum_added += added
				aggregate_added[aid] = int(aggregate_added.get(aid, 0)) + added

		var ok: bool = (sum_added == expected_added)
		print("[DIST t=%d] floor=%d pl=%d expected=%d added=%d ok=%s { %s }" % [
			t, floor_i, pl, expected_added, sum_added, str(ok), _fmt_kv_plus(dist)
		])

		# Print one full runtime snapshot (first trial) for ballpark sanity
		if t == 0:
			var mr: MonsterRuntime = MonsterRuntime.from_alloc(snap, alloc, role)
			var pr: PlayerRuntime = PlayerRuntime.from_stats(_default_player_attrs(), _default_player_attrs(), _default_player_caps())
			_print_monster(mr)
			_print_player(pr)

	# Summaries
	if not aggregate_added.is_empty():
		print("[DIST aggregate across %d trials] { %s }" % [trials, _fmt_kv_plus(aggregate_added)])
	if not pl_hist.is_empty():
		print("[PL histogram] { %s }" % [_fmt_kv_counts(pl_hist)])

	_finish()

# ---------------- helpers ----------------

func _finish() -> void:
	if quit_after:
		await get_tree().process_frame
		get_tree().quit()

func _expected_ability_levels_from_pl(pl: int) -> int:
	var levels_from_pl: int = int(floor(float(max(1, pl)) * 0.20))
	return max(0, pl - levels_from_pl)

func _default_player_attrs() -> Dictionary:
	var rs: Dictionary = SaveManager.load_run()
	var pa_any: Variant = rs.get("player_attributes")
	var out: Dictionary = {
		"STR": 8, "AGI": 8, "DEX": 8, "END": 8,
		"INT": 8, "WIS": 8, "CHA": 8, "LCK": 8
	}
	if pa_any is Dictionary:
		var pa: Dictionary = pa_any as Dictionary
		for k in out.keys():
			var v: Variant = pa.get(k)
			if v is int:
				out[k] = int(v)
			elif v is float:
				out[k] = int(round(float(v)))
	return out

func _default_player_caps() -> Dictionary:
	return { "crit_chance_cap": 0.35, "crit_multi_cap": 2.5 }

func _seed_from(parts: Array[String]) -> int:
	if Engine.has_singleton("DetHash"):
		var DH = Engine.get_singleton("DetHash")
		return int(DH.call("djb2_64", [String(",".join(parts))]))
	return int(hash(",".join(parts)) & 0x7fffffff)

func _fmt_kv_plus(m: Dictionary) -> String:
	if m.is_empty():
		return ""
	var parts: Array[String] = []
	for k_any in m.keys():
		var k: String = str(k_any)          # <-- use str()
		var v: int = int(m[k_any])          # <-- read by original key
		parts.append("%s:+%d" % [k, v])
	parts.sort()
	return ",".join(parts)


func _fmt_kv_counts(m: Dictionary) -> String:
	if m.is_empty():
		return ""
	var parts: Array[String] = []
	for k_any in m.keys():
		var k: String = str(k_any)          # <-- use str()
		var v: int = int(m[k_any])          # <-- read by original key
		parts.append("%s:%d" % [k, v])
	parts.sort()
	return ",".join(parts)


func _print_monster(mr: MonsterRuntime) -> void:
	print_rich("[color=cyan][HARNESS:Monster][/color] ",
		mr.display_name, " (", String(mr.slug), ") role=", mr.role,
		" | L=", mr.final_level, " base=", mr.base_stats, " final=", mr.final_stats,
		" | HP:", mr.hp_max, " MP:", mr.mp_max, " ST:", mr.stam_max,
		" | PATK:", String.num(mr.p_atk, 1), " MATK:", String.num(mr.m_atk, 1),
		" | DEF:", String.num(mr.defense, 1), " RES:", String.num(mr.resistance, 1),
		" | Crit:", String.num(mr.crit_chance * 100.0, 1), "% ×", String.num(mr.crit_multi, 2),
		" | CTB:", String.num(mr.ctb_speed, 2)
	)

func _print_player(pr: PlayerRuntime) -> void:
	print_rich("[color=lightgreen][HARNESS:Player][/color] ",
		"base=", pr.base_stats, " final=", pr.final_stats,
		" | HP:", pr.hp, "/", pr.hp_max, " MP:", pr.mp, "/", pr.mp_max,
		" ST:", pr.stam, "/", pr.stam_max,
		" | PATK:", String.num(pr.p_atk, 1), " MATK:", String.num(pr.m_atk, 1),
		" | DEF:", String.num(pr.defense, 1), " RES:", String.num(pr.resistance, 1),
		" | Crit:", String.num(pr.crit_chance * 100.0, 1), "% ×", String.num(pr.crit_multi, 2),
		" | CTB:", String.num(pr.ctb_speed, 2)
	)
