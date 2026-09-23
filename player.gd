extends CharacterBody3D
## Horizontal actions use XZ; jump and future flight use independent Y motion.
## The collision capsule stays upright while the model turns and animates.

signal energy_changed(current: float, maximum: float)
signal action_played(action_name: String, cost: float)
signal action_attempted(action_name: String, accepted: bool, reason: String)
signal status_changed(message: String, is_error: bool)
signal cybernetic_changed(active_time_left: float, cooldown_left: float)
signal health_changed(current: float, maximum: float)
signal shield_changed(current: float)
signal damaged(amount: float)
signal defeated()

const COMBAT = preload("res://combat_hit.gd")
const CARD_CATALOG = preload("res://card_catalog.gd")
const CHARACTER_VISUAL = preload("res://character_visual.gd")
const ROLL_ATTACKS: Array[String] = ["punch", "slash", "sweep", "front_kick", "shot"]

@export var move_speed: float = 5.5
@export_range(60.0, 720.0, 15.0) var turn_speed_degrees: float = 360.0
@export_range(0.0, 1.0, 0.05) var min_turn_speed_ratio: float = 0.10
@export var jump_speed: float = 8.0
@export var gravity: float = 24.0
@export var max_fall_speed: float = 30.0
@export_range(0.0, 0.5, 0.01) var max_step_height: float = 0.30
## The roll keeps its authored duration while covering two-thirds of the
## previous 6.16 metre travel distance, about 4.11 metres.
@export var roll_speed: float = 9.333333
@export var roll_duration: float = 0.44
@export var dash_speed: float = 16.0
@export var dash_duration: float = 0.24
@export var max_energy: float = 10.0
@export var energy_regen_per_second: float = 2.0
@export var slash_cost: float = 2.0
@export var roll_cost: float = 3.0
@export var dash_slash_cost: float = 5.0
@export var slash_visual_duration: float = 0.14
@export var arena_rect: Rect2 = Rect2(-10.0, -8.0, 20.0, 16.0)
@export var bounds_enabled: bool = true
@export var spawn_position: Vector3 = Vector3(0.0, 0.0, 2.0)
@export var radius: float = 0.35
@export_group("Combat")
@export var max_health: float = 100.0
@export_range(0.05, 10.0, 0.05) var shield_decay_interval: float = 0.2
@export var slash_damage: float = 25.0
@export var dash_slash_damage: float = 45.0
@export var slash_reach: float = 2.1
@export var dash_slash_reach: float = 2.8
@export var slash_half_angle: float = deg_to_rad(65.0)
@export var melee_vertical_reach: float = 1.1
@export var combo_slash_duration: float = 0.10
@export var combo_window_duration: float = 0.16
@export_group("Additional Card Actions")
@export var punch_damage: float = 12.0
@export var punch_reach: float = 1.05
@export var sweep_damage: float = 22.0
@export var sweep_reach: float = 1.65
@export var sweep_visual_duration: float = 0.18
@export var front_kick_damage: float = 50.0
@export var front_kick_radius: float = 2.0
@export var front_kick_hit_duration: float = 0.18
@export_range(0.0, 2.0, 0.05) var front_kick_damage_delay: float = 0.8
## The kick remains locked for its complete accelerated visual action.
@export_range(0.1, 2.0, 0.05) var front_kick_action_duration: float = 0.9
@export var shield_per_card: float = 10.0
@export var shot_damage: float = 18.0
@export var shot_range: float = 10.0
@export var charged_slash_damage: float = 45.0
@export var charged_slash_windup: float = 0.20
@export var blink_distance: float = 3.5
@export var jet_jump_speed: float = 10.6
@export var airborne_slash_damage: float = 20.0
@export var dive_slash_damage: float = 60.0
@export var dive_radius: float = 2.6
@export_group("Initial Cybernetic / Burst Speed")
@export_range(0.1, 30.0, 0.1) var cybernetic_duration: float = 3.0
## Cooldown begins on activation, alongside the active duration.
@export_range(0.1, 60.0, 0.1) var cybernetic_cooldown: float = 8.0
@export_range(1.0, 5.0, 0.1) var cybernetic_speed_multiplier: float = 1.8

var cybernetic_time_left: float = 0.0
var cybernetic_cooldown_left: float = 0.0
var is_cybernetic_active: bool:
	get:
		return cybernetic_time_left > 0.0
var movement_yaw: float = 0.0
## Runtime flight hooks: net Y acceleration = lift - scaled gravity.
## A future skill can cancel gravity for hover or add lift for takeoff.
var gravity_scale: float = 1.0
var vertical_acceleration: float = 0.0
var energy: float = 10.0
var health: float = 100.0
var shield: float = 0.0
var _shield_decay_elapsed: float = 0.0
var is_dead: bool = false
var _damage_flash_left: float = 0.0
var _slash_targets_hit: Array[int] = []
var _buffered_card: String = ""
var combo_window_left: float = 0.0
var _slash_is_combo: bool = false
var charge_time_left: float = 0.0
var charge_direction: Vector3 = Vector3.FORWARD
var is_diving: bool = false
var dive_startup_left: float = 0.0
var dive_direction: Vector3 = Vector3.FORWARD
var jet_jump_used: bool = false
var airborne_slash_used: bool = false
var air_move_time_left: float = 0.0
var air_move_direction: Vector3 = Vector3.FORWARD
var air_move_speed: float = 0.0
var _active_attack_kind: String = "slash"
var _active_melee_damage: float = 25.0
var _active_melee_reach: float = 2.1
var _active_melee_half_angle: float = deg_to_rad(65.0)
var _active_melee_vertical_reach: float = 1.1
var _roll_attack_used: bool = false
var _action_effects: Array[Dictionary] = []
var facing: Vector3 = Vector3.FORWARD
var _visual_yaw: float = 0.0
var is_rolling: bool = false
var roll_direction: Vector3 = Vector3.FORWARD
var roll_time_left: float = 0.0
var is_dashing: bool = false
var dash_direction: Vector3 = Vector3.FORWARD
var dash_time_left: float = 0.0
var slash_time_left: float = 0.0
var front_kick_lock_time_left: float = 0.0
var front_kick_damage_delay_left: float = 0.0
var front_kick_damage_fired: bool = false
var slash_direction: Vector3 = Vector3.FORWARD
var _dash_slash_started: bool = false
var _dash_targets_hit: Array[int] = []
var _slash_is_dash: bool = false
var _active_slash_duration: float = 0.14
## Monotonically increasing token for visual action clips.  Gameplay actions
## can hand off from a dash into its hit window without restarting the same
## visual clip, while a newly played card can interrupt a visual tail.
var _action_visual_token: int = 0
var _trail: Array[Dictionary] = []
var _trail_clock: float = 0.0
var _life_time: float = 0.0
var _walk_phase: float = 0.0
var _heading: Node3D
var _body_pivot: Node3D
var _character_visual: Node3D
var _left_arm: Node3D
var _right_arm: Node3D
var _left_leg: Node3D
var _right_leg: Node3D
var _sword: Node3D
var _slash_root: Node3D
var _slash_material: StandardMaterial3D
var _slash_edge_material: StandardMaterial3D
var _body_material: StandardMaterial3D
var _implant_material: StandardMaterial3D
var _cybernetic_ring: MeshInstance3D
var _cybernetic_trail_clock: float = 0.0
var _step_support_active: bool = false
var _implant_base_stats: Dictionary = {}
var implant_damage_multiplier: float = 1.0
var implant_damage_reduction_multiplier: float = 1.0


