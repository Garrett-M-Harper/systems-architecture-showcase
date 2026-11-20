class_name MechBreakdownController
extends Node

## MechBreakdownController
## Authoritative state transition and skeletal posture system for mechs experiencing
## critical fail states in STRATA-7X:
## 1. Overheat Seizure: Pelvis drops -0.75m, left knee locks at 75°, right leg trails,
##    torso pitches forward 22°, head tilts down, radiator thermal glow flares.
## 2. Power Blackout: Head droops -35° into collar, shoulders roll -12°, arms hang limp,
##    cockpit and visor emissive shaders turn off.
## 3. Catastrophic Destruction: Kinematic movement disabled, central Torso collapses into
##    a grounded carcass with physical collision, and severable limbs pop as severed physics bodies.
## 4. Limb Severance: Targeted limb slot detached into a tumbling physics RigidBody3D.

signal breakdown_state_changed(new_state: int, state_name: String)
signal overheat_seizure_triggered()
signal power_blackout_triggered()
signal catastrophic_destruction_triggered()
signal limb_severed(mount_id: String, severed_part: Node)

enum BreakdownState {
	INTACT,
	OVERHEAT_SEIZURE,
	POWER_BLACKOUT,
	CATASTROPHIC_DESTRUCTION,
}

const STATE_NAMES: Dictionary = {
	BreakdownState.INTACT: "intact",
	BreakdownState.OVERHEAT_SEIZURE: "overheat_seizure",
	BreakdownState.POWER_BLACKOUT: "power_blackout",
	BreakdownState.CATASTROPHIC_DESTRUCTION: "catastrophic_destruction",
}

@export var mech_root: Node3D = null
@export var modular_assembly: Node = null
@export var pose_controller: Node = null
@export var auto_discover_on_ready: bool = true

@export var thermal_glow_color: Color = Color(1.0, 0.35, 0.05, 1.0)
@export var thermal_glow_energy: float = 4.0

var current_state: BreakdownState = BreakdownState.INTACT
var is_overheated: bool = false
var is_blackout: bool = false
var is_destroyed: bool = false

# Skeletal joint nodes
var _pelvis: Node3D = null
var _torso: Node3D = null
var _head: Node3D = null
var _shoulder_l: Node3D = null
var _elbow_l: Node3D = null
var _shoulder_r: Node3D = null
var _elbow_r: Node3D = null
var _thigh_l: Node3D = null
var _shin_l: Node3D = null
var _thigh_r: Node3D = null
var _shin_r: Node3D = null

# Discovered meshes & materials for visual shader/emissive fail states
var _radiator_meshes: Array[MeshInstance3D] = []
var _emissive_meshes: Array[MeshInstance3D] = []
var _original_materials: Dictionary = {} # MeshInstance3D -> Material

var _active_tween: Tween = null

func _ready() -> void:
	if auto_discover_on_ready:
		_discover_references()

## Explicit initialization hook
func initialize(p_assembly: Node = null, p_root: Node3D = null) -> void:
	if p_assembly:
		modular_assembly = p_assembly
	if p_root:
		mech_root = p_root
	_discover_references()

## Discovers skeleton, assembly, pose controller, and visual meshes across the hierarchy
func _discover_references() -> void:
	if not mech_root:
		if get_parent() is Node3D:
			mech_root = get_parent() as Node3D
		elif modular_assembly is Node3D:
			mech_root = modular_assembly as Node3D

	if not modular_assembly and mech_root:
		if mech_root.has_method("get_slot") and mech_root.has_method("sever_part"):
			modular_assembly = mech_root
		else:
			modular_assembly = mech_root.find_child("*Assembly*", true, false)

	if not pose_controller and mech_root:
		pose_controller = mech_root.find_child("*PoseController*", true, false)
		if not pose_controller:
			pose_controller = find_child("*PoseController*", true, false)

	_discover_bones()
	_discover_visual_meshes()

func _discover_bones() -> void:
	if not mech_root:
		return

	_pelvis = _find_bone_node(["Pelvis", "Chassis", "RootBone"])
	_torso = _find_bone_node(["Torso", "Chest", "CoreBlock", "ChassisCore"])
	_head = _find_bone_node(["Head", "SensorPod", "Mast"])
	_shoulder_l = _find_bone_node(["ShoulderL", "Shoulder_L", "ArmLeft", "Arm_L", "UpperArmL"])
	_elbow_l = _find_bone_node(["ElbowL", "Elbow_L", "ForearmL", "Forearm_L"])
	_shoulder_r = _find_bone_node(["ShoulderR", "Shoulder_R", "ArmRight", "Arm_R", "UpperArmR"])
	_elbow_r = _find_bone_node(["ElbowR", "Elbow_R", "ForearmR", "Forearm_R"])
	_thigh_l = _find_bone_node(["ThighL", "Thigh_L", "HipL", "Hip_L", "UpperLegL"])
	_shin_l = _find_bone_node(["ShinL", "Shin_L", "KneeL", "Knee_L", "LowerLegL"])
	_thigh_r = _find_bone_node(["ThighR", "Thigh_R", "HipR", "Hip_R", "UpperLegR"])
	_shin_r = _find_bone_node(["ShinR", "Shin_R", "KneeR", "Knee_R", "LowerLegR"])

