extends CharacterBody3D
## A training opponent: follow the player while raising the blade, then commit
## to a short, fixed-direction strike. Roll timing beats the committed swing.

signal health_changed(current: float, maximum: float)
signal defeated

const COMBAT_HIT = preload("res://combat_hit.gd")
const LABEL_FONT = preload("res://assets/fonts/NotoSansSC-Regular.ttf")

@export var max_health: float = 100.0
@export var display_name: String = "训练对手"
@export var spawn_position: Vector3 = Vector3(0.0, 0.0, -2.0)
@export var attack_damage: float = 20.0
@export var aggro_range: float = 3.5
@export var attack_start_range: float = 2.6
@export var move_speed: float = 6.2
@export var windup_duration: float = 0.30
@export var aim_lock_duration: float = 0.30
@export var active_duration: float = 0.12
@export var recovery_duration: float = 1.2
@export var attack_reach: float = 3.8
@export var attack_half_angle: float = deg_to_rad(80.0)
@export var vertical_reach: float = 1.1
@export var radius: float = 0.4

var health: float = 100.0
var is_dead: bool = false
var combat_enabled: bool = true
var state: StringName = &"idle"
var state_time_left: float = 0.0
var attack_direction: Vector3 = Vector3.BACK
var _actor: CharacterBody3D
var _hit_this_swing: bool = false
var _hurt_time_left: float = 0.0
var _walk_phase: float = 0.0
var _heading: Node3D
var _body_pivot: Node3D
var _right_arm: Node3D
var _left_arm: Node3D
var _left_leg: Node3D
var _right_leg: Node3D
var _warning: Node3D
var _slash_arc: Node3D
var _health_label: Label3D
var _body_material: StandardMaterial3D
var _warning_material: StandardMaterial3D
var _warning_edge_material: StandardMaterial3D
var _slash_material: StandardMaterial3D


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	collision_layer = 4
	collision_mask = 1
	floor_snap_length = 0.2
	add_to_group("combat_targets")
	_build_model()
	reset_enemy()


func setup(actor: CharacterBody3D) -> void:
	_actor = actor


func reset_enemy() -> void:
	health = max_health
	is_dead = false
	global_position = spawn_position
	velocity = Vector3.ZERO
	collision_layer = 4
	collision_mask = 1
	state = &"idle"
	state_time_left = 0.0
	attack_direction = Vector3.BACK
	_hit_this_swing = false
	_hurt_time_left = 0.0
	_walk_phase = 0.0
	if is_instance_valid(_heading):
		_heading.rotation.y = _direction_yaw(attack_direction)
		_update_model()
	health_changed.emit(health, max_health)


func take_damage(amount: float) -> bool:
	if is_dead or amount <= 0.0 or get_tree().paused:
		return false
	health = maxf(0.0, health - amount)
	_hurt_time_left = 0.16
	# A successful player hit never cancels the telegraph or stun-locks the foe.
	if health <= 0.0:
		is_dead = true
		state = &"dead"
		state_time_left = 0.0
		velocity = Vector3.ZERO
		collision_layer = 0
		collision_mask = 0
		_hit_this_swing = true
	_update_model()
	health_changed.emit(health, max_health)
	if is_dead:
		defeated.emit()
	return true


func _physics_process(delta: float) -> void:
	_hurt_time_left = maxf(0.0, _hurt_time_left - delta)
	if is_dead:
		_update_model()
		return
	velocity.x = 0.0
	velocity.z = 0.0
	if not combat_enabled or not is_instance_valid(_actor) or _actor.is_dead:
		state = &"idle"
		state_time_left = 0.0
	else:
		_update_combat(delta)
	velocity.y = -0.1 if is_on_floor() else maxf(velocity.y - 24.0 * delta, -30.0)
	move_and_slide()
	_walk_phase += Vector2(velocity.x, velocity.z).length() * delta * 2.1
	# A swing resolves once on contact, either as damage or a successful dodge.
	# Its trailing frames must not hit again after a well-timed roll ends.
	if state == &"strike" and not _hit_this_swing and is_instance_valid(_actor) and not _actor.is_dead:
		if COMBAT_HIT.can_hit(self, _actor, attack_direction, attack_reach, attack_half_angle, vertical_reach):
			if _actor.is_rolling:
				_hit_this_swing = true
				_actor.status_changed.emit("翻滚闪避成功 · 等待收招反击", false)
			else:
				_hit_this_swing = _actor.take_damage(attack_damage)
	_update_model()


