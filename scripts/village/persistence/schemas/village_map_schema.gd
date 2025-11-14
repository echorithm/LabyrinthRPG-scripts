extends RefCounted
class_name VillageMapSchema

## Village map snapshot schema v2 (art-first).
## v2: per-tile render_key is ALWAYS computed (unique packing). No tiebreaks.

const SCHEMA_VERSION: int = 2
const CORE_KINDS: PackedStringArray = ["wild", "road", "bridge", "camp_core", "labyrinth"]

static func defaults() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"seed": 0,
		"grid": {
			"radius": 4,
			"tiles": []  # Array[Dictionary]
		},
		"meta": { "created_at": Time.get_unix_time_from_system(), "edited_at": 0 }
	}

static func validate(d_in: Dictionary) -> Dictionary:
	if d_in.is_empty():
		return defaults()

	var out: Dictionary = {}
	out["schema_version"] = SCHEMA_VERSION
	out["seed"] = int(d_in.get("seed", 0))

	var g_in: Dictionary = _to_dict(d_in.get("grid", {}))
	var radius: int = max(0, int(g_in.get("radius", 4)))

	var tiles_in_any: Variant = g_in.get("tiles", [])
	var tiles_in: Array = tiles_in_any if (tiles_in_any is Array) else []
	var tiles_out: Array[Dictionary] = []
	for it in tiles_in:
		if it is Dictionary:
			var coerced: Dictionary = _coerce_tile(it as Dictionary, radius)
			tiles_out.append(coerced)

	out["grid"] = { "radius": radius, "tiles": tiles_out }

	var m_in: Dictionary = _to_dict(d_in.get("meta", {}))
	var created: int = int(m_in.get("created_at", Time.get_unix_time_from_system()))
	var edited: int = int(Time.get_unix_time_from_system())
	out["meta"] = { "created_at": created, "edited_at": edited }

	return out

# --- internals ---

static func _to_dict(v: Variant) -> Dictionary:
	return v if (v is Dictionary) else {}

static func _tile_id_for(q: int, r: int) -> String:
	return "H_%d_%d" % [q, r]

static func _to_string_array(v: Variant) -> Array[String]:
	var out: Array[String] = []
	if v is Array:
		for x in (v as Array):
			out.append(String(x))
	return out

# Unique integer packing for axial coordinates within a disk of given radius.
# base = 2*radius + 1; domain is q,r ∈ [-radius, +radius].
static func _pack_render_key(q: int, r: int, radius: int) -> int:
	var base: int = 2 * radius + 1
	return (r + radius) * base + (q + radius)

static func _coerce_tile(t_in: Dictionary, radius: int) -> Dictionary:
	# Coordinates and identity
	var q: int = int(t_in.get("q", 0))
	var r: int = int(t_in.get("r", 0))
	var tile_id: String = String(t_in.get("tile_id", _tile_id_for(q, r)))

	# Gameplay/art classification
	var biome: int = int(t_in.get("biome", 0))
	var kind: String = String(t_in.get("kind", "wild"))
	# Enforce only core kinds; anything else (e.g., "alchemist_lab") is allowed
	if CORE_KINDS.has(kind):
		pass # keep as-is
	elif kind == "":
		kind = "wild"  # empty -> wild
	# else: pass-through (expected for building ids from Buildings Catalog)

	# Road mask (6-neighbor bitmask)
	var road_mask: int = int(t_in.get("road_mask", 0)) & 0b111111

	# Required art id
	var base_art_id: String = String(t_in.get("base_art_id", ""))
	if base_art_id == "":
		push_error("VillageMapSchema: base_art_id is REQUIRED for tile (%d,%d)" % [q, r])

	# Optional art attrs (persist only if non-default)
	var art_locked: bool = bool(t_in.get("art_locked", false))
	var rotation: int = int(t_in.get("rotation", 0))
	var variant: int = int(t_in.get("variant", 0))
	var decor_art_ids: Array[String] = _to_string_array(t_in.get("decor_art_ids", []))

	# --- v2 deterministic render (no overrides, no tiebreaks) ---

	# Ignore any incoming render fields and compute a unique key.
	var render_key: int = _pack_render_key(q, r, radius)

	# Optional stable payload and tags (not render-related)
	var static_payload_any: Variant = t_in.get("static", {})
	var static_payload: Dictionary = _to_dict(static_payload_any)
	var tags: Array[String] = _to_string_array(t_in.get("tags", []))

	# Assemble output
	var t_out: Dictionary = {
		"q": q,
		"r": r,
		"tile_id": tile_id,
		"biome": biome,
		"kind": kind,
		"road_mask": road_mask,
		"base_art_id": base_art_id,
		"render_key": render_key
	}

	# Persist optionals only when meaningful
	if art_locked:
		t_out["art_locked"] = true
	if rotation != 0:
		t_out["rotation"] = rotation
	if variant != 0:
		t_out["variant"] = variant
	if decor_art_ids.size() > 0:
		t_out["decor_art_ids"] = decor_art_ids
	if static_payload.size() > 0:
		t_out["static"] = static_payload
	if tags.size() > 0:
		t_out["tags"] = tags

	return t_out
