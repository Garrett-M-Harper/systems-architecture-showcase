class_name RuntimePart
extends RefCounted

const RuntimeComponentScript = preload("runtime_component.gd")
const ItemPortContractScript = preload("item_port_contract.gd")
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
var contents: Dictionary[String, RuntimeComponent] = {}

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
	var name_str: String = str(definition.get("display_name", definition.get("name", definition_id)))
	var dur_str: String = "%d%%" % int(round(get_health_percentage() * 100.0))
	return "%s - %s - %s" % [q, name_str, dur_str]

func get_display_name() -> String:
	return str(definition.get("display_name", definition.get("name", definition_id)))

func get_full_display_name() -> String:
	return get_identity_string()

func get_quality_grade() -> String:
	return HardwareServiceTuningScript.get_quality_grade_static(quality)

func get_quality_multiplier() -> float:
	return 1.0 + _quality_identity_delta()

func _quality_identity_delta() -> float:
	return HardwareServiceTuningScript.get_stat_delta_static(quality, 0.15)



func get_tier_level() -> int:
	return 2

func get_health_percentage() -> float:
	return clampf(current_durability / max_durability, 0.0, 1.0) if max_durability > 0.0 else 0.0

func get_family_multiplier(target_family: String) -> float:
	var family: String = str(definition.get("family", definition.get("capability", "")))
	var role: String = str(definition.get("role", definition.get("part_type", "")))
	var matches_family := (family == target_family) or role.contains(target_family)
	if target_family == "drive" and ("locomotion" in role or "actuator" in role or "servo" in role or "linear" in role or "rotary" in role):
		matches_family = true
	if not matches_family:
		return 1.0
	var hp := get_health_percentage()
	if hp <= 0.0:
		return 0.0
	return 0.45 + 0.55 * hp

func get_sub_component(socket_id: String) -> RuntimeComponent:
	return contents.get(socket_id, null)

func _slot(socket_id: String) -> Dictionary:
	for value in definition.get("sockets", []):
		if value is Dictionary and str(value.get("slot_id", value.get("socket_id", ""))) == socket_id:
			return value
	return {}

func _contains(candidate: RuntimeComponent) -> bool:
	for child in contents.values():
		if child == candidate:
			return true
	return false

func _contains_item(candidate: RuntimeComponent) -> bool:
	return _contains(candidate)

const DISCIPLINE_COMPONENTS: Dictionary = {
	"kinematic": ["bearing", "spring", "bushing"],
	"energetic": ["cell", "coil", "capacitor"],
	"thermal_fluid": ["valve", "heatsink", "heat_sink", "conduit"],
	"structural": ["plate", "spar", "bracket"],
	"informational": ["diode", "optic", "optics", "crystal"]
}

static func _canonical_discipline(name: String) -> String:
	var d := name.to_lower().strip_edges()
	match d:
		"kinematic", "kinematics", "rotary_kinematics", "mechanical_compliance":
			return "kinematic"
		"energetic", "energy", "energetics", "power", "electromagnetic":
			return "energetic"
		"thermal_fluid", "thermal", "fluid", "fluidic", "thermodynamics":
			return "thermal_fluid"
		"structural", "structure", "metallurgy":
			return "structural"
		"informational", "information", "optics", "optic", "logic", "control":
			return "informational"
		_:
			return d

static func _candidate_matches_discipline(candidate: RuntimeComponent, discipline_key: String) -> bool:
	if not DISCIPLINE_COMPONENTS.has(discipline_key):
		return false
	var valid_types: Array = DISCIPLINE_COMPONENTS[discipline_key]

	# 1. Check component_type
	var c_type := str(candidate.definition.get("component_type", "")).to_lower().strip_edges()
	if c_type != "" and valid_types.has(c_type):
		return true

	# 2. Check discipline / domain
	var c_disc := _canonical_discipline(str(candidate.definition.get("discipline", candidate.definition.get("domain", ""))))
	if c_disc == discipline_key:
		return true

	# 3. Check family / category
	var c_fam := _canonical_discipline(str(candidate.definition.get("family", candidate.definition.get("category", ""))))
	if c_fam == discipline_key or valid_types.has(c_fam):
		return true

	# 4. Check tags
	var tags = candidate.definition.get("tags", [])
	if tags is Array:
		for tag in tags:
			var t_str := str(tag).to_lower().strip_edges()
			if t_str == discipline_key or _canonical_discipline(t_str) == discipline_key or valid_types.has(t_str):
				return true

	# 5. Check definition_id prefix/exact
	var def_id := candidate.definition_id.to_lower()
	for vt in valid_types:
		if def_id == vt or def_id.begins_with(vt + "_"):
			return true

	return false