func _ready() -> void:
	collision_layer = 2
	collision_mask = 1
	_capture_implant_base_stats()
	_build_model()
	reset_player()


func _capture_implant_base_stats() -> void:
	if _implant_base_stats.is_empty():
		_implant_base_stats = {
			"move_speed": move_speed,
			"max_energy": max_energy,
			"energy_regen_per_second": energy_regen_per_second,
		}


func apply_implant_bonuses(bonuses: Dictionary) -> void:
	# Recompute from authored values every time, including unequip and sale.
	_capture_implant_base_stats()
	implant_damage_multiplier = 1.0 + maxf(0.0, float(bonuses.get("damage_bonus", 0.0)))
	implant_damage_reduction_multiplier = clampf(float(bonuses.get("damage_reduction_multiplier", 1.0)), 0.0, 1.0)
	move_speed = float(_implant_base_stats["move_speed"]) * (1.0 + maxf(0.0, float(bonuses.get("move_speed_bonus", 0.0))))
	max_energy = float(_implant_base_stats["max_energy"]) * (1.0 + maxf(0.0, float(bonuses.get("energy_capacity_bonus", 0.0))))
	energy_regen_per_second = float(_implant_base_stats["energy_regen_per_second"]) * (1.0 + maxf(0.0, float(bonuses.get("energy_regen_bonus", 0.0))))
	# A larger battery grants capacity, never free energy. Removing one clamps it.
	energy = minf(energy, max_energy)
	energy_changed.emit(energy, max_energy)


func get_attack_damage(base_damage: float) -> float:
	return base_damage * implant_damage_multiplier


func reset_player() -> void:
	set_physics_process(true)
	_action_visual_token += 1
	energy = max_energy
	health = max_health
	shield = 0.0
	_shield_decay_elapsed = 0.0
	is_dead = false
	_damage_flash_left = 0.0
	_slash_targets_hit.clear()
	_buffered_card = ""
	combo_window_left = 0.0
	_slash_is_combo = false
	_clear_extra_actions()
	global_position = spawn_position
	velocity = Vector3.ZERO
	_step_support_active = false
	gravity_scale = 1.0
	vertical_acceleration = 0.0
	facing = Vector3.FORWARD
	_visual_yaw = _direction_yaw(facing)
	_heading.rotation.y = _visual_yaw
	roll_direction = Vector3.FORWARD
	dash_direction = Vector3.FORWARD
	slash_direction = Vector3.FORWARD
	is_rolling = false
	is_dashing = false
	roll_time_left = 0.0
	dash_time_left = 0.0
	slash_time_left = 0.0
	front_kick_lock_time_left = 0.0
	front_kick_damage_delay_left = 0.0
	front_kick_damage_fired = false
	_dash_targets_hit.clear()
	cybernetic_time_left = 0.0
	cybernetic_cooldown_left = 0.0
	_cybernetic_trail_clock = 0.0
	_dash_slash_started = false
	_slash_is_dash = false
	for echo in _trail:
		if is_instance_valid(echo["node"]):
			echo["node"].queue_free()
	_trail.clear()
	_trail_clock = 0.0
	_life_time = 0.0
	_walk_phase = 0.0
	_clamp_to_arena()
	if is_instance_valid(_character_visual) and _character_visual.has_method("reset_pose"):
		_character_visual.reset_pose()
	_update_model(Vector3.ZERO)
	energy_changed.emit(energy, max_energy)
	health_changed.emit(health, max_health)
	shield_changed.emit(shield)
	cybernetic_changed.emit(cybernetic_time_left, cybernetic_cooldown_left)
	status_changed.emit("准备就绪 · 选择一张动作牌", false)


func _physics_process(delta: float) -> void:
	_life_time += delta
	_damage_flash_left = maxf(0.0, _damage_flash_left - delta)
	if is_dead:
		_step_support_active = false
		_update_visual_timers(delta)
		_update_vertical_velocity(delta)
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		_update_model(Vector3.ZERO)
		return
	_update_shield_decay(delta)
	var previous_energy := energy
	energy = minf(max_energy, energy + energy_regen_per_second * delta)
	if not is_equal_approx(energy, previous_energy):
		energy_changed.emit(energy, max_energy)
	_update_visual_timers(delta)
	combo_window_left = maxf(0.0, combo_window_left - delta)
	if is_on_floor() and velocity.y <= 0.0 and not is_diving:
		jet_jump_used = false
		airborne_slash_used = false
	_update_charge(delta)

	var input_direction := _get_input_direction()
	if not is_action_locked():
		if input_direction != Vector3.ZERO:
			facing = input_direction.normalized()

	_update_visual_heading(delta)
	_update_vertical_velocity(delta)
	if is_diving:
		_step_support_active = false
		_advance_dive(delta)
	elif is_rolling:
		_step_support_active = false
		_advance_roll(delta)
	elif is_dashing:
		_step_support_active = false
		_advance_dash(delta)
	elif _is_front_kick_active():
		# The roundhouse owns the complete horizontal movement window. Gravity and
		# floor collision still run, but input cannot slide the player during it.
		_step_support_active = false
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		_clamp_to_arena()
	elif air_move_time_left > 0.0:
		_step_support_active = false
		air_move_time_left = maxf(0.0, air_move_time_left - delta)
		velocity.x = air_move_direction.x * air_move_speed
		velocity.z = air_move_direction.z * air_move_speed
		move_and_slide()
		_clamp_to_arena()
	else:
		var speed := move_speed * (cybernetic_speed_multiplier if is_cybernetic_active else 1.0)
		speed *= _get_turn_speed_ratio(input_direction)
		if charge_time_left > 0.0:
			speed *= 0.35
		velocity.x = input_direction.x * speed
		velocity.z = input_direction.z * speed
		_move_with_steps(delta)
		_clamp_to_arena()
	_apply_slash_hits()
	_update_cybernetic(delta)
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	_walk_phase += delta * 13.0 * horizontal_speed / maxf(move_speed, 0.001)
	_update_model(input_direction)
	if is_cybernetic_active and not is_action_locked() and get_position_delta().length_squared() > 0.0001:
		_cybernetic_trail_clock += delta
		if _cybernetic_trail_clock >= 0.07:
			_cybernetic_trail_clock = 0.0
			_add_trail(true)
	else:
		_cybernetic_trail_clock = 0.0


func _move_with_steps(delta: float) -> void:
	# Only grounded walking can climb a small riser. Jump, flight and card
	# movement keep their existing vertical motion and collision behaviour.
	var can_step := (is_on_floor() or _step_support_active) and velocity.y <= 0.0 and max_step_height > 0.0
	var can_snap := can_step
	_step_support_active = false
	var horizontal_motion := Vector3(velocity.x, 0.0, velocity.z) * delta
	if can_step and not horizontal_motion.is_zero_approx():
		_try_step_up(horizontal_motion)
	move_and_slide()
	if can_snap and not is_on_floor() and velocity.y <= 0.0:
		_snap_down_step()


