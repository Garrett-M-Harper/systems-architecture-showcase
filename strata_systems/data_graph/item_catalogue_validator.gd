class_name ItemCatalogueValidator
extends RefCounted

const Registry = preload("item_channel_registry.gd")
const PortContract = preload("item_port_contract.gd")

static func validate_definition(definition: Variant, definitions: Array = []) -> Dictionary:
	var report: Dictionary = {"valid": true, "definition_id": str(definition.get("definition_id", "")) if definition is Dictionary else "", "errors": []}
	var errors: Array = report["errors"]
	if not (definition is Dictionary):
		errors.append(_error("malformed_definition", "", "definition", "definition must be a Dictionary"))
		report["valid"] = false
		return report
	_validate_shape(definition, errors)
	_validate_ports(definition, errors)
	_validate_sockets(definition, definitions, errors)
	_validate_outputs(definition, errors)
	_validate_definition_children(definition, definitions, errors)
	_sort_errors(errors)
	report["valid"] = errors.is_empty()
	return report

static func validate_catalogue(definitions: Variant) -> Dictionary:
	var errors: Array = []
	if not definitions is Array:
		errors.append(_error("malformed_catalogue", "", "definitions", "definitions must be an Array"))
		return {"valid": false, "errors": errors, "definition_count": 0}
	var by_id: Dictionary = {}
	for raw_index in range(definitions.size()):
		var definition: Variant = definitions[raw_index]
		if not (definition is Dictionary):
			errors.append(_error("malformed_definition", "", "definitions[%d]" % raw_index, "definition must be a Dictionary"))
			continue
		var definition_id: String = str(definition.get("definition_id", ""))
		if by_id.has(definition_id):
			errors.append(_error("duplicate_definition", definition_id, "definitions[%d]/definition_id" % raw_index, "definition IDs must be unique in raw catalogue order"))
		by_id[definition_id] = definition
	for definition in definitions:
		if not (definition is Dictionary):
			continue
		var result: Dictionary = validate_definition(definition, definitions)
		errors.append_array(result.get("errors", []))
	_validate_topology(definitions, by_id, errors)
	_validate_canonical_bundle(definitions, by_id, errors)
	_sort_errors(errors)
	var legacy_count: int = 0
	for definition in definitions:
		if definition is Dictionary and not _is_canonical_definition(definition):
			legacy_count += 1
	return {"valid": errors.is_empty(), "errors": errors, "definition_count": definitions.size(), "canonical": legacy_count == 0, "advisory_legacy": legacy_count > 0, "legacy_definition_count": legacy_count, "scope_notes": ["RuntimeItem enforcement belongs to P2", "numeric output explainability and conservation belong to P3"]}

static func _error(code: String, definition_id: String, path: String, message: String) -> Dictionary:
	return {"code": code, "definition_id": definition_id, "path": path, "message": message}

static func _validate_shape(definition: Dictionary, errors: Array) -> void:
	var definition_id: String = str(definition.get("definition_id", ""))
	var kind: String = str(definition.get("kind", ""))
	if definition_id.is_empty(): errors.append(_error("missing_definition_id", definition_id, "definition_id", "definition_id is required"))
	if not kind in ["item", "part", "component"]: errors.append(_error("unknown_kind", definition_id, "kind", "kind must be item, part, or component"))
	if str(definition.get("family", "")).is_empty(): errors.append(_error("missing_family", definition_id, "family", "family is required"))
	elif not Registry.is_registered_family(str(definition.get("family", ""))): errors.append(_error("unregistered_family", definition_id, "family", "family has no authoritative output contract"))
	if str(definition.get("interface_id", "")) == "faction_frame_v1":
		if str(definition.get("family", "")) != "frame" or str(definition.get("faction_id", "")).is_empty():
			errors.append(_error("faction_metadata", definition_id, "faction_id", "faction frame definitions require frame family and explicit faction_id"))

