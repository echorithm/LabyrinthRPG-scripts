extends RefCounted
class_name RuntimeReducer

const StatusEngine := preload("res://scripts/combat/status/StatusEngine.gd")

static func apply(ar: Object, player: Object, monster: Object) -> Dictionary:
	# ar: ActionResult-like {events: Array[Dict], deltas: Array[Dict], ...}
	var monster_took_damage := false

	# 1) Emit/persist statuses (caller still emits signals separately)
	for e in (ar.events if "events" in ar else []):
		if e is Dictionary:
			StatusEngine.apply_event_if_status(e, player, monster)
			if String(e.get("type","")) == "damage_applied":
				if int(e.get("target_id", e.get("target",-1))) == monster.id and int(e.get("total",0)) > 0:
					monster_took_damage = true

	# 2) Apply deltas
	for d in (ar.deltas if "deltas" in ar else []):
		if d is Dictionary:
			var aid := int(d.get("actor_id",-1))
			var rt := (player if aid == player.id else (monster if aid == monster.id else null))
			if rt == null: continue
			if d.has("hp"):   rt.hp   = clampi(rt.hp + int(d["hp"]),   0, rt.hp_max)
			if d.has("mp"):   rt.mp   = clampi(rt.mp + int(d["mp"]),   0, rt.mp_max)
			if d.has("stam"): rt.stam = clampi(rt.stam + int(d["stam"]), 0, rt.stam_max)
			if d.has("cooldowns"):
				for k_any in (d["cooldowns"] as Dictionary).keys():
					var k := String(k_any)
					rt.cooldowns[k] = max(0, int((d["cooldowns"] as Dictionary)[k_any]))
			if d.has("charges"):
				for k2_any in (d["charges"] as Dictionary).keys():
					var k2 := String(k2_any)
					rt.charges[k2] = max(0, int(rt.charges.get(k2,0)) + int((d["charges"] as Dictionary)[k2_any]))

	# 3) Merge tallies (return a flag so controller can log)
	var merged_any := false
	if "skill_tally_player" in ar and ar.skill_tally_player is Dictionary and player != null and player.has_method("skill_usage_merge_map"):
		player.call("skill_usage_merge_map", ar.skill_tally_player)
		merged_any = true
	elif "skill_tally" in ar and ar.skill_tally is Dictionary and (ar.skill_tally as Dictionary).has(player.id):
		var map_b: Dictionary = (ar.skill_tally as Dictionary)[player.id]
		if player != null and player.has_method("skill_usage_merge_map"):
			player.call("skill_usage_merge_map", map_b)
			merged_any = true

	return {
		"monster_took_damage": monster_took_damage,
		"merged_tallies": merged_any,
	}
