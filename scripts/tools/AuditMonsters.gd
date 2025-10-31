# scripts/tools/AuditMonsters.gd
@tool
extends EditorScript

const MONSTER_JSON_PATH: String = "res://data/combat/enemies/monster_catalog.json"
const OUTPUT_REPORT: String = "user://monster_audit_report.txt"
const OUTPUT_FIXED_JSON: String = "user://monster_catalog_fixed.json"

# Use literal arrays/dicts only for consts (constructor calls aren't constant expressions).
const ALLOWED_ROLES: Array[String] = ["regular", "elite", "boss"]
const ALLOWED_ELEMENTS: Array[String] = ["physical", "fire", "water", "earth", "wind", "light", "dark"]
const ALLOWED_DMG: Array[String] = ["pierce", "slash", "blunt", "ranged", "fire", "water", "earth", "wind", "light", "dark"]
const ALLOWED_TARGETING: Array[String] = ["single", "multi", "aoe", "cone", "line"]
const ALLOWED_RANGE: Array[String] = ["melee", "ranged"]

const INTENT_TO_DMG := {
	"IT_attack_phys_pierce": "pierce",
	"IT_attack_phys_slash": "slash",
	"IT_attack_phys_blunt": "blunt",
	"IT_attack_phys_ranged": "ranged",
	"IT_attack_mag_fire": "fire",
	"IT_attack_mag_water": "water",
	"IT_attack_mag_earth": "earth",
	"IT_attack_mag_wind": "wind",
	"IT_attack_mag_light": "light",
	"IT_attack_mag_dark": "dark",
}

const DEFAULT_BIAS := {
	"power":  {"STR": 5, "AGI": 3, "DEX": 2},
	"finesse":{"DEX": 5, "AGI": 3, "STR": 2},
	"arcane": {"INT": 6, "WIS": 3, "DEX": 1},
	"support":{"WIS": 5, "INT": 3, "LCK": 2},
}

func _run() -> void:
	var report: Array[String] = []
	var fixed_root: Array[Dictionary] = []
	var raw: String = ""
	if not FileAccess.file_exists(MONSTER_JSON_PATH):
		push_error("Monster JSON not found at: %s" % MONSTER_JSON_PATH)
		return

	raw = FileAccess.get_file_as_string(MONSTER_JSON_PATH)

	# Explicitly type as Variant to avoid "inferred from Variant value" warning.
	var parsed: Variant = JSON.parse_string(raw)
	if parsed == null or typeof(parsed) != TYPE_ARRAY:
		push_error("Monster JSON root must be an Array.")
		return

	var monsters: Array = parsed
	var monster_index: int = 0
	for item in monsters:
		monster_index += 1
		var index_tag: String = "index=%d" % monster_index
		if typeof(item) != TYPE_DICTIONARY:
			report.append(_err(index_tag, "Root element is not a Dictionary"))
			continue

		var monster: Dictionary = item
		_normalize_monster(monster)

		var errs: Array[String] = _validate_monster(monster)
		for e in errs:
			report.append(e)

		fixed_root.append(monster)

	# Write report
	var report_text: String = "\n".join(PackedStringArray(report))
	_save_text(OUTPUT_REPORT, report_text)

	# Write fixed JSON
	_save_text(OUTPUT_FIXED_JSON, JSON.stringify(fixed_root, "  "))
	print("[AuditMonsters] Done. Report → %s, Fixed JSON → %s" % [OUTPUT_REPORT, OUTPUT_FIXED_JSON])

func _normalize_monster(monster: Dictionary) -> void:
	if not monster.has("abilities"):
		return
	var abilities: Array = monster["abilities"]
	for ability_var in abilities:
		if typeof(ability_var) != TYPE_DICTIONARY:
			continue
		var ability: Dictionary = ability_var

		# Replace Taunt* animations with a safe default
		if ability.has("animation_key"):
			var ak: String = str(ability["animation_key"])
			if ak.to_lower().begins_with("taunt"):
				ability["animation_key"] = "Attack01"

		# Ensure stat_bias exists and totals 10
		if not ability.has("stat_bias") or typeof(ability["stat_bias"]) != TYPE_DICTIONARY or (ability["stat_bias"] as Dictionary).is_empty():
			var scaling: String = str(ability.get("scaling", "support"))
			var fallback: Dictionary = _bias_fallback_for_scaling(scaling)
			ability["stat_bias"] = fallback.duplicate()
		else:
			ability["stat_bias"] = _fix_bias_to_ten(ability["stat_bias"])

		# Clamp lanes to [0..1] and zero tiny floats
		if ability.has("lanes") and typeof(ability["lanes"]) == TYPE_DICTIONARY:
			var lanes: Dictionary = ability["lanes"]
			for k in lanes.keys():
				var v := float(lanes[k])
				if absf(v) < 0.0005:
					v = 0.0
				lanes[k] = clampf(v, 0.0, 1.0)

