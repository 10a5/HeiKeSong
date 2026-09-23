extends SceneTree
## Visual regression checks for the imported tactical character.
## Run with:
## Godot --headless --path . --fixed-fps 60 --script tests/test_character_visual.gd --quit-after 1200

const ACTIONS: Array[String] = [
	"move_left", "move_right", "move_up", "move_down",
	"hand_1", "hand_2", "hand_3", "hand_4", "jump", "cybernetic_boost"
]
const EPS := 0.015

var scene: Node3D
var player: CharacterBody3D
var visual: Node
var skeleton: Skeleton3D
var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var packed := load("res://main.tscn") as PackedScene
	_check(packed != null, "Main scene can be loaded")
	if packed == null:
		_finish()
		return
	scene = packed.instantiate() as Node3D
	root.add_child(scene)
	await process_frame
	player = scene.get("player") as CharacterBody3D
	if player == null:
		player = scene.get_node_or_null("Player") as CharacterBody3D
	_check(player != null, "Main scene exposes a CharacterBody3D player")
	if player == null:
		_finish()
		return
	visual = _find_visual(player)
	_check(visual != null, "Player contains the imported character visual controller")
	if visual == null:
		_finish()
		return
	skeleton = visual.call("get_skeleton") as Skeleton3D
	_check(skeleton != null, "Character visual exposes its Skeleton3D")
	if skeleton == null:
		_finish()
		return
	_check(skeleton.get_bone_count() >= 40, "Imported character has a full humanoid skeleton")
	var meshes := visual.find_children("*", "MeshInstance3D", true, false)
	_check(not meshes.is_empty(), "Imported character has visible skinned mesh geometry")
	var has_humanoid_size := _has_humanoid_bounds(meshes)
	_check(has_humanoid_size, "Imported mesh has a usable humanoid size")
	_check(_has_floor_scale(meshes), "Imported character is approximately 1.8 metres tall")
	var armature := _find_named_descendant(visual, "Armature") as Node3D
	_check(armature != null, "Imported model keeps its Armature orientation node")
	if armature != null:
		var standing_fbx := absf(absf(wrapf(armature.rotation.x, -PI, PI)) - PI / 2.0) < 0.25
		var standing_glb := absf(wrapf(armature.rotation.x, -PI, PI)) < 0.25
		_check(standing_fbx or standing_glb, "Imported Armature keeps a standing orientation")
	_check(_find_bone("mixamorig_RightArm", "RightArm") >= 0, "Imported skeleton contains a right arm bone")
	_check(_find_bone("mixamorig_LeftArm", "LeftArm") >= 0, "Imported skeleton contains a left arm bone")
	_check(_find_bone("mixamorig_RightUpLeg", "RightUpLeg") >= 0, "Imported skeleton contains a right leg bone")
	_check(_find_bone("mixamorig_LeftUpLeg", "LeftUpLeg") >= 0, "Imported skeleton contains a left leg bone")

	await _steps(2)
	await _test_reset_and_idle_pose()
	await _test_walk_pose()
	await _test_walk_to_idle_transition()
	_test_walk_joint_trajectories()
	await _test_attack_pose()
	await _test_new_card_animation_mapping()
	await _test_action_animation_completion()
	await _test_roll_and_slash_chain()
	await _test_pause_and_reset()
	_release_all()
	_finish()


func _find_visual(node: Node) -> Node:
	for child in node.find_children("*", "Node", true, false):
		if child.has_method("apply_state") and child.has_method("reset_pose") and child.has_method("get_skeleton"):
			return child
	return null


func _find_named_descendant(node: Node, target_name: String) -> Node:
	if node.name == target_name:
		return node
	for child in node.get_children():
		var found := _find_named_descendant(child, target_name)
		if found != null:
			return found
	return null


