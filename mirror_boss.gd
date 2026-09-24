extends "res://player.gd"
## The mirror uses the player's rig, authored clips, card effects and collision
## body. Only its input, action scheduling and opponent targeting are different.
## A complete combo is paid for up front, so a defensive card cannot consume
## the energy reserved for its final retreat.

signal dodge_observed()
signal attack_observed(kind: String, hit: bool, damage: float)
signal combo_started(combo_name: StringName)
signal combo_finished(combo_name: StringName)

const ROLL_PUNCHES: StringName = &"roll_punches"
const DASH_KICK: StringName = &"dash_kick"
const ENTRANCE_SHADER = preload("res://materials/boss_entrance.gdshader")
## Authored duel numbers, identical to the values the lab fighter always had.
## `_apply_floor_scaling()` multiplies these by the current floor's multipliers
## instead of editing them, so floor one's duel is numerically unchanged.
const AUTHORED_MAX_HEALTH: float = 500.0
const AUTHORED_SLASH_DAMAGE: float = 12.0
const AUTHORED_DASH_SLASH_DAMAGE: float = 18.0
const AUTHORED_FRONT_KICK_DAMAGE: float = 15.0

@export_group("Mirror Boss")
@export var display_name: String = "镜像 Boss"
## Full protected entrance, including its shield fade. Zero skips the intro.
@export_range(0.0, 10.0, 0.1) var entrance_duration: float = 3.0
@export_range(0.05, 1.0, 0.01) var windup_duration: float = 0.27
@export_range(0.05, 0.5, 0.01) var roll_windup_duration: float = 0.14
@export_range(0.20, 0.8, 0.01) var punch_interval: float = 0.36
@export_range(0.0, 3.0, 0.05) var combo_recovery: float = 0.70
@export_range(360.0, 1080.0, 15.0) var boss_turn_speed_degrees: float = 720.0
## Zero follows the actual player's roll speed times duration.
@export var preferred_distance: float = 0.0
@export var distance_tolerance: float = 0.45
@export var minimum_body_distance: float = 0.88
@export var combo_start_distance: float = 4.6
@export_range(0.0, 1.0, 0.05) var strafe_amount: float = 0.25
@export var shield_trigger_distance: float = 1.7
@export var shield_trigger_below: float = 1.0
@export var shield_cooldown: float = 4.0
@export var ground_probe_drop: float = 1.7
## Optional circular boundary, in addition to the inherited rectangular bounds.
@export var arena_center: Vector3 = Vector3.ZERO
@export var arena_radius: float = 0.0
## Per-floor tuning. The duel is otherwise identical on every floor: same
## combos, telegraphs, energy economy and card effects. Later floors make the
## mirror's health pool thicker and its landed hits hurt more; both are applied
## once in `_init()` from these fields, and `set_floor_scaling()` lets the arena
## override them before the boss enters the tree. A zero or negative value is
## treated as "leave the authored number alone".
@export var health_multiplier: float = 1.0
@export var damage_multiplier: float = 1.0

## Health pool authored by `_init()`, before any floor multiplier. Retained so
## the duel can be re-scaled repeatedly without compounding.
var base_max_health: float = 500.0

var combat_enabled: bool = true:
	set(value):
		combat_enabled = value
		if not value:
			_cancel_combo(true)
			state = &"dead" if is_dead else (&"entrance" if is_entering else &"idle")
var entrance_time_left: float = 0.0
var is_entering: bool:
	get:
		return entrance_time_left > 0.0
var state: StringName = &"recover"
var state_time_left: float = 0.0
var combo_active: bool = false
var planned_combo: StringName = ROLL_PUNCHES
var active_combo: StringName = &""
var shield_cooldown_left: float = 0.0
var adaptive_reaction: StringName = &"observe"
var adaptive_reaction_payload: Dictionary = {}

