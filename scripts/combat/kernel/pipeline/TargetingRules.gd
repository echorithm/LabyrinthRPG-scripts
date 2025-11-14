# res://scripts/combat/kernel/pipeline/TargetingRules.gd
extends RefCounted
class_name TargetingRules

const ActorSnapshot := preload("res://scripts/combat/data/ActorSnapshot.gd")
const AbilityUse    := preload("res://scripts/combat/data/AbilityUse.gd")
const TurnContext   := preload("res://scripts/combat/data/TurnContext.gd")
const AbilityCatalogService := preload("res://persistence/services/ability_catalog_service.gd")

# Return one of: "self", "ally", "enemy", "any"
static func _intent_target_mode(intent_id: String) -> String:
	var i := intent_id
	# Self-only utilities
	if i in ["IT_block", "IT_block_boost", "IT_restore_stamina", "IT_restore_mana_over_time"]:
		return "self"
	# Ally side (heals/cleanses)
	if i.begins_with("IT_heal") or i.begins_with("IT_cleanse"):
		return "ally"
	# Enemy default for debuffs and any attack
	if i.begins_with("IT_apply_") or i.begins_with("IT_attack"):
		return "enemy"
	return "any"

# Validate and resolve concrete target ids based on the ability intent.
# Returns: { ok: bool, targets: Array[int], reason?: String }
func validate(actors: Array[ActorSnapshot], use: AbilityUse, _turn_ctx: TurnContext) -> Dictionary:
	var actor_id: int = int(use.actor_id)

	# Build indexes
	var by_id: Dictionary = {}
	var team_by_id: Dictionary = {}
	for a: ActorSnapshot in actors:
		if a == null: continue
		by_id[a.id] = a
		team_by_id[a.id] = String(a.team)

	if not by_id.has(actor_id):
		return { "ok": false, "reason": "no_attacker", "targets": [] }

	var my_team: String = String(team_by_id.get(actor_id, "player"))

	# Lookup ability + intent
	var row: Dictionary = AbilityCatalogService.get_by_id(String(use.ability_id))
	if row.is_empty():
		# Unknown ability → enemy default, keep MVP no-self rule
		var fallback: Array[int] = []
		if use.targets is Array:
			for v in (use.targets as Array):
				var tid := int(v)
				if tid != actor_id and team_by_id.get(tid, "") != my_team:
					fallback.append(tid)
		if fallback.is_empty():
			# pick first enemy
			for idv in by_id.keys():
				var tid2 := int(idv)
				if team_by_id.get(tid2, "") != my_team:
					fallback = [tid2]
					break
		return { "ok": not fallback.is_empty(), "targets": fallback, "reason": "unknown_ability" }

	var intent_id: String = String(row.get("intent_id", ""))
	var mode: String = _intent_target_mode(intent_id)

	match mode:
		"self":
			# Always self
			return { "ok": true, "targets": [actor_id] }

		"ally":
			# Allies only; default to self if none provided
			var t_ally: Array[int] = []
			if use.targets is Array:
				for v in (use.targets as Array):
					var tid := int(v)
					if team_by_id.get(tid, "") == my_team:
						t_ally.append(tid)
			if t_ally.is_empty():
				t_ally = [actor_id]
			return { "ok": true, "targets": t_ally }

		"enemy":
			# Enemies only; never self
			var t_enemy: Array[int] = []
			if use.targets is Array:
				for v in (use.targets as Array):
					var tid := int(v)
					if tid != actor_id and team_by_id.get(tid, "") != "" and team_by_id[tid] != my_team:
						t_enemy.append(tid)
			if t_enemy.is_empty():
				# fallback: pick the first enemy on field
				for idv in by_id.keys():
					var tid2 := int(idv)
					if team_by_id.get(tid2, "") != my_team:
						t_enemy = [tid2]
						break
			return { "ok": not t_enemy.is_empty(), "targets": t_enemy, "reason": "no_enemy" }

		_:
			# Any side: honor provided list, otherwise prefer first enemy, else self
			var t_any: Array[int] = []
			if use.targets is Array:
				for v in (use.targets as Array):
					var tid := int(v)
					if by_id.has(tid):
						t_any.append(tid)
			if t_any.is_empty():
				for idv in by_id.keys():
					var tid2 := int(idv)
					if team_by_id.get(tid2, "") != my_team:
						t_any = [tid2]
						break
			if t_any.is_empty():
				t_any = [actor_id]
			return { "ok": true, "targets": t_any }
