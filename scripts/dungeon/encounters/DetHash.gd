extends RefCounted
class_name DetHash

static func djb2_64(parts: Array[String]) -> int:
	var h: int = 5381
	for s: String in parts:
		var buf: PackedByteArray = s.to_utf8_buffer()
		for b: int in buf:
			h = ((h << 5) + h) + b  # h*33 + b
	# Clamp to positive signed 63-bit
	h &= 0x7fffffffffffffff
	return h