var _actor: CharacterBody3D
var _ai_direction: Vector3 = Vector3.ZERO
var _combo_steps: Array[String] = []
var _combo_step: int = 0
var _reserved_energy: float = 0.0
var _windup_kind: String = ""
var _windup_direction: Vector3 = Vector3.FORWARD
var _step_wait_left: float = 0.0
var _recovery_left: float = 0.0
var _strafe_sign: float = 1.0
var _strafe_time_left: float = 2.6
var _distance_mode: int = 0
var _executing_prepaid_card: bool = false
var _identity_ring: MeshInstance3D
var _warning_ring: MeshInstance3D
var _warning_material: StandardMaterial3D
var _shield_shell: MeshInstance3D
var _entrance_shell: MeshInstance3D
var _entrance_material: ShaderMaterial
var _entrance_ring: MeshInstance3D
var _entrance_ring_material: StandardMaterial3D


func _init() -> void:
	base_max_health = AUTHORED_MAX_HEALTH
	max_health = base_max_health
	move_speed = 3.2
	max_energy = 10.0
	energy_regen_per_second = 2.0
	# The same moves have lower training damage to leave room to observe a full
	# sequence and answer it. All damage remains editable in the inspector.
	slash_damage = AUTHORED_SLASH_DAMAGE
	dash_slash_damage = AUTHORED_DASH_SLASH_DAMAGE
	front_kick_damage = AUTHORED_FRONT_KICK_DAMAGE
	# Keep the protected lab fighter's shield lifetime. The live player's
	# shield decay was shortened independently after the lab was created.
	shield_decay_interval = 0.5
	_apply_floor_scaling()


## Floor scaling hook for the arena. Values are applied in `_init()` from the
## exported fields, so the arena can also set them before `add_child()` and the
## protected entrance, HUD bars and first `reset_enemy()` all use the scaled
## pool instead of the unscaled 500.
func set_floor_scaling(health_scale: float, damage_scale: float) -> void:
	if health_scale > 0.0:
		health_multiplier = health_scale
	if damage_scale > 0.0:
		damage_multiplier = damage_scale
	_apply_floor_scaling()


func _apply_floor_scaling() -> void:
	var health_scale := health_multiplier if health_multiplier > 0.0 else 1.0
	var damage_scale := damage_multiplier if damage_multiplier > 0.0 else 1.0
	# Re-derive every value from the authored base so repeated calls never
	# compound, whether they come from `_init()` or from the arena.
	max_health = AUTHORED_MAX_HEALTH * health_scale
	slash_damage = AUTHORED_SLASH_DAMAGE * damage_scale
	dash_slash_damage = AUTHORED_DASH_SLASH_DAMAGE * damage_scale
	front_kick_damage = AUTHORED_FRONT_KICK_DAMAGE * damage_scale
	# The duel always starts from a full pool; `reset_player()` refills it again
	# on every retry, and the HUD reads `max_health` for its bar length.
	health = max_health


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	super._ready()
	_character_visual.sweep_uses_front_kick_animation = true
	collision_layer = 4
	collision_mask = 1 | 2
	add_to_group("combat_targets")
	_build_boss_markers()
	reset_enemy()


func setup(actor: CharacterBody3D) -> void:
	_actor = actor
	if is_entering:
		facing = _direction_to_actor()
		_visual_yaw = _direction_yaw(facing)
		_heading.rotation.y = _visual_yaw


func reset_enemy() -> void:
	_cancel_combo(false)
	super.reset_player()
	collision_layer = 4
	collision_mask = 1 | 2
	entrance_time_left = maxf(0.0, entrance_duration)
	state = &"entrance" if is_entering else (&"recover" if combat_enabled else &"idle")
	state_time_left = entrance_time_left
	planned_combo = ROLL_PUNCHES
	active_combo = &""
	shield_cooldown_left = 0.0
	_recovery_left = 0.35
	_strafe_sign = 1.0
	_strafe_time_left = 2.6
	_distance_mode = 0
	adaptive_reaction = &"observe"
	adaptive_reaction_payload.clear()
	if is_instance_valid(_actor):
		facing = _direction_to_actor()
		_visual_yaw = _direction_yaw(facing)
		_heading.rotation.y = _visual_yaw
	_update_boss_markers()


func apply_adaptive_reaction(reaction: StringName, payload: Dictionary = {}) -> void:
	# Keep the later LLM/FSM hook observable without silently replacing these
	# three authored behaviours with a different adaptive combat policy.
	adaptive_reaction = reaction
	adaptive_reaction_payload = payload.duplicate(true)


func desired_distance() -> float:
	if preferred_distance > 0.0:
		return preferred_distance
	if is_instance_valid(_actor):
		return maxf(1.2, float(_actor.get("roll_speed")) * float(_actor.get("roll_duration")))
	return roll_speed * roll_duration


