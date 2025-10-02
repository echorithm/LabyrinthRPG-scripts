extends RefCounted
class_name ItemText
## Formats affix lines & adds quality markers per ui rules.

const _S := preload("res://persistence/util/save_utils.gd")
const Registry := preload("res://scripts/items/AffixRegistry.gd")

static func format_affix_lines(affixes: Array, rarity_code: String) -> PackedStringArray:
	var reg := Registry.new()
	reg.ensure_loaded()
	var ui: Dictionary = reg.ui_rules()

	var dp := int(_S.dget(ui, "decimal_places", 0))
	var show_q := bool(_S.dget(ui, "show_quality_tier", true))

	var qt: Dictionary = _S.to_dict(ui.get("quality_tiers", {}))
	var steps: int = int(_S.dget(qt, "steps", 5))
	var symbols_arr: Array = (_S.dget(qt, "symbols", []) as Array)

	var out := PackedStringArray()
	for a_any in affixes:
		if not (a_any is Dictionary):
			continue
		var a: Dictionary = a_any
		var name := String(_S.dget(a, "id", ""))
		var val := float(_S.dget(a, "value", 0.0))
		var units := String(_S.dget(a, "units", ""))
		var q := float(_S.dget(a, "quality", 1.0))

		var line := name + ": " + _fmt_val(val, dp, units)
		if show_q and symbols_arr.size() >= steps:
			var tier := clampi(int(floor(clampf(q, 0.0, 1.0) * float(steps))), 0, steps - 1)
			line += " " + String(symbols_arr[tier])
		out.append(line)
	return out

static func _fmt_val(v: float, dp: int, units: String) -> String:
	var scale := pow(10.0, dp)
	var rounded := roundf(v * scale) / scale
	var s := str(rounded)
	if units == "percent":
		return s + "%"
	return s