func _has_humanoid_bounds(meshes: Array[Node]) -> bool:
	if meshes.is_empty():
		return false
	var min_corner := Vector3(INF, INF, INF)
	var max_corner := Vector3(-INF, -INF, -INF)
	var found := false
	var to_visual: Transform3D = visual.global_transform.affine_inverse()
	for mesh_node in meshes:
		var mesh_instance := mesh_node as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var aabb := mesh_instance.get_aabb()
		var mesh_to_visual: Transform3D = to_visual * mesh_instance.global_transform
		for x in [aabb.position.x, aabb.end.x]:
			for y in [aabb.position.y, aabb.end.y]:
				for z in [aabb.position.z, aabb.end.z]:
					var point: Vector3 = mesh_to_visual * Vector3(float(x), float(y), float(z))
					min_corner = min_corner.min(point)
					max_corner = max_corner.max(point)
					found = true
	if not found:
		return false
	var size := max_corner - min_corner
	return size.y > 0.6 and size.x > 0.05 and size.z > 0.05


func _has_floor_scale(meshes: Array[Node]) -> bool:
	if meshes.is_empty():
		return false
	var min_corner := Vector3(INF, INF, INF)
	var max_corner := Vector3(-INF, -INF, -INF)
	var found := false
	var to_visual: Transform3D = visual.global_transform.affine_inverse()
	for mesh_node in meshes:
		var mesh_instance := mesh_node as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var aabb := mesh_instance.get_aabb()
		var mesh_to_visual: Transform3D = to_visual * mesh_instance.global_transform
		for x in [aabb.position.x, aabb.end.x]:
			for y in [aabb.position.y, aabb.end.y]:
				for z in [aabb.position.z, aabb.end.z]:
					var point: Vector3 = mesh_to_visual * Vector3(float(x), float(y), float(z))
					min_corner = min_corner.min(point)
					max_corner = max_corner.max(point)
					found = true
	if not found:
		return false
	var height := (max_corner - min_corner).y
	return height > 1.72 and height < 1.88


func _find_bone(primary: String, fallback: String) -> int:
	var id := skeleton.find_bone(primary)
	return id if id >= 0 else skeleton.find_bone(fallback)


func _pose(id: int) -> Transform3D:
	return skeleton.get_bone_pose(id)


func _pose_changed(before: Transform3D, after: Transform3D, tolerance: float = EPS) -> bool:
	if before.origin.distance_to(after.origin) > tolerance:
		return true
	return before.basis.get_rotation_quaternion().angle_to(after.basis.get_rotation_quaternion()) > tolerance


func _test_reset_and_idle_pose() -> void:
	player.reset_player()
	await _steps(2)
	var arm_id := _find_bone("mixamorig_RightArm", "RightArm")
	var leg_id := _find_bone("mixamorig_RightUpLeg", "RightUpLeg")
	visual.call("reset_pose")
	var arm_rest := _pose(arm_id)
	var leg_rest := _pose(leg_id)
	visual.call("apply_state", {"state": "idle", "blend": 1.0, "speed": 0.0})
	var animation_player := visual.get("animation_player") as AnimationPlayer
	_check(animation_player == null or animation_player.current_animation == "idle", "Character visual accepts an idle AnimationPlayer state")
	visual.call("reset_pose")
	_check(not _pose_changed(arm_rest, _pose(arm_id), 0.05), "Reset pose preserves the imported right arm bind pose")
	_check(not _pose_changed(leg_rest, _pose(leg_id), 0.05), "Reset pose preserves the imported right leg bind pose")


func _test_walk_pose() -> void:
	var leg_id := _find_bone("mixamorig_RightUpLeg", "RightUpLeg")
	var before := _pose(leg_id)
	Input.action_press("move_up")
	await _steps(10)
	var during := _pose(leg_id)
	_check(_pose_changed(before, during), "Walking drives a visible leg pose on the imported skeleton")
	var animation_player := visual.get("animation_player") as AnimationPlayer
	if animation_player != null:
		print("WALK ANIMATION: ", animation_player.current_animation, " pos=", animation_player.current_animation_position)
	_check(animation_player == null or animation_player.current_animation in ["run", "walk"], "Walking selects the AnimationPlayer run clip")
	_release_all()
	await _steps(1)
	_check(player.global_position.z < 1.2, "Walking still moves the real player capsule")