func get_preferred_distance() -> float:
	return desired_distance()


func get_combo_cost(combo_name: StringName) -> float:
	if combo_name == DASH_KICK:
		return get_card_cost("dash_slash") + get_card_cost("front_kick")
	return 2.0 * get_card_cost("roll") + 2.0 * get_card_cost("slash")


func _get_input_direction() -> Vector3:
	# Never consult Input: the player and Boss deliberately share no controls.
	return _ai_direction


func request_card(kind: String) -> bool:
	if is_entering or not combat_enabled or is_dead or get_tree().paused:
		return false
	if combo_active and not _executing_prepaid_card:
		return false
	return super.request_card(kind)


func _physics_process(delta: float) -> void:
	if get_tree().paused:
		return
	_life_time += delta
	if is_entering:
		_advance_entrance(delta)
		return
	_damage_flash_left = maxf(0.0, _damage_flash_left - delta)
	_update_visual_timers(delta)
	_update_shield_decay(delta)
	combo_window_left = maxf(0.0, combo_window_left - delta)
	shield_cooldown_left = maxf(0.0, shield_cooldown_left - delta)
	_update_vertical_velocity(delta)
	_ai_direction = Vector3.ZERO
	var opponent_available := is_instance_valid(_actor) and not bool(_actor.get("is_dead"))
	if is_dead or not combat_enabled or not opponent_available:
		_cancel_combo(not is_dead)
		state = &"dead" if is_dead else &"idle"
	else:
		_update_ai(delta)
	_update_visual_heading(delta)
	if is_rolling:
		_step_support_active = false
		_advance_roll(delta)
	elif is_dashing:
		_step_support_active = false
		_advance_dash(delta)
	elif _is_front_kick_active():
		# The current main-game kick includes a delayed hit and a full action
		# lock. Keep the Boss planted for the same authored animation.
		_step_support_active = false
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		_clamp_to_arena()
	else:
		var speed := move_speed * _get_turn_speed_ratio(_ai_direction)
		velocity.x = _ai_direction.x * speed
		velocity.z = _ai_direction.z * speed
		_move_with_steps(delta)
		_clamp_to_arena()
	_apply_slash_hits()
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	_walk_phase += delta * 13.0 * horizontal_speed / maxf(move_speed, 0.001)
	_update_model(_ai_direction)
	_update_boss_markers()


func _advance_entrance(delta: float) -> void:
	# The shield is a timed invulnerability state, not a large amount of HP.
	# Keep gravity/floor contact active, but never advance combat or spend cards.
	_ai_direction = Vector3.ZERO
	velocity.x = 0.0
	velocity.z = 0.0
	_update_vertical_velocity(delta)
	move_and_slide()
	_clamp_to_arena()
	entrance_time_left = maxf(0.0, entrance_time_left - delta)
	if entrance_time_left < 0.00001:
		entrance_time_left = 0.0
	state_time_left = entrance_time_left
	state = &"entrance" if is_entering else (&"recover" if combat_enabled else &"idle")
	_update_model(Vector3.ZERO)
	_update_boss_markers()


func _update_ai(delta: float) -> void:
	if combo_active:
		_ai_direction = Vector3.ZERO
		if state == &"windup":
			state_time_left = maxf(0.0, state_time_left - delta)
			facing = _windup_direction
			if state_time_left <= 0.0:
				_execute_combo_step()
			return
		_step_wait_left = maxf(0.0, _step_wait_left - delta)
		if _step_wait_left <= 0.0 and not is_action_locked() and slash_time_left <= 0.0:
			_combo_step += 1
			if _combo_step >= _combo_steps.size():
				_finish_combo()
			else:
				_begin_step_windup()
		return
	var previous_energy := energy
	energy = minf(max_energy, energy + energy_regen_per_second * delta)
	if not is_equal_approx(previous_energy, energy):
		energy_changed.emit(energy, max_energy)
	_recovery_left = maxf(0.0, _recovery_left - delta)
	state_time_left = _recovery_left
	if state == &"shield" and _recovery_left > 0.0:
		return
	state = &"recover"
	var distance := _horizontal_actor_offset().length()
	if distance <= shield_trigger_distance and shield < shield_trigger_below and shield_cooldown_left <= 0.0 and energy >= get_card_cost("shield"):
		if request_card("shield"):
			shield_cooldown_left = shield_cooldown
			state = &"shield"
			_recovery_left = maxf(_recovery_left, 0.18)
			state_time_left = _recovery_left
			return
	# Select the next sequence before recharging. In particular, the cheaper
	# dash combo may not continually spend seven energy intended for ten.
	if planned_combo != ROLL_PUNCHES and planned_combo != DASH_KICK:
		planned_combo = ROLL_PUNCHES
	if _recovery_left <= 0.0 and energy + 0.00001 >= get_combo_cost(planned_combo) and distance <= combo_start_distance and _has_line_to_actor():
		_begin_combo()
		return
	_update_recovery_movement(delta)


