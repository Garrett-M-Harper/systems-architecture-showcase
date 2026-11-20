class_name MechProceduralStrideController
extends Node

## ==============================================================================
## STRATA-7X: PROCEDURAL HYDRAULIC KINEMATIC STRIDE CONTROLLER
## Ticket: ANIM-LOCO-01: First-Person Mech Walk Stride Animation & Locomotion Shadow Synchronization
##
## Option B Implementation:
## Procedurally animates the spatial leg bone nodes (Hip, Knee, Ankle) and Pelvis
## in real-time based on physical locomotion speed and ground contact.
## Produces authentic dynamic Forward+ directional shadows and hydraulic footstep clangs.
##
## Leg Bone Structure:
## Pelvis/HipL -> KneeL -> AnkleL
## Pelvis/HipR -> KneeR -> AnkleR
## ==============================================================================

signal footstep_struck(is_left: bool)
signal stride_phase_advanced(phase: float)

const STRIDE_LENGTH: float = 2.4 # Stride length (~2.4m per step / half-cycle)
const HIP_SWING_MAX: float = 0.314159265 # +/- 18 degrees (~0.31 rad)
const KNEE_FLEX_MAX: float = 0.663225116 # 0 to ~38 degrees (~0.66 rad)
const DECAY_TIME: float = 0.18 # Decay time to rest pose (~0.18s)
const PELVIS_HEAVE_MAX: float = 0.035 # Subtle vertical heave (~3.5 cm)
const PELVIS_SWAY_MAX: float = 0.025 # Subtle lateral sway (~2.5 cm)
const PELVIS_ROLL_MAX: float = 0.026179938 # Subtle pelvic roll (~1.5 degrees)

@export var host_body: CharacterBody3D = null
@export var is_active: bool = true

# Stride Cycle Phase in radians: [0.0, TAU)
# Left foot strikes at 0 / TAU, Right foot strikes at PI
var stride_phase: float = 0.0
var blend_weight: float = 0.0
var is_moving: bool = false
var step_count: int = 0

# Discovered Spatial Nodes
var pelvis: Node3D = null
var hip_l: Node3D = null
var knee_l: Node3D = null
var ankle_l: Node3D = null
var hip_r: Node3D = null
var knee_r: Node3D = null
var ankle_r: Node3D = null
var torso: Node3D = null
var head: Node3D = null

# Footstep Sensors
var footstep_sensor_l: RayCast3D = null
var footstep_sensor_r: RayCast3D = null

# Neutral Rest Pose Cache
var rest_pelvis_pos: Vector3 = Vector3.ZERO
var walk_pelvis_pos: Vector3 = Vector3.ZERO
var rest_pelvis_rot: Vector3 = Vector3.ZERO
var rest_hip_l_rot: Vector3 = Vector3.ZERO
var rest_knee_l_rot: Vector3 = Vector3.ZERO
var rest_ankle_l_rot: Vector3 = Vector3.ZERO
var rest_hip_r_rot: Vector3 = Vector3.ZERO
var rest_knee_r_rot: Vector3 = Vector3.ZERO
var rest_ankle_r_rot: Vector3 = Vector3.ZERO
var rest_torso_rot: Vector3 = Vector3.ZERO

var _rest_pose_saved: bool = false
var _bones_discovered: bool = false
var _last_update_frame: int = -1

func _ready() -> void:
	if not host_body and get_parent() is CharacterBody3D:
		host_body = get_parent() as CharacterBody3D
	discover_bones()
	if host_body and host_body.has_method("_update_locomotion_animation"):
		set_physics_process(false)

func _physics_process(delta: float) -> void:
	if not is_active:
		return
	if _last_update_frame == Engine.get_physics_frames():
		return
	_last_update_frame = Engine.get_physics_frames()

	var vel := host_body.velocity if host_body else Vector3.ZERO
	var grounded := host_body.is_on_floor() if host_body else true
	update_stride(delta, vel, grounded)

