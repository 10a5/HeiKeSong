extends SceneTree
## Godot --headless --path . --fixed-fps 60 --script tests/test_erosion_flow.gd
## Integration coverage for the first-floor erosion clock and Boss hand-off.

const TEST_SEED := 7331
const MAX_WAIT_FRAMES := 420

var floor_scene: Node3D
var player: CharacterBody3D
var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("Testing first-floor erosion and Boss flow...")
	floor_scene = load("res://floor_one.tscn").instantiate() as Node3D
	root.add_child(floor_scene)
	await _steps(4)
	await _new_floor(TEST_SEED)
	await _test_activity_clock_and_encounter_gate()
	await _test_facility_entries()
	await _test_boss_transition_and_intro()
	await _test_boss_r_retry()
	_cleanup()
	print("EROSION FLOW RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_activity_clock_and_encounter_gate() -> void:
	var erosion: Node = floor_scene.erosion
	erosion.reset()
	erosion.set_combat_active(false)
	erosion.process_activity(0.99, true, false)
	_check(erosion.value == 0, "Movement does not charge before one complete second")
	erosion.process_activity(0.01, true, false)
	_check(erosion.value == 1, "One second of movement charges one erosion point")
	erosion.reset()
	erosion.process_activity(2.99, false, false)
	_check(erosion.value == 0, "Standing still waits for three complete seconds")
	erosion.process_activity(0.01, false, false)
	_check(erosion.value == 1, "Three seconds of stillness charge one erosion point")
	erosion.reset()
	erosion.process_activity(0.90, true, false)
	erosion.set_combat_active(true)
	erosion.process_activity(2.0, true, false)
	_check(erosion.value == 0, "An active encounter freezes movement erosion")
	erosion.set_combat_active(false)
	erosion.process_activity(0.10, true, false)
	_check(erosion.value == 1, "Leaving an encounter resumes the saved movement remainder")

	var encounter: Node = floor_scene.encounters[0]
	var old_state: StringName = encounter.state
	encounter.state = &"active"
	_check(floor_scene._is_in_combat(), "The first-floor combat gate sees an active street encounter")
	encounter.state = &"dormant"
	_check(not floor_scene._is_in_combat(), "The combat gate clears after the street encounter is left")
	encounter.state = old_state


func _test_facility_entries() -> void:
	await _new_floor(TEST_SEED)
	var erosion: Node = floor_scene.erosion
	var medical: Node = _service_of_kind("medical")
	var factory: Node = _service_of_kind("factory")
	var shop: Node = _service_of_kind("shop")
	var police: Node = _service_of_kind("police")
	_check(medical != null and factory != null and shop != null and police != null, "The generated floor contains all four facility types")
	if medical == null or factory == null or shop == null or police == null:
		return

	# A failed medical interaction (full health) must not charge entry.
	_move_to_service(medical)
	player.health = player.max_health
	var before: int = int(erosion.value)
	_check(not medical.interact() and erosion.value == before, "A failed full-health medical interaction does not charge erosion")
	player.health = 35.0
	_check(medical.interact() and erosion.value == before + 10, "A successful medical entry charges exactly ten erosion")
	_check(not medical.interact() and erosion.value == before + 10, "A used medical station cannot charge a second time")

	# Police is a useful control facility: it may grant cards/credits but never
	# contributes to the erosion meter.
	_move_to_service(police)
	var police_before: int = int(erosion.value)
	_check(police.interact() and erosion.value == police_before, "公安局 interaction does not charge erosion")

	# Factory charge happens only after its reward modal successfully opens.
	_move_to_service(factory)
	var factory_before: int = int(erosion.value)
	var factory_opened := bool(factory.interact())
	_check(factory_opened and erosion.value == factory_before + 10, "A successful factory reward entry charges ten erosion")
	await _close_reward_modal()

	# A distant shop request is rejected. A nearby shop can be opened repeatedly,
	# and each actual opening is one facility entry.
	player.global_position = Vector3.ZERO
	var shop_before: int = int(erosion.value)
	_check(not shop.interact() and erosion.value == shop_before, "A distant shop interaction does not charge erosion")
	_move_to_service(shop)
	_check(shop.interact() and erosion.value == shop_before + 10, "A successful shop opening charges ten erosion")
	if is_instance_valid(floor_scene.shop_system):
		floor_scene.shop_system.close()
	await _steps(2)
	_move_to_service(shop)
	_check(shop.interact() and erosion.value == shop_before + 20, "A shop can be revisited and charges ten erosion per opening")
	if is_instance_valid(floor_scene.shop_system):
		floor_scene.shop_system.close()


func _test_boss_transition_and_intro() -> void:
	await _new_floor(TEST_SEED)
	var erosion: Node = floor_scene.erosion
	var deck: Node = floor_scene.deck
	var inventory: Node = floor_scene.inventory
	player.health = 73.0
	# Use a full battery so the player's ordinary regeneration cannot obscure
	# the state-preservation assertion while the Matrix cover is resolving.
	player.energy = player.max_energy
	var health_before: float = player.health
	var energy_before: float = player.energy
	var hand_before: Array = player_hand_snapshot(deck)
	var cards_before: int = int(deck.total_cards)
	var implants_before: int = inventory.get_items().size()

	erosion.reset(99)
	erosion.set_combat_active(false)
	erosion.process_activity(1.0, true, false)
	_check(erosion.value == 100, "Actual movement processing takes erosion from 99 to the threshold")
	_check(bool(floor_scene.get("_boss_transitioning")) or bool(floor_scene.get("_boss_pending")), "Reaching the threshold requests a Boss transition")

	var ready := await _wait_until(func() -> bool:
		return bool(floor_scene.get("_boss_active")) and is_instance_valid(floor_scene.boss_target)
	, MAX_WAIT_FRAMES)
	_check(ready, "Matrix transition finishes with a live Boss arena")
	if not ready:
		return

	_check(is_instance_valid(floor_scene.boss_arena) and not floor_scene.city_map.visible, "Boss hand-off hides the generated city and mounts the duel arena")
	_check(not player.bounds_enabled, "Boss hand-off keeps the player's movement free of a rectangular air wall")
	_check(not floor_scene.boss_target.bounds_enabled, "Boss hand-off keeps the mirror Boss free of a rectangular air wall")
	_check(is_equal_approx(player.health, health_before) and is_equal_approx(player.energy, energy_before), "Boss hand-off preserves player health and energy")
	_check(player_hand_snapshot(deck) == hand_before and int(deck.total_cards) == cards_before and inventory.get_items().size() == implants_before, "Boss hand-off preserves the current deck and implants")

	var boss: Node = floor_scene.boss_target
	var entrance_left := float(boss.entrance_time_left)
	_check(boss.is_entering and entrance_left > 0.0, "The mirror Boss starts with its protected three-second entrance")
	var health_during_intro := float(boss.health)
	_check(not boss.take_damage(100.0) and is_equal_approx(float(boss.health), health_during_intro), "The Boss cannot be damaged during its entrance shield")

	# Pausing the world must freeze the intro clock; then a bounded wait lets the
	# intro complete without hanging the headless test if a scene is broken.
	floor_scene.paused = true
	paused = true
	await _steps(20)
	_check(is_equal_approx(float(boss.entrance_time_left), entrance_left), "A paused world freezes the Boss entrance timer")
	floor_scene.paused = false
	paused = false
	var intro_done := await _wait_until(func() -> bool: return not boss.is_entering, 240)
	_check(intro_done, "The Boss entrance shield ends after its bounded three-second window")

	# Boss erosion drains while combat is active and remains a stable zero; the
	# floor does not silently end the duel when the timer is depleted.
	erosion.value = 2
	floor_scene._physics_process(2.0)
	_check(erosion.value == 0 and bool(floor_scene.get("_boss_active")), "Boss erosion drains to zero without ending the active duel")


func _test_boss_r_retry() -> void:
	# R must interrupt a covered Matrix transition and restore exploration state.
	await _new_floor(TEST_SEED)
	var erosion: Node = floor_scene.erosion
	erosion.reset(99)
	erosion.process_activity(1.0, true, false)
	var event := _key_event(KEY_R)
	Input.parse_input_event(event)
	await _steps(4)
	_check(erosion.value == 0 and not bool(floor_scene.get("_boss_active")) and not bool(floor_scene.get("_boss_transitioning")), "R interrupts a Boss transition and resets erosion")
	_check(floor_scene.boss_arena == null and floor_scene.city_map.visible and not player.bounds_enabled, "R during transition restores the first-floor city and free movement")

	# Enter the duel again and use the same input while the Boss is live.
	erosion.reset(99)
	erosion.process_activity(1.0, true, false)
	var entered := await _wait_until(func() -> bool: return bool(floor_scene.get("_boss_active")), MAX_WAIT_FRAMES)
	if entered:
		Input.parse_input_event(_key_event(KEY_R))
		await _steps(5)
	_check(entered and erosion.value == 0 and not bool(floor_scene.get("_boss_active")), "R during an active Boss duel returns to a clean first-floor run")


func _new_floor(seed_value: int) -> void:
	if is_instance_valid(floor_scene):
		floor_scene.regenerate_floor(seed_value)
	await _steps(3)
	player = floor_scene.player
	# The integration test controls timing through the floor API; keep the
	# generated actors present while moving the player directly for facilities.


func _move_to_service(service: Node) -> void:
	var data: Dictionary = service.data
	player.global_position = Vector3(data.get("interaction_center", data.get("position", Vector3.ZERO)))
	player.velocity = Vector3.ZERO


func _service_of_kind(kind: String) -> Node:
	for service: Node in floor_scene.services:
		if str(service.kind) == kind:
			return service
	return null


func _close_reward_modal() -> void:
	var reward: Node = floor_scene.reward_flow
	if is_instance_valid(reward) and reward.is_open():
		reward.skip()
		await _steps(4)


func _wait_until(predicate: Callable, limit: int) -> bool:
	for _i in range(limit):
		if bool(predicate.call()):
			return true
		await _steps(1)
	return bool(predicate.call())


func _steps(count: int) -> void:
	for _i in range(count):
		await physics_frame
		await process_frame


func _inside_rect(position: Vector3, rect: Rect2) -> bool:
	return rect.has_point(Vector2(position.x, position.z))


func player_hand_snapshot(deck: Node) -> Array:
	var result: Array = []
	for card in deck.hand:
		result.append(str(card.get("id", "")))
	return result


func _key_event(code: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = true
	return event


func _cleanup() -> void:
	if is_instance_valid(floor_scene):
		paused = false
		floor_scene.paused = false
		floor_scene.queue_free()


func _check(condition: bool, message: String) -> void:
	if condition:
		passed += 1
		print("PASS: " + message)
	else:
		failed += 1
		push_error("FAIL: " + message)
