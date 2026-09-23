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
## The replacement GLB contains the rest pose in Godot's standing orientation.
## The legacy FBX path is still supported with its historical -90-degree
## Armature correction. Every procedural pose is written as rest rotation *
## local delta, and rest position/scale are kept on every frame so a reset can
## never collapse the skinned mesh.

const CHARACTER_SCENE: PackedScene = preload("res://main Character/futuristic+armored+female+3d+model (5).glb")
const ACTION_ANIMATION_STATES: Array[String] = [
	"punch", "slash", "roll", "dash_slash",
	"sweep", "front_kick", "shot", "charged_slash", "airborne_slash", "dive_slash",
]

## World-space height of the imported character.  The first-floor buildings
## use a three-metre storey, so the player is authored at a human 1.8 m scale.
@export var visual_height: float = 1.8
@export var face_yaw: float = PI
@export var pose_lerp_speed: float = 14.0
@export var roll_pivot_height: float = 0.9
@export var show_tech_blade: bool = true
## When enabled, the imported rig is driven by the AnimationPlayer library
## instead of the legacy per-frame pose synthesis below.  Turning this off is
## useful when authoring or debugging procedural poses.
@export var use_animation_player: bool = true
## Drive the authored action clips from the replacement GLB. Missing legacy
## clips fall back to the closest available action (for example slash cards use
## the imported punch clip) so older cards remain playable while the library
## continues to grow.
@export var use_skill_animations: bool = true
@export_range(0.1, 2.0, 0.05) var run_animation_speed_scale: float = 0.5
@export_range(0.0, 0.5, 0.01) var locomotion_blend_duration: float = 0.18
## Action clips are authored much longer than their gameplay hit windows. This
## value slows the visual timeline relative to each short gameplay window. The
## visual tail continues after the hit window until the clip reaches its last
## key, while movement, hit detection and card timing remain responsive.
@export_range(0.01, 1.0, 0.01) var action_animation_speed_scale: float = 0.1
## The imported punch clip has a short lead-in before the actual strike. Start
## punch, slash and dash-slash visuals from this point and keep only the next
## half-second of authored motion; the later recovery keys read as an overly
## long afterswing in this prototype.
@export_range(0.0, 1.5, 0.05) var punch_animation_start_offset: float = 0.5
@export_range(0.05, 1.5, 0.05) var punch_animation_segment_duration: float = 0.5
## Roll movement and the authored forward-roll clip share the gameplay timeline.
@export_range(0.1, 2.0, 0.05) var roll_animation_speed_scale: float = 1.0
## The imported jump clip begins with a short run-up. Start playback at this
## offset so the visible action begins at takeoff while player physics stays
## unchanged. The value is clamped for shorter fallback clips.
@export_range(0.0, 1.5, 0.05) var jump_animation_start_offset: float = 0.5
@export_file("*.tres") var animation_library_path: String = "res://character_animations.tres"

var model_root: Node3D
var rig_pivot: Node3D
var armature: Node3D
var skeleton: Skeleton3D
var animation_player: AnimationPlayer
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
var _animation_library: AnimationLibrary
var _animation_available: bool = false
var _last_animation_name: String = ""
var _locomotion_blend_left: float = 0.0
var _animation_aliases: Dictionary = {}
var _visual_action_name: String = ""
var _visual_action_state: String = ""
var _visual_action_token: int = -1
var _visual_action_elapsed: float = 0.0
var _visual_action_duration: float = 0.0
var _visual_action_active: bool = false
var _visual_action_start_offset: float = 0.0
var _visual_action_end_offset: float = 0.0


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
	# The replacement GLB is already in Godot's standing orientation. The older
	# FBX needs the historical -90° conversion, so keep that path compatible.
	if CHARACTER_SCENE.resource_path.get_extension().to_lower() == "fbx":
		armature.rotation.x = -PI * 0.5
	else:
		armature.rotation = Vector3.ZERO
	skeleton = armature.get_node_or_null("Skeleton3D") as Skeleton3D
	if skeleton == null:
		push_error("character_visual.gd: FBX Skeleton3D node is missing")
		return

	_cache_bones()
	_create_animation_player()
	_create_tech_blade()
	_is_setup = true


