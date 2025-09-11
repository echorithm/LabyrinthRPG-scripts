# File: res://scripts/combat/EnemyBrain.gd
# Godot 4.4.1 — Tiny weighted picker

class_name EnemyBrain
extends RefCounted

static var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
static var _rng_ready: bool = false

static func pick(def: EnemyDef) -> IntentDef:
	if def == null or def.intents.is_empty():
		return null
	if not _rng_ready:
		_rng.randomize()
		_rng_ready = true
	var total: int = 0
	for wi in def.intents:
		total += max(0, wi.weight)
	if total <= 0:
		return def.intents[0].intent

	var roll: int = _rng.randi_range(0, total - 1)
	var acc: int = 0
	for wi in def.intents:
		acc += max(0, wi.weight)
		if roll < acc:
			return wi.intent
	return def.intents[def.intents.size() - 1].intent
