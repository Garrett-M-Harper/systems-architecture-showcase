class_name RuntimeComponent
extends RefCounted

const HardwareServiceTuningScript = preload("hardware_service_tuning.gd")

var instance_id: String = ""
var definition_id: String = ""
var definition: Dictionary = {}
var owner: String = ""
var quality: float = 50.0
var quality_grade: String = "C"
var current_durability: float = 0.0
var max_durability: float = 0.0
var runtime_state: String = "active"
var serial_number: String = ""
var factory_identity: Dictionary = {}
var service_record: Dictionary = {
	"scar_count": 0,
	"overhaul_count": 0,
	"tune_points_applied": 0
}
static var _sequence: int = 0

func _init(def_id: String, def_data: Dictionary) -> void:
	_sequence += 1
	instance_id = "%s_%s_%s" % [def_id, str(Time.get_ticks_usec()), str(_sequence)]
	definition_id = def_id
	definition = def_data.duplicate(true)
	max_durability = float(definition.get("max_durability", 100.0))
	current_durability = max_durability

	var def_grade := str(definition.get("quality_grade", "C"))
	var build_seed := int(definition.get("factory_build_seed", hash(instance_id)))
	if definition.has("base_quality"):
		quality = float(definition["base_quality"])
	else:
		quality = HardwareServiceTuningScript.derive_quality_from_grade(def_grade, build_seed)
	quality_grade = get_quality_grade()

	serial_number = str(definition.get("serial_number", instance_id))
	factory_identity = {
		"definition_id": definition_id,
		"serial_number": serial_number,
		"quality_grade": def_grade
	}

## Formats strict industrial identity schema: (Quality - Name - Durability) [NO prefixes/suffixes]
func get_identity_string() -> String:
	var q: String = quality_grade.to_upper()
	var name_str: String = str(definition.get("display_name", definition_id))
	var dur_str: String = "%d%%" % int(round(get_health_percentage() * 100.0))
	return "%s - %s - %s" % [q, name_str, dur_str]

func get_quality_grade() -> String:
	return HardwareServiceTuningScript.get_quality_grade_static(quality)

func get_quality_multiplier() -> float:
	return 1.0 + _quality_identity_delta()

func _quality_identity_delta() -> float:
	return HardwareServiceTuningScript.get_stat_delta_static(quality, 0.15)



func get_tier_level() -> int:
	return 3

func get_health_percentage() -> float:
	return clampf(current_durability / max_durability, 0.0, 1.0) if max_durability > 0.0 else 0.0

func is_operational() -> bool:
	return current_durability > 0.0 and runtime_state != "destroyed"

func get_sub_component(_socket_id: String) -> RuntimeComponent:
	return null

func can_socket_accept(_socket_id: String, _candidate: RuntimeComponent) -> bool:
	return false

func install_sub_component(_socket_id: String, _candidate: RuntimeComponent) -> bool:
	return false

func remove_sub_component(_socket_id: String) -> RuntimeComponent:
	return null

func get_resolved_stat(stat_name: String) -> float:
	if not is_operational():
		return 0.0
	var base_val := 0.0
	var stats: Variant = definition.get("base_stats", {})
	if stats is Dictionary and stats.has(stat_name):
		base_val = float(stats[stat_name])
	else:
		base_val = float(definition.get(stat_name, 0.0))
	return base_val * get_health_percentage() * get_quality_multiplier()

func get_total_mass() -> float:
	return float(definition.get("own_mass_kg", definition.get("mass_kg", 0.0)))

func get_aggregated_stat(stat_name: String) -> float:
	var stats: Variant = definition.get("stats", definition.get("base_stats", {}))
	return float(stats.get(stat_name, 0.0)) if stats is Dictionary else 0.0

func repair_to_full(_recursive: bool = true) -> void:
	current_durability = max_durability
	runtime_state = "active"

func take_damage(amount: float, _damage_type: String = "kinetic") -> void:
	if current_durability <= 0.0 or amount <= 0.0:
		return
	var was_alive := current_durability > 0.0
	current_durability = maxf(0.0, current_durability - amount)
	if current_durability <= 0.0:
		current_durability = 0.0
		runtime_state = "destroyed"
		if was_alive:
			apply_destruction_scar()

## Permanently drops one quality letter grade to the lower floor upon complete destruction
func apply_destruction_scar() -> void:
	var current_g := get_quality_grade()
	if current_g == "F":
		return
	var lower_g: String = HardwareServiceTuningScript.get_lower_grade_static(current_g)
	quality = HardwareServiceTuningScript.get_grade_floor_static(lower_g)
	quality_grade = lower_g
	service_record["scar_count"] = int(service_record.get("scar_count", 0)) + 1
	print("[%s] Destruction scarring: dropped from Grade %s to %s (%.1f%%)" % [definition_id, current_g, lower_g, quality])



func get_current_assembly_snapshot(include_current_state: bool = true) -> Dictionary:
	var snapshot: Dictionary = {"definition_id": definition_id, "sockets": {}}
	if include_current_state:
		snapshot["current_durability"] = current_durability
		snapshot["max_durability"] = max_durability
		snapshot["runtime_state"] = runtime_state
	return snapshot

func get_canonical_tree_digest() -> String:
	return "%s|%s|%.6f|%.2f|%s" % ["", definition_id, current_durability, quality, runtime_state]
