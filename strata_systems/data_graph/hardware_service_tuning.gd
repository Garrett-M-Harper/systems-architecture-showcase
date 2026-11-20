class_name HardwareServiceTuning
extends Resource

## HardwareServiceTuning
## Single Source of Truth (SSOT) for hangar hardware servicing:
## Repair, Tuning (+1%), Overhauling (Nanopaste oz), and Destruction Scarring.

@export_group("Tuning (+1% Quality)")
@export var k_tune: float = 0.005
@export var q_scale: float = 20.0
@export var power_kwh_per_kg_tune: float = 0.1
@export var fasteners_mass_ratio_tune: float = 0.05

@export_group("Overhauling (Nanopaste)")
@export var oz_mass_divisor_kg: float = 50.0
@export var base_value_nanopaste_oz: int = 150

@export_group("Quality & Stat Scaling")
## Maximum stat delta percentage applied at the boundaries (-15% at Q0, +15% at Q95+)
@export var max_stat_delta: float = 0.15

@export_group("Repair")
@export var power_kwh_base_repair: float = 15.0
@export var fasteners_mass_ratio_repair: float = 0.05

@export_group("Wholesale Scrap Liquidation (₵/kg)")
@export var fe_iron_credits_per_kg: float = 2.0
@export var ti_titanium_credits_per_kg: float = 6.0
@export var cu_copper_credits_per_kg: float = 12.0
@export var w_tungsten_credits_per_kg: float = 25.0
@export var fasteners_credits_per_unit: float = 1.0

## Returns credits yielded for liquidating a specific elemental scrap or fastener batch
func calculate_scrap_liquidation_credits(element_type: String, amount: float) -> int:
	var amt := maxf(0.0, amount)
	match element_type.to_lower():
		"fe_iron", "iron":
			return int(floor(amt * fe_iron_credits_per_kg))
		"ti_titanium", "titanium":
			return int(floor(amt * ti_titanium_credits_per_kg))
		"cu_copper", "copper":
			return int(floor(amt * cu_copper_credits_per_kg))
		"w_tungsten", "tungsten":
			return int(floor(amt * w_tungsten_credits_per_kg))
		"unthreaded_fasteners", "fasteners":
			return int(floor(amt * fasteners_credits_per_unit))
		_:
			return 0


const GRADE_FLOORS: Dictionary = {
	"A+": 95.0,
	"A": 85.0,
	"B": 70.0,
	"C": 50.0,
	"D": 30.0,
	"F": 0.0
}

const GRADE_LADDER: Array[String] = ["F", "D", "C", "B", "A", "A+"]

## Returns standard industrial letter grade for a quality float (0.0 - 100.0)
func get_quality_grade(q: float) -> String:
	return get_quality_grade_static(q)

static func get_quality_grade_static(q: float) -> String:
	if q >= 95.0: return "A+"
	if q >= 85.0: return "A"
	if q >= 70.0: return "B"
	if q >= 50.0: return "C"
	if q >= 30.0: return "D"
	return "F"

## Returns the lowest Quality value (floor) for a given grade
func get_grade_floor(grade: String) -> float:
	return get_grade_floor_static(grade)

static func get_grade_floor_static(grade: String) -> float:
	return float(GRADE_FLOORS.get(grade.to_upper(), 0.0))

## Returns the next higher letter grade, or empty string if at max (A+)
func get_next_grade(current_grade: String) -> String:
	return get_next_grade_static(current_grade)

static func get_next_grade_static(current_grade: String) -> String:
	var g := current_grade.to_upper()
	var idx := GRADE_LADDER.find(g)
	if idx >= 0 and idx < GRADE_LADDER.size() - 1:
		return GRADE_LADDER[idx + 1]
	return ""

## Returns the next lower letter grade, or "F" if at floor
func get_lower_grade(current_grade: String) -> String:
	return get_lower_grade_static(current_grade)

static func get_lower_grade_static(current_grade: String) -> String:
	var g := current_grade.to_upper()
	var idx := GRADE_LADDER.find(g)
	if idx > 0:
		return GRADE_LADDER[idx - 1]
	return "F"

## Derives initial Quality within the band of a factory grade
static func derive_quality_from_grade(grade: String, seed_val: int = 0) -> float:
	var g := grade.to_upper().strip_edges()
	var floor_val: float = 50.0
	var width_val: float = 20.0
	match g:
		"A+":
			floor_val = 95.0
			width_val = 5.0
		"A":
			floor_val = 85.0
			width_val = 10.0
		"B":
			floor_val = 70.0
			width_val = 15.0
		"C":
			floor_val = 50.0
			width_val = 20.0
		"D":
			floor_val = 30.0
			width_val = 20.0
		"F":
			floor_val = 5.0
			width_val = 25.0
		_:
			floor_val = 50.0
			width_val = 20.0

	if seed_val == 0:
		return floor_val
	var u: float = float(posmod(int(hash(seed_val)), 1000)) / 1000.0
	return floor_val + (width_val * u)

