# GestureRecognizer.gd — Unistroke matcher + data-driven gates (Godot 4.5)
# Returns: { "id": StringName, "confidence": float }

extends RefCounted


const RESAMPLE_COUNT: int = 64
const MIN_INPUT_POINTS: int = 8
const SPECS_PATH: String = "res://scripts/combat/gestures/gesture_specs.json"

static var _initialized: bool = false
static var _template_ids: Array[StringName] = [] as Array[StringName]
static var _template_pts: Array[PackedVector2Array] = [] as Array[PackedVector2Array]
static var _specs: Dictionary = {}

# ------------------------------------------------------------
# Public API
# ------------------------------------------------------------
static func ensure_initialized() -> void:
	if _initialized:
		return
	_initialized = true
	_template_ids.clear()
	_template_pts.clear()
	_specs.clear()

	_init_default_templates()

	# JSON-only specs
	_specs = {}
	_load_specs_from_json(_specs, SPECS_PATH)

static func recognize(points: Array[Vector2]) -> Dictionary:
	var result_id: StringName = StringName("")
	var conf: float = 0.0
	if points.size() < MIN_INPUT_POINTS or _template_ids.is_empty():
		return { "id": result_id, "confidence": conf }

	var pts: Array[Vector2] = _smooth(points, 1)
	var norm: PackedVector2Array = _normalize_local(_resample_local(pts, RESAMPLE_COUNT))

	# Compute distances to all templates
	var best_d: float = 1e30
	var best_idx: int = -1
	var dists: Array[float] = []
	dists.resize(_template_ids.size())

	for i in range(_template_ids.size()):
		var tpts: PackedVector2Array = _template_pts[i]
		var d: float = _avg_dist(norm, tpts)
		dists[i] = d
		if d < best_d:
			best_d = d
			best_idx = i

	# Re-rank by: first id whose gates PASS
	var order: Array[int] = []
	order.resize(_template_ids.size())
	for i in range(order.size()):
		order[i] = i
	order.sort_custom(func(a: int, b: int) -> bool:
		return dists[a] < dists[b]
	)

	var chosen_idx: int = best_idx
	for i in order:
		var tid: StringName = _template_ids[i]
		var gates := passes_symbol_filters_verbose(tid, points)
		if bool(gates["ok"]):
			chosen_idx = i
			best_d = dists[i]
			break

	var best_id: StringName = _template_ids[chosen_idx]
	conf = clamp(1.0 / (1.0 + best_d * 6.0), 0.0, 1.0)
	return { "id": best_id, "confidence": conf }


static func passes_symbol_filters(result_id: StringName, raw_points: Array[Vector2]) -> bool:
	var v: Dictionary = passes_symbol_filters_verbose(result_id, raw_points)
	return bool(v["ok"])

# Verbose version to see which gate failed.
# Returns: { ok: bool, failed: PackedStringArray, feats: Dictionary }
static func passes_symbol_filters_verbose(result_id: StringName, raw_points: Array[Vector2]) -> Dictionary:
	if raw_points.size() < MIN_INPUT_POINTS:
		return { "ok": false, "failed": PackedStringArray(["too_few_points"]), "feats": {} }
	var feats: Dictionary = _calc_features(raw_points)
	var id: String = String(result_id)
	if not _specs.has(id):
		return { "ok": true, "failed": PackedStringArray(), "feats": feats }
	var spec: Dictionary = _specs[id]
	var failed := PackedStringArray()
	var ok: bool = _gate_verbose(spec, feats, failed)
	return { "ok": ok, "failed": failed, "feats": feats }