func _find_bone_node(aliases: Array[String]) -> Node3D:
	if not mech_root:
		return null
	for alias in aliases:
		var node = mech_root.find_child(alias, true, false) as Node3D
		if node:
			return node
	return null

func _discover_visual_meshes() -> void:
	_radiator_meshes.clear()
	_emissive_meshes.clear()
	if not mech_root:
		return

	var meshes = mech_root.find_children("*", "MeshInstance3D", true, false)
	for mesh_node in meshes:
		var mesh_instance := mesh_node as MeshInstance3D
		var node_name := mesh_instance.name.to_lower()
		var parent_name := mesh_instance.get_parent().name.to_lower() if mesh_instance.get_parent() else ""

		# Skip guide, envelope, and reference box meshes
		if "guide" in node_name or "envelope" in node_name or "env_" in node_name or "reference" in node_name:
			continue
		if "guide" in parent_name or "envelope" in parent_name:
			continue

		# Radiator / thermal mesh detection
		if "radiator" in node_name or "thermal" in node_name or "vent" in node_name or "grate" in node_name or "radiator" in parent_name or "thermal" in parent_name:
			if not _radiator_meshes.has(mesh_instance):
				_radiator_meshes.append(mesh_instance)

		# Visor / optics / status emissive mesh detection
		if "viewport" in node_name or "glass" in node_name or "optics" in node_name or "lidar" in node_name or "visor" in node_name or "cockpit" in node_name or "status" in node_name or "lens" in node_name:
			if not _emissive_meshes.has(mesh_instance):
				_emissive_meshes.append(mesh_instance)
		else:
			# Check material emission setting
			var mat = mesh_instance.material_override
			if not mat and mesh_instance.mesh and mesh_instance.mesh.surface_get_material(0):
				mat = mesh_instance.mesh.surface_get_material(0)
			if mat is StandardMaterial3D and (mat as StandardMaterial3D).emission_enabled:
				if not _emissive_meshes.has(mesh_instance):
					_emissive_meshes.append(mesh_instance)

# ==============================================================================
# FAIL STATE 1: OVERHEAT SEIZURE
# ==============================================================================
## Triggers overheat seizure: Lowers pelvis by -0.75m, locks left knee to deck at 75°,
## right leg trailing, torso pitched forward 22°, head tilted down, sets radiator mesh emission/thermal glow.
func trigger_overheat_seizure(duration: float = 0.5) -> void:
	is_overheated = true
	_set_state(BreakdownState.OVERHEAT_SEIZURE)

	if pose_controller and pose_controller.has_method("apply_pose"):
		pose_controller.apply_pose("thermal_seize", duration)
	else:
		_apply_posture_overheat_seizure(duration)

	_apply_radiator_thermal_glow(true, duration)
	overheat_seizure_triggered.emit()

