extends Node
class_name GestureRecognizer

# Simple $1-style single-stroke recognizer
var templates: Dictionary = {} # name: String -> points: PackedVector2Array

@export var resample_points: int = 64
@export var square_size: float = 256.0

func add_template(name: String, points: PackedVector2Array) -> void:
	if points.size() < 8:
		return
	templates[name] = _normalize(_resample(points, resample_points))

func recognize(points: PackedVector2Array) -> Dictionary:
	if points.size() < 8 or templates.is_empty():
		return {"match": "", "score": INF}
	var p: PackedVector2Array = _normalize(_resample(points, resample_points))
	var best_name: String = ""
	var best_score: float = INF
	for name in templates.keys():
		var score: float = _path_distance(p, templates[name])
		if score < best_score:
			best_score = score
			best_name = name
	return {"match": best_name, "score": best_score}

# --- Helpers ---

func _resample(points: PackedVector2Array, n: int) -> PackedVector2Array:
	var I: float = _path_length(points) / float(n - 1)
	var D: float = 0.0
	var new_points: PackedVector2Array = PackedVector2Array()
	new_points.append(points[0])
	var i: int = 1
	while i < points.size():
		var prev: Vector2 = points[i - 1]
		var curr: Vector2 = points[i]
		var d: float = prev.distance_to(curr)
		if (D + d) >= I and d > 0.0:
			var t: float = (I - D) / d
			var q: Vector2 = prev.lerp(curr, t)
			new_points.append(q)
			points.insert(i, q) # inject
			D = 0.0
		else:
			D += d
			i += 1
	while new_points.size() < n:
		new_points.append(points[-1])
	return new_points

func _path_length(points: PackedVector2Array) -> float:
	var d: float = 0.0
	for i in range(1, points.size()):
		d += points[i - 1].distance_to(points[i])
	return d

func _normalize(points: PackedVector2Array) -> PackedVector2Array:
	var c: Vector2 = _centroid(points)
	var translated: PackedVector2Array = PackedVector2Array()
	translated.resize(points.size())
	for i in range(points.size()):
		translated[i] = points[i] - c
	var rect: Rect2 = _bounds(translated)
	var scale: float = 1.0
	if rect.size.x > rect.size.y and rect.size.x > 0.0:
		scale = square_size / rect.size.x
	elif rect.size.y > 0.0:
		scale = square_size / rect.size.y
	for i in range(translated.size()):
		translated[i] *= scale
	return translated

func _centroid(points: PackedVector2Array) -> Vector2:
	var s := Vector2.ZERO
	for p in points:
		s += p
	return s / float(max(points.size(), 1))

func _bounds(points: PackedVector2Array) -> Rect2:
	var minx: float = INF
	var miny: float = INF
	var maxx: float = -INF
	var maxy: float = -INF
	for p in points:
		minx = min(minx, p.x)
		miny = min(miny, p.y)
		maxx = max(maxx, p.x)
		maxy = max(maxy, p.y)
	return Rect2(Vector2(minx, miny), Vector2(maxx - minx, maxy - miny))

func _path_distance(a: PackedVector2Array, b: PackedVector2Array) -> float:
	var d: float = 0.0
	var n: int = min(a.size(), b.size())
	for i in range(n):
		d += a[i].distance_to(b[i])
	return d / float(n)