func discover_bones(root_node: Node = null) -> bool:
	var search_root: Node = root_node
	if not search_root:
		search_root = host_body if host_body else get_parent()
	if not search_root:
		search_root = self

	# 1. Discover Pelvis
	pelvis = search_root.get_node_or_null("Pelvis") as Node3D
	if not pelvis:
		pelvis = search_root.get_node_or_null("MechBody/Pelvis") as Node3D
	if not pelvis:
		pelvis = search_root.find_child("Pelvis", true, false) as Node3D

	if not pelvis:
		return false

	# 2. Discover Left Leg Chain
	hip_l = pelvis.get_node_or_null("HipL") as Node3D
	if hip_l:
		knee_l = hip_l.get_node_or_null("KneeL") as Node3D
		if knee_l:
			ankle_l = knee_l.get_node_or_null("AnkleL") as Node3D

	# 3. Discover Right Leg Chain
	hip_r = pelvis.get_node_or_null("HipR") as Node3D
	if hip_r:
		knee_r = hip_r.get_node_or_null("KneeR") as Node3D
		if knee_r:
			ankle_r = knee_r.get_node_or_null("AnkleR") as Node3D

	# 4. Discover Torso & Head
	torso = pelvis.get_node_or_null("Torso") as Node3D
	if torso:
		head = torso.get_node_or_null("Head") as Node3D

	# 5. Fallback discovery if non-standard hierarchy
	if not hip_l: hip_l = search_root.find_child("HipL", true, false) as Node3D
	if not knee_l: knee_l = search_root.find_child("KneeL", true, false) as Node3D
	if not ankle_l: ankle_l = search_root.find_child("AnkleL", true, false) as Node3D
	if not hip_r: hip_r = search_root.find_child("HipR", true, false) as Node3D
	if not knee_r: knee_r = search_root.find_child("KneeR", true, false) as Node3D
	if not ankle_r: ankle_r = search_root.find_child("AnkleR", true, false) as Node3D
	if not torso: torso = search_root.find_child("Torso", true, false) as Node3D
	if not head: head = search_root.find_child("Head", true, false) as Node3D

	# 6. Capture Neutral Rest Pose (once only)
	if not _rest_pose_saved and pelvis:
		sync_rest_pose_from_bones()

	# 7. Discover Sensors on Host
	if search_root is CharacterBody3D and not host_body:
		host_body = search_root as CharacterBody3D
	if host_body:
		footstep_sensor_l = host_body.get_node_or_null("FootstepSensorL") as RayCast3D
		footstep_sensor_r = host_body.get_node_or_null("FootstepSensorR") as RayCast3D

	# 8. Isolate AnimationPlayer so baked clips cannot clobber procedural leg kinematics
	var anim_player: AnimationPlayer = search_root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if not anim_player and host_body:
		anim_player = host_body.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if anim_player:
		_isolate_animation_player(anim_player)

	_bones_discovered = (hip_l != null and hip_r != null)
	return _bones_discovered

func sync_rest_pose_from_bones() -> void:
	if pelvis and is_instance_valid(pelvis):
		rest_pelvis_pos = pelvis.position
		walk_pelvis_pos = pelvis.get_meta("rest_position", pelvis.position)
		rest_pelvis_rot = pelvis.rotation
	if hip_l and is_instance_valid(hip_l): rest_hip_l_rot = hip_l.rotation
	if knee_l and is_instance_valid(knee_l): rest_knee_l_rot = knee_l.rotation
	if ankle_l and is_instance_valid(ankle_l): rest_ankle_l_rot = ankle_l.rotation
	if hip_r and is_instance_valid(hip_r): rest_hip_r_rot = hip_r.rotation
	if knee_r and is_instance_valid(knee_r): rest_knee_r_rot = knee_r.rotation
	if ankle_r and is_instance_valid(ankle_r): rest_ankle_r_rot = ankle_r.rotation
	if torso and is_instance_valid(torso): rest_torso_rot = torso.rotation
	_rest_pose_saved = true