# ------------------------------------------------------------
# Templates (representative strokes per ability id)
# ------------------------------------------------------------
static func _init_default_templates() -> void:
	_template_ids.clear()
	_template_pts.clear()

	# Sword
	_add_template(&"arc_slash", [Vector2(10,100), Vector2(190,100)])
	_add_template(&"arc_slash", [Vector2(190,100), Vector2(10,100)])
	_add_template(&"riposte", [Vector2(70,120), Vector2(95,145), Vector2(155,75)])

	# Spear
	_add_template(&"thrust", [Vector2(40,160), Vector2(160,40)])
	# Skewer (rightward peak: long up-right then short down-right)
	_add_template(&"skewer", [
		Vector2(60, 150), Vector2(132, 72), Vector2(162, 98)
	])

	# Mace
	_add_template(&"crush", [Vector2(100,40), Vector2(100,170)])
	_add_template(&"guard_break", [Vector2(90,80), Vector2(90,150), Vector2(160,150)])

	# Bow
	_add_template(&"aimed_shot", [Vector2(55,90), Vector2(165,100), Vector2(55,135)])
	_add_template(&"piercing_bolt", [Vector2(40,110), Vector2(170,110), Vector2(150,90)])

	# Light
	_add_template(&"heal", [Vector2(40,150), Vector2(100,60), Vector2(160,150)])
	# Purify (triangle) – multiple draw orders
	# base L→R → apex → back to base L (existing order)
	_add_template(&"purify", [Vector2(60,150), Vector2(140,150), Vector2(100,70), Vector2(60,150)])
	# base L → apex → base R → back to base L
	_add_template(&"purify", [Vector2(60,150), Vector2(100,70), Vector2(140,150), Vector2(60,150)])
	# apex → base L → base R → back to apex
	_add_template(&"purify", [Vector2(100,70), Vector2(60,150), Vector2(140,150), Vector2(100,70)])

	# Dark
	_add_template(&"shadow_grasp", [Vector2(110,40), Vector2(110,160), Vector2(145,150)])
	# Curse Mark (diamond) – several orders, CW/CCW, different start points
	_add_template(&"curse_mark", [Vector2(100,60), Vector2(150,110), Vector2(100,160), Vector2(50,110), Vector2(100,60)]) # top → right → bottom → left → top
	_add_template(&"curse_mark", [Vector2(100,60), Vector2(50,110),  Vector2(100,160), Vector2(150,110), Vector2(100,60)]) # top → left → bottom → right → top
	_add_template(&"curse_mark", [Vector2(50,110),  Vector2(100,60),  Vector2(150,110), Vector2(100,160), Vector2(50,110)]) # left → top → right → bottom → left
	_add_template(&"curse_mark", [Vector2(150,110), Vector2(100,60),  Vector2(50,110),  Vector2(100,160), Vector2(150,110)]) # right → top → left → bottom → right

	# Fire
	_add_template(&"firebolt", [Vector2(40,70), Vector2(100,150), Vector2(160,70)])
	# Flame Wall — multiple curvatures so arch beats caret in distance
	_add_template(&"flame_wall", [Vector2(60,140), Vector2(100,70), Vector2(140,140)])  # 3-pt arch
	_add_template(&"flame_wall", [Vector2(60,140), Vector2(80,90), Vector2(100,70), Vector2(120,90), Vector2(140,140)])

	# Water
	_add_template(&"water_jet", [Vector2(50,110), Vector2(85,95), Vector2(120,110), Vector2(155,95)])
	_add_template(&"tide_surge", [Vector2(210, 70),  Vector2(50, 120),  Vector2(210, 170)])  # extra tall
	_add_template(&"tide_surge", [Vector2(200, 90),  Vector2(60, 120),  Vector2(200, 150)])  # medium
	_add_template(&"tide_surge", [Vector2(210, 80),  Vector2(70, 120),  Vector2(200, 160)])  # apex slightly right
	_add_template(&"tide_surge", [Vector2(200, 80),  Vector2(40, 120),  Vector2(190, 160)]) 	

	# Earth
	_add_template(&"stone_spikes", [Vector2(60,90), Vector2(140,90), Vector2(60,140), Vector2(140,140)])
	_add_template(&"bulwark", [Vector2(70,80),  Vector2(150,80), Vector2(150,160), Vector2(70,160), Vector2(70,80)])      # TL→TR→BR→BL→TL
	_add_template(&"bulwark", [Vector2(150,80), Vector2(70,80),  Vector2(70,160),  Vector2(150,160), Vector2(150,80)])     # TR→TL→BL→BR→TR
	_add_template(&"bulwark", [Vector2(70,160), Vector2(70,80),  Vector2(150,80),  Vector2(150,160), Vector2(70,160)])     # BL→TL→TR→BR→BL
	_add_template(&"bulwark", [Vector2(150,160),Vector2(150,80), Vector2(70,80),   Vector2(70,160),  Vector2(150,160)])    # BR→TR→TL→BL→BR

	# Rounded-corner variant (closer to your demo screenshot)
	_add_template(&"bulwark", [
		Vector2(78,88), Vector2(145,85), Vector2(155,95), Vector2(155,145),
		Vector2(145,155), Vector2(90,155), Vector2(80,145), Vector2(78,95), Vector2(78,88)
	])
	_add_template(&"bulwark", [Vector2(120,120), Vector2(260,120), Vector2(260,260), Vector2(120,260), Vector2(120,120)])
	_add_template(&"bulwark", [Vector2(260,120), Vector2(120,120), Vector2(120,260), Vector2(260,260), Vector2(260,120)])

	# Slightly rounded large square (closer to hand-drawn)
	_add_template(&"bulwark", [
		Vector2(126,128), Vector2(252,122), Vector2(260,130), Vector2(260,252),
		Vector2(252,260), Vector2(128,260), Vector2(120,252), Vector2(120,130), Vector2(126,128)
	])
	
	# Wind
	_add_template(&"gust", [Vector2(70,140), Vector2(78,120), Vector2(90,100), Vector2(110,85), Vector2(135,80)])
	
	# Cyclone — smooth arch up "∪" (two variants: 3-pt and smoother 7-pt)
	_add_template(&"cyclone", [Vector2(60,80), Vector2(100,150), Vector2(140,80)])
	_add_template(&"cyclone", [
		Vector2(60,80), Vector2(85,115), Vector2(100,135),
		Vector2(115,145), Vector2(130,135), Vector2(145,115),
		Vector2(170,80)
	])
	
	
	# Defensive
	_add_template(&"block", [Vector2(100,170), Vector2(100,40)])
	
		# --- Unarmed / Utility ---
	# punch: single down-right slash (unique: net right + down, straight)
	_add_template(&"punch", [Vector2(40,60), Vector2(160,140)])

	# Rest — short left tap then long down-right slide
	_add_template(&"rest", [Vector2(150,70), Vector2(122,94), Vector2(200,230)])
	_add_template(&"rest", [Vector2(146,70), Vector2(120,92), Vector2(194,220)]) # slight shorter slide
	_add_template(&"rest", [Vector2(154,70), Vector2(126,98), Vector2(206,236)]) # slight longer slide

	_add_template(&"meditate", [
	Vector2(60,160), Vector2(92,60), Vector2(112,150), Vector2(138,60), Vector2(170,160)
	])
	_add_template(&"meditate", [  # narrow M, sharp peaks
		Vector2(80,160), Vector2(100,70), Vector2(112,148), Vector2(128,70), Vector2(148,160)
	])
	_add_template(&"meditate", [  # wide M
		Vector2(50,160), Vector2(90,60), Vector2(115,150), Vector2(150,60), Vector2(190,160)
	])
	_add_template(&"meditate", [  # asymmetric hand-drawn
		Vector2(62,160), Vector2(94,62), Vector2(114,146), Vector2(142,68), Vector2(170,160)
	])
	_add_template(&"meditate", [  # extra mid sample helps resampler
		Vector2(60,160), Vector2(90,60), Vector2(108,120), Vector2(112,148), Vector2(130,60), Vector2(160,160)
	])

static func _add_template(id: StringName, pts_in: Array[Vector2]) -> void:
	var res: PackedVector2Array = _normalize_local(_resample_local(pts_in, RESAMPLE_COUNT))
	_template_ids.append(id)
	_template_pts.append(res)

# ------------------------------------------------------------
# Built-in specs + JSON overrides
# ------------------------------------------------------------
static func _builtin_specs() -> Dictionary:
	return {
		"arc_slash": { "dir":"h","horiz_slope_max":0.40,"straight_max":0.08,"detour_max":1.04,"corners_max":0 },
		"riposte": { "closed_min":0.18,"corners_min":1,"check_mark":true,"check_ratio_min":1.15,"not_perfect_line_min":0.02 },

		"thrust": { "dir":"ne","slope_range":Vector2(0.40,2.00),"straight_max":0.08,"detour_max":1.04,"corners_max":0 },
		"skewer": { "dir":"ne","slope_range":Vector2(0.40,2.00),"straight_max":0.14,"detour_max":1.12,"corners_min":1,"check_mark":true,"check_ratio_min":1.15,"not_perfect_line_min":0.02 },

		"crush": { "dir":"v","dy_sign":"down","vert_slope_max":0.35,"straight_max":0.08,"detour_max":1.04,"corners_max":0 },
		"guard_break": { "closed_min":0.18,"corners_min":1,"right_angle":true,"angle_tolerance_deg":25.0 },

		"aimed_shot": {
			"closed_min":0.18, "corners_min":1,
			"chevron_apex_rightmost":true,
			"chevron_leg_min_ratio":0.20,
			"chevron_cos_range": Vector2(-0.999, 0.95)
			},
		"piercing_bolt": { "dir":"h","dx_min_norm":0.25,"horiz_slope_max":0.25,"straight_max":0.10,"detour_max":1.10,"tail_samples":12,"tail_apex_rightmost":true,"tail_two_legs_right":true,"tail_leg_frac_range":Vector2(0.05,0.25),"tail_corners_range":Vector2i(1,2) },

		"heal": { "closed_min":0.18,"corners_min":1,"apex_high":true },
		"purify": { "closed_max":0.30,"corners_range":Vector2i(2,6),"not_line_min":0.04 },

		"shadow_grasp": { "closed_min":0.18,"corners_max":2,"hook_right":true,"hook_tail_ratio_min":0.15 },
		"curse_mark": { "closed_max":0.25,"corners_range":Vector2i(3,6) },

		"firebolt": { "closed_min":0.18,"corners_min":1,"apex_low":true },
		"flame_wall": { "closed_min":0.18,"corners_max":0,"not_line_min":0.02,"concavity":"down" },

		"water_jet": { "dir":"h","horiz_slope_max":0.60,"not_line_min":0.04,"detour_min":1.10,"corners_max":3 },
		"tide_surge": { "closed_min":0.18,"corners_max":0,"not_line_min":0.02,"concavity":"up" },

		"stone_spikes": { "closed_min":0.18,"corners_range":Vector2i(2,4),"alternate_turns":true,"net_dir":"right" },
		"bulwark": { "closed_max":0.25,"corners_range":Vector2i(3,6),"axis_aligned_bias":true },

		"gust": { "closed_min":0.18,"corners_max":0,"not_line_min":0.02,"arc_direction":"cw" },

		"block": { "dir":"v","dy_sign":"up","vert_slope_max":0.35,"straight_max":0.08,"detour_max":1.04,"corners_max":0 }
	}

