# res://persistence/services/village_wallet.gd
extends RefCounted
class_name VillageWallet

const _S := preload("res://persistence/util/save_utils.gd")

static func stash_get(slot: int = 1) -> Dictionary:
	var gs: Dictionary = SaveManager.load_game(slot)
	return {
		"gold": int(_S.dget(gs, "stash_gold", 0)),
		"shards": int(_S.dget(gs, "stash_shards", 0))
	}

static func can_afford(gold: int, shards: int, slot: int = 1) -> bool:
	var st := stash_get(slot)
	return (int(st["gold"]) >= max(0, gold)) and (int(st["shards"]) >= max(0, shards))

static func spend(gold: int, shards: int, reason: String = "village_upgrade", slot: int = 1) -> bool:
	var g: int = max(0, gold)
	var s: int = max(0, shards)
	var gs: Dictionary = SaveManager.load_game(slot)
	var cur_g: int = int(_S.dget(gs, "stash_gold", 0))
	var cur_s: int = int(_S.dget(gs, "stash_shards", 0))
	if cur_g < g or cur_s < s:
		return false
	gs["stash_gold"] = cur_g - g
	gs["stash_shards"] = cur_s - s
	gs["updated_at"] = _S.now_ts()
	SaveManager.save_game(gs, slot)
	# Telemetry hook (optional): print for now
	print("[VillageWallet] Spent g=", g, " s=", s, " reason=", reason)
	return true