func _create_animation_player() -> void:
	# Prefer clips authored inside the replacement GLB. Godot imports them as an
	# AnimationPlayer under the model root, so its Armature/Skeleton3D paths are
	# already correct and do not need to be copied into another library.
	var embedded := model_root.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if embedded != null and (embedded.has_animation("run") or embedded.has_animation("idle")):
		animation_player = embedded
		for clip_name in animation_player.get_animation_list():
			var clip := animation_player.get_animation(clip_name)
			if clip == null:
				continue
			if clip_name in ["idle", "run"]:
				clip.loop_mode = Animation.LOOP_LINEAR
			_strip_root_motion(clip)
			if clip_name == "idle":
				_lock_idle_lower_body(clip)
		_build_animation_aliases()
		_create_generated_sweep_animation()
		_create_generated_front_kick_animation()
		_animation_available = true
		return

	animation_player = AnimationPlayer.new()
	animation_player.name = "AnimationPlayer"
	# The generated library stores paths relative to the visual root, e.g.
	# RigPivot/TacticalFemale/Armature/Skeleton3D:mixamorig_RightArm.
	animation_player.root_node = NodePath("..")
	add_child(animation_player)
	_animation_library = load(animation_library_path) as AnimationLibrary
	if _animation_library == null:
		push_warning("character_visual.gd: animation library not found: %s" % animation_library_path)
		return
	animation_player.add_animation_library("", _animation_library)
	_build_animation_aliases()
	_create_generated_front_kick_animation()
	_animation_available = true


func _strip_root_motion(animation: Animation) -> void:
	# Player.gd owns world movement. The imported run/idle clips also contain a
	# Hips position track, which would otherwise make the model slide or move
	# twice as far as the collision capsule. Remove only that root-motion track.
	for track_index in range(animation.get_track_count() - 1, -1, -1):
		if animation.track_get_type(track_index) != Animation.TYPE_POSITION_3D:
			continue
		var path := String(animation.track_get_path(track_index))
		if path.ends_with(":mixamorig_Hips"):
			animation.remove_track(track_index)


func _lock_idle_lower_body(animation: Animation) -> void:
	# Keep the authored upper-body sway, but explicitly key every lower-body
	# joint at its imported bind pose. Removing these tracks entirely leaves the
	# last run pose in place during AnimationPlayer's run -> idle cross-fade,
	# because a track that does not exist cannot blend a leg back to rest.
	var lower_bones: Array[String] = [
		"mixamorig_Hips",
		"mixamorig_LeftUpLeg",
		"mixamorig_LeftLeg",
		"mixamorig_LeftFoot",
		"mixamorig_LeftToeBase",
		"mixamorig_RightUpLeg",
		"mixamorig_RightLeg",
		"mixamorig_RightFoot",
		"mixamorig_RightToeBase",
	]
	var locked: Dictionary = {}
	for track_index in range(animation.get_track_count()):
		if animation.track_get_type(track_index) != Animation.TYPE_ROTATION_3D:
			continue
		var path := String(animation.track_get_path(track_index))
		var bone_name := path.get_slice(":", 1)
		if not lower_bones.has(bone_name) or not _bone_ids.has(bone_name):
			continue
		var bone_index := int(_bone_ids[bone_name])
		var rest_rotation := _rest_rotations[bone_index]
		for key_index in range(animation.track_get_key_count(track_index)):
			animation.track_set_key_value(track_index, key_index, rest_rotation)
		locked[bone_name] = true

	# The idle source does not always include a Hips track. Add a constant track
	# for any missing lower joint so a previous run pose can never leak through.
	for bone_name in lower_bones:
		if locked.has(bone_name) or not _bone_ids.has(bone_name):
			continue
		var track_index := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track_index, NodePath("Armature/Skeleton3D:%s" % bone_name))
		animation.track_insert_key(track_index, 0.0, _rest_rotations[int(_bone_ids[bone_name])])
		animation.track_insert_key(track_index, animation.length, _rest_rotations[int(_bone_ids[bone_name])])


func _build_animation_aliases() -> void:
	_animation_aliases.clear()
	for logical_name in ["idle", "run", "punch", "roll", "jump", "sweep", "front_kick"]:
		var direct := ""
		if is_instance_valid(animation_player) and animation_player.has_animation(logical_name):
			direct = logical_name
		if direct.is_empty():
			var tokens: Array[String] = []
			match logical_name:
				"punch": tokens = ["punch", "拳"]
				"roll": tokens = ["roll", "翻滚", "翻"]
				"jump": tokens = ["jump", "leap", "跳"]
				# A front kick is a separate authored action. Do not let the sweep
				# alias claim it just because both names contain "kick".
				"sweep": tokens = ["sweep", "扫腿"]
				"front_kick": tokens = ["front_kick_02", "front kick 02", "front-kick-02", "frontkick02"]
				_: tokens = [logical_name]
			direct = _find_animation_by_tokens(tokens)
		if not direct.is_empty():
			_animation_aliases[logical_name] = direct