func _try_step_up(horizontal_motion: Vector3) -> void:
	var obstacle := KinematicCollision3D.new()
	if not test_move(global_transform, horizontal_motion, obstacle):
		return
	if obstacle.get_normal().dot(Vector3.UP) >= cos(floor_max_angle):
		return
	# A capsule first meets the edge with its rounded foot, whose contact
	# normal is not the tread normal. Check the actual surface just ahead.
	var probe := global_position + horizontal_motion + horizontal_motion.normalized() * radius
	var query := PhysicsRayQueryParameters3D.create(probe + Vector3.UP * (max_step_height + 0.01), probe, collision_mask)
	query.exclude = [get_rid()]
	var landing := get_world_3d().direct_space_state.intersect_ray(query)
	if landing.is_empty() or (landing["normal"] as Vector3).dot(Vector3.UP) < cos(floor_max_angle):
		return
	var rise := (landing["position"] as Vector3).y - global_position.y
	if rise <= 0.005 or rise > max_step_height + 0.001:
		return
	# Sweep the entire capsule upward and across before committing movement;
	# a low ceiling or a taller wall makes the step impossible.
	var raised := global_transform
	var lift := Vector3.UP * (rise + safe_margin)
	if test_move(raised, lift):
		return
	raised.origin += lift
	if test_move(raised, horizontal_motion):
		return
	global_position.y += lift.y


func _snap_down_step() -> void:
	# At a descending edge the rounded capsule can report a steep contact
	# normal against the upper tread. Verify the lower tread itself with a
	# ray, then sweep down safely and keep following it across that edge.
	var query := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * 0.01, global_position + Vector3.DOWN * (max_step_height + 0.01), collision_mask)
	query.exclude = [get_rid()]
	var floor_hit := get_world_3d().direct_space_state.intersect_ray(query)
	if floor_hit.is_empty() or (floor_hit["normal"] as Vector3).dot(Vector3.UP) < cos(floor_max_angle):
		return
	var drop := global_position.y - (floor_hit["position"] as Vector3).y
	if drop < -safe_margin or drop > max_step_height + 0.01:
		return
	var landing := KinematicCollision3D.new()
	if not test_move(global_transform, Vector3.DOWN * (maxf(0.0, drop) + safe_margin), landing):
		return
	global_position += landing.get_travel()
	velocity.y = 0.0
	_step_support_active = true
	apply_floor_snap()


func request_jump() -> bool:
	if is_dead or get_tree().paused or is_action_locked() or not (is_on_floor() or _step_support_active) or velocity.y > 0.0:
		return false
	velocity.y = jump_speed
	_step_support_active = false
	_action_visual_token += 1
	_update_model(_get_input_direction())
	status_changed.emit("跳跃 · 可在空中移动与出牌", false)
	return true


func _update_vertical_velocity(delta: float) -> void:
	var acceleration := vertical_acceleration - gravity * gravity_scale
	# The previous move may still report floor contact on the takeoff frame.
	# Preserve a positive jump velocity and allow lift to leave the floor.
	if (is_on_floor() or _step_support_active) and velocity.y <= 0.0:
		velocity.y = 0.0
		if acceleration < 0.0:
			velocity.y = -0.1
			return
	velocity.y = maxf(velocity.y + acceleration * delta, -max_fall_speed)


func activate_cybernetic() -> bool:
	# The implant is independent of cards, energy, and their execution locks.
	if is_dead or get_tree().paused:
		return false
	if is_cybernetic_active or cybernetic_cooldown_left > 0.0:
		status_changed.emit("义体尚未就绪 · %.1f 秒后可用" % maxf(cybernetic_time_left, cybernetic_cooldown_left), true)
		return false
	cybernetic_time_left = cybernetic_duration
	cybernetic_cooldown_left = cybernetic_cooldown
	_cybernetic_trail_clock = 0.0
	_update_model(_get_input_direction())
	cybernetic_changed.emit(cybernetic_time_left, cybernetic_cooldown_left)
	status_changed.emit("义体启动 · 移速 ×%.1f，持续 %.1f 秒" % [cybernetic_speed_multiplier, cybernetic_duration], false)
	return true


func _update_cybernetic(delta: float) -> void:
	if not is_cybernetic_active and cybernetic_cooldown_left <= 0.0:
		return
	var was_active := is_cybernetic_active
	cybernetic_time_left = maxf(0.0, cybernetic_time_left - delta)
	cybernetic_cooldown_left = maxf(0.0, cybernetic_cooldown_left - delta)
	# Avoid an extra frame of cooldown caused by floating-point residue.
	if is_zero_approx(cybernetic_time_left):
		cybernetic_time_left = 0.0
	if is_zero_approx(cybernetic_cooldown_left):
		cybernetic_cooldown_left = 0.0
	cybernetic_changed.emit(cybernetic_time_left, cybernetic_cooldown_left)
	if not is_cybernetic_active and cybernetic_cooldown_left <= 0.0:
		status_changed.emit("义体就绪 · 按 Q 爆发加速", false)
	elif was_active and not is_cybernetic_active:
		status_changed.emit("爆发加速结束 · 义体冷却中", false)


func _get_input_direction() -> Vector3:
	var direction := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	return Vector3(direction.x, 0.0, direction.y).rotated(Vector3.UP, movement_yaw)


func _update_visual_heading(delta: float) -> void:
	if not is_instance_valid(_heading):
		return
	# Advance only once per physics tick. Action/pose refreshes must not snap yaw.
	var target_yaw := _direction_yaw(facing)
	_visual_yaw = rotate_toward(_visual_yaw, target_yaw, deg_to_rad(turn_speed_degrees) * delta)
	_heading.rotation.y = _visual_yaw


func _get_turn_speed_ratio(direction: Vector3) -> float:
	if direction.is_zero_approx():
		return 1.0
	# Use the visible body's heading, not the already-updated logical target.
	# A shortest-angle cosine curve smoothly brakes large turns and releases
	# the brake as the model faces the requested direction.
	var angle_error := wrapf(_direction_yaw(direction) - _visual_yaw, -PI, PI)
	var alignment := clampf((1.0 + cos(angle_error)) * 0.5, 0.0, 1.0)
	return lerpf(min_turn_speed_ratio, 1.0, alignment)


func get_card_cost(kind: String) -> float:
	if kind == "slash":
		return slash_cost
	if kind == "roll":
		return roll_cost
	if kind == "dash_slash":
		return dash_slash_cost
	return float(CARD_CATALOG.cost(kind))


