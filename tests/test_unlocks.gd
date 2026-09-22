extends SceneTree
## Real-scene progression: physical interaction, live deck growth, reset and cycling.

const NEW_KINDS: Array[String] = ["punch", "shot", "charged_slash", "blink", "jet_jump", "airborne_slash", "dive_slash"]
var scene: Node3D
var player: CharacterBody3D
var deck: Node
var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	scene = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	await process_frame
	player = scene.get("player")
	deck = scene.get("deck")
	scene.get("enemy").combat_enabled = false
	await _steps(2)
	_check(InputMap.has_action("interact"), "E interaction is mapped")
	_check(deck.total_cards == 10 and deck.get_card_snapshot().size() == 10, "Fresh game retains ten starter cards")
	_check(deck.hand.size() == 4, "Unlocking does not enlarge cognitive hand capacity")
	for kind in ["slash", "roll", "dash_slash"]:
		_check(deck.is_kind_unlocked(kind), "Starter action %s is already known" % kind)
	for kind in NEW_KINDS:
		_check(not deck.is_kind_unlocked(kind), "%s starts locked" % kind)
	scene.open_card_browser(&"catalog")
	var catalog_browser: Control = scene.get("hud").card_browser
	var unlocked_count := 0
	for entry in catalog_browser.displayed_cards:
		unlocked_count += int(entry.get("unlocked", false))
	_check(catalog_browser.displayed_cards.size() == 10 and unlocked_count == 3, "Discovery browser shows ten actions with only three restored")
	_check(deck.get_card_snapshot().size() == 10, "Locked catalog entries never create physical cards")
	scene.close_card_browser()
	var original: Array = deck.get_card_snapshot()
	_check(not deck.unlock_kind("invalid_kind") and not deck.unlock_kind("slash"), "Unknown and duplicate unlocks are rejected")
	_check(original == deck.get_card_snapshot(), "Rejected unlocks preserve every live card")
	_check(not scene.try_interact(), "E cannot unlock a distant terminal from spawn")
	var terminals: Array = scene.get("unlock_terminals")
	_check(terminals.size() == 3, "Scene contains three grouped memory terminals")
	var total := 10
	for terminal in terminals:
		player.reset_player()
		player.global_position = terminal.global_position + Vector3(0, 0, 1)
		await _steps(2)
		_check(terminal.can_interact(), "Terminal can be reached on foot: %s" % terminal.name)
		scene.toggle_pause()
		_check(not scene.try_interact(), "Pause prevents memory restoration")
		scene.toggle_pause()
		scene.open_card_browser(&"all")
		_check(not scene.try_interact(), "Deck browser prevents memory restoration")
		scene.close_card_browser()
		var nearby_position := player.global_position
		player.global_position.y = terminal.global_position.y + 4.0
		_check(not scene.try_interact(), "Flying far above a terminal cannot interact")
		player.global_position = nearby_position
		player.take_damage(player.max_health)
		_check(not scene.try_interact(), "Defeated players cannot restore memories")
		player.reset_player()
		player.global_position = nearby_position
		await _steps(2)
		var hand_before: Array = deck.hand.duplicate(true)
		var draw_before: int = deck.draw_pile.size()
		var energy_before: float = player.energy
		Input.action_press("interact")
		await _steps(2)
		Input.action_release("interact")
		await _steps(1)
		total += terminal.card_kinds.size()
		_check(terminal.is_restored, "E input restores %s" % terminal.name)
		_check(deck.total_cards == total, "Restoration grows the live deck exactly once")
		_check(deck.draw_pile.size() == draw_before + terminal.card_kinds.size(), "New cards immediately enter the draw pile")
		_check(deck.hand == hand_before and is_equal_approx(energy_before, player.energy), "Restoration preserves held cards and energy")
		for kind in terminal.card_kinds:
			_check(deck.is_kind_unlocked(kind) and _kind_count(kind) == 1, "Recovered %s has exactly one physical card" % kind)
		_check(not scene.try_interact(), "A restored terminal cannot duplicate rewards")
		_check(_deck_valid(total), "Card identity and zone conservation survive restoration")
	_check(deck.total_cards == 17, "All ten actions produce seventeen physical cards")
	scene.open_card_browser(&"catalog")
	var all_restored := true
	for entry in catalog_browser.displayed_cards:
		all_restored = all_restored and bool(entry.get("unlocked", false))
	_check(all_restored and catalog_browser.displayed_cards.size() == 10, "Discovery browser updates every unlock state")
	scene.close_card_browser()
	scene.open_card_browser(&"all")
	var browser: Control = scene.get("hud").card_browser
	_check(browser.displayed_cards.size() == 17, "Complete deck browser immediately includes every unlocked card")
	scene.close_card_browser()
	scene.restart()
	scene.get("enemy").combat_enabled = false
	await _steps(2)
	_check(deck.total_cards == 17 and _deck_valid(17), "R preserves unlocks and rebuilds seventeen unique cards")
	for terminal in terminals:
		_check(terminal.is_restored, "R preserves restored terminal appearance")
	await _test_full_deck_cycle()
	# A separately constructed deck represents a fresh process, not an R reset.
	var fresh := Node.new()
	fresh.set_script(load("res://deck.gd"))
	root.add_child(fresh)
	fresh.setup(player, 44)
	_check(fresh.total_cards == 10 and not fresh.is_kind_unlocked("punch"), "Unlock scope is this session; a fresh deck starts with basic memories")
	fresh.queue_free()
	print("UNLOCK RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_full_deck_cycle() -> void:
	# Go through the deck public play path. Each accepted action spends a real
	# card; delayed draws exhaust the stack before shuffling spent cards back.
	deck.reset_deck(917)
	var saw: Dictionary = {}
	var all_valid := true
	var all_playable := true
	var shuffled := [0]
	deck.reshuffled.connect(func(_count: int) -> void: shuffled[0] += 1)
	for index in range(72):
		player.reset_player()
		await _steps(2)
		var slot := index % 4
		if deck.hand[slot].is_empty():
			all_playable = false
			continue
		var kind: String = deck.hand[slot]["kind"]
		var card_id: int = deck.hand[slot]["id"]
		var accepted: bool = deck.play_slot(slot)
		all_playable = all_playable and accepted
		if accepted:
			saw[kind] = true
			all_valid = all_valid and deck.hand[slot].is_empty() and _has_id(deck.discard_pile, card_id)
		await _steps(64)
		all_valid = all_valid and _deck_valid(17)
	_check(all_playable, "Every expanded-deck card can be played through the real deck")
	_check(saw.size() == 10, "Random drawing reaches all ten action kinds")
	_check(all_valid, "Expanded deck conserves unique cards across play, refill and shuffle")
	_check(shuffled[0] >= 3, "Expanded deck recycles discarded cards on demand across multiple cycles")


func _has_id(cards: Array, card_id: int) -> bool:
	for card in cards:
		if int(card["id"]) == card_id:
			return true
	return false


func _kind_count(kind: String) -> int:
	var count := 0
	for card in deck.get_card_snapshot():
		if card["kind"] == kind:
			count += 1
	return count


func _deck_valid(expected: int) -> bool:
	var seen: Dictionary = {}
	var valid := true
	for zone in [deck.hand, deck.draw_pile, deck.discard_pile]:
		for card in zone:
			if card.is_empty():
				continue
			valid = valid and not seen.has(card["id"]) and deck.is_kind_unlocked(card["kind"])
			seen[card["id"]] = true
	return valid and seen.size() == expected and deck.total_cards == expected


func _steps(count: int) -> void:
	for _frame in range(count):
		await physics_frame
		await process_frame


func _check(condition: bool, label: String) -> void:
	if condition:
		passed += 1
		print("PASS: " + label)
	else:
		failed += 1
		push_error("FAIL: " + label)
