class_name ItemPortContract
extends RefCounted

const Registry = preload("item_channel_registry.gd")

var port_id: String = ""
var direction: String = ""
var domain: String = ""
var family: String = ""
var channel_set: Array[String] = []
var channel_units: Dictionary = {}
var interface_id: String = ""
var interface_revision: int = 0
var role: String = ""
var required: bool = false
var limits: Dictionary = {}

func _init(source: Dictionary = {}) -> void:
	port_id = str(source.get("port_id", ""))
	direction = str(source.get("direction", ""))
	domain = str(source.get("domain", ""))
	family = str(source.get("family", ""))
	for channel in source.get("channel_set", []):
		channel_set.append(str(channel))
	channel_set.sort()
	var source_units: Variant = source.get("channel_units", source.get("units", {}))
	channel_units = source_units.duplicate(true) if source_units is Dictionary else {}
	interface_id = str(source.get("interface_id", ""))
	interface_revision = int(source.get("interface_revision", 0))
	role = str(source.get("role", ""))
	required = bool(source.get("required", false))
	var limits_value: Variant = source.get("limits", {})
	limits = limits_value.duplicate(true) if limits_value is Dictionary else {}

func matches(other: ItemPortContract) -> bool:
	return explain_mismatch(other).is_empty()

func explain_mismatch(other: ItemPortContract) -> String:
	if other == null:
		return "missing_port"
	if not ((direction == "out" and other.direction == "in") or (direction == "bidirectional" and other.direction == "bidirectional")):
		return "direction"
	if domain != other.domain:
		return "domain"
	if family != other.family:
		return "family"
	if role != other.role:
		return "role"
	if channel_set != other.channel_set:
		return "channel_set"
	for channel_id in channel_set:
		var spec = Registry.get_channel(str(channel_id))
		if spec == null or not channel_units.has(str(channel_id)) or not other.channel_units.has(str(channel_id)):
			return "unit"
		if str(channel_units[str(channel_id)]) != spec.unit or str(other.channel_units[str(channel_id)]) != spec.unit:
			return "unit"
	if channel_units != other.channel_units:
		return "unit"
	if interface_id != other.interface_id:
		return "interface_id"
	if interface_revision != other.interface_revision:
		return "interface_revision"
	if limits != other.limits:
		return "limits"
	return ""

func to_dict() -> Dictionary:
	return {"port_id": port_id, "direction": direction, "domain": domain, "family": family, "channel_set": channel_set.duplicate(), "channel_units": channel_units.duplicate(true), "interface_id": interface_id, "interface_revision": interface_revision, "role": role, "required": required, "limits": limits.duplicate(true)}

func serialize_canonical() -> String:
	return JSON.stringify(to_dict())

static func faction_insertion_allowed(parent_definition: Dictionary, child_definition: Dictionary) -> bool:
	if str(child_definition.get("interface_id", "")) != "faction_frame_v1":
		return true
	if str(parent_definition.get("kind", "")) != "item" or str(parent_definition.get("family", "")) != "frame":
		return false
	var parent_faction: String = str(parent_definition.get("faction_id", ""))
	var child_faction: String = str(child_definition.get("faction_id", ""))
	if parent_faction.is_empty() or child_faction.is_empty() or parent_faction != child_faction:
		return false
	return str(child_definition.get("family", "")) == "frame"