func _bias_fallback_for_scaling(scaling: String) -> Dictionary:
	if DEFAULT_BIAS.has(scaling):
		return DEFAULT_BIAS[scaling]
	return DEFAULT_BIAS["support"]

func _fix_bias_to_ten(bias_in: Dictionary) -> Dictionary:
	var keys := PackedStringArray()
	var vals: Array[float] = []
	var total: float = 0.0

	for k in bias_in.keys():
		var v := float(bias_in[k])
		if v < 0.0:
			v = 0.0
		keys.append(str(k))
		vals.append(v)
		total += v

	if total <= 0.0:
		return {"WIS": 5, "INT": 3, "LCK": 2} # safe fallback

	# scale and round
	var ints: Array[int] = []
	var running_sum: int = 0
	for v in vals:
		var iv := int(roundf(v * 10.0 / total))
		ints.append(iv)
		running_sum += iv

	# distribute remainder
	var delta: int = 10 - running_sum
	if delta != 0:
		var order: Array[Dictionary] = []
		for i in keys.size():
			order.append({"i": i, "v": vals[i]})
		order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a["v"]) > float(b["v"])
		)
		var si: int = 0
		while delta != 0 and order.size() > 0:
			var idx: int = int(order[si]["i"])
			ints[idx] = max(0, ints[idx] + _sign(delta))
			delta -= _sign(delta)
			si = (si + 1) % order.size()

	var out := {}
	for i in keys.size():
		if ints[i] > 0:
			out[keys[i]] = ints[i]
	return out

func _validate_monster(m: Dictionary) -> Array[String]:
	var errs: Array[String] = []
	var id_txt := "id=%s slug=%s" % [str(m.get("id","?")), str(m.get("slug","?"))]

	# Basic fields
	if not m.has("schema_version"): errs.append(_err(id_txt, "missing schema_version"))
	if not m.has("id"): errs.append(_err(id_txt, "missing id"))
	if not m.has("slug"): errs.append(_err(id_txt, "missing slug"))
	if not m.has("display_name"): errs.append(_err(id_txt, "missing display_name"))

	# Scene path exists
	var scene_path := str(m.get("scene_path",""))
	if scene_path == "" or not ResourceLoader.exists(scene_path):
		errs.append(_err(id_txt, "scene_path missing or not found: %s" % scene_path))

	# Roles & boss_only rule
	var boss_only := bool(m.get("boss_only", false))
	if m.has("roles_allowed") and typeof(m["roles_allowed"]) == TYPE_ARRAY:
		var roles: Array = m["roles_allowed"]
		for r_var in roles:
			var r: String = str(r_var)
			if r not in ALLOWED_ROLES:
				errs.append(_err(id_txt, "roles_allowed contains invalid role: %s" % r))
		if boss_only and not (roles.size() == 1 and str(roles[0]) == "boss"):
			errs.append(_err(id_txt, "boss_only=true but roles_allowed != ['boss']"))
	else:
		errs.append(_err(id_txt, "missing roles_allowed"))

	# Abilities
	if not m.has("abilities") or typeof(m["abilities"]) != TYPE_ARRAY or (m["abilities"] as Array).is_empty():
		errs.append(_err(id_txt, "missing abilities[]"))
	else:
		var weight_sum: float = 0.0
		for ab_var in m["abilities"]:
			var ab: Variant = ab_var
			errs.append_array(_validate_ability(id_txt, ab))
			weight_sum += float((ab as Dictionary).get("weight", 0.0))
		if absf(weight_sum - 1.0) > 0.01:
			errs.append(_warn(id_txt, "ability weight sum ~= %0.3f (should be 1.0)" % weight_sum))

	return errs