func request_card(kind: String) -> bool:
	if not can_chain_card(kind):
		action_attempted.emit(kind, false, "blocked")
		return false
	var cost := get_card_cost(kind)
	if energy < cost:
		action_attempted.emit(kind, false, "no_energy")
		status_changed.emit("能量不足", true)
		return false
	if kind == "shield":
		# An instant defensive card can protect a combo without cancelling its
		# movement, hit window or animation. Repeated cards add to the same pool.
		if not add_shield(shield_per_card):
			return false
		energy -= cost
		energy_changed.emit(energy, max_energy)
		_spawn_ring(Color("74dfff"), 0.7, 0.24)
		action_played.emit(kind, cost)
		action_attempted.emit(kind, true, "accepted")
		status_changed.emit("护盾 +%.0f" % shield_per_card, false)
		return true
	# Resolve direction at the actual input event, including HUD card clicks.
	var input_direction := _get_input_direction()
	var direction := input_direction.normalized() if input_direction != Vector3.ZERO else facing
	if is_rolling:
		# One simultaneous attack per roll; the roll keeps its movement,
		# duration and evasion. There is no delayed damage queue.
		direction = roll_direction
		_roll_attack_used = true
	else:
		facing = direction
	energy -= cost
	_action_visual_token += 1
	energy_changed.emit(energy, max_energy)
	var chained := combo_window_left > 0.0 or slash_time_left > 0.0 or is_rolling
	# Movement cards may cancel a heavy windup or a previous swing's recovery.
	if CARD_CATALOG.category(kind) != "attack":
		charge_time_left = 0.0
		slash_time_left = 0.0
		if kind in ["roll", "blink"]:
			is_diving = false
			dive_startup_left = 0.0
			air_move_time_left = 0.0
	match kind:
		"punch":
			_start_melee(direction, kind, punch_damage, punch_reach, 0.09, deg_to_rad(42.0), melee_vertical_reach)
		"slash":
			# Legacy card id retained for deck/save compatibility; its action is now
			# the imported punch animation rather than a sword slash.
			_start_melee(direction, kind, slash_damage, slash_reach, slash_visual_duration if not chained else combo_slash_duration, deg_to_rad(48.0), melee_vertical_reach)
		"sweep":
			_start_melee(direction, kind, sweep_damage, sweep_reach, sweep_visual_duration, deg_to_rad(100.0), 0.65)
		"front_kick":
			# A full-circle area hit uses the same one-hit-per-target, height and
			# wall checks as the existing melee system.
			front_kick_damage_delay_left = maxf(front_kick_damage_delay, 0.0)
			front_kick_damage_fired = false
			_start_melee(direction, kind, front_kick_damage, front_kick_radius, front_kick_hit_duration, PI, melee_vertical_reach)
			front_kick_lock_time_left = maxf(front_kick_action_duration, front_kick_hit_duration)
			_spawn_ring(Color("ffd087"), front_kick_radius, front_kick_hit_duration)
		"shot":
			_fire_shot(direction)
		"charged_slash":
			charge_direction = direction
			charge_time_left = charged_slash_windup
			slash_time_left = 0.0
		"roll":
			roll_direction = direction
			is_rolling = true
			roll_time_left = roll_duration
			_roll_attack_used = false
			_trail_clock = 0.0
			_add_trail()
		"blink":
			_add_trail()
			# Swept CharacterBody capsule stops at the first solid obstacle.
			# Only horizontal movement is changed, preserving airborne velocity.
			move_and_collide(direction * blink_distance)
			_clamp_to_arena()
			_add_trail()
		"jet_jump":
			jet_jump_used = true
			velocity.y = maxf(velocity.y, jet_jump_speed)
			_begin_air_move(direction, 9.4, 0.16)
			_spawn_ring(Color("62ddff"), 0.7, 0.20)
		"dash_slash":
			dash_direction = direction
			is_dashing = true
			dash_time_left = dash_duration
			_dash_targets_hit.clear()
			slash_direction = direction
			_active_melee_damage = dash_slash_damage
			_active_melee_reach = dash_slash_reach
			_active_melee_half_angle = PI
			_active_melee_vertical_reach = melee_vertical_reach
			_dash_slash_started = false
			_trail_clock = 0.0
			_add_trail()
		"airborne_slash":
			airborne_slash_used = true
			velocity.y = maxf(velocity.y, 8.2)
			_begin_air_move(direction, 7.0, 0.18)
			_start_melee(direction, kind, airborne_slash_damage, 2.1, 0.18, slash_half_angle, 1.65)
		"dive_slash":
			is_diving = true
			dive_direction = direction
			air_move_time_left = 0.0
			# Ground use includes a very short hop; air use dives immediately.
			dive_startup_left = 0.16 if is_on_floor() else 0.0
			velocity.y = 6.0 if dive_startup_left > 0.0 else -22.0
	combo_window_left = combo_window_duration
	action_played.emit(kind, cost)
	action_attempted.emit(kind, true, "accepted")
	status_changed.emit(CARD_CATALOG.card_name(kind), false)
	_update_model(Vector3.ZERO)
	return true


func is_action_locked() -> bool:
	return is_rolling or is_dashing or is_diving or _is_front_kick_active()


func _is_front_kick_active() -> bool:
	return front_kick_lock_time_left > 0.0


func can_chain_card(kind: String) -> bool:
	if is_dead or get_tree().paused or not CARD_CATALOG.has_kind(kind):
		return false
	if _is_front_kick_active():
		return false
	if kind == "shield":
		return true
	if kind == "jet_jump" and jet_jump_used:
		return false
	if kind == "airborne_slash" and airborne_slash_used:
		return false
	if is_rolling:
		return kind in ROLL_ATTACKS and not _roll_attack_used
	if is_dashing:
		return false
	if is_diving:
		return kind in ROLL_ATTACKS or kind in ["roll", "blink"]
	if charge_time_left > 0.0:
		return CARD_CATALOG.category(kind) == "movement"
	return true


func _start_slash_visual(direction: Vector3, from_dash: bool, combo: bool = false) -> void:
	_slash_is_combo = combo and not from_dash
	var duration := 0.24 if from_dash else (combo_slash_duration if _slash_is_combo else slash_visual_duration)
	_start_melee(direction, "dash_slash" if from_dash else "slash", dash_slash_damage if from_dash else slash_damage, dash_slash_reach if from_dash else slash_reach, duration, slash_half_angle, melee_vertical_reach)
	if from_dash:
		# Preserve path hits when the follow-up punch window begins so a target
		# crossed during the dash cannot be damaged a second time at the endpoint.
		for target_id in _dash_targets_hit:
			if target_id not in _slash_targets_hit:
				_slash_targets_hit.append(target_id)


func _start_melee(direction: Vector3, kind: String, damage: float, reach: float, duration: float, half_angle: float, vertical_reach: float) -> void:
	var preserved_dash_hits: Array[int] = []
	if kind == "dash_slash":
		for target_id in _dash_targets_hit:
			preserved_dash_hits.append(int(target_id))
	slash_direction = direction
	_active_attack_kind = kind
	_slash_is_dash = kind == "dash_slash"
	_active_slash_duration = duration
	_active_melee_damage = damage
	_active_melee_reach = reach
	_active_melee_half_angle = half_angle
	_active_melee_vertical_reach = vertical_reach
	slash_time_left = duration
	_slash_targets_hit.clear()
	if not preserved_dash_hits.is_empty():
		_slash_targets_hit.append_array(preserved_dash_hits)
	var color := Color("ffae48")
	if kind == "punch" or kind == "slash":
		color = Color("fff6b0")
	elif kind == "sweep":
		color = Color("8ff0ff")
	elif kind == "front_kick":
		color = Color("ffd087")
	elif kind == "airborne_slash":
		color = Color("6ceaff")
	elif kind == "dash_slash":
		color = Color("c269ff")
	elif kind == "charged_slash":
		color = Color("ff704c")
	_slash_material.albedo_color = Color(color, 0.72)
	_slash_edge_material.albedo_color = color.lightened(0.25)
	_apply_slash_hits()


