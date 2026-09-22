extends Node3D
## Visual-only controller for the tactical female FBX.
##
## The parent owns movement, collisions, damage and action timers.  This node
## only turns a compact state dictionary into skeletal pose and presentation:
##
##     visual.apply_state({
##         "time": elapsed,
##         "walk_phase": walk_phase,
##         "move_amount": movement_amount,
##         "airborne": not player.is_on_floor(),
##         "vertical_speed": player.velocity.y,
##         "roll_progress": roll_progress,       # -1 when inactive
##         "dash_progress": dash_progress,       # -1 when inactive
##         "slash_progress": slash_progress,     # -1 when inactive
##         "attack_kind": "slash",
##         "boost": player.is_cybernetic_active,
##         "damage_flash": damage_flash,
##     })
##
## The imported FBX already contains the rest pose and an Armature rotated by
## -90 degrees around X.  We keep that transform intact.  Every animated pose
## is written as rest rotation * local delta, and rest position/scale are kept
## on every frame so a reset can never collapse the skinned mesh.

const CHARACTER_SCENE: PackedScene = preload("res://tactical+female+armor+3d+model/tripo_convert_dd330cff-e086-44c0-a315-e15f143795f3.fbx")

@export var visual_height: float = 1.55
@export var face_yaw: float = PI
@export var pose_lerp_speed: float = 14.0
@export var roll_pivot_height: float = 0.78
@export var show_tech_blade: bool = true

var model_root: Node3D
var rig_pivot: Node3D
var armature: Node3D
var skeleton: Skeleton3D
var blade_attachment: BoneAttachment3D
var tech_blade: MeshInstance3D

var _rest_rotations: Array[Quaternion] = []
var _rest_positions: Array[Vector3] = []
var _rest_scales: Array[Vector3] = []
var _current_deltas: Array[Quaternion] = []
var _bone_ids: Dictionary = {}
var _last_time: float = -INF
var _roll_angle: float = 0.0
var _is_setup: bool = false
var _blade_material: StandardMaterial3D


func _ready() -> void:
	setup()
	reset_pose()


## Builds the imported model once. Safe to call from a parent before the first
## state update; it is also called automatically from _ready().
func setup() -> void:
	if _is_setup and is_instance_valid(skeleton):
		return

	rig_pivot = Node3D.new()
	rig_pivot.name = "RigPivot"
	add_child(rig_pivot)
	rig_pivot.position = Vector3(0.0, roll_pivot_height, 0.0)

	model_root = CHARACTER_SCENE.instantiate() as Node3D
	model_root.name = "TacticalFemale"
	model_root.scale = Vector3.ONE * (visual_height / 1.0)
	model_root.position = Vector3(0.0, -roll_pivot_height, 0.0)
	model_root.rotation.y = face_yaw
	rig_pivot.add_child(model_root)

	armature = model_root.get_node_or_null("Armature") as Node3D
	if armature == null:
		push_error("character_visual.gd: FBX Armature node is missing")
		return
	# Keep the imported coordinate conversion.  Do not replace it with identity.
	armature.rotation.x = -PI * 0.5
	skeleton = armature.get_node_or_null("Skeleton3D") as Skeleton3D
	if skeleton == null:
		push_error("character_visual.gd: FBX Skeleton3D node is missing")
		return

	_cache_bones()
	_create_tech_blade()
	_is_setup = true


func _cache_bones() -> void:
	_rest_rotations.clear()
	_rest_positions.clear()
	_rest_scales.clear()
	_current_deltas.clear()
	_bone_ids.clear()
	for bone_index in skeleton.get_bone_count():
		var rest := skeleton.get_bone_rest(bone_index)
		_rest_rotations.append(rest.basis.get_rotation_quaternion())
		_rest_positions.append(rest.origin)
		_rest_scales.append(rest.basis.get_scale())
		_current_deltas.append(Quaternion.IDENTITY)
		_bone_ids[skeleton.get_bone_name(bone_index)] = bone_index