static func _validate_ports(definition: Dictionary, errors: Array) -> void:
	var definition_id: String = str(definition.get("definition_id", ""))
	var seen: Dictionary = {}
	var ports_value: Variant = definition.get("ports", [])
	if not (ports_value is Array):
		errors.append(_error("malformed_ports", definition_id, "ports", "ports must be an Array"))
		return
	var ports: Array = ports_value
	for index in range(ports.size()):
		var raw_value: Variant = ports[index]
		var path: String = "ports[%d]" % index
		if not (raw_value is Dictionary):
			errors.append(_error("malformed_port", definition_id, path, "port must be a Dictionary"))
			continue
		var raw: Dictionary = raw_value
		for required_port_field in ["limits", "required"]:
			if not raw.has(required_port_field):
				errors.append(_error("missing_port_field", definition_id, path + "/" + required_port_field, "port field is required and cannot default"))
		var channel_set_value: Variant = raw.get("channel_set", [])
		if not (channel_set_value is Array):
			errors.append(_error("malformed_channel_set", definition_id, path + "/channel_set", "channel_set must be an Array"))
			continue
		var port: ItemPortContract = PortContract.new(raw)
		if port.port_id.is_empty() or seen.has(port.port_id): errors.append(_error("duplicate_port" if seen.has(port.port_id) else "missing_port_id", definition_id, path, "port IDs must be present and unique"))
		seen[port.port_id] = true
		if not port.direction in ["in", "out", "bidirectional"]: errors.append(_error("invalid_direction", definition_id, path + "/direction", "invalid port direction"))
		if port.domain.is_empty(): errors.append(_error("missing_port_domain", definition_id, path + "/domain", "port domain is required"))
		if port.family.is_empty(): errors.append(_error("missing_port_family", definition_id, path + "/family", "port family is required"))
		if port.role.is_empty(): errors.append(_error("missing_port_role", definition_id, path + "/role", "port role is required"))
		if port.interface_id.is_empty() or port.interface_revision < 1: errors.append(_error("invalid_interface", definition_id, path + "/interface", "interface ID and positive revision are required"))
		if port.channel_set.is_empty(): errors.append(_error("missing_channel_set", definition_id, path + "/channel_set", "port channel set is required"))
		var channel_set: Array = channel_set_value
		var units_value: Variant = raw.get("channel_units", raw.get("units", {}))
		var channel_units: Dictionary = units_value if units_value is Dictionary else {}
		if not (units_value is Dictionary): errors.append(_error("malformed_units", definition_id, path + "/channel_units", "channel units must be a Dictionary"))
		for channel_id in channel_set:
			var spec = Registry.get_channel(str(channel_id))
			if spec == null: errors.append(_error("unknown_channel", definition_id, path + "/channel_set", "channel is not canonical"))
			elif spec.domain != port.domain: errors.append(_error("domain_mismatch", definition_id, path + "/channel_set", "channel domain does not match port"))
			elif not channel_units.has(str(channel_id)): errors.append(_error("missing_channel_unit", definition_id, path + "/channel_units", "every channel requires its canonical unit"))
			elif channel_units.has(str(channel_id)) and str(channel_units[str(channel_id)]) != spec.unit: errors.append(_error("unit_mismatch", definition_id, path + "/channel_units", "channel unit is not canonical"))
		var unique_channels: Dictionary = {}
		for channel_id in channel_set:
			if unique_channels.has(str(channel_id)):
				errors.append(_error("duplicate_channel", definition_id, path + "/channel_set", "channel IDs must be unique"))
			unique_channels[str(channel_id)] = true
		for unit_channel in channel_units.keys():
			if not channel_set.has(str(unit_channel)):
				errors.append(_error("extra_channel_unit", definition_id, path + "/channel_units/%s" % unit_channel, "unit map cannot contain undeclared channels"))

