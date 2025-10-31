extends RefCounted
class_name EconomyLedgerSchema

static func validate(d_in: Dictionary) -> Dictionary:
	var out: Dictionary = {
		"ledger": [],                # Array[Dictionary]
		"spent_gold_total": 0,
		"earned_gold_total": 0
	}
	var lg_any: Variant = d_in.get("ledger", [])
	var lg_in: Array = (lg_any as Array) if (lg_any is Array) else []
	var cleaned: Array[Dictionary] = []
	for row_any in lg_in:
		if row_any is Dictionary:
			var r: Dictionary = row_any
			cleaned.append({
				"ts": int(r.get("ts", Time.get_unix_time_from_system())),
				"op": String(r.get("op", "")),                  # "BUY" | "SELL"
				"vendor": String(r.get("vendor", "")),
				"id": String(r.get("id", "")),
				"count": int(r.get("count", 0)),
				"unit_price": int(r.get("unit_price", 0)),
				"total": int(r.get("total", 0))
			})
	out["ledger"] = cleaned
	out["spent_gold_total"] = int(d_in.get("spent_gold_total", 0))
	out["earned_gold_total"] = int(d_in.get("earned_gold_total", 0))
	return out
