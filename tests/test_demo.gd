extends SceneTree
## Run: Godot --headless --path . --fixed-fps 60 --script tests/test_demo.gd
## Add -- --soak to exercise three minutes of simulated gameplay.

const ACTIONS: Array[String] = ["move_left", "move_right", "move_up", "move_down", "hand_1", "hand_2", "hand_3", "hand_4", "cybernetic_boost", "jump"]
const SPAWN := Vector3(0.0, 0.0, 2.0)
const ARENA_X := 10.0
const ARENA_Z := 8.0
const EPS := 0.08

var scene: Node
var player: CharacterBody3D
var deck: Node
var adaptive_brain: Node
var shuffle_events: Array[int] = []
var draw_events: Array[Dictionary] = []
var discard_events: Array[Dictionary] = []
var passed := 0
var failed := 0
var played: Array[String] = []
var errors: Array[String] = []
var energy_events: Array[Vector2] = []
var cybernetic_events: Array[Vector2] = []
var _main_process_was_enabled := true

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	print("Testing the 3D greybox action-card demo...")
	var packed := load("res://main.tscn") as PackedScene
	if packed == null:
		push_error("Cannot load res://main.tscn")
		quit(1)
		return
	for action in ACTIONS:
		_check(InputMap.has_action(action), "Input Map contains %s" % action)
	scene = packed.instantiate()
	root.add_child(scene)
	await process_frame
	player = scene.get("player") as CharacterBody3D
	if player == null:
		player = scene.get_node_or_null("Player") as CharacterBody3D
	if player == null:
		push_error("Main/Player must be a CharacterBody3D")
		quit(1)
		return
	# Keep movement/deck regressions isolated from the separately tested enemy AI.
	scene.get("enemy").combat_enabled = false
	deck = scene.get("deck")
	if deck == null:
		push_error("Main must expose its deck")
		quit(1)
		return
	deck.reshuffled.connect(_on_reshuffled)
	deck.card_drawn.connect(_on_drawn)
	deck.card_discarded.connect(_on_discarded)
	player.action_played.connect(_on_action)
	player.status_changed.connect(_on_status)
	player.energy_changed.connect(_on_energy)
	player.cybernetic_changed.connect(_on_cybernetic_changed)
	_main_process_was_enabled = scene.is_processing()
	await _steps(2)
	_check(scene is Node3D, "Main scene is a real 3D scene")
	_check(scene.get("camera") is Camera3D and scene.get("camera").current, "Scene has an active Camera3D")
	_check(scene.get("hud") is Control, "Energy and cards have a screen-space HUD")
	adaptive_brain = scene.get("boss_brain") as Node
	_check(adaptive_brain != null and adaptive_brain.get("player") == player, "Adaptive boss brain observes the live player")
	_check(_near(player.movement_yaw, scene.get("camera_yaw")), "Player movement tracks the camera yaw")
	_check_reset("Initial state")
	await _test_costs_and_recovery()
	var observed: Dictionary = adaptive_brain.snapshot()
	_check(int(observed["total_actions_seen"]) > 0, "Adaptive brain records accepted player actions from the live scene")
	_check(int(observed["attempts"]["rejected"]) > 0, "Adaptive brain records rejected action attempts")
	await _test_arrow_key_bindings()
	await _test_camera_inputs()
	await _test_camera_relative_movement()
	await _test_smooth_turning()
	await _test_turn_angle_speed()
	await _test_roll_lock()
	await _test_dash_slash()
	await _test_cybernetic_input_and_timers()
	await _test_cybernetic_movement_and_cards()
	await _test_cybernetic_action_speeds()
	await _test_cybernetic_pause_and_reset()
	await _test_jump_input_and_arc()
	await _test_jump_movement_independence()
	await _test_jump_card_compatibility()
	await _test_jump_pause_and_reset()
	await _test_jump_geometry()
	await _test_vertical_skill_hooks()
	await _test_deck_distribution_and_cycle()
	await _test_deck_failures_and_refill()
	await _test_input_edges()
	await _test_bounds_and_obstacles()
	await _test_pause_and_reset()
	await _test_scene_restart(packed)
	if "--soak" in OS.get_cmdline_user_args():
		await _test_soak()
	_release_all()
	print("RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)

func _test_costs_and_recovery() -> void:
	player.reset_player()
	_check(player.request_card("slash"), "Slash can be played at full energy")
	_check(_near(player.energy, 8.0), "Slash costs exactly 2 energy")
	_check(_near(player.slash_time_left, 0.14), "Slash feedback begins with a 0.14-second lifetime")
	await _steps(10)
	_check(_near(player.slash_time_left, 0.0), "Slash feedback expires automatically")
	player.reset_player()
	_check(player.request_card("roll"), "Roll can be played at full energy")
	_check(_near(player.energy, 7.0), "Roll costs exactly 3 energy")
	_check(player.is_rolling and _near(player.roll_time_left, 0.44), "Roll starts with its 0.44-second lifetime")
	await _steps(30)
	_check(not player.is_rolling, "Roll completes automatically")
	_check(_xz_distance(player.position, SPAWN) > 3.0 and _xz_distance(player.position, SPAWN) < 3.16, "Roll travels 7 units/second for 0.44 seconds")
	_check(absf(player.position.y - SPAWN.y) < 0.1, "Roll remains grounded")
	player.reset_player()
	player.energy = 1.5
	played.clear()
	errors.clear()
	_check(not player.request_card("slash"), "Insufficient energy rejects slash")
	_check(not player.request_card("roll"), "Insufficient energy rejects roll")
	_check(_near(player.energy, 1.5), "Rejected cards do not spend energy")
	_check(played.is_empty() and _near(player.slash_time_left, 0.0) and not player.is_rolling, "Rejected cards do not execute an action")
	_check(errors.size() == 2, "Insufficient energy reports feedback for both cards")
	player.energy = 0.0
	var start_frame := Engine.get_physics_frames()
	await _steps(60)
	var elapsed := float(Engine.get_physics_frames() - start_frame) / float(Engine.physics_ticks_per_second)
	_check(_near(player.energy, elapsed * 2.0, 0.06), "Energy regenerates continuously at 2 per second")
	player.energy = 9.99
	await _steps(4)
	_check(_near(player.energy, 10.0), "Energy recovery stops at 10")
	var valid_energy := true
	for event in energy_events:
		valid_energy = valid_energy and event.x >= -EPS and event.x <= event.y + EPS and _near(event.y, 10.0)
	_check(valid_energy, "HUD energy signals stay within 0–10")

func _test_camera_relative_movement() -> void:
	_release_all()
	if _main_process_was_enabled:
		scene.set_process(false)
	player.movement_yaw = 0.0
	var cases: Array[Dictionary] = [
		{"keys": ["move_right"], "direction": Vector3.RIGHT},
		{"keys": ["move_left"], "direction": Vector3.LEFT},
		{"keys": ["move_up"], "direction": Vector3.FORWARD},
		{"keys": ["move_down"], "direction": Vector3.BACK},
		{"keys": ["move_right", "move_up"], "direction": (Vector3.RIGHT + Vector3.FORWARD).normalized()},
		{"keys": ["move_left", "move_up"], "direction": (Vector3.LEFT + Vector3.FORWARD).normalized()},
		{"keys": ["move_right", "move_down"], "direction": (Vector3.RIGHT + Vector3.BACK).normalized()},
		{"keys": ["move_left", "move_down"], "direction": (Vector3.LEFT + Vector3.BACK).normalized()}
	]
	for item in cases:
		_release_all()
		player.reset_player()
		player.movement_yaw = 0.0
		for key in item["keys"]:
			Input.action_press(key)
		# Even a reverse turn finishes within 32 frames at the default rate.
		# Starting at SPAWN keeps this short settling movement clear of obstacles.
		await _steps(32)
		var direction: Vector3 = item["direction"]
		_check(_horizontal(player.velocity).is_equal_approx(direction * 5.5), "Aligned movement %s has normalized 5.5-unit/second velocity" % str(item["keys"]))
		_check(_horizontal(player.facing).is_equal_approx(direction), "Movement %s updates facing" % str(item["keys"]))
	_release_all()
	await _steps(2)
	_check(_horizontal(player.velocity) == Vector3.ZERO, "Releasing movement keys stops ordinary movement")
	var last_facing := _horizontal(player.facing)
	player.request_card("slash")
	_check(_horizontal(player.slash_direction).is_equal_approx(last_facing), "Slash uses the last movement direction")
	player.request_card("roll")
	_check(_horizontal(player.roll_direction).is_equal_approx(last_facing), "Idle roll uses the last facing direction")
	await _steps(16)
	player.reset_player()
	player.movement_yaw = PI / 2.0
	Input.action_press("move_up")
	await _steps(3)
	_release_all()
	_check(_horizontal(player.facing).is_equal_approx(Vector3.LEFT), "At 90-degree camera yaw, forward input moves world-left")
	await _steps(2)
	_check(_near(_horizontal(player.velocity).length(), 0.0), "Released movement has no residual velocity")
	if _main_process_was_enabled:
		scene.set_process(true)

func _test_camera_inputs() -> void:
	var yaw_before: float = scene.get("camera_yaw")
	var camera_before: Vector3 = scene.get("camera").global_position
	_send_mouse_button(MOUSE_BUTTON_LEFT, true)
	var drag := InputEventMouseMotion.new()
	drag.position = Vector2(480, 240)
	drag.relative = Vector2(40, 15)
	Input.parse_input_event(drag)
	_send_mouse_button(MOUSE_BUTTON_LEFT, false)
	await _steps(2)
	_check(not _near(scene.get("camera_yaw"), yaw_before), "Left mouse drag rotates the viewing direction")
	_check(scene.get("camera").global_position.distance_to(camera_before) > 0.1, "Camera orbit moves the Camera3D through world space")
	_check(_near(player.movement_yaw, scene.get("camera_yaw")), "Rotated camera updates the movement basis")
	var distance_before: float = scene.get("camera_distance")
	_send_mouse_button(MOUSE_BUTTON_WHEEL_UP, true)
	await _steps(2)
	_check(scene.get("camera_distance") < distance_before, "Mouse wheel up moves the camera closer")
	_send_mouse_button(MOUSE_BUTTON_WHEEL_DOWN, true)
	await _steps(2)
	_check(_near(scene.get("camera_distance"), distance_before), "Mouse wheel down moves the camera back out")
	_send_magnify(1.5)
	await _steps(2)
	_check(scene.get("camera_distance") < distance_before, "Spreading two fingers zooms the camera in")
	_send_magnify(1.0 / 1.5)
	await _steps(2)
	_check(_near(scene.get("camera_distance"), distance_before), "Pinching two fingers zooms the camera back out")
	_send_pan(Vector2(0, -2))
	await _steps(2)
	_check(scene.get("camera_distance") < distance_before, "Two-finger upward scrolling also zooms closer")
	_send_pan(Vector2(0, 2))
	await _steps(2)
	_check(_near(scene.get("camera_distance"), distance_before), "Two-finger downward scrolling restores the wider view")
	_send_magnify(1000.0)
	await _steps(2)
	var near_distance: float = scene.get("camera_distance")
	_check(near_distance > 0.0 and near_distance < 9.0, "Zoom can reach closer than the previous nine-unit limit without crossing the target")
	_send_magnify(0.0001)
	await _steps(2)
	var far_distance: float = scene.get("camera_distance")
	_check(is_finite(far_distance) and far_distance > 24.0, "Zoom can show a wider view than the previous twenty-four-unit limit")
	_drag_camera(Vector2(0, -10000))
	await _steps(2)
	var low_pitch: float = scene.get("camera_pitch")
	_check(low_pitch < 0.45 and low_pitch > -PI / 2.0, "Orbit can lower the view below the former twenty-six-degree limit")
	_drag_camera(Vector2(0, 10000))
	await _steps(2)
	var high_pitch: float = scene.get("camera_pitch")
	_check(high_pitch > 1.22 and high_pitch < PI / 2.0, "Orbit can approach an overhead view without crossing its pole")
	var orbit_travel := 0.0
	for _index in range(5):
		yaw_before = scene.get("camera_yaw")
		_drag_camera(Vector2(300, 0))
		await _steps(2)
		orbit_travel += absf(wrapf(float(scene.get("camera_yaw")) - yaw_before, -PI, PI))
	_check(orbit_travel > TAU, "Horizontal orbit remains free through a complete revolution")
	_check(scene.get("camera").global_transform.is_finite(), "Extreme zoom and pitch keep the camera transform finite")
	scene.restart()
	await _steps(2)


func _test_arrow_key_bindings() -> void:
	var expected := {
		"move_left": KEY_LEFT,
		"move_right": KEY_RIGHT,
		"move_up": KEY_UP,
		"move_down": KEY_DOWN,
	}
	for action: String in expected:
		var has_arrow := false
		for event in InputMap.action_get_events(action):
			if event is InputEventKey and event.physical_keycode == expected[action]:
				has_arrow = true
		_check(has_arrow, "%s includes its matching arrow key" % action)
	if _main_process_was_enabled:
		scene.set_process(false)
	_release_all()
	player.reset_player()
	player.movement_yaw = 0.0
	var before := player.global_position
	_set_physical_key(KEY_UP, true)
	await _steps(12)
	_set_physical_key(KEY_UP, false)
	var arrow_delta := player.global_position - before
	var arrow_direction := _horizontal(player.facing)
	_check(arrow_delta.length() > 0.5 and absf(arrow_delta.z) > absf(arrow_delta.x) * 2.0, "Up arrow uses the same forward movement action as W")
	_release_all()
	player.reset_player()
	player.movement_yaw = 0.0
	before = player.global_position
	_set_physical_key(KEY_W, true)
	await _steps(12)
	_set_physical_key(KEY_W, false)
	var wasd_delta := player.global_position - before
	var wasd_direction := _horizontal(player.facing)
	_check(arrow_direction.is_equal_approx(wasd_direction) and arrow_delta.normalized().dot(wasd_delta.normalized()) > 0.99, "Arrow and WASD movement share the same direction basis")
	if _main_process_was_enabled:
		scene.set_process(true)

func _test_roll_lock() -> void:
	_release_all()
	if _main_process_was_enabled:
		scene.set_process(false)
	player.reset_player()
	player.movement_yaw = 0.0
	Input.action_press("move_right")
	Input.action_press("move_up")
	player.request_card("roll")
	var direction := (Vector3.RIGHT + Vector3.FORWARD).normalized()
	_check(_horizontal(player.roll_direction).is_equal_approx(direction), "Roll prefers current camera-relative diagonal input")
	var remaining_energy: float = player.energy
	_check(player.request_card("slash") and not player.request_card("roll"), "A slash plays during a roll while another roll stays locked")
	_check(_near(player.energy, remaining_energy - player.slash_cost), "Concurrent combo card spends its own energy")
	_check(player.is_rolling and player.slash_time_left > 0.0, "Slash is already active during the roll")
	_release_all()
	player.movement_yaw = PI
	Input.action_press("move_left")
	Input.action_press("move_down")
	await _steps(4)
	_check(player.is_rolling and _horizontal(player.roll_direction).is_equal_approx(direction), "Opposite input cannot redirect an active roll")
	_check(_horizontal(player.velocity).normalized().is_equal_approx(direction), "Camera rotation cannot redirect an active roll")
	_check(_horizontal(player.facing).is_equal_approx(direction), "Facing remains locked during a roll")
	_release_all()
	await _steps(12)
	_check(not player.is_rolling, "Roll releases action lock when it ends")
	_check(player.slash_time_left <= 0.0, "Concurrent slash expires without replaying after the roll")
	if _main_process_was_enabled:
		scene.set_process(true)

func _test_input_edges() -> void:
	_release_all()
	await _steps(2)
	player.reset_player()
	deck.reset_deck(8128)
	played.clear()
	var expected_kind: String = deck.hand[0]["kind"]
	var first_id: int = deck.hand[0]["id"]
	Input.action_press("hand_1")
	Input.action_press("hand_2")
	await _steps(2)
	_check(played == [expected_kind], "Simultaneous card-slot inputs execute only the lowest slot")
	_check(_ids(deck.discard_pile).has(first_id) and deck.hand[0].is_empty(), "Keyboard card use discards its exact ID and empties that slot")
	await _steps(90)
	_check(played == [expected_kind], "Holding a slot key does not auto-play its replacement card")
	_release_all()
	await _steps(2)
	for slot in range(4):
		player.reset_player()
		deck.reset_deck(900 + slot)
		played.clear()
		expected_kind = deck.hand[slot]["kind"]
		Input.action_press("hand_%d" % (slot + 1))
		await _steps(2)
		_check(played == [expected_kind] and deck.hand[slot].is_empty(), "Key %d plays the current card in its slot" % (slot + 1))
		_release_all()
		await _steps(2)
	player.reset_player()
	deck.reset_deck(2026)
	played.clear()
	expected_kind = deck.hand[2]["kind"]
	var yaw_before: float = scene.get("camera_yaw")
	var hud: Control = scene.get("hud")
	var card_rect: Rect2 = hud.card_rect(2)
	var pointer_position: Vector2 = hud.get_global_transform_with_canvas() * card_rect.get_center()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = pointer_position
	root.push_input(click, true)
	var drag := InputEventMouseMotion.new()
	drag.position = pointer_position + Vector2(25, 0)
	drag.relative = Vector2(25, 0)
	root.push_input(drag, true)
	click = InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = false
	click.position = pointer_position
	root.push_input(click, true)
	_check(played == [expected_kind] and deck.hand[2].is_empty(), "Clicking the visible card executes its deck slot")
	_check(_near(scene.get("camera_yaw"), yaw_before), "Dragging from a card cannot start a camera orbit")
	await _steps(20)

func _test_bounds_and_obstacles() -> void:
	scene.set_process(false)
	# Test each outer wall from a safe location; player has a 0.35-unit radius.
	var cases: Array[Dictionary] = [
		{"key": "move_left", "position": Vector3(-9.2, 0, 0), "edge": Vector3(-9.65, 0, 0)},
		{"key": "move_right", "position": Vector3(9.2, 0, 0), "edge": Vector3(9.65, 0, 0)},
		{"key": "move_up", "position": Vector3(0, 0, -7.2), "edge": Vector3(0, 0, -7.65)},
		{"key": "move_down", "position": Vector3(0, 0, 7.2), "edge": Vector3(0, 0, 7.65)}
	]
	for item in cases:
		player.reset_player()
		player.position = item["position"]
		player.movement_yaw = 0.0
		Input.action_press(item["key"])
		await _steps(20)
		_check(_inside_arena(player.position) and _xz_distance(player.position, item["edge"]) < 0.05, "Movement reaches and stops at %s boundary" % item["key"])
		player.request_card("roll")
		await _steps(16)
		_check(_inside_arena(player.position) and _xz_distance(player.position, item["edge"]) < 0.05, "Rolling stops at %s boundary" % item["key"])
		_release_all()
	await _steps(2)
	# Approach the central-left crate from its safe side and ensure collision stops penetration.
	player.reset_player()
	player.position = Vector3(-3.0, 0, -2.7)
	player.movement_yaw = 0.0
	Input.action_press("move_left")
	await _steps(60)
	_release_all()
	_check(player.position.x > -4.3 and player.position.x < -4.15, "Walking stops before the greybox crate surface")
	player.position = Vector3(-3.0, 0, -2.7)
	player.energy = 10.0
	Input.action_press("move_left")
	player.request_card("roll")
	_release_all()
	await _steps(16)
	_check(player.position.x > -4.3 and player.position.x < -4.15, "Roll cannot tunnel through the greybox crate")
	if _main_process_was_enabled:
		scene.set_process(true)

func _test_pause_and_reset() -> void:
	_release_all()
	player.reset_player()
	player.request_card("slash")
	player.energy = 4.0
	var position_before := player.position
	var energy_before: float = player.energy
	var slash_before: float = player.slash_time_left
	_send_key(KEY_ESCAPE)
	await _steps(3)
	_check(bool(scene.get("paused")), "Pause state is enabled")
	_check(player.position.is_equal_approx(position_before), "Paused player position is frozen")
	_check(_near(player.energy, energy_before), "Paused player energy is frozen")
	_check(_near(player.slash_time_left, slash_before), "Paused action timer is frozen")
	var rejected_energy: float = player.energy
	scene.get("hud").card_requested.emit(0)
	_check(_near(player.energy, rejected_energy) and not player.is_rolling, "Paused HUD requests cannot execute or spend energy")
	_send_key(KEY_ESCAPE)
	await _steps(2)
	_check(not bool(scene.get("paused")), "Pause state resumes")
	player.position = Vector3(3, 0, 3)
	player.energy = 4.0
	_send_key(KEY_ESCAPE)
	_send_key(KEY_R)
	await _steps(2)
	_check(not bool(scene.get("paused")) and not paused, "Keyboard R leaves pause mode")
	_check_reset("Keyboard restart")
	_check(_deck_valid() and _occupied_hand_count() == 4 and deck.draw_pile.size() == 6 and deck.discard_pile.is_empty(), "Keyboard restart rebuilds the deck and deals four new cards")

func _test_scene_restart(packed: PackedScene) -> void:
	scene.queue_free()
	await process_frame
	scene = packed.instantiate()
	root.add_child(scene)
	await process_frame
	player = scene.get("player") as CharacterBody3D
	scene.get("enemy").combat_enabled = false
	deck = scene.get("deck")
	_check_reset("Fresh scene restart")
	_check(_deck_valid() and _occupied_hand_count() == 4 and deck.draw_pile.size() == 6 and deck.discard_pile.is_empty(), "Fresh scene begins with ten unique cards and four in hand")

func _test_soak() -> void:
	print("Running three minutes of simulated gameplay...")
	var steps := Engine.physics_ticks_per_second * 180
	var directions: Array[String] = ["move_right", "move_down", "move_left", "move_up"]
	var stable := true
	for index in range(steps):
		if index % 90 == 0:
			_release_all()
			Input.action_press(directions[(index / 90) % directions.size()])
		if index % 23 == 0:
			deck.play_slot((index / 23) % 4)
		if index % 500 == 0:
			Input.action_press("cybernetic_boost")
		elif index % 500 == 1:
			Input.action_release("cybernetic_boost")
		if index % 137 == 0:
			Input.action_press("jump")
		elif index % 137 == 1:
			Input.action_release("jump")
		await _steps(1)
		stable = stable and is_instance_valid(player) and player.energy >= 0.0 and player.energy <= 10.0 and _inside_arena(player.position) and _deck_valid()
		stable = stable and player.cybernetic_time_left >= 0.0 and player.cybernetic_time_left <= 3.0 and player.cybernetic_cooldown_left >= 0.0 and player.cybernetic_cooldown_left <= 8.0
		stable = stable and player.velocity.y >= -30.001 and player.velocity.y <= 8.001
	_check(stable, "Three-minute movement/card/jump soak preserves energy, boost timers, vertical speed, geometry bounds and all ten card IDs")

func _steps(count: int) -> void:
	for _index in range(count):
		await physics_frame
		await process_frame

func _release_all() -> void:
	for action in ACTIONS:
		Input.action_release(action)

func _send_key(keycode: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	Input.parse_input_event(event)
	event = InputEventKey.new()
	event.keycode = keycode
	event.pressed = false
	Input.parse_input_event(event)

func _set_physical_key(keycode: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = pressed
	event.echo = false
	Input.parse_input_event(event)

func _send_mouse_button(button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	event.position = Vector2(480, 240)
	Input.parse_input_event(event)

func _send_magnify(factor: float) -> void:
	var event := InputEventMagnifyGesture.new()
	event.position = Vector2(480, 240)
	event.factor = factor
	Input.parse_input_event(event)

func _send_pan(delta: Vector2) -> void:
	var event := InputEventPanGesture.new()
	event.position = Vector2(480, 240)
	event.delta = delta
	Input.parse_input_event(event)

func _drag_camera(relative: Vector2) -> void:
	_send_mouse_button(MOUSE_BUTTON_LEFT, true)
	var event := InputEventMouseMotion.new()
	event.position = Vector2(480, 240)
	event.relative = relative
	Input.parse_input_event(event)
	_send_mouse_button(MOUSE_BUTTON_LEFT, false)

func _check_reset(context: String) -> void:
	_check(_near(player.energy, 10.0), "%s: energy is 10" % context)
	_check(_xz_distance(player.position, SPAWN) < 0.08, "%s: player returns to spawn" % context)
	_check(_horizontal(player.facing).is_equal_approx(Vector3.FORWARD) and _horizontal(player.velocity) == Vector3.ZERO, "%s: facing and horizontal velocity reset" % context)
	_check(not player.is_rolling and not player.is_dashing and _near(player.roll_time_left, 0.0) and _near(player.dash_time_left, 0.0) and _near(player.slash_time_left, 0.0), "%s: active actions are cleared" % context)
	_check(not player.is_cybernetic_active and _near(player.cybernetic_time_left, 0.0) and _near(player.cybernetic_cooldown_left, 0.0), "%s: cybernetic effect and cooldown are cleared" % context)
	_check(_near(player.position.y, SPAWN.y, 0.08) and absf(player.velocity.y) <= 0.11 and _near(player.gravity_scale, 1.0) and _near(player.vertical_acceleration, 0.0), "%s: vertical movement and flight modifiers reset" % context)

func _inside_arena(point: Vector3) -> bool:
	# The tallest box is 1.8 units; a normal jump adds about 1.33 units.
	return absf(point.x) <= ARENA_X - 0.30 and absf(point.z) <= ARENA_Z - 0.30 and point.y >= -0.1 and point.y <= 3.3

func _horizontal(value: Vector3) -> Vector3:
	return Vector3(value.x, 0.0, value.z)

func _xz_distance(a: Vector3, b: Vector3) -> float:
	return _horizontal(a - b).length()

func _near(a: float, b: float, tolerance: float = 0.001) -> bool:
	return absf(a - b) <= tolerance

func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
		print("PASS: " + description)
	else:
		failed += 1
		push_error("FAIL: " + description)

func _on_action(action_name: String, _cost: float) -> void:
	played.append(action_name)

func _on_status(message: String, is_error: bool) -> void:
	if is_error:
		errors.append(message)

func _on_energy(current: float, maximum: float) -> void:
	energy_events.append(Vector2(current, maximum))

func _on_cybernetic_changed(active_time_left: float, cooldown_left: float) -> void:
	cybernetic_events.append(Vector2(active_time_left, cooldown_left))

func _test_dash_slash() -> void:
	_release_all()
	scene.set_process(false)
	player.reset_player()
	player.movement_yaw = 0.0
	played.clear()
	_check(player.request_card("dash_slash"), "Dash slash can be executed at full energy")
	_check(_near(player.energy, 5.0) and player.is_dashing and _near(player.dash_time_left, 0.24), "Dash slash costs 5 and starts a 0.24-second action")
	var energy_before: float = player.energy
	_check(not player.request_card("slash") and not player.request_card("roll") and not player.request_card("dash_slash"), "Dash slash locks all three action kinds")
	_check(_near(player.energy, energy_before), "Rejected inputs during dash slash do not spend again")
	Input.action_press("move_right")
	player.movement_yaw = PI / 2.0
	await _steps(9)
	_check(player.is_dashing and player.dash_direction.is_equal_approx(Vector3.FORWARD), "Dash slash keeps its original world direction during movement and camera changes")
	_check(player.slash_time_left > 0.0 and player.slash_direction.is_equal_approx(Vector3.FORWARD), "Dash slash follows its movement with a directional slash effect")
	_release_all()
	await _steps(8)
	_check(not player.is_action_locked() and _near(_xz_distance(player.position, SPAWN), 3.84, 0.06), "Dash slash travels 16 units/second for 0.24 seconds and unlocks")
	_check(played == ["dash_slash"], "Dash and its slash emit only one paid action")
	player.reset_player()
	player.energy = 4.9
	_check(not player.request_card("dash_slash") and _near(player.energy, 4.9) and not player.is_dashing, "Dash slash rejects insufficient energy without starting")
	player.reset_player()
	player.position = Vector3(-3.0, 0, -2.7)
	player.movement_yaw = 0.0
	Input.action_press("move_left")
	player.request_card("dash_slash")
	_release_all()
	await _steps(18)
	_check(player.position.x > -4.3 and player.position.x < -4.15, "Dash slash stops before a solid crate without tunneling")
	player.reset_player()
	player.position = Vector3(9.2, 0, 0)
	Input.action_press("move_right")
	player.request_card("dash_slash")
	_release_all()
	await _steps(18)
	_check(_inside_arena(player.position) and _near(player.position.x, 9.65, 0.05), "Dash slash stops at the outer wall")
	player.reset_player()
	if _main_process_was_enabled:
		scene.set_process(true)

func _test_deck_distribution_and_cycle() -> void:
	_release_all()
	player.reset_player()
	deck.reset_deck(31415)
	_check(deck.total_cards == 10 and deck.hand_size == 4, "Deck exposes ten physical cards and four hand slots")
	_check(_deck_valid(), "All card IDs are unique and the deck contains 4 slash, 3 roll and 3 dash-slash cards")
	_check(_occupied_hand_count() == 4 and deck.draw_pile.size() == 6 and deck.discard_pile.is_empty(), "A new deck deals four cards and leaves six to draw")
	var opening: Dictionary = _deck_snapshot()
	deck.reset_deck(31415)
	_check(_deck_snapshot() == opening, "A fixed seed reproduces the same opening and draw pile")
	var orders: Dictionary = {}
	for seed_value in [11, 29, 41, 83]:
		deck.reset_deck(seed_value)
		orders[str(_ids(deck.hand))] = true
	_check(orders.size() > 1, "Fixed distinct seeds exercise different randomized opening hands")
	deck.reset_deck(2718)
	var occupied_snapshot := _deck_snapshot()
	_check(not deck.draw_to_slot(0) and _deck_snapshot() == occupied_snapshot, "Drawing into an occupied slot cannot replace a held card")
	shuffle_events.clear()
	draw_events.clear()
	discard_events.clear()
	var conserved := true
	var draws_only_from_pile := true
	var held_cards_stay := true
	var no_early_recycle := true
	var paid_cards_discarded := true
	for _index in range(6):
		player.reset_player()
		var held_before: Array = _ids(deck.hand.slice(1))
		var available_ids: Array = _ids(deck.draw_pile)
		var used_id: int = deck.hand[0]["id"]
		var accepted: bool = deck.play_slot(0)
		paid_cards_discarded = paid_cards_discarded and accepted and deck.hand[0].is_empty() and _ids(deck.discard_pile).has(used_id)
		conserved = conserved and _deck_valid()
		var discard_before: Array = _ids(deck.discard_pile)
		var drawn: bool = deck.draw_to_slot(0)
		draws_only_from_pile = draws_only_from_pile and drawn and available_ids.has(deck.hand[0]["id"]) and not _ids(deck.draw_pile).has(deck.hand[0]["id"])
		held_cards_stay = held_cards_stay and _ids(deck.hand.slice(1)) == held_before
		no_early_recycle = no_early_recycle and _ids(deck.discard_pile) == discard_before and shuffle_events.is_empty()
		conserved = conserved and _deck_valid()
	_check(paid_cards_discarded, "Successful play transfers the exact card ID from hand to discard")
	_check(draws_only_from_pile, "Every replacement is drawn only from the prior draw pile, without replacement")
	_check(held_cards_stay, "Drawing replacements never changes the other three held cards")
	_check(no_early_recycle, "Discarded cards stay out of draws while the draw pile still has cards")
	_check(conserved, "All ten unique card IDs are conserved through every play and draw")
	_check(deck.draw_pile.is_empty() and deck.discard_pile.size() == 6 and shuffle_events.is_empty(), "An empty draw pile does not recycle until another draw is requested")
	player.reset_player()
	var retained: Array = _ids(deck.hand.slice(1))
	deck.play_slot(0)
	var recyclable: Array = _ids(deck.discard_pile)
	_check(recyclable.size() == 7 and deck.draw_to_slot(0), "The next empty-slot draw can recycle the seven discarded cards")
	_check(shuffle_events == [7] and deck.discard_pile.is_empty() and deck.draw_pile.size() == 6, "Recycling moves all discards once and draws one of them")
	_check(recyclable.has(deck.hand[0]["id"]) and _ids(deck.hand.slice(1)) == retained, "Recycled draw excludes every card still held in hand")
	_check(_deck_valid(), "Deck IDs and type counts remain intact after recycling")
	_check(draw_events.size() == 7 and discard_events.size() == 7, "Each successful transfer emits one draw or discard event")
	player.reset_player()
	deck.reset_deck(31415)

func _test_deck_failures_and_refill() -> void:
	_release_all()
	player.reset_player()
	deck.reset_deck(4001)
	player.energy = 0.0
	var before: Dictionary = _deck_snapshot()
	var played_before: int = played.size()
	_check(not deck.play_slot(0), "Deck rejects a card when energy is insufficient")
	_check(_deck_snapshot() == before and _near(player.energy, 0.0) and played.size() == played_before, "Insufficient energy leaves hand, piles, timer, energy and action count unchanged")
	_check(not deck.play_slot(-1) and not deck.play_slot(4) and _deck_snapshot() == before, "Out-of-range slots leave the deck unchanged")
	player.reset_player()
	player.request_card("roll")
	before = _deck_snapshot()
	var energy_before: float = player.energy
	_check(not deck.play_slot(1) and _deck_snapshot() == before and _near(player.energy, energy_before), "An active roll rejects a hand card without spending or discarding it")
	player.reset_player()
	player.request_card("dash_slash")
	before = _deck_snapshot()
	energy_before = player.energy
	_check(not deck.play_slot(1) and _deck_snapshot() == before and _near(player.energy, energy_before), "An active dash slash rejects a hand card without spending or discarding it")
	player.reset_player()
	var available: Array = _ids(deck.draw_pile)
	var kind: String = deck.hand[0]["kind"]
	var expected_cost: float = {"slash": 2.0, "roll": 3.0, "dash_slash": 5.0}[kind]
	_check(deck.play_slot(0) and _near(player.energy, 10.0 - expected_cost), "Deck spends the selected card's actual action cost exactly once")
	_check(deck.hand[0].is_empty() and _near(deck.refill_time_left[0], 1.0), "A successful card leaves an empty slot with a one-second refill timer")
	player.reset_player()
	before = _deck_snapshot()
	_check(not deck.play_slot(0) and _deck_snapshot() == before and _near(player.energy, 10.0), "An empty slot cannot discard, restart its timer or spend energy")
	await _steps(20)
	_check(deck.hand[0].is_empty() and deck.refill_time_left[0] > 0.6, "A replacement is not dealt immediately after a card is played")
	scene.toggle_pause()
	before = _deck_snapshot()
	energy_before = player.energy
	await _steps(90)
	_check(_deck_snapshot() == before and _near(player.energy, energy_before), "Pause freezes refill timers, all card zones and energy")
	_check(not deck.play_slot(1) and not deck.draw_to_slot(0) and _deck_snapshot() == before, "Paused deck rejects play and direct draw without mutation")
	scene.toggle_pause()
	await _steps(32)
	_check(deck.hand[0].is_empty(), "A card stays empty before one accumulated second of active game time")
	await _steps(12)
	_check(not deck.hand[0].is_empty() and available.has(deck.hand[0]["id"]) and _near(deck.refill_time_left[0], 0.0), "The original slot refills from the draw pile after one active second")
	_check(_deck_valid(), "Timed refill conserves all ten unique cards")
	player.reset_player()
	deck.play_slot(0)
	_check(deck.hand[0].is_empty(), "Reset test begins with a pending refill")
	deck.reset_deck(4001)
	var timers_clear := true
	for timer in deck.refill_time_left:
		timers_clear = timers_clear and _near(timer, 0.0)
	_check(_deck_valid() and _occupied_hand_count() == 4 and deck.draw_pile.size() == 6 and deck.discard_pile.is_empty() and timers_clear, "Deck reset replaces all piles and clears pending refills")
	player.reset_player()
	await _steps(65)
	_check(_deck_valid() and _occupied_hand_count() == 4 and deck.draw_pile.size() == 6, "A stale refill cannot fire after reset")

func _ids(cards: Array) -> Array:
	var result: Array = []
	for card in cards:
		if not card.is_empty():
			result.append(card["id"])
	return result

func _occupied_hand_count() -> int:
	return _ids(deck.hand).size()

func _deck_snapshot() -> Dictionary:
	return {
		"hand": deck.hand.duplicate(true),
		"draw": deck.draw_pile.duplicate(true),
		"discard": deck.discard_pile.duplicate(true),
		"refill": deck.refill_time_left.duplicate()
	}

func _deck_valid() -> bool:
	if deck.hand.size() != 4 or deck.refill_time_left.size() != 4:
		return false
	var seen: Dictionary = {}
	var counts := {"slash": 0, "roll": 0, "dash_slash": 0}
	var all_cards: Array = []
	all_cards.append_array(deck.hand)
	all_cards.append_array(deck.draw_pile)
	all_cards.append_array(deck.discard_pile)
	for card in all_cards:
		if card.is_empty():
			continue
		if typeof(card.get("id")) != TYPE_INT or not counts.has(card.get("kind")):
			return false
		if seen.has(card["id"]):
			return false
		seen[card["id"]] = true
		counts[card["kind"]] += 1
	return seen.size() == 10 and counts == {"slash": 4, "roll": 3, "dash_slash": 3}

func _on_reshuffled(count: int) -> void:
	shuffle_events.append(count)

func _on_drawn(card: Dictionary, slot: int) -> void:
	draw_events.append({"card": card.duplicate(true), "slot": slot})

func _on_discarded(card: Dictionary, slot: int) -> void:
	discard_events.append({"card": card.duplicate(true), "slot": slot})

func _test_cybernetic_input_and_timers() -> void:
	_release_all()
	_set_physical_key(KEY_Q, false)
	await _steps(2)
	player.reset_player()
	deck.reset_deck(8080)
	cybernetic_events.clear()
	var has_physical_q := false
	for event in InputMap.action_get_events("cybernetic_boost"):
		if event is InputEventKey and event.physical_keycode == KEY_Q:
			has_physical_q = true
	_check(has_physical_q, "Cybernetic boost is bound to the physical Q key")
	var deck_before: Dictionary = _deck_snapshot()
	var played_before: int = played.size()
	_set_physical_key(KEY_Q, true)
	await _steps(2)
	_check(player.is_cybernetic_active and player.cybernetic_time_left > 2.9 and player.cybernetic_time_left <= 3.0, "Pressing Q starts the three-second cybernetic boost")
	_check(player.cybernetic_cooldown_left > 7.9 and player.cybernetic_cooldown_left <= 8.0, "Eight-second cooldown starts at activation, alongside the boost")
	_check(_near(player.energy, 10.0) and _deck_snapshot() == deck_before and played.size() == played_before, "Q activation consumes neither energy nor cards and emits no card action")
	var active_before: float = player.cybernetic_time_left
	var cooldown_before: float = player.cybernetic_cooldown_left
	_check(not player.activate_cybernetic() and _near(player.cybernetic_time_left, active_before) and _near(player.cybernetic_cooldown_left, cooldown_before), "Reactivation cannot stack or refresh the active boost")
	await _steps(165)
	_check(player.is_cybernetic_active and player.cybernetic_time_left > 0.1, "Boost remains active shortly before three seconds")
	await _steps(16)
	_check(not player.is_cybernetic_active and _near(player.cybernetic_time_left, 0.0), "Boost ends after three seconds of active gameplay")
	_check(_near(player.cybernetic_cooldown_left, 5.0, 0.1), "Boost expiry leaves approximately five seconds of cooldown")
	cooldown_before = player.cybernetic_cooldown_left
	_check(not player.activate_cybernetic() and _near(player.cybernetic_cooldown_left, cooldown_before), "Cooldown blocks activation without restarting its timer")
	await _steps(288)
	_check(player.cybernetic_cooldown_left > 0.05 and not player.activate_cybernetic(), "Ability is still unavailable shortly before eight seconds")
	await _steps(18)
	_check(_near(player.cybernetic_cooldown_left, 0.0) and not player.is_cybernetic_active, "Cooldown finishes at eight seconds and holding Q does not trigger again")
	_set_physical_key(KEY_Q, false)
	await _steps(2)
	_set_physical_key(KEY_Q, true)
	await _steps(2)
	_check(player.is_cybernetic_active and player.cybernetic_cooldown_left > 7.9, "Releasing and pressing Q after cooldown activates another boost")
	_set_physical_key(KEY_Q, false)
	var valid_events := not cybernetic_events.is_empty()
	var saw_active := false
	var saw_cooldown_only := false
	for event in cybernetic_events:
		valid_events = valid_events and event.x >= 0.0 and event.x <= 3.0 and event.y >= 0.0 and event.y <= 8.0
		saw_active = saw_active or event.x > 0.0
		saw_cooldown_only = saw_cooldown_only or (_near(event.x, 0.0) and event.y > 0.1)
	_check(valid_events and saw_active and saw_cooldown_only, "Cybernetic signals report bounded active and cooldown-only states")
	player.reset_player()
	_release_all()
	await _steps(2)

func _test_cybernetic_movement_and_cards() -> void:
	_release_all()
	scene.set_process(false)
	player.reset_player()
	deck.reset_deck(1818)
	player.energy = 0.0
	var deck_before: Dictionary = _deck_snapshot()
	_check(player.activate_cybernetic() and _near(player.energy, 0.0) and _deck_snapshot() == deck_before, "Cybernetic boost can activate at zero energy without touching any card zone")
	var start_frame := Engine.get_physics_frames()
	await _steps(60)
	var elapsed := float(Engine.get_physics_frames() - start_frame) / float(Engine.physics_ticks_per_second)
	_check(_near(player.energy, elapsed * 2.0, 0.06), "Boost leaves natural energy recovery at two points per second")
	var cases: Array[Dictionary] = [
		{"keys": ["move_right"], "direction": Vector3.RIGHT},
		{"keys": ["move_right", "move_up"], "direction": (Vector3.RIGHT + Vector3.FORWARD).normalized()}
	]
	for item in cases:
		_release_all()
		player.reset_player()
		player.movement_yaw = 0.0
		player.activate_cybernetic()
		for key in item["keys"]:
			Input.action_press(key)
		await _steps(32)
		var expected: Vector3 = item["direction"] * 9.9
		_check(_horizontal(player.velocity).is_equal_approx(expected), "Aligned boosted movement %s is normalized at 5.5 x 1.8 units/second" % str(item["keys"]))
	_release_all()
	player.reset_player()
	player.movement_yaw = 0.0
	player.activate_cybernetic()
	await _steps(185)
	Input.action_press("move_right")
	await _steps(32)
	_check(not player.is_cybernetic_active and _horizontal(player.velocity).is_equal_approx(Vector3.RIGHT * 5.5), "Ordinary speed returns to 5.5 when the boost expires")
	_release_all()
	player.reset_player()
	deck.reset_deck(1919)
	player.activate_cybernetic()
	var active_before: float = player.cybernetic_time_left
	var cooldown_before: float = player.cybernetic_cooldown_left
	var kind: String = deck.hand[0]["kind"]
	var cost: float = {"slash": 2.0, "roll": 3.0, "dash_slash": 5.0}[kind]
	_check(deck.play_slot(0) and _near(player.energy, 10.0 - cost), "Cards remain usable during boost and keep their normal energy cost")
	_check(deck.hand[0].is_empty() and deck.discard_pile.size() == 1 and _deck_valid(), "Boosted card play still transfers exactly one card into discard")
	_check(_near(player.cybernetic_time_left, active_before) and _near(player.cybernetic_cooldown_left, cooldown_before), "Playing a card neither consumes nor refreshes cybernetic timers")
	player.reset_player()
	deck.reset_deck(1919)
	if _main_process_was_enabled:
		scene.set_process(true)

func _test_cybernetic_action_speeds() -> void:
	_release_all()
	scene.set_process(false)
	for kind in ["roll", "dash_slash"]:
		player.reset_player()
		player.movement_yaw = 0.0
		deck.reset_deck(2323)
		player.request_card(kind)
		var action_timer: float = player.roll_time_left if kind == "roll" else player.dash_time_left
		var energy_before: float = player.energy
		var deck_before: Dictionary = _deck_snapshot()
		var action_count: int = played.size()
		_check(player.activate_cybernetic() and player.is_action_locked(), "Boost can activate during %s without clearing the action lock" % kind)
		var current_timer: float = player.roll_time_left if kind == "roll" else player.dash_time_left
		_check(_near(current_timer, action_timer) and _near(player.energy, energy_before) and _deck_snapshot() == deck_before and played.size() == action_count, "Activation during %s preserves its timer, paid cost, cards and action count" % kind)
		if kind == "roll":
			var combo_energy: float = player.energy
			_check(player.request_card("slash") and _near(player.energy, combo_energy - player.slash_cost), "Boosted roll accepts its concurrent slash combo")
		else:
			_check(not player.request_card("slash"), "Boost activation does not allow another card to bypass the %s lock" % kind)
		await _steps(4)
		var expected_speed := 7.0 if kind == "roll" else 16.0
		_check(_near(_horizontal(player.velocity).length(), expected_speed, 0.001), "Boost does not multiply the fixed %s speed" % kind)
		await _steps(30 if kind == "roll" else 16)
		var expected_distance := 3.08 if kind == "roll" else 3.84
		_check(_near(_xz_distance(player.position, SPAWN), expected_distance, 0.06) and not player.is_action_locked() and player.is_cybernetic_active, "%s keeps its normal distance and finishes while boost remains active" % kind)
	player.reset_player()
	if _main_process_was_enabled:
		scene.set_process(true)

func _test_cybernetic_pause_and_reset() -> void:
	_release_all()
	_set_physical_key(KEY_Q, false)
	player.reset_player()
	deck.reset_deck(2424)
	player.activate_cybernetic()
	await _steps(10)
	scene.toggle_pause()
	var active_before: float = player.cybernetic_time_left
	var cooldown_before: float = player.cybernetic_cooldown_left
	var deck_before: Dictionary = _deck_snapshot()
	_set_physical_key(KEY_Q, true)
	await _steps(90)
	_set_physical_key(KEY_Q, false)
	_check(player.is_cybernetic_active and _near(player.cybernetic_time_left, active_before) and _near(player.cybernetic_cooldown_left, cooldown_before), "Pause freezes both the active cybernetic effect and its cooldown")
	_check(not player.activate_cybernetic() and _deck_snapshot() == deck_before, "Paused cybernetic activation is rejected without affecting cards")
	player.reset_player()
	_set_physical_key(KEY_Q, true)
	await _steps(2)
	_set_physical_key(KEY_Q, false)
	_check(not player.activate_cybernetic() and not player.is_cybernetic_active and _near(player.cybernetic_cooldown_left, 0.0), "A ready ability cannot activate through Q or its API while paused")
	scene.toggle_pause()
	player.activate_cybernetic()
	_send_key(KEY_R)
	await _steps(2)
	_check_reset("Keyboard reset during cybernetic boost")
	_check(player.activate_cybernetic(), "Reset clears cooldown so the ability is immediately available")
	player.reset_player()
	_check(not player.is_cybernetic_active and _near(player.cybernetic_time_left, 0.0) and _near(player.cybernetic_cooldown_left, 0.0), "Direct player reset clears both cybernetic timers")
	_release_all()


func _test_smooth_turning() -> void:
	_release_all()
	scene.set_process(false)
	player.reset_player()
	player.movement_yaw = 0.0
	var model_heading: Node3D = player.get_node("Facing")
	Input.action_press("move_down")
	await _steps(1)
	var first_angle := absf(model_heading.rotation.y)
	_check(first_angle > 0.01 and first_angle < deg_to_rad(10.0), "Model starts a 180-degree turn with a visible intermediate angle, not a snap")
	_check(player.facing.is_equal_approx(Vector3.BACK) and _horizontal(player.velocity).normalized().is_equal_approx(Vector3.BACK), "Movement direction and logical card direction respond immediately during a visual turn")
	_release_all()
	await _steps(14)
	_check(_near(absf(model_heading.rotation.y), PI / 2.0, 0.12), "Model is only halfway through a reverse turn after a quarter second")
	var paused_angle := model_heading.rotation.y
	scene.toggle_pause()
	await _steps(12)
	_check(_near(model_heading.rotation.y, paused_angle), "Pause freezes a partially completed turn")
	scene.toggle_pause()
	await _steps(15)
	_check(absf(wrapf(model_heading.rotation.y - PI, -PI, PI)) < 0.02, "Model finishes its last target turn after releasing movement, within half a second")
	player.reset_player()
	_check(_near(model_heading.rotation.y, 0.0), "Reset immediately restores the visible model heading")
	await _steps(2)
	Input.action_press("move_right")
	_check(player.request_card("slash"), "Slash is accepted while requesting a new facing direction")
	player.activate_cybernetic()
	player.request_jump()
	_check(_near(model_heading.rotation.y, 0.0), "Card, boost and jump model updates cannot snap or advance visual heading")
	_check(player.slash_direction.is_equal_approx(Vector3.RIGHT), "Slash uses the requested direction while the body is still turning")
	await _steps(1)
	_check(absf(model_heading.rotation.y) > 0.01 and absf(model_heading.rotation.y) < deg_to_rad(10.0), "Multiple action updates still advance rotation just once per physics frame")
	_release_all()
	player.reset_player()
	for sign_value in [-1.0, 1.0]:
		var before_yaw: float = deg_to_rad(179.0) * sign_value
		player.facing = Vector3.FORWARD.rotated(Vector3.UP, before_yaw)
		await _steps(32)
		var before := model_heading.rotation.y
		var target_yaw := -before_yaw
		player.facing = Vector3.FORWARD.rotated(Vector3.UP, target_yaw)
		await _steps(1)
		_check(absf(wrapf(model_heading.rotation.y - target_yaw, -PI, PI)) < 0.001 and absf(wrapf(model_heading.rotation.y - before, -PI, PI)) < deg_to_rad(3.0), "Turning across the +/-180-degree boundary takes the short path (%+.0f)" % sign_value)
	player.reset_player()
	if _main_process_was_enabled:
		scene.set_process(true)


func _test_turn_angle_speed() -> void:
	_release_all()
	scene.set_process(false)
	player.reset_player()
	player.movement_yaw = 0.0
	var model_heading: Node3D = player.get_node("Facing")
	Input.action_press("move_down")
	await _steps(1)
	var reverse_speed := _horizontal(player.velocity).length()
	var previous_speed := reverse_speed
	var previous_error := absf(wrapf(model_heading.rotation.y - PI, -PI, PI))
	_check(previous_error > deg_to_rad(160.0) and reverse_speed > 0.0 and reverse_speed < 5.5 * 0.25, "Reversing movement starts slowly while the visible model still faces away")
	var recovers_monotonically := true
	for frame in range(31):
		await _steps(1)
		var speed := _horizontal(player.velocity).length()
		var angle_error := absf(wrapf(model_heading.rotation.y - PI, -PI, PI))
		recovers_monotonically = recovers_monotonically and angle_error <= previous_error + 0.001 and speed >= previous_speed - 0.001
		previous_speed = speed
		previous_error = angle_error
	_check(recovers_monotonically and previous_speed > reverse_speed * 4.0 and _near(previous_speed, 5.5, 0.001) and previous_error < 0.001, "Reverse-turn movement recovers smoothly to full speed as the actual model aligns")

	_release_all()
	player.reset_player()
	player.movement_yaw = 0.0
	Input.action_press("move_right")
	await _steps(1)
	var side_speed := _horizontal(player.velocity).length()
	_check(side_speed > reverse_speed * 2.0 and side_speed < 5.5 * 0.8, "A 90-degree change moves faster than a reverse turn but slower than aligned movement")

	_release_all()
	player.reset_player()
	player.movement_yaw = 0.0
	player.activate_cybernetic()
	Input.action_press("move_down")
	await _steps(1)
	var boosted_reverse_speed := _horizontal(player.velocity).length()
	_check(_near(boosted_reverse_speed / reverse_speed, 1.8, 0.01) and boosted_reverse_speed < 9.9 * 0.25, "Q multiplies turning movement by 1.8 without bypassing the reverse-turn slowdown")
	_release_all()
	await _steps(1)
	_check(_horizontal(player.velocity) == Vector3.ZERO and absf(wrapf(model_heading.rotation.y - PI, -PI, PI)) > 0.1, "Releasing movement stops immediately even before the visible turn finishes")

	var straight_arc: Array[Vector2] = []
	var airborne_arc_matches := true
	var air_reverse_speed := 0.0
	for turning in [false, true]:
		_release_all()
		player.reset_player()
		player.movement_yaw = 0.0
		await _steps(2)
		_check(player.request_jump(), "Jump starts for the airborne turn comparison (turning=%s)" % turning)
		var takeoff_height := player.position.y
		Input.action_press("move_down" if turning else "move_up")
		for frame in range(12):
			await _steps(1)
			var vertical_state := Vector2(player.position.y - takeoff_height, player.velocity.y)
			if turning:
				# Floor collision recovery can shift takeoff within the 0.001 safe margin.
				airborne_arc_matches = airborne_arc_matches and _near(vertical_state.x, straight_arc[frame].x, 0.001) and _near(vertical_state.y, straight_arc[frame].y, 0.001)
				if frame == 0:
					air_reverse_speed = _horizontal(player.velocity).length()
			else:
				straight_arc.append(vertical_state)
	_check(_near(air_reverse_speed, reverse_speed, 0.01) and air_reverse_speed < 5.5 * 0.25 and not player.is_on_floor(), "Airborne XZ movement receives the same reverse-turn slowdown as grounded movement")
	_check(airborne_arc_matches, "Turning in air changes horizontal speed without changing the jump's height or vertical velocity")

	for kind in ["roll", "dash_slash"]:
		_release_all()
		player.reset_player()
		player.movement_yaw = 0.0
		await _steps(2)
		Input.action_press("move_down")
		_check(player.request_card(kind), "Reverse-facing %s begins normally" % kind)
		_release_all()
		await _steps(1)
		var expected_speed := 7.0 if kind == "roll" else 16.0
		_check(absf(wrapf(model_heading.rotation.y - PI, -PI, PI)) > deg_to_rad(160.0) and _near(_horizontal(player.velocity).length(), expected_speed, 0.001), "%s keeps its fixed speed even while the model is nearly opposite its travel direction" % kind)
		await _steps(30 if kind == "roll" else 19)
		var expected_distance := 3.08 if kind == "roll" else 3.84
		_check(_near(_xz_distance(player.position, SPAWN), expected_distance, 0.06), "Turning does not shorten the fixed %s travel distance" % kind)

	for sign_value in [-1.0, 1.0]:
		_release_all()
		player.reset_player()
		player.movement_yaw = deg_to_rad(179.0) * sign_value
		Input.action_press("move_up")
		await _steps(32)
		var before_yaw := model_heading.rotation.y
		player.movement_yaw = -player.movement_yaw
		await _steps(1)
		var angular_step := absf(wrapf(model_heading.rotation.y - before_yaw, -PI, PI))
		_check(angular_step < deg_to_rad(3.0) and _horizontal(player.velocity).length() > 5.5 * 0.95, "Movement across the +/-180-degree boundary keeps near-full speed for its tiny turn (%+.0f)" % sign_value)
	_release_all()
	player.reset_player()
	if _main_process_was_enabled:
		scene.set_process(true)


func _test_jump_input_and_arc() -> void:
	_release_all()
	scene.restart()
	await _steps(3)
	var space_bound := false
	for event in InputMap.action_get_events("jump"):
		if event is InputEventKey and event.physical_keycode == KEY_SPACE:
			space_bound = true
	_check(space_bound, "Jump is mapped to the physical Space key")
	var deck_before := _deck_snapshot()
	_set_physical_key(KEY_SPACE, true)
	await _steps(2)
	_check(player.position.y > 0.1 and player.velocity.y > 0.0 and not player.is_on_floor(), "Space actually lifts the 3D character off the floor")
	var velocity_before := player.velocity.y
	_check(not player.request_jump() and _near(player.velocity.y, velocity_before), "A second jump cannot reset upward velocity in midair")
	var peak := player.position.y
	for index in 55:
		await _steps(1)
		peak = maxf(peak, player.position.y)
	_check(peak > 1.2 and peak < 1.4, "Jump reaches approximately 1.3 units of real height")
	_check(player.is_on_floor() and absf(player.position.y) < 0.05, "Character lands naturally and holding Space does not auto-jump")
	_check(_near(player.energy, 10.0) and _deck_snapshot() == deck_before, "Jump does not consume energy or alter the card piles")
	_set_physical_key(KEY_SPACE, false)
	await _steps(2)
	_set_physical_key(KEY_SPACE, true)
	await _steps(2)
	_check(player.velocity.y > 0.0, "Releasing and pressing Space allows a new jump after landing")
	_set_physical_key(KEY_SPACE, false)
	_release_all()
	player.reset_player()
	await _steps(2)


func _test_jump_movement_independence() -> void:
	scene.set_process(false)
	var heights: Array[float] = []
	for boost in [false, true]:
		_release_all()
		player.reset_player()
		player.movement_yaw = 0.0
		await _steps(2)
		if boost:
			player.activate_cybernetic()
		player.request_jump()
		# Keep this arc/boost comparison aligned; turning in air is tested separately.
		Input.action_press("move_up")
	await _steps(30)
		heights.append(player.position.y)
		_check(_near(_horizontal(player.velocity).length(), 9.9 if boost else 5.5, 0.01), "Air control retains the current horizontal movement speed (boost=%s)" % boost)
	_check(_near(heights[0], heights[1], 0.001), "Cybernetic movement boost does not change the jump arc")
	_release_all()
	player.reset_player()
	if _main_process_was_enabled:
		scene.set_process(true)


func _test_jump_card_compatibility() -> void:
	_release_all()
	for kind in ["slash", "roll", "dash_slash"]:
		player.reset_player()
		await _steps(2)
		player.request_jump()
		await _steps(5)
		var vertical_before := player.velocity.y
		_check(player.request_card(kind) and _near(player.velocity.y, vertical_before), "Airborne %s preserves the existing vertical velocity" % kind)
		await _steps(3)
		_check(player.position.y > 0.5 and player.velocity.y < vertical_before, "Gravity continues through airborne %s" % kind)
		await _steps(50)
		_check(player.is_on_floor(), "Airborne %s ends with a collision-based landing" % kind)
	for kind in ["roll", "dash_slash"]:
		player.reset_player()
		await _steps(2)
		player.request_card(kind)
		_check(not player.request_jump() and player.is_action_locked(), "Jump cannot interrupt an active %s" % kind)
	player.reset_player()
	await _steps(2)


func _test_jump_pause_and_reset() -> void:
	_release_all()
	player.reset_player()
	await _steps(2)
	player.request_jump()
	await _steps(8)
	scene.toggle_pause()
	var position_before := player.position
	var velocity_before := player.velocity
	await _steps(20)
	_check(player.position.is_equal_approx(position_before) and player.velocity.is_equal_approx(velocity_before), "Pause freezes both height and vertical velocity")
	_check(not player.request_jump(), "Paused jump requests are rejected")
	_send_key(KEY_R)
	await _steps(2)
	_check_reset("Reset during a jump")


func _test_jump_geometry() -> void:
	_release_all()
	player.reset_player()
	# Drop onto the existing 0.9-unit box, then jump from its top surface.
	player.position = Vector3(-6.2, 2.2, 3.3)
	await _steps(45)
	_check(player.is_on_floor() and _near(player.position.y, 0.9, 0.04), "Character can land on a box above ground level")
	_check(player.request_jump(), "Box tops count as valid ground for jumping")
	await _steps(18)
	_check(player.position.y > 2.1, "Jumping from a box retains the elevated starting height")
	await _steps(35)
	_check(player.is_on_floor() and _near(player.position.y, 0.9, 0.04), "Character lands back on the box without being clamped to ground height")
	player.reset_player()
	await _steps(2)


func _test_vertical_skill_hooks() -> void:
	_release_all()
	player.reset_player()
	await _steps(2)
	player.position.y = 2.0
	player.velocity = Vector3.ZERO
	player.gravity_scale = 0.0
	await _steps(30)
	_check(_near(player.position.y, 2.0, 0.02), "Zero gravity allows a future skill to hover at an arbitrary height")
	player.gravity_scale = 1.0
	player.vertical_acceleration = player.gravity
	await _steps(20)
	_check(_near(player.position.y, 2.0, 0.02), "Lift can counter gravity without changing XZ movement")
	player.reset_player()
	await _steps(2)
	player.vertical_acceleration = player.gravity + 12.0
	await _steps(15)
	_check(player.position.y > 0.2 and player.velocity.y > 0.0, "Positive net lift can take off from the ground")
	player.reset_player()
	await _steps(2)
	_check_reset("Reset after future flight modifiers")