func _test_walk_to_idle_transition() -> void:
	var leg_id := _find_bone("mixamorig_RightUpLeg", "RightUpLeg")
	player.reset_player()
	await _steps(12)
	var idle_pose := _pose(leg_id)
	Input.action_press("move_up")
	await _steps(10)
	Input.action_release("move_up")
	# The locomotion blend is 0.18 seconds. Wait beyond it so this verifies the
	# final planted pose rather than only the first idle frame.
	await _steps(18)
	var animation_player := visual.get("animation_player") as AnimationPlayer
	_check(animation_player == null or animation_player.current_animation == "idle", "Stopping movement selects the idle AnimationPlayer clip")
	_check(not _pose_changed(idle_pose, _pose(leg_id), 0.05), "Stopping movement returns the upper leg to its planted idle pose")
	player.reset_player()
	await _steps(2)


func _test_walk_joint_trajectories() -> void:
	# Measure joint positions after the entire imported transform hierarchy.
	# A rotating leg quaternion alone cannot tell a forward stride from a
	# sideways leg spread when the FBX's local bone axes are different.
	var joints := {
		"left ankle": _find_bone("mixamorig_LeftFoot", "LeftFoot"),
		"right ankle": _find_bone("mixamorig_RightFoot", "RightFoot"),
		"left knee": _find_bone("mixamorig_LeftLeg", "LeftLeg"),
		"right knee": _find_bone("mixamorig_RightLeg", "RightLeg"),
	}
	var trajectories: Dictionary = {}
	for label: String in joints:
		_check(int(joints[label]) >= 0, "Walking trajectory has a real %s joint" % label)
		if int(joints[label]) < 0:
			return
		trajectories[label] = []

	visual.call("reset_pose")
	const SAMPLES_PER_CYCLE := 60
	# Settle blending over two cycles, then record one complete cycle. This
	# synchronous loop prevents live input/physics from overwriting the poses.
	for sample in range(SAMPLES_PER_CYCLE * 3):
		visual.call("apply_state", {
			"time": float(sample + 1) / 60.0,
			"walk_phase": TAU * float(sample) / float(SAMPLES_PER_CYCLE),
			"move_amount": 1.0,
			"airborne": false,
			"vertical_speed": 0.0,
		})
		if sample < SAMPLES_PER_CYCLE * 2:
			continue
		var skeleton_to_character: Transform3D = (visual as Node3D).global_transform.affine_inverse() * skeleton.global_transform
		for label: String in joints:
			var joint_pose := skeleton.get_bone_global_pose(int(joints[label]))
			var character_position: Vector3 = skeleton_to_character * joint_pose.origin
			trajectories[label].append(character_position)

	for label: String in trajectories:
		var extent := _trajectory_extent(trajectories[label])
		print("WALK TRAJECTORY %s: X=%.4f m, Z=%.4f m" % [label, extent.x, extent.z])
		var minimum_stride := 0.05 if label.ends_with("ankle") else 0.03
		_check(extent.z > minimum_stride, "%s visibly travels forward and backward during walking" % label)
		_check(extent.z > extent.x * 1.1, "%s run cycle has useful forward/back travel" % label)
	var ankle_correlation := _z_trajectory_correlation(trajectories["left ankle"], trajectories["right ankle"])
	var knee_correlation := _z_trajectory_correlation(trajectories["left knee"], trajectories["right knee"])
	print("WALK PHASE: ankle correlation=%.4f, knee correlation=%.4f" % [ankle_correlation, knee_correlation])
	_check(ankle_correlation < -0.65, "Left and right ankles alternate their forward stride")
	_check(absf(knee_correlation) > 0.2, "Left and right knees have distinct alternating run motion")
	visual.call("reset_pose")
	player.reset_player()


func _trajectory_extent(positions: Array) -> Vector3:
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	for point: Vector3 in positions:
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	return maximum - minimum


func _z_trajectory_correlation(left: Array, right: Array) -> float:
	var left_mean := 0.0
	var right_mean := 0.0
	for index in range(left.size()):
		left_mean += (left[index] as Vector3).z
		right_mean += (right[index] as Vector3).z
	left_mean /= float(left.size())
	right_mean /= float(right.size())
	var covariance := 0.0
	var left_variance := 0.0
	var right_variance := 0.0
	for index in range(left.size()):
		var left_offset: float = (left[index] as Vector3).z - left_mean
		var right_offset: float = (right[index] as Vector3).z - right_mean
		covariance += left_offset * right_offset
		left_variance += left_offset * left_offset
		right_variance += right_offset * right_offset
	var denominator := sqrt(left_variance * right_variance)
	# A stationary foot is a failure, not an apparently alternating stride.
	return covariance / denominator if denominator > 0.000001 else 0.0


