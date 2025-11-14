# Godot 4.5
extends RefCounted
class_name MonsterRarityService
##
## Purpose
## - Compute rarity band from **level** (10‑level bands).
## - Apply a multiplicative **power spike** to MonsterRuntime stats when band ≥ Uncommon.
## - Reskin a monster's 3D visual by overriding **albedo texture** based on band.
##
## References / Contracts
## - Rarity → DBZ "value" and cube‑root "power" chain (authoritative multipliers). :contentReference[oaicite:0]{index=0} :contentReference[oaicite:1]{index=1}
## - Level bands: 1–10 C, 11–20 U, 21–30 R, 31–40 E, 41–50 A, 51–60 L, 61+ M. :contentReference[oaicite:2]{index=2}
## - This module is deterministic (no RNG) and makes **no persistence writes**.

const _MonsterRuntime := preload("res://scripts/combat/snapshot/MonsterRuntime.gd")

## Debug flag (local to this service)
static var DEBUG_LOGS: bool = true

# -----------------------------------------------------------------------------#
# Rarity math (letters & names)
# -----------------------------------------------------------------------------#

static func rarity_code_for_level(level: int) -> String:
	if level <= 10:
		return "C"
	elif level <= 20:
		return "U"
	elif level <= 30:
		return "R"
	elif level <= 40:
		return "E"
	elif level <= 50:
		return "A"
	elif level <= 60:
		return "L"
	else:
		return "M"

static func rarity_name_for_code(code: String) -> String:
	match code:
		"C": return "COMMON"
		"U": return "UNCOMMON"
		"R": return "RARE"
		"E": return "EPIC"
		"A": return "ANCIENT"
		"L": return "LEGENDARY"
		"M": return "MYTHIC"
		_:   return "COMMON"

## DBZ chain (combat power multipliers). See ADR-010/plan table.
static func power_mult_for_code(code: String) -> float:
	match code:
		"C": return 1.00
		"U": return 1.65
		"R": return 2.62
		"E": return 3.98
		"A": return 5.74
		"L": return 7.78
		"M": return 9.79
		_:   return 1.00

static func power_mult_for_level(level: int) -> float:
	return power_mult_for_code(rarity_code_for_level(level))

# -----------------------------------------------------------------------------#
# Power spike application
# -----------------------------------------------------------------------------#

## Applies rarity power to a MonsterRuntime's **derived** numbers.
## Scales: hp_max/mp_max/p_atk/m_atk/defense/resistance and current hp/mp.
## Returns the rarity code applied (e.g., "U"), allowing the caller to log it.
static func apply_power_by_level(mr: _MonsterRuntime, level: int) -> String:
	var code: String = rarity_code_for_level(level)
	var mult: float = power_mult_for_code(code)
	if mult <= 1.0001:
		return code

	# Scale derived combat numbers; keep CTB/resists lanes/armor as authored.
	mr.hp_max = int(round(float(mr.hp_max) * mult))
	mr.mp_max = int(round(float(mr.mp_max) * mult))
	mr.p_atk  = float(mr.p_atk)  * mult
	mr.m_atk  = float(mr.m_atk)  * mult
	mr.defense    = float(mr.defense)    * mult
	mr.resistance = float(mr.resistance) * mult

	# Preserve current pools proportionally; clamp to new maxima.
	mr.hp = clampi(int(round(float(max(mr.hp, 1)) * mult)), 1, mr.hp_max)
	mr.mp = clampi(int(round(float(max(mr.mp, 0)) * mult)), 0, mr.mp_max)

	if DEBUG_LOGS:
		print("[Rarity] Applied ", rarity_name_for_code(code), " ×", String.num(mult, 2),
			"  → HP:", mr.hp, "/", mr.hp_max, "  MP:", mr.mp, "/", mr.mp_max,
			"  PATK:", String.num(mr.p_atk, 2), "  MATK:", String.num(mr.m_atk, 2))

	return code

