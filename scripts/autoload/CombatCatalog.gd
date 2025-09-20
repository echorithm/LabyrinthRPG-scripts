extends Node
# Loads monster_catalog.json and provides helpers to resolve ids/slugs and spawn visuals.

@export var catalog_path: String = "res://data/combat/enemies/monster_catalog.json"
@export var id_offset: int = 2000            # Mxx => id_offset + xx  (e.g., 2000 + 24 = 2024)
@export var debug_verbose: bool = true

var _by_id: Dictionary          = {}  # int -> Dictionary (raw entry)
var _by_slug: Dictionary        = {}  # StringName -> Dictionary
var _by_mid: Dictionary         = {}  # "Mxx" -> Dictionary

func _ready() -> void:
	_by_id.clear()
	_by_slug.clear()
	_by_mid.clear()

	var f := FileAccess.open(catalog_path, FileAccess.READ)
	if f == null:
		push_error("[CombatCatalog] Could not open: " + catalog_path)
		return

	var txt: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Array):
		push_error("[CombatCatalog] JSON is not an Array at " + catalog_path)
		return

	var arr: Array = parsed as Array
	for e_any: Variant in arr:
		if not (e_any is Dictionary):
			continue
		var e := e_any as Dictionary
		var id: int = int(e.get("id", 0))
		var slug: StringName = StringName(e.get("slug", ""))
		if id <= 0 or String(slug) == "":
			continue

		_by_id[id] = e
		_by_slug[slug] = e

		# Also index as Mxx if it fits the offset mapping (optional but handy)
		var m_num: int = id - id_offset
		if m_num >= 0 and m_num <= 99:
			var mid: String = "M%02d" % m_num
			_by_mid[StringName(mid)] = e

	if debug_verbose:
		print("[CombatCatalog] Loaded entries=", _by_id.size(),
			"  slugs=", PackedStringArray(_by_slug.keys().map(func(k): return String(k))),
			"  has_Mxx=", _by_mid.size())

# ---- Lookups ----
func get_by_slug(slug: StringName) -> Dictionary:
	var v: Variant = _by_slug.get(slug)
	return v if (v is Dictionary) else {}

func get_by_id(id: int) -> Dictionary:
	var v: Variant = _by_id.get(id)
	return v if (v is Dictionary) else {}

func get_by_mid(mid: StringName) -> Dictionary:
	var v: Variant = _by_mid.get(mid)
	if v is Dictionary:
		return v
	# Fallback: parse “Mxx” directly
	var s: String = String(mid)
	if s.length() >= 2 and s[0] == "M":
		var n_str := s.substr(1, s.length() - 1)
		var n := int(n_str)
		return get_by_id(id_offset + n)
	return {}

func resolve_entry(tag: StringName) -> Dictionary:
	# Accept either “slug” or “Mxx”
	var e := get_by_slug(tag)
	if e.is_empty():
		e = get_by_mid(tag)
	return e

# ---- Convenience: visuals & encounter ids ----
func scene_path_for(tag: StringName) -> String:
	var e := resolve_entry(tag)
	return String(e.get("scene_path", ""))

func enemy_id_for(tag: StringName) -> StringName:
	# For BattleController → use the slug as the enemy id.
	var e := resolve_entry(tag)
	var slug: String = String(e.get("slug", ""))
	return StringName(slug)

func instantiate_visual(parent: Node3D, tag: StringName) -> Node3D:
	var p: String = scene_path_for(tag)
	if p == "":
		if debug_verbose:
			print("[CombatCatalog] No scene_path for", String(tag))
		return null
	var ps: PackedScene = load(p) as PackedScene
	if ps == null:
		push_warning("[CombatCatalog] Could not load PackedScene: " + p)
		return null
	var inst: Node3D = ps.instantiate() as Node3D
	if inst == null:
		return null
	parent.add_child(inst)
	return inst

func build_stats_from_entry(entry: Dictionary) -> Stats:
	var s: Stats = Stats.new()
	var lvl: int = int(entry.get("level_baseline", 1))
	var st: Dictionary = entry.get("stats", {})
	s.level = lvl
	s.strength     = int(st.get("STR", 0))
	s.agility      = int(st.get("AGI", 0))
	s.dexterity    = int(st.get("DEX", 0))
	s.endurance    = int(st.get("END", 0))
	s.intelligence = int(st.get("INT", 0))
	s.wisdom       = int(st.get("WIS", 0))
	s.charisma     = int(st.get("CHA", 0))
	s.luck         = int(st.get("LCK", 0))
	return s

func primary_school_for(tag: StringName) -> StringName:
	var e: Dictionary = resolve_entry(tag)
	var abilities_any: Variant = e.get("abilities", [])
	if abilities_any is Array:
		for a_any in (abilities_any as Array):
			if a_any is Dictionary:
				var a: Dictionary = a_any
				var tags_any: Variant = a.get("tags", [])
				if tags_any is Array and (tags_any as Array).has("primary"):
					return StringName(a.get("school", "power"))
	# default if not found
	return &"power"
