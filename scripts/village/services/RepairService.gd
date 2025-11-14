# res://scripts/services/economy/RepairService.gd
# Godot 4.5
# Deterministic repair costs based on BIV_r (already rarity-scaled) and missing durability percent.
# Camp repairs cost exactly 2× the Blacksmith per "point" (same missing %), per plan.

extends Node
class_name RepairService

@export var debug_logging: bool = false

# Cost tuning:
# If an item is 100% broken (missing_pct = 1.0), Blacksmith charges (BIV_r * blacksmith_rate_per_100pct) / 100.
# Camp is exactly 2× the Blacksmith for the same missing percent.
@export var blacksmith_rate_per_100pct: int = 20  # = 20% of BIV_r when fully broken
@export var camp_multiplier: float = 2.0          # exactly 2× per point (don’t change unless ADR updates)

# Optional minimums (keeps trivial nicks from costing 0 if you want a floor)
@export var min_cost_if_any_missing: int = 1      # 0 disables; 1 = at least 1 gold if any repair is needed

# --- API -------------------------------------------------------------------

func calc_blacksmith_cost(biv_r: int, missing_pct: float) -> int:
	# Clamp inputs
	var biv: int = max(0, biv_r)
	var miss: float = clamp(missing_pct, 0.0, 1.0)

	# Fixed-point math for determinism: work in basis points (0..10000)
	var bp: int = int(round(miss * 10000.0))        # e.g., 37.42% => 3742 bp
	# Effective percent of BIV to charge = (rate_per_100pct * bp / 10000)
	# cost = BIV * rate_per_100pct * bp / (100 * 10000) = BIV * rate * bp / 1_000_000
	var numer: int = biv * blacksmith_rate_per_100pct * bp
	var cost: int = _ceil_div(numer, 1_000_000)

	if miss > 0.0 and min_cost_if_any_missing > 0:
		cost = max(cost, min_cost_if_any_missing)

	if debug_logging:
		print("[RepairService] BS biv=", biv, " miss%=", miss, " bp=", bp, " -> cost=", cost)

	return cost


func calc_camp_cost(biv_r: int, missing_pct: float) -> int:
	# “Exactly 2× per point” → same percent basis, strict 2× multiplier (configurable).
	var base: int = calc_blacksmith_cost(biv_r, missing_pct)
	# Use integer math to avoid float drift: camp_multiplier is expected 2.0
	var cost: int = int(round(float(base) * camp_multiplier))

	if debug_logging:
		print("[RepairService] Camp base=", base, " mult=", camp_multiplier, " -> cost=", cost)

	return max(0, cost)

# --- Helpers ---------------------------------------------------------------

func _ceil_div(a: int, b: int) -> int:
	# Ceiling division for positive integers (a, b >= 0)
	if b <= 0:
		return 0
	if a == 0:
		return 0
	return int((a + (b - 1)) / b)