func _apply_posture_overheat_seizure(duration: float = 0.5) -> void:
	if duration <= 0.0:
		if _pelvis:
			_pelvis.position = Vector3(0.0, -0.75, -0.2)
			_pelvis.rotation_degrees = Vector3(8.0, 0.0, -6.0)
		if _torso:
			_torso.rotation_degrees = Vector3(22.0, 5.0, 0.0)
		if _head:
			_head.rotation_degrees = Vector3(-20.0, 15.0, -5.0)
		if _shoulder_l:
			_shoulder_l.rotation_degrees = Vector3(-45.0, 25.0, -15.0)
		if _elbow_l:
			_elbow_l.rotation_degrees = Vector3(55.0, -10.0, 0.0)
		if _shoulder_r:
			_shoulder_r.rotation_degrees = Vector3(-15.0, -10.0, 5.0)
		if _elbow_r:
			_elbow_r.rotation_degrees = Vector3(10.0, 5.0, 0.0)
		if _thigh_l:
			_thigh_l.rotation_degrees = Vector3(-65.0, 10.0, 0.0)
		if _shin_l:
			_shin_l.rotation_degrees = Vector3(75.0, 0.0, 0.0)
		if _thigh_r:
			_thigh_r.rotation_degrees = Vector3(25.0, -15.0, 0.0)
		if _shin_r:
			_shin_r.rotation_degrees = Vector3(20.0, 0.0, 0.0)
		return

	if _active_tween and _active_tween.is_valid():
		_active_tween.kill()
	_active_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

	if _pelvis:
		_active_tween.tween_property(_pelvis, "position", Vector3(0.0, -0.75, -0.2), duration)
		_active_tween.tween_property(_pelvis, "rotation_degrees", Vector3(8.0, 0.0, -6.0), duration)
	if _torso:
		_active_tween.tween_property(_torso, "rotation_degrees", Vector3(22.0, 5.0, 0.0), duration)
	if _head:
		_active_tween.tween_property(_head, "rotation_degrees", Vector3(-20.0, 15.0, -5.0), duration)
	if _shoulder_l:
		_active_tween.tween_property(_shoulder_l, "rotation_degrees", Vector3(-45.0, 25.0, -15.0), duration)
	if _elbow_l:
		_active_tween.tween_property(_elbow_l, "rotation_degrees", Vector3(55.0, -10.0, 0.0), duration)
	if _shoulder_r:
		_active_tween.tween_property(_shoulder_r, "rotation_degrees", Vector3(-15.0, -10.0, 5.0), duration)
	if _elbow_r:
		_active_tween.tween_property(_elbow_r, "rotation_degrees", Vector3(10.0, 5.0, 0.0), duration)
	if _thigh_l:
		_active_tween.tween_property(_thigh_l, "rotation_degrees", Vector3(-65.0, 10.0, 0.0), duration)
	if _shin_l:
		_active_tween.tween_property(_shin_l, "rotation_degrees", Vector3(75.0, 0.0, 0.0), duration)
	if _thigh_r:
		_active_tween.tween_property(_thigh_r, "rotation_degrees", Vector3(25.0, -15.0, 0.0), duration)
	if _shin_r:
		_active_tween.tween_property(_shin_r, "rotation_degrees", Vector3(20.0, 0.0, 0.0), duration)

func _apply_radiator_thermal_glow(enable: bool, duration: float = 0.5) -> void:
	for mesh_instance in _radiator_meshes:
		if not is_instance_valid(mesh_instance):
			continue
		if enable:
			var mat: StandardMaterial3D = null
			if mesh_instance.material_override is StandardMaterial3D:
				mat = mesh_instance.material_override as StandardMaterial3D
			else:
				mat = StandardMaterial3D.new()
				if mesh_instance.material_override:
					mat = mesh_instance.material_override.duplicate() as StandardMaterial3D
				mesh_instance.material_override = mat

			mat.emission_enabled = true
			mat.emission = thermal_glow_color
			mat.albedo_color = Color(0.9, 0.2, 0.05, 1.0)

			if duration > 0.0:
				var t = create_tween()
				mat.emission_energy_multiplier = 0.0
				t.tween_property(mat, "emission_energy_multiplier", thermal_glow_energy, duration)
			else:
				mat.emission_energy_multiplier = thermal_glow_energy
		else:
			if mesh_instance.material_override is StandardMaterial3D:
				(mesh_instance.material_override as StandardMaterial3D).emission_enabled = false

# ==============================================================================
# FAIL STATE 2: POWER BLACKOUT
# ==============================================================================
## Triggers power blackout: Head droops -35° into collar, shoulders roll forward -12°,
## arms hang limp, turns off all visor/cockpit emissive shaders.
func trigger_power_blackout(duration: float = 0.5) -> void:
	is_blackout = true
	_set_state(BreakdownState.POWER_BLACKOUT)

	if pose_controller and pose_controller.has_method("apply_pose"):
		pose_controller.apply_pose("power_blackout", duration)
	else:
		_apply_posture_power_blackout(duration)

	_turn_off_emissives()
	power_blackout_triggered.emit()

