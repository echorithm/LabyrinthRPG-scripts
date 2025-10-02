extends RefCounted
class_name ActorSyncService
## Bridges runtime nodes (Player/NPC) with META/RUN saves at safe boundaries.
## Keep it conservative: only sets/reads fields that obviously exist.

const _S     := preload("res://persistence/util/save_utils.gd")
const Stats  := preload("res://persistence/schemas/stats_schema.gd")
const Actor  := preload("res://persistence/schemas/actor_schema.gd")

const DEFAULT_SLOT: int = 1

# ---------------------------
# Runtime <-> RUN snapshot
# ---------------------------
static func push_runtime_hpmp_to_run(player: Node, slot: int = DEFAULT_SLOT) -> void:
	if player == null:
		return
	var rs: Dictionary = SaveManager.load_run(slot)
	var hp: int = _get_int(player, "hp", int(_S.dget(rs, "hp", 0)))
	var mp: int = _get_int(player, "mp", int(_S.dget(rs, "mp", 0)))
	var hp_max: int = _get_int(player, "hp_max", int(_S.dget(rs, "hp_max", 30)))
	var mp_max: int = _get_int(player, "mp_max", int(_S.dget(rs, "mp_max", 10)))
	rs["hp"] = clampi(hp, 0, hp_max)
	rs["mp"] = clampi(mp, 0, mp_max)
	rs["hp_max"] = hp_max
	rs["mp_max"] = mp_max
	SaveManager.save_run(rs, slot)

static func pull_run_hpmp_to_runtime(player: Node, slot: int = DEFAULT_SLOT) -> void:
	if player == null:
		return
	var rs: Dictionary = SaveManager.load_run(slot)
	_set_int(player, "hp_max", int(_S.dget(rs, "hp_max", 30)))
	_set_int(player, "mp_max", int(_S.dget(rs, "mp_max", 10)))
	_set_int(player, "hp", int(_S.dget(rs, "hp", 30)))
	_set_int(player, "mp", int(_S.dget(rs, "mp", 10)))

# ---------------------------
# Runtime <-> META snapshot
# ---------------------------
static func pull_meta_level_to_runtime(player: Node, slot: int = DEFAULT_SLOT) -> void:
	if player == null:
		return
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl_any: Variant = _S.dget(gs, "player", {})
	var pl: Dictionary = _S.to_dict(pl_any)
	var level: int = int(_S.dget(pl, "level", 1))
	_set_int(player, "level", level)

static func read_meta_actor_snapshot(kind_hint: String = "player", slot: int = DEFAULT_SLOT) -> Dictionary:
	## Produces an ActorSchema block from current META player.
	var gs: Dictionary = SaveManager.load_game(slot)
	var pl: Dictionary = _S.to_dict(_S.dget(gs, "player", {}))
	var out: Dictionary = Actor.default_block(kind_hint)
	out["id"] = "player"
	out["name"] = "Player"
	out["level"] = int(_S.dget(pl, "level", 1))
	out["stats"] = Stats.normalize(_S.dget(pl, "stats", {}))
	# Abilities placeholder: if you have a canonical list elsewhere, map it in here
	out["abilities"] = []
	# Loadout: if you later store this in META, normalize it here
	out["loadout"] = Actor._default_loadout()
	return Actor.normalize(out, kind_hint)

# ---------------------------
# Helpers (safe get/set)
# ---------------------------
static func _get_int(o: Object, prop: String, fallback: int) -> int:
	if o == null:
		return fallback
	if o.has_method("get"):
		var v: Variant = o.get(prop)
		if v == null:
			return fallback
		return int(v)
	return fallback

static func _set_int(o: Object, prop: String, value: int) -> void:
	if o == null:
		return
	if o.has_method("set"):
		o.set(prop, value)