# -----------------------------------------------------------------------------#
# Reskinning (albedo swap)
# -----------------------------------------------------------------------------#

## Texture path mapping per band (U+). Common → no swap.
static func _texture_path_for(code: String) -> String:
	match code:
		"U": return "res://art/monsters/common/textures/rarity/Albedo_uncommon.png"
		"R": return "res://art/monsters/common/textures/rarity/Albedo_rare.png"
		"E": return "res://art/monsters/common/textures/rarity/Albedo_epic.png"
		"A": return "res://art/monsters/common/textures/rarity/Albedo_ancient.png"
		"L": return "res://art/monsters/common/textures/rarity/Albedo_legendary.png"
		"M": return "res://art/monsters/common/textures/rarity/Albedo_mythic.png"
		_:   return ""  # Common or unknown

## Fallback tint if a texture is missing (kept simple/neutral).
static func _tint_color_for(code: String) -> Color:
	match code:
		"U": return Color(0.70, 0.90, 1.00)  # soft cyan
		"R": return Color(1.00, 0.85, 0.25)  # amber
		"E": return Color(0.85, 0.50, 1.00)  # violet
		"A": return Color(1.00, 0.65, 0.30)  # orange
		"L": return Color(1.00, 0.95, 0.55)  # gold
		"M": return Color(1.00, 0.30, 0.30)  # red
		_:   return Color.WHITE

## Public: reskin by **level**. Returns number of MeshInstance3D altered.
static func reskin_visual_for_level(visual_root: Node3D, level: int) -> int:
	return reskin_visual_for_code(visual_root, rarity_code_for_level(level))

## Public: reskin by **rarity code**. Returns number of MeshInstance3D altered.
static func reskin_visual_for_code(visual_root: Node3D, code: String) -> int:
	if visual_root == null:
		return 0
	if code == "C":
		return 0  # Common keeps default authoring.

	var tex_path: String = _texture_path_for(code)
	var texture: Texture2D = null
	if tex_path != "" and ResourceLoader.exists(tex_path):
		var res: Resource = ResourceLoader.load(tex_path)
		texture = res as Texture2D

	var changed: int = 0
	var stack: Array[Node] = [visual_root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		var mi: MeshInstance3D = n as MeshInstance3D
		if mi != null:
			if _apply_material_override(mi, texture, code):
				changed += 1
		# Traverse children (Node3D only to stay on the visual branch)
		var cc: int = n.get_child_count()
		for i in range(cc):
			var c: Node = n.get_child(i)
			if c is Node3D:
				stack.push_back(c)
	return changed

# --- internals ---------------------------------------------------------------#

static func _apply_material_override(mi: MeshInstance3D, tex: Texture2D, code: String) -> bool:
	# If we have a texture, put it on a duplicated StandardMaterial3D and
	# assign to material_override. If not, tint albedo color.
	var out: bool = false
	if tex != null:
		var mat: StandardMaterial3D = null
		if mi.material_override is StandardMaterial3D:
			mat = (mi.material_override as StandardMaterial3D).duplicate(true)
		else:
			mat = StandardMaterial3D.new()
		mat.albedo_texture = tex
		# Ensure base color is neutral to fully show the texture
		mat.albedo_color = Color(1, 1, 1, 1)
		mi.material_override = mat
		out = true
	else:
		# Texture missing: apply a subtle band tint so the tier is still visible.
		var mat2: StandardMaterial3D = null
		if mi.material_override is StandardMaterial3D:
			mat2 = (mi.material_override as StandardMaterial3D).duplicate(true)
			mat2.albedo_texture = null
		else:
			mat2 = StandardMaterial3D.new()
		mat2.albedo_color = _tint_color_for(code)
		mi.material_override = mat2
		out = true

	if DEBUG_LOGS and out:
		var path_dbg: String = (mi.get_path() if mi.get_parent() != null else mi.name)
		print("[Rarity] Reskinned ", path_dbg, " → ", rarity_name_for_code(code))
	return out
