extends RefCounted
class_name VendorBlockSchema
## ADR-aligned vendor instance block (no stock).
## Stored at village.json -> vendors[instance_id].

static func validate(v_in: Dictionary) -> Dictionary:
	var out: Dictionary = {
		"kind": String(v_in.get("kind", "")),
		"active": bool(v_in.get("active", false)),
		"period_index": int(v_in.get("period_index", 0))
	}
	return out