func _find_animation_by_tokens(tokens: Array[String]) -> String:
	if not is_instance_valid(animation_player):
		return ""
	for clip_name in animation_player.get_animation_list():
		var lowered := String(clip_name).to_lower()
		for token in tokens:
			if lowered.contains(token.to_lower()):
				return String(clip_name)
	return ""


func _create_generated_sweep_animation() -> void:
	if not is_instance_valid(animation_player) or _animation_aliases.has("sweep") or animation_player.has_animation("sweep_generated"):
		return
	var library := animation_player.get_animation_library("")
	if library == null:
		library = AnimationLibrary.new()
		animation_player.add_animation_library("", library)
	var animation := Animation.new()
	animation.length = 0.36
	animation.loop_mode = Animation.LOOP_NONE
	var tracks: Dictionary = {}
	for bone_name in ["mixamorig_Hips", "mixamorig_LeftUpLeg", "mixamorig_LeftLeg", "mixamorig_RightUpLeg", "mixamorig_RightLeg", "mixamorig_Spine", "mixamorig_Spine1", "mixamorig_LeftArm", "mixamorig_RightArm"]:
		if not _bone_ids.has(bone_name):
			continue
		var track_index := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track_index, NodePath("Armature/Skeleton3D:%s" % bone_name))
		tracks[bone_name] = track_index
	var poses: Array[Dictionary] = [
		{"time": 0.0, "hips": Vector3.ZERO, "left_up": Vector3.ZERO, "left_leg": Vector3.ZERO, "right_up": Vector3.ZERO, "right_leg": Vector3.ZERO, "spine": Vector3.ZERO, "spine1": Vector3.ZERO, "left_arm": Vector3.ZERO, "right_arm": Vector3.ZERO},
		{"time": 0.08, "hips": Vector3(0.0, 0.0, -0.16), "left_up": Vector3(0.0, 0.0, -0.24), "left_leg": Vector3(0.0, 0.0, 0.28), "right_up": Vector3(0.0, 0.0, -0.62), "right_leg": Vector3(0.0, 0.0, 0.95), "spine": Vector3(0.0, 0.0, -0.10), "spine1": Vector3(0.0, 0.0, -0.08), "left_arm": Vector3(0.0, 0.0, 0.18), "right_arm": Vector3(0.0, 0.0, -0.20)},
		{"time": 0.19, "hips": Vector3(0.0, 0.0, 0.10), "left_up": Vector3(0.0, 0.0, 0.22), "left_leg": Vector3(0.0, 0.0, -0.18), "right_up": Vector3(0.0, 0.0, 0.75), "right_leg": Vector3(0.0, 0.0, 1.25), "spine": Vector3(0.0, 0.0, 0.14), "spine1": Vector3(0.0, 0.0, 0.10), "left_arm": Vector3(0.0, 0.0, -0.18), "right_arm": Vector3(0.0, 0.0, 0.24)},
		{"time": 0.36, "hips": Vector3.ZERO, "left_up": Vector3.ZERO, "left_leg": Vector3.ZERO, "right_up": Vector3.ZERO, "right_leg": Vector3.ZERO, "spine": Vector3.ZERO, "spine1": Vector3.ZERO, "left_arm": Vector3.ZERO, "right_arm": Vector3.ZERO},
	]
	var keys_for: Dictionary = {"mixamorig_Hips": "hips", "mixamorig_LeftUpLeg": "left_up", "mixamorig_LeftLeg": "left_leg", "mixamorig_RightUpLeg": "right_up", "mixamorig_RightLeg": "right_leg", "mixamorig_Spine": "spine", "mixamorig_Spine1": "spine1", "mixamorig_LeftArm": "left_arm", "mixamorig_RightArm": "right_arm"}
	for bone_name in tracks:
		var bone_index := int(_bone_ids[bone_name])
		var track_index := int(tracks[bone_name])
		var pose_key: String = keys_for[bone_name]
		for pose: Dictionary in poses:
			var local_delta: Vector3 = pose[pose_key]
			animation.track_insert_key(track_index, float(pose["time"]), _rest_rotations[bone_index] * Quaternion.from_euler(local_delta))
	library.add_animation("sweep_generated", animation)
	_animation_aliases["sweep"] = "sweep_generated"


