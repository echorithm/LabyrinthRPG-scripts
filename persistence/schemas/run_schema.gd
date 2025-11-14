# res://persistence/schemas/run_schema.gd
extends RefCounted
class_name RunSchema

const _S := preload("res://persistence/util/save_utils.gd")
const LATEST_VERSION: int = 6  # weapon family slots (sword/spear/mace/bow)

static func defaults(_meta_schema_version: int) -> Dictionary:
	var now_ts: int = _S.now_ts()
	return {
		"schema_version": LATEST_VERSION,
		"created_at": float(now_ts),
		"updated_at": now_ts,

		"run_seed": 0,
		"depth": 1,
		"furthest_depth_reached": 1,

		# Pools
		"hp_max": 0, "hp": 0,
		"mp_max": 0, "mp": 0,
		"stam_max": 0, "stam": 0,

		# On-hand currencies (NOT stash)
		"gold": 0,
		"shards": 0,

		# Inventory & equip
		"inventory": [],
		"equipment": {
			"head": null, "chest": null, "legs": null, "boots": null,
			"sword": null, "spear": null, "mace": null, "bow": null,
			"ring1": null, "ring2": null, "amulet": null
		},
		"equipped_bank": {},      # full item dicts keyed by uid
		"weapon_tags": [],        # derived by BuffService

		# Runtime-only
		"buffs": [],
		"effects": [],

		# Progress mirrors
		"player_stat_block": { "level": 1, "xp_current": 0, "xp_needed": 90 },
		"skill_tracks": {},

		# Per-session
		"skill_xp_delta": {},
		"ability_use_counts": {},
		"ability_xp_pending": {},
		"action_skills": {},
	}

static func migrate(d_in: Dictionary, _meta_schema_version: int) -> Dictionary:
	var d: Dictionary = _S.to_dict(d_in)
	if d.is_empty():
		return defaults(_meta_schema_version)

	d["schema_version"] = LATEST_VERSION
	d["depth"] = int(d.get("depth", 1))
	d["furthest_depth_reached"] = int(d.get("furthest_depth_reached", int(d["depth"])))
	d["run_seed"] = int(d.get("run_seed", 0))

	# pools
	d["hp_max"] = int(d.get("hp_max", 0))
	d["hp"]     = int(d.get("hp", d["hp_max"]))
	d["mp_max"] = int(d.get("mp_max", 0))
	d["mp"]     = int(d.get("mp", d["mp_max"]))
	d["stam_max"] = int(d.get("stam_max", 0))
	d["stam"]     = int(d.get("stam", d["stam_max"]))

	# on-hand currencies
	d["gold"] = int(d.get("gold", 0))
	d["shards"] = int(d.get("shards", 0))

	# equipment & tags (canonical family slots)
	var eq_in: Dictionary = _S.to_dict(d.get("equipment", {}))
	var eq_norm: Dictionary = {
		"head": null, "chest": null, "legs": null, "boots": null,
		"sword": null, "spear": null, "mace": null, "bow": null,
		"ring1": null, "ring2": null, "amulet": null
	}
	for k_any in eq_norm.keys():
		var k: String = String(k_any)
		eq_norm[k] = eq_in.get(k, null)
	d["equipment"] = eq_norm
	d["weapon_tags"] = _S.to_string_array(d.get("weapon_tags", []))

	# bank
	var bank: Dictionary = _S.to_dict(d.get("equipped_bank", {}))
	d["equipped_bank"] = bank

	# progress mirrors
	var sb: Dictionary = _S.to_dict(d.get("player_stat_block", {}))
	var lvl: int = int(sb.get("level", 1))
	sb["level"] = max(1, lvl)
	sb["xp_current"] = int(sb.get("xp_current", 0))
	sb["xp_needed"] = int(sb.get("xp_needed", 90))
	d["player_stat_block"] = sb

	var tracks: Dictionary = _S.to_dict(d.get("skill_tracks", {}))
	for kk in tracks.keys():
		if tracks[kk] is Dictionary:
			var row: Dictionary = tracks[kk]
			row["level"] = int(row.get("level", 1))
			row["xp_current"] = int(row.get("xp_current", 0))
			row["xp_needed"] = int(row.get("xp_needed", 90))
			row["cap_band"] = int(row.get("cap_band", 10))
			row["unlocked"] = bool(row.get("unlocked", false))
			row["last_milestone_applied"] = int(row.get("last_milestone_applied", 0))
			tracks[kk] = row
	d["skill_tracks"] = tracks

	# session tables
	var deltas: Dictionary = _S.to_dict(d.get("skill_xp_delta", {}))
	for k in deltas.keys():
		deltas[k] = int(deltas[k])
	d["skill_xp_delta"] = deltas

	var counts: Dictionary = _S.to_dict(d.get("ability_use_counts", {}))
	for k2 in counts.keys():
		counts[k2] = int(counts[k2])
	d["ability_use_counts"] = counts

	d["ability_xp_pending"] = _S.to_dict(d.get("ability_xp_pending", {}))
	d["action_skills"] = _S.to_dict(d.get("action_skills", {}))

	if not d.has("created_at"):
		d["created_at"] = float(_S.now_ts())
	d["updated_at"] = _S.now_ts()
	return d