func _apply_slash_hits() -> void:
	if is_dead or get_tree().paused:
		return
	if _active_attack_kind == "front_kick":
		if front_kick_damage_fired or front_kick_damage_delay_left > 0.0:
			return
	else:
		if slash_time_left <= 0.0:
			return
	for target in get_tree().get_nodes_in_group("combat_targets"):
		if not target is Node3D or not target.has_method("take_damage"):
			continue
		var target_id := target.get_instance_id()
		if target_id in _slash_targets_hit:
			continue
		if COMBAT.can_hit(self, target, slash_direction, _active_melee_reach, _active_melee_half_angle, _active_melee_vertical_reach):
			if bool(target.call("take_damage", get_attack_damage(_active_melee_damage))):
				_slash_targets_hit.append(target_id)
				if _active_attack_kind == "dash_slash" and target_id not in _dash_targets_hit:
					_dash_targets_hit.append(target_id)
	if _active_attack_kind == "front_kick":
		front_kick_damage_fired = true


func _apply_dash_path_hits(previous_position: Vector3) -> void:
	if is_dead or get_tree().paused:
		return
	var segment := global_position - previous_position
	var segment_xz := Vector3(segment.x, 0.0, segment.z)
	var segment_length_squared := segment_xz.length_squared()
	for target in get_tree().get_nodes_in_group("combat_targets"):
		if not target is Node3D or not target.has_method("take_damage"):
			continue
		var target_id := target.get_instance_id()
		if target_id in _dash_targets_hit:
			continue
		var target_position: Vector3 = target.global_position
		if absf(target_position.y - global_position.y) > melee_vertical_reach:
			continue
		var nearest := previous_position
		if segment_length_squared > 0.000001:
			var along := clampf(Vector3(target_position.x - previous_position.x, 0.0, target_position.z - previous_position.z).dot(segment_xz) / segment_length_squared, 0.0, 1.0)
			nearest = previous_position + segment * along
		var target_radius: float = float(target.get("radius")) if target.get("radius") != null else 0.35
		var path_radius := radius + target_radius + 0.2
		if Vector2(target_position.x - nearest.x, target_position.z - nearest.z).length() > path_radius:
			continue
		var ray := PhysicsRayQueryParameters3D.create(nearest + Vector3.UP * 0.85, target_position + Vector3.UP * 0.85, 1)
		var exclusions: Array[RID] = [get_rid()]
		if target is CollisionObject3D:
			exclusions.append(target.get_rid())
		ray.exclude = exclusions
		if not get_world_3d().direct_space_state.intersect_ray(ray).is_empty():
			continue
		if bool(target.call("take_damage", get_attack_damage(dash_slash_damage))):
			_dash_targets_hit.append(target_id)


func _update_charge(delta: float) -> void:
	if charge_time_left <= 0.0:
		return
	charge_time_left = maxf(0.0, charge_time_left - delta)
	if is_zero_approx(charge_time_left):
		charge_time_left = 0.0
	if charge_time_left <= 0.0:
		_start_melee(charge_direction, "charged_slash", charged_slash_damage, 2.4, 0.12, slash_half_angle, melee_vertical_reach)
		combo_window_left = combo_window_duration


func _fire_shot(direction: Vector3) -> void:
	var origin := global_position + Vector3.UP * 0.9
	var end := origin + direction * shot_range
	# The nearest collision wins: world geometry blocks opponents behind it.
	var query := PhysicsRayQueryParameters3D.create(origin, end, 1 | 4)
	query.exclude = [get_rid()]
	query.hit_from_inside = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		end = hit["position"]
		var target: Object = hit["collider"]
		if is_instance_valid(target) and target.has_method("take_damage"):
			target.call("take_damage", get_attack_damage(shot_damage))
	var length := origin.distance_to(end)
	if length <= 0.001:
		return
	var beam := MeshInstance3D.new()
	beam.name = "ShotTracer"
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.025
	mesh.bottom_radius = 0.025
	mesh.height = length
	mesh.radial_segments = 8
	beam.mesh = mesh
	var material := _make_material(Color("ffe79b"), true)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	beam.material_override = material
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(beam)
	beam.top_level = true
	beam.global_position = (origin + end) * 0.5
	beam.quaternion = Quaternion(Vector3.UP, (end - origin).normalized())
	_action_effects.append({"node": beam, "material": material, "life": 0.09, "duration": 0.09})


func _begin_air_move(direction: Vector3, speed: float, duration: float) -> void:
	air_move_direction = direction
	air_move_speed = speed
	air_move_time_left = duration


func _advance_dive(delta: float) -> void:
	dive_startup_left = maxf(0.0, dive_startup_left - delta)
	if dive_startup_left <= 0.0:
		velocity.y = -22.0
	velocity.x = dive_direction.x * 9.0
	velocity.z = dive_direction.z * 9.0
	move_and_slide()
	_clamp_to_arena()
	if is_on_floor() and dive_startup_left <= 0.0:
		# Resolve exactly one impact; the effect persists without a hitbox.
		is_diving = false
		velocity.x = 0.0
		velocity.z = 0.0
		for target in get_tree().get_nodes_in_group("combat_targets"):
			if target is Node3D and target.has_method("take_damage"):
				if COMBAT.can_hit(self, target, dive_direction, dive_radius, PI, 1.3):
					target.call("take_damage", get_attack_damage(dive_slash_damage))
		_spawn_ring(Color("ce8bff"), dive_radius, 0.20)
		combo_window_left = combo_window_duration
		jet_jump_used = false
		airborne_slash_used = false


func _spawn_ring(color: Color, effect_radius: float, duration: float) -> void:
	var ring := MeshInstance3D.new()
	ring.name = "ActionRing"
	var mesh := TorusMesh.new()
	mesh.inner_radius = maxf(0.1, effect_radius - 0.09)
	mesh.outer_radius = effect_radius
	mesh.rings = 40
	mesh.ring_segments = 6
	ring.mesh = mesh
	var material := _make_material(color, true)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring.material_override = material
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ring)
	ring.top_level = true
	ring.global_position = global_position + Vector3.UP * 0.07
	_action_effects.append({"node": ring, "material": material, "life": duration, "duration": duration})


func _clear_extra_actions() -> void:
	charge_time_left = 0.0
	front_kick_lock_time_left = 0.0
	front_kick_damage_delay_left = 0.0
	front_kick_damage_fired = false
	is_diving = false
	dive_startup_left = 0.0
	jet_jump_used = false
	airborne_slash_used = false
	air_move_time_left = 0.0
	air_move_speed = 0.0
	_roll_attack_used = false
	_dash_targets_hit.clear()
	_active_attack_kind = "slash"
	for effect in _action_effects:
		if is_instance_valid(effect["node"]):
			effect["node"].queue_free()
	_action_effects.clear()