static func _load_specs_from_json(specs: Dictionary, path: String) -> void:
	if not ResourceLoader.exists(path):
		return
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var txt: String = f.get_as_text()
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var d: Dictionary = parsed as Dictionary
	for k in d.keys():
		var id: String = String(k)
		var v_any: Variant = d[k]
		if typeof(v_any) == TYPE_DICTIONARY:
			var incoming: Dictionary = (v_any as Dictionary).duplicate()
			_coerce_field_vec2(incoming, "slope_range")
			_coerce_field_vec2(incoming, "chevron_cos_range")
			_coerce_field_vec2(incoming, "tail_leg_frac_range")
			_coerce_field_vec2(incoming, "bbox_aspect_range") 
			_coerce_field_vec2i(incoming, "corners_range")
			_coerce_field_vec2i(incoming, "tail_corners_range")
			specs[id] = incoming

static func _coerce_field_vec2(d: Dictionary, key: String) -> void:
	if not d.has(key):
		return
	var v: Variant = d[key]
	if v is Vector2:
		return
	if v is Array:
		var a: Array = v as Array
		if a.size() >= 2:
			d[key] = Vector2(float(a[0]), float(a[1]))

static func _coerce_field_vec2i(d: Dictionary, key: String) -> void:
	if not d.has(key):
		return
	var v: Variant = d[key]
	if v is Vector2i:
		return
	if v is Array:
		var a: Array = v as Array
		if a.size() >= 2:
			d[key] = Vector2i(int(a[0]), int(a[1]))

# ------------------------------------------------------------
# Feature extraction + gating
# ------------------------------------------------------------
static func _calc_features(raw_points: Array[Vector2]) -> Dictionary:
	var proc: PackedVector2Array = _normalize_local(_resample_local(_smooth(raw_points, 1), RESAMPLE_COUNT))
	var proc_raw: PackedVector2Array = _normalize_local(_resample_local(raw_points, RESAMPLE_COUNT))
	
	var total_turn_deg: float = _total_signed_turn_deg(proc_raw)
	var radial_outward_frac: float = _radial_outward_frac(proc)


	var a: Vector2 = proc[0]
	var b: Vector2 = proc[proc.size() - 1]
	var dx: float = b.x - a.x
	var dy: float = b.y - a.y
	var abs_dx: float = abs(dx)
	var abs_dy: float = abs(dy)

	var straight: float = _straightness_ratio(proc)
	var closed: float = _closure_ratio(proc)
	var corners60: int = _corner_count(proc_raw, 60.0)
	var chord: float = max(0.001, a.distance_to(b))
	var path_len: float = _polyline_length(proc_raw)
	var detour: float = path_len / chord
	var slope: float = abs_dy / max(0.001, abs_dx)

	var apex_max_x_idx: int = _max_x_index(proc)
	var apex_min_y_idx: int = _min_y_index(proc)
	
	var bb: Rect2 = _bbox(proc)
	var bb_aspect: float = bb.size.x / max(0.001, bb.size.y)
	var ext_max_x: int = _max_x_index(proc)
	var ext_min_x: int = _min_x_index(proc)   # uses helper above
	var ext_max_y: int = _max_y_index(proc)
	var ext_min_y: int = _min_y_index(proc)

	var seg_len_1: float = _segment_length(proc, 0, apex_max_x_idx)
	var seg_len_2: float = _segment_length(proc, apex_max_x_idx, proc.size() - 1)
	var v1: Vector2 = proc[apex_max_x_idx] - proc[0]
	var v2: Vector2 = proc[proc.size() - 1] - proc[apex_max_x_idx]
	var cosang: float = 0.0
	if v1.length() > 0.0 and v2.length() > 0.0:
		cosang = v1.normalized().dot(v2.normalized())
		
	var apex_min_x_idx2: int = _min_x_index(proc)
	var seg_len_l1: float = _segment_length(proc, 0, apex_min_x_idx2)
	var seg_len_l2: float = _segment_length(proc, apex_min_x_idx2, proc.size() - 1)
	var v1l: Vector2 = proc[apex_min_x_idx2] - proc[0]
	var v2l: Vector2 = proc[proc.size() - 1] - proc[apex_min_x_idx2]
	var cosang_left: float = 0.0
	if v1l.length() > 0.0 and v2l.length() > 0.0:
		cosang_left = v1l.normalized().dot(v2l.normalized())

	var mid_idx: int = proc.size() / 2
	var mid: Vector2 = proc[mid_idx]
	var chord_mid: Vector2 = (a + b) * 0.5
	var concavity_sign: float = sign(mid.y - chord_mid.y)  # Y down in screen coords

	var signed_area: float = _signed_area(proc)

	var tail: PackedVector2Array = _tail(proc, 12)
	var tail_bb: Rect2 = _bbox(tail)
	var tail_diag: float = max(0.001, tail_bb.size.length())
	var tail_closed: float = tail[0].distance_to(tail[tail.size() - 1]) / tail_diag
	var tail_chord: float = max(0.001, tail[0].distance_to(tail[tail.size() - 1]))
	var tail_len: float = _polyline_length(tail)
	var tail_loopiness: float = tail_len / tail_chord
	var tail_area_abs: float = abs(_signed_area(tail))
	var tail_corners: int = _corner_count(tail, 60.0)

	var tail_leg_frac_1: float = 0.0
	var tail_leg_frac_2: float = 0.0
	if tail.size() >= 4:
		var t_ai: int = _max_x_index(tail)
		var tL1: float = _segment_length(tail, 0, t_ai)
		var tL2: float = _segment_length(tail, t_ai, tail.size() - 1)
		var t_tot: float = max(0.001, tL1 + tL2)
		tail_leg_frac_1 = tL1 / t_tot
		tail_leg_frac_2 = tL2 / t_tot
		
		# --- NEW: a simple direction vector for the tail as a whole ---
	var tail_dx: float = 0.0
	var tail_dy: float = 0.0
	if tail.size() >= 2:
		var tdir: Vector2 = (tail[tail.size() - 1] - tail[0]).normalized()
		tail_dx = tdir.x
		tail_dy = tdir.y
		
	var tail_last_dx: float = 0.0
	var tail_last_dy: float = 0.0
	var tail_kink_deg: float = 0.0
	if tail.size() >= 3:
		var ci: int = _sharpest_corner_index(tail)
		ci = clamp(ci, 1, tail.size() - 2)
		var w: int = min(4, ci, (tail.size() - 1) - ci)

		var pre_dir: Vector2 = tail[ci] - tail[ci - w]
		var post_dir: Vector2 = tail[min(tail.size() - 1, ci + w)] - tail[ci]

		if post_dir.length() > 0.0:
			var npost := post_dir.normalized()
			tail_last_dx = npost.x
			tail_last_dy = npost.y
		if pre_dir.length() > 0.0 and post_dir.length() > 0.0:
			var cosv: float = clamp(pre_dir.normalized().dot(post_dir.normalized()), -1.0, 1.0)
			tail_kink_deg = rad_to_deg(acos(cosv))

	return {
		"proc": proc, "proc_raw": proc_raw,
		"a": a, "b": b, "dx": dx, "dy": dy, "abs_dx": abs_dx, "abs_dy": abs_dy,
		"straight": straight, "closed": closed, "corners60": corners60,
		"chord": chord, "path_len": path_len, "detour": detour, "slope": slope,
		"apex_max_x_idx": apex_max_x_idx, "apex_min_y_idx": apex_min_y_idx,
		"bb_aspect": bb_aspect,
		"ext_max_x": ext_max_x, "ext_min_x": ext_min_x,
		"ext_max_y": ext_max_y, "ext_min_y": ext_min_y,
		"seg_len_1": seg_len_1, "seg_len_2": seg_len_2, "cosang": cosang,
		"mid": mid, "chord_mid": chord_mid, "concavity_sign": concavity_sign,
		"signed_area": signed_area,
		"tail_closed": tail_closed, "tail_diag": tail_diag,
		"tail_loopiness": tail_loopiness, "tail_area_abs": tail_area_abs,
		"tail_corners": tail_corners,
		"tail_leg_frac_1": tail_leg_frac_1, "tail_leg_frac_2": tail_leg_frac_2,
		"tail_dx": tail_dx, "tail_dy": tail_dy, "tail_chord": tail_chord,
		"apex_min_x_idx": apex_min_x_idx2,
		"seg_len_l1": seg_len_l1, "seg_len_l2": seg_len_l2,
		"total_turn_deg": total_turn_deg,
		"radial_outward_frac": radial_outward_frac,
		"cosang_left": cosang_left,
		"tail_last_dx": tail_last_dx, "tail_last_dy": tail_last_dy, "tail_kink_deg": tail_kink_deg
	}

