# GestureRecognizer.gd — Rune-lite unistroke matcher
# IDs returned: "slash", "block", "heal", "fireball"
class_name GestureRecognizer
extends RefCounted

# --- Config -----------------------------------------------------------------
const RESAMPLE_COUNT: int = 64
const MIN_INPUT_POINTS: int = 8

# --- Internal template storage ---------------------------------------------
static var _initialized: bool = false
static var _template_ids: Array[StringName] = []
# Note: top-level Array must remain untyped to avoid "nested typed collections".
static var _template_pts: Array[PackedVector2Array] = [] 

# --- Public API -------------------------------------------------------------
static func ensure_initialized() -> void:
	if _initialized:
		return
	_initialized = true
	_template_ids.clear()
	_template_pts.clear()
	_init_default_templates()

static func recognize(points: Array[Vector2]) -> Dictionary:
	# Returns { "id": StringName, "confidence": float }
	var result_id: StringName = StringName("")
	var conf: float = 0.0

	if points.size() < MIN_INPUT_POINTS or _template_ids.is_empty():
		return { "id": result_id, "confidence": conf }

	# preprocess
	var pts: Array[Vector2] = _smooth(points, 1)
	var norm: PackedVector2Array = _normalize_local(_resample_local(pts, RESAMPLE_COUNT))

	var best_id: StringName = StringName("")
	var best_d: float = 1e30

	for i in range(_template_ids.size()):
		var tid: StringName = _template_ids[i]
		var tpts: PackedVector2Array = _template_pts[i]
		var d: float = _avg_dist(norm, tpts)
		if d < best_d:
			best_d = d
			best_id = tid

	# Distance → confidence (norm space): 0.0 (far) .. 1.0 (same)
	# Typical good matches ~0.15–0.35; map with a soft knee.
	var c: float = clamp(1.0 / (1.0 + best_d * 6.0), 0.0, 1.0)

	return { "id": best_id, "confidence": c }

# Gate raw points for plausibility of the recognized id
static func passes_symbol_filters(result_id: StringName, raw_points: Array[Vector2]) -> bool:
	if raw_points.size() < MIN_INPUT_POINTS:
		return false

	# Smoothed for general metrics
	var proc: PackedVector2Array = _normalize_local(_resample_local(_smooth(raw_points, 1), 64))
	# Raw for jagged detection
	var proc_raw: PackedVector2Array = _normalize_local(_resample_local(raw_points, 64))

	var straight: float = _straightness_ratio(proc)
	var closed: float = _closure_ratio(proc)
	var corners60: int = _corner_count(proc_raw, 60.0)

	var a: Vector2 = proc[0]
	var b: Vector2 = proc[proc.size() - 1]
	var dx: float = abs(b.x - a.x)
	var dy: float = abs(b.y - a.y)

	# Detour: 1.0 = perfectly straight
	var chord: float = max(0.001, a.distance_to(b))
	var path_len: float = _polyline_length(proc_raw)
	var detour: float = path_len / chord

	match result_id:
		&"slash":
			# Must be truly straight & horizontal-ish
			return (straight <= 0.08) and (dy <= dx * 0.40) and (corners60 == 0) and (detour <= 1.04)

		&"block":
			# Must be truly straight & vertical-ish
			return (straight <= 0.08) and (dx <= dy * 0.40) and (corners60 == 0) and (detour <= 1.04)

		&"heal":
			# Caret (∧): apex above both ends, not closed, has 1+ sharp turn
			if closed <= 0.18: return false
			if corners60 < 1: return false
			var apex_idx: int = _min_y_index(proc)
			var apex: Vector2 = proc[apex_idx]
			return apex.y <= min(a.y, b.y) - 0.05

		&"fireball":
			# Triangle-ish: near-closed and cornered; not a line
			var near_closed: bool = (closed <= 0.30)
			var k: int = _corner_count(proc_raw, 60.0)
			var has_corners: bool = (k >= 2 and k <= 6)
			var not_line: bool = (straight >= 0.04)
			return near_closed and has_corners and not_line

		&"aimed":
			# Chevron (>):
			# - not closed
			# - at least one sharp turn
			# - apex is the rightmost sample
			# - first leg goes right, second leg goes left
			# - both legs have non-trivial length
			if closed <= 0.18:
				return false
			if _corner_count(proc_raw, 70.0) < 1:
				return false

			var ai: int = _max_x_index(proc)        # robust apex
			var p0: Vector2 = proc[0]
			var pc: Vector2 = proc[ai]
			var pe: Vector2 = proc[proc.size() - 1]

			# apex clearly to the right of both ends (slightly relaxed)
			if pc.x <= max(p0.x, pe.x) + 0.01:
				return false

			# legs: first moves right, second moves left (tolerant)
			if pc.x <= p0.x + 0.015:
				return false
			if pe.x >= pc.x - 0.0075:
				return false

			var L1: float = _segment_length(proc, 0, ai)
			var L2: float = _segment_length(proc, ai, proc.size() - 1)
			var Ltot: float = L1 + L2
			# accept wider chevrons
			if L1 < Ltot * 0.20 or L2 < Ltot * 0.20:
				return false

			# interior angle: allow shallow chevrons but reject near-straight lines
			var v1: Vector2 = pc - p0
			var v2: Vector2 = pe - pc
			var cosang: float = v1.normalized().dot(v2.normalized())  # -1..+1
			# widen to ~25°–155° (cos ~ 0.90 .. -0.90)
			return cosang <= 0.90 and cosang >= -0.90

		&"riposte":
			# Checkmark (✓): down-right tick, longer up-right stroke
			if closed <= 0.18: return false
			if _corner_count(proc_raw, 70.0) < 1: return false

			var ci2: int = _sharpest_corner_index(proc)
			var p0b: Vector2 = proc[0]
			var pcb: Vector2 = proc[ci2]
			var peb: Vector2 = proc[proc.size() - 1]
			var a1: Vector2 = pcb - p0b
			var a2: Vector2 = peb - pcb

			if not (a1.x > 0.0 and a1.y > 0.0 and a2.x > 0.0 and a2.y < 0.0): return false
			var L1b: float = _segment_length(proc, 0, ci2)
			var L2b: float = _segment_length(proc, ci2, proc.size() - 1)
			if L2b < L1b * 1.15: return false

			return _straightness_ratio(proc) >= 0.02
			
		

		_:
			return true




