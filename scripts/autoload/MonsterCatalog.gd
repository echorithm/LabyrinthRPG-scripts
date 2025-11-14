# res://scripts/autoload/MonsterCatalog.gd
extends Node

@export var catalog_path: String = "res://data/combat/enemies/monster_catalog.json"
const AbilityCatalog := preload("res://persistence/services/ability_catalog_service.gd")


var _loaded: bool = false
var _by_slug: Dictionary = {}                  # slug -> Dictionary (entry)
var _order_slugs: PackedStringArray = PackedStringArray()

# Canonical keys (per ADR + catalogs)
const _LANE_KEYS: PackedStringArray = [
	"pierce","slash","ranged","blunt","dark","light","fire","water","earth","wind"
]
const _ARMOR_KEYS: PackedStringArray = ["pierce","slash","ranged","blunt"]


func _ready() -> void:
	_ensure_loaded()

# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------
func resolve_slug(id_or_slug: StringName) -> StringName:
	_ensure_loaded()
	var s := String(id_or_slug)
	if _by_slug.has(s):
		return StringName(s)
	# Legacy "Mxx" → Nth sorted slug
	if s.length() >= 2 and s[0] == "M"[0] and s.substr(1).is_valid_int():
		if _order_slugs.is_empty():
			_order_slugs = _sorted_slugs()
		var idx := int(s.substr(1)) - 1
		if idx >= 0 and idx < _order_slugs.size():
			return StringName(_order_slugs[idx])
	return StringName(s)

func entry(slug: StringName) -> Dictionary:
	_ensure_loaded()
	var key := String(slug)
	var v: Variant = _by_slug.get(key, {})
	return (v as Dictionary)

func snapshot(slug: StringName) -> Dictionary:
	_ensure_loaded()
	var e := entry(slug)
	if e.is_empty():
		return {}

	# --- normalize stats ---
	var stats_in: Dictionary = (e.get("stats", {}) as Dictionary)
	var base: Dictionary      = (stats_in.get("base", {}) as Dictionary)
	var resist_in: Dictionary = (stats_in.get("resist_pct", {}) as Dictionary)
	var armor_in: Dictionary  = (stats_in.get("armor_flat", {}) as Dictionary)

	var stats_out: Dictionary = {
		"base": _norm_base_attrs(base),
		"resist_pct": _norm_resists(resist_in),
		"armor_flat": _norm_armor(armor_in),
		"derived": (stats_in.get("derived", {}) as Dictionary),
		"tags": (stats_in.get("tags", []) as Array)
	}

	# --- normalize abilities ---
	var abil_any: Variant = e.get("abilities", [])
	var abil_arr: Array = (abil_any as Array) if abil_any is Array else []
	var abil_out: Array = []
	for a_any in abil_arr:
		if a_any is Dictionary:
			abil_out.append(_norm_emb_ability(a_any as Dictionary))

	# --- caps (top-level) ---
	var caps_in: Dictionary = (e.get("caps", {}) as Dictionary)
	var caps_out: Dictionary = {
		"crit_chance_cap": float(caps_in.get("crit_chance_cap", 0.35)),
		"crit_multi_cap": float(caps_in.get("crit_multi_cap", 2.5)),
	}

	# Build snapshot
	return {
		"slug":           String(e.get("slug", String(slug))),
		"display_name":   String(e.get("display_name", String(slug))),
		"id":             int(e.get("id", 0)),
		"schema_version": String(e.get("schema_version", "")),
		"version":        String(e.get("version", "")),
		"scene_path":     String(e.get("scene_path", "")),
		"roles_allowed":  (e.get("roles_allowed", []) as Array),
		"boss_only":      bool(e.get("boss_only", false)),
		"base_weight":    int(e.get("base_weight", 1)),
		"level_baseline": int(e.get("level_baseline", 0)),

		"stats":          stats_out,
		"caps":           caps_out,

		"abilities":      abil_out,
		"xp_species_mod": float(e.get("xp_species_mod", 1.0)),
		"loot_source_id": String(e.get("loot_source_id", "")),
		"sigil_credit":   int(e.get("sigil_credit", 0)),
		"collision_profile": String(e.get("collision_profile", "")),
	}

func slugs_for_role(role: String, include_boss_only: bool=false) -> PackedStringArray:
	_ensure_loaded()
	var out := PackedStringArray()
	for k in _by_slug.keys():
		var ee: Dictionary = _by_slug[k]
		var roles: Array = (ee.get("roles_allowed", []) as Array)
		var boss_only: bool = bool(ee.get("boss_only", false))
		if roles.has(role):
			if role != "boss" and boss_only and not include_boss_only:
				continue
			out.append(String(k))
	return out