static func _validate_sockets(definition: Dictionary, definitions: Array, errors: Array) -> void:
	var definition_id: String = str(definition.get("definition_id", ""))
	var seen: Dictionary = {}
	var sockets_value: Variant = definition.get("sockets", [])
	if not (sockets_value is Array):
		errors.append(_error("malformed_sockets", definition_id, "sockets", "sockets must be an Array"))
		return
	var sockets: Array = sockets_value
	for index in range(sockets.size()):
		var raw_socket: Variant = sockets[index]
		var path: String = "sockets[%d]" % index
		if not (raw_socket is Dictionary):
			errors.append(_error("malformed_socket", definition_id, path, "socket must be a Dictionary"))
			continue
		var socket: Dictionary = raw_socket
		var socket_id: String = str(socket.get("slot_id", socket.get("socket_id", "")))
		if socket_id.is_empty() or seen.has(socket_id): errors.append(_error("duplicate_socket", definition_id, path, "socket IDs must be present and unique"))
		seen[socket_id] = true
		var accepted_types_value: Variant = socket.get("accepted_types", [])
		var accepted_types: Array = accepted_types_value if accepted_types_value is Array else []
		if bool(socket.get("required", false)) and (not (accepted_types_value is Array) or accepted_types.is_empty() or str(socket.get("accepts_kind", "")).is_empty()): errors.append(_error("required_socket_untyped", definition_id, path, "required socket must declare accepted kind and non-empty accepted types"))
		for field in ["port_id", "interface_id", "interface_revision", "direction", "domain", "family", "role", "channel_set", "channel_units", "limits"]:
			if not socket.has(field) or socket[field] == null or (socket[field] is String and str(socket[field]).is_empty()):
				errors.append(_error("socket_contract_incomplete", definition_id, path + "/" + field, "socket must declare its complete typed port contract"))
		if int(socket.get("interface_revision", 0)) < 1:
			errors.append(_error("invalid_socket_revision", definition_id, path + "/interface_revision", "socket interface revision must be positive"))
		if not str(socket.get("direction", "")) in ["in", "out", "bidirectional"]:
			errors.append(_error("invalid_socket_direction", definition_id, path + "/direction", "socket direction is invalid"))
		var socket_channels_value: Variant = socket.get("channel_set", [])
		var socket_units_value: Variant = socket.get("channel_units", {})
		if socket_channels_value is Array and socket_units_value is Dictionary:
			for socket_channel in socket_channels_value:
				var socket_spec = Registry.get_channel(str(socket_channel))
				if socket_spec == null:
					errors.append(_error("socket_channel_unknown", definition_id, path + "/channel_set", "socket channel is not canonical"))
				elif socket_spec.domain != str(socket.get("domain", "")):
					errors.append(_error("socket_channel_domain", definition_id, path + "/domain", "socket channel domain does not match declaration"))
				elif not socket_units_value.has(str(socket_channel)) or str(socket_units_value[str(socket_channel)]) != socket_spec.unit:
					errors.append(_error("socket_channel_unit", definition_id, path + "/channel_units", "socket channel unit is not canonical"))

