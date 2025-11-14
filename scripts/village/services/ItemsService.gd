extends Node
class_name ItemsService

const _DBG := "[ItemsService] "
func _log(msg: String) -> void: print(_DBG + msg)

@export var items_catalog_path: NodePath   # Optional: your existing catalog node (if any)

var _catalog: Node = null

func _ready() -> void:
	_catalog = get_node_or_null(items_catalog_path)

func get_display_name(id: StringName) -> String:
	# Primary: ask an items catalog if present
	if _catalog != null and _catalog.has_method("get_display_name"):
		var n: String = _catalog.call("get_display_name", id)
		if n != "": return n
	# Fallback: prettify the id
	var s := String(id)
	if s == "": return ""
	return s.capitalize().replace("_", " ")

func get_desc(id: StringName) -> String:
	if _catalog != null and _catalog.has_method("get_desc"):
		var d: String = _catalog.call("get_desc", id)
		if d != "": return d
	return ""  # OK for UI to render empty desc