func _begin_combo() -> void:
	active_combo = planned_combo
	_combo_steps.clear()
	if active_combo == DASH_KICK:
		_combo_steps.assign(["dash_slash", "front_kick"])
	else:
		_combo_steps.assign(["roll", "slash", "slash", "roll"])
	_reserved_energy = get_combo_cost(active_combo)
	energy = maxf(0.0, energy - _reserved_energy)
	energy_changed.emit(energy, max_energy)
	combo_active = true
	_combo_step = 0
	_ai_direction = Vector3.ZERO
	combo_started.emit(active_combo)
	_begin_step_windup()


func _begin_step_windup() -> void:
	_windup_kind = _combo_steps[_combo_step]
	_windup_direction = _direction_to_actor()
	if _windup_kind == "roll" and _combo_step == _combo_steps.size() - 1:
		_windup_direction = -_windup_direction
	# Targeting commits here. Moving or rolling aside during the telegraph can
	# therefore evade a punch; there is no last-frame tracking correction.
	facing = _windup_direction
	state = &"windup"
	state_time_left = roll_windup_duration if _windup_kind == "roll" else windup_duration
	# The second punch follows on a short rhythm, including its own warning.
	if _windup_kind == "slash" and _combo_step > 0 and _combo_steps[_combo_step - 1] == "slash":
		state_time_left = maxf(0.05, punch_interval - maxf(slash_visual_duration, combo_slash_duration))
	# The retreat reverses the heading by 180 degrees. Allocate time for the
	# visible body to turn before starting the roll, rather than spinning it
	# sideways during the authored roll clip. One physics tick covers the final
	# frame's transition out of windup, where normal turn speed resumes.
	var angle_error := absf(wrapf(_direction_yaw(facing) - _visual_yaw, -PI, PI))
	var turn_time := angle_error / maxf(deg_to_rad(boss_turn_speed_degrees), 0.001)
	state_time_left = maxf(state_time_left, turn_time + 1.0 / Engine.physics_ticks_per_second)
	_ai_direction = Vector3.ZERO


func _execute_combo_step() -> void:
	var cost := get_card_cost(_windup_kind)
	if _reserved_energy + 0.00001 < cost:
		_cancel_combo(true)
		state = &"recover"
		return
	# The parent emits the real card cost and handles its animation/effects.
	# Temporarily expose precisely its prepaid allocation; after the call the
	# public energy is unchanged, since the whole sequence was already paid.
	var free_energy := energy
	energy += cost
	_ai_direction = _windup_direction
	facing = _windup_direction
	_executing_prepaid_card = true
	var accepted := super.request_card(_windup_kind)
	_executing_prepaid_card = false
	energy = free_energy
	_ai_direction = Vector3.ZERO
	if not accepted:
		_cancel_combo(true)
		state = &"recover"
		return
	_reserved_energy = maxf(0.0, _reserved_energy - cost)
	state = StringName(_windup_kind)
	_step_wait_left = 0.0
	if _windup_kind == "roll":
		_step_wait_left = roll_duration
	elif _windup_kind == "dash_slash":
		_step_wait_left = dash_duration
	elif _windup_kind == "front_kick":
		_step_wait_left = maxf(front_kick_lock_time_left, front_kick_damage_delay_left)
	else:
		_step_wait_left = slash_time_left
	state_time_left = _step_wait_left


