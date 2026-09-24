extends SceneTree
## Integration checks for street activation, pursuing, and disengagement.
## Godot --headless --path . --fixed-fps 60 --script tests/test_street_enemy_leash.gd

const PLAYER = preload("res://player.gd")
const ENCOUNTER = preload("res://street_encounter.gd")
## The city map owns the encounter plot, so its colour decision is checked here
## rather than through a rendered overlay.
const OVERLAY = preload("res://city_overlay.gd")

class RewardReceiver extends Node:
	var rewards := 0
	var rewarded_encounter: Node

	func encounter_cleared(cleared: Node = null) -> void:
		rewards += 1
		rewarded_encounter = cleared

var world: Node3D
var player: CharacterBody3D
var encounter: Node3D
var foe: CharacterBody3D
var rewards: RewardReceiver
var wall: StaticBody3D
var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _test_boxer_activation_and_approach()
	await _test_boxer_range_limit()
	await _test_boxer_line_of_sight()
	for kind: StringName in [&"boxer", &"sniper"]:
		await _test_cloaked_encounter_marker(kind)
	for kind: StringName in [&"sword", &"boxer", &"sniper"]:
		await _test_disengage_and_resume(kind)
		await _test_inactive_position_is_not_clamped(kind)
	if is_instance_valid(world):
		world.queue_free()
		await process_frame
	print("STREET ENEMY LEASH RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_boxer_activation_and_approach() -> void:
	# Activation uses the original 10 m radial range, regardless of the old
	# street segment's width. Starting just inside that range should wake the
	# encounter and let the concealed boxer close the gap.
	await _new_case(&"boxer", Vector3.ZERO, Vector3(0.0, 0.0, 9.0))
	await _steps(2)
	_check(encounter.state == &"active" and foe.combat_enabled, "A boxer activates when the player is within 10 m")
	_check(foe.state == &"chase" and absf(foe.velocity.z) > 1.0, "The boxer starts approaching after activation")
	var initial_gap := _horizontal_distance(foe.global_position, player.global_position)
	await _steps(20)
	_check(_horizontal_distance(foe.global_position, player.global_position) < initial_gap - 1.0, "The boxer closes distance while pursuing")
	_check(encounter.state == &"active" and foe.state == &"chase", "The encounter remains active during the approach")


func _test_boxer_range_limit() -> void:
	# A player between the 10 m activation radius and the 20 m leash must not
	# wake a dormant boxer. The leash only matters after combat is active.
	await _new_case(&"boxer", Vector3(0.0, 0.0, 15.0))
	var initial_position := foe.global_position
	await _steps(20)
	_check(encounter.state == &"dormant" and not foe.combat_enabled, "A player at 15 m does not activate a dormant boxer")
	_check(_horizontal_distance(foe.global_position, initial_position) < 0.01, "The boxer remains stationary outside its detection range")
	player.global_position = Vector3(0.0, 0.0, 9.0)
	await _steps(3)
	_check(encounter.state == &"active" and foe.state == &"chase", "Crossing inside 10 m begins the boxer pursuit")
	var engaged_position := foe.global_position
	player.global_position = engaged_position + Vector3(0.0, 0.0, 15.0)
	var leash_gap := _horizontal_distance(foe.global_position, player.global_position)
	await _steps(3)
	_check(encounter.state == &"active" and foe.combat_enabled and foe.state == &"chase", "An active boxer keeps aggro and chases inside its 20 m leash")
	_check(_horizontal_distance(foe.global_position, player.global_position) < leash_gap - 0.1, "The active boxer closes distance inside its leash")
	player.global_position = foe.global_position + Vector3(0.0, 0.0, 21.0)
	await _steps(3)
	_check(encounter.state == &"dormant" and not foe.combat_enabled, "A boxer drops aggro beyond twice its 10 m activation range")
	var disengaged_position := foe.global_position
	player.global_position = disengaged_position + Vector3(0.0, 0.0, 15.0)
	await _steps(3)
	_check(encounter.state == &"dormant" and not foe.combat_enabled, "A disengaged boxer stays dormant at 15 m without reactivation")
	player.global_position = disengaged_position + Vector3(0.0, 0.0, 9.0)
	await _steps(3)
	_check(encounter.state == &"active" and foe.combat_enabled, "A boxer can reactivate after returning within 10 m")


func _test_boxer_line_of_sight() -> void:
	await _new_case(&"boxer", Vector3(0.0, 0.0, 9.0), Vector3(0.0, 0.0, 18.0), true)
	var initial_position := foe.global_position
	await _steps(20)
	_check(encounter.state == &"dormant" and not foe.combat_enabled, "A solid wall blocks the boxer's initial distant detection")
	_check(_horizontal_distance(foe.global_position, initial_position) < 0.01, "A concealed boxer does not run into a wall toward an unseen player")
	wall.queue_free()
	await process_frame
	await _steps(3)
	_check(encounter.state == &"active" and foe.state == &"chase", "The boxer notices the same player once the view becomes clear")


func _test_cloaked_encounter_marker(kind: StringName) -> void:
	await _new_case(kind, Vector3(70.0, 0.0, 40.0))
	var marker := encounter.get("_marker") as MeshInstance3D
	var overlay := OVERLAY.new()
	world.add_child(overlay)
	await _steps(2)
	_check(foe.is_optically_hidden() and is_instance_valid(marker) and not marker.visible, "%s's encounter ring does not expose its cloaked spawn" % kind)
	# The city map plots encounter positions, so a concealed enemy has to opt out
	# of it for the same reason its world ring stays hidden.
	if kind == &"sniper":
		_check(not bool(encounter.call("shows_on_city_map")), "A concealed sentry is left off the city map")
		_check(overlay.call("encounter_map_color", encounter).a <= 0.0, "A concealed sentry plots no dot at all")
	else:
		_check(bool(encounter.call("shows_on_city_map")), "%s plots on the city map from the start" % kind)
		_check(overlay.call("encounter_map_color", encounter).is_equal_approx(OVERLAY.DANGER), "%s keeps the red unfinished dot" % kind)
	# Both player positions are inside the street trigger; the boxer charges
	# from 4 m while the sniper fires from its own range at 9 m.
	player.global_position = Vector3(4.0 if kind == &"boxer" else 9.0, 0.0, 0.0)
	await _steps(3)
	_check(encounter.state == &"active" and not foe.is_fully_revealed() and not marker.visible, "%s's encounter ring stays hidden throughout the first hologram phase" % kind)
	if kind == &"sniper":
		# The sentry fires from concealment; only a hit drops its cloak, so the
		# ring must stay hidden through a complete firing cycle.
		_check(await _wait_for_enemy_state(&"sniper_cooldown", 150), "The encounter sniper fires without ever exposing itself")
		_check(foe.is_optically_hidden() and not marker.visible, "The sniper ring stays hidden while the sentry shoots from concealment")
		_check(not bool(encounter.call("shows_on_city_map")), "Firing does not put the sentry on the city map either")
		_check(foe.take_damage(10.0), "The concealed sentry accepts the hit that exposes it")
		_check(await _wait_for_enemy_revealed(75), "A hit reveals the encounter sniper")
		await _steps(1)
		_check(marker.visible, "The sniper encounter ring appears once the sentry is exposed")
		# Exposed but unfinished: now on the map, still the red unfinished dot.
		_check(bool(encounter.call("shows_on_city_map")), "An exposed sentry is finally plotted on the city map")
		_check(overlay.call("encounter_map_color", encounter).is_equal_approx(OVERLAY.DANGER), "An exposed sentry uses the red unfinished dot")
	else:
		_check(await _wait_for_enemy_revealed(75), "%s fully reveals during its real combat state" % kind)
		await _steps(1)
		_check(marker.visible, "%s's encounter ring appears after full reveal" % kind)
	_check(foe.take_damage(1000.0), "%s can be defeated while its encounter controls the marker" % kind)
	await _steps(1)
	_check(encounter.state == &"cleared" and marker.visible, "%s's cleared encounter marker appears even if the enemy was cloaked" % kind)
	_check(overlay.call("encounter_map_color", encounter).is_equal_approx(OVERLAY.TEAL), "%s leaves the cyan cleared dot on the city map" % kind)
	# The world ring has to match that map dot, so a beaten sniper nest reads as
	# a finished cyan point in the street and on the overview map alike.
	var cleared_material := marker.material_override as StandardMaterial3D
	_check(cleared_material != null and cleared_material.albedo_color.is_equal_approx(ENCOUNTER.CLEARED_MARKER_COLOR), "%s's cleared ring uses the cyan completion colour" % kind)
	_check(cleared_material != null and cleared_material.emission_enabled and cleared_material.emission.is_equal_approx(ENCOUNTER.CLEARED_MARKER_EMISSION), "%s's cleared ring emits cyan light as a finished point" % kind)


func _test_disengage_and_resume(kind: StringName) -> void:
	# Begin off the spawn marker. Melee then walks closer before winding up;
	# the sniper first backs away until it reaches its aiming distance.
	# Keep the initial player point inside the legacy street trigger for sword
	# and sniper. The boxer is also within its 10 m radial trigger, so all three
	# variants get a real attack/aim state before the player breaks aggro.
	await _new_case(kind, Vector3(5.8, 0.0, 0.0), Vector3(2.0, 0.0, 0.0))
	var attack_state: StringName = &"sniper_aim" if kind == &"sniper" else &"windup"
	_check(await _wait_for_enemy_state(attack_state, 120), "%s reaches its real telegraph before disengagement" % kind)
	_check(foe.take_damage(17.0), "%s can be wounded before it is disengaged" % kind)
	var health_before: float = player.health
	# Leave immediately before the pending strike/shot would be committed.
	foe.state_time_left = 0.001
	foe.velocity.x = 4.0
	foe.velocity.z = 1.0
	var stopped_at := foe.global_position
	player.global_position = Vector3(70.0, 0.0, 40.0)
	await _steps(1)
	_check(encounter.state == &"dormant" and not foe.combat_enabled, "%s stops participating in combat after disengagement" % kind)
	_check(foe.state == &"idle" and is_zero_approx(foe.state_time_left), "%s cancels its pending attack on disengagement" % kind)
	_check(Vector2(foe.velocity.x, foe.velocity.z).length() < 0.01, "%s immediately stops horizontal movement" % kind)
	_check(_horizontal_distance(foe.global_position, stopped_at) < 0.01, "%s stops at its current location without an extra movement frame" % kind)
	await _steps(135)
	_check(_horizontal_distance(foe.global_position, stopped_at) < 0.01 and _horizontal_distance(foe.global_position, foe.spawn_position) > 1.0, "%s stays at its stopped position instead of returning to spawn" % kind)
	_check(is_equal_approx(float(foe.health), float(foe.max_health) - 17.0), "%s keeps its remaining health while out of combat" % kind)
	_check(is_equal_approx(float(player.health), health_before), "%s cannot finish a cancelled strike or shot after disengagement" % kind)
	if kind == &"sniper":
		player.global_position = stopped_at + Vector3(3.0, 0.0, 0.0)
	elif kind == &"boxer":
		# Resume outside the original street again, measured from the boxer.
		player.global_position = stopped_at + Vector3(0.0, 0.0, 8.0)
	else:
		player.global_position = stopped_at + Vector3(-4.0, 0.0, 0.0)
	await _steps(3)
	_check(encounter.state == &"active" and foe.combat_enabled, "%s resumes combat when the player returns" % kind)
	if kind == &"sniper":
		# A sentry never walks, and the wound it took before disengaging holds
		# the rifle: the lockout is a property of the weapon, so it keeps running
		# through disengagement and then lets the sentry re-arm in place.
		_check(bool(foe.call("is_suppressed")), "The pre-disengagement wound still holds the sniper's trigger")
		_check(await _wait_for_enemy_state(&"sniper_aim", 240), "The sniper re-arms from its nest once the lockout expires")
		_check(Vector2(foe.velocity.x, foe.velocity.z).length() < 0.01, "The sniper re-arms without walking")
		_check(_horizontal_distance(foe.global_position, stopped_at) < 0.01 and is_equal_approx(float(foe.health), float(foe.max_health) - 17.0), "The sniper resumes without moving or restoring health")
	else:
		_check(foe.state == &"chase" and Vector2(foe.velocity.x, foe.velocity.z).length() > 0.1, "%s moves again from the location where it disengaged" % kind)
		_check(_horizontal_distance(foe.global_position, stopped_at) > 0.03 and is_equal_approx(float(foe.health), float(foe.max_health) - 17.0), "%s resumes without teleporting or restoring health" % kind)
	_check(foe.take_damage(1000.0), "%s can be defeated after re-engagement" % kind)
	_check(not foe.take_damage(1000.0), "%s rejects a duplicate lethal hit" % kind)
	await _steps(2)
	_check(encounter.state == &"cleared" and rewards.rewards == 1 and rewards.rewarded_encounter == encounter, "%s awards its encounter reward exactly once" % kind)
	player.global_position = Vector3(70.0, 0.0, 40.0)
	await _steps(2)
	player.global_position = foe.global_position + Vector3(1.0, 0.0, 0.0)
	await _steps(3)
	_check(encounter.state == &"cleared" and foe.is_dead and is_zero_approx(float(foe.health)) and rewards.rewards == 1, "%s cannot respawn or reward again on another approach" % kind)


func _test_inactive_position_is_not_clamped(kind: StringName) -> void:
	# An out-of-combat body may stand beyond a former street edge. Activation
	# logic must not snap it into that rectangle while deciding whether to wake.
	var parked_at := Vector3(13.5, 0.0, 4.5)
	await _new_case(kind, Vector3(70.0, 0.0, 40.0), parked_at)
	await _steps(8)
	_check(encounter.state == &"dormant" and _horizontal_distance(foe.global_position, parked_at) < 0.01, "%s preserves an inactive position outside the old street bounds" % kind)


func _new_case(kind: StringName, player_position: Vector3, foe_position: Vector3 = Vector3.ZERO, blocked: bool = false) -> void:
	if is_instance_valid(world):
		world.queue_free()
		await process_frame
	world = Node3D.new()
	world.name = "StreetEnemyLeashWorld"
	root.add_child(world)
	_add_box(Vector3(240.0, 0.2, 240.0), Vector3(0.0, -0.1, 0.0))
	wall = _add_box(Vector3(8.0, 4.0, 1.0), Vector3(0.0, 2.0, 12.0)) if blocked else null
	rewards = RewardReceiver.new()
	world.add_child(rewards)
	player = PLAYER.new()
	player.name = "Player"
	player.bounds_enabled = false
	player.spawn_position = player_position
	world.add_child(player)
	player.set_physics_process(false)
	player.global_position = player_position
	encounter = ENCOUNTER.new()
	encounter.name = "StreetEncounter"
	world.add_child(encounter)
	encounter.setup({
		"position": Vector3.ZERO,
		"axis": Vector3.RIGHT,
		"endpoint_a": Vector3(-12.0, 0.0, 0.0),
		"endpoint_b": Vector3(12.0, 0.0, 0.0),
		"enemy_type": String(kind),
	}, player, rewards)
	encounter.set_physics_process(false)
	foe = encounter.foe
	foe.set_physics_process(false)
	foe.global_position = foe_position
	# Register both the floor and optional wall before the first perception ray.
	await _steps(2)
	encounter.set_physics_process(true)
	foe.set_physics_process(true)


func _add_box(size: Vector3, at: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	world.add_child(body)
	body.position = at
	return body


func _wait_for_enemy_state(expected: StringName, limit: int) -> bool:
	for _index in range(limit):
		if foe.state == expected:
			return true
		await _steps(1)
	return foe.state == expected


func _wait_for_enemy_revealed(limit: int) -> bool:
	for _index in range(limit):
		if foe.is_fully_revealed():
			return true
		await _steps(1)
	return foe.is_fully_revealed()


func _wait_for_enemy_hidden(limit: int) -> bool:
	for _index in range(limit):
		if foe.is_optically_hidden():
			return true
		await _steps(1)
	return foe.is_optically_hidden()


func _steps(count: int) -> void:
	for _index in range(count):
		await physics_frame
		await process_frame


func _horizontal_distance(left: Vector3, right: Vector3) -> float:
	return Vector2(left.x, left.z).distance_to(Vector2(right.x, right.z))


func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		push_error("FAIL: " + description)
