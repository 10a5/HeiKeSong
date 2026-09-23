extends SceneTree
## Real-world action checks for discoverable actions and the shield/kick starters.
## Godot --headless --path . --fixed-fps 60 --script tests/test_new_actions.gd

const ACTIONS: Array[String] = ["move_left", "move_right", "move_up", "move_down", "hand_1", "hand_2", "hand_3", "hand_4", "jump", "cybernetic_boost", "interact"]
const NEW_CARDS: Dictionary = {"punch": 1.0, "sweep": 2.0, "shot": 2.0, "charged_slash": 3.0, "blink": 3.0, "jet_jump": 2.0, "airborne_slash": 4.0, "dive_slash": 5.0, "shield": 2.0, "front_kick": 2.0}
const START := Vector3(0.0, 0.0, 2.0)
const FAR_TARGET := Vector3(7.0, 0.0, -6.0)

var scene: Node3D
var player: CharacterBody3D
var enemy: CharacterBody3D
var passed := 0
var failed := 0
var played: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	scene = load("res://main.tscn").instantiate() as Node3D
	root.add_child(scene)
	await process_frame
	player = scene.get("player") as CharacterBody3D
	enemy = scene.get("enemy") as CharacterBody3D
	scene.set_process(false)
	enemy.combat_enabled = false
	player.action_played.connect(func(kind: String, _cost: float) -> void: played.append(kind))
	await _steps(2)
	await _test_costs_and_rejection()
	await _test_punch()
	await _test_front_kick_area()
	await _test_shot()
	await _test_heavy_slash()
	await _test_blink()
	await _test_jet_jump()
	await _test_airborne_slash()
	await _test_dive_slash()
	await _test_air_combos()
	await _test_roll_attacks()
	await _test_pause()
	await _test_death_and_reset()
	_release_all()
	print("NEW ACTIONS RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_costs_and_rejection() -> void:
	for kind: String in NEW_CARDS:
		await _reset()
		var cost: float = NEW_CARDS[kind]
		_check(_near(player.get_card_cost(kind), cost), "%s exposes its intended energy cost" % kind)
		_check(player.request_card(kind), "%s starts at full energy" % kind)
		_check(_near(player.energy, 10.0 - cost) and played == [kind], "%s spends and emits exactly once" % kind)
		await _reset()
		player.energy = cost - 0.1
		var position_before := player.global_position
		_check(not player.request_card(kind), "%s rejects insufficient energy" % kind)
		_check(_near(player.energy, cost - 0.1) and player.global_position.is_equal_approx(position_before) and played.is_empty(), "%s rejection preserves energy, position and action events" % kind)
	await _reset()
	_check(not player.request_card("missing_card") and _near(player.energy, 10.0), "Unknown actions cannot spend energy")


func _test_punch() -> void:
	await _reset(START, Vector3(0.0, 0.0, 1.0))
	_check(player.request_card("punch"), "Punch starts against a close target")
	_check(_near(enemy.health, 88.0), "Punch deals 12 immediate close-range damage")
	await _steps(12)
	_check(_near(enemy.health, 88.0), "A punch damages its target only once")
	await _reset(START, Vector3(0.0, 0.0, -0.2))
	player.request_card("punch")
	await _steps(8)
	_check(_near(enemy.health, 100.0), "Punch cannot reach a distant target")
	await _reset(START, Vector3(0.0, 0.0, 2.9))
	player.request_card("punch")
	await _steps(8)
	_check(_near(enemy.health, 100.0), "Punch cannot hit behind the character")
	await _reset(START, Vector3(0.0, 0.0, 1.0))
	var wall := _make_wall(Vector3(0.0, 1.3, 1.5), Vector3(3.0, 2.6, 0.12))
	await _steps(2)
	player.request_card("punch")
	await _steps(8)
	_check(_near(enemy.health, 100.0), "A solid wall blocks punch damage")
	wall.queue_free()
	await _steps(2)


func _test_front_kick_area() -> void:
	# The roundhouse is intentionally radial: a target beside or behind the
	# player is still hit, while a target outside two metres is untouched.
	await _reset(START, Vector3(1.0, 0.0, 2.0))
	_check(player.request_card("front_kick"), "Front kick starts beside the player")
	var locked_energy: float = player.energy
	var locked_position: Vector3 = player.global_position
	_check(player.is_action_locked(), "Front kick locks movement for its accelerated action")
	_check(not player.request_card("punch") and not player.request_card("shield") and not player.request_card("roll"), "Front kick rejects every other card while active")
	_check(_near(player.energy, locked_energy), "Rejected cards during front kick do not spend energy")
	Input.action_press("move_right")
	await _steps(4)
	Input.action_release("move_right")
	_check(_horizontal_distance(player.global_position, locked_position) < 0.02, "Front kick holds the player in place")
	_check(_near(enemy.health, 50.0), "Front kick deals 50 area damage to a side target")
	await _steps(14)
	_check(_near(enemy.health, 50.0), "Front kick damages each target only once")
	await _steps(40)
	_check(not player.is_action_locked(), "Front kick unlocks after its complete animation window")
	await _reset(START, Vector3(0.0, 0.0, 4.5))
	player.request_card("front_kick")
	_check(_near(enemy.health, 100.0), "Front kick does not reach targets outside its two metre radius")
	await _reset(START, Vector3(1.0, 0.0, 2.0))
	var wall := _make_wall(Vector3(0.5, 1.3, 2.0), Vector3(0.12, 2.6, 3.0))
	await _steps(2)
	player.request_card("front_kick")
	_check(_near(enemy.health, 100.0), "Front kick area damage respects a solid wall")
	wall.queue_free()
	await _steps(2)


func _test_shot() -> void:
	await _reset(START, Vector3(0.0, 0.0, -5.0))
	_check(player.request_card("shot"), "Shot starts against a distant target")
	_check(_near(enemy.health, 82.0), "Shot deals 18 damage seven metres away")
	await _steps(12)
	_check(_near(enemy.health, 82.0), "The visible shot trace cannot apply repeated damage")
	await _reset(Vector3(0.0, 0.0, 6.0), Vector3(0.0, 0.0, -6.0))
	player.request_card("shot")
	_check(_near(enemy.health, 100.0), "Shot does not reach targets beyond ten metres")
	await _reset(START, Vector3(0.0, 0.0, -5.0))
	var wall := _make_wall(Vector3(0.0, 1.5, 0.2), Vector3(3.0, 3.0, 0.18))
	await _steps(2)
	player.request_card("shot")
	_check(_near(enemy.health, 100.0), "Shot stops at a wall before hitting an enemy behind it")
	wall.queue_free()
	await _steps(2)
	player.request_card("shot")
	_check(_near(enemy.health, 82.0), "Removing the wall restores the same shot line")
	await _reset(Vector3(0.0, 3.0, 2.0), Vector3(0.0, 0.0, -1.0))
	player.gravity_scale = 0.0
	player.velocity = Vector3.ZERO
	player.request_card("shot")
	_check(_near(enemy.health, 100.0), "A high horizontal shot does not hit a target below its ray")


func _test_heavy_slash() -> void:
	await _reset(START, Vector3(0.0, 0.0, 0.3))
	_check(player.request_card("charged_slash"), "Heavy slash begins charging")
	_check(_near(enemy.health, 100.0) and player.charge_time_left > 0.0, "Heavy slash has a real harmless windup")
	await _steps(8)
	_check(_near(enemy.health, 100.0), "Heavy slash remains harmless before its 0.2-second windup ends")
	await _steps(12)
	_check(_near(enemy.health, 55.0), "Heavy slash lands for 45 damage")
	await _steps(12)
	_check(_near(enemy.health, 55.0), "Heavy slash does not repeat damage through recovery")
	await _reset(START, Vector3(0.0, 0.0, 0.3))
	var wall := _make_wall(Vector3(0.0, 1.5, 1.0), Vector3(3.0, 3.0, 0.18))
	await _steps(2)
	player.request_card("charged_slash")
	await _steps(24)
	_check(_near(enemy.health, 100.0), "A wall blocks the completed heavy slash")
	wall.queue_free()
	await _steps(2)
	await _reset(START, Vector3(0.0, 0.0, 0.3))
	player.request_card("charged_slash")
	await _steps(3)
	_check(player.request_card("roll"), "A roll can cancel heavy-slash windup immediately")
	await _steps(30)
	_check(_near(enemy.health, 100.0) and _near(player.charge_time_left, 0.0), "Cancelled heavy windup cannot release a delayed attack")
	await _reset()
	Input.action_press("move_up")
	player.request_card("charged_slash")
	await _steps(3)
	_check(player.velocity.z < -1.0 and player.velocity.z > -2.5, "Heavy windup permits only slow ordinary movement")
	_release_all()


func _test_blink() -> void:
	await _reset(Vector3(0.0, 0.0, 3.0))
	var before := player.global_position
	_check(player.request_card("blink"), "Blink starts on clear ground")
	_check(_near(_horizontal_distance(player.global_position, before), 3.5, 0.025), "Blink instantly travels 3.5 metres")
	_check(player.take_damage(20.0) and _near(player.health, 80.0), "Blink does not leave a lingering invulnerability window")
	await _reset(Vector3(0.0, 0.0, 3.0))
	var wall := _make_wall(Vector3(0.0, 1.5, 1.0), Vector3(3.0, 3.0, 0.18))
	await _steps(2)
	player.request_card("blink")
	_check(player.global_position.z > 1.40 and player.global_position.z < 1.60, "The blink capsule sweeps to the near wall surface without tunnelling")
	wall.queue_free()
	await _steps(2)
	await _reset(Vector3(0.0, 2.5, 3.0))
	player.velocity.y = 4.0
	var height_before: float = player.global_position.y
	_check(player.request_card("blink"), "Blink is available in the air")
	_check(_near(player.global_position.y, height_before) and _near(player.velocity.y, 4.0), "Air blink preserves current height and vertical velocity")


func _test_jet_jump() -> void:
	await _reset()
	var before := player.global_position
	_check(player.request_card("jet_jump"), "Jet jump begins from the ground")
	var energy_after: float = player.energy
	_check(player.velocity.y > 10.0, "Jet jump immediately supplies real upward velocity")
	_check(not player.request_card("jet_jump") and _near(player.energy, energy_after), "Jet jump is limited to one activation per airborne period")
	await _steps(10)
	_check(player.global_position.y > 1.2 and _horizontal_distance(player.global_position, before) > 1.35 and _horizontal_distance(player.global_position, before) < 1.8, "Jet jump rises while moving about 1.5 metres forward")
	var peak: float = player.global_position.y
	for _frame in range(80):
		await _steps(1)
		peak = maxf(peak, player.global_position.y)
		if player.is_on_floor():
			break
	await _steps(2)
	_check(peak > 2.1 and peak < 2.6 and player.is_on_floor(), "Jet jump reaches a higher arc and lands naturally")
	_check(player.request_card("jet_jump"), "Landing refreshes the jet jump limit")
	await _reset(Vector3(0.0, 0.0, 3.0))
	var wall := _make_wall(Vector3(0.0, 2.5, 1.6), Vector3(3.0, 5.0, 0.18))
	await _steps(2)
	player.request_card("jet_jump")
	await _steps(20)
	_check(player.global_position.z > 1.9 and player.global_position.y > 1.0, "Jet motion respects solid walls while preserving upward motion")
	wall.queue_free()
	await _steps(2)


func _test_airborne_slash() -> void:
	await _reset(START, Vector3(0.0, 0.0, 0.4))
	_check(player.request_card("airborne_slash"), "Airborne slash starts directly from the ground")
	_check(_near(enemy.health, 80.0) and player.velocity.y > 8.0, "Airborne slash deals 20 damage and launches the character upward")
	var energy_after: float = player.energy
	_check(not player.request_card("airborne_slash") and _near(player.energy, energy_after), "Repeated airborne slash cannot create unlimited lift")
	await _steps(20)
	_check(player.global_position.y > 1.0 and _near(enemy.health, 80.0), "Airborne slash produces real height and hits each target only once")
	await _steps(60)
	_check(player.is_on_floor() and player.request_card("airborne_slash"), "Landing refreshes airborne slash")
	await _reset(START, Vector3(0.0, 0.0, 0.4))
	var wall := _make_wall(Vector3(0.0, 2.5, 1.0), Vector3(3.0, 5.0, 0.18))
	await _steps(2)
	player.request_card("airborne_slash")
	await _steps(24)
	_check(_near(enemy.health, 100.0) and player.global_position.z > 1.4, "Airborne slash cannot pass through a tall wall or damage beyond it")
	wall.queue_free()
	await _steps(2)


func _test_dive_slash() -> void:
	await _reset(START, Vector3(0.0, 0.0, -0.6))
	_check(player.request_card("dive_slash"), "Dive slash can start on the ground")
	_check(player.is_diving and player.velocity.y > 0.0 and _near(enemy.health, 100.0), "Ground dive begins with a short harmless hop")
	await _steps(3)
	_check(player.global_position.y > 0.1 and _near(enemy.health, 100.0), "Ground dive visibly leaves the floor before its impact")
	await _steps(30)
	_check(not player.is_diving and player.is_on_floor() and _near(enemy.health, 40.0), "Ground dive lands for 60 damage")
	await _steps(20)
	_check(_near(enemy.health, 40.0), "Dive impact damages its target only once")
	await _reset(Vector3(0.0, 2.5, 2.0), Vector3(0.0, 0.0, -0.6))
	_check(player.request_card("dive_slash") and player.velocity.y < -20.0, "An airborne dive begins its downward motion immediately")
	await _steps(20)
	_check(_near(enemy.health, 40.0) and player.is_on_floor(), "Airborne dive resolves the same landing damage")
	await _reset(Vector3(0.0, 2.5, 2.0), Vector3(0.0, 0.0, -0.7))
	var wall := _make_wall(Vector3(0.0, 2.5, 0.2), Vector3(4.0, 5.0, 0.18))
	await _steps(2)
	player.request_card("dive_slash")
	await _steps(25)
	_check(_near(enemy.health, 100.0) and player.global_position.z > 0.5, "Dive movement and impact respect a solid separating wall")
	wall.queue_free()
	await _steps(2)
	await _reset(Vector3(0.0, 2.5, 2.0), Vector3(1.7, 0.0, 1.1))
	player.request_card("dive_slash")
	await _steps(25)
	_check(_near(enemy.health, 40.0), "Dive impact reaches a nearby side target rather than only a forward cone")


func _test_air_combos() -> void:
	await _reset(START, Vector3(0.0, 0.0, -0.2))
	_check(player.request_card("jet_jump"), "Jet-to-air sequence starts with a jet jump")
	await _steps(3)
	_check(player.request_card("airborne_slash"), "Airborne slash chains during the jet movement window")
	_check(player.velocity.y > 0.0 and player.global_position.y > 0.0 and _near(player.energy, 4.1, 0.06), "Jet-to-air retains lift and spends just the two card costs")
	await _steps(12)
	_check(_near(enemy.health, 80.0), "Jet-to-air combo connects its rising slash")
	await _reset(START, Vector3(0.0, 0.0, -0.2))
	player.request_card("jet_jump")
	await _steps(5)
	_check(player.request_card("dive_slash"), "Dive chains directly from jet jump before its motion ends")
	_check(player.is_diving and player.velocity.y < -20.0, "Jet-to-dive immediately replaces upward travel with a dive")
	await _steps(25)
	_check(_near(enemy.health, 40.0) and player.is_on_floor() and not player.is_diving, "Jet-to-dive completes one clean impact and returns control")
	await _reset(START, Vector3(0.0, 0.0, 0.4))
	player.request_card("airborne_slash")
	await _steps(3)
	_check(player.request_card("dive_slash"), "Airborne slash can immediately link into dive slash")
	await _steps(25)
	_check(_near(enemy.health, 20.0) and played == ["airborne_slash", "dive_slash"], "Rising slash and dive apply their separate 20 and 60 damage once")


func _test_roll_attacks() -> void:
	for kind: String in ["punch", "shot"]:
		await _reset(START, Vector3(0.0, 0.0, 1.0 if kind == "punch" else -4.0))
		player.request_card("roll")
		var remaining: float = player.roll_time_left
		_check(player.request_card(kind), "%s can attack immediately during a roll" % kind)
		_check(player.is_rolling and _near(player.roll_time_left, remaining) and _near(enemy.health, 88.0 if kind == "punch" else 82.0), "%s deals damage without cancelling or extending the roll" % kind)
		var energy_after: float = player.energy
		_check(not player.request_card("slash") and _near(player.energy, energy_after), "A roll accepts only one simultaneous attack (%s)" % kind)
		_check(not player.take_damage(20.0), "A roll combined with %s retains its evasion window" % kind)
		await _steps(28)
		_check(not player.is_rolling and not player.is_action_locked(), "Roll plus %s releases action control normally" % kind)


func _test_pause() -> void:
	for kind: String in ["charged_slash", "jet_jump", "airborne_slash", "dive_slash"]:
		await _reset()
		player.request_card(kind)
		await _steps(2)
		var position_before := player.global_position
		var velocity_before := player.velocity
		var charge_before: float = player.charge_time_left
		var energy_before: float = player.energy
		scene.toggle_pause()
		await _steps(15)
		_check(player.global_position.is_equal_approx(position_before) and player.velocity.is_equal_approx(velocity_before) and _near(player.charge_time_left, charge_before), "Pause freezes %s motion and windup" % kind)
		_check(not player.request_card("blink") and not player.take_damage(20.0) and _near(player.energy, energy_before), "Paused %s cannot spend cards or take damage" % kind)
		scene.toggle_pause()
		await _steps(75)
		_check(not player.is_action_locked() and player.charge_time_left <= 0.0 and player.is_on_floor(), "%s resumes after pause and finishes normally" % kind)


func _test_death_and_reset() -> void:
	for kind: String in NEW_CARDS:
		await _reset(START, Vector3(0.0, 0.0, 0.3))
		player.request_card(kind)
		var health_before: float = enemy.health
		_check(player.take_damage(200.0) and player.is_dead, "Damage can defeat the player during %s" % kind)
		_check(player.charge_time_left <= 0.0 and not player.is_diving and player.air_move_time_left <= 0.0, "Death clears extra action state for %s" % kind)
		_check(not player.request_card("blink"), "A dead player cannot activate a card after %s" % kind)
		await _steps(35)
		_check(_near(enemy.health, health_before), "Death cannot leave delayed damage from %s" % kind)
		player.reset_player()
		await _steps(2)
		_check(not player.is_dead and _near(player.health, 100.0) and not player.jet_jump_used and not player.airborne_slash_used, "Reset restores health and airborne limits after %s" % kind)
		_check(player.request_card(kind), "Reset permits a fresh %s activation" % kind)
	for kind: String in ["charged_slash", "jet_jump", "airborne_slash", "dive_slash"]:
		await _reset(START, Vector3(0.0, 0.0, 0.3))
		player.request_card(kind)
		var health_before: float = enemy.health
		player.reset_player()
		await _steps(35)
		_check(_near(enemy.health, health_before) and not player.is_action_locked() and player.charge_time_left <= 0.0, "Reset cancels pending %s without delayed damage" % kind)


func _reset(player_position: Vector3 = START, enemy_position: Vector3 = FAR_TARGET) -> void:
	_release_all()
	if scene.paused:
		scene.toggle_pause()
	player.reset_player()
	enemy.reset_enemy()
	enemy.combat_enabled = false
	player.global_position = player_position
	enemy.global_position = enemy_position
	player.movement_yaw = 0.0
	player.velocity = Vector3.ZERO
	enemy.velocity = Vector3.ZERO
	await _steps(2)
	played.clear()


func _make_wall(location: Vector3, dimensions: Vector3) -> StaticBody3D:
	var wall := StaticBody3D.new()
	wall.name = "NewActionsTestWall"
	wall.position = location
	wall.collision_layer = 1
	var collider := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = dimensions
	collider.shape = shape
	wall.add_child(collider)
	scene.add_child(wall)
	return wall


func _steps(count: int) -> void:
	for _index in range(count):
		await physics_frame
		await process_frame


func _release_all() -> void:
	for action in ACTIONS:
		Input.action_release(action)


func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _near(a: float, b: float, tolerance: float = 0.01) -> bool:
	return absf(a - b) <= tolerance


func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
		print("PASS: " + description)
	else:
		failed += 1
		push_error("FAIL: " + description)
