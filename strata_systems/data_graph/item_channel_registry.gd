class_name ItemChannelRegistry
extends RefCounted

class ChannelSpec:
	extends RefCounted
	var channel_id: String
	var domain: String
	var unit: String
	var dimension: String
	var role: String

	func _init(id: String, channel_domain: String, channel_unit: String, channel_dimension: String, channel_role: String = "") -> void:
		channel_id = id
		domain = channel_domain
		unit = channel_unit
		dimension = channel_dimension
		role = channel_role if not channel_role.is_empty() else ("resistance" if channel_dimension == "resistance" else ("rating" if channel_dimension == "rating" else "capability"))

	func to_dict() -> Dictionary:
		return {"channel_id": channel_id, "domain": domain, "unit": unit, "dimension": dimension, "role": role}

const _CHANNEL_ROWS: Array = [
	["drive_force_kn", "motion", "kN", "force"], ["manipulator_force_n", "motion", "N", "force"], ["locomotion_traction_force_n", "motion", "N", "force"],
	["limb_control_bandwidth_hz", "motion", "Hz", "bandwidth"], ["leg_control_bandwidth_hz", "motion", "Hz", "bandwidth"], ["limb_allowable_load_n", "motion", "N", "force"],
	["leg_allowable_load_n", "motion", "N", "force"], ["pelvis_allowable_load_n", "motion", "N", "force"], ["hip_control_bandwidth_hz", "motion", "Hz", "bandwidth"],
	["sensor_range_m", "sensing", "m", "distance"], ["sensor_bandwidth_ghz", "sensing", "GHz", "bandwidth"],
	["heat_dissipation_kw", "thermal", "kW", "power"], ["thermal_capacity_kj", "thermal", "kJ", "energy"], ["heat_generation_kw", "thermal", "kW", "power"],
	["power_storage_mj", "electrical power", "MJ", "energy"], ["power_generation_kw", "electrical power", "kW", "power"], ["peak_discharge_kw", "electrical power", "kW", "power"], ["power_draw_kw", "electrical power", "kW", "power"],
	["oxygen_capacity_l", "life support", "L", "volume"], ["scrub_rate_lpm", "life support", "L/min", "flow"],
	["data_bandwidth_gbps", "control", "Gbps", "bandwidth"], ["control_bandwidth_hz", "control", "Hz", "bandwidth"], ["fire_control_rating", "control", "rating units", "rating"],
	["feed_rate_rounds_s", "weapon", "rounds/s", "rate"], ["recoil_absorption", "weapon", "rating units", "rating"],
	["booster_thrust_kn", "booster", "kN", "force"], ["booster_control_rating", "booster", "rating units", "rating"],
	["winch_force_kn", "tether", "kN", "force"], ["tether_length_m", "tether", "m", "distance"], ["winch_speed_mps", "tether", "m/s", "speed"],
	["cargo_limit_kg", "structure", "kg", "mass"], ["structural_integrity_hp", "structure", "HP", "integrity"], ["kinetic_res", "structure", "resistance units", "resistance"], ["thermal_res", "structure", "resistance units", "resistance"]
]

static func all_channels() -> Dictionary:
	var result: Dictionary = {}
	for row in _CHANNEL_ROWS:
		result[row[0]] = ChannelSpec.new(row[0], row[1], row[2], row[3])
	return result

static func get_channel(channel_id: String) -> ChannelSpec:
	for row in _CHANNEL_ROWS:
		if row[0] == channel_id:
			return ChannelSpec.new(row[0], row[1], row[2], row[3])
	return null

static func validate_channel(channel_id: String, domain: String, unit: String) -> String:
	var spec: ChannelSpec = get_channel(channel_id)
	if spec == null:
		return "unknown_channel"
	if spec.domain != domain:
		return "domain_mismatch"
	if spec.unit != unit:
		return "unit_mismatch"
	return ""

static func family_output_channels(family: String) -> Array:
	var contracts: Dictionary = {
		"drive": ["drive_force_kn", "manipulator_force_n", "locomotion_traction_force_n", "limb_control_bandwidth_hz", "leg_control_bandwidth_hz", "limb_allowable_load_n", "leg_allowable_load_n", "pelvis_allowable_load_n", "hip_control_bandwidth_hz", "power_draw_kw", "heat_generation_kw"],
		"frame": ["structural_integrity_hp", "kinetic_res", "thermal_res"], "utility": [], "sensor": ["sensor_range_m", "sensor_bandwidth_ghz", "power_draw_kw", "heat_generation_kw"],
		"control": ["data_bandwidth_gbps", "control_bandwidth_hz", "fire_control_rating", "power_draw_kw", "heat_generation_kw"], "power": ["power_storage_mj", "power_generation_kw", "peak_discharge_kw", "power_draw_kw", "heat_generation_kw"],
		"thermal": ["heat_dissipation_kw", "thermal_capacity_kj", "heat_generation_kw", "power_draw_kw"], "weapon": ["feed_rate_rounds_s", "recoil_absorption", "power_draw_kw", "heat_generation_kw"],
		"booster": ["booster_thrust_kn", "booster_control_rating", "power_draw_kw", "heat_generation_kw"], "tether": ["winch_force_kn", "tether_length_m", "winch_speed_mps", "power_draw_kw", "heat_generation_kw"],
		"structure": ["cargo_limit_kg", "structural_integrity_hp", "kinetic_res", "thermal_res"]
	}
	return (contracts.get(family, []) as Array).duplicate()

static func is_registered_family(family: String) -> bool:
	return not family_output_channels(family).is_empty() or family in ["utility"]