# Non-verbose gate just delegates
static func _gate(spec: Dictionary, f: Dictionary) -> bool:
	var dummy := PackedStringArray()
	return _gate_verbose(spec, f, dummy)

# Verbose gating — inline fail handling (no lambdas)
static func _gate_verbose(spec: Dictionary, f: Dictionary, failed: PackedStringArray) -> bool:
	# Direction / axis family
	if spec.has("dir"):
		var d: String = String(spec["dir"])
		var dx: float = float(f["dx"])
		var dy: float = float(f["dy"])
		match d:
			"h":
				var max_s: float = float(spec.get("horiz_slope_max", 0.40))
				if abs(dy) > abs(dx) * max_s:
					failed.append("dir:h"); return false
			"v":
				var max_s2: float = float(spec.get("vert_slope_max", 0.40))
				if abs(dx) > abs(dy) * max_s2:
					failed.append("dir:v"); return false
			"ne":
				if not (dx > 0.02 and dy < -0.02):
					failed.append("dir:ne"); return false
			_:
				pass

	# Signed vertical direction
	if spec.has("dy_sign"):
		var sgn: String = String(spec["dy_sign"])
		var dy2: float = float(f["dy"])
		if sgn == "up" and not (dy2 < -0.02):
			failed.append("dy_sign:up"); return false
		if sgn == "down" and not (dy2 > 0.02):
			failed.append("dy_sign:down"); return false

	# Straightness / detour / corners
	if spec.has("straight_max") and float(f["straight"]) > float(spec["straight_max"]):
		failed.append("straight_max"); return false
	if spec.has("detour_max") and float(f["detour"]) > float(spec["detour_max"]):
		failed.append("detour_max"); return false
	if spec.has("detour_min") and float(f["detour"]) < float(spec["detour_min"]):
		failed.append("detour_min"); return false

	# If a stronger shape gate is present, corners_min becomes redundant.
	var has_strong_shape_gate := bool(spec.get("check_mark", false)) \
		or bool(spec.get("right_angle", false)) \
		or bool(spec.get("chevron_apex_rightmost", false)) \
		or bool(spec.get("apex_high", false)) \
		or bool(spec.get("apex_low", false))
		
	var k_corners: int = int(f["corners60"])
	if spec.has("corners_thresh_deg"):
		var proc_raw2: PackedVector2Array = f["proc_raw"]
		k_corners = _corner_count(proc_raw2, float(spec["corners_thresh_deg"]))

	if spec.has("corners_max") and k_corners > int(spec["corners_max"]):
		failed.append("corners_max"); return false

	if spec.has("corners_min") and not has_strong_shape_gate and k_corners < int(spec["corners_min"]):
		failed.append("corners_min"); return false

	if spec.has("corners_range"):
		var r: Vector2i = spec["corners_range"]
		var k: int = k_corners
		if k < r.x or k > r.y:
			failed.append("corners_range"); return false

	# Closure
	if spec.has("closed_max") and float(f["closed"]) > float(spec["closed_max"]):
		failed.append("closed_max"); return false
	if spec.has("closed_min") and float(f["closed"]) < float(spec["closed_min"]):
		failed.append("closed_min"); return false

	# Not-a-line minimum curvature
	if spec.has("not_line_min") and float(f["straight"]) < float(spec["not_line_min"]):
		failed.append("not_line_min"); return false

	# Slope range
	if spec.has("slope_range"):
		var rr: Vector2 = spec["slope_range"]
		var s: float = float(f["slope"])
		if s < rr.x or s > rr.y:
			failed.append("slope_range"); return false

	# Carets
	if bool(spec.get("apex_high", false)):
		var proc: PackedVector2Array = f["proc"]
		var ai: int = int(f["apex_min_y_idx"])
		var apex: Vector2 = proc[ai]
		var a: Vector2 = f["a"]
		var b: Vector2 = f["b"]
		if not (apex.y <= min(a.y, b.y) - 0.05):
			failed.append("apex_high"); return false

	if bool(spec.get("apex_low", false)):
		var proc2: PackedVector2Array = f["proc"]
		var max_y_idx: int = _max_y_index(proc2)
		var apex2: Vector2 = proc2[max_y_idx]
		var a2: Vector2 = f["a"]
		var b2: Vector2 = f["b"]
		if not (apex2.y >= max(a2.y, b2.y) + 0.05):
			failed.append("apex_low"); return false

	# Chevron
	if bool(spec.get("chevron_apex_rightmost", false)):
		var proc3: PackedVector2Array = f["proc"]
		var ac: int = int(f["apex_max_x_idx"])
		var p0: Vector2 = proc3[0]
		var pc: Vector2 = proc3[ac]
		var pe: Vector2 = proc3[proc3.size() - 1]
		if pc.x <= max(p0.x, pe.x) + 0.01:
			failed.append("chev:rightmost"); return false
		if pc.x <= p0.x + 0.015:
			failed.append("chev:leg1_dir"); return false
		if pe.x >= pc.x - 0.0075:
			failed.append("chev:leg2_dir"); return false
		var L1: float = float(f["seg_len_1"])
		var L2: float = float(f["seg_len_2"])
		var Ltot: float = L1 + L2
		var min_frac: float = float(spec.get("chevron_leg_min_ratio", 0.20))
		if L1 < Ltot * min_frac or L2 < Ltot * min_frac:
			failed.append("chev:leg_min"); return false
		var cosang: float = float(f["cosang"])
		var rr2: Vector2 = spec.get("chevron_cos_range", Vector2(-0.90, 0.90))
		if cosang < rr2.x or cosang > rr2.y:
			failed.append("chev:cos_range"); return false
			
		# Chevron (left-facing)
	if bool(spec.get("chevron_apex_leftmost", false)):
		var procL: PackedVector2Array = f["proc"]
		var acL: int = int(f["apex_min_x_idx"])
		var p0L: Vector2 = procL[0]
		var pcL: Vector2 = procL[acL]
		var peL: Vector2 = procL[procL.size() - 1]

		# apex must be the leftmost point
		if pcL.x >= min(p0L.x, peL.x) - 0.01:
			failed.append("chev:leftmost"); return false
		# leg1 must move left, leg2 must move right
		if pcL.x >= p0L.x - 0.015:
			failed.append("chev:leg1_dir"); return false
		if peL.x <= pcL.x + 0.0075:
			failed.append("chev:leg2_dir"); return false

		var L1L: float = float(f["seg_len_l1"])
		var L2L: float = float(f["seg_len_l2"])
		var LtotL: float = L1L + L2L
		var min_fracL: float = float(spec.get("chevron_leg_min_ratio", 0.20))
		if L1L < LtotL * min_fracL or L2L < LtotL * min_fracL:
			failed.append("chev:leg_min"); return false

		var cosangL: float = float(f["cosang_left"])
		var rrL: Vector2 = spec.get("chevron_cos_range", Vector2(-0.90, 0.90))
		if cosangL < rrL.x or cosangL > rrL.y:
			failed.append("chev:cos_range"); return false


	# Check mark family (supports modes)
	if bool(spec.get("check_mark", false)):
		var proc4: PackedVector2Array = f["proc"]
		var ci: int = _sharpest_corner_index(proc4)
		var p0b: Vector2 = proc4[0]
		var pcb: Vector2 = proc4[ci]
		var peb: Vector2 = proc4[proc4.size() - 1]
		var a1v: Vector2 = pcb - p0b
		var a2v: Vector2 = peb - pcb

		var mode: String = String(spec.get("check_mode", "normal"))
		var dir_ok: bool = false
		match mode:
			"normal":    # short down-right, long up-right (✓)
				dir_ok = (a1v.x > 0.0 and a1v.y > 0.0 and a2v.x > 0.0 and a2v.y < 0.0)
			"rot180":    # short up-left, long down-left
				dir_ok = (a1v.x < 0.0 and a1v.y < 0.0 and a2v.x < 0.0 and a2v.y > 0.0)
			"rightward": # long up-right, short down-right  ← Skewer
				dir_ok = (a1v.x > 0.0 and a1v.y < 0.0 and a2v.x > 0.0 and a2v.y > 0.0)
			"leftward":  # long down-left, short up-left
				dir_ok = (a1v.x < 0.0 and a1v.y > 0.0 and a2v.x < 0.0 and a2v.y < 0.0)
			_:
				dir_ok = (a1v.x > 0.0 and a1v.y > 0.0 and a2v.x > 0.0 and a2v.y < 0.0)

		if not dir_ok:
			failed.append("check:quadrants"); return false

		var L1b: float = _segment_length(proc4, 0, ci)
		var L2b: float = _segment_length(proc4, ci, proc4.size() - 1)

		# Length relationship per mode
		if mode == "rightward" or mode == "leftward":
			var rmin_first: float = float(spec.get("check_first_longer_min", 1.15))
			if L1b < L2b * rmin_first:
				failed.append("check:first_longer_ratio"); return false
		else:
			var rmin_second: float = float(spec.get("check_ratio_min", 1.15))
			if L2b < L1b * rmin_second:
				failed.append("check:length_ratio"); return false

		# Still require not-perfectly-straight
		if float(f["straight"]) < float(spec.get("not_perfect_line_min", 0.02)):
			failed.append("check:not_perfect_line"); return false

	# Right angle (≈90° turn; default order: down then right)
	if bool(spec.get("right_angle", false)):
		var pts: PackedVector2Array = f["proc"]
		var ci: int = _sharpest_corner_index(pts)

		# Use a window of samples to estimate each leg's direction
		var w: int = int(spec.get("corner_window_samples", 8))
		var i0: int = max(0, ci - w)
		var i1: int = min(pts.size() - 1, ci + w)

		var pre_dir: Vector2 = (pts[ci] - pts[i0])
		var post_dir: Vector2 = (pts[i1] - pts[ci])

		if pre_dir.length() == 0.0 or post_dir.length() == 0.0:
			failed.append("right_angle:zero_seg"); return false

		pre_dir = pre_dir.normalized()
		post_dir = post_dir.normalized()

		# Angle between averaged leg directions
		var cosv: float = clamp(pre_dir.dot(post_dir), -1.0, 1.0)
		var ang: float = rad_to_deg(acos(cosv))

		var tol: float = float(spec.get("angle_tolerance_deg", 40.0)) # slightly looser default
		if abs(ang - 90.0) > tol:
			failed.append("right_angle:angle"); return false

		# Direction order: default down_then_right; switch with right_angle_order="right_down"
		var order: String = String(spec.get("right_angle_order", "down_right"))
		match order:
			"right_down":
				if not (pre_dir.x > 0.0 and post_dir.y > 0.0):
					failed.append("right_angle:order"); return false
			_:
				if not (pre_dir.y > 0.0 and post_dir.x > 0.0):
					failed.append("right_angle:order"); return false

		# Optional: ensure both legs have non-trivial length fractions of the whole stroke
		if spec.has("right_angle_min_leg_frac"):
			var Ltot: float = _polyline_length(pts)
			var Lpre: float = _segment_length(pts, i0, ci)
			var Lpost: float = _segment_length(pts, ci, i1)
			var min_frac: float = float(spec["right_angle_min_leg_frac"])
			if Lpre < Ltot * min_frac or Lpost < Ltot * min_frac:
				failed.append("right_angle:leg_frac"); return false

		# Tail constraints
		if spec.has("tail_samples"):
			if float(f.get("tail_closed", 0.0)) > float(spec.get("tail_closed_max", 1.0)):
				failed.append("tail:closed_max"); return false
			if float(f.get("tail_diag", 0.0)) > float(spec.get("tail_diag_max", 1.0)):
				failed.append("tail:diag_max"); return false
			if spec.has("tail_diag_min") and float(f.get("tail_diag", 0.0)) < float(spec["tail_diag_min"]):
				failed.append("tail:diag_min"); return false

			if float(f.get("tail_loopiness", 0.0)) < float(spec.get("tail_loopiness_min", 0.0)):
				failed.append("tail:loopiness_min"); return false
			if spec.has("tail_loopiness_max") and float(f.get("tail_loopiness", 0.0)) > float(spec["tail_loopiness_max"]):
				failed.append("tail:loopiness_max"); return false

			if float(f.get("tail_area_abs", 0.0)) < float(spec.get("tail_area_abs_min", 0.0)):
				failed.append("tail:area_abs_min"); return false
			if bool(spec.get("tail_apex_rightmost", false)):
				var proc6: PackedVector2Array = f["proc"]
				var ai3: int = _max_x_index(proc6)
				if ai3 < proc6.size() - 3:
					failed.append("tail:apex_not_tail"); return false
			if bool(spec.get("tail_two_legs_right", false)):
				var r2: Vector2 = spec.get("tail_leg_frac_range", Vector2(0.05, 0.25))
				var r1f: float = float(f.get("tail_leg_frac_1", 0.0))
				var r2f: float = float(f.get("tail_leg_frac_2", 0.0))
				if r1f < r2.x or r2f < r2.x or r1f > r2.y or r2f > r2.y:
					failed.append("tail:leg_frac_range"); return false
			if spec.has("tail_corners_range"):
				var rr3: Vector2i = spec["tail_corners_range"]
				var tc: int = int(f.get("tail_corners", 0))
				if tc < rr3.x or tc > rr3.y:
					failed.append("tail:corners_range"); return false

			# NEW: require a visible kink at the tip
			if spec.has("tail_kink_min_deg") and float(f.get("tail_kink_deg", 0.0)) < float(spec["tail_kink_min_deg"]):
				failed.append("tail:kink_min"); return false

			# NEW: slash direction uses the LAST LEG of the tail
			if spec.has("tail_slash_dir"):
				var want: String = String(spec["tail_slash_dir"])
				var tdx: float = float(f.get("tail_last_dx", f.get("tail_dx", 0.0)))
				var tdy: float = float(f.get("tail_last_dy", f.get("tail_dy", 0.0)))
				var ok_dir: bool = false
				match want:
					"up_left":
						ok_dir = (tdx < -0.01 and tdy < -0.01)
					"up_right":
						ok_dir = (tdx > 0.01 and tdy < -0.01)
					"down_right":
						ok_dir = (tdx > 0.01 and tdy > 0.01)
					"down_left":
						ok_dir = (tdx < -0.01 and tdy > 0.01)
					_:
						ok_dir = true
				if not ok_dir:
					failed.append("tail:slash_dir"); return false
					
						# If a right-hook is requested: require a visible kink and final tail heading to the right
			# NOTE: shadow_grasp uses { hook_right: true, hook_tail_ratio_min: 0.15 }
			if bool(spec.get("hook_right", false)):
				var kink := float(f.get("tail_kink_deg", 0.0))
				var last_dx := float(f.get("tail_last_dx", f.get("tail_dx", 0.0)))
				if kink < 25.0:
					failed.append("hook:kink_too_small"); return false
				if last_dx <= 0.02:
					failed.append("hook:not_rightward"); return false
				if spec.has("hook_tail_ratio_min"):
					# use the second leg fraction as a proxy for a visible tail
					var tail_frac2 := float(f.get("tail_leg_frac_2", 0.0))
					if tail_frac2 < float(spec["hook_tail_ratio_min"]):
						failed.append("hook:tail_too_short"); return false




	# Concavity
	if spec.has("concavity"):
		var conc: String = String(spec["concavity"])
		var sign_needed: float = -1.0 if conc == "down" else 1.0
		var sgn: float = float(f["concavity_sign"])
		if sign(sgn) != sign(sign_needed):
			failed.append("concavity"); return false

	# Arc direction
	if spec.has("arc_direction"):
		var want: String = String(spec["arc_direction"])
		var area: float = float(f["signed_area"])
		var cw_ok: bool = (area < 0.0)
		var ccw_ok: bool = (area > 0.0)
		if (want == "cw" and not cw_ok) or (want == "ccw" and not ccw_ok):
			failed.append("arc_direction"); return false

	# Net dir bias
	if spec.has("net_dir"):
		var nd: String = String(spec["net_dir"])
		if nd == "right" and not (float(f["dx"]) > 0.05):
			failed.append("net_dir:right"); return false

	# Minimum normalized horizontal travel
	if spec.has("dx_min_norm"):
		if abs(float(f["dx"])) < float(spec["dx_min_norm"]):
			failed.append("dx_min_norm"); return false

	# Alternating turns
	if bool(spec.get("alternate_turns", false)):
		var proc7: PackedVector2Array = f["proc"]
		if not _has_alternating_turns(proc7, 60.0):
			failed.append("alternate_turns"); return false
			
	# BBox aspect range (for diamond-ish / square-ish shapes)
	if spec.has("bbox_aspect_range"):
		var r_aspect: Vector2 = Vector2(0.70, 1.35)
		var v_any: Variant = spec["bbox_aspect_range"]
		if v_any is Vector2:
			r_aspect = v_any
		elif v_any is Array and (v_any as Array).size() >= 2:
			var arr := v_any as Array
			r_aspect = Vector2(float(arr[0]), float(arr[1]))
		var asp: float = float(f.get("bb_aspect", 1.0))
		if asp < r_aspect.x or asp > r_aspect.y:
			failed.append("bbox_aspect_range"); return false

	# Require four extrema well-separated along stroke order
	if bool(spec.get("require_four_extrema", false)):
		var n: int = (f["proc"] as PackedVector2Array).size()
		var min_sep_frac: float = float(spec.get("extrema_min_separation_frac", 0.10))
		var min_sep: int = int(round(min_sep_frac * float(n)))

		# Read indices
		var ix: Array[int] = [
			int(f["ext_max_x"]), int(f["ext_min_x"]),
			int(f["ext_max_y"]), int(f["ext_min_y"])
		]

		# All distinct?
		var seen: Dictionary = {}
		for v in ix:
			seen[v] = true
		if seen.size() < 4:
			failed.append("extrema:distinct"); return false

		# Pairwise circular separation on [0, n)
		for i in range(ix.size()):
			for j in range(i + 1, ix.size()):
				if _circular_index_distance(ix[i], ix[j], n) < min_sep:
					failed.append("extrema:separation"); return false

	# Axis aligned bias
	if bool(spec.get("axis_aligned_bias", false)):
		var proc8: PackedVector2Array = f["proc"]
		if not _axis_aligned_bias_ok(proc8):
			failed.append("axis_aligned_bias"); return false
			
	# Spiral-ish turning (CCW or CW)
	if spec.has("total_turn_ccw_min_deg"):
		if float(f.get("total_turn_deg", 0.0)) < float(spec["total_turn_ccw_min_deg"]):
			failed.append("turn:ccw_min"); return false
	if spec.has("total_turn_cw_min_deg"):
		if float(f.get("total_turn_deg", 0.0)) > -float(spec["total_turn_cw_min_deg"]):
			failed.append("turn:cw_min"); return false

	# Outward growth from start (spiral expands)
	if spec.has("radial_outward_min_frac"):
		if float(f.get("radial_outward_frac", 0.0)) < float(spec["radial_outward_min_frac"]):
			failed.append("radial_outward"); return false


	return true

