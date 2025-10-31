extends Node


signal entry_added(entry: Dictionary)
signal cleared()

enum Level { INFO, WARN, ERROR }

const MAX_ENTRIES: int = 500

# Each entry:
# { "ts": float, "level": int, "cat": String, "msg": String, "data": Dictionary }
var _entries: Array[Dictionary] = []

func _ready() -> void:
	_entries.clear() # no reserve() on Array in Godot 4.x

func entries() -> Array[Dictionary]:
	return _entries.duplicate() # shallow copy to avoid external mutation

func count() -> int:
	return _entries.size()

func clear() -> void:
	_entries.clear()
	cleared.emit()

func post(cat: String, msg: String, data: Dictionary = {}, level: int = Level.INFO) -> void:
	var row: Dictionary = {
		"ts": Time.get_ticks_msec() / 1000.0,
		"level": level,
		"cat": String(cat),
		"msg": String(msg),
		"data": data.duplicate(),
	}
	_entries.append(row)
	if _entries.size() > MAX_ENTRIES:
		_entries.remove_at(0)
	entry_added.emit(row)

func info(cat: String, msg: String, data: Dictionary = {}) -> void:
	post(cat, msg, data, Level.INFO)

func warn(cat: String, msg: String, data: Dictionary = {}) -> void:
	post(cat, msg, data, Level.WARN)

func error(cat: String, msg: String, data: Dictionary = {}) -> void:
	post(cat, msg, data, Level.ERROR)
