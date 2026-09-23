extends SceneTree
## Godot --headless --path . --fixed-fps 60 --script tests/test_shield.gd
## Exercise shield accounting, exact decay timing, combat and lifecycle rules.

const PLAYER = preload("res://player.gd")
const ENEMY = preload("res://enemy.gd")

var scene: Node3D
var player: CharacterBody3D
var enemy: CharacterBody3D
var shield_events: Array[float] = []
var health_damage_events: Array[float] = []
var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	scene = Node3D.new()
	root.add_child(scene)
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(30.0, 1.0, 30.0)
	floor_shape.shape = box
	floor_body.position.y = -0.5
	floor_body.add_child(floor_shape)
	scene.add_child(floor_body)
	player = PLAYER.new()
	player.spawn_position = Vector3.ZERO
	scene.add_child(player)
	enemy = ENEMY.new()
	enemy.spawn_position = Vector3(0.0, 0.0, -1.5)
	scene.add_child(enemy)
	enemy.setup(player)
	enemy.combat_enabled = false
	player.shield_changed.connect(func(value: float) -> void: shield_events.append(value))
	player.damaged.connect(func(value: float) -> void: health_damage_events.append(value))
	await _steps(2)
	_test_absorption()
	_test_decay()
	await _test_physics_and_pause()
	await _test_enemy_hit()
	_test_lifecycle()
	print("SHIELD RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_absorption() -> void:
	_reset()
	_check(_near(player.shield, 0.0), "Player starts without a shield")
	_check(player.add_shield(10.0) and _near(player.shield, 10.0), "Generating shield adds ten points")
	_check(_near(player.health, 100.0) and shield_events == [10.0], "Shield is independent from health and publishes its own value")
	_check(player.take_damage(20.0), "A shielded hit still resolves the incoming strike")
	_check(_near(player.shield, 0.0) and _near(player.health, 90.0), "Ten shield against twenty damage loses ten shield and ten health")
	_check(health_damage_events == [10.0], "Health damage feedback reports only the unabsorbed ten damage")
	_reset()
	player.add_shield(10.0)
	_check(player.take_damage(4.0) and _near(player.shield, 6.0) and _near(player.health, 100.0), "Shield fully absorbs a smaller hit without reducing health")
	_check(health_damage_events.is_empty(), "A fully absorbed hit produces no false health-loss event")
	_check(player.take_damage(6.0) and _near(player.shield, 0.0) and _near(player.health, 100.0), "An exactly matching hit depletes shield without health spillover")
	player.add_shield(10.0)
	player.add_shield(10.0)
	_check(_near(player.shield, 20.0), "Successive shield generation stacks its protection")
	_check(not player.add_shield(0.0) and not player.add_shield(-10.0) and _near(player.shield, 20.0), "Invalid shield gains cannot remove or alter protection")
	_check(not player.take_damage(-10.0) and not player.take_damage(0.0) and _near(player.shield, 20.0), "Invalid damage cannot create shield or consume protection")
	player.is_rolling = true
	_check(not player.take_damage(20.0) and _near(player.shield, 20.0), "Successful rolling evasion consumes no shield")


func _test_decay() -> void:
	_reset()
	player.add_shield(10.0)
	player._update_shield_decay(0.49)
	_check(_near(player.shield, 10.0), "Shield remains unchanged before the first half-second")
	player._update_shield_decay(0.01)
	_check(_near(player.shield, 9.0), "Exactly one shield point decays at half a second")
	player._update_shield_decay(1.25)
	_check(_near(player.shield, 7.0), "A long frame applies every elapsed shield decay tick")
	player._update_shield_decay(0.25)
	_check(_near(player.shield, 6.0), "Decay preserves the fractional remainder between updates")
	player._update_shield_decay(0.4)
	player.add_shield(10.0)
	player._update_shield_decay(0.1)
	_check(_near(player.shield, 15.0), "Adding shield to an existing shield does not reset its decay clock")
	player._update_shield_decay(100.0)
	_check(_near(player.shield, 0.0) and _near(player.health, 100.0), "Shield decay stops at zero and never damages health")
	player.add_shield(10.0)
	player._update_shield_decay(0.49)
	_check(_near(player.shield, 10.0), "New protection after depletion begins a fresh half-second interval")
	player.take_damage(10.0)
	player.add_shield(10.0)
	player._update_shield_decay(0.49)
	_check(_near(player.shield, 10.0), "A shield broken by damage also clears the previous decay remainder")
	player._update_shield_decay(0.01)
	_check(_near(player.shield, 9.0), "The replacement shield decays normally after its own first interval")


func _test_physics_and_pause() -> void:
	_reset()
	player.add_shield(10.0)
	player.set_physics_process(true)
	await _steps(30)
	_check(_near(player.shield, 9.0), "The live physics loop loses one shield point over thirty 60 Hz frames")
	paused = true
	var before: float = player.shield
	await _steps(45)
	_check(_near(player.shield, before), "Paused gameplay freezes shield decay")
	_check(not player.add_shield(10.0) and not player.take_damage(20.0) and _near(player.shield, before), "Paused gameplay rejects shield gains and incoming damage")
	paused = false
	await _steps(30)
	_check(_near(player.shield, before - 1.0), "Shield decay continues normally after resuming")
	player.set_physics_process(false)


func _test_enemy_hit() -> void:
	_reset()
	player.add_shield(30.0)
	player.set_physics_process(true)
	enemy.reset_enemy()
	enemy.combat_enabled = true
	for _frame in range(60):
		await _steps(1)
		if enemy.state == &"recovery":
			break
	_check(enemy.state == &"recovery" and _near(player.health, 100.0), "A normal enemy swing can be fully absorbed by shield")
	_check(player.shield >= 9.0 and player.shield <= 10.0, "A shielded enemy swing consumes its twenty damage only once")
	enemy.combat_enabled = false
	player.set_physics_process(false)


func _test_lifecycle() -> void:
	_reset()
	player.add_shield(10.0)
	_check(player.take_damage(200.0) and player.is_dead and _near(player.health, 0.0) and _near(player.shield, 0.0), "Lethal overflow defeats the player after consuming all shield")
	_check(not player.add_shield(10.0) and not player.take_damage(20.0), "A defeated player cannot gain shield or receive repeated damage")
	player.reset_player()
	player.set_physics_process(false)
	player.add_shield(10.0)
	player._update_shield_decay(0.49)
	player.reset_player()
	player.set_physics_process(false)
	_check(not player.is_dead and _near(player.health, 100.0) and _near(player.shield, 0.0), "Restart restores full health and clears temporary shield")
	player.add_shield(10.0)
	player._update_shield_decay(0.49)
	_check(_near(player.shield, 10.0), "Restart clears the old shield decay clock")
	player.is_rolling = true
	player.become_lost()
	_check(player.is_dead and _near(player.health, 0.0) and _near(player.shield, 0.0), "Deep water remains lethal despite shield and rolling evasion")


func _reset() -> void:
	paused = false
	player.reset_player()
	player.set_physics_process(false)
	enemy.combat_enabled = false
	shield_events.clear()
	health_damage_events.clear()


func _steps(count: int) -> void:
	for _index in range(count):
		await physics_frame
		await process_frame


func _near(a: float, b: float) -> bool:
	return absf(a - b) <= 0.01


func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
		print("PASS: " + description)
	else:
		failed += 1
		push_error("FAIL: " + description)