func _update_combat(delta: float) -> void:
	var offset := _actor.global_position - global_position
	offset.y = 0.0
	var distance := offset.length()
	match state:
		&"idle", &"chase":
			var engagement_range := maxf(aggro_range, 8.0) if state == &"chase" else aggro_range
			if distance > engagement_range:
				state = &"idle"
			elif distance <= attack_start_range:
				_begin_windup(offset)
			else:
				state = &"chase"
				_track_and_approach(offset, delta)
		&"windup":
			# Only the early part of a windup tracks. Once the red warning locks,
			# both the origin and direction stay fixed through the entire strike.
			var tracking_step := minf(delta, maxf(0.0, state_time_left - aim_lock_duration))
			if tracking_step > 0.0:
				_track_and_approach(offset, delta, tracking_step)
			state_time_left = maxf(0.0, state_time_left - delta)
			if state_time_left <= 0.0:
				state = &"strike"
				state_time_left = active_duration
				velocity.x = 0.0
				velocity.z = 0.0
		&"strike":
			state_time_left = maxf(0.0, state_time_left - delta)
			if state_time_left <= 0.0:
				state = &"recovery"
				state_time_left = recovery_duration
		&"recovery":
			state_time_left = maxf(0.0, state_time_left - delta)
			if state_time_left <= 0.0:
				state = &"idle"


func _begin_windup(offset: Vector3) -> void:
	state = &"windup"
	state_time_left = windup_duration
	_hit_this_swing = false
	if not offset.is_zero_approx():
		attack_direction = offset.normalized()
	_heading.rotation.y = _direction_yaw(attack_direction)


func _track_and_approach(offset: Vector3, delta: float, movement_step: float = -1.0) -> void:
	if not offset.is_zero_approx():
		attack_direction = offset.normalized()
	_heading.rotation.y = _direction_yaw(attack_direction)
	# Leave room to read the pose and step back if the player walks into us.
	# The gap at aim lock prevents simply walking through the foe to its back.
	var step := delta if movement_step < 0.0 else movement_step
	var desired_travel := offset.length() - 1.65
	if state != &"windup":
		desired_travel = maxf(0.0, desired_travel)
	var travel := clampf(desired_travel, -move_speed * step, move_speed * step)
	var speed := travel / maxf(delta, 0.0001)
	velocity.x = attack_direction.x * speed
	velocity.z = attack_direction.z * speed


