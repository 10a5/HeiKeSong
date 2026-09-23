extends SceneTree
## Real capsule movement on stairs, walls, ceilings and airborne approaches.
## Godot --headless --path . --fixed-fps 60 --script tests/test_player_steps.gd

const PLAYER = preload("res://player.gd")
var scene: Node3D
var player: CharacterBody3D
var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	scene = Node3D.new()
	root.add_child(scene)
	_box(Vector3(60.0, 0.5, 30.0), Vector3(0.0, -0.25, 0.0))
	# Five real 25 cm risers; no ramp substitutes the walking surface.
	for index in range(5):
		var height := float(index + 1) * 0.25
		_box(Vector3(0.75, height, 3.0), Vector3(0.375 + index * 0.75, height * 0.5, 0.0), true)
	_box(Vector3(3.0, 1.25, 3.0), Vector3(5.25, 0.625, 0.0), true)
	_box(Vector3(3.0, 0.5, 3.0), Vector3(1.5, 0.25, 6.0))
	_box(Vector3(3.0, 0.25, 3.0), Vector3(1.5, 0.125, -6.0))
	_box(Vector3(6.0, 0.5, 3.0), Vector3(0.0, 2.0, -6.0))
	player = PLAYER.new()
	player.bounds_enabled = false
	player.spawn_position = Vector3(-1.0, 0.0, 0.0)
	scene.add_child(player)
	await _steps(8)
	_check(player.is_on_floor(), "Player begins grounded beside the staircase")
	Input.action_press("move_right")
	await _steps(65)
	Input.action_release("move_right")
	await _steps(6)
	_check(player.global_position.x > 2.9 and player.global_position.y > 1.2 and player.is_on_floor(), "Ordinary movement climbs five 25 cm steps to the upper tread")
	Input.action_press("move_left")
	var fastest_fall := 0.0
	var largest_drop := 0.0
	for _frame in range(85):
		var previous_height := player.global_position.y
		await _steps(1)
		fastest_fall = minf(fastest_fall, player.velocity.y)
		largest_drop = maxf(largest_drop, previous_height - player.global_position.y)
	Input.action_release("move_left")
	_check(player.global_position.x < -0.4 and player.global_position.y < 0.05 and player.is_on_floor(), "Walking back down the staircase returns to the ground")
	_check(fastest_fall > -0.2 and largest_drop <= 0.27, "Small downward steps follow each tread without a ballistic fall or skipping risers")
	await _park(Vector3(-1.0, 0.0, 6.0))
	Input.action_press("move_right")
	await _steps(60)
	Input.action_release("move_right")
	_check(player.global_position.x < 0.0 and player.global_position.y < 0.1, "A 50 cm obstacle remains a wall and cannot be walked up")
	await _park(Vector3(-1.0, 0.0, -6.0))
	Input.action_press("move_right")
	await _steps(60)
	Input.action_release("move_right")
	_check(player.global_position.x < 0.0 and player.global_position.y < 0.16, "A low ceiling blocks a step when the full capsule cannot fit")
	await _park(Vector3(-1.0, 0.0, 0.0))
	_check(player.request_jump(), "Jump is still available next to the stairs")
	Input.action_press("move_right")
	await _steps(10)
	_check(player.global_position.y > 0.65 and player.velocity.y > 0.0 and not player.is_on_floor(), "Takeoff preserves upward velocity beside a stair instead of snapping onto it")
	Input.action_release("move_right")
	await _park(Vector3(-1.0, 0.0, 6.0))
	player.global_position.y = 0.24
	player.gravity_scale = 0.0
	player.velocity = Vector3.ZERO
	player.floor_snap_length = 0.0
	player.move_and_slide()
	player.floor_snap_length = 0.32
	await _steps(2)
	_check(not player.is_on_floor() and player.global_position.y > 0.23, "The airborne ledge test begins truly unsupported")
	Input.action_press("move_right")
	await _steps(50)
	Input.action_release("move_right")
	_check(player.global_position.x < 0.0 and player.global_position.y < 0.3, "An airborne approach cannot climb an otherwise reachable 26 cm ledge")
	for card: String in ["roll", "dash_slash"]:
		await _park(Vector3(-1.0, 0.0, 6.0))
		Input.action_press("move_right")
		_check(player.request_card(card), "%s can be played beside a tall obstacle" % card)
		await _steps(22)
		Input.action_release("move_right")
		_check(player.global_position.x < -0.25 and player.global_position.y < 0.1 and not player.is_action_locked(), "%s stops against the wall without climbing or tunnelling" % card)
	await _park(Vector3(6.3, 1.25, 0.0))
	Input.action_press("move_right")
	await _steps(20)
	Input.action_release("move_right")
	_check(not player.is_on_floor() and player.global_position.y > 0.6 and player.global_position.y < 1.2 and player.velocity.y < -1.0, "Leaving a high ledge starts a natural fall instead of snapping to distant ground")
	print("PLAYER STEPS RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _box(size: Vector3, location: Vector3, triangle_collision: bool = false) -> void:
	var body := StaticBody3D.new()
	body.position = location
	var shape := CollisionShape3D.new()
	if triangle_collision:
		var mesh := BoxMesh.new()
		mesh.size = size
		shape.shape = mesh.create_trimesh_shape()
	else:
		var box := BoxShape3D.new()
		box.size = size
		shape.shape = box
	body.add_child(shape)
	scene.add_child(body)


func _park(location: Vector3) -> void:
	Input.action_release("move_left")
	Input.action_release("move_right")
	player.spawn_position = location
	player.reset_player()
	await _steps(8)


func _steps(count: int) -> void:
	for _frame in range(count):
		await physics_frame
		await process_frame


func _check(condition: bool, label: String) -> void:
	if condition:
		passed += 1
		print("PASS: ", label)
	else:
		failed += 1
		push_error("FAIL: %s at %s, velocity %s" % [label, player.global_position, player.velocity])