func _test_attack_pose() -> void:
	var arm_id := _find_bone("mixamorig_RightArm", "RightArm")
	player.reset_player()
	await _steps(2)
	var before := _pose(arm_id)
	_check(player.request_card("slash"), "Slash starts while using the imported character")
	await _steps(1)
	var during := _pose(arm_id)
	var animation_player := visual.get("animation_player") as AnimationPlayer
	_check(animation_player == null or animation_player.current_animation == "punch", "The former slash card now selects the imported punch clip")
	_check(_pose_changed(before, during), "The punch clip changes the imported arm pose")
	if animation_player != null and animation_player.current_animation == "punch":
		var punch_clip := animation_player.get_animation("punch")
		var punch_start := float(visual.get("punch_animation_start_offset"))
		var punch_segment := float(visual.get("punch_animation_segment_duration"))
		_check(animation_player.current_animation_position >= punch_start - 0.01 and animation_player.current_animation_position <= punch_start + punch_segment + 0.01, "Punch skips its lead-in and stays inside the trimmed half-second segment")
	await _steps(18)
	_check(player.slash_time_left <= 0.0, "Slash visual action completes")


func _test_new_card_animation_mapping() -> void:
	var animation_player := visual.get("animation_player") as AnimationPlayer
	_check(animation_player != null, "Latest character model exposes its AnimationPlayer")
	if animation_player == null:
		return
	player.reset_player()
	await _steps(2)
	_check(player.request_card("dash_slash"), "The former dash-slash card remains playable")
	await _steps(1)
	_check(animation_player.current_animation == "punch", "Dash-slash now uses the imported punch clip")
	if animation_player.current_animation == "punch":
		var punch_clip := animation_player.get_animation("punch")
		var punch_start := float(visual.get("punch_animation_start_offset"))
		var punch_segment := float(visual.get("punch_animation_segment_duration"))
		_check(animation_player.current_animation_position >= punch_start - 0.01 and animation_player.current_animation_position <= punch_start + punch_segment + 0.01, "Dash punch skips its lead-in and stays inside the trimmed half-second segment")
	await _steps(18)
	player.reset_player()
	await _steps(2)
	_check(player.request_card("sweep"), "The sweep card starts from the player action API")
	await _steps(1)
	_check(animation_player.current_animation == "sweep_generated" or animation_player.current_animation.to_lower().contains("sweep"), "Sweep selects the sweep animation mapping")
	await _steps(20)
	player.reset_player()
	await _steps(2)
	_check(player.request_jump(), "Jump starts from the player action API")
	await _steps(1)
	_check(animation_player.current_animation.to_lower().contains("jump") or animation_player.current_animation.contains("跳"), "Jump selects the authored jump animation")
	_check(animation_player.current_animation_position >= 0.49, "Jump animation skips its first 0.5 seconds")
	var jump_start_position := animation_player.current_animation_position
	await _steps(4)
	_check(animation_player.current_animation_position > jump_start_position + 0.03, "Trimmed jump animation continues advancing after its new start")
	await _steps(30)


