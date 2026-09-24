extends SceneTree
## End-to-end check of the onboarding range: spawn setup, the five-step
## machine, the frozen lesson hand, and the clean exit to the first floor.
## Godot --headless --path . --fixed-fps 60 --script tests/test_tutorial.gd
##
## The tutorial script inherits main.gd, so its members are reached through
## get()/set() instead of static types: a Node3D-typed variable cannot see
## inherited members, and typing the variable as the script itself would
## re-enter the scene's own class.

const TUTORIAL = preload("res://tutorial.tscn")
var scene: Node3D
var player: Node
var enemy: Node
var deck: Node
var reward_flow: Node
var passed := 0
var failed := 0
var exit_path := ""
var frames := 0
## A failed preload leaves scene null, which aborts this coroutine before quit()
## is ever reached. This budget turns that empty spin into a fast, loud failure.
const FRAME_BUDGET := 3000


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	scene = TUTORIAL.instantiate()
	root.add_child(scene)
	scene.set("exit_requested", Callable(self, "_on_exit"))
	await _steps(10)
	player = scene.get("player")
	enemy = scene.get("enemy")
	deck = scene.get("deck")
	reward_flow = scene.get("reward_flow")
	_park(Vector3(0.0, 0.0, 6.0))
	await _steps(6)

	_check(scene.get("step") == 0, "Tutorial opens on step 1 of 5")
	var terminals: Array = scene.get("unlock_terminals")
	_check(terminals.is_empty(), "Main-scene unlock terminals are removed for the lesson")
	_check(scene.get("enemy") == enemy, "The lesson foe replaced the inherited training mannequin")
	_check(enemy.name == "TutorialBoxer", "The lesson foe is the training boxer")
	_check(enemy.get_variant_kind() == &"boxer", "The lesson foe carries the street boxer variant")
	_check(enemy.display_name == "拳击手", "The lesson foe reports itself as 拳击手")
	var boxer_visual: Node3D = enemy.get("_variant_visual") as Node3D
	var boxer_animation: AnimationPlayer = enemy.get("_variant_animation") as AnimationPlayer
	_check(is_instance_valid(boxer_visual) and bool(enemy.get("_variant_model_imported")), "The boxer's imported model is live instead of the greybox mannequin")
	_check(is_instance_valid(boxer_animation), "The boxer's punch animation player was found")
	_check(not enemy.is_optically_hidden(), "The lesson boxer is not cloaked, so the drill target is readable from the first frame")
	_check(not enemy.get("_boxer_first_approach"), "The lesson boxer does not spend a concealed first approach")
	_check(is_instance_valid(enemy) and not enemy.visible and enemy.process_mode == Node.PROCESS_MODE_DISABLED, "Lesson enemy starts hidden and out of process")
	_check(is_equal_approx(enemy.max_health, 45.0) and is_equal_approx(enemy.attack_damage, 6.0), "Lesson enemy is the weakened 45 HP / 6 damage variant")
	_check(is_equal_approx(deck.refill_delay, 9999.0), "Automatic refill is parked for the whole tutorial")
	_check(scene.get_node_or_null("TutorialRoute") != null, "Greybox route with the move pad and barriers was built")
	_check(scene.get_node_or_null("TutorialHUD") != null, "Tutorial HUD canvas was created")

	# Step 1 -> 2: walk into the teal beacon.
	_park(Vector3(0.0, 0.0, 1.0))
	await _steps(10)
	_check(scene.get("step") == 1, "Walking into the teal ring advances to step 2 of 5")

	# Step 2 -> 3: a real jump at the orange ring, then land beyond the low wall.
	Input.action_press("move_left")
	await _steps(2)
	Input.action_release("move_left")
	_check(player.is_on_floor() and player.request_jump(), "Jump is available on the pad before the low wall")
	var peak: float = player.global_position.y
	var airborne: bool = false
	for _frame in range(60):
		await _steps(1)
		peak = maxf(peak, player.global_position.y)
		airborne = airborne or not player.is_on_floor()
		if player.is_on_floor() and _frame > 4:
			break
	_check(peak > 0.55 and airborne, "The jump clears the low wall's 0.72 m height")
	_check(scene.get("_jump_seen"), "Jumping registers the jump lesson as taught")
	_check(scene.get("step") == 1, "Jumping in place does not skip the jump lesson")
	_park(Vector3(0.0, 0.0, -3.5))
	await _steps(10)
	_check(scene.get("step") == 2, "Landing past the low wall advances to step 3 of 5")
	# Step 3 -> 4: playing any card teaches the hand-driven verb. The player is
	# returned to the start of the route first so the still-dormant lesson enemy
	# cannot reach them while the hand is being cycled.
	_park(Vector3(0.0, 0.0, 3.5))
	await _steps(120)
	player.energy = player.max_energy
	var played := false
	for slot in range(deck.hand_size):
		if deck.hand[slot].is_empty():
			continue
		if deck.play_slot(slot):
			played = true
			break
	_check(played, "A randomly drawn card can be played during the card lesson")
	await _steps(6)
	_check(scene.get("step") == 3, "Playing a card advances to step 4 of 5")
	# A movement card played in step 3 leaves the player mid-action; the combat
	# drill must wait for that roll to finish before its own roll can be played.
	for _frame in range(120):
		if not player.is_action_locked():
			break
		await _steps(1)
	_check(not player.is_action_locked(), "The combat drill begins with the player free to act")

	# Step 4: the lesson hand holds exactly one roll, and the enemy waits.
	var roll_slots := 0
	var empty_slots := 0
	for slot in range(deck.hand_size):
		if deck.hand[slot].is_empty():
			empty_slots += 1
		elif str(deck.hand[slot]["kind"]) == "roll":
			roll_slots += 1
	_check(roll_slots == 1 and empty_slots == deck.hand_size - 1, "Roll lesson hand is exactly one 【roll】 with empty, never-refilling slots")
	_check(is_equal_approx(player.energy, player.max_energy), "Lesson hand refills energy so the taught verb is castable")
	_check(enemy.visible and enemy.process_mode == Node.PROCESS_MODE_INHERIT, "Lesson enemy appears for the combat drill")
	_check(not enemy.combat_enabled, "Lesson enemy holds its attack during the 3 second read-the-text buffer")
	_check(scene.get("_combat_intro_left") > 0.0, "Combat buffer countdown is running")

	# The roll must be playable and must be what releases the combat drill.
	var roll_slot := -1
	for slot in range(deck.hand_size):
		if not deck.hand[slot].is_empty() and str(deck.hand[slot]["kind"]) == "roll":
			roll_slot = slot
	_check(roll_slot >= 0 and deck.play_slot(roll_slot), "【roll】 is playable from the locked lesson hand")
	await _steps(6)
	_check(scene.get("step") == 4, "A successful roll advances to the final step of 5")

	# Step 5 swaps in the attack hand. It is the last scripted hand, so the deck
	# must be back on its normal rules the moment it appears: the player is in a
	# live fight there and a board that spent its punches has to be able to draw
	# more. Read the composition before touching any card.
	var slash_slots := 0
	var roll_left := 0
	for slot in range(deck.hand_size):
		if deck.hand[slot].is_empty():
			continue
		match str(deck.hand[slot]["kind"]):
			"slash": slash_slots += 1
			"roll": roll_left += 1
	_check(slash_slots == 3 and roll_left == 1, "Attack lesson hand is 3 【slash】 plus 1 【roll】")
	_check(is_equal_approx(deck.refill_delay, 1.0), "Normal refill returns with the attack hand, not one step later")
	var live_slot := -1
	for slot in range(deck.hand_size):
		if not deck.hand[slot].is_empty():
			live_slot = slot
			break
	_check(live_slot >= 0 and deck.play_slot(live_slot), "A card from the attack hand can be played")
	await _steps(2)
	_check(deck.hand[live_slot].is_empty(), "Playing the card empties its slot")
	var refilled := false
	for _frame in range(120):
		await _steps(1)
		if not deck.hand[live_slot].is_empty():
			refilled = true
			break
	_check(refilled, "The emptied slot draws a replacement instead of sitting at the frozen delay")
	# The other resource the player spends on step 5 is energy, so prove that
	# clock is running too rather than quietly parked like the refill was.
	player.energy = 0.0
	var regained := 0.0
	for _frame in range(90):
		await _steps(1)
		regained = maxf(regained, float(player.energy))
	_check(regained > 0.0, "Energy keeps regenerating on the attack hand instead of stalling")
	player.energy = player.max_energy

	# The buffer belongs to the enemy, not to the step: releasing it here proves a
	# player who rolls inside the 3 seconds still ends up with an attacking foe.
	# The drill pad keeps the player safe while the remaining buffer burns down.
	scene.set("_combat_intro_left", 0.05)
	await _steps(8)
	_check(enemy.combat_enabled, "Combat buffer releases the enemy even after a fast roll")
	_check(not enemy.is_dead, "The lesson enemy survives the roll lesson")

	# The drill must actually be a boxing exchange: the foe telegraphs with its
	# own imported punch clip, and one resolved swing must stay dodgeable. The
	# roll is only 0.32 s long, so it has to start after the telegraph appears;
	# the damage delta also proves the lesson weakened the street number.
	_park(Vector3(0.0, 0.0, -3.4))
	var punched := false
	var clip := ""
	for _frame in range(600):
		await _steps(1)
		clip = str(boxer_animation.current_animation)
		if clip.begins_with("box_0"):
			punched = true
			break
	_check(punched, "The boxer telegraphs with its own punch animation instead of the mannequin clips")
	var health_before: float = player.get("health")
	player.energy = player.max_energy
	_check(player.request_card("roll"), "The player can answer the boxer's telegraph with a roll")
	for _frame in range(50):
		await _steps(1)
		if enemy.get("_hit_this_swing"):
			break
	var strike_damage: float = health_before - float(player.get("health"))
	_check(strike_damage <= 0.0 or is_equal_approx(strike_damage, 6.0), "One boxer swing resolves as a dodge or as the weakened 6 damage, never the street 12")

	# Step 6 marks the lesson finished; the refill rules were already restored
	# when the attack hand arrived.
	enemy.spawn_position = Vector3(0.0, 0.0, -3.2)
	enemy.reset_enemy()
	enemy.combat_enabled = false
	_park(Vector3(0.0, 0.0, -5.2))
	await _steps(6)
	_check(not player.is_dead and player.get("health") > 0.0, "The player survives the combat drill")

	var rewards_before := _reward_panel_visible()
	enemy.take_damage(enemy.health + 1.0)
	await _steps(12)
	_check(scene.get("step") == 5 and scene.get("_finished"), "Defeating the lesson enemy completes the tutorial")
	_check(is_equal_approx(deck.refill_delay, 1.0), "Refill rules are still normal after the lesson ends")
	var rewards_after := _reward_panel_visible()
	_check(not rewards_after and rewards_after == rewards_before, "Killing the lesson enemy never opens the roguelike reward panel")

	scene.call("_skip_to_first_floor")
	await _steps(2)
	_check(exit_path == "res://floor_one.tscn", "Skip button exits to the first floor scene")

	# The finish button must reach the same place. A finished lesson is re-entered
	# from a clean step 4 so the exit path is exercised through the real flow.
	exit_path = ""
	scene.set("_finished", false)
	scene.call("_show_step", 4)
	enemy.reset_enemy()
	enemy.take_damage(enemy.health + 1.0)
	await _steps(12)
	_check(scene.get("step") == 5, "A second clear still reaches the finished step")
	scene.call("_skip_to_first_floor")
	await _steps(2)
	_check(exit_path == "res://floor_one.tscn", "Finish button exits to the first floor scene")

	print("TUTORIAL RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _park(location: Vector3) -> void:
	player.spawn_position = location
	player.reset_player()


## Captures the tutorial's exit target instead of switching this test's tree.
func _on_exit(path: String) -> void:
	exit_path = path


func _reward_panel_visible() -> bool:
	if not is_instance_valid(reward_flow):
		return false
	var panel: Variant = reward_flow.get("panel")
	return is_instance_valid(panel) and panel.visible


func _steps(count: int) -> void:
	for _frame in range(count):
		frames += 1
		if frames > FRAME_BUDGET:
			push_error("FAIL: tutorial suite exceeded its %d frame budget" % FRAME_BUDGET)
			print("TUTORIAL RESULT: %d passed, %d failed (aborted)" % [passed, failed + 1])
			quit(1)
			return
		await physics_frame
		await process_frame


func _check(condition: bool, label: String) -> void:
	if condition:
		passed += 1
		print("PASS: ", label)
	else:
		failed += 1
		push_error("FAIL: %s" % label)