func can_socket_accept(socket_id: String, candidate: RuntimeComponent) -> bool:
	if not candidate is RuntimeComponentScript or candidate == self:
		return false
	if candidate.owner != "" and not (candidate.owner == instance_id and contents.get(socket_id) == candidate):
		return false
	if not ItemPortContractScript.faction_insertion_allowed(definition, candidate.definition):
		return false
	var slot: Dictionary = _slot(socket_id)
	if slot.is_empty():
		return false
	for sock_key in contents.keys():
		if sock_key != socket_id and contents[sock_key] == candidate:
			return false
	if not _port_contract_matches(slot, candidate.definition):
		return false
	var accepts_kind := str(slot.get("accepts_kind", ""))
	var cand_kind := str(candidate.definition.get("kind", "component"))
	if (accepts_kind != "" and accepts_kind != "component") or cand_kind != "component":
		return false

	# Collect declared disciplines
	var declared_disciplines: Array[String] = []
	if slot.has("accepted_disciplines"):
		var raw_disc = slot.get("accepted_disciplines")
		if raw_disc is Array:
			for d in raw_disc:
				var cd := _canonical_discipline(str(d))
				if not declared_disciplines.has(cd):
					declared_disciplines.append(cd)
		elif raw_disc is String:
			var cd := _canonical_discipline(str(raw_disc))
			if not declared_disciplines.has(cd):
				declared_disciplines.append(cd)
	if slot.has("discipline") and str(slot["discipline"]) != "":
		var cd := _canonical_discipline(str(slot["discipline"]))
		if not declared_disciplines.has(cd):
			declared_disciplines.append(cd)
	if slot.has("accepted_domains"):
		for d in slot.get("accepted_domains", []):
			var cd := _canonical_discipline(str(d))
			if not declared_disciplines.has(cd):
				declared_disciplines.append(cd)
	if slot.has("domain") and str(slot["domain"]) != "":
		var cd := _canonical_discipline(str(slot["domain"]))
		if not declared_disciplines.has(cd):
			declared_disciplines.append(cd)

	var accepted: Array = slot.get("accepted_types", [])
	for t in accepted:
		var t_str := str(t).to_lower().strip_edges()
		var cd := _canonical_discipline(t_str)
		if DISCIPLINE_COMPONENTS.has(cd) and not declared_disciplines.has(cd):
			declared_disciplines.append(cd)

	var candidate_c_type := str(candidate.definition.get("component_type", "")).to_lower()
	var candidate_def_id := candidate.definition_id.to_lower()

	var discipline_match := false
	for d in declared_disciplines:
		if _candidate_matches_discipline(candidate, d):
			discipline_match = true
			break

	var type_match := false
	if not accepted.is_empty():
		for t in accepted:
			var t_str := str(t).to_lower()
			if t_str == candidate_c_type or t_str == candidate_def_id or t_str == candidate.definition_id:
				type_match = true
				break
			for d_key in DISCIPLINE_COMPONENTS.keys():
				if t_str == d_key and _candidate_matches_discipline(candidate, d_key):
					type_match = true
					break

	if not discipline_match and not type_match:
		if declared_disciplines.is_empty() and accepted.is_empty():
			var slot_role := str(slot.get("role", "")).to_lower()
			var cand_role := str(candidate.definition.get("role", "")).to_lower()
			if slot_role != "" and slot_role != cand_role:
				return false
		else:
			return false

	var canonical_component: bool = str(candidate.definition.get("interface_id", "")) == "component_standard" or discipline_match
	if not canonical_component and str(slot.get("role", "")) != "" and str(slot.get("role", "")) != str(candidate.definition.get("role", slot.get("role", ""))):
		return false
	if not canonical_component and str(slot.get("interface_id", "")) != "" and str(slot.get("interface_id", "")) != str(candidate.definition.get("interface_id", "")):
		return false
	if int(slot.get("interface_revision", candidate.definition.get("interface_revision", 0))) != int(candidate.definition.get("interface_revision", 0)):
		return false
	var limits: Dictionary = slot.get("limits", {})
	var mass: float = float(candidate.definition.get("own_mass_kg", candidate.definition.get("mass_kg", 0.0)))
	return not limits.has("max_mass_kg") or mass <= float(limits["max_mass_kg"])

func _port_contract_matches(slot: Dictionary, candidate_definition: Dictionary) -> bool:
	var consumer_value: Variant = slot.get("consumer_port", slot.get("port_contract", null))
	if consumer_value == null:
		return true
	if not consumer_value is Dictionary:
		return false
	var consumer = ItemPortContractScript.new(consumer_value)
	var producer_value: Variant = candidate_definition.get("producer_port", candidate_definition.get("port", null))
	if producer_value == null:
		var ports: Variant = candidate_definition.get("ports", [])
		if ports is Array and not ports.is_empty():
			producer_value = ports[0]
	if not producer_value is Dictionary:
		return false
	return ItemPortContractScript.new(producer_value).matches(consumer)