func _update_model() -> void:
	if not is_instance_valid(_body_pivot):
		return
	_body_material.albedo_color = Color("ffd9a4") if _hurt_time_left > 0.0 else Color("d35b3c")
	_body_pivot.position.y = 0.8
	_body_pivot.rotation = Vector3.ZERO
	var moving := Vector2(velocity.x, velocity.z).length() > 0.1
	var stride := sin(_walk_phase) * 0.42 if moving else 0.0
	_left_leg.rotation.x = stride
	_right_leg.rotation.x = -stride
	_left_arm.rotation = Vector3(-stride * 0.6, 0.0, 0.0)
	_right_arm.rotation = Vector3(stride * 0.45, 0.0, 0.0)
	# The short windup is the complete reaction window. Show the sector only
	# while the raised weapon can still be dodged; hide it during chase and
	# recovery so the arena stays readable.
	var dodge_warning_active := state == &"windup"
	_warning.visible = dodge_warning_active
	_warning.rotation.y = _direction_yaw(attack_direction)
	_slash_arc.visible = state == &"strike"
	_slash_arc.rotation.y = _direction_yaw(attack_direction)
	var status_text := ""
	var label_color := Color("ffd1a1")
	match state:
		&"chase":
			pass
		&"windup":
			var progress := 1.0 - state_time_left / maxf(windup_duration, 0.001)
			_right_arm.rotation = Vector3(lerpf(0.4, 1.95, minf(1.0, progress * 3.0)), 0.0, -0.2)
			_left_arm.rotation.x = -0.5
			_body_pivot.rotation.x = -0.09
			var locked := state_time_left <= aim_lock_duration
			_warning_material.albedo_color = Color(1.0, 0.17, 0.08, 0.42) if locked else Color(1.0, 0.56, 0.08, 0.22 + progress * 0.12)
			_warning_edge_material.albedo_color = Color("ff563f") if locked else Color("ffd278")
			status_text = "· 翻滚" if locked else ""
			label_color = Color("ff8970") if locked else Color("ffe3a5")
		&"strike":
			var progress := 1.0 - state_time_left / maxf(active_duration, 0.001)
			_right_arm.rotation = Vector3(lerpf(1.95, -0.8, progress), lerpf(-0.5, 0.8, progress), -0.2)
			_body_pivot.rotation.x = -0.18
			_slash_material.albedo_color.a = 0.75 * (1.0 - progress * 0.65)
			status_text = "· 劈砍"
			label_color = Color("ff8d72")
		&"recovery":
			var progress := 1.0 - state_time_left / maxf(recovery_duration, 0.001)
			_right_arm.rotation.x = lerpf(-0.8, 0.0, progress)
			_body_pivot.rotation.x = lerpf(-0.2, 0.0, progress)
			status_text = "· 反击"
			label_color = Color("a1f0c7")
		&"dead":
			_body_pivot.rotation.z = PI * 0.5
			_body_pivot.position.y = 0.35
			_body_material.albedo_color = Color("715a52")
			label_color = Color("c3d3d5")
	_health_label.text = "%s  %.0f / %.0f%s" % [display_name, health, max_health, status_text]
	_health_label.modulate = label_color


func _direction_yaw(direction: Vector3) -> float:
	return atan2(-direction.x, -direction.z)