static func _validate_outputs(definition: Dictionary, errors: Array) -> void:
	var definition_id: String = str(definition.get("definition_id", ""))
	var outputs_value: Variant = definition.get("outputs", definition.get("base_stats", {}))
	if not (outputs_value is Dictionary):
		errors.append(_error("malformed_outputs", definition_id, "outputs", "outputs must be a Dictionary"))
		return
	var outputs: Dictionary = outputs_value
	if not _is_canonical_definition(definition):
		return
	var output_units_value: Variant = definition.get("output_units", {})
	var output_units: Dictionary = output_units_value if output_units_value is Dictionary else {}
	if not (output_units_value is Dictionary):
		errors.append(_error("missing_output_units", definition_id, "output_units", "canonical outputs require an output_units Dictionary"))
	for channel_id in outputs.keys():
		var spec = Registry.get_channel(str(channel_id))
		if spec != null and (not output_units.has(str(channel_id)) or str(output_units[str(channel_id)]) != spec.unit):
			errors.append(_error("output_unit_mismatch", definition_id, "output_units/%s" % channel_id, "every canonical output requires its registry unit"))
	if str(definition.get("kind", "")) == "part":
		var roles_value: Variant = definition.get("required_contributor_roles", [])
		var transfers_value: Variant = definition.get("transfers", {})
		var roles: Array = roles_value if roles_value is Array else []
		var transfers: Dictionary = transfers_value if transfers_value is Dictionary else {}
		if not (roles_value is Array) or roles.is_empty(): errors.append(_error("missing_contributor_roles", definition_id, "required_contributor_roles", "Part must declare required contributor roles"))
		if not (transfers_value is Dictionary): errors.append(_error("missing_transfers", definition_id, "transfers", "Part must declare one transfer per emitted channel"))
		for channel_id in outputs.keys():
			if not transfers.has(str(channel_id)): errors.append(_error("missing_transfer", definition_id, "transfers/%s" % channel_id, "Part output must have exactly one declared transfer"))
		for transfer_channel in transfers.keys():
			if not outputs.has(str(transfer_channel)): errors.append(_error("extra_transfer", definition_id, "transfers/%s" % transfer_channel, "Part transfers must exactly match emitted output channels"))
			var transfer_value: Variant = transfers[transfer_channel]
			if not (transfer_value is int or transfer_value is float) or not is_finite(float(transfer_value)):
				errors.append(_error("invalid_transfer", definition_id, "transfers/%s" % transfer_channel, "Part transfers must be finite numeric values"))
		var actual_roles: Array[String] = []
		var sockets_value: Variant = definition.get("sockets", [])
		if sockets_value is Array:
			for socket_value in sockets_value:
				if socket_value is Dictionary and bool(socket_value.get("required", false)):
					var socket_role: String = str(socket_value.get("role", ""))
					if not socket_role.is_empty() and not actual_roles.has(socket_role): actual_roles.append(socket_role)
			actual_roles.sort()
		var declared_roles: Array[String] = []
		for role_value in roles:
			var role_name: String = str(role_value)
			if declared_roles.has(role_name): errors.append(_error("contributor_roles_duplicate", definition_id, "required_contributor_roles", "contributor roles cannot contain duplicates"))
			declared_roles.append(role_name)
		declared_roles.sort()
		if declared_roles != actual_roles: errors.append(_error("contributor_roles_mismatch", definition_id, "required_contributor_roles", "declared contributor roles must match required socket roles"))
	var legal_outputs: Array = Registry.family_output_channels(str(definition.get("family", "")))
	for channel_id in outputs.keys():
		if Registry.get_channel(str(channel_id)) == null: errors.append(_error("undeclared_output", definition_id, "outputs/%s" % channel_id, "output channel is not canonical"))
		elif not legal_outputs.has(str(channel_id)): errors.append(_error("family_output_bound", definition_id, "outputs/%s" % channel_id, "output is outside registered family contract"))
	var declared_value: Variant = definition.get("declared_outputs", [])
	var declared: Array = declared_value if declared_value is Array else []
	if not (declared_value is Array):
		errors.append(_error("malformed_declared_outputs", definition_id, "declared_outputs", "declared_outputs must be an Array"))
	var output_keys: Array[String] = []
	for output_key in outputs.keys(): output_keys.append(str(output_key))
	output_keys.sort()
	var declared_keys: Array[String] = []
	for declared_key in declared: declared_keys.append(str(declared_key))
	declared_keys.sort()
	if declared_keys != output_keys:
		errors.append(_error("declared_outputs_mismatch", definition_id, "declared_outputs", "declared_outputs must exactly match emitted outputs"))
	for channel_id in outputs.keys():
		if not declared.is_empty() and not str(channel_id) in declared: errors.append(_error("family_output_bound", definition_id, "outputs/%s" % channel_id, "output is outside family declaration"))

