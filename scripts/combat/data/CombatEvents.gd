# FILE: scripts/combat/data/CombatEvents.gd
extends RefCounted
class_name CombatEvents

# All payloads are UI-safe, immutable dictionaries.
# NOTE: For compatibility, many events include both the new canonical keys
#   - src / dst / id / turns
# and legacy keys used elsewhere
#   - attacker_id / target_id / status_id / duration
# Consumers may read either; new code should prefer the canonical keys.

static func turn_began(round_i: int, actor_id: int, who: String) -> Dictionary:
	return {
		"type": "turn_began",
		"round_i": round_i,
		"actor_id": actor_id,
		"src": actor_id,      # canonical mirror
		"who": who,
	}

static func ability_used(actor_id: int, ability_id: String, target_ids: Array[int], time_ctb_cost: int) -> Dictionary:
	return {
		"type": "ability_used",
		"actor_id": actor_id,
		"src": actor_id,      # canonical mirror
		"ability_id": ability_id,
		"targets": target_ids.duplicate(),
		"time_ctb_cost": time_ctb_cost,
	}

static func costs_paid(actor_id: int, mp: int, stam: int, charges: int, cooldown: int) -> Dictionary:
	return {
		"type": "costs_paid",
		"actor_id": actor_id,
		"src": actor_id,      # canonical mirror
		"mp": mp,
		"stam": stam,
		"charges": charges,
		"cooldown": cooldown,
	}

static func miss(attacker_id: int, target_id: int, reason: String) -> Dictionary:
	return {
		"type": "miss",
		"attacker_id": attacker_id, # legacy
		"target_id": target_id,     # legacy
		"src": attacker_id,         # canonical
		"dst": target_id,           # canonical
		"reason": reason,           # "evasion" | "immune" | "dodge" | "blind" | etc.
	}

static func crit(attacker_id: int, target_id: int, amount_pct: float) -> Dictionary:
	return {
		"type": "crit",
		"attacker_id": attacker_id, # legacy
		"target_id": target_id,     # legacy
		"src": attacker_id,         # canonical
		"dst": target_id,           # canonical
		"amount_pct": amount_pct,   # e.g. 1.5 for +50%
	}

static func shield_absorb(target_id: int, lane: String, absorbed: int, shield_id: String) -> Dictionary:
	return {
		"type": "shield_absorb",
		"target_id": target_id,   # legacy
		"dst": target_id,         # canonical
		"lane": lane,
		"absorbed": absorbed,
		"shield_id": shield_id,
	}

static func block(target_id: int, lane: String, reduced: int, source: String) -> Dictionary:
	return {
		"type": "block",
		"target_id": target_id,   # legacy
		"dst": target_id,         # canonical
		"lane": lane,
		"reduced": reduced,
		"source": source,         # "shield_block" | "weapon_block" | etc.
	}

static func damage_applied(attacker_id: int, target_id: int, lanes_after: Dictionary, total: int) -> Dictionary:
	return {
		"type": "damage_applied",
		"attacker_id": attacker_id, # legacy
		"target_id": target_id,     # legacy
		"src": attacker_id,         # canonical
		"dst": target_id,           # canonical
		"lanes": lanes_after.duplicate(), # expect up to 10 lanes
		"total": total,
	}

# Kernel sometimes emits a raw {"type":"heal", ...}. Keep alias for consistency.
static func heal(source_id: int, target_id: int, amount: int) -> Dictionary:
	return heal_applied(source_id, target_id, amount)

static func heal_applied(source_id: int, target_id: int, amount: int) -> Dictionary:
	return {
		"type": "heal_applied",
		"source_id": source_id,  # legacy
		"target_id": target_id,  # legacy
		"src": source_id,        # canonical
		"dst": target_id,        # canonical
		"amount": amount,
	}

# Canonical status helpers (used when calling from code)
# BuffDebuffPipeline already emits {type:"status_applied", src, dst, id, kind, turns, ...}
# These helpers mirror that shape and include legacy fields for compatibility.
static func status_applied(source_id: int, target_id: int, status_id: String, duration: int, kind: String = "", extra: Dictionary = {}) -> Dictionary:
	var ev := {
		"type": "status_applied",
		# canonical
		"src": source_id,
		"dst": target_id,
		"id": status_id,
		"turns": duration,
		"kind": kind,
	}
	# optional rider fields (pct, stacks, per_stack_tick, etc.)
	for k in extra.keys():
		ev[k] = extra[k]

	# legacy mirrors
	ev["source_id"] = source_id
	ev["target_id"] = target_id
	ev["status_id"] = status_id
	ev["duration"] = duration

	return ev

static func status_resisted(source_id: int, target_id: int, status_id: String, reason: String = "resist") -> Dictionary:
	return {
		"type": "status_resisted",
		# canonical
		"src": source_id,
		"dst": target_id,
		"id": status_id,
		"reason": reason,           # "resist", "immune", "ward"
		# legacy mirrors
		"source_id": source_id,
		"target_id": target_id,
		"status_id": status_id,
	}

# Upkeep narration (ResolveTurnPipeline) — purely informational; no numbers here.
static func status_tick(target_id: int, status_id: String, turns_left: int) -> Dictionary:
	return {
		"type": "status_tick",
		# canonical
		"dst": target_id,
		"id": status_id,
		"turns_left": turns_left,
		# legacy mirrors (useful for generic handlers)
		"target_id": target_id,
		"status_id": status_id,
	}

static func status_removed(target_id: int, status_id: String) -> Dictionary:
	return {
		"type": "status_removed",
		# canonical
		"dst": target_id,
		"id": status_id,
		# legacy mirrors
		"target_id": target_id,
		"status_id": status_id,
	}

static func death(target_id: int, killer_id: int) -> Dictionary:
	return {
		"type": "death",
		# canonical
		"dst": target_id,
		"src": killer_id,
		# legacy mirrors
		"target_id": target_id,
		"killer_id": killer_id,
	}

static func gauge_advanced(actor_id: int, consumed: int, next_ctb: int) -> Dictionary:
	return {
		"type": "gauge_advanced",
		"actor_id": actor_id,
		"src": actor_id,      # canonical mirror
		"consumed": consumed,
		"next_ctb": next_ctb,
	}

# Turn summary: includes consolidated deltas and event count.
# Optional: ctb_consumed may be passed if the caller wants CTB consumption visible on summary.
static func turn_summary(actor_id: int, deltas: Dictionary, events_count: int, ctb_consumed: int = -1) -> Dictionary:
	var ev := {
		"type": "turn_summary",
		"actor_id": actor_id,
		"src": actor_id,                 # canonical mirror
		"deltas": deltas.duplicate(),    # e.g., {hp:-12, mp:-3, stam:+5, cooldowns:{...}}
		"events_count": events_count,
		"ctb_consumed": ctb_consumed,    # -1 means "not provided"
	}
	return ev

# Legacy name used by BattleController
static func battle_end(victor: String, round_i: int) -> Dictionary:
	return {
		"type": "battle_end",
		"victor": victor, # "victory" | "defeat"
		"round_i": round_i,
	}

# New alias to match taxonomy naming
static func battle_finished(outcome: String, round_i: int) -> Dictionary:
	return {
		"type": "battle_finished",
		"outcome": outcome, # "victory" | "defeat"
		"round_i": round_i,
	}