static func _circular_index_distance(a: int, b: int, modulo_n: int) -> int:
	var d: int = abs(a - b)
	return min(d, modulo_n - d)
# ------------------------------------------------------------
# Distance & preprocessing
# ------------------------------------------------------------
static func _avg_dist(a: PackedVector2Array, b: PackedVector2Array) -> float:
	var n: int = min(a.size(), b.size())
	if n == 0:
		return 1e30
	var s: float = 0.0
	for i in range(n):
		s += a[i].distance_to(b[i])
	return s / float(n)

static func _smooth(raw: Array[Vector2], passes: int) -> Array[Vector2]:
	var pts: Array[Vector2] = raw.duplicate()
	for _i in range(max(0, passes)):
		if pts.size() <= 2:
			return pts
		var out: Array[Vector2] = []
		out.append(pts[0])
		for j in range(1, pts.size() - 1):
			var v: Vector2 = (pts[j - 1] + pts[j] + pts[j + 1]) / 3.0
			out.append(v)
		out.append(pts[pts.size() - 1])
		pts = out
	return pts

static func _bbox(points: PackedVector2Array) -> Rect2:
	var min_v: Vector2 = points[0]
	var max_v: Vector2 = points[0]
	for p in points:
		min_v.x = min(min_v.x, p.x); min_v.y = min(min_v.y, p.y)
		max_v.x = max(max_v.x, p.x); max_v.y = max(max_v.y, p.y)
	return Rect2(min_v, max_v - min_v)