static func _validate_definition_children(definition: Dictionary, definitions: Array, errors: Array) -> void:
	var definition_id: String = str(definition.get("definition_id", ""))
	var by_id: Dictionary = {}
	for candidate in definitions:
		if candidate is Dictionary:
			by_id[str(candidate.get("definition_id", ""))] = candidate
	var sockets: Dictionary = {}
	var sockets_value: Variant = definition.get("sockets", [])
	if not (sockets_value is Array):
		return
	for socket in sockets_value:
		if socket is Dictionary:
			sockets[str(socket.get("slot_id", socket.get("socket_id", "")))] = socket
	var counts: Dictionary = {}
	var children_value: Variant = definition.get("default_contents", [])
	if not (children_value is Array):
		errors.append(_error("malformed_children", definition_id, "default_contents", "default_contents must be an Array"))
		return
	for child in children_value:
		if not (child is Dictionary):
			errors.append(_error("malformed_child", definition_id, "default_contents", "child entry must be a Dictionary"))
			continue
		var socket_id: String = str(child.get("socket_id", ""))
		counts[socket_id] = int(counts.get(socket_id, 0)) + 1
		if not sockets.has(socket_id): errors.append(_error("unknown_socket", definition_id, "default_contents/%s" % socket_id, "child references an unknown socket")); continue
		var child_id: String = str(child.get("definition_id", ""))
		if not by_id.has(child_id): errors.append(_error("missing_child_definition", definition_id, "default_contents/%s" % socket_id, "child definition is absent")); continue
		var child_def: Dictionary = by_id[child_id]
		var socket: Dictionary = sockets[socket_id]
		var parent_kind: String = str(definition.get("kind", ""))
		var child_kind: String = str(child_def.get("kind", ""))
		var expected_kind: String = "part" if parent_kind == "item" else ("component" if parent_kind == "part" else "")
		if expected_kind.is_empty():
			errors.append(_error("component_children_forbidden", definition_id, "default_contents/%s" % socket_id, "Component definitions cannot own children"))
		elif child_kind != expected_kind:
			errors.append(_error("containment_kind_mismatch", definition_id, "default_contents/%s" % socket_id, "containment must be Item -> Part -> Component"))
		if not PortContract.faction_insertion_allowed(definition, child_def): errors.append(_error("faction_frame_mismatch", definition_id, "default_contents/%s" % socket_id, "faction frame Part is not allowed in this Item"))
		if str(child_def.get("kind", "")) != str(socket.get("accepts_kind", "")): errors.append(_error("kind_mismatch", definition_id, "default_contents/%s" % socket_id, "child kind does not match socket"))
		var accepted_types_value: Variant = socket.get("accepted_types", [])
		var accepted_types: Array = accepted_types_value if accepted_types_value is Array else []
		if not accepted_types.is_empty() and str(child_def.get("component_type", child_def.get("part_type", child_def.get("item_type", "")))) not in accepted_types: errors.append(_error("type_mismatch", definition_id, "default_contents/%s" % socket_id, "child type is not accepted"))
		_validate_socket_connection(definition, child_def, socket, errors)
	for socket_id in sockets:
		if bool(sockets[socket_id].get("required", false)) and int(counts.get(socket_id, 0)) != 1: errors.append(_error("required_socket_unresolved", definition_id, "sockets/%s" % socket_id, "required socket must resolve to exactly one child"))

static func _validate_socket_connection(parent: Dictionary, child: Dictionary, socket: Dictionary, errors: Array) -> void:
	var parent_id: String = str(parent.get("definition_id", ""))
	var socket_port_id: String = str(socket.get("port_id", ""))
	if socket_port_id.is_empty():
		return
	var parent_port: Dictionary = {}
	var parent_ports_value: Variant = parent.get("ports", [])
	var parent_ports: Array = parent_ports_value if parent_ports_value is Array else []
	for candidate in parent_ports:
		if candidate is Dictionary and str(candidate.get("port_id", "")) == socket_port_id:
			parent_port = candidate
			break
	if parent_port.is_empty():
		errors.append(_error("missing_socket_port", parent_id, "sockets/%s/port_id" % socket.get("slot_id", socket.get("socket_id", "")), "socket port_id is not declared by parent"))
		return
	var child_port: Dictionary = {}
	var child_ports_value: Variant = child.get("ports", [])
	var child_ports: Array = child_ports_value if child_ports_value is Array else []
	for candidate in child_ports:
		if candidate is Dictionary and str(candidate.get("port_id", "")) == socket_port_id:
			child_port = candidate
			break
	if child_port.is_empty():
		errors.append(_error("missing_child_port", parent_id, "default_contents/%s/port_id" % socket.get("slot_id", socket.get("socket_id", "")), "child does not expose the exact socket port_id"))
		return
	var socket_contract_data: Dictionary = parent_port.duplicate(true)
	for key in ["direction", "domain", "family", "channel_set", "channel_units", "interface_id", "interface_revision", "role", "limits"]:
		if socket.has(key):
			socket_contract_data[key] = socket[key]
	var child_contract: ItemPortContract = PortContract.new(child_port)
	var socket_contract: ItemPortContract = PortContract.new(socket_contract_data)
	var mismatch: String = child_contract.explain_mismatch(socket_contract)
	if not mismatch.is_empty():
		errors.append(_error("port_%s" % mismatch, parent_id, "default_contents/%s/port_id" % socket.get("slot_id", socket.get("socket_id", "")), "child and socket ports are incompatible"))