func _build_model() -> void:
	var collision := CollisionShape3D.new()
	collision.name = "StandingCapsule"
	var shape := CapsuleShape3D.new()
	shape.radius = radius
	shape.height = 1.6
	collision.shape = shape
	collision.position.y = 0.8
	add_child(collision)
	_body_material = _make_material(Color("d35b3c"))
	var dark := _make_material(Color("4d302e"))
	var joint := _make_material(Color("62463d"))
	var orange := _make_material(Color("ffb469"), true)
	var steel := _make_material(Color("e7bd9a"))
	_heading = Node3D.new()
	_heading.name = "Facing"
	add_child(_heading)
	_body_pivot = Node3D.new()
	_body_pivot.name = "Model"
	_body_pivot.position.y = 0.8
	_heading.add_child(_body_pivot)
	_add_box(_body_pivot, Vector3(0.0, 0.09, 0.0), Vector3(0.58, 0.67, 0.4), _body_material)
	_add_box(_body_pivot, Vector3(0.0, 0.12, -0.22), Vector3(0.38, 0.3, 0.07), dark)
	_add_box(_body_pivot, Vector3(0.0, 0.12, -0.265), Vector3(0.18, 0.07, 0.03), orange)
	_add_box(_body_pivot, Vector3(0.0, 0.63, 0.0), Vector3(0.44, 0.43, 0.4), dark)
	_add_box(_body_pivot, Vector3(0.0, 0.65, -0.215), Vector3(0.33, 0.09, 0.035), orange)
	_left_leg = _make_joint("LeftLeg", Vector3(-0.16, -0.25, 0.0))
	_right_leg = _make_joint("RightLeg", Vector3(0.16, -0.25, 0.0))
	for leg in [_left_leg, _right_leg]:
		_add_box(leg, Vector3(0.0, -0.22, 0.0), Vector3(0.21, 0.43, 0.24), joint)
		_add_box(leg, Vector3(0.0, -0.46, -0.065), Vector3(0.25, 0.16, 0.36), dark)
	_left_arm = _make_joint("LeftArm", Vector3(-0.4, 0.36, 0.0))
	_right_arm = _make_joint("RightArm", Vector3(0.4, 0.36, 0.0))
	for arm in [_left_arm, _right_arm]:
		_add_box(arm, Vector3(0.0, -0.21, 0.0), Vector3(0.18, 0.47, 0.21), _body_material)
		_add_box(arm, Vector3(0.0, -0.44, 0.0), Vector3(0.2, 0.16, 0.2), dark)
	var sword := Node3D.new()
	sword.name = "TrainingBlade"
	sword.position = Vector3(0.0, -0.43, -0.06)
	_right_arm.add_child(sword)
	_add_box(sword, Vector3(0.0, 0.0, -0.13), Vector3(0.075, 0.09, 0.29), joint)
	_add_box(sword, Vector3(0.0, 0.0, -0.3), Vector3(0.36, 0.1, 0.08), orange)
	_add_box(sword, Vector3(0.0, 0.0, -0.97), Vector3(0.2, 0.07, 1.3), steel)
	_add_box(sword, Vector3(0.10, 0.0, -0.97), Vector3(0.025, 0.08, 1.3), orange)
	_warning = Node3D.new()
	_warning.name = "AttackWarning"
	_warning.position.y = 0.035
	add_child(_warning)
	_warning_material = _make_material(Color(1.0, 0.56, 0.08, 0.28), true, true)
	_warning_edge_material = _make_material(Color("ffd278"), true)
	_warning_edge_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_add_sector(_warning, 0.0, attack_reach, _warning_material)
	_add_sector(_warning, attack_reach - 0.045, attack_reach, _warning_edge_material)
	for angle in [-attack_half_angle, attack_half_angle]:
		var edge := _add_box(_warning, Vector3(sin(angle), 0.002, -cos(angle)) * attack_reach * 0.5, Vector3(0.035, 0.012, attack_reach), _warning_edge_material)
		edge.rotation.y = -angle
	_slash_arc = Node3D.new()
	_slash_arc.name = "StrikeArc"
	_slash_arc.position.y = 0.82
	add_child(_slash_arc)
	_slash_material = _make_material(Color(1.0, 0.31, 0.10, 0.75), true, true)
	_add_sector(_slash_arc, 1.05, attack_reach, _slash_material)
	_health_label = Label3D.new()
	_health_label.name = "HealthAndState"
	_health_label.font = LABEL_FONT
	_health_label.font_size = 40
	_health_label.pixel_size = 0.0085
	_health_label.outline_size = 9
	_health_label.outline_modulate = Color("24272d")
	_health_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_health_label.position.y = 3.35
	_health_label.no_depth_test = true
	add_child(_health_label)


func _make_joint(joint_name: String, local_position: Vector3) -> Node3D:
	var joint := Node3D.new()
	joint.name = joint_name
	joint.position = local_position
	_body_pivot.add_child(joint)
	return joint


func _make_material(color: Color, glowing: bool = false, transparent: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.8
	if glowing:
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if transparent:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func _add_box(parent: Node3D, center: Vector3, size: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = center
	parent.add_child(instance)
	return instance


func _add_sector(parent: Node3D, inner_radius: float, outer_radius: float, material: Material) -> void:
	var vertices := PackedVector3Array()
	var segments := 40
	for index in range(segments):
		var a := lerpf(-attack_half_angle, attack_half_angle, float(index) / float(segments))
		var b := lerpf(-attack_half_angle, attack_half_angle, float(index + 1) / float(segments))
		var inner_a := Vector3(sin(a) * inner_radius, 0.0, -cos(a) * inner_radius)
		var outer_a := Vector3(sin(a) * outer_radius, 0.0, -cos(a) * outer_radius)
		var inner_b := Vector3(sin(b) * inner_radius, 0.0, -cos(b) * inner_radius)
		var outer_b := Vector3(sin(b) * outer_radius, 0.0, -cos(b) * outer_radius)
		vertices.append_array(PackedVector3Array([inner_a, outer_a, outer_b, inner_a, outer_b, inner_b]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)
