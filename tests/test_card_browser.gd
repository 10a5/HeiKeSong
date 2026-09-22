extends SceneTree
## Godot --headless --path . --fixed-fps 60 --script tests/test_card_browser.gd
## Exercise the real HUD, modal input routing, and physical card identities.

const ACTIONS: Array[String] = ["move_left", "move_right", "move_up", "move_down", "hand_1", "hand_2", "hand_3", "hand_4", "cybernetic_boost", "jump"]
const DECK_BUTTON := Vector2(64, 358)
const DRAW_BUTTON := Vector2(50, 269)
const DISCARD_BUTTON := Vector2(910, 269)

var scene: Node3D
var player: CharacterBody3D
var enemy: CharacterBody3D
var deck: Node
var hud: Control
var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("Testing the deck and pile browser...")
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
	deck = scene.get("deck") as Node
	hud = scene.get("hud") as Control
	enemy.combat_enabled = false
	await _steps(2)
	await _test_snapshots()
	await _test_real_hud_entrances()
	await _test_play_refill_and_recycle()
	await _test_modal_freeze()
	await _test_modal_input_isolation()
	await _test_pause_and_reset()
	_release_all()
	paused = false
	scene.queue_free()
	await process_frame
	print("CARD BROWSER RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_snapshots() -> void:
	await _reset()
	var initial: Dictionary = _deck_state()
	var all: Array = deck.get_card_snapshot(&"all")
	var draw: Array = deck.get_card_snapshot(&"draw")
	var discard: Array = deck.get_card_snapshot(&"discard")
	_check(all.size() == 10 and _unique_ids(all).size() == 10, "The complete deck includes ten distinct physical cards")
	_check(_kind_count(all, "slash") == 4 and _kind_count(all, "roll") == 3 and _kind_count(all, "dash_slash") == 3, "Repeated action kinds retain all four/three/three card copies")
	_check(draw.size() == 6 and _ids(draw) == _ids(deck.draw_pile), "Draw snapshot contains exactly the six undrawn cards")
	_check(discard.is_empty(), "An initially empty discard pile has no invented cards")
	_check(_zone_count(all, &"draw") == 6 and _zone_count(all, &"hand") == 4 and _zone_count(all, &"discard") == 0, "The complete snapshot reports each card's actual zone")
	var hand_slots_correct := true
	for card in all:
		if card["zone"] == &"hand":
			var slot := int(card.get("hand_slot", -1))
			hand_slots_correct = hand_slots_correct and slot >= 0 and slot < deck.hand.size()
			if slot >= 0 and slot < deck.hand.size():
				hand_slots_correct = hand_slots_correct and card["id"] == deck.hand[slot]["id"]
	_check(hand_slots_correct, "Held cards identify their current hand slots")
	_check(deck.get_card_snapshot(&"unknown").is_empty(), "An unknown view does not leak a different card collection")
	_check(all == deck.get_card_snapshot(&"all"), "Repeated read-only snapshots have a stable display order")
	_check(_deck_state() == initial, "Reading and sorting snapshots preserves hand, pile order, timers, and RNG state")
	all[0]["id"] = -999
	all[0]["kind"] = "changed_by_viewer"
	all[0]["zone"] = &"discard"
	all.clear()
	draw[0]["kind"] = "changed_draw_copy"
	draw.append({"id": -1, "kind": "fake"})
	_check(_deck_state() == initial, "Mutating returned arrays and card dictionaries cannot mutate the live deck")


func _test_real_hud_entrances() -> void:
	await _reset()
	var before: Dictionary = _deck_state()
	await _click(DECK_BUTTON)
	_check(hud.is_browser_open() and scene.paused and paused, "Clicking the full-deck button opens a paused modal")
	_check(hud.card_browser.current_view == &"all", "The full-deck button selects the complete collection")
	_check(_ids(hud.card_browser.displayed_cards) == _ids(deck.get_card_snapshot(&"all")), "The complete browser displays every physical card, including duplicates")
	_check(hud.card_browser.get_node("Panel/CardScroll/CardGrid").get_child_count() == 10, "The full collection creates one visible card panel per physical card")
	await _click(Vector2(344, 143))
	_check(hud.card_browser.current_view == &"draw" and _ids(hud.card_browser.displayed_cards) == _ids(deck.draw_pile), "The draw tab switches to the actual draw collection")
	await _click(Vector2(494, 143))
	_check(hud.card_browser.current_view == &"discard" and hud.card_browser.displayed_cards.is_empty(), "The discard tab switches to its empty-state collection")
	await _click(Vector2(194, 143))
	_check(hud.card_browser.current_view == &"all" and hud.card_browser.displayed_cards.size() == 10 and paused, "The all tab restores all ten cards without resuming the game")
	await _key(KEY_ESCAPE)
	_check(not hud.is_browser_open() and not scene.paused and not paused, "Escape closes the browser and resumes a previously active game")
	await _click(DRAW_BUTTON)
	_check(hud.is_browser_open() and hud.card_browser.current_view == &"draw", "Clicking the actual draw pile opens its collection")
	_check(_ids(hud.card_browser.displayed_cards) == _ids(deck.draw_pile), "The draw viewer displays only cards still in the draw pile")
	await _click_close()
	_check(not hud.is_browser_open() and not paused, "The visible close button closes and resumes the browser")
	await _click(DISCARD_BUTTON)
	_check(hud.is_browser_open() and hud.card_browser.current_view == &"discard", "Clicking the actual discard pile opens its collection")
	_check(hud.card_browser.displayed_cards.is_empty(), "The discard viewer correctly displays an empty pile")
	await _key(KEY_ESCAPE)
	_check(_deck_state() == before, "Opening and closing all three viewers neither draws nor rearranges cards")
	await _key(KEY_TAB)
	_check(hud.is_browser_open() and hud.card_browser.current_view == &"all", "Tab opens the full-deck browser")
	await _key(KEY_TAB)
	_check(not hud.is_browser_open() and not paused, "A second Tab closes the full-deck browser")


func _test_play_refill_and_recycle() -> void:
	await _reset()
	var played_id := int(deck.hand[0]["id"])
	_check(deck.play_slot(0), "A real hand card can be played before browsing")
	await _click(DISCARD_BUTTON)
	var discarded: Array = hud.card_browser.displayed_cards
	_check(discarded.size() == 1 and int(discarded[0]["id"]) == played_id and discarded[0]["zone"] == &"discard", "The discard viewer shows the exact physical card just played")
	scene.open_card_browser(&"all")
	_check(hud.card_browser.displayed_cards.size() == 10 and _zone_count(hud.card_browser.displayed_cards, &"hand") == 3 and _zone_count(hud.card_browser.displayed_cards, &"discard") == 1, "Switching to all cards includes the empty hand slot's discarded card")
	var pending: Array = deck.refill_time_left.duplicate()
	await _steps(80)
	_check(deck.hand[0].is_empty() and deck.refill_time_left == pending, "Viewing cards freezes delayed refill even beyond its normal deadline")
	scene.close_card_browser()
	await _steps(66)
	_check(not deck.hand[0].is_empty() and deck.draw_pile.size() == 5 and deck.discard_pile.size() == 1, "Closing the viewer lets the pending card refill normally")
	await _click(DRAW_BUTTON)
	_check(hud.card_browser.displayed_cards.size() == 5 and _ids(hud.card_browser.displayed_cards) == _ids(deck.draw_pile), "Reopening the draw viewer reflects the completed refill")
	scene.close_card_browser()
	# Consume the other five original draw cards through the real deck API.
	for _index in range(5):
		player.reset_player()
		_check(deck.play_slot(0), "A cycle card can be played without altering its identity")
		await _steps(66)
	_check(deck.draw_pile.is_empty() and deck.discard_pile.size() == 6, "Six consumed cards leave an empty draw pile awaiting a future draw")
	var empty_draw_state: Dictionary = _deck_state()
	await _click(DRAW_BUTTON)
	_check(hud.card_browser.displayed_cards.is_empty(), "An empty draw viewer does not present discarded cards as future draws")
	scene.open_card_browser(&"discard")
	_check(hud.card_browser.displayed_cards.size() == 6 and _ids(hud.card_browser.displayed_cards) == _ids(deck.discard_pile), "Unrecycled cards remain visible in the discard collection")
	_check(_deck_state() == empty_draw_state, "Browsing an empty draw pile does not trigger a shuffle or consume RNG")
	scene.close_card_browser()
	player.reset_player()
	_check(deck.play_slot(0), "A seventh play requests the first recycled draw")
	await _steps(66)
	await _click(DISCARD_BUTTON)
	_check(hud.card_browser.displayed_cards.is_empty() and deck.draw_pile.size() == 6, "After recycling, the discard viewer is empty and the six undrawn cards are in draw")
	scene.open_card_browser(&"all")
	_check(hud.card_browser.displayed_cards.size() == 10 and _unique_ids(hud.card_browser.displayed_cards).size() == 10, "Recycling keeps all ten physical cards visible exactly once")
	scene.close_card_browser()


func _test_modal_freeze() -> void:
	await _reset()
	player.global_position = Vector3(0, 0, 1)
	enemy.global_position = Vector3(0, 0, -1)
	enemy.combat_enabled = true
	await _steps(2)
	_check(enemy.state == &"windup", "The freeze test begins during a real enemy windup")
	_check(player.request_jump() and player.activate_cybernetic(), "Jump and cybernetic timers can be active before inspecting cards")
	_check(deck.play_slot(0), "A card refill can be pending before inspecting cards")
	scene.open_card_browser(&"all")
	var player_position: Vector3 = player.global_position
	var enemy_position: Vector3 = enemy.global_position
	var enemy_time: float = enemy.state_time_left
	var energy_before: float = player.energy
	var boost_time: float = player.cybernetic_time_left
	var cooldown_time: float = player.cybernetic_cooldown_left
	var vertical_speed: float = player.velocity.y
	var deck_before: Dictionary = _deck_state()
	await _steps(90)
	_check(player.global_position == player_position and player.velocity.y == vertical_speed, "The modal freezes airborne motion and gravity")
	_check(enemy.global_position == enemy_position and enemy.state == &"windup" and enemy.state_time_left == enemy_time, "The modal freezes the enemy's movement and attack timer")
	_check(player.energy == energy_before and player.cybernetic_time_left == boost_time and player.cybernetic_cooldown_left == cooldown_time, "The modal freezes energy recovery, boost duration, and cooldown")
	_check(_deck_state() == deck_before, "The modal freezes deck refill and preserves its RNG state")
	scene.close_card_browser()
	enemy.combat_enabled = false
	await _steps(3)
	_check(player.global_position != player_position and player.cybernetic_time_left < boost_time, "Closing the modal resumes the existing jump and boost")


func _test_modal_input_isolation() -> void:
	await _reset()
	scene.open_card_browser(&"all")
	var original_position: Vector3 = player.global_position
	var original_energy: float = player.energy
	var original_deck: Dictionary = _deck_state()
	var original_yaw: float = scene.camera_yaw
	var original_pitch: float = scene.camera_pitch
	var original_distance: float = scene.camera_distance
	for code in [KEY_W, KEY_1, KEY_Q, KEY_SPACE]:
		_send_key(code, true)
	await _steps(6)
	for code in [KEY_W, KEY_1, KEY_Q, KEY_SPACE]:
		_send_key(code, false)
	await _steps(2)
	_check(player.global_position == original_position and player.energy == original_energy, "Movement and numbered-card input cannot move or spend energy in the modal")
	_check(not player.is_cybernetic_active and player.cybernetic_cooldown_left == 0.0 and player.velocity.y <= 0.0, "Q and Space cannot activate a boost or jump in the modal")
	_check(_deck_state() == original_deck, "Numbered-card input does not discard or draw behind the viewer")
	await _click(Vector2(318, 464))
	_send_mouse(MOUSE_BUTTON_LEFT, true, Vector2(480, 270))
	_send_motion(Vector2(540, 300), Vector2(60, 30))
	_send_mouse(MOUSE_BUTTON_LEFT, false, Vector2(540, 300))
	_send_mouse(MOUSE_BUTTON_WHEEL_UP, true, Vector2(480, 270))
	_send_mouse(MOUSE_BUTTON_WHEEL_UP, false, Vector2(480, 270))
	_send_magnify(1.5, Vector2(480, 270))
	_send_magnify(0.5, Vector2(480, 270))
	var scroll := InputEventPanGesture.new()
	scroll.position = hud.get_global_transform_with_canvas() * Vector2(480, 270)
	scroll.delta = Vector2(0, 4)
	root.push_input(scroll, true)
	await _steps(3)
	_check(scene.camera_yaw == original_yaw and scene.camera_pitch == original_pitch and scene.camera_distance == original_distance, "Modal drags, wheel scrolling, trackpad pinches and scrolls cannot rotate or zoom the world camera")
	_check(hud.is_browser_open() and _deck_state() == original_deck, "Clicking over an underlying hand card cannot play through the modal")
	await _click_close()
	_send_motion(Vector2(580, 320), Vector2(40, 20))
	await _steps(3)
	_check(not scene._orbiting and scene.camera_yaw == original_yaw, "Closing by mouse leaves no held camera drag or release-through rotation")
	_check(_deck_state() == original_deck and not player.is_cybernetic_active and player.velocity.y <= 0.0, "Closing the viewer does not replay blocked card, Q, or jump presses")
	# Opening while a world drag is held must also clear that drag.
	_send_mouse(MOUSE_BUTTON_LEFT, true, Vector2(480, 240))
	await process_frame
	scene.open_card_browser(&"all")
	_send_mouse(MOUSE_BUTTON_LEFT, false, Vector2(480, 240))
	await _key(KEY_ESCAPE)
	_send_motion(Vector2(520, 240), Vector2(40, 0))
	await _steps(2)
	_check(not scene._orbiting and scene.camera_yaw == original_yaw, "Escape also clears a world drag that was held when the viewer opened")


func _test_pause_and_reset() -> void:
	await _reset()
	scene.toggle_pause()
	await _click(DRAW_BUTTON)
	_check(hud.is_browser_open() and scene.paused, "A pile can be inspected while the game was already manually paused")
	await _key(KEY_ESCAPE)
	_check(not hud.is_browser_open() and scene.paused and paused, "Closing an inspection preserves a pre-existing manual pause")
	scene.open_card_browser(&"all")
	scene.toggle_pause()
	_check(not hud.is_browser_open() and scene.paused and paused, "Pause-toggle closes the modal without losing the earlier pause state")
	scene.toggle_pause()
	scene.open_card_browser(&"all")
	scene.toggle_pause()
	_check(not hud.is_browser_open() and not scene.paused and not paused, "Pause-toggle closes the modal and restores a previously active game")
	player.health = 25.0
	player.energy = 1.0
	scene.open_card_browser(&"discard")
	await _key(KEY_R)
	enemy.combat_enabled = false
	_check(not hud.is_browser_open() and not scene.paused and not paused, "R closes the browser and restarts without a stuck pause")
	_check(player.health == player.max_health and player.energy == player.max_energy, "Restart from the browser restores player health and energy")
	_check(deck.hand.size() == 4 and _nonempty_hand_count() == 4 and deck.draw_pile.size() == 6 and deck.discard_pile.is_empty(), "Restart from the browser rebuilds the normal ten-card distribution")
	await _click(DECK_BUTTON)
	_check(hud.card_browser.displayed_cards.size() == 10 and _zone_count(hud.card_browser.displayed_cards, &"discard") == 0, "The next browser opening uses the restarted deck without stale discarded cards")
	scene.close_card_browser()


func _reset() -> void:
	_release_all()
	scene.restart()
	enemy.combat_enabled = false
	deck.reset_deck(8128)
	await _steps(2)


func _deck_state() -> Dictionary:
	return {
		"hand": deck.hand.duplicate(true),
		"draw": deck.draw_pile.duplicate(true),
		"discard": deck.discard_pile.duplicate(true),
		"refill": deck.refill_time_left.duplicate(),
		"rng": deck._rng.state,
	}


func _ids(cards: Array) -> Array[int]:
	var ids: Array[int] = []
	for card in cards:
		if not card.is_empty():
			ids.append(int(card["id"]))
	ids.sort()
	return ids


func _unique_ids(cards: Array) -> Dictionary:
	var ids: Dictionary = {}
	for card in cards:
		ids[card["id"]] = true
	return ids


func _kind_count(cards: Array, kind: String) -> int:
	var count := 0
	for card in cards:
		if card["kind"] == kind:
			count += 1
	return count


func _zone_count(cards: Array, zone: StringName) -> int:
	var count := 0
	for card in cards:
		if card["zone"] == zone:
			count += 1
	return count


func _nonempty_hand_count() -> int:
	var count := 0
	for card in deck.hand:
		if not card.is_empty():
			count += 1
	return count


func _click(point: Vector2) -> void:
	_send_motion(point, Vector2.ZERO)
	await process_frame
	_send_mouse(MOUSE_BUTTON_LEFT, true, point)
	await process_frame
	_send_mouse(MOUSE_BUTTON_LEFT, false, point)
	await process_frame
	await process_frame


func _click_close() -> void:
	var close_button := hud.card_browser.get_node("Panel/CloseButton") as Control
	# Use the real button's center, converted back into the HUD's logical space.
	var button_center: Vector2 = close_button.get_global_transform_with_canvas() * (close_button.size * 0.5)
	await _click(hud.get_global_transform_with_canvas().affine_inverse() * button_center)


func _send_mouse(button: MouseButton, down: bool, point: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = down
	event.position = hud.get_global_transform_with_canvas() * point
	event.global_position = event.position
	# Coordinates are already in the stretched viewport's logical space. Feed
	# its complete input/GUI/unhandled pipeline without applying window scaling
	# a second time (the configured 1280x720 window displays a 960x540 canvas).
	root.push_input(event, true)


func _send_motion(point: Vector2, relative: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = hud.get_global_transform_with_canvas() * point
	event.global_position = event.position
	event.relative = relative
	root.push_input(event, true)


func _send_magnify(factor: float, point: Vector2) -> void:
	var event := InputEventMagnifyGesture.new()
	event.position = hud.get_global_transform_with_canvas() * point
	event.factor = factor
	root.push_input(event, true)


func _send_key(code: Key, down: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = down
	Input.parse_input_event(event)


func _key(code: Key) -> void:
	_send_key(code, true)
	await process_frame
	_send_key(code, false)
	await process_frame
	await process_frame


func _steps(count: int) -> void:
	for _index in range(count):
		await physics_frame
	await process_frame


func _release_all() -> void:
	for action in ACTIONS:
		Input.action_release(action)


func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
		print("PASS: ", description)
	else:
		failed += 1
		push_error("FAIL: " + description)