func add_shield(amount: float) -> bool:
	if is_dead or get_tree().paused or amount <= 0.0:
		return false
	if shield <= 0.0:
		_shield_decay_elapsed = 0.0
	shield += amount
	shield_changed.emit(shield)
	return true


func _update_shield_decay(delta: float) -> void:
	if shield <= 0.0:
		_shield_decay_elapsed = 0.0
		return
	# Keep fractional time between frames and additions. A long frame must
	# consume every elapsed 0.2-second decay tick instead of slowing down the decay.
	_shield_decay_elapsed += maxf(0.0, delta)
	var interval := maxf(0.05, shield_decay_interval)
	var ticks := floori((_shield_decay_elapsed + 0.000001) / interval)
	if ticks <= 0:
		return
	_shield_decay_elapsed = maxf(0.0, _shield_decay_elapsed - ticks * interval)
	shield = maxf(0.0, shield - float(ticks))
	if shield <= 0.0:
		_shield_decay_elapsed = 0.0
	shield_changed.emit(shield)


func take_damage(amount: float, ignore_damage_reduction: bool = false) -> bool:
	# A roll has a short, explicit evasion window; walking and dash-slash do not.
	if is_dead or get_tree().paused or is_rolling or amount <= 0.0:
		return false
	if not ignore_damage_reduction:
		amount *= implant_damage_reduction_multiplier
	var absorbed := minf(amount, shield)
	if absorbed > 0.0:
		shield = maxf(0.0, shield - absorbed)
		if shield <= 0.0:
			_shield_decay_elapsed = 0.0
		shield_changed.emit(shield)
	var applied := minf(amount - absorbed, health)
	health = maxf(0.0, health - applied)
	# A fully absorbed hit should not flash the red health feedback; the shield
	# bar and status message already communicate that impact.
	_damage_flash_left = 0.2 if applied > 0.0 else 0.0
	if health <= 0.0:
		is_dead = true
		_clear_extra_actions()
		combo_window_left = 0.0
		_buffered_card = ""
		is_rolling = false
		is_dashing = false
		roll_time_left = 0.0
		dash_time_left = 0.0
		slash_time_left = 0.0
		cybernetic_time_left = 0.0
		velocity.x = 0.0
		velocity.z = 0.0
		cybernetic_changed.emit(cybernetic_time_left, cybernetic_cooldown_left)
	if applied > 0.0:
		health_changed.emit(health, max_health)
		damaged.emit(applied)
	if is_dead:
		status_changed.emit("训练失败 · 按 R 重试", true)
		defeated.emit()
	elif applied > 0.0:
		status_changed.emit("受到劈砍 −%.0f 生命 · 落刀前翻滚" % applied, true)
	else:
		status_changed.emit("护盾吸收 %.0f 伤害" % absorbed, false)
	_update_model(Vector3.ZERO)
	return true


func become_lost() -> void:
	# Environmental loss is independent of a card's combat evasion window.
	if is_dead or get_tree().paused:
		return
	is_rolling = false
	# Environmental loss bypasses accessories as well as temporary shields.
	take_damage(health + shield, true)
	velocity = Vector3.ZERO
	set_physics_process(false)
	status_changed.emit("沉入深水 · 意识迷失", true)


func _advance_roll(delta: float) -> void:
	# Keep the authored roll timeline unchanged while covering two-thirds of the
	# previous 6.16 m travel distance, about 4.11 m in an unobstructed direction.
	var step := minf(delta, roll_time_left)
	var frame_speed := roll_speed * (step / delta if delta > 0.0 else 0.0)
	velocity.x = roll_direction.x * frame_speed
	velocity.z = roll_direction.z * frame_speed
	move_and_slide()
	_clamp_to_arena()
	roll_time_left = maxf(0.0, roll_time_left - step)
	_trail_clock += step
	if _trail_clock >= 0.04:
		_trail_clock = 0.0
		_update_model(Vector3.ZERO)
		_add_trail()
	if roll_time_left <= 0.0:
		# Publish the exact terminal progress while the roll state is still
		# active. The visual controller uses this normalized value to seek the
		# authored final roll key on the same physics frame as the last metre of
		# movement; clearing is_rolling first would make it miss progress == 1.
		roll_time_left = 0.0
		_update_model(Vector3.ZERO)
		is_rolling = false
		velocity.x = 0.0
		velocity.z = 0.0
		combo_window_left = combo_window_duration
		_roll_attack_used = false


func _advance_dash(delta: float) -> void:
	# Damage starts with the follow-up slash; the card spends and emits once.
	var step := minf(delta, dash_time_left)
	var previous_position := global_position
	var frame_speed := dash_speed * (step / delta if delta > 0.0 else 0.0)
	velocity.x = dash_direction.x * frame_speed
	velocity.z = dash_direction.z * frame_speed
	move_and_slide()
	_clamp_to_arena()
	_apply_dash_path_hits(previous_position)
	dash_time_left = maxf(0.0, dash_time_left - step)
	if not _dash_slash_started and dash_time_left <= dash_duration * 0.5:
		_dash_slash_started = true
		_start_slash_visual(dash_direction, true)
		status_changed.emit("突进出拳 · 路径命中", false)
	_trail_clock += step
	if _trail_clock >= 0.035:
		_trail_clock = 0.0
		_update_model(Vector3.ZERO)
		_add_trail()
	if dash_time_left <= 0.0:
		is_dashing = false
		velocity.x = 0.0
		velocity.z = 0.0
		status_changed.emit("突进出拳完成 · 能量持续恢复", false)


func _clamp_to_arena() -> void:
	if not bounds_enabled:
		return
	global_position.x = clampf(global_position.x, arena_rect.position.x + radius, arena_rect.end.x - radius)
	global_position.z = clampf(global_position.z, arena_rect.position.y + radius, arena_rect.end.y - radius)


func _update_visual_timers(delta: float) -> void:
	slash_time_left = maxf(0.0, slash_time_left - delta)
	front_kick_lock_time_left = maxf(0.0, front_kick_lock_time_left - delta)
	if front_kick_damage_delay_left > 0.0:
		front_kick_damage_delay_left = maxf(0.0, front_kick_damage_delay_left - delta)
		if front_kick_damage_delay_left <= 0.0:
			_apply_slash_hits()
	for index in range(_action_effects.size() - 1, -1, -1):
		_action_effects[index]["life"] = float(_action_effects[index]["life"]) - delta
		var effect: Dictionary = _action_effects[index]
		if float(effect["life"]) <= 0.0:
			effect["node"].queue_free()
			_action_effects.remove_at(index)
		else:
			var material: StandardMaterial3D = effect["material"]
			material.albedo_color.a = float(effect["life"]) / float(effect["duration"])
	for index in range(_trail.size() - 1, -1, -1):
		_trail[index]["life"] = float(_trail[index]["life"]) - delta
		var life: float = _trail[index]["life"]
		if life <= 0.0:
			_trail[index]["node"].queue_free()
			_trail.remove_at(index)
		else:
			var material: StandardMaterial3D = _trail[index]["material"]
			material.albedo_color.a = 0.3 * life / 0.2