func install_component(socket_id: String, candidate: RuntimeComponent) -> bool:
	if not can_socket_accept(socket_id, candidate):
		return false
	var previous: RuntimeComponent = contents.get(socket_id, null)
	if previous == candidate:
		return true
	if candidate.owner != "" and candidate.owner != instance_id:
		return false
	if previous != null:
		remove_component(socket_id)
	contents[socket_id] = candidate
	candidate.owner = instance_id
	return true

func install_sub_component(socket_id: String, candidate: RuntimeComponent) -> bool:
	return install_component(socket_id, candidate)

func swap_component(socket_id: String, candidate: RuntimeComponent) -> RuntimeComponent:
	var previous: RuntimeComponent = contents.get(socket_id, null)
	if not install_component(socket_id, candidate):
		return null
	return previous

func remove_component(socket_id: String) -> RuntimeComponent:
	if not contents.has(socket_id):
		return null
	var removed: RuntimeComponent = contents[socket_id]
	contents.erase(socket_id)
	if removed.owner == instance_id:
		removed.owner = ""
	return removed

func remove_sub_component(socket_id: String) -> RuntimeComponent:
	return remove_component(socket_id)

func is_operational() -> bool:
	if current_durability <= 0.0 or runtime_state == "destroyed":
		return false
	for slot_value in definition.get("sockets", []):
		if bool(slot_value.get("required", false)):
			var child: RuntimeComponent = contents.get(str(slot_value.get("slot_id", slot_value.get("socket_id", ""))), null)
			if child == null or not child.is_operational():
				return false
	return true

func get_resolved_stat(stat_name: String) -> float:
	if not is_operational():
		return 0.0
	var total: float = 0.0
	for child in contents.values():
		total += child.get_resolved_stat(stat_name)
	var stats: Variant = definition.get("base_stats", {})
	if stats is Dictionary:
		total += float(stats.get(stat_name, 0.0))
	return total * get_health_percentage()

func get_total_mass() -> float:
	var total: float = float(definition.get("own_mass_kg", definition.get("mass_kg", 0.0)))
	for child in contents.values():
		total += child.get_total_mass()
	return total

func get_aggregated_stat(stat_name: String) -> float:
	var total: float = 0.0
	var stats: Variant = definition.get("stats", definition.get("base_stats", {}))
	if stats is Dictionary:
		total += float(stats.get(stat_name, 0.0))
	for child in contents.values():
		total += child.get_aggregated_stat(stat_name)
	return total

func repair_to_full(recursive: bool = true) -> void:
	current_durability = max_durability
	runtime_state = "active"
	if recursive:
		for child in contents.values():
			child.repair_to_full(true)

func take_damage(amount: float, damage_type: String = "kinetic") -> void:
	if current_durability <= 0.0 or amount <= 0.0:
		return

	# 1. Part Housing Enclosure absorbs baseline shock
	var housing_defense: float = float(definition.get("housing_defense_rating", definition.get("housing_armor_absorption", 10.0)))
	var health_ratio := get_health_percentage()
	var effective_housing_defense := housing_defense * health_ratio
	var housing_mitigated_damage: float = maxf(amount - effective_housing_defense, amount * 0.15)

	var was_alive := current_durability > 0.0
	current_durability = maxf(0.0, current_durability - housing_mitigated_damage)
	if current_durability <= 0.0:
		current_durability = 0.0
		runtime_state = "destroyed"
		if was_alive:
			apply_destruction_scar()

	# 2. Bleed residual shock to socketed components weighted by fragility

	var component_bleed_base: float = housing_mitigated_damage * 0.20
	if component_bleed_base > 0.1:
		for child in contents.values():
			var comp: RuntimeComponent = child
			if comp == null:
				continue
			var fragility: float = float(comp.definition.get("fragility_multiplier", 1.0))
			var comp_family: String = str(comp.definition.get("category", comp.definition.get("family", ""))).to_lower()
			if comp_family in ["control", "optics", "sensor"]:
				fragility = maxf(fragility, 1.6)
			elif comp_family in ["fluidic", "hydraulic", "seal"]:
				fragility = maxf(fragility, 1.3)
			elif comp_family in ["structural", "spar", "clevis"]:
				fragility = minf(fragility, 0.6)

			comp.take_damage(component_bleed_base * fragility, damage_type)

func get_current_assembly_snapshot(include_current_state: bool = true) -> Dictionary:
	var snapshot: Dictionary = {"definition_id": definition_id, "sockets": {}}
	if include_current_state:
		snapshot["current_durability"] = current_durability
		snapshot["max_durability"] = max_durability
		snapshot["runtime_state"] = runtime_state
	for socket_id in contents.keys():
		snapshot["sockets"][str(socket_id)] = contents[socket_id].get_current_assembly_snapshot(include_current_state)
	return snapshot

func get_canonical_tree_digest() -> String:
	var result: String = "%s|%s|%.6f|%.2f|%s" % ["", definition_id, current_durability, quality, runtime_state]
	for socket_id in contents.keys():
		result += "\n" + contents[socket_id].get_canonical_tree_digest()
	return result

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