func _create_generated_front_kick_animation() -> void:
	# Some deliveries of the character GLB do not include front_kick_02 yet.
	# Keep the card functional with a dedicated leg animation generated from the
	# same rest pose; an authored clip with that exact name always wins.
	if not is_instance_valid(animation_player) or _animation_aliases.has("front_kick") or animation_player.has_animation("front_kick_02"):
		if is_instance_valid(animation_player) and animation_player.has_animation("front_kick_02"):
			_animation_aliases["front_kick"] = "front_kick_02"
		return
	var library := animation_player.get_animation_library("")
	if library == null:
		library = AnimationLibrary.new()
		animation_player.add_animation_library("", library)
	var animation := Animation.new()
	animation.length = 0.42
	animation.loop_mode = Animation.LOOP_NONE
	var tracks: Dictionary = {}
	for bone_name in ["mixamorig_Hips", "mixamorig_RightUpLeg", "mixamorig_RightLeg", "mixamorig_RightFoot", "mixamorig_LeftUpLeg", "mixamorig_Spine", "mixamorig_Spine1", "mixamorig_LeftArm", "mixamorig_RightArm"]:
		if not _bone_ids.has(bone_name):
			continue
		var track_index := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track_index, NodePath("Armature/Skeleton3D:%s" % bone_name))
		tracks[bone_name] = track_index
	var poses: Array[Dictionary] = [
		{"time": 0.0, "hips": Vector3.ZERO, "right_up": Vector3.ZERO, "right_leg": Vector3.ZERO, "right_foot": Vector3.ZERO, "left_up": Vector3.ZERO, "spine": Vector3.ZERO, "spine1": Vector3.ZERO, "left_arm": Vector3.ZERO, "right_arm": Vector3.ZERO},
		{"time": 0.10, "hips": Vector3(0.0, 0.0, -0.12), "right_up": Vector3(-0.48, 0.0, 0.08), "right_leg": Vector3(0.72, 0.0, 0.0), "right_foot": Vector3(-0.18, 0.0, 0.0), "left_up": Vector3(0.12, 0.0, -0.05), "spine": Vector3(0.0, 0.0, -0.08), "spine1": Vector3(0.0, 0.0, -0.06), "left_arm": Vector3(0.0, 0.0, 0.18), "right_arm": Vector3(0.0, 0.0, -0.18)},
		{"time": 0.19, "hips": Vector3(0.0, 0.0, 0.04), "right_up": Vector3(-1.02, 0.0, 0.10), "right_leg": Vector3(1.30, 0.0, 0.0), "right_foot": Vector3(-0.38, 0.0, 0.0), "left_up": Vector3(0.16, 0.0, -0.06), "spine": Vector3(0.0, 0.0, 0.16), "spine1": Vector3(0.0, 0.0, 0.11), "left_arm": Vector3(0.0, 0.0, -0.16), "right_arm": Vector3(0.0, 0.0, 0.18)},
		{"time": 0.42, "hips": Vector3.ZERO, "right_up": Vector3.ZERO, "right_leg": Vector3.ZERO, "right_foot": Vector3.ZERO, "left_up": Vector3.ZERO, "spine": Vector3.ZERO, "spine1": Vector3.ZERO, "left_arm": Vector3.ZERO, "right_arm": Vector3.ZERO},
	]
	var keys_for: Dictionary = {"mixamorig_Hips": "hips", "mixamorig_RightUpLeg": "right_up", "mixamorig_RightLeg": "right_leg", "mixamorig_RightFoot": "right_foot", "mixamorig_LeftUpLeg": "left_up", "mixamorig_Spine": "spine", "mixamorig_Spine1": "spine1", "mixamorig_LeftArm": "left_arm", "mixamorig_RightArm": "right_arm"}
	for bone_name in tracks:
		var bone_index := int(_bone_ids[bone_name])
		var track_index := int(tracks[bone_name])
		for pose: Dictionary in poses:
			animation.track_insert_key(track_index, float(pose["time"]), _rest_rotations[bone_index] * Quaternion.from_euler(pose[keys_for[bone_name]]))
	library.add_animation("front_kick_02", animation)
	_animation_aliases["front_kick"] = "front_kick_02"


