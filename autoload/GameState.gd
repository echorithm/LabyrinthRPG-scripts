extends Node
class_name GameState

var shards: int = 0
var village: Dictionary = {
	"inn": 0,
	"blacksmith": 0,
	"alchemist": 0
}

const SAVE_PATH := "user://save_meta.json"
const SAVE_VERSION := 1

func _ready() -> void:
	load_meta()
	print("AppState loaded")

func save_meta() -> void:
	var payload: Dictionary = {
		"version": SAVE_VERSION,
		"shards": shards,
		"village": village,
	}
	var f: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(payload))
	f.close()

func load_meta() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var text: String = f.get_as_text()
	f.close()
	var res: Variant = JSON.parse_string(text)
	if res is Dictionary:
		var d: Dictionary = res
		if d.has("shards"):
			shards = int(d["shards"])
		if d.has("village"):
			village = d["village"]