func _isolate_animation_player(anim_player: AnimationPlayer) -> void:
	for lib_name in anim_player.get_animation_library_list():
		var lib: AnimationLibrary = anim_player.get_animation_library(lib_name)
		if not lib:
			continue
		for anim_name in lib.get_animation_list():
			var anim: Animation = lib.get_animation(anim_name)
			if not anim:
				continue
			var tracks_to_remove: Array[int] = []
			for t in range(anim.get_track_count()):
				var path_str := String(anim.track_get_path(t)).to_lower()
				# Check if track targets Pelvis, Hips, Knees, Ankles, or Pelvis-level Torso rotation
				if "pelvis" in path_str and not ("shoulder" in path_str or "head" in path_str or "elbow" in path_str or "wrist" in path_str or "weapon" in path_str):
					tracks_to_remove.append(t)
			tracks_to_remove.reverse()
			for t in tracks_to_remove:
				anim.remove_track(t)

func update_stride(delta: float, velocity: Vector3, is_grounded: bool) -> void:
	if not is_active:
		return
	var current_physics_frame := Engine.get_physics_frames()
	if _last_update_frame == current_physics_frame:
		return
	_last_update_frame = current_physics_frame

	if not _bones_discovered:
		if not discover_bones():
			return

	var horiz_vel := Vector2(velocity.x, velocity.z)
	var horiz_speed := horiz_vel.length()
	var should_step := is_grounded and horiz_speed > 0.1

	if should_step:
		is_moving = true
		blend_weight = move_toward(blend_weight, 1.0, delta / DECAY_TIME)

		# Evaluate travel direction relative to forward facing
		var speed_sign: float = 1.0
		if host_body:
			var fwd: Vector3 = -host_body.global_transform.basis.z
			var v3: Vector3 = Vector3(velocity.x, 0.0, velocity.z).normalized()
			if fwd.dot(v3) < -0.2:
				speed_sign = -1.0

		# Advance stride phase proportional to horizontal speed and stride length (~2.4m):
		# Full stride cycle (left step + right step) = 2.0 * STRIDE_LENGTH (4.8m)
		# d(stride_phase)/dt = (PI * horiz_speed) / STRIDE_LENGTH
		var phase_speed: float = (PI * horiz_speed) / STRIDE_LENGTH
		var delta_phase: float = phase_speed * delta * speed_sign
		var old_phase: float = stride_phase
		stride_phase += delta_phase

		# Trigger footstep clangs precisely when each foot strikes ground phase:
		# Left strikes at 0 (or TAU), Right strikes at PI
		if delta_phase > 0.0:
			if old_phase < PI and stride_phase >= PI:
				_trigger_footstep(false) # Right foot impact
			if stride_phase >= TAU:
				_trigger_footstep(true) # Left foot impact
				stride_phase = fmod(stride_phase, TAU)
		elif delta_phase < 0.0:
			if old_phase > PI and stride_phase <= PI:
				_trigger_footstep(false)
			if stride_phase <= 0.0:
				_trigger_footstep(true)
				stride_phase += TAU
		stride_phase_advanced.emit(stride_phase)
	else:
		is_moving = false
		blend_weight = move_toward(blend_weight, 0.0, delta / DECAY_TIME)

	_apply_stride_kinematics()