func _create_tech_blade() -> void:
	blade_attachment = BoneAttachment3D.new()
	blade_attachment.name = "TechBladeAttachment"
	blade_attachment.bone_name = "mixamorig_RightHand"
	skeleton.add_child(blade_attachment)
	blade_attachment.position = Vector3(0.0, 0.135, -0.018)
	blade_attachment.rotation = Vector3(0.0, 0.0, 0.0)

	tech_blade = MeshInstance3D.new()
	tech_blade.name = "TechBlade"
	var blade_mesh := BoxMesh.new()
	blade_mesh.size = Vector3(0.032, 0.15, 0.012)
	tech_blade.mesh = blade_mesh
	_blade_material = StandardMaterial3D.new()
	_blade_material.albedo_color = Color("#8df6ff")
	_blade_material.emission_enabled = true
	_blade_material.emission = Color("#24d8ff")
	_blade_material.emission_energy_multiplier = 2.8
	tech_blade.material_override = _blade_material
	blade_attachment.add_child(tech_blade)
	tech_blade.visible = show_tech_blade


## Apply one parent-authored visual state. Values are intentionally tolerant of
## missing keys so older player code can start with only time and movement.
func apply_state(state: Dictionary) -> void:
	setup()
	if not _is_setup:
		return

	var now := float(state.get("time", 0.0))
	var state_name := String(state.get("state", ""))
	var state_blend := clampf(float(state.get("blend", 1.0)), 0.0, 1.0)
	var dt := get_process_delta_time()
	if not is_finite(dt) or dt <= 0.0 or dt > 0.2:
		dt = 1.0 / 60.0
	if _last_time > -INF and now > _last_time:
		dt = clampf(now - _last_time, 1.0 / 240.0, 0.1)
	_last_time = now

	var target: Array[Quaternion] = []
	for bone_index in skeleton.get_bone_count():
		target.append(Quaternion.IDENTITY)

	var time := now
	var walk_phase := float(state.get("walk_phase", time * 6.0))
	var move_amount := clampf(float(state.get("move_amount", 0.0)), 0.0, 1.0)
	if state_name == "walk" or state_name == "moving":
		move_amount = maxf(move_amount, state_blend)
	var airborne := bool(state.get("airborne", false))
	var vertical_speed := float(state.get("vertical_speed", 0.0))
	var roll_progress := float(state.get("roll_progress", -1.0))
	var dash_progress := float(state.get("dash_progress", -1.0))
	var slash_progress := float(state.get("slash_progress", -1.0))
	var attack_kind := String(state.get("attack_kind", "slash"))
	var charge_amount := clampf(float(state.get("charge_amount", 0.0)), 0.0, 1.0)
	var diving := bool(state.get("diving", false)) or state_name == "dive"
	var dead := bool(state.get("dead", false)) or state_name == "dead"
	var boost := bool(state.get("boost", false))
	var damage_flash := clampf(float(state.get("damage_flash", 0.0)), 0.0, 1.0)

	# This imported rig does not use the usual Mixamo local axes. Its local X
	# points along the character's forward direction; bending around X splays
	# the limbs sideways. Z is the anatomical flexion axis for arms and legs.
	var breath := sin(time * 2.1) * 0.010
	_add_delta(target, "mixamorig_Spine1", Vector3(0.0, 0.0, breath), 1.0)
	_add_delta(target, "mixamorig_Spine2", Vector3(0.0, 0.0, breath * 0.5), 1.0)
	_add_delta(target, "mixamorig_Neck", Vector3(0.0, 0.0, -breath * 0.5), 1.0)

	# A planted leg stays nearly straight; its opposite bends only during the
	# swing phase. All hip, knee and arm travel stays in the forward/back plane.
	var stride := sin(walk_phase)
	var opposite := -stride
	var left_swing := maxf(0.0, cos(walk_phase))
	var right_swing := maxf(0.0, -cos(walk_phase))
	_add_delta(target, "mixamorig_LeftUpLeg", Vector3(0.0, 0.0, stride * 0.46 * move_amount), 1.0)
	_add_delta(target, "mixamorig_RightUpLeg", Vector3(0.0, 0.0, opposite * 0.46 * move_amount), 1.0)
	_add_delta(target, "mixamorig_LeftLeg", Vector3(0.0, 0.0, (0.05 + left_swing * 0.64) * move_amount), 1.0)
	_add_delta(target, "mixamorig_RightLeg", Vector3(0.0, 0.0, (0.05 + right_swing * 0.64) * move_amount), 1.0)
	_add_delta(target, "mixamorig_LeftArm", Vector3(0.0, 0.0, opposite * 0.27 * move_amount), 1.0)
	_add_delta(target, "mixamorig_RightArm", Vector3(0.0, 0.0, stride * 0.27 * move_amount), 1.0)
	_add_delta(target, "mixamorig_LeftForeArm", Vector3(0.0, 0.0, -(0.13 + maxf(0.0, stride) * 0.12) * move_amount), 1.0)
	_add_delta(target, "mixamorig_RightForeArm", Vector3(0.0, 0.0, -(0.13 + maxf(0.0, opposite) * 0.12) * move_amount), 1.0)
	_add_delta(target, "mixamorig_Hips", Vector3(0.0, stride * 0.035 * move_amount, 0.0), 1.0)
	var body_height := roll_pivot_height + (1.0 - cos(walk_phase * 2.0)) * 0.009 * move_amount

	if airborne:
		var jump_lift := clampf(vertical_speed / 8.0, -1.0, 1.0)
		_add_delta(target, "mixamorig_LeftUpLeg", Vector3(0.0, 0.0, -0.25 - maxf(0.0, jump_lift) * 0.20), 1.0)
		_add_delta(target, "mixamorig_RightUpLeg", Vector3(0.0, 0.0, -0.16 - maxf(0.0, jump_lift) * 0.14), 1.0)
		_add_delta(target, "mixamorig_LeftLeg", Vector3(0.0, 0.0, 0.50), 1.0)
		_add_delta(target, "mixamorig_RightLeg", Vector3(0.0, 0.0, 0.40), 1.0)
		_add_delta(target, "mixamorig_LeftArm", Vector3(0.08, 0.0, -0.25), 1.0)
		_add_delta(target, "mixamorig_RightArm", Vector3(-0.08, 0.0, -0.25), 1.0)

	# Rotate the body exactly once. The old version spun both the waist bone
	# and this pivot, and shortest-angle smoothing even reversed the rotation.
	var roll_active := roll_progress >= 0.0
	if state_name == "roll" and roll_progress < 0.0:
		roll_progress = state_blend
		roll_active = true
	if roll_active:
		var rp := clampf(roll_progress, 0.0, 1.0)
		_roll_angle = -TAU * _ease(rp)
		var tuck := sin(PI * rp)
		body_height = roll_pivot_height - tuck * 0.15
		_add_delta(target, "mixamorig_Hips", Vector3(0.0, 0.0, -0.35 * tuck), 1.0)
		_add_delta(target, "mixamorig_Spine", Vector3(0.0, 0.0, -0.22 * tuck), 1.0)
		_add_delta(target, "mixamorig_Spine1", Vector3(0.0, 0.0, -0.18 * tuck), 1.0)
		_add_delta(target, "mixamorig_LeftUpLeg", Vector3(0.0, 0.0, -1.0 * tuck), 1.0)
		_add_delta(target, "mixamorig_RightUpLeg", Vector3(0.0, 0.0, -1.0 * tuck), 1.0)
		_add_delta(target, "mixamorig_LeftLeg", Vector3(0.0, 0.0, 1.45 * tuck), 1.0)
		_add_delta(target, "mixamorig_RightLeg", Vector3(0.0, 0.0, 1.45 * tuck), 1.0)
		_add_delta(target, "mixamorig_LeftArm", Vector3(0.06, 0.0, -0.75 * tuck), 1.0)
		_add_delta(target, "mixamorig_RightArm", Vector3(-0.06, 0.0, -0.75 * tuck), 1.0)
		_add_delta(target, "mixamorig_LeftForeArm", Vector3(0.0, 0.0, -0.85 * tuck), 1.0)
		_add_delta(target, "mixamorig_RightForeArm", Vector3(0.0, 0.0, -0.85 * tuck), 1.0)
	else:
		_roll_angle = 0.0
	rig_pivot.rotation.x = _roll_angle
	rig_pivot.position.y = body_height

	if dash_progress >= 0.0:
		var dash_blend := sin(clampf(dash_progress, 0.0, 1.0) * PI)
		_add_delta(target, "mixamorig_Spine", Vector3(0.0, 0.0, -0.12 * dash_blend), 1.0)
		_add_delta(target, "mixamorig_Spine1", Vector3(0.0, 0.0, -0.14 * dash_blend), 1.0)
		_add_delta(target, "mixamorig_LeftUpLeg", Vector3(0.0, 0.0, -0.42 * dash_blend), 1.0)
		_add_delta(target, "mixamorig_RightUpLeg", Vector3(0.0, 0.0, 0.30 * dash_blend), 1.0)
		_add_delta(target, "mixamorig_LeftLeg", Vector3(0.0, 0.0, 0.45 * dash_blend), 1.0)
		_add_delta(target, "mixamorig_RightLeg", Vector3(0.0, 0.0, 0.25 * dash_blend), 1.0)
		_add_delta(target, "mixamorig_LeftArm", Vector3(0.0, 0.0, 0.45 * dash_blend), 1.0)
		_add_delta(target, "mixamorig_RightArm", Vector3(0.0, 0.0, -0.55 * dash_blend), 1.0)

	# Author preparation, contact and recovery as separate poses. The elbow
	# flexes along Z with the shoulder; it never folds through the torso.
	if slash_progress >= 0.0:
		var sp := clampf(slash_progress, 0.0, 1.0)
		var upper := _three_phase(sp, Vector3(-0.58, 0.0, 0.82), Vector3(0.62, 0.0, 1.05), Vector3(0.06, 0.0, 0.14))
		var elbow := _three_phase(sp, Vector3(-0.48, 0.0, 0.38), Vector3(0.52, 0.0, 0.62), Vector3(0.04, 0.0, 0.12))
		var torso := _three_phase(sp, Vector3(0.0, -0.08, 0.06), Vector3(0.0, 0.10, 0.04), Vector3.ZERO)
		if attack_kind == "punch":
			upper = _three_phase(sp, Vector3(-0.18, 0.0, 0.10), Vector3(0.18, 0.0, 1.45), Vector3.ZERO)
			elbow = _three_phase(sp, Vector3(-0.18, 0.0, 0.18), Vector3(0.20, 0.0, 0.78), Vector3.ZERO)
		elif attack_kind == "shot":
			upper = Vector3(-0.04, 0.0, 1.20)
			elbow = Vector3(0.0, 0.0, 0.70)
		elif attack_kind == "charged_slash":
			upper = _three_phase(sp, Vector3(-0.72, 0.0, 1.00), Vector3(0.70, 0.0, 1.20), Vector3(0.02, 0.0, 0.10))
		_add_delta(target, "mixamorig_RightArm", upper, 1.0)
		_add_delta(target, "mixamorig_RightForeArm", elbow, 1.0)
		_add_delta(target, "mixamorig_RightHand", Vector3(0.0, 0.0, 0.08 * sin(sp * PI)), 1.0)
		_add_delta(target, "mixamorig_Spine2", torso, 1.0)
		_add_delta(target, "mixamorig_LeftArm", Vector3(0.04, 0.0, 0.32 * sin(sp * PI)), 1.0)
		_add_delta(target, "mixamorig_LeftForeArm", Vector3(0.0, 0.0, 0.45 * sin(sp * PI)), 1.0)

	if charge_amount > 0.0:
		_add_delta(target, "mixamorig_RightArm", Vector3(-0.20, 0.0, 1.9) * charge_amount, 1.0)
		_add_delta(target, "mixamorig_RightForeArm", Vector3(0.0, 0.0, 0.80) * charge_amount, 1.0)
	if diving:
		_add_delta(target, "mixamorig_Spine", Vector3(0.0, 0.0, -0.25), 1.0)
		_add_delta(target, "mixamorig_Spine1", Vector3(0.0, 0.0, -0.20), 1.0)
		_add_delta(target, "mixamorig_LeftUpLeg", Vector3(0.0, 0.0, -0.45), 1.0)
		_add_delta(target, "mixamorig_RightUpLeg", Vector3(0.0, 0.0, -0.30), 1.0)
	if dead:
		_add_delta(target, "mixamorig_Spine", Vector3(0.0, 0.0, -0.35), 1.0)
		_add_delta(target, "mixamorig_Spine1", Vector3(0.0, 0.0, -0.25), 1.0)
		_add_delta(target, "mixamorig_Head", Vector3(0.0, 0.0, -0.20), 1.0)
		rig_pivot.rotation.z = lerpf(rig_pivot.rotation.z, PI * 0.5, clampf(dt * 5.0, 0.0, 1.0))
		rig_pivot.position.y = lerpf(rig_pivot.position.y, 0.35, clampf(dt * 5.0, 0.0, 1.0))
	else:
		rig_pivot.rotation.z = 0.0

	# Interpolate every bone from the previous local delta.  Rest position and
	# scale are restored every time to preserve the imported skin bind.
	var action_speed := 36.0 if slash_progress >= 0.0 or roll_active else pose_lerp_speed
	var blend := 1.0 - exp(-dt * action_speed)
	for bone_index in skeleton.get_bone_count():
		_current_deltas[bone_index] = _current_deltas[bone_index].slerp(target[bone_index], blend)
		_apply_bone(bone_index, _current_deltas[bone_index])

	if is_instance_valid(tech_blade):
		tech_blade.visible = show_tech_blade and not dead
		if is_instance_valid(_blade_material):
			var glow := 1.0 + (1.5 if boost else 0.0) + damage_flash * 2.5
			_blade_material.emission_energy_multiplier = glow
			_blade_material.emission = Color("#ff7799") if damage_flash > 0.0 else Color("#24d8ff")