func _add_trail(from_cybernetic: bool = false) -> void:
	var echo := Node3D.new()
	echo.name = "CyberneticEcho" if from_cybernetic else ("DashEcho" if is_dashing else "RollEcho")
	add_child(echo)
	echo.top_level = true
	echo.global_transform = _body_pivot.global_transform
	var color := Color(0.73, 0.35, 1.0, 0.3) if is_dashing else Color(0.26, 0.78, 1.0, 0.3)
	if from_cybernetic:
		color = Color(1.0, 0.82, 0.35, 0.3)
	var material := _make_material(color, true)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_add_capsule(echo, Vector3(0.0, 0.08, 0.0), 0.27, 0.69, material)
	_add_box(echo, Vector3(0.0, 0.61, 0.0), Vector3(0.39, 0.39, 0.36), material)
	_add_box(echo, Vector3(-0.15, -0.48, 0.0), Vector3(0.19, 0.5, 0.21), material)
	_add_box(echo, Vector3(0.15, -0.48, 0.0), Vector3(0.19, 0.5, 0.21), material)
	for child in echo.get_children():
		(child as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_trail.append({"node": echo, "material": material, "life": 0.2})


func _current_visual_action_duration() -> float:
	# The combat timers remain short so hit windows and movement stay responsive.
	# The character visual controller uses this as the base window for its
	# independent, slowed animation tail.
	var duration := 0.14
	if slash_time_left > 0.0:
		duration = maxf(_active_slash_duration, 0.01)
	if is_rolling:
		duration = maxf(duration, roll_duration)
	if is_dashing:
		duration = maxf(duration, dash_duration)
	if charge_time_left > 0.0:
		duration = maxf(duration, charged_slash_windup)
	return duration


func _update_model(input_direction: Vector3) -> void:
	if not is_instance_valid(_heading):
		return
	_body_material.albedo_color = Color("ffe18a") if is_cybernetic_active else Color("50d6c0")
	if _damage_flash_left > 0.0:
		_body_material.albedo_color = Color("ff6474")
	_implant_material.albedo_color = Color("ffe18a") if is_cybernetic_active else Color("74c8bb")
	_cybernetic_ring.visible = is_cybernetic_active
	_cybernetic_ring.scale = Vector3.ONE * (1.0 + sin(_life_time * 12.0) * 0.07)
	var airborne := not (is_on_floor() or _step_support_active) or velocity.y > 0.0
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var walking := input_direction.length() > 0.01 and horizontal_speed > 0.05 and not is_action_locked() and not airborne
	var stride_strength := clampf(horizontal_speed / maxf(move_speed, 0.001), 0.0, 1.0)
	var stride := sin(_walk_phase) * 0.5 * stride_strength if walking else 0.0
	var roll_progress := 1.0 - roll_time_left / maxf(roll_duration, 0.001) if is_rolling else -1.0
	var dash_progress := 1.0 - dash_time_left / maxf(dash_duration, 0.001) if is_dashing else -1.0
	var slash_progress := 1.0 - slash_time_left / maxf(_active_slash_duration, 0.001) if slash_time_left > 0.0 else -1.0
	var charge_amount := 1.0 - charge_time_left / maxf(charged_slash_windup, 0.001) if charge_time_left > 0.0 else 0.0
	var visual_state := "idle"
	if is_dead:
		visual_state = "dead"
	elif is_diving:
		visual_state = "dive"
	elif charge_time_left > 0.0:
		visual_state = "charged_slash"
	elif slash_time_left > 0.0:
		visual_state = _active_attack_kind
	elif is_dashing:
		visual_state = "dash_slash"
	elif is_rolling:
		visual_state = "roll"
	elif airborne:
		visual_state = "jump"
	elif walking:
		visual_state = "walk"
	if is_instance_valid(_character_visual) and _character_visual.has_method("apply_state"):
		_character_visual.apply_state({
			"time": _life_time,
			"state": visual_state,
			"walk_phase": _walk_phase,
			"move_amount": stride_strength if walking else 0.0,
			"airborne": airborne,
			"vertical_speed": velocity.y,
			"roll_progress": roll_progress,
			"dash_progress": dash_progress,
			"slash_progress": slash_progress,
			"attack_kind": _active_attack_kind,
			"charge_amount": charge_amount,
			"diving": is_diving,
			"dead": is_dead,
			"boost": is_cybernetic_active,
			"damage_flash": _damage_flash_left,
			"action_visual_token": _action_visual_token,
			"action_duration": _current_visual_action_duration(),
		})
	_left_leg.rotation.x = stride
	_right_leg.rotation.x = -stride
	_left_arm.rotation = Vector3(-stride * 0.65, 0.0, 0.0)
	_right_arm.rotation = Vector3(stride * 0.45, 0.0, 0.0)
	_body_pivot.rotation = Vector3.ZERO
	_body_pivot.position.y = 0.8 + (absf(sin(_walk_phase)) * 0.025 * stride_strength if walking else 0.0)
	_sword.visible = (not is_rolling or slash_time_left > 0.0) and not (slash_time_left > 0.0 and _active_attack_kind == "punch")
	if is_dead:
		_body_material.albedo_color = Color("58616b")
		_body_pivot.rotation.z = PI / 2.0
		_body_pivot.position.y = 0.35
		_slash_root.visible = false
		_cybernetic_ring.visible = false
		return
	if is_diving:
		_body_pivot.rotation.x = -0.65
		_left_leg.rotation.x = -0.5
		_right_leg.rotation.x = 0.5
		_right_arm.rotation.x = -2.3
	elif is_rolling:
		_body_pivot.rotation.x = -roll_progress * TAU
		_body_pivot.position.y = 0.8 + sin(roll_progress * PI) * 0.16
		_left_leg.rotation.x = -0.7
		_right_leg.rotation.x = -0.7
		_left_arm.rotation.x = -1.1
		_right_arm.rotation.x = -1.1
	elif is_dashing:
		_body_pivot.rotation.x = -0.48
		_body_pivot.position.y = 0.76
		_left_leg.rotation.x = -0.5
		_right_leg.rotation.x = 0.65
		_left_arm.rotation.x = 0.65
		_right_arm.rotation.x = -1.3
	elif airborne:
		_body_pivot.rotation.x = -0.1
		_left_leg.rotation.x = -0.65 if velocity.y > 0.0 else -0.25
		_right_leg.rotation.x = -0.4 if velocity.y > 0.0 else 0.15
		_left_arm.rotation = Vector3(-0.45, 0.0, -0.3)
		_right_arm.rotation = Vector3(-0.45, 0.0, 0.3)
	elif is_cybernetic_active and walking:
		_body_pivot.rotation.x = -0.18
	if charge_time_left > 0.0:
		_right_arm.rotation = Vector3(-2.6, 0.0, -0.2)
		_left_arm.rotation.x = -1.8
		_body_pivot.rotation.x = -0.12
	var uses_punch_motion := _active_attack_kind in ["punch", "slash", "dash_slash"]
	var uses_sweep_motion := _active_attack_kind == "sweep"
	_slash_root.visible = slash_time_left > 0.0 and not uses_punch_motion and not uses_sweep_motion
	if slash_time_left > 0.0:
		var progress := 1.0 - slash_time_left / _active_slash_duration
		_slash_root.rotation.y = _direction_yaw(slash_direction) + lerpf(-0.15, 0.2, progress)
		var slash_scale := _active_melee_reach / maxf(slash_reach, 0.01)
		_slash_root.scale = Vector3.ONE * lerpf(0.86, 1.14, progress) * slash_scale
		_slash_material.albedo_color.a = (1.0 - progress * 0.8) * 0.72
		_slash_edge_material.albedo_color.a = 1.0 - progress * 0.8
		_right_arm.rotation = Vector3(-0.3, lerpf(-1.1, 1.1, progress), -0.3)
		if _active_attack_kind == "punch":
			_right_arm.rotation = Vector3(-1.5, 0.0, -0.08)


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
	floor_snap_length = maxf(0.2, max_step_height + 0.02)

	_body_material = _make_material(Color("50d6c0"))
	_implant_material = _make_material(Color("74c8bb"), true)
	var dark := _make_material(Color("173b48"))
	var joint := _make_material(Color("253b50"))
	var light := _make_material(Color("b9fff0"), true)
	var steel := _make_material(Color("e7f1ef"))
	var orange := _make_material(Color("ffb265"), true)
	_heading = Node3D.new()
	_heading.name = "Facing"
	add_child(_heading)
	_body_pivot = Node3D.new()
	_body_pivot.name = "Model"
	_body_pivot.position.y = 0.8
	_heading.add_child(_body_pivot)
	_character_visual = CHARACTER_VISUAL.new()
	_character_visual.name = "TacticalFemaleVisual"
	# The authored roundhouse clip reads more clearly than the generated low
	# sweep on the current rig. Keep the gameplay card as `sweep`; this only
	# changes the visual clip and leaves its damage/reach/timing untouched.
	_character_visual.sweep_uses_front_kick_animation = true
	_heading.add_child(_character_visual)

	_add_capsule(_body_pivot, Vector3(0.0, 0.09, 0.0), 0.27, 0.69, _body_material)
	_add_box(_body_pivot, Vector3(0.0, 0.08, -0.25), Vector3(0.32, 0.23, 0.055), dark)
	_add_box(_body_pivot, Vector3(0.0, 0.12, -0.283), Vector3(0.045, 0.12, 0.025), light)
	_add_box(_body_pivot, Vector3(0.0, 0.61, 0.0), Vector3(0.4, 0.4, 0.37), dark)
	_add_box(_body_pivot, Vector3(0.0, 0.64, -0.192), Vector3(0.3, 0.09, 0.027), light)
	_add_box(_body_pivot, Vector3(0.0, -0.29, 0.0), Vector3(0.42, 0.14, 0.28), dark)

	_left_leg = _make_joint("LeftLeg", Vector3(-0.15, -0.27, 0.0))
	_right_leg = _make_joint("RightLeg", Vector3(0.15, -0.27, 0.0))
	for leg in [_left_leg, _right_leg]:
		_add_box(leg, Vector3(0.0, -0.21, 0.0), Vector3(0.18, 0.41, 0.22), joint)
		_add_box(leg, Vector3(0.0, -0.45, -0.055), Vector3(0.22, 0.16, 0.34), dark)
		_add_box(leg, Vector3(0.0, -0.21, -0.12), Vector3(0.07, 0.3, 0.035), _implant_material)
	_left_arm = _make_joint("LeftArm", Vector3(-0.36, 0.34, 0.0))
	_right_arm = _make_joint("RightArm", Vector3(0.36, 0.34, 0.0))
	for arm in [_left_arm, _right_arm]:
		_add_capsule(arm, Vector3(0.0, -0.2, 0.0), 0.095, 0.48, _body_material)
		_add_box(arm, Vector3(0.0, -0.41, -0.015), Vector3(0.15, 0.16, 0.18), dark)
	_sword = Node3D.new()
	_sword.name = "SimpleSword"
	_sword.position = Vector3(0.0, -0.4, -0.06)
	_right_arm.add_child(_sword)
	_add_box(_sword, Vector3(0.0, 0.0, -0.12), Vector3(0.065, 0.075, 0.28), joint)
	_add_box(_sword, Vector3(0.0, 0.0, -0.28), Vector3(0.28, 0.07, 0.07), orange)
	_add_box(_sword, Vector3(0.0, 0.0, -0.76), Vector3(0.095, 0.055, 0.91), steel)
	_add_box(_sword, Vector3(0.047, 0.0, -0.76), Vector3(0.016, 0.059, 0.91), orange)

	_cybernetic_ring = MeshInstance3D.new()
	_cybernetic_ring.name = "CyberneticRing"
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = 0.55
	ring_mesh.outer_radius = 0.61
	ring_mesh.rings = 32
	ring_mesh.ring_segments = 8
	_cybernetic_ring.mesh = ring_mesh
	_cybernetic_ring.material_override = _implant_material
	_cybernetic_ring.position.y = 0.055
	_cybernetic_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_cybernetic_ring.visible = false
	add_child(_cybernetic_ring)

	_slash_root = Node3D.new()
	_slash_root.name = "SlashArc"
	_slash_root.position.y = 0.9
	add_child(_slash_root)
	_slash_material = _make_material(Color(1.0, 0.4, 0.08, 0.72), true)
	_slash_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_slash_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_slash_edge_material = _make_material(Color(1.0, 0.8, 0.35), true)
	_slash_edge_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_slash_edge_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_add_arc(1.25, slash_reach, _slash_material)
	_add_arc(slash_reach - 0.045, slash_reach, _slash_edge_material)
	_slash_root.visible = false
	# Keep the old greybox joints alive for compatibility with existing visual
	# helpers and tests, but let the imported rig be the only visible body.
	_body_pivot.visible = false


func _make_joint(joint_name: String, local_position: Vector3) -> Node3D:
	var joint := Node3D.new()
	joint.name = joint_name
	joint.position = local_position
	_body_pivot.add_child(joint)
	return joint


func _make_material(color: Color, glowing: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.75
	if glowing:
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
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


func _add_capsule(parent: Node3D, center: Vector3, capsule_radius: float, height: float, material: Material) -> MeshInstance3D:
	var mesh := CapsuleMesh.new()
	mesh.radius = capsule_radius
	mesh.height = height
	mesh.radial_segments = 12
	mesh.rings = 4
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = center
	parent.add_child(instance)
	return instance


func _add_arc(inner_radius: float, outer_radius: float, material: Material) -> void:
	var vertices := PackedVector3Array()
	var segments := 28
	for index in range(segments):
		var a := lerpf(-slash_half_angle, slash_half_angle, float(index) / float(segments))
		var b := lerpf(-slash_half_angle, slash_half_angle, float(index + 1) / float(segments))
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
	_slash_root.add_child(instance)