func _apply_stride_kinematics() -> void:
	if blend_weight <= 0.0001:
		# Return precisely to neutral rest rotations and positions
		if hip_l and is_instance_valid(hip_l): hip_l.rotation = rest_hip_l_rot
		if hip_r and is_instance_valid(hip_r): hip_r.rotation = rest_hip_r_rot
		if knee_l and is_instance_valid(knee_l): knee_l.rotation = rest_knee_l_rot
		if knee_r and is_instance_valid(knee_r): knee_r.rotation = rest_knee_r_rot
		if ankle_l and is_instance_valid(ankle_l): ankle_l.rotation = rest_ankle_l_rot
		if ankle_r and is_instance_valid(ankle_r): ankle_r.rotation = rest_ankle_r_rot
		if pelvis and is_instance_valid(pelvis):
			pelvis.position = rest_pelvis_pos
			pelvis.rotation = rest_pelvis_rot
		if torso and is_instance_valid(torso):
			torso.rotation = rest_torso_rot
		return

	# 1. Hip Swing along X-axis in antiphase (+/- 18 degrees / ~0.31 rad)
	var hip_l_offset: float = cos(stride_phase) * HIP_SWING_MAX
	var hip_r_offset: float = -hip_l_offset

	# 2. Knee Flexion during swing phase (0 to ~38 degrees / ~0.66 rad)
	# Left swings between PI and TAU
	var knee_flex_l: float = 0.0
	if stride_phase >= PI and stride_phase < TAU:
		var swing_progress_l: float = (stride_phase - PI) / PI
		knee_flex_l = sin(swing_progress_l * PI) * KNEE_FLEX_MAX

	# Right swings between 0.0 and PI
	var knee_flex_r: float = 0.0
	if stride_phase >= 0.0 and stride_phase < PI:
		var swing_progress_r: float = stride_phase / PI
		knee_flex_r = sin(swing_progress_r * PI) * KNEE_FLEX_MAX

	# 3. Counter-pitch Ankle so the foot envelope stays parallel to the floor
	# Total leg pitch = hip_offset + knee_flex + ankle_offset = 0
	var ankle_offset_l: float = -(hip_l_offset + knee_flex_l)
	var ankle_offset_r: float = -(hip_r_offset + knee_flex_r)

	# 4. Subtle vertical heave and sway to Pelvis
	# Heave at twice the stride frequency (frequency of steps)
	var heave: float = (cos(stride_phase * 2.0) - 1.0) * 0.5 * PELVIS_HEAVE_MAX
	# Sway lateral weight shift towards the stance leg
	var sway: float = sin(stride_phase) * PELVIS_SWAY_MAX
	# Pelvic roll towards the stance leg
	var roll: float = sin(stride_phase) * PELVIS_ROLL_MAX

	# Apply rotation to Hip nodes
	if hip_l and is_instance_valid(hip_l):
		var base_hip_l_x: float = deg_to_rad(hip_l.get_meta("rest_rotation_degrees", Vector3.ZERO).x) if hip_l.has_meta("rest_rotation_degrees") else rest_hip_l_rot.x
		hip_l.rotation.x = lerpf(rest_hip_l_rot.x, base_hip_l_x, blend_weight) + hip_l_offset * blend_weight
		hip_l.rotation.y = rest_hip_l_rot.y
		hip_l.rotation.z = rest_hip_l_rot.z

	if hip_r and is_instance_valid(hip_r):
		var base_hip_r_x: float = deg_to_rad(hip_r.get_meta("rest_rotation_degrees", Vector3.ZERO).x) if hip_r.has_meta("rest_rotation_degrees") else rest_hip_r_rot.x
		hip_r.rotation.x = lerpf(rest_hip_r_rot.x, base_hip_r_x, blend_weight) + hip_r_offset * blend_weight
		hip_r.rotation.y = rest_hip_r_rot.y
		hip_r.rotation.z = rest_hip_r_rot.z

	# Apply rotation to Knee nodes
	if knee_l and is_instance_valid(knee_l):
		var base_knee_l_x: float = deg_to_rad(knee_l.get_meta("rest_rotation_degrees", Vector3.ZERO).x) if knee_l.has_meta("rest_rotation_degrees") else rest_knee_l_rot.x
		knee_l.rotation.x = lerpf(rest_knee_l_rot.x, base_knee_l_x, blend_weight) + knee_flex_l * blend_weight
		knee_l.rotation.y = rest_knee_l_rot.y
		knee_l.rotation.z = rest_knee_l_rot.z

	if knee_r and is_instance_valid(knee_r):
		var base_knee_r_x: float = deg_to_rad(knee_r.get_meta("rest_rotation_degrees", Vector3.ZERO).x) if knee_r.has_meta("rest_rotation_degrees") else rest_knee_r_rot.x
		knee_r.rotation.x = lerpf(rest_knee_r_rot.x, base_knee_r_x, blend_weight) + knee_flex_r * blend_weight
		knee_r.rotation.y = rest_knee_r_rot.y
		knee_r.rotation.z = rest_knee_r_rot.z

	# Apply rotation to Ankle nodes
	if ankle_l and is_instance_valid(ankle_l):
		var base_ankle_l_x: float = deg_to_rad(ankle_l.get_meta("rest_rotation_degrees", Vector3.ZERO).x) if ankle_l.has_meta("rest_rotation_degrees") else rest_ankle_l_rot.x
		ankle_l.rotation.x = lerpf(rest_ankle_l_rot.x, base_ankle_l_x, blend_weight) + ankle_offset_l * blend_weight
		ankle_l.rotation.y = rest_ankle_l_rot.y
		ankle_l.rotation.z = rest_ankle_l_rot.z

	if ankle_r and is_instance_valid(ankle_r):
		var base_ankle_r_x: float = deg_to_rad(ankle_r.get_meta("rest_rotation_degrees", Vector3.ZERO).x) if ankle_r.has_meta("rest_rotation_degrees") else rest_ankle_r_rot.x
		ankle_r.rotation.x = lerpf(rest_ankle_r_rot.x, base_ankle_r_x, blend_weight) + ankle_offset_r * blend_weight
		ankle_r.rotation.y = rest_ankle_r_rot.y
		ankle_r.rotation.z = rest_ankle_r_rot.z

	# Apply heave, sway and roll to Pelvis
	if pelvis and is_instance_valid(pelvis):
		var target_pelvis_base: Vector3 = pelvis.get_meta("rest_position", walk_pelvis_pos) if pelvis.has_meta("rest_position") else (walk_pelvis_pos if walk_pelvis_pos != Vector3.ZERO else rest_pelvis_pos)
		pelvis.position = rest_pelvis_pos.lerp(target_pelvis_base, blend_weight) + Vector3(sway, heave, 0.0) * blend_weight
		pelvis.rotation = rest_pelvis_rot + Vector3(0.0, 0.0, roll) * blend_weight

	# Cockpit view and head isolation:
	# Counter-roll Torso by -roll so Torso and Head remain upright and rock-solid
	if torso and is_instance_valid(torso):
		torso.rotation.x = rest_torso_rot.x
		torso.rotation.y = rest_torso_rot.y
		torso.rotation.z = rest_torso_rot.z - roll * blend_weight