func _apply_posture_power_blackout(duration: float = 0.5) -> void:
	if duration <= 0.0:
		if _pelvis:
			_pelvis.position = Vector3(0.0, -0.15, 0.0)
			_pelvis.rotation_degrees = Vector3(4.0, 0.0, 0.0)
		if _torso:
			_torso.rotation_degrees = Vector3(14.0, 0.0, 0.0)
		if _head:
			_head.rotation_degrees = Vector3(-35.0, 0.0, 0.0)
		if _shoulder_l:
			_shoulder_l.rotation_degrees = Vector3(-12.0, 5.0, -4.0)
		if _elbow_l:
			_elbow_l.rotation_degrees = Vector3(4.0, 0.0, 0.0)
		if _shoulder_r:
			_shoulder_r.rotation_degrees = Vector3(-12.0, -5.0, 4.0)
		if _elbow_r:
			_elbow_r.rotation_degrees = Vector3(4.0, 0.0, 0.0)
		if _thigh_l:
			_thigh_l.rotation_degrees = Vector3.ZERO
		if _shin_l:
			_shin_l.rotation_degrees = Vector3.ZERO
		if _thigh_r:
			_thigh_r.rotation_degrees = Vector3.ZERO
		if _shin_r:
			_shin_r.rotation_degrees = Vector3.ZERO
		return

	if _active_tween and _active_tween.is_valid():
		_active_tween.kill()
	_active_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

	if _pelvis:
		_active_tween.tween_property(_pelvis, "position", Vector3(0.0, -0.15, 0.0), duration)
		_active_tween.tween_property(_pelvis, "rotation_degrees", Vector3(4.0, 0.0, 0.0), duration)
	if _torso:
		_active_tween.tween_property(_torso, "rotation_degrees", Vector3(14.0, 0.0, 0.0), duration)
	if _head:
		_active_tween.tween_property(_head, "rotation_degrees", Vector3(-35.0, 0.0, 0.0), duration)
	if _shoulder_l:
		_active_tween.tween_property(_shoulder_l, "rotation_degrees", Vector3(-12.0, 5.0, -4.0), duration)
	if _elbow_l:
		_active_tween.tween_property(_elbow_l, "rotation_degrees", Vector3(4.0, 0.0, 0.0), duration)
	if _shoulder_r:
		_active_tween.tween_property(_shoulder_r, "rotation_degrees", Vector3(-12.0, -5.0, 4.0), duration)
	if _elbow_r:
		_active_tween.tween_property(_elbow_r, "rotation_degrees", Vector3(4.0, 0.0, 0.0), duration)
	if _thigh_l:
		_active_tween.tween_property(_thigh_l, "rotation_degrees", Vector3.ZERO, duration)
	if _shin_l:
		_active_tween.tween_property(_shin_l, "rotation_degrees", Vector3.ZERO, duration)
	if _thigh_r:
		_active_tween.tween_property(_thigh_r, "rotation_degrees", Vector3.ZERO, duration)
	if _shin_r:
		_active_tween.tween_property(_shin_r, "rotation_degrees", Vector3.ZERO, duration)

func _turn_off_emissives() -> void:
	for mesh_instance in _emissive_meshes:
		if not is_instance_valid(mesh_instance):
			continue
		var mat = mesh_instance.material_override
		if not mat and mesh_instance.mesh and mesh_instance.mesh.surface_get_material(0):
			mat = mesh_instance.mesh.surface_get_material(0)

		if mat is StandardMaterial3D:
			var mat_override := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
			mat_override.emission_enabled = false
			mat_override.emission_energy_multiplier = 0.0
			mat_override.emission = Color.BLACK
			mesh_instance.material_override = mat_override
		else:
			var black_mat := StandardMaterial3D.new()
			black_mat.albedo_color = Color(0.05, 0.05, 0.05, 1.0)
			black_mat.emission_enabled = false
			mesh_instance.material_override = black_mat

# ==============================================================================
# FAIL STATE 3: CATASTROPHIC DESTRUCTION
# ==============================================================================
## Triggers catastrophic destruction: Disables kinematic movement, collapses central Torso
## into a grounded carcass with physical collision, and pops damaged/severable limbs.
func trigger_catastrophic_destruction(duration: float = 0.5) -> void:
	if is_destroyed:
		return
	is_destroyed = true
	_set_state(BreakdownState.CATASTROPHIC_DESTRUCTION)

	# 1. Disable kinematic movement
	_disable_kinematic_movement()

	# 2. Collapse central Torso into grounded carcass with physical collision
	_collapse_torso_carcass(duration)

	# 3. Pop damaged and severable limbs
	_pop_all_severable_limbs()

	catastrophic_destruction_triggered.emit()

func _disable_kinematic_movement() -> void:
	if not mech_root:
		return
	if mech_root is CharacterBody3D:
		var cb := mech_root as CharacterBody3D
		cb.velocity = Vector3.ZERO
		cb.set_physics_process(false)
		cb.set_process(false)
	elif mech_root.get_parent() is CharacterBody3D:
		var cb := mech_root.get_parent() as CharacterBody3D
		cb.velocity = Vector3.ZERO
		cb.set_physics_process(false)
		cb.set_process(false)