## Restore the complete imported bind pose.  This is intentionally explicit:
## setting pose rotation/position to identity/zero would collapse this FBX.
func reset_pose() -> void:
	if not _is_setup:
		setup()
	if not _is_setup:
		return
	_roll_angle = 0.0
	rig_pivot.rotation = Vector3.ZERO
	rig_pivot.position.y = roll_pivot_height
	for bone_index in skeleton.get_bone_count():
		_current_deltas[bone_index] = Quaternion.IDENTITY
		_apply_bone(bone_index, Quaternion.IDENTITY)
	_last_time = -INF


func _apply_bone(bone_index: int, delta: Quaternion) -> void:
	var pose_rotation := _rest_rotations[bone_index] * delta
	# The FBX's rest positions and scales are part of its bind pose.
	skeleton.set_bone_pose_rotation(bone_index, pose_rotation)
	skeleton.set_bone_pose_position(bone_index, _rest_positions[bone_index])
	skeleton.set_bone_pose_scale(bone_index, _rest_scales[bone_index])


func get_skeleton() -> Skeleton3D:
	setup()
	return skeleton


func _add_delta(target: Array[Quaternion], bone_name: String, euler: Vector3, weight: float) -> void:
	if not _bone_ids.has(bone_name):
		return
	var bone_index: int = _bone_ids[bone_name]
	var delta := Quaternion.from_euler(euler)
	target[bone_index] = target[bone_index].slerp(delta, clampf(weight, 0.0, 1.0))


func _three_phase(progress: float, preparation: Vector3, contact: Vector3, recovery: Vector3) -> Vector3:
	if progress < 0.22:
		return preparation * _ease(progress / 0.22)
	if progress < 0.60:
		return preparation.lerp(contact, _ease((progress - 0.22) / 0.38))
	return contact.lerp(recovery, _ease((progress - 0.60) / 0.40))


func _attack_envelope(progress: float) -> float:
	# A short anticipation, fast contact, then a soft follow-through.
	if progress < 0.22:
		return progress / 0.22 * 0.16
	if progress < 0.52:
		return lerpf(0.16, 1.0, (progress - 0.22) / 0.30)
	return lerpf(1.0, 0.28, (progress - 0.52) / 0.48)


func _ease(value: float) -> float:
	return value * value * (3.0 - 2.0 * value)