func _has_animation(animation_name: String) -> bool:
	return not _resolve_animation_name(animation_name).is_empty()


func _get_animation(animation_name: String) -> Animation:
	var resolved := _resolve_animation_name(animation_name)
	if is_instance_valid(animation_player) and animation_player.has_animation(resolved):
		return animation_player.get_animation(resolved)
	if _animation_library != null and _animation_library.has_animation(resolved):
		return _animation_library.get_animation(resolved)
	return null


func _resolve_animation_name(logical_name: String) -> String:
	if not is_instance_valid(animation_player):
		return ""
	if animation_player.has_animation(logical_name):
		return logical_name
	if _animation_aliases.has(logical_name):
		return String(_animation_aliases[logical_name])
	if logical_name == "walk" and _animation_aliases.has("run"):
		return String(_animation_aliases["run"])
	# front_kick deliberately has no replacement clip. Until an authored front
	# kick is present, normal state fallback keeps idle instead of presenting a
	# punch or generated sweep as the requested animation.
	# Legacy attack cards share the authored punch clip until dedicated clips
	# are added to the model.
	if logical_name in ["slash", "dash_slash", "shot", "charged_slash", "airborne_slash", "dive_slash"] and _animation_aliases.has("punch"):
		return String(_animation_aliases["punch"])
	if logical_name == "dead" and _animation_aliases.has("idle"):
		return String(_animation_aliases["idle"])
	return ""


func _locomotion_animation_name() -> String:
	return "run" if _has_animation("run") else "walk"


func _jump_animation_start_time(animation: Animation) -> float:
	if animation == null or animation.length <= 0.0:
		return 0.0
	# Leave a tiny final slice available so a short fallback clip cannot seek
	# beyond its valid range.
	return clampf(jump_animation_start_offset, 0.0, maxf(0.0, animation.length - 0.001))


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
		var bone_name := skeleton.get_bone_name(bone_index)
		_bone_ids[bone_name] = bone_index
		# Support both Mixamo naming conventions used by the old FBX and the
		# replacement GLB (mixamorig_LeftArm vs mixamorig:LeftArm).
		if bone_name.begins_with("mixamorig:"):
			_bone_ids[bone_name.replace("mixamorig:", "mixamorig_")] = bone_index
		elif bone_name.begins_with("mixamorig_"):
			_bone_ids[bone_name.replace("mixamorig_", "mixamorig:")] = bone_index


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

	# AnimationPlayer owns the Skeleton3D pose in this mode.  Return before the
	# procedural target array is built so no set_bone_pose_* call can overwrite
	# an authored keyframe during the same frame.
	if use_animation_player and _animation_available:
		_apply_animation_state(state_name, state, roll_progress, dash_progress, slash_progress, attack_kind, charge_amount, diving, dead, airborne, move_amount, boost, damage_flash, dt)
		return
	if is_instance_valid(animation_player) and animation_player.is_playing():
		# Allow the exported switch to be changed while running. The procedural
		# path below will write a complete pose on this same frame.
		animation_player.stop()
		_last_animation_name = ""
	if is_instance_valid(animation_player) and _last_animation_name != "":
		# A runtime toggle back to procedural authoring must release the
		# AnimationPlayer before set_bone_pose_* writes resume.
		animation_player.stop()
		_last_animation_name = ""

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
		var upper := _three_phase(sp, Vector3(-0.82, 0.0, -0.72), Vector3(0.36, 0.0, -0.95), Vector3(0.06, 0.0, -0.10))
		var elbow := _three_phase(sp, Vector3(-0.42, 0.0, -0.35), Vector3(0.34, 0.0, -0.48), Vector3(0.04, 0.0, -0.08))
		var torso := _three_phase(sp, Vector3(0.0, -0.08, -0.05), Vector3(0.0, 0.10, -0.08), Vector3.ZERO)
		if attack_kind == "punch":
			upper = _three_phase(sp, Vector3(-0.24, 0.0, -0.10), Vector3(0.22, 0.0, -1.35), Vector3.ZERO)
			elbow = _three_phase(sp, Vector3(-0.20, 0.0, -0.18), Vector3(0.24, 0.0, -0.72), Vector3.ZERO)
		elif attack_kind == "shot":
			upper = Vector3(-0.04, 0.0, -1.15)
			elbow = Vector3(0.0, 0.0, -0.65)
		elif attack_kind == "charged_slash":
			upper = _three_phase(sp, Vector3(-0.90, 0.0, -0.95), Vector3(0.42, 0.0, -1.10), Vector3(0.02, 0.0, -0.08))
		_add_delta(target, "mixamorig_RightArm", upper, 1.0)
		_add_delta(target, "mixamorig_RightForeArm", elbow, 1.0)
		_add_delta(target, "mixamorig_RightHand", Vector3(0.0, 0.0, -0.08 * sin(sp * PI)), 1.0)
		_add_delta(target, "mixamorig_Spine2", torso, 1.0)
		_add_delta(target, "mixamorig_LeftArm", Vector3(0.04, 0.0, -0.32 * sin(sp * PI)), 1.0)
		_add_delta(target, "mixamorig_LeftForeArm", Vector3(0.0, 0.0, -0.45 * sin(sp * PI)), 1.0)

	if charge_amount > 0.0:
		_add_delta(target, "mixamorig_RightArm", Vector3(-0.20, 0.0, -1.9) * charge_amount, 1.0)
		_add_delta(target, "mixamorig_RightForeArm", Vector3(0.0, 0.0, -0.80) * charge_amount, 1.0)
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

	_update_blade_presentation(dead, boost, damage_flash)