func _trigger_footstep(is_left: bool) -> void:
	step_count += 1
	footstep_struck.emit(is_left)

	if not host_body:
		return

	# 1. Trigger Footstep Sensor on Rig
	var sensor: RayCast3D = null
	if host_body.has_method("get_footstep_sensor_left") and host_body.has_method("get_footstep_sensor_right"):
		sensor = host_body.get_footstep_sensor_left() if is_left else host_body.get_footstep_sensor_right()
	elif is_left and footstep_sensor_l:
		sensor = footstep_sensor_l
	elif not is_left and footstep_sensor_r:
		sensor = footstep_sensor_r

	if sensor and is_instance_valid(sensor) and sensor.has_method("trigger_footstep"):
		sensor.trigger_footstep(host_body.velocity)
	elif host_body.get("_footstep_player"):
		var p: AudioStreamPlayer3D = host_body.get("_footstep_player")
		if p and is_instance_valid(p):
			p.pitch_scale = randf_range(0.92, 1.15)
			p.play()

	# 2. Reset _stride_accum on host
	if "_stride_accum" in host_body:
		host_body.set("_stride_accum", 0.0)

	# 3. Acoustic Event Broadcast
	var horiz_vel := Vector2(host_body.velocity.x, host_body.velocity.z).length()
	var step_db := clampf(remap(horiz_vel, 0.35, 7.5, 74.0, 90.0), 74.0, 90.0)
	var foot_pos: Vector3 = host_body.global_position + Vector3.UP * 0.1
	if is_left and ankle_l and is_instance_valid(ankle_l):
		foot_pos = ankle_l.global_position
	elif not is_left and ankle_r and is_instance_valid(ankle_r):
		foot_pos = ankle_r.global_position

	var geb: Node = host_body.get_node_or_null("/root/GameEventBus")
	if geb and geb.has_signal("acoustic_event_emitted"):
		geb.acoustic_event_emitted.emit(foot_pos, step_db)

	var ab: Node = host_body.get_node_or_null("/root/AcousticBus")
	if ab and ab.has_method("inject"):
		ab.inject(foot_pos, step_db)
