extends RefCounted
class_name SaveUtils
# Small, typed helpers used by schemas/services.

static func dget(d: Dictionary, key: String, def: Variant) -> Variant:
	return d[key] if d.has(key) else def

static func now_ts() -> int:
	return Time.get_unix_time_from_system()

static func deep_copy_dict(d: Dictionary) -> Dictionary:
	return d.duplicate(true)

static func to_dict(v: Variant) -> Dictionary:
	return (v as Dictionary) if v is Dictionary else {}

static func to_int_array(v: Variant) -> Array[int]:
	var out: Array[int] = []
	if v is Array:
		for x in (v as Array):
			out.append(int(x))
	elif v is PackedInt32Array:
		for x in (v as PackedInt32Array):
			out.append(int(x))
	elif v is PackedInt64Array:
		for x in (v as PackedInt64Array):
			out.append(int(x))
	return out

static func to_string_array(v: Variant) -> Array[String]:
	var out: Array[String] = []
	if v is Array:
		for x in (v as Array):
			out.append(String(x))
	elif v is PackedStringArray:
		for x in (v as PackedStringArray):
			out.append(String(x))
	return out

static func normalize_seeds(v: Variant) -> Dictionary:
	var seeds_in: Dictionary = to_dict(v)
	var out: Dictionary = {}
	for k in seeds_in.keys():
		out[int(k)] = int(seeds_in[k])
	return out

static func merge_defaults(dst: Dictionary, defaults: Dictionary) -> Dictionary:
	var out: Dictionary = deep_copy_dict(dst)
	for k in defaults.keys():
		if not out.has(k):
			out[k] = defaults[k]
	return out