static func _path_len_local(points: Array[Vector2]) -> float:
	var total: float = 0.0
	for i in range(1, points.size()):
		total += points[i - 1].distance_to(points[i])
	return total

static func _resample_local(points: Array[Vector2], n: int) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	if points.size() == 0:
		return out
	if n <= 1:
		out.push_back(points[0]); return out

	var D: float = _path_len_local(points) / float(n - 1)
	var dist_accum: float = 0.0
	var a: Vector2 = points[0]
	out.push_back(a)
	var i: int = 1
	while i < points.size():
		var b: Vector2 = points[i]
		var d: float = a.distance_to(b)
		if (dist_accum + d) >= D and d > 0.0:
			var t: float = (D - dist_accum) / d
			var q: Vector2 = a.lerp(b, t)
			out.push_back(q)
			a = q
			dist_accum = 0.0
		else:
			dist_accum += d
			a = b
			i += 1

	while out.size() < n: out.push_back(points[points.size() - 1])
	if out.size() > n: out.resize(n)
	return out

static func _normalize_local(points: PackedVector2Array) -> PackedVector2Array:
	if points.is_empty():
		return PackedVector2Array()
	var bb: Rect2 = _bbox(points)
	var center: Vector2 = bb.position + bb.size * 0.5
	var diag: float = max(0.001, bb.size.length())
	var out: PackedVector2Array = PackedVector2Array()
	out.resize(points.size())
	for i in range(points.size()):
		out[i] = (points[i] - center) / diag
	return out