func _test_action_animation_completion() -> void:
	var animation_player := visual.get("animation_player") as AnimationPlayer
	_check(animation_player != null, "Action completion test has an AnimationPlayer")
	if animation_player == null:
		return
	for card in ["punch", "roll", "dash_slash"]:
		player.reset_player()
		await _steps(2)
		_check(player.request_card(card), "%s starts for the complete visual timeline" % card)
		await _steps(18)
		var clip_name := animation_player.current_animation
		var clip := animation_player.get_animation(clip_name)
		_check(clip != null, "%s resolves to a playable authored clip" % card)
		if clip == null:
			continue
		var during_gameplay_tail := animation_player.current_animation_position
		_check(during_gameplay_tail > 0.0 and during_gameplay_tail < clip.length - 0.01, "%s is still in its visual tail after the gameplay window" % card)
		var visual_duration := float(visual.get("_visual_action_duration"))
		if card == "roll":
			_check(absf(visual_duration - player.roll_duration) < 0.02, "%s visual duration matches the slowed roll movement" % card)
		else:
			_check(absf(visual_duration - float(visual.get("punch_animation_segment_duration"))) < 0.02, "%s visual duration is trimmed to 0.5 seconds" % card)
		await _steps(int(ceil(visual_duration * 60.0)) + 8)
		_check(float(visual.get("_visual_action_elapsed")) >= visual_duration - 0.001, "%s reaches the end of its independent visual timeline" % card)
		if animation_player.current_animation == clip_name:
			if card == "roll":
				_check(animation_player.current_animation_position >= clip.length - 0.05, "%s reaches the final roll key" % card)
			else:
				var expected_end := float(visual.get("punch_animation_start_offset")) + float(visual.get("punch_animation_segment_duration"))
				_check(absf(animation_player.current_animation_position - expected_end) < 0.06, "%s stops at the trimmed punch segment end" % card)
		await _steps(3)
		_check(animation_player.current_animation in ["idle", "run"], "%s returns to locomotion after its clip finishes" % card)


func _test_roll_and_slash_chain() -> void:
	var hips_id := _find_bone("mixamorig_Hips", "Hips")
	var arm_id := _find_bone("mixamorig_RightArm", "RightArm")
	player.reset_player()
	await _steps(2)
	var hips_before := _pose(hips_id)
	var rig_pivot := visual.get_node("RigPivot") as Node3D
	var pivot_before := rig_pivot.rotation.x if rig_pivot != null else 0.0
	_check(player.request_card("roll"), "Roll starts with the imported character")
	await _steps(1)
	var hips_roll := _pose(hips_id)
	var pivot_roll := rig_pivot.rotation.x if rig_pivot != null else pivot_before
	var animation_player := visual.get("animation_player") as AnimationPlayer
	_check(_pose_changed(hips_before, hips_roll) or absf(pivot_roll - pivot_before) > 0.015 or (animation_player != null and animation_player.current_animation == "idle"), "Roll keeps the locomotion-only animation policy")
	if animation_player != null and animation_player.current_animation.contains("翻滚"):
		var roll_clip := animation_player.get_animation(animation_player.current_animation)
		_check(animation_player.current_animation_position > 0.0 and animation_player.current_animation_position < roll_clip.length, "Roll animation advances on the independent 0.1 visual timeline")
	var arm_before_chain := _pose(arm_id)
	_check(player.request_card("slash"), "Slash can chain during roll")
	await _steps(1)
	var arm_roll_slash := _pose(arm_id)
	_check(_pose_changed(arm_before_chain, arm_roll_slash) or player.slash_time_left > 0.0, "Roll plus slash keeps an active linked visual state")
	await _steps(32)
	_check(not player.is_rolling and player.slash_time_left <= 0.0, "Roll plus slash returns to control")


func _test_pause_and_reset() -> void:
	player.reset_player()
	await _steps(2)
	visual.call("reset_pose")
	var rest_arm_pose := _pose(_find_bone("mixamorig_RightArm", "RightArm"))
	_check(player.request_card("slash"), "Pause test starts a slash")
	await _steps(1)
	var arm_id := _find_bone("mixamorig_RightArm", "RightArm")
	var paused_pose := _pose(arm_id)
	scene.get_tree().paused = true
	await _steps(8)
	_check(not _pose_changed(paused_pose, _pose(arm_id), 0.001), "Paused game freezes the imported character pose")
	scene.get_tree().paused = false
	player.reset_player()
	visual.call("reset_pose")
	await _steps(2)
	_check(player.slash_time_left <= 0.0 and not player.is_rolling, "Reset clears visual action timers")
	visual.call("reset_pose")
	_check(not _pose_changed(rest_arm_pose, _pose(arm_id), 0.02), "Reset pose restores the imported arm bind pose")


func _steps(count: int) -> void:
	for _index in range(count):
		await physics_frame
		await process_frame


func _release_all() -> void:
	for action in ACTIONS:
		Input.action_release(action)


func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
		print("PASS: " + description)
	else:
		failed += 1
		push_error("FAIL: " + description)


func _finish() -> void:
	print("CHARACTER VISUAL RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)