static func _validate_topology(definitions: Array, by_id: Dictionary, errors: Array) -> void:
	var owner: Dictionary = {}
	for definition in definitions:
		if not (definition is Dictionary):
			continue
		var parent_id: String = str(definition.get("definition_id", ""))
		var children_value: Variant = definition.get("default_contents", [])
		var children: Array = children_value if children_value is Array else []
		for child in children:
			if not (child is Dictionary):
				continue
			var child_id: String = str(child.get("definition_id", ""))
			if owner.has(child_id) and owner[child_id] != parent_id: errors.append(_error("duplicate_owner", child_id, "owner", "child has more than one owner"))
			owner[child_id] = parent_id
	for definition in definitions:
		if not (definition is Dictionary):
			continue
		var definition_id: String = str(definition.get("definition_id", ""))
		var required_owner: String = str(definition.get("required_owner", ""))
		var has_explicit_root: bool = definition.has("topology_root")
		var is_root: bool = bool(definition.get("topology_root", false))
		if has_explicit_root and is_root and owner.has(definition_id):
			errors.append(_error("root_has_owner", definition_id, "topology_root", "a topology root cannot be owned by another definition"))
		if has_explicit_root and not is_root and not owner.has(definition_id):
			errors.append(_error("unowned_definition", definition_id, "topology_root", "a non-root definition must have exactly one owner"))
		if not required_owner.is_empty() and (not owner.has(definition_id) or str(owner[definition_id]) != required_owner):
			errors.append(_error("unowned_definition", definition_id, "required_owner", "definition is not owned by its declared parent"))
		var cursor: String = definition_id
		var visited: Dictionary = {}
		while by_id.has(cursor):
			if visited.has(cursor): errors.append(_error("cycle", definition_id, "default_contents", "containment graph is cyclic")); break
			visited[cursor] = true
			if not owner.has(cursor): break
			cursor = str(owner[cursor])

static func _sort_errors(errors: Array) -> void:
	errors.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ak: String = "%s|%s|%s" % [a.get("definition_id", ""), a.get("path", ""), a.get("code", "")]
		var bk: String = "%s|%s|%s" % [b.get("definition_id", ""), b.get("path", ""), b.get("code", "")]
		return ak < bk
	)

static func _is_canonical_definition(definition: Dictionary) -> bool:
	return definition.has("ports") or bool(definition.get("canonical", false)) or str(definition.get("schema_version", "")) == "p1"

static func _validate_canonical_bundle(definitions: Array, by_id: Dictionary, errors: Array) -> void:
	var bundle_enabled: bool = false
	var root_count: int = 0
	for definition in definitions:
		if definition is Dictionary and bool(definition.get("canonical_bundle", false)):
			bundle_enabled = true
			if bool(definition.get("topology_root", false)):
				root_count += 1
	if not bundle_enabled:
		return
	if root_count != 1:
		errors.append(_error("canonical_root_count", "", "canonical_bundle", "canonical bundle must declare exactly one topology root"))
	var owner: Dictionary = {}
	for definition in definitions:
		if not (definition is Dictionary) or not bool(definition.get("canonical_bundle", false)):
			continue
		var parent_id: String = str(definition.get("definition_id", ""))
		var children_value: Variant = definition.get("default_contents", [])
		if children_value is Array:
			for child_value in children_value:
				if child_value is Dictionary:
					owner[str(child_value.get("definition_id", ""))] = parent_id
	for definition in definitions:
		if not (definition is Dictionary) or not bool(definition.get("canonical_bundle", false)):
			continue
		var definition_id: String = str(definition.get("definition_id", ""))
		if bool(definition.get("topology_root", false)):
			continue
		if not owner.has(definition_id):
			errors.append(_error("canonical_unowned_definition", definition_id, "canonical_bundle", "canonical bundle definitions must be owned or declared roots"))