# ------------------------------------------------------------
# Shape metrics / helpers
# ------------------------------------------------------------
static func _straightness_ratio(points: PackedVector2Array) -> float:
	if points.size() < 2:
		return 0.0
	var a: Vector2 = points[0]
	var b: Vector2 = points[points.size() - 1]
	var seg_len: float = max(0.001, a.distance_to(b))
	var sum: float = 0.0
	for p in points:
		sum += _dist_to_segment(p, a, b)
	return (sum / float(points.size())) / seg_len

static func _dist_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var t: float = 0.0
	var d: float = ab.length_squared()
	if d > 0.0:
		t = clamp((p - a).dot(ab) / d, 0.0, 1.0)
	var proj: Vector2 = a + ab * t
	return p.distance_to(proj)

static func _closure_ratio(points: PackedVector2Array) -> float:
	if points.size() < 2:
		return 1.0
	return points[0].distance_to(points[points.size() - 1]) / max(0.001, _bbox(points).size.length())

static func _corner_count(points: PackedVector2Array, thresh_deg: float) -> int:
	if points.size() < 5:
		return 0
	var cnt: int = 0
	var prev: Vector2 = points[1] - points[0]
	var tcos: float = cos(deg_to_rad(max(5.0, thresh_deg)))
	for i in range(2, points.size()):
		var cur: Vector2 = points[i] - points[i - 1]
		if prev.length() > 0.0 and cur.length() > 0.0:
			var c: float = prev.normalized().dot(cur.normalized())
			if c <= tcos:
				cnt += 1
		prev = cur
	return cnt