func _finish_combo() -> void:
	var finished := active_combo
	planned_combo = ROLL_PUNCHES if finished == DASH_KICK else DASH_KICK
	combo_active = false
	active_combo = &""
	_combo_steps.clear()
	_reserved_energy = 0.0
	_windup_kind = ""
	_recovery_left = combo_recovery
	state = &"recover"
	state_time_left = _recovery_left
	combo_finished.emit(finished)


func _cancel_combo(refund_unspent: bool) -> void:
	if refund_unspent and _reserved_energy > 0.0:
		energy = minf(max_energy, energy + _reserved_energy)
		energy_changed.emit(energy, max_energy)
	combo_active = false
	active_combo = &""
	_combo_steps.clear()
	_combo_step = 0
	_reserved_energy = 0.0
	_windup_kind = ""
	_executing_prepaid_card = false
	_step_wait_left = 0.0
	state_time_left = 0.0
	_ai_direction = Vector3.ZERO
	is_rolling = false
	is_dashing = false
	roll_time_left = 0.0
	dash_time_left = 0.0
	slash_time_left = 0.0
	front_kick_lock_time_left = 0.0
	front_kick_damage_delay_left = 0.0
	front_kick_damage_fired = false
	combo_window_left = 0.0
	charge_time_left = 0.0
	_buffered_card = ""
	_slash_targets_hit.clear()
	_dash_targets_hit.clear()
	velocity.x = 0.0
	velocity.z = 0.0
	if is_instance_valid(_warning_ring):
		_warning_ring.visible = false
	if is_instance_valid(_character_visual):
		_character_visual.rotation.x = 0.0


func _update_recovery_movement(delta: float) -> void:
	var offset := _horizontal_actor_offset()
	var distance := offset.length()
	var toward := offset.normalized() if distance > 0.01 else facing
	var desired := desired_distance()
	var tolerance := maxf(0.1, distance_tolerance)
	# Hysteresis keeps a tiny position change at the preferred radius from
	# alternating forward/backward movement every physics frame.
	if distance > desired + tolerance:
		_distance_mode = 1
	elif distance < desired - tolerance:
		_distance_mode = -1
	elif (_distance_mode == 1 and distance <= desired) or (_distance_mode == -1 and distance >= desired):
		_distance_mode = 0
	_strafe_time_left -= delta
	if _strafe_time_left <= 0.0:
		_strafe_sign *= -1.0
		_strafe_time_left = 2.6
	var tangent := toward.cross(Vector3.UP) * _strafe_sign
	var direction := toward * float(_distance_mode) + tangent * strafe_amount
	if direction.length_squared() > 1.0:
		direction = direction.normalized()
	var probe_length := maxf(0.30, move_speed * delta + radius)
	if not direction.is_zero_approx() and not _can_traverse(direction.normalized(), probe_length):
		direction = tangent * maxf(strafe_amount, 0.45)
		if not _can_traverse(direction.normalized(), probe_length):
			direction = -tangent * maxf(strafe_amount, 0.45)
			if not _can_traverse(direction.normalized(), probe_length):
				direction = Vector3.ZERO
	_ai_direction = direction
	if not direction.is_zero_approx():
		facing = direction.normalized()


func _horizontal_actor_offset() -> Vector3:
	if not is_instance_valid(_actor):
		return Vector3.ZERO
	var offset := _actor.global_position - global_position
	offset.y = 0.0
	return offset


func _direction_to_actor() -> Vector3:
	var offset := _horizontal_actor_offset()
	return offset.normalized() if offset.length_squared() > 0.0001 else facing


