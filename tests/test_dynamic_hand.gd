extends SceneTree
## Run: Godot --headless --path . --fixed-fps 60 --script tests/test_dynamic_hand.gd
## Exercise real UI/input routing, paused equipment changes, and card identity.

const DECK = preload("res://deck.gd")
var scene: Node3D
var player: CharacterBody3D
var deck: Node
var hud: Control
var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	scene = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	await process_frame
	player = scene.player
	deck = scene.deck
	hud = scene.hud
	scene.enemy.combat_enabled = false
	await _steps(2)
	_test_purchases()
	await _test_resize_and_pause()
	await _test_input_and_labels()
	await _test_empty_deck_recovery()
	scene.restart()
	_check(deck.hand_size == 4 and deck.total_cards == 11, "New run removes purchased copies and accessories while preserving exploration rewards")
	_check(scene.inventory.get_equipped_count() == 0 and hud._labels["implants_control"].text == "义体 0/5", "Restart resets the equipped count in the HUD")
	print("DYNAMIC HAND RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_purchases() -> void:
	var original: Array = deck.get_card_snapshot()
	_check(not deck.add_purchased_card("missing") and deck.get_card_snapshot() == original, "Invalid purchases cannot mutate cards or unlock knowledge")
	_check(deck.add_purchased_card("slash") and deck.total_cards == 11 and _count_kind("slash") == 4, "Buying an already known attack adds exactly one copy")
	_check(deck.add_purchased_card("shot") and deck.is_kind_unlocked("shot") and deck.total_cards == 12 and _count_kind("shot") == 1, "Buying a new action unlocks knowledge without granting a second free copy")
	_check(deck.add_purchased_card("shot") and deck.total_cards == 13 and _count_kind("shot") == 2, "Repeated purchases create separate usable card copies")
	_check(_unique_cards(deck, 13), "Purchased cards have distinct IDs across all three zones")
	deck.reset_deck(24)
	_check(deck.total_cards == 13 and _count_kind("shot") == 2 and _unique_cards(deck, 13), "Ordinary reshuffling/reset preserves purchased quantities without adding unlock duplicates")
	_check(deck.unlock_kind("blink"), "Exploration can still grant a distinct new action")
	deck.clear_purchased_cards()
	deck.reset_deck(25)
	_check(deck.total_cards == 11 and _count_kind("slash") == 3 and _count_kind("shot") == 0 and _count_kind("blink") == 1, "Clearing purchases retains only starter and exploration reward copies")
	_check(deck.is_kind_unlocked("shot"), "Purchased action knowledge may remain without becoming a free physical card")


func _test_resize_and_pause() -> void:
	var first_rect: Rect2 = hud.card_rect(0)
	_check(first_rect == Rect2(268, 424, 100, 80) and hud.card_rect(3) == Rect2(592, 424, 100, 80), "Default four-slot HUD positions remain unchanged")
	var before: Array = _ids(deck.get_card_snapshot())
	deck.set_hand_size(99)
	_check(deck.hand_size == 9 and _occupied(deck) == 9 and _unique_cards(deck, 11), "Slot capacity clamps at nine and fills without duplicating cards")
	_check(_ids(deck.get_card_snapshot()) == before, "Growing the hand preserves the exact set of physical cards")
	var kept: Array = deck.hand.slice(0, 4).duplicate(true)
	player.reset_player()
	deck.play_slot(8)
	_check(deck.refill_time_left[8] > 0.0, "Last slot has a real pending refill before it is removed")
	deck.set_hand_size(-10)
	_check(deck.hand_size == 4 and deck.refill_time_left.size() == 4 and deck.hand == kept, "Shrinking preserves earlier slots and cancels removed-slot timers")
	_check(_ids(deck.get_card_snapshot()) == before and _unique_cards(deck, 11), "Cards removed from extra slots return to the draw pile without loss")
	scene.toggle_pause()
	for index in 5:
		scene.inventory.add_item("hand_slot")
	_check(deck.hand_size == 9 and _occupied(deck) == 4, "Equipping five expansions during pause schedules all five new slots")
	_check(hud._labels["implants_control"].text == "义体 5/5" and hud._labels["hand_count"].text == "手牌 4 / 9", "Paused HUD shows all equipped implants and expanded capacity")
	var timers: Array = deck.refill_time_left.duplicate()
	await _steps(8)
	_check(deck.refill_time_left == timers and _occupied(deck) == 4, "Shop-style pause freezes pending draws")
	scene.toggle_pause()
	await _steps(64)
	_check(_occupied(deck) == 9 and _unique_cards(deck, 11), "Resuming after a paused expansion fills every available slot")
	hud.setup(player, deck)
	hud.set_implant_inventory(scene.inventory)
	hud.set_implant_inventory(scene.inventory)
	var hud_connections := 0
	for connection in scene.inventory.changed.get_connections():
		if connection["callable"] == Callable(hud, "_on_implants_changed"):
			hud_connections += 1
	_check(hud_connections == 1, "Rebinding HUD inventory cannot duplicate change listeners")


func _test_input_and_labels() -> void:
	var left: Rect2 = hud.card_rect(0)
	var right: Rect2 = hud.card_rect(8)
	_check(is_equal_approx(left.position.x, 960.0 - right.end.x) and right.end.x <= 852.0, "Nine cards remain centered and inside the screen")
	_check(not right.intersects(hud.RESET_CONTROL) and not right.intersects(hud.PAUSE_CONTROL), "Expanded cards cannot overlap restart or pause buttons")
	var clicks: Array[int] = []
	hud.card_requested.connect(func(slot: int) -> void: clicks.append(slot))
	for slot in 9:
		var action := "hand_%d" % (slot + 1)
		_check(InputMap.has_action(action), "Keyboard binding exists for slot %d" % (slot + 1))
		player.reset_player()
		deck.reset_deck(50 + slot)
		var id: int = deck.hand[slot]["id"]
		Input.action_press(action)
		await _steps(2)
		Input.action_release(action)
		await _steps(1)
		_check(deck.hand[slot].is_empty() and _ids(deck.discard_pile).has(id), "Number %d plays its displayed hand position" % (slot + 1))
		player.reset_player()
		deck.reset_deck(70 + slot)
		var mouse := InputEventMouseButton.new()
		mouse.button_index = MOUSE_BUTTON_LEFT
		mouse.pressed = true
		mouse.position = hud.get_global_transform_with_canvas() * hud.card_rect(slot).get_center()
		hud._unhandled_input(mouse)
		_check(clicks.back() == slot and deck.hand[slot].is_empty(), "Clicking displayed slot %d routes the same card as its keyboard key" % (slot + 1))
		_check(hud._labels["slot%d_key" % slot].text == str(slot + 1) and hud._labels["slot%d_key" % slot].visible, "Slot %d has the correct visible keyboard label" % (slot + 1))
	scene.inventory.reset_inventory()
	_check(not hud._labels["slot4_key"].visible and not hud._labels["slot8_name"].visible and hud._slot_at(right.get_center()) == -1, "Unequipping expansions hides and disables removed slots")


func _test_empty_deck_recovery() -> void:
	var sparse := DECK.new()
	root.add_child(sparse)
	sparse.setup(player, 91)
	# A future deck editor may reduce the physical deck below hand capacity.
	sparse.hand = [{"id": 0, "kind": "slash"}, {}, {}, {}]
	sparse.draw_pile.clear()
	sparse.discard_pile.clear()
	sparse.total_cards = 1
	sparse.refill_time_left.fill(0.0)
	sparse.set_hand_size(9)
	await _steps(64)
	_check(_occupied(sparse) == 1, "Slots safely remain empty while every physical card is already held")
	sparse.add_purchased_card("shield")
	await _steps(2)
	_check(_occupied(sparse) == 2 and sparse.draw_pile.is_empty() and _unique_cards(sparse, 2), "Previously exhausted slots automatically recover when a purchase adds a card")
	paused = true
	sparse.add_purchased_card("roll")
	sparse.reset_deck(92)
	_check(_occupied(sparse) == 0, "A reset during pause does not bypass the deck's pause rules")
	paused = false
	await _steps(2)
	_check(_occupied(sparse) == 9 and _unique_cards(sparse, 12), "A deck reset during pause still deals its hand after resuming")
	sparse.queue_free()
	await process_frame


func _count_kind(kind: String) -> int:
	var result := 0
	for card in deck.get_card_snapshot():
		result += int(card["kind"] == kind)
	return result


func _ids(cards: Array) -> Array:
	var result: Array = []
	for card in cards:
		if not card.is_empty():
			result.append(card["id"])
	result.sort()
	return result


func _occupied(source: Node) -> int:
	return _ids(source.hand).size()


func _unique_cards(source: Node, expected: int) -> bool:
	var ids := _ids(source.get_card_snapshot())
	var unique := {}
	for id in ids:
		unique[id] = true
	return ids.size() == expected and unique.size() == expected and source.total_cards == expected


func _steps(count: int) -> void:
	for index in count:
		await physics_frame
		await process_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		passed += 1
		print("PASS: " + message)
	else:
		failed += 1
		push_error("FAIL: " + message)