## Continuous stat modifier delta across the widened [-0.15, +0.15] range
func get_stat_delta(q: float) -> float:
	return get_stat_delta_static(q, max_stat_delta)

static func get_stat_delta_static(q: float, max_delta: float = 0.15) -> float:
	var clamped_q := clampf(q, 0.0, 100.0)
	if clamped_q >= 50.0:
		return ((clamped_q - 50.0) / 45.0) * max_delta
	else:
		return ((clamped_q - 50.0) / 50.0) * max_delta


## Calculates required Nanopaste in fluid ounces (oz) for an overhaul
func calculate_overhaul_oz(mass_kg: float) -> int:
	var effective_mass := maxf(1.0, mass_kg)
	return int(maxi(1, int(ceil(effective_mass / oz_mass_divisor_kg))))

## Calculates elemental metals, fasteners, and power required to Tune a node +1%
func calculate_tune_cost(current_quality: float, mass_kg: float, role: String) -> Dictionary:
	var q := clampf(current_quality, 0.0, 99.0)
	var effective_mass := maxf(1.0, mass_kg)
	var total_metal_kg := effective_mass * k_tune * exp(q / q_scale)

	var fe_mass := 0.0
	var ti_mass := 0.0
	var cu_mass := 0.0
	var w_mass := 0.0

	match role.to_lower():
		"armor", "defense", "torso_chassis", "pelvis_assembly", "shoulder_payload_left", "shoulder_payload_right":
			ti_mass = total_metal_kg * 0.40
			fe_mass = total_metal_kg * 0.25
			cu_mass = total_metal_kg * 0.10
			w_mass = total_metal_kg * 0.05
		"power", "power_bay", "battery", "generator", "cooling":
			cu_mass = total_metal_kg * 0.40
			fe_mass = total_metal_kg * 0.20
			ti_mass = total_metal_kg * 0.10
		"weapon", "autocannon_30mm", "slag_rail_lance":
			w_mass = total_metal_kg * 0.30
			fe_mass = total_metal_kg * 0.30
			ti_mass = total_metal_kg * 0.15
		"sensor", "control", "avionics", "control_bay":
			cu_mass = total_metal_kg * 0.35
			ti_mass = total_metal_kg * 0.25
			fe_mass = total_metal_kg * 0.20
		_:
			fe_mass = total_metal_kg * 0.40
			ti_mass = total_metal_kg * 0.20
			cu_mass = total_metal_kg * 0.10

	var fasteners := int(maxi(1, int(round(total_metal_kg * fasteners_mass_ratio_tune))))
	var power_kwh := total_metal_kg * power_kwh_per_kg_tune

	return {
		"fe_iron": fe_mass,
		"ti_titanium": ti_mass,
		"cu_copper": cu_mass,
		"w_tungsten": w_mass,
		"unthreaded_fasteners": fasteners,
		"power_kwh": power_kwh,
		"total_metal_kg": total_metal_kg
	}

## Calculates repair cost for a node based on its own mass and damage fraction
func calculate_repair_cost(mass_kg: float, damage_fraction: float, role: String) -> Dictionary:
	var frac := clampf(damage_fraction, 0.0, 1.0)
	if frac <= 0.001:
		return {
			"fe_iron": 0.0, "ti_titanium": 0.0, "cu_copper": 0.0, "w_tungsten": 0.0,
			"unthreaded_fasteners": 0, "power_kwh": 0.0
		}

	var effective_mass := maxf(1.0, mass_kg)
	var fe_needed := 0.0
	var ti_needed := 0.0
	var cu_needed := 0.0
	var w_needed := 0.0

	match role.to_lower():
		"armor", "defense", "torso_chassis", "pelvis_assembly", "shoulder_payload_left", "shoulder_payload_right":
			ti_needed = effective_mass * 0.40 * frac
			fe_needed = effective_mass * 0.25 * frac
		"power", "power_bay", "battery", "generator", "cooling":
			cu_needed = effective_mass * 0.40 * frac
			fe_needed = effective_mass * 0.20 * frac
		"weapon", "autocannon_30mm", "slag_rail_lance":
			w_needed = effective_mass * 0.30 * frac
			fe_needed = effective_mass * 0.30 * frac
		"sensor", "control", "avionics", "control_bay":
			cu_needed = effective_mass * 0.35 * frac
			ti_needed = effective_mass * 0.25 * frac
		_:
			fe_needed = effective_mass * 0.40 * frac
			ti_needed = effective_mass * 0.15 * frac
			cu_needed = effective_mass * 0.10 * frac

	var fasteners := int(maxi(1, int(effective_mass * fasteners_mass_ratio_repair * frac)))
	var power := frac * power_kwh_base_repair

	return {
		"fe_iron": fe_needed,
		"ti_titanium": ti_needed,
		"cu_copper": cu_needed,
		"w_tungsten": w_needed,
		"unthreaded_fasteners": fasteners,
		"power_kwh": power
	}
