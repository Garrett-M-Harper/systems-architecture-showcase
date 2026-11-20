class_name SensorProcessor
extends Node

## Processes multi-band sensor sweeps (OPTICAL, LIDAR, THERMAL, ACOUSTIC, EM) for any rig.
## Attach to any Node3D rig. Emits sweep telemetry via GameEventBus when present.

func sweep(band: String, origin: Transform3D, range_m: float) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var space_state = get_world_3d().direct_space_state
	if not space_state: return results

	if band == "OPTICAL":
		var p = PhysicsRayQueryParameters3D.create(origin.origin, origin.origin - origin.basis.z * range_m)
		p.collision_mask = 1
		var hit = space_state.intersect_ray(p)
		if not hit.is_empty():
			results.append({"position": hit.position, "type": "geometry", "intensity": 1.0})

	elif band == "LIDAR":
		var rays = 8
		var fov_deg = 30.0
		var half_fov = deg_to_rad(fov_deg) * 0.5

		for i in range(rays):
			var angle = -half_fov + (float(i) / max(1, rays - 1)) * (half_fov * 2.0)
			# Distribute around Y axis for a fan or randomly in a cone. For simplicity, flat fan here.
			var dir = (-origin.basis.z).rotated(origin.basis.y, angle)
			var p = PhysicsRayQueryParameters3D.create(origin.origin, origin.origin + dir * range_m)
			p.collision_mask = 1 | 2 # Also hit other stuff
			var hit = space_state.intersect_ray(p)
			if not hit.is_empty():
				var collider = hit.collider
				if collider is Node and collider.is_in_group("lidar_absorbent"):
					continue # absorbed
				results.append({"position": hit.position, "type": "lidar_return", "intensity": 0.8})

	elif band == "THERMAL":
		var emitters = get_tree().get_nodes_in_group("thermal_emitter")
		for e in emitters:
			if e is Node3D:
				var dist = origin.origin.distance_to(e.global_position)
				if dist <= range_m:
					results.append({"position": e.global_position, "type": "heat_source", "intensity": clamp(1.0 - (dist / range_m), 0.1, 1.0)})

	elif band == "ACOUSTIC":
		var sources = get_tree().get_nodes_in_group("acoustic_source")
		for s in sources:
			if s is Node3D:
				var dist = origin.origin.distance_to(s.global_position)
				if dist <= range_m:
					var atten = clamp(1.0 - (dist / range_m), 0.0, 1.0)
					if atten > 0.01:
						results.append({"position": s.global_position, "type": "sound", "intensity": atten})

	elif band == "EM":
		var em_sources = get_tree().get_nodes_in_group("em_source")
		for src in em_sources:
			if src is Node3D:
				var dist = origin.origin.distance_to(src.global_position)
				if dist <= range_m:
					var atten: float = clampf(1.0 - (dist / range_m), 0.0, 1.0)
					var p = PhysicsRayQueryParameters3D.create(origin.origin, src.global_position, 1)
					var hit = space_state.intersect_ray(p)
					if not hit.is_empty():
						var col = hit.get("collider")
						var is_steel: bool = false
						if col is Node:
							var col_name: String = col.name.to_lower()
							if "steel" in col_name or "metal" in col_name or "bulkhead" in col_name or "door" in col_name:
								is_steel = true
							elif "atom_class" in col and str(col.get("atom_class")).to_lower() == "steel":
								is_steel = true
						atten *= (0.08 if is_steel else 0.40)
					if atten > 0.02:
						results.append({"position": src.global_position, "type": "em_emission", "intensity": atten})

	return results

func full_sweep(origin: Transform3D) -> Dictionary:
	var optical = sweep("OPTICAL", origin, 100.0)
	var lidar = sweep("LIDAR", origin, 100.0)
	var thermal = sweep("THERMAL", origin, 40.0)
	var acoustic = sweep("ACOUSTIC", origin, 60.0)
	var em = sweep("EM", origin, 45.0)

	var data = {
		"optical": optical,
		"lidar": lidar,
		"thermal": thermal,
		"acoustic": acoustic,
		"em": em
	}

	var bus = get_node_or_null("/root/GameEventBus")
	if bus and bus.has_signal("sensor_sweep_complete"):
		bus.emit_signal("sensor_sweep_complete", data)

	return data
