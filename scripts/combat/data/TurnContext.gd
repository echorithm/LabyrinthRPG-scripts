extends RefCounted
class_name TurnContext

var battle_id: String
var encounter_id: String
var seed: int
var round: int
var ctb_snapshot: Dictionary
var actor_order: Array[int]
var hit_bonus_pct: float = 0.0
var damage_bonus_pct: float = 0.0

static func from_ids(battle_id_in: String, encounter_id_in: String, seed_in: int, round_in: int, ctb_snapshot_in: Dictionary, order_in: Array[int]) -> TurnContext:
	var t := TurnContext.new()
	t.battle_id = battle_id_in
	t.encounter_id = encounter_id_in
	t.seed = seed_in
	t.round = round_in
	t.ctb_snapshot = ctb_snapshot_in.duplicate(true)
	t.actor_order = []
	for idv in order_in:
		t.actor_order.append(int(idv))
	return t