func weight_for(slug: StringName) -> int:
	var e := entry(slug)
	return int(e.get("base_weight", 1))

func display_name(slug: StringName) -> String:
	var e := entry(slug)
	return String(e.get("display_name", String(slug)))

func instantiate_visual(parent: Node, slug: StringName) -> Node3D:
	var e := entry(slug)
	var p := String(e.get("scene_path", ""))
	if p != "" and ResourceLoader.exists(p):
		var sc: PackedScene = load(p)
		if sc != null:
			var inst := sc.instantiate() as Node3D
			if inst != null and parent != null:
				parent.add_child(inst)
			return inst
	return _fallback_box(parent)

func is_role_allowed(slug: StringName, role: String) -> bool:
	var e_any: Variant = _by_slug.get(String(slug), null)
	if e_any == null or not (e_any is Dictionary):
		return false
	var e := e_any as Dictionary
	var roles_any: Variant = e.get("roles_allowed", [])
	var roles_arr: Array = (roles_any as Array) if roles_any is Array else []
	for r in roles_arr:
		if String(r) == role:
			return true
	return false

# -------------------------------------------------------------------
# Internals
# -------------------------------------------------------------------
func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true

	var f := FileAccess.open(catalog_path, FileAccess.READ)
	if f == null:
		push_error("[MonsterCatalog] Could not open catalog: " + catalog_path)
		return

	var txt := f.get_as_text()
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_ARRAY:
		push_error("[MonsterCatalog] JSON root is not an array: " + catalog_path)
		return

	# Ability catalog service (no global const needed elsewhere)
	var AbilityCatalog := preload("res://persistence/services/ability_catalog_service.gd")

	var arr: Array = parsed as Array
	for item in arr:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = (item as Dictionary)
		var slug := String(e.get("slug", ""))
		if slug == "":
			continue

		# Store raw entry
		_by_slug[slug] = e

		# Register this monster's abilities into the ability catalog (if any)
		var abil_any: Variant = e.get("abilities", [])
		if typeof(abil_any) == TYPE_ARRAY:
			var norm: Array = []
			for a_any in (abil_any as Array):
				if typeof(a_any) == TYPE_DICTIONARY:
					norm.append(_norm_emb_ability(a_any as Dictionary))
			if not norm.is_empty():
				AbilityCatalog.register_external(norm)

	_order_slugs = _sorted_slugs()
	print("[MonsterCatalog] Loaded entries=%d" % _by_slug.size())


func _sorted_slugs() -> PackedStringArray:
	var keys := PackedStringArray()
	for k in _by_slug.keys():
		keys.append(String(k))
	keys.sort()
	return keys

func _fallback_box(parent: Node) -> Node3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.0, 1.8, 1.0)
	mi.mesh = bm
	if parent != null:
		parent.add_child(mi)
	return mi

# --- Normalizers ----------------------------------------------------
func _norm_base_attrs(in_d: Dictionary) -> Dictionary:
	# 8 base attributes; default 1s are fine for monsters
	var keys := ["STR","AGI","DEX","END","INT","WIS","CHA","LCK"]
	var out := {}
	for k in keys:
		out[k] = int(in_d.get(k, 1))
	return out

func _norm_resists(in_d: Dictionary) -> Dictionary:
	var out := {}
	for k in _LANE_KEYS:
		# clamp to ADR limits [-90.0, +95.0] (soft guard)
		var v := float(in_d.get(k, 0.0))
		if v < -90.0: v = -90.0
		if v > 95.0: v = 95.0
		out[k] = v
	return out

func _norm_armor(in_d: Dictionary) -> Dictionary:
	var out := {}
	for k in _ARMOR_KEYS:
		out[k] = max(0, int(in_d.get(k, 0)))
	return out

func _norm_emb_ability(a: Dictionary) -> Dictionary:
	# Keep authoring fields, enforce lanes{10} + ai{} presence and types
	var lanes_in: Dictionary = (a.get("lanes", {}) as Dictionary)
	var lanes_out := {}
	for k in _LANE_KEYS:
		lanes_out[k] = float(lanes_in.get(k, 0.0))
	var ai_in: Dictionary = (a.get("ai", {}) as Dictionary)

	var out := a.duplicate(true)
	out["lanes"] = lanes_out
	out["ai"] = {
		"targeting": String(ai_in.get("targeting", "")),
		"range": String(ai_in.get("range", ""))
	}
	# Ensure a few numeric types are concrete
	out["base_power"] = int(out.get("base_power", 0))
	out["ctb_cost"] = int(out.get("ctb_cost", 100))
	out["skill_level_baseline"] = int(out.get("skill_level_baseline", 1))
	out["weight"] = float(out.get("weight", 0.0))
	return out