func _collapse_torso_carcass(duration: float = 0.5) -> void:
	if pose_controller and pose_controller.has_method("apply_pose"):
		pose_controller.apply_pose("toppled_wreck", duration)
	else:
		if duration <= 0.0:
			if _pelvis:
				_pelvis.position = Vector3(0.0, -1.25, 0.0)
				_pelvis.rotation_degrees = Vector3(15.0, 20.0, 75.0)
			if _torso:
				_torso.rotation_degrees = Vector3(10.0, -15.0, 12.0)
			if _head:
				_head.rotation_degrees = Vector3(-25.0, 30.0, 0.0)
		else:
			if _active_tween and _active_tween.is_valid():
				_active_tween.kill()
			_active_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			if _pelvis:
				_active_tween.tween_property(_pelvis, "position", Vector3(0.0, -1.25, 0.0), duration)
				_active_tween.tween_property(_pelvis, "rotation_degrees", Vector3(15.0, 20.0, 75.0), duration)
			if _torso:
				_active_tween.tween_property(_torso, "rotation_degrees", Vector3(10.0, -15.0, 12.0), duration)
			if _head:
				_active_tween.tween_property(_head, "rotation_degrees", Vector3(-25.0, 30.0, 0.0), duration)

	# Ensure Torso/Chassis carcass has physical world collision
	_ensure_carcass_collision()

func _ensure_carcass_collision() -> void:
	if not mech_root:
		return
	var torso_or_chassis = _torso if _torso else (_pelvis if _pelvis else mech_root)
	if not torso_or_chassis:
		return

	# Ensure existing Area3D hitboxes or collision shapes are active for salvage interaction
	for area in torso_or_chassis.find_children("*", "Area3D", true, false):
		var area_node := area as Area3D
		area_node.monitoring = true
		area_node.monitorable = true
		for col in area_node.find_children("*", "CollisionShape3D", true, false):
			(col as CollisionShape3D).disabled = false

func _pop_all_severable_limbs() -> void:
	if not modular_assembly:
		return

	var severable_slots: Array = []
	if "slots" in modular_assembly:
		for slot in modular_assembly.slots.values():
			if slot and slot.get("can_be_severed") and not slot.get("is_severed") and slot.get("mount_id") != "chassis":
				severable_slots.append(slot)

	for slot in severable_slots:
		var blast_impulse = Vector3(
			randf_range(-5.0, 5.0),
			randf_range(3.0, 7.0),
			randf_range(-5.0, 5.0)
		)
		var blast_torque = Vector3(
			randf_range(-8.0, 8.0),
			randf_range(-8.0, 8.0),
			randf_range(-8.0, 8.0)
		)
		trigger_limb_severance(str(slot.get("mount_id")), blast_impulse, blast_torque)

# ==============================================================================
# FAIL STATE 4: LIMB SEVERANCE
# ==============================================================================
## Triggers targeted limb severance: Detaches limb slot, spawns severed physics body
## with mass and angular damp, and tumbles onto deck.
func trigger_limb_severance(mount_id: String, impulse: Vector3 = Vector3.ZERO, torque: Vector3 = Vector3.ZERO) -> Node:
	if not modular_assembly:
		_discover_references()

	if not modular_assembly:
		printerr("[MechBreakdownController] Cannot sever limb without modular_assembly")
		return null

	var slot: Variant = modular_assembly.get_slot(mount_id) if modular_assembly.has_method("get_slot") else null
	if not slot:
		printerr("[MechBreakdownController] Unknown mount slot: ", mount_id)
		return null

	if slot.get("is_severed"):
		return null

	if impulse == Vector3.ZERO:
		impulse = Vector3(randf_range(-3.0, 3.0), randf_range(2.0, 5.0), randf_range(-3.0, 3.0))
	if torque == Vector3.ZERO:
		torque = Vector3(randf_range(-4.0, 4.0), randf_range(-4.0, 4.0), randf_range(-4.0, 4.0))

	var severed_node: Node = modular_assembly.sever_part(mount_id, impulse, torque) if modular_assembly.has_method("sever_part") else null
	if severed_node:
		limb_severed.emit(mount_id, severed_node)
	return severed_node

## Slot severance notification from modular_assembly
func on_part_severed(mount_id: String, severed_node: Node) -> void:
	limb_severed.emit(mount_id, severed_node)

func _set_state(new_state: BreakdownState) -> void:
	current_state = new_state
	breakdown_state_changed.emit(current_state, STATE_NAMES.get(current_state, "unknown"))

func get_breakdown_state() -> BreakdownState:
	return current_state

func get_breakdown_state_name() -> String:
	return STATE_NAMES.get(current_state, "unknown")
