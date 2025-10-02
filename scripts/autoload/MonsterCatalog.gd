# res://scripts/autoload/MonsterCatalog.gd
extends Node


@export var catalog_path: String = "res://data/combat/enemies/monster_catalog.json"

var _loaded: bool = false
var _by_slug: Dictionary = {}                  # slug -> Dictionary (entry)
var _order_slugs: PackedStringArray = PackedStringArray()

func _ready() -> void:
	_ensure_loaded()

# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------
func resolve_slug(id_or_slug: StringName) -> StringName:
	_ensure_loaded()
	var s: String = String(id_or_slug)
	# Already a known slug?
	if _by_slug.has(s):
		return StringName(s)
	# Legacy "Mxx" support (M01 -> first slug in sorted order)
	if s.length() >= 2 and s[0] == "M"[0] and s.substr(1).is_valid_int():
		if _order_slugs.is_empty():
			_order_slugs = _sorted_slugs()
		var idx: int = int(s.substr(1)) - 1
		if idx >= 0 and idx < _order_slugs.size():
			return StringName(_order_slugs[idx])
	# Fallback: return as-is (treat as slug)
	return StringName(s)

func entry(slug: StringName) -> Dictionary:
	_ensure_loaded()
	var key: String = String(slug)
	var v: Variant = _by_slug.get(key, {})
	return (v as Dictionary)

func snapshot(slug: StringName) -> Dictionary:
	_ensure_loaded()
	var e: Dictionary = entry(slug)
	if e.is_empty():
		return {}
	var roles_any: Variant = e.get("roles_allowed", [])
	var stats_any: Variant = e.get("stats", {})
	var abilities_any: Variant = e.get("abilities", [])
	return {
		"slug":           String(e.get("slug", "")),
		"display_name":   String(e.get("display_name", String(slug))),
		"id":             int(e.get("id", 0)),
		"scene_path":     String(e.get("scene_path", "")),
		"roles_allowed":  (roles_any as Array),
		"boss_only":      bool(e.get("boss_only", false)),
		"base_weight":    int(e.get("base_weight", 1)),
		"level_baseline": int(e.get("level_baseline", 1)),
		"stats":          (stats_any as Dictionary),
		"abilities":      (abilities_any as Array),
		"loot_source_id": String(e.get("loot_source_id", "")),
	}

func slugs_for_role(role: String, include_boss_only: bool=false) -> PackedStringArray:
	_ensure_loaded()
	var out: PackedStringArray = PackedStringArray()
	for k in _by_slug.keys():
		var e: Dictionary = _by_slug[k]
		var roles: Array = (e.get("roles_allowed", []) as Array)
		var boss_only: bool = bool(e.get("boss_only", false))
		if roles.has(role):
			if role != "boss" and boss_only and not include_boss_only:
				continue
			out.append(String(k))
	return out

func weight_for(slug: StringName) -> int:
	var e: Dictionary = entry(slug)
	return int(e.get("base_weight", 1))

func display_name(slug: StringName) -> String:
	var e: Dictionary = entry(slug)
	return String(e.get("display_name", String(slug)))

func instantiate_visual(parent: Node, slug: StringName) -> Node3D:
	var e: Dictionary = entry(slug)
	var p: String = String(e.get("scene_path", ""))
	if p != "" and ResourceLoader.exists(p):
		var sc: PackedScene = load(p)
		if sc != null:
			var inst: Node3D = sc.instantiate() as Node3D
			if inst != null and parent != null:
				parent.add_child(inst)
			return inst
	# Fallback cube if scene missing
	return _fallback_box(parent)

# -------------------------------------------------------------------
# Internals
# -------------------------------------------------------------------
func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true

	var f: FileAccess = FileAccess.open(catalog_path, FileAccess.READ)
	if f == null:
		push_error("[MonsterCatalog] Could not open catalog: " + catalog_path)
		return

	var txt: String = f.get_as_text()
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_ARRAY:
		push_error("[MonsterCatalog] JSON root is not an array: " + catalog_path)
		return

	var arr: Array = (parsed as Array)
	for item in arr:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = (item as Dictionary)
		var slug: String = String(e.get("slug", ""))
		if slug == "":
			continue
		_by_slug[slug] = e

	_order_slugs = _sorted_slugs()
	print("[MonsterCatalog] Loaded entries=", _by_slug.size())

func _sorted_slugs() -> PackedStringArray:
	var keys: PackedStringArray = PackedStringArray()
	for k in _by_slug.keys():
		keys.append(String(k))
	keys.sort()
	return keys

func _fallback_box(parent: Node) -> Node3D:
	var mi: MeshInstance3D = MeshInstance3D.new()
	var bm: BoxMesh = BoxMesh.new()
	bm.size = Vector3(1.0, 1.8, 1.0)
	mi.mesh = bm
	if parent != null:
		parent.add_child(mi)
	return mi

func is_role_allowed(slug: StringName, role: String) -> bool:
	var e_any: Variant = _by_slug.get(slug, null)
	if e_any == null or not (e_any is Dictionary):
		return false
	var e: Dictionary = e_any as Dictionary

	var roles_any: Variant = e.get("roles_allowed", [])
	var roles_arr: Array = (roles_any as Array) if roles_any is Array else []

	for r in roles_arr:
		if String(r) == role:
			return true
	return false