# --- Template construction ---------------------------------------------------
static func _init_default_templates() -> void:
	_template_ids.clear()
	_template_pts.clear()

	# Slash — (L→R and R→L)
	_add_template(&"slash", [Vector2(10, 100), Vector2(190, 100)])
	_add_template(&"slash", [Vector2(190, 100), Vector2(10, 100)])

	# Block | (T→B and B→T)
	_add_template(&"block", [Vector2(100, 10), Vector2(100, 190)])
	_add_template(&"block", [Vector2(100, 190), Vector2(100, 10)])

	# Heal ∧ (two variants: narrow / wide)
	_add_template(&"heal", [Vector2(40, 160), Vector2(100, 40), Vector2(160, 160)])
	_add_template(&"heal", [Vector2(30, 165), Vector2(100, 35), Vector2(170, 165)])

	# Fire ▲ (CW and CCW)
	var tri1: Array[Vector2] = [Vector2(60, 160), Vector2(140, 160), Vector2(100, 60), Vector2(60, 160)]
	var tri2: Array[Vector2] = [Vector2(60, 160), Vector2(100, 60), Vector2(140, 160), Vector2(60, 160)]
	_add_template(&"fireball", tri1)
	_add_template(&"fireball", tri2)

	# Aimed > (true right-pointing chevrons; apex is rightmost)
	# Variant A (medium)
	_add_template(&"aimed", [Vector2(50,  90), Vector2(160, 100), Vector2(50, 130)])
	# Variant B (slightly taller)
	_add_template(&"aimed", [Vector2(55,  85), Vector2(165, 100), Vector2(55, 135)])

	# Riposte ✓ (short down-right then long up-right)
	_add_template(&"riposte", [Vector2(70, 115), Vector2( 92, 135), Vector2(150,  70)])
	_add_template(&"riposte", [Vector2(70, 120), Vector2( 96, 142), Vector2(155,  75)])


static func _add_template(id: StringName, pts_in: Array[Vector2]) -> void:
	var res: PackedVector2Array = _normalize_local(_resample_local(pts_in, RESAMPLE_COUNT))
	_template_ids.append(id)
	_template_pts.append(res)

# --- Distance & preprocessing -----------------------------------------------
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
		out.push_back(points[0])
		return out

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

	while out.size() < n:
		out.push_back(points[points.size() - 1])
	if out.size() > n:
		out.resize(n)
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
		out[i] = (points[i] - center) / diag  # roughly within [-0.5..0.5]
	return out

# --- Shape metrics used by gates --------------------------------------------
static func _straightness_ratio(points: PackedVector2Array) -> float:
	if points.size() < 2:
		return 0.0
	var a: Vector2 = points[0]
	var b: Vector2 = points[points.size() - 1]
	var seg_len: float = max(0.001, a.distance_to(b))
	var sum: float = 0.0
	# distance to end-to-end segment
	for p in points:
		var sum_d: float = _dist_to_segment(p, a, b)
		sum += sum_d
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
	var bb: Rect2 = _bbox(points)
	var diag: float = max(0.001, bb.size.length())
	return points[0].distance_to(points[points.size() - 1]) / diag

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

# Path length between two sample indices (inclusive)
static func _segment_length(points: PackedVector2Array, i0: int, i1: int) -> float:
	var a: int = min(i0, i1)
	var b: int = max(i0, i1)
	var L: float = 0.0
	for i in range(a + 1, b + 1):
		L += points[i - 1].distance_to(points[i])
	return L
	
# Pick the sharpest turn along the stroke (index of the corner sample)
static func _sharpest_corner_index(points: PackedVector2Array) -> int:
	var best_i: int = 1
	var best_cos: float = 1.0
	var prev: Vector2 = points[1] - points[0]
	for i in range(2, points.size()):
		var cur: Vector2 = points[i] - points[i - 1]
		if prev.length() > 0.0 and cur.length() > 0.0:
			var c: float = prev.normalized().dot(cur.normalized()) # -1..+1
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

static func _max_x_index(points: PackedVector2Array) -> int:
	var idx: int = 0
	var mx: float = points[0].x
	for i in range(1, points.size()):
		if points[i].x > mx:
			mx = points[i].x
			idx = i
	return idx

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
	# Shoelace over a polyline (treat as closed by last->first).
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