func _apply_animation_state(state_name: String, state: Dictionary, roll_progress: float, dash_progress: float, slash_progress: float, attack_kind: String, charge_amount: float, diving: bool, dead: bool, airborne: bool, move_amount: float, boost: bool, damage_flash: float, dt: float) -> void:
	var requested_state := _animation_name_for_state(state_name, state, attack_kind, charge_amount, diving, dead, airborne, move_amount, slash_progress, roll_progress, dash_progress)
	var requested := _resolve_animation_name(requested_state)
	if requested.is_empty():
		requested_state = "idle"
		requested = _resolve_animation_name(requested_state)
	if requested.is_empty():
		return

	var gameplay_action := _is_action_animation_state(requested_state)
	var incoming_token := int(state.get("action_visual_token", -1))
	var hold_action_visual := false
	var leaving_finished_visual := false
	if not _visual_action_name.is_empty() and (
		dead or (incoming_token >= 0 and incoming_token != _visual_action_token and not gameplay_action)
	):
		# A reset, death, jump, or movement card owns the next visual state and
		# should be able to cancel a long action tail immediately.
		_cancel_visual_action()
	if gameplay_action:
		var token_changed := incoming_token >= 0 and incoming_token != _visual_action_token
		var fallback_action_changed := incoming_token < 0 and (_visual_action_name.is_empty() or _visual_action_state != requested_state)
		var clip_changed := not _visual_action_name.is_empty() and _visual_action_name != requested
		if token_changed or fallback_action_changed or clip_changed:
			_begin_visual_action(
				requested,
				requested_state,
				incoming_token,
				maxf(float(state.get("action_duration", 0.14)), 0.01),
			)
		_advance_visual_action(dt, roll_progress)
		if not _visual_action_name.is_empty():
			# Keep the action clip visible even after the gameplay hit/roll timer
			# expires. A later card can interrupt it by changing the token.
			requested = _visual_action_name
			requested_state = _visual_action_state
			hold_action_visual = true
	elif not _visual_action_name.is_empty():
		if _visual_action_active:
			_advance_visual_action(dt, roll_progress)
		if _visual_action_active:
			requested = _visual_action_name
			requested_state = _visual_action_state
			hold_action_visual = true
		else:
			# The clip reached its final key. Let the requested idle/run/jump
			# state take over on this frame.
			leaving_finished_visual = true

	if _last_animation_name != requested:
		# Idle is authored in the imported rest pose, so blending into it after
		# reset would briefly apply an unrelated cross-fade pose. Action changes
		# retain a short blend for readable transitions.
		var previous_animation := _last_animation_name
		if requested == "idle":
			skeleton.reset_bone_poses()
		animation_player.speed_scale = run_animation_speed_scale if requested_state in ["run", "walk"] else 1.0
		var blend_time := 0.0
		var previous_locomotion := previous_animation in [_resolve_animation_name("idle"), _resolve_animation_name("run")]
		var requested_locomotion := requested_state in ["idle", "run", "walk"]
		if previous_locomotion and requested_locomotion and previous_animation != requested:
			blend_time = locomotion_blend_duration
		_locomotion_blend_left = blend_time
		animation_player.play(requested, blend_time if blend_time > 0.0 else (0.0 if requested == "idle" else 0.08))
		_last_animation_name = requested
		# Apply the first key immediately. This keeps a newly selected action
		# visible even when the caller is sampling from a physics callback.
		animation_player.advance(0.0)
		if requested_state == "jump":
			# The imported jump clip contains a run-up before the actual takeoff.
			# Skip that authored lead-in only when entering the clip; subsequent
			# frames advance normally from the trimmed start point.
			var jump_animation := _get_animation(requested)
			if jump_animation != null:
				animation_player.seek(_jump_animation_start_time(jump_animation), true)

	if hold_action_visual:
		# Action clips are advanced by _advance_visual_action(), which seeks the
		# paused AnimationPlayer manually. This prevents the imported player from
		# racing the independent visual timeline.
		pass
	elif _locomotion_blend_left > 0.0:
		_locomotion_blend_left = maxf(0.0, _locomotion_blend_left - dt)
	elif requested_state in ["walk", "run"]:
		# The locomotion clip is looping. The gameplay walk phase is more stable than
		# frame-rate playback and also makes synchronous pose previews deterministic.
		var locomotion_animation := _get_animation(requested)
		if locomotion_animation != null and locomotion_animation.length > 0.0:
			var walk_phase := fposmod(float(state.get("walk_phase", 0.0)) * run_animation_speed_scale, TAU) / TAU
			animation_player.seek(walk_phase * locomotion_animation.length, true)
	if leaving_finished_visual and requested != _visual_action_name:
		_visual_action_name = ""
		_visual_action_state = ""
		_visual_action_token = -1
	var rp := clampf(roll_progress, 0.0, 1.0) if roll_progress >= 0.0 else 0.0
	var tuck := sin(PI * rp) if roll_progress >= 0.0 else 0.0
	if not use_skill_animations:
		rig_pivot.rotation = Vector3.ZERO
		rig_pivot.position.y = roll_pivot_height
	elif roll_progress >= 0.0:
		# The authored GLB roll clip already rotates the hips. Do not add a second
		# full turn on the outer pivot, which would make the character spin twice.
		rig_pivot.rotation.x = 0.0 if _has_animation("roll") else -TAU * _ease(rp)
		rig_pivot.rotation.z = 0.0
		rig_pivot.position.y = roll_pivot_height - tuck * 0.15
	elif dead:
		rig_pivot.rotation.x = 0.0
		rig_pivot.rotation.z = PI * 0.5
		rig_pivot.position.y = 0.35
	else:
		rig_pivot.rotation = Vector3.ZERO
		rig_pivot.position.y = roll_pivot_height

	_update_blade_presentation(dead, boost, damage_flash)