static func _min_y_index(points: PackedVector2Array) -> int:
	var idx: int = 0
	var min_y: float = points[0].y
	for i in range(1, points.size()):
		if points[i].y < min_y:
			min_y = points[i].y
			idx = i
	return idx

static func _max_y_index(points: PackedVector2Array) -> int:
	var idx: int = 0
	var max_y: float = points[0].y
	for i in range(1, points.size()):
		if points[i].y > max_y:
			max_y = points[i].y
			idx = i
	return idx

static func _max_x_index(points: PackedVector2Array) -> int:
	var idx: int = 0
	var mx: float = points[0].x
	for i in range(1, points.size()):
		if points[i].x > mx:
			mx = points[i].x
			idx = i
	return idx

static func _segment_length(points: PackedVector2Array, i0: int, i1: int) -> float:
	var a: int = min(i0, i1)
	var b: int = max(i0, i1)
	var L: float = 0.0
	for i in range(a + 1, b + 1):
		L += points[i - 1].distance_to(points[i])
	return L

static func _sharpest_corner_index(points: PackedVector2Array) -> int:
	var best_i: int = 1
	var best_cos: float = 1.0
	var prev: Vector2 = points[1] - points[0]
	for i in range(2, points.size()):
		var cur: Vector2 = points[i] - points[i - 1]
		if prev.length() > 0.0 and cur.length() > 0.0:
			var c: float = prev.normalized().dot(cur.normalized())
			if c < best_cos:
				best_cos = c
				best_i = i - 1
		prev = cur
	return best_i

static func _polyline_length(points: PackedVector2Array) -> float:
	var L: float = 0.0
	for i in range(1, points.size()):
		L += points[i - 1].distance_to(points[i])
	return L

static func _tail(points: PackedVector2Array, count: int) -> PackedVector2Array:
	var n: int = points.size()
	var c: int = clamp(count, 2, n)
	var out := PackedVector2Array()
	out.resize(c)
	var start: int = n - c
	var idx: int = 0
	for i in range(start, n):
		out[idx] = points[i]
		idx += 1
	return out

static func _signed_area(points: PackedVector2Array) -> float:
	var n: int = points.size()
	if n < 3:
		return 0.0
	var s: float = 0.0
	var j: int = n - 1
	for i in range(n):
		var pi: Vector2 = points[i]
		var pj: Vector2 = points[j]
		s += (pj.x + pi.x) * (pj.y - pi.y)
		j = i
	return s * 0.5

static func _has_alternating_turns(points: PackedVector2Array, thresh_deg: float) -> bool:
	if points.size() < 5:
		return false
	var tcos: float = cos(deg_to_rad(max(5.0, thresh_deg)))
	var prev: Vector2 = points[1] - points[0]
	var last_sign: int = 0
	var flips: int = 0
	for i in range(2, points.size()):
		var cur: Vector2 = points[i] - points[i - 1]
		if prev.length() == 0.0 or cur.length() == 0.0:
			prev = cur
			continue
		var c: float = prev.normalized().dot(cur.normalized())
		if c <= tcos:
			var z: float = prev.x * cur.y - prev.y * cur.x
			var sgn: int = 1 if z > 0.0 else -1
			if last_sign != 0 and sgn == last_sign:
				return false
			last_sign = sgn
			flips += 1
		prev = cur
	return flips >= 2

static func _axis_aligned_bias_ok(points: PackedVector2Array) -> bool:
	if points.size() < 4:
		return false
	var good: int = 0
	var total: int = 0
	for i in range(1, points.size()):
		var v: Vector2 = points[i] - points[i - 1]
		if v.length() == 0.0:
			continue
		total += 1
		var ang: float = abs(rad_to_deg(atan2(v.y, v.x)))
		ang = fmod(ang, 90.0)
		var delta: float = min(ang, 90.0 - ang)
		if delta <= 15.0:
			good += 1
	return total > 0 and float(good) / float(total) >= 0.7

static func _min_x_index(points: PackedVector2Array) -> int:
	var idx: int = 0
	var mn: float = points[0].x
	for i in range(1, points.size()):
		if points[i].x < mn:
			mn = points[i].x
			idx = i
	return idx

static func _total_signed_turn_deg(points: PackedVector2Array) -> float:
	if points.size() < 3: return 0.0
	var sum := 0.0
	var prev: Vector2 = points[1] - points[0]
	for i in range(2, points.size()):
		var cur: Vector2 = points[i] - points[i - 1]
		if prev.length() == 0.0 or cur.length() == 0.0:
			prev = cur
			continue
		# atan2( cross, dot ) = signed turn
		var ang := atan2(prev.x * cur.y - prev.y * cur.x, prev.dot(cur))
		sum += rad_to_deg(ang)
		prev = cur
	return sum

static func _radial_outward_frac(points: PackedVector2Array) -> float:
	if points.size() < 2: return 0.0
	var origin: Vector2 = points[0]
	var inc := 0
	var total := 0
	var last_d := origin.distance_to(points[0])
	for i in range(1, points.size()):
		var d := origin.distance_to(points[i])
		if d > last_d: inc += 1
		total += 1
		last_d = d
	return float(inc) / float(max(1, total))

static func reset_for_dev() -> void:
	_initialized = false

static func debug_dump(points: Array[Vector2], top_n: int = 6) -> void:
	if points.size() < MIN_INPUT_POINTS:
		print_rich("[GR/debug] too few points: ", points.size())
		return
	if not _initialized:
		ensure_initialized()

	var norm: PackedVector2Array = _normalize_local(
		_resample_local(_smooth(points, 1), RESAMPLE_COUNT)
	)

	var rows: Array[Dictionary] = []
	for i in range(_template_ids.size()):
		var tid: StringName = _template_ids[i]
		var tpts: PackedVector2Array = _template_pts[i]
		var d: float = _avg_dist(norm, tpts)
		var gates: Dictionary = passes_symbol_filters_verbose(tid, points)
		rows.append({
			"id": String(tid),
			"d": d,
			"ok": bool(gates["ok"]),
			"failed": gates.get("failed", PackedStringArray())
		})

	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["d"]) < float(b["d"])
	)

	var n: int = int(min(top_n, rows.size()))
	print_rich("[GR/debug] top ", n, " candidates:")
	for i in range(n):
		var r: Dictionary = rows[i]
		var d_i: float = float(r["d"])
		var conf: float = clampf(1.0 / (1.0 + d_i * 6.0), 0.0, 1.0)
		var ok: bool = bool(r["ok"])
		var failed: Variant = r.get("failed", PackedStringArray())
		print_rich(
			"  #", i,
			"  id=", String(r["id"]),
			"  d=", "%.4f" % d_i,
			"  conf≈", "%.0f%%" % (conf * 100.0),
			"  gates=", ( "OK" if ok else "NO"),
			( "" if ok else (" fail=" + str(failed)) )
		)
