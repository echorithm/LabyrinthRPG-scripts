extends RefCounted
class_name ActionResult

var ok: bool
var outcome: String        # "normal","invalid","ko","battle_end"
var deltas: Array[Dictionary]
var events: Array[Dictionary]


static func ok_result(outcome_in: String, deltas_in: Array[Dictionary], events_in: Array[Dictionary]) -> ActionResult:
	var a := ActionResult.new()
	a.ok = true
	a.outcome = outcome_in
	a.deltas = deltas_in.duplicate(true)
	a.events = events_in.duplicate(true)
	return a

static func invalid(reason: String) -> ActionResult:
	var a := ActionResult.new()
	a.ok = false
	a.outcome = "invalid"
	a.deltas = []
	a.events = [{"type":"invalid","reason":reason}]
	return a

func to_dict() -> Dictionary:
	return {"ok": ok, "outcome": outcome, "deltas": deltas, "events": events}