func _has_line_to_actor() -> bool:
	if not is_instance_valid(_actor):
		return false
	var ray := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * 0.85, _actor.global_position + Vector3.UP * 0.85, 1)
	ray.exclude = [get_rid(), _actor.get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(ray).is_empty()


func _can_traverse(direction: Vector3, travel: float) -> bool:
	if direction.is_zero_approx():
		return true
	var point := global_position + direction * travel
	if bounds_enabled:
		var safe_rect := arena_rect.grow(-radius)
		if not safe_rect.has_point(Vector2(point.x, point.z)):
			return false
	if arena_radius > 0.0 and Vector2(point.x - arena_center.x, point.z - arena_center.z).length() > arena_radius - radius:
		return false
	# Probe generously downward because the authored arena is a curved mesh.
	# The probe still refuses a drop larger than a normal safe floor step.
	var query := PhysicsRayQueryParameters3D.create(point + Vector3.UP * 0.85, point + Vector3.DOWN * ground_probe_drop, 1)
	query.exclude = [get_rid()]
	var floor_hit := get_world_3d().direct_space_state.intersect_ray(query)
	if floor_hit.is_empty() or (floor_hit["normal"] as Vector3).dot(Vector3.UP) < cos(floor_max_angle):
		return false
	var height_change := (floor_hit["position"] as Vector3).y - global_position.y
	if height_change > max_step_height + 0.15 or height_change < -ground_probe_drop:
		return false
	var obstacle := KinematicCollision3D.new()
	# Raising the probe avoids treating the floor itself as a horizontal wall;
	# actual movement still uses the complete grounded capsule.
	var raised := global_transform
	raised.origin.y += 0.08
	if test_move(raised, direction * travel, obstacle):
		if obstacle.get_normal().dot(Vector3.UP) < cos(floor_max_angle):
			return false
	return true


func _safe_action_velocity(direction: Vector3, speed: float, delta: float) -> Vector3:
	var travel := speed * delta
	if is_instance_valid(_actor):
		var offset := _horizontal_actor_offset()
		var along := offset.dot(direction)
		var side_squared := maxf(0.0, offset.length_squared() - along * along)
		var separation := maxf(minimum_body_distance, radius + float(_actor.get("radius")) + 0.08)
		if along > 0.0 and side_squared < separation * separation:
			travel = minf(travel, maxf(0.0, along - sqrt(separation * separation - side_squared)))
	if travel > 0.0 and not _can_traverse(direction, travel):
		travel = 0.0
	return direction * (travel / delta if delta > 0.0 else 0.0)


func _advance_roll(delta: float) -> void:
	var step := minf(delta, roll_time_left)
	var motion := _safe_action_velocity(roll_direction, roll_speed * (step / delta if delta > 0.0 else 0.0), delta)
	velocity.x = motion.x
	velocity.z = motion.z
	move_and_slide()
	_clamp_to_arena()
	roll_time_left = maxf(0.0, roll_time_left - step)
	_trail_clock += step
	if _trail_clock >= 0.07:
		_trail_clock = 0.0
		_add_trail()
	if roll_time_left <= 0.0:
		roll_time_left = 0.0
		_update_model(Vector3.ZERO)
		is_rolling = false
		velocity.x = 0.0
		velocity.z = 0.0
		combo_window_left = combo_window_duration
		_roll_attack_used = false


func _advance_dash(delta: float) -> void:
	var step := minf(delta, dash_time_left)
	var previous_position := global_position
	var motion := _safe_action_velocity(dash_direction, dash_speed * (step / delta if delta > 0.0 else 0.0), delta)
	velocity.x = motion.x
	velocity.z = motion.z
	move_and_slide()
	_clamp_to_arena()
	_apply_dash_path_hits(previous_position)
	dash_time_left = maxf(0.0, dash_time_left - step)
	if not _dash_slash_started and dash_time_left <= dash_duration * 0.5:
		_dash_slash_started = true
		_start_slash_visual(dash_direction, true)
	_trail_clock += step
	if _trail_clock >= 0.06:
		_trail_clock = 0.0
		_add_trail()
	if dash_time_left <= 0.0:
		is_dashing = false
		velocity.x = 0.0
		velocity.z = 0.0


func _apply_slash_hits() -> void:
	if is_entering or is_dead or not combat_enabled or get_tree().paused or not is_instance_valid(_actor) or bool(_actor.get("is_dead")):
		return
	if _active_attack_kind == "front_kick":
		if front_kick_damage_fired or front_kick_damage_delay_left > 0.0:
			return
		# The kick resolves once when the real player's delayed hit opens,
		# including a miss; it cannot chase someone for the remaining lock.
		front_kick_damage_fired = true
	elif slash_time_left <= 0.0:
		return
	var target_id := _actor.get_instance_id()
	if target_id in _slash_targets_hit:
		return
	if not COMBAT.can_hit(self, _actor, slash_direction, _active_melee_reach, _active_melee_half_angle, _active_melee_vertical_reach):
		return
	# A successful roll consumes this swing too: its final active frame must
	# never hit the player again as the roll invulnerability ends.
	_slash_targets_hit.append(target_id)
	if _active_attack_kind == "dash_slash" and target_id not in _dash_targets_hit:
		_dash_targets_hit.append(target_id)
	if bool(_actor.get("is_rolling")):
		dodge_observed.emit()
		return
	var previous_health := float(_actor.get("health"))
	if bool(_actor.call("take_damage", get_attack_damage(_active_melee_damage))):
		attack_observed.emit(_active_attack_kind, true, maxf(0.0, previous_health - float(_actor.get("health"))))


func _apply_dash_path_hits(previous_position: Vector3) -> void:
	# Target only the opponent: the inherited player sweep iterates the
	# combat_targets group, which also contains the mirror itself.
	if is_entering or is_dead or not combat_enabled or get_tree().paused or not is_instance_valid(_actor) or bool(_actor.get("is_dead")):
		return
	var target_id := _actor.get_instance_id()
	if target_id in _dash_targets_hit:
		return
	var target_position := _actor.global_position
	if absf(target_position.y - global_position.y) > melee_vertical_reach:
		return
	var segment := global_position - previous_position
	var segment_xz := Vector3(segment.x, 0.0, segment.z)
	var nearest := previous_position
	if segment_xz.length_squared() > 0.000001:
		var offset := Vector3(target_position.x - previous_position.x, 0.0, target_position.z - previous_position.z)
		var along := clampf(offset.dot(segment_xz) / segment_xz.length_squared(), 0.0, 1.0)
		nearest += segment * along
	var path_radius := radius + float(_actor.get("radius")) + 0.2
	if Vector2(target_position.x - nearest.x, target_position.z - nearest.z).length() > path_radius:
		return
	var ray := PhysicsRayQueryParameters3D.create(nearest + Vector3.UP * 0.85, target_position + Vector3.UP * 0.85, 1)
	ray.exclude = [get_rid(), _actor.get_rid()]
	if not get_world_3d().direct_space_state.intersect_ray(ray).is_empty():
		return
	_dash_targets_hit.append(target_id)
	if target_id not in _slash_targets_hit:
		_slash_targets_hit.append(target_id)
	if bool(_actor.get("is_rolling")):
		dodge_observed.emit()
		return
	var previous_health := float(_actor.get("health"))
	if bool(_actor.call("take_damage", get_attack_damage(dash_slash_damage))):
		attack_observed.emit("dash_slash", true, maxf(0.0, previous_health - float(_actor.get("health"))))


func take_damage(amount: float, ignore_damage_reduction: bool = false) -> bool:
	if is_entering:
		return false
	var accepted := super.take_damage(amount, ignore_damage_reduction)
	if is_dead:
		_cancel_combo(false)
		state = &"dead"
		collision_layer = 0
	_update_boss_markers()
	return accepted


func _update_visual_heading(delta: float) -> void:
	if not is_instance_valid(_heading):
		return
	var speed := boss_turn_speed_degrees if state == &"windup" else turn_speed_degrees
	_visual_yaw = rotate_toward(_visual_yaw, _direction_yaw(facing), deg_to_rad(speed) * delta)
	_heading.rotation.y = _visual_yaw


func _update_model(input_direction: Vector3) -> void:
	super._update_model(input_direction)
	if is_instance_valid(_character_visual):
		_character_visual.rotation.x = -0.07 if state == &"windup" and _windup_kind != "roll" else 0.0


func _build_boss_markers() -> void:
	_identity_ring = MeshInstance3D.new()
	_identity_ring.name = "MirrorIdentityRing"
	var identity_mesh := TorusMesh.new()
	identity_mesh.inner_radius = 0.49
	identity_mesh.outer_radius = 0.53
	identity_mesh.rings = 32
	identity_mesh.ring_segments = 6
	_identity_ring.mesh = identity_mesh
	_identity_ring.material_override = _make_material(Color("ff597b"), true)
	_identity_ring.position.y = 0.055
	_identity_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_identity_ring)
	_warning_ring = MeshInstance3D.new()
	_warning_ring.name = "ComboWindupRing"
	var warning_mesh := TorusMesh.new()
	warning_mesh.inner_radius = 0.94
	warning_mesh.outer_radius = 1.0
	warning_mesh.rings = 48
	warning_mesh.ring_segments = 6
	_warning_ring.mesh = warning_mesh
	_warning_material = _make_material(Color(1.0, 0.28, 0.20, 0.72), true)
	_warning_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_warning_ring.material_override = _warning_material
	_warning_ring.position.y = 0.065
	_warning_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_warning_ring.visible = false
	add_child(_warning_ring)
	_shield_shell = MeshInstance3D.new()
	_shield_shell.name = "MirrorShield"
	var shield_mesh := SphereMesh.new()
	shield_mesh.radius = 0.72
	shield_mesh.height = 2.05
	shield_mesh.radial_segments = 24
	shield_mesh.rings = 12
	_shield_shell.mesh = shield_mesh
	var material := _make_material(Color(0.35, 0.84, 1.0, 0.18), true)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_shield_shell.material_override = material
	_shield_shell.position.y = 0.9
	_shield_shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shield_shell.visible = false
	add_child(_shield_shell)
	_entrance_shell = MeshInstance3D.new()
	_entrance_shell.name = "EntranceShell"
	var entrance_mesh := SphereMesh.new()
	entrance_mesh.radius = 0.95
	entrance_mesh.height = 2.45
	entrance_mesh.radial_segments = 40
	entrance_mesh.rings = 24
	_entrance_shell.mesh = entrance_mesh
	_entrance_shell.position.y = 1.05
	_entrance_shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_entrance_material = ShaderMaterial.new()
	_entrance_material.shader = ENTRANCE_SHADER
	_entrance_shell.material_override = _entrance_material
	add_child(_entrance_shell)
	_entrance_ring = MeshInstance3D.new()
	_entrance_ring.name = "EntranceScanRing"
	var scan_mesh := TorusMesh.new()
	scan_mesh.inner_radius = 0.99
	scan_mesh.outer_radius = 1.03
	scan_mesh.rings = 48
	scan_mesh.ring_segments = 6
	_entrance_ring.mesh = scan_mesh
	_entrance_ring_material = _make_material(Color("9beaff"), true)
	_entrance_ring_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_entrance_ring.material_override = _entrance_ring_material
	_entrance_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_entrance_ring)


