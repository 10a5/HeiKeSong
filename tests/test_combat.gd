extends SceneTree
## Godot --headless --path . --fixed-fps 60 --script tests/test_combat.gd
## Exercise combat using the real scene, collision world, input, and physics ticks.

const ACTIONS: Array[String] = ["move_left", "move_right", "move_up", "move_down", "hand_1", "hand_2", "hand_3", "hand_4", "cybernetic_boost", "jump"]
const PLAYER_START := Vector3(0.0, 0.0, 1.0)
const ENEMY_START := Vector3(0.0, 0.0, -1.0)

var scene: Node3D
var player: CharacterBody3D
var enemy: CharacterBody3D
var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("Testing the basic 3D melee opponent...")
	var packed := load("res://main.tscn") as PackedScene
	if packed == null:
		push_error("Cannot load res://main.tscn")
		quit(1)
		return
	scene = packed.instantiate() as Node3D
	root.add_child(scene)
	await process_frame
	player = scene.get("player") as CharacterBody3D
	enemy = scene.get("enemy") as CharacterBody3D
	if player == null or enemy == null:
		push_error("Main must expose a player and a CharacterBody3D enemy")
		quit(1)
		return
	# Keep camera-relative test directions deterministic; input routing stays active.
	scene.set_process(false)
	enemy.combat_enabled = false
	await _steps(2)
	_check(enemy.health == enemy.max_health and player.health == player.max_health, "Both combatants begin at full health")
	await _test_player_slash()
	await _test_hit_geometry()
	await _test_dash_damage()
	await _test_card_combos()
	await _test_telegraph_and_single_hit()
	await _test_walking_cannot_evade()
	await _test_roll_timing()
	await _test_recovery_counterattack()
	await _test_pause()
	await _test_death_and_restart()
	_release_all()
	print("COMBAT RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_player_slash() -> void:
	await _reset_pair(false, PLAYER_START, Vector3(0, 0, -0.6))
	_check(player.request_card("slash"), "Player can play slash against the opponent")
	await _steps(2)
	_check(_near(enemy.health, 75.0), "A close forward slash deals 25 damage")
	await _steps(14)
	_check(_near(enemy.health, 75.0), "A slash cannot damage the same target again on subsequent visual frames")
	_check(player.request_card("slash"), "A second played slash is accepted")
	await _steps(12)
	_check(_near(enemy.health, 50.0), "A separate slash can hit the same target again")
	# A target entering a still-visible swing is checked after the opening instant.
	await _reset_pair(false, PLAYER_START, Vector3(0, 0, -3.0))
	player.request_card("slash")
	await _steps(2)
	_check(_near(enemy.health, 100.0), "Slash opening cannot hit an out-of-range target")
	enemy.global_position = Vector3(0, 0, -0.6)
	await _steps(2)
	_check(_near(enemy.health, 75.0), "A target entering an active slash can be hit")
	await _steps(12)
	_check(_near(enemy.health, 75.0), "Late-entry slash still damages each target only once")


func _test_hit_geometry() -> void:
	var misses: Array[Dictionary] = [
		{"position": Vector3(0, 0, -3.0), "description": "A distant opponent is outside slash reach"},
		{"position": Vector3(0, 0, 2.6), "description": "An opponent behind the player is outside the slash arc"},
		{"position": Vector3(1.6, 0, 1.0), "description": "An opponent directly to the side is outside the slash arc"},
		{"position": Vector3(0, 4.0, -0.6), "description": "A high airborne opponent is outside the grounded slash height"}
	]
	for item in misses:
		await _reset_pair(false, PLAYER_START, item["position"])
		player.request_card("slash")
		await _steps(12)
		_check(_near(enemy.health, 100.0), item["description"])
	await _reset_pair(false, Vector3(0, 4.0, 1.0), Vector3(0, 0, -0.6))
	player.gravity_scale = 0.0
	player.velocity = Vector3.ZERO
	player.request_card("slash")
	await _steps(12)
	_check(_near(enemy.health, 100.0), "An airborne player cannot slash a target far below")
	await _reset_pair(false, PLAYER_START, Vector3(0, 0, -0.6))
	var wall := StaticBody3D.new()
	wall.name = "CombatOcclusionTestWall"
	wall.position = Vector3(0.0, 1.1, 0.2)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(3.0, 2.2, 0.16)
	collision.shape = shape
	wall.add_child(collision)
	scene.add_child(wall)
	await _steps(2)
	player.request_card("slash")
	await _steps(12)
	_check(_near(enemy.health, 100.0), "A solid wall blocks player melee damage")
	wall.queue_free()
	await _steps(2)
	player.request_card("slash")
	await _steps(12)
	_check(_near(enemy.health, 75.0), "The same target is hittable after the blocking wall is removed")


func _test_dash_damage() -> void:
	await _reset_pair(false, PLAYER_START, Vector3(0, 0, -2.2))
	_check(player.request_card("dash_slash"), "Dash slash starts normally near an enemy")
	await _steps(5)
	_check(player.is_dashing and player.slash_time_left <= 0.0 and _near(enemy.health, 100.0), "The dash approach does not deal damage before its slash begins")
	await _steps(20)
	_check(_near(enemy.health, 55.0), "Dash slash deals exactly 45 damage over the entire action")


func _test_card_combos() -> void:
	# Attacks overlap the short roll without cancelling its movement or immunity.
	await _reset_pair(false, PLAYER_START, Vector3(0, 0, -0.6))
	var normal_slash_cost: float = player.slash_cost
	_check(player.request_card("slash"), "A normal slash still starts immediately")
	var normal_slash_duration: float = player.slash_time_left
	_check(normal_slash_duration > 0.0, "A normal slash keeps a visible attack window")
	await _reset_pair(false, PLAYER_START, Vector3(0, 0, -0.6))
	var roll_energy_before: float = player.energy
	_check(player.request_card("roll"), "A roll starts normally before a combo attack")
	var energy_after_roll: float = player.energy
	_check(player.request_card("slash"), "Slash starts immediately during an active roll")
	_check(_near(energy_after_roll - player.energy, normal_slash_cost), "A concurrent slash spends exactly its own card cost")
	_check(_near(roll_energy_before - player.energy, player.roll_cost + player.slash_cost), "Roll plus slash spend only the two card costs")
	_check(player.is_rolling and player.slash_time_left > 0.0, "Rolling movement and slash attack coexist")
	_check(player.slash_time_left < normal_slash_duration, "Roll attack uses a shortened attack window")
	_check(_near(enemy.health, 75.0), "Roll slash hits immediately rather than waiting for the roll to end")
	_check(not player.take_damage(20.0) and _near(player.health, player.max_health), "Roll slash keeps roll invulnerability")
	var energy_after_attack: float = player.energy
	_check(not player.request_card("slash") and _near(player.energy, energy_after_attack), "Only one attack can be inserted in the same roll")
	await _steps(30)
	_check(not player.is_rolling and player.slash_time_left <= 0.0, "The concurrent combo expires without a delayed replay")
	_check(_near(enemy.health, 75.0), "One roll slash damages the same target only once")

	# The reverse order is also cancellable: roll begins during the short slash
	# window, without an additional windup or an extra energy charge.
	await _reset_pair(false, PLAYER_START, Vector3(0, 0, -0.6))
	var slash_energy_before: float = player.energy
	_check(player.request_card("slash"), "Slash-to-roll sequence starts with an ordinary slash")
	var slash_active_before_roll: float = player.slash_time_left
	_check(player.request_card("roll"), "Roll can follow an active slash without a new windup")
	_check(player.is_rolling, "Slash-to-roll enters the roll immediately")
	_check(_near(slash_energy_before - player.energy, player.slash_cost + player.roll_cost), "Slash-to-roll spends exactly both card costs")
	_check(not player.take_damage(20.0) and _near(player.health, player.max_health), "Slash-to-roll still grants roll invulnerability")
	await _steps(30)
	_check(not player.is_rolling and player.slash_time_left <= 0.0, "Slash-to-roll does not leave a stale attack after the roll")
	_check(slash_active_before_roll > 0.0, "The preceding slash had a real active window")

	# Both layers of the concurrent combo freeze during pause and clear on reset.
	await _reset_pair(false, PLAYER_START, Vector3(0, 0, -2.5))
	_check(player.request_card("roll") and player.request_card("slash"), "A second roll-to-slash combo can be armed")
	var roll_time_before_pause: float = player.roll_time_left
	var slash_time_before_pause: float = player.slash_time_left
	scene.toggle_pause()
	await _steps(12)
	_check(_near(player.roll_time_left, roll_time_before_pause) and _near(player.slash_time_left, slash_time_before_pause), "Pause freezes both rolling and its concurrent slash")
	_check(not player.request_card("slash"), "Pause rejects another combo card")
	scene.toggle_pause()
	await _steps(30)
	_check(not player.is_rolling and player.slash_time_left <= 0.0, "A paused combo resumes once and then expires cleanly")
	await _reset_pair(false, PLAYER_START, Vector3(0, 0, -2.5))
	_check(player.request_card("roll") and player.request_card("slash"), "A concurrent combo can be cancelled by reset")
	player.reset_player()
	await _steps(2)
	_check(not player.is_rolling and player.slash_time_left <= 0.0, "Reset clears both layers of the combo")
	_check(not player.is_dead and player.request_card("slash"), "A reset player can start a fresh ordinary slash")

	# Playing through Deck uses exactly one physical card per action. Empty hand
	# slots remain empty until their normal delayed refill, with every card still
	# present in one of the three zones.
	var deck: Node = scene.get("deck") as Node
	var roll_slot := -1
	var slash_slot := -1
	for seed in range(1, 80):
		deck.reset_deck(seed)
		var current_hand: Array = deck.get("hand")
		roll_slot = -1
		slash_slot = -1
		for slot in range(current_hand.size()):
			if current_hand[slot].is_empty():
				continue
			if str(current_hand[slot]["kind"]) == "roll" and roll_slot < 0:
				roll_slot = slot
			if str(current_hand[slot]["kind"]) == "slash" and slash_slot < 0:
				slash_slot = slot
		if roll_slot >= 0 and slash_slot >= 0:
			break
	_check(roll_slot >= 0 and slash_slot >= 0, "The physical deck can expose a roll and slash for combo testing")
	if roll_slot >= 0 and slash_slot >= 0:
		await _reset_pair(false, PLAYER_START, Vector3(0, 0, -2.5))
		deck.reset_deck(17)
		var chosen_hand: Array = deck.get("hand")
		roll_slot = -1
		slash_slot = -1
		for slot in range(chosen_hand.size()):
			if chosen_hand[slot].is_empty():
				continue
			if str(chosen_hand[slot]["kind"]) == "roll" and roll_slot < 0:
				roll_slot = slot
			if str(chosen_hand[slot]["kind"]) == "slash" and slash_slot < 0:
				slash_slot = slot
		if roll_slot >= 0 and slash_slot >= 0:
			_check(deck.play_slot(roll_slot), "Deck accepts the physical roll card")
			_check(deck.play_slot(slash_slot), "Deck accepts the physical slash card during the roll")
			var all_cards: Array[Dictionary] = deck.get_card_snapshot(&"all")
			var hand_cards: Array = deck.get("hand")
			var draw_cards: Array[Dictionary] = deck.get_card_snapshot(&"draw")
			var discard_cards: Array[Dictionary] = deck.get_card_snapshot(&"discard")
			var nonempty_hand_cards := 0
			for card in hand_cards:
				if not card.is_empty():
					nonempty_hand_cards += 1
			_check(all_cards.size() == 10 and nonempty_hand_cards == 2 and draw_cards.size() == 6 and discard_cards.size() == 2, "Combo cards move one-for-one between hand, draw, and discard piles")
			_check(deck.play_slot(roll_slot) == false, "An empty hand slot cannot replay a spent roll card")
			_check(deck.play_slot(slash_slot) == false, "An empty hand slot cannot replay a spent slash card")


func _test_telegraph_and_single_hit() -> void:
	await _reset_pair(true)
	_check(await _wait_state(&"windup", 90), "An opponent in melee range visibly begins a windup")
	var start_frame := Engine.get_physics_frames()
	var harmless_windup := true
	var ticks := 0
	while enemy.state == &"windup" and ticks < 80:
		harmless_windup = harmless_windup and _near(player.health, 100.0)
		await _steps(1)
		ticks += 1
	var elapsed := float(Engine.get_physics_frames() - start_frame) / float(Engine.physics_ticks_per_second)
	_check(harmless_windup, "The entire raised-weapon reaction window is harmless")
	_check(elapsed >= 0.25 and elapsed <= 0.38, "Windup gives approximately 0.3 seconds to react")
	_check(await _wait_state(&"recovery", 30), "The swing finishes and enters recovery")
	_check(_near(player.health, 80.0), "Standing in the attack loses exactly 20 health, not damage every active frame")
	var health_after: float = player.health
	await _steps(20)
	_check(enemy.state == &"recovery" and _near(player.health, health_after), "Recovery cannot immediately deal another hit")


func _test_walking_cannot_evade() -> void:
	var cases: Array[Dictionary] = [
		{"keys": ["move_up"], "name": "walking forward"},
		{"keys": ["move_down"], "name": "walking backward"},
		{"keys": ["move_left"], "name": "strafing left"},
		{"keys": ["move_right"], "name": "strafing right"},
		{"keys": ["move_left", "move_up"], "name": "walking diagonally forward-left"},
		{"keys": ["move_right", "move_up"], "name": "walking diagonally forward-right"},
		{"keys": ["move_left", "move_down"], "name": "walking diagonally backward-left"},
		{"keys": ["move_right", "move_down"], "name": "walking diagonally backward-right"}
	]
	for item in cases:
		await _reset_pair(false)
		# Turn fully before combat starts: this checks full ordinary speed, not
		# just the temporary braking that occurs when turning away from a foe.
		for action in item["keys"]:
			Input.action_press(action)
		await _steps(32)
		player.global_position = PLAYER_START
		enemy.global_position = ENEMY_START
		enemy.combat_enabled = true
		var did_windup := await _wait_state(&"windup", 90)
		var did_recover := await _wait_state(&"recovery", 100)
		_check(did_windup and did_recover and _near(player.health, 80.0), "%s at full ordinary speed cannot evade a committed melee attack" % item["name"])
		_release_all()


func _test_roll_timing() -> void:
	await _reset_pair(true)
	_check(await _wait_state(&"windup", 90), "The roll timing trial begins with a real telegraph")
	await _wait_windup_remaining(0.14)
	Input.action_press("move_down")
	_check(player.request_card("roll"), "A roll can be played in the final part of the telegraph")
	_check(not player.take_damage(20.0) and _near(player.health, 100.0), "An active roll rejects incoming damage")
	_check(await _wait_state(&"recovery", 60), "The telegraphed slash completes after a timed roll")
	_check(_near(player.health, 100.0), "A correctly timed retreat roll avoids the whole enemy swing")
	_release_all()
	var roll_directions: Array[Dictionary] = [
		{"key": "move_left", "name": "left"},
		{"key": "move_right", "name": "right"},
		{"key": "move_up", "name": "forward"}
	]
	for item in roll_directions:
		await _reset_pair(true)
		await _wait_state(&"windup", 90)
		await _wait_windup_remaining(0.14)
		Input.action_press(item["key"])
		_check(player.request_card("roll"), "A timely %s roll starts in the final telegraph window" % item["name"])
		# Release movement so the full swing is tested at the roll's actual end
		# position, including the active frames after invulnerability expires.
		_release_all()
		var completed_swing := await _wait_state(&"recovery", 60)
		_check(completed_swing and not player.is_rolling and _near(player.health, 100.0), "A timely %s roll avoids the whole swing, including its trailing active frames" % item["name"])
	await _reset_pair(true)
	await _wait_state(&"windup", 90)
	Input.action_press("move_down")
	_check(player.request_card("roll"), "An early roll can also be started")
	# Releasing the key does not interrupt the locked roll; it stops subsequent walking.
	_release_all()
	await _steps(16)
	_check(not player.is_rolling and enemy.state == &"windup", "An immediately spent roll expires before the enemy finishes raising its weapon")
	_check(await _wait_state(&"recovery", 80), "The enemy continues its committed attack after the early roll")
	_check(player.health <= 100.0 and player.health >= 80.0, "Rolling too early ends its invulnerability before the committed swing")


func _test_recovery_counterattack() -> void:
	await _reset_pair(true)
	await _wait_state(&"windup", 90)
	await _wait_state(&"recovery", 100)
	var health_before: float = player.health
	_check(player.request_card("slash"), "The player can counterattack while the enemy recovers")
	await _steps(12)
	_check(_near(enemy.health, 75.0), "A counterattack actually removes enemy health")
	_check(enemy.state == &"recovery" and _near(player.health, health_before), "The recovery opening permits a counter without a second enemy strike")


func _test_pause() -> void:
	await _reset_pair(true)
	await _wait_state(&"windup", 90)
	await _wait_windup_remaining(0.35)
	var timer_before: float = enemy.state_time_left
	var location_before := enemy.global_position
	var player_health_before: float = player.health
	scene.toggle_pause()
	Input.action_press("move_down")
	await _steps(20)
	_check(_near(enemy.state_time_left, timer_before) and enemy.state == &"windup", "Pause freezes the enemy's telegraph timer")
	_check(enemy.global_position.is_equal_approx(location_before) and _near(player.health, player_health_before), "Pause freezes pursuit and combat damage")
	_check(not player.take_damage(20.0) and not enemy.take_damage(25.0), "Paused combatants reject direct damage requests")
	_check(not player.request_card("slash") and not player.request_jump() and not player.activate_cybernetic(), "Pause blocks every player combat action")
	_release_all()
	scene.toggle_pause()
	_check(await _wait_state(&"recovery", 90), "Resuming completes the suspended enemy attack")
	_check(_near(player.health, 80.0), "A resumed swing still deals its damage only once")


func _test_death_and_restart() -> void:
	await _reset_pair(false, PLAYER_START, Vector3(0, 0, -0.6))
	for _attack in range(4):
		player.request_card("slash")
		await _steps(12)
	_check(enemy.is_dead and _near(enemy.health, 0.0) and enemy.state == &"dead", "Four ordinary slashes kill a 100-health enemy")
	_check(not enemy.take_damage(25.0) and _near(enemy.health, 0.0), "A defeated enemy cannot take repeated or negative health damage")
	enemy.combat_enabled = true
	await _steps(120)
	_check(enemy.is_dead and enemy.state == &"dead" and _near(player.health, 100.0), "A defeated enemy cannot resume pursuit or attack")
	await _reset_pair(false)
	_check(player.take_damage(100.0) and player.is_dead and _near(player.health, 0.0), "Player lethal damage enters the defeated state")
	var death_position := player.global_position
	var energy_before: float = player.energy
	_check(not player.request_card("slash") and not player.request_card("roll") and not player.request_card("dash_slash"), "A defeated player cannot play any combat card")
	_check(not player.request_jump() and not player.activate_cybernetic() and not player.take_damage(20.0), "A defeated player cannot jump, activate an implant, or lose health again")
	Input.action_press("move_right")
	Input.action_press("hand_1")
	Input.action_press("jump")
	Input.action_press("cybernetic_boost")
	await _steps(20)
	_check(Vector2(player.global_position.x - death_position.x, player.global_position.z - death_position.z).length() < 0.01, "Ordinary movement input cannot move a defeated player")
	_check(not player.is_rolling and not player.is_dashing and player.slash_time_left <= 0.0 and not player.is_cybernetic_active and player.energy >= energy_before, "Physical action inputs cannot execute or spend energy after defeat")
	_release_all()
	enemy.take_damage(100.0)
	scene.restart()
	enemy.combat_enabled = false
	await _steps(2)
	_check(not player.is_dead and _near(player.health, 100.0), "Restart revives the player at full health")
	_check(not enemy.is_dead and _near(enemy.health, 100.0) and enemy.state != &"dead", "Restart revives the enemy at full health")
	_check(player.global_position.distance_to(Vector3(0, 0, 2)) < 0.1 and enemy.global_position.distance_to(Vector3(0, 0, -2)) < 0.1, "Restart restores both combatants to their spawn points")
	_check(player.request_card("slash"), "Restart restores player combat input")


func _reset_pair(enable_combat: bool, player_position: Vector3 = PLAYER_START, enemy_position: Vector3 = ENEMY_START) -> void:
	_release_all()
	if scene.paused:
		scene.toggle_pause()
	enemy.combat_enabled = false
	player.reset_player()
	enemy.reset_enemy()
	scene.camera_yaw = 0.0
	player.movement_yaw = 0.0
	player.global_position = player_position
	enemy.global_position = enemy_position
	player.velocity = Vector3.ZERO
	enemy.velocity = Vector3.ZERO
	await _steps(2)
	enemy.combat_enabled = enable_combat


func _wait_state(expected: StringName, maximum_frames: int) -> bool:
	for _index in range(maximum_frames):
		if enemy.state == expected:
			return true
		await _steps(1)
	return enemy.state == expected


func _wait_windup_remaining(seconds: float) -> void:
	for _index in range(90):
		if enemy.state != &"windup" or enemy.state_time_left <= seconds:
			return
		await _steps(1)


func _steps(count: int) -> void:
	for _index in range(count):
		await physics_frame
		await process_frame


func _release_all() -> void:
	for action in ACTIONS:
		Input.action_release(action)


func _near(a: float, b: float, tolerance: float = 0.01) -> bool:
	return absf(a - b) <= tolerance


func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
		print("PASS: " + description)
	else:
		failed += 1
		push_error("FAIL: " + description)