func _validate_ability(id_txt: String, ab: Variant) -> Array[String]:
	var errs: Array[String] = []
	if typeof(ab) != TYPE_DICTIONARY:
		errs.append(_err(id_txt, "ability is not a Dictionary"))
		return errs

	var abd: Dictionary = ab
	var aid := str(abd.get("ability_id","?"))
	var tag := "%s ability=%s" % [id_txt, aid]

	# Required
	for k in ["element","scaling","intent_id","damage_type","animation_key"]:
		if not abd.has(k):
			errs.append(_err(tag, "missing %s" % k))

	# Enumerations
	if abd.has("element") and str(abd["element"]) not in ALLOWED_ELEMENTS:
		errs.append(_err(tag, "invalid element: %s" % str(abd["element"])))
	if abd.has("damage_type") and str(abd["damage_type"]) not in ALLOWED_DMG:
		errs.append(_err(tag, "invalid damage_type: %s" % str(abd["damage_type"])))

	# intent ↔ damage_type consistency
	var intent := str(abd.get("intent_id",""))
	var dmg := str(abd.get("damage_type",""))
	if INTENT_TO_DMG.has(intent) and str(INTENT_TO_DMG[intent]) != dmg:
		errs.append(_err(tag, "intent_id(%s) implies %s but damage_type=%s" % [intent, str(INTENT_TO_DMG[intent]), dmg]))

	# lanes consistency: only damage_type lane should be 1.0; others 0.0
	if abd.has("lanes") and typeof(abd["lanes"]) == TYPE_DICTIONARY:
		var lanes: Dictionary = abd["lanes"]
		var lane_ok: bool = true
		for k in lanes.keys():
			var v := float(lanes[k])
			if k == dmg:
				if absf(v - 1.0) > 0.001:
					lane_ok = false
			else:
				if absf(v) > 0.001:
					lane_ok = false
		if not lane_ok:
			errs.append(_warn(tag, "lanes do not match damage_type=%s (expect 1.0 only on that lane)" % dmg))
	else:
		errs.append(_err(tag, "missing lanes"))

	# AI fields
	if abd.has("ai") and typeof(abd["ai"]) == TYPE_DICTIONARY:
		var ai: Dictionary = abd["ai"]
		if ai.has("targeting") and str(ai["targeting"]) not in ALLOWED_TARGETING:
			errs.append(_err(tag, "invalid ai.targeting: %s" % str(ai["targeting"])))
		if ai.has("range") and str(ai["range"]) not in ALLOWED_RANGE:
			errs.append(_err(tag, "invalid ai.range: %s" % str(ai["range"])))
	else:
		errs.append(_err(tag, "missing ai block"))

	# support scaling: base_power should be 0 and crit off
	if str(abd.get("scaling","")) == "support":
		if int(abd.get("base_power", -1)) != 0:
			errs.append(_warn(tag, "support ability base_power should be 0"))
		if bool(abd.get("crit_allowed", true)):
			errs.append(_warn(tag, "support ability crit_allowed should be false"))

	# stat_bias must total 10
	if abd.has("stat_bias") and typeof(abd["stat_bias"]) == TYPE_DICTIONARY:
		var s: int = 0
		for v in (abd["stat_bias"] as Dictionary).values():
			s += int(v)
		if s != 10:
			errs.append(_fix(tag, "stat_bias sums to %d; normalized to 10 in output file" % s))
	else:
		errs.append(_fix(tag, "missing stat_bias; defaulted based on 'scaling'"))

	# Animation checks
	var ak := str(abd.get("animation_key",""))
	if ak.to_lower().begins_with("taunt"):
		errs.append(_fix(tag, "animation_key was Taunt*; replaced with Attack01 in output file"))

	# CTB sanity
	var ctb := int(abd.get("ctb_cost", 100))
	if ctb < 60 or ctb > 160:
		errs.append(_warn(tag, "ctb_cost=%d looks out-of-band (60..160 typical)" % ctb))

	return errs

func _save_text(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(text)
		f.close()

func _err(id_txt: String, msg: String) -> String:
	return "[ERROR] %s — %s" % [id_txt, msg]

func _warn(id_txt: String, msg: String) -> String:
	return "[WARN ] %s — %s" % [id_txt, msg]

func _fix(id_txt: String, msg: String) -> String:
	return "[FIX  ] %s — %s" % [id_txt, msg]

func _sign(x: int) -> int:
	if x < 0: return -1
	if x > 0: return 1
	return 0