func _is_action_animation_state(state_name: String) -> bool:
	return state_name in ACTION_ANIMATION_STATES


func _begin_visual_action(resolved_name: String, logical_state: String, token: int, gameplay_duration: float) -> void:
	var animation := _get_animation(resolved_name)
	if animation == null or animation.length <= 0.0:
		return
	_visual_action_name = resolved_name
	_visual_action_state = logical_state
	_visual_action_token = token
	_visual_action_elapsed = 0.0
	_visual_action_start_offset = _action_animation_start_time(logical_state, animation)
	_visual_action_end_offset = _action_animation_end_time(logical_state, animation, _visual_action_start_offset)
	if logical_state in ["punch", "slash", "dash_slash"]:
		# These three logical actions share the imported punch clip. Keep the
		# visible segment short enough that the player can immediately choose the
		# next card after contact instead of watching a long recovery tail.
		_visual_action_duration = maxf(minf(punch_animation_segment_duration, _visual_action_end_offset - _visual_action_start_offset), 0.01)
	elif logical_state == "roll":
		_visual_action_duration = maxf(gameplay_duration / maxf(roll_animation_speed_scale, 0.001), 0.01)
	else:
		_visual_action_duration = maxf(gameplay_duration / maxf(action_animation_speed_scale, 0.001), 0.01)
	_visual_action_active = true
	_locomotion_blend_left = 0.0
	animation_player.stop()
	animation_player.play(resolved_name, 0.0)
	# The visual timeline is advanced explicitly below. A zero speed scale keeps
	# AnimationPlayer's idle/physics callback from adding time between seeks.
	animation_player.speed_scale = 0.0
	animation_player.seek(_visual_action_start_offset, true)
	_last_animation_name = resolved_name