func _update_boss_markers() -> void:
	if is_instance_valid(_identity_ring):
		_identity_ring.visible = not is_dead
	if is_instance_valid(_warning_ring):
		_warning_ring.visible = combat_enabled and not is_dead and state == &"windup" and _windup_kind != "roll"
		var reach := front_kick_radius if _windup_kind == "front_kick" else slash_reach
		_warning_ring.scale = Vector3(reach, 1.0, reach)
		_warning_material.albedo_color.a = 0.50 + 0.25 * sin(_life_time * 24.0)
	if is_instance_valid(_shield_shell):
		_shield_shell.visible = not is_entering and not is_dead and shield > 0.0
	_update_entrance_visuals()


func _update_entrance_visuals() -> void:
	if not is_instance_valid(_entrance_shell):
		return
	_entrance_shell.visible = is_entering and not is_dead
	_entrance_ring.visible = _entrance_shell.visible
	if not is_entering:
		_character_visual.position.y = 0.0
		return
	var elapsed := maxf(0.0, entrance_duration - entrance_time_left)
	var forming := smoothstep(0.0, 0.45, elapsed)
	var fading := smoothstep(0.0, minf(0.45, entrance_duration), entrance_time_left)
	_entrance_shell.scale = Vector3.ONE * lerpf(0.78, 1.0, forming)
	_entrance_material.set_shader_parameter("elapsed", elapsed)
	_entrance_material.set_shader_parameter("visibility", (0.3 + 0.7 * forming) * fading)
	# A short visual settle introduces the actor while its collision body stays
	# on the ground. A rising scan and pulsing shell continue during the hold.
	_character_visual.position.y = 0.22 * (1.0 - smoothstep(0.0, 0.6, elapsed))
	_entrance_ring.position.y = 0.08 + fmod(elapsed * 0.75, 1.85)
	_entrance_ring.scale = Vector3.ONE * (0.85 + 0.15 * sin(elapsed * 3.0))
	_entrance_ring_material.albedo_color.a = fading * (0.45 + 0.25 * sin(elapsed * 6.0))