func _cancel_visual_action() -> void:
	if is_instance_valid(animation_player):
		animation_player.speed_scale = 1.0
	_visual_action_name = ""
	_visual_action_state = ""
	_visual_action_token = -1
	_visual_action_elapsed = 0.0
	_visual_action_duration = 0.0
	_visual_action_active = false
	_visual_action_start_offset = 0.0
	_visual_action_end_offset = 0.0


func _action_animation_start_time(logical_state: String, animation: Animation) -> float:
	if animation == null or animation.length <= 0.0:
		return 0.0
	if logical_state in ["punch", "slash", "dash_slash"]:
		return clampf(punch_animation_start_offset, 0.0, maxf(animation.length - 0.001, 0.0))
	return 0.0


func _action_animation_end_time(logical_state: String, animation: Animation, start_offset: float) -> float:
	if animation == null or animation.length <= 0.0:
		return 0.0
	if logical_state in ["punch", "slash", "dash_slash"]:
		# The current GLB's punch clip is about 1.96 s long. The useful contact
		# and early recovery occupy [0.5, 1.0], while keys after that are the
		# excessive afterswing the player asked to remove.
		return clampf(start_offset + punch_animation_segment_duration, start_offset, animation.length)
	return animation.length


func _advance_visual_action(dt: float, roll_progress: float = -1.0) -> void:
	if not _visual_action_active or _visual_action_name.is_empty():
		return
	var animation := _get_animation(_visual_action_name)
	if animation == null or animation.length <= 0.0:
		_visual_action_active = false
		return
	if _visual_action_state == "roll" and roll_progress >= 0.0:
		# Use the same normalized progress as CharacterBody3D movement so the
		# authored roll and the physical displacement land on the same frame.
		_visual_action_elapsed = _visual_action_duration * clampf(roll_progress, 0.0, 1.0)
	else:
		_visual_action_elapsed = minf(_visual_action_duration, _visual_action_elapsed + maxf(dt, 0.0))
	var progress := clampf(_visual_action_elapsed / maxf(_visual_action_duration, 0.001), 0.0, 1.0)
	animation_player.seek(lerpf(_visual_action_start_offset, _visual_action_end_offset, progress), true)
	if progress >= 1.0:
		_visual_action_active = false


func _animation_name_for_state(state_name: String, state: Dictionary, attack_kind: String, charge_amount: float, diving: bool, dead: bool, airborne: bool, move_amount: float, slash_progress: float, roll_progress: float, dash_progress: float) -> String:
	if not use_skill_animations:
		return _locomotion_animation_name() if move_amount > 0.01 and not airborne and not dead else "idle"
	if dead or state_name == "dead":
		return "dead"
	if diving or state_name == "dive":
		return "dive_slash"
	# A dash is already a dash-slash card even during its wind-up. Once the
	# follow-up melee starts, the same clip continues from its gameplay timer.
	if state_name == "dash_slash" or dash_progress >= 0.0:
		return "dash_slash"
	if state_name == "charged_slash" or charge_amount > 0.0:
		return "charged_slash"
	if state_name in ["slash", "punch", "sweep", "front_kick", "shot", "airborne_slash", "dive_slash"]:
		return state_name
	if slash_progress >= 0.0:
		if attack_kind in ["punch", "sweep", "front_kick", "shot", "charged_slash", "airborne_slash", "dive_slash"]:
			return attack_kind
		return "slash"
	if roll_progress >= 0.0 or state_name == "roll":
		return "roll"
	if airborne or state_name in ["jump", "airborne"]:
		return "jump"
	if move_amount > 0.01 or state_name in ["walk", "moving"]:
		return _locomotion_animation_name()
	return "idle"


func _update_blade_presentation(dead: bool, boost: bool, damage_flash: float) -> void:
	if not is_instance_valid(tech_blade):
		return
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
	if is_instance_valid(animation_player):
		animation_player.stop()
		animation_player.speed_scale = 1.0
	_last_animation_name = ""
	_locomotion_blend_left = 0.0
	_visual_action_name = ""
	_visual_action_state = ""
	_visual_action_token = -1
	_visual_action_elapsed = 0.0
	_visual_action_duration = 0.0
	_visual_action_active = false
	_visual_action_start_offset = 0.0
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
