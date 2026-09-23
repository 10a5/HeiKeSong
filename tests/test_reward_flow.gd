extends SceneTree
## Real-scene reward flow integration test.
## Godot --headless --path . --fixed-fps 60 --script tests/test_reward_flow.gd

const FLOOR = preload("res://floor_one.tscn")
const IMPLANTS = preload("res://implant_catalog.gd")

var scene: Node
var flow: Node
var deck: Node
var inventory: Node
var player: CharacterBody3D
var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	scene = FLOOR.instantiate()
	root.add_child(scene)
	await _frames(4)
	flow = scene.get("reward_flow") as Node
	deck = scene.get("deck") as Node
	inventory = scene.get("inventory") as Node
	player = scene.get("player") as CharacterBody3D
	_check(is_instance_valid(flow) and is_instance_valid(deck) and is_instance_valid(inventory), "The first-floor scene exposes deck, implants and reward flow")
	await _test_card_mouse_choice()
	await _test_implant_full_slots()
	await _test_factory_real_interaction()
	await _test_payload_validation_and_modal_guard()
	await _test_reset_discards_waiting_rewards()
	await _test_queued_rewards()
	await _test_same_frame_enemy_deaths()
	await _test_restart_clears_run_cards()
	if is_instance_valid(scene):
		scene.queue_free()
	print("REWARD FLOW RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_card_mouse_choice() -> void:
	await _call_scene_restart()
	var before: int = int(deck.get("total_cards"))
	_check(_open_reward("enemy", {"type": "card", "options": ["punch", "roll"]}), "Card reward opens through the floor controller")
	var opening := _snapshot()
	_check(str(opening.get("source", "")) == "enemy" and opening.has("reward"), "Reward snapshot exposes source and payload")
	_check(_flow_bool("is_transitioning"), "Reward starts in the Matrix transition")
	_check(not _flow_call_bool("choose_card", 0) and int(deck.get("total_cards")) == before, "Card cannot be claimed while the transition is covering the panel")
	var card_button := await _wait_for_choice("携带", 120)
	_check(card_button != null and not _flow_bool("is_transitioning"), "Card choices become clickable after the transition")
	if card_button != null:
		await _click(card_button)
	await _frames(4)
	_check(int(deck.get("total_cards")) == before + 1, "A real mouse click adds exactly one selected card")
	_check(not _flow_bool("is_open"), "Selecting a card closes the reward modal")


func _test_implant_full_slots() -> void:
	await _call_scene_restart()
	var kinds: Array[String] = IMPLANTS.kinds()
	for index in range(mini(5, kinds.size())):
		inventory.call("add_item", kinds[index])
	_check(int(inventory.call("get_equipped_count")) == 5, "The implant inventory can be filled to five equipped slots")
	var before: int = (inventory.call("get_items") as Array).size()
	_check(_open_reward("factory", {"type": "implant", "kind": "damage"}), "A factory implant reward opens")
	_check(not _flow_bool("choose_implant") and (inventory.call("get_items") as Array).size() == before, "Implants cannot be claimed during the transition")
	var implant_button := await _wait_for_choice("携带", 120)
	_check(implant_button != null, "The implant offer is presented as a clickable choice")
	if implant_button != null:
		await _click(implant_button)
	await _frames(4)
	var items: Array = inventory.call("get_items") as Array
	var received_in_bag := false
	if items.size() == before + 1:
		var last: Dictionary = items[items.size() - 1] as Dictionary
		received_in_bag = not bool(last.get("equipped", true))
	_check(items.size() == before + 1 and received_in_bag, "A sixth implant is received in the bag when all five slots are full")
	_check(int(inventory.call("get_equipped_count")) == 5, "A full implant loadout remains capped at five equipped items")


func _test_reset_discards_waiting_rewards() -> void:
	await _call_scene_restart()
	_check(_open_reward("enemy", {"type": "card", "options": ["shot", "blink"]}), "A reward can be opened before a retry")
	_check(_flow_bool("is_open"), "The retry fixture is active")
	await _tap_key(KEY_R)
	await _frames(3)
	var effect: Node = scene.get("hud").get("matrix_transition") as Node
	_check(not _flow_bool("is_open") and _snapshot_source().is_empty() and effect.get_signal_connection_list("covered").is_empty(), "R clears the visible reward and its transition callback")
	_check(_open_reward("enemy", {"type": "card", "options": ["punch", "shot"]}), "A reward can be queued before generating a new district")
	if _flow_has("enqueue_reward"):
		_flow_call("enqueue_reward", "factory", {"type": "implant", "kind": "armor"})
	var old_seed: int = int(scene.get("map_seed"))
	await _tap_key(KEY_N)
	await _frames(4)
	_check(not _flow_bool("is_open") and _snapshot_source().is_empty() and int(_snapshot().get("queued", 0)) == 0 and int(scene.get("map_seed")) != old_seed, "N discards visible and queued rewards from the previous district")


func _test_factory_real_interaction() -> void:
	await _call_scene_restart()
	var factory: Node = null
	for service: Node in scene.get("services") as Array:
		if str(service.get("kind")) == "factory":
			factory = service
			break
	_check(is_instance_valid(factory), "The generated floor contains a factory reward service")
	if not is_instance_valid(factory):
		return
	player.global_position = factory.global_position
	await _frames(2)
	var cards_before: int = int(deck.get("total_cards"))
	var items_before: int = (inventory.call("get_items") as Array).size()
	var event_index: int = int(factory.get("event_index"))
	_check(bool(factory.call("can_interact")), "The factory's physical interaction range is reachable")
	await _tap_key(KEY_E)
	_check(_flow_bool("is_open"), "A real E key interaction opens the factory reward")
	var expected_type := "card" if event_index == 0 else "implant"
	var opened_snapshot := _snapshot()
	_check(str(opened_snapshot.get("source", "")) == "factory" and str(opened_snapshot.get("reward", {}).get("type", "")) == expected_type, "Factory interaction presents its seeded card or implant reward")
	var skip := await _wait_for_choice("暂不携带", 120)
	_check(skip != null, "The factory reward has a real skip button")
	if skip != null:
		await _click(skip)
	await _frames(4)
	_check(bool(factory.get("used")) and not _flow_bool("is_open"), "The factory stays consumed after its reward modal is dismissed")
	_check(int(deck.get("total_cards")) == cards_before and (inventory.call("get_items") as Array).size() == items_before, "Skipping a factory reward grants no card or implant")
	_check(not bool(scene.call("try_interact")), "A consumed factory cannot be claimed twice")


func _test_payload_validation_and_modal_guard() -> void:
	await _call_scene_restart()
	_check(not bool(scene.call("open_reward", "test", {"type": "unknown"})), "Unknown reward payloads are rejected")
	_check(not bool(scene.call("open_reward", "test", {"type": "card", "options": []})), "Empty card choices are rejected")
	_check(not bool(scene.call("open_reward", "test", {"type": "implant", "kind": ""})), "Empty implant payloads are rejected")
	_check(not bool(scene.call("open_reward", "test", {"type": "card", "options": ["punch", "missing_card"]})), "Unknown action identifiers are rejected")
	_check(not bool(scene.call("open_reward", "test", {"type": "card", "options": ["punch", "punch"]})), "Duplicate card options are rejected")
	_check(not bool(scene.call("open_reward", "test", {"type": "implant", "kind": "missing_implant"})), "Unknown implant identifiers are rejected")
	_check(_open_reward("enemy", {"type": "card", "options": ["punch", "roll"]}), "A valid reward opens after invalid payloads")
	_check(not bool(_flow_call("enqueue_reward", "enemy", {"type": "implant", "kind": "missing_implant"})) and int(_snapshot().get("queued", 0)) == 0, "Invalid queued rewards are rejected without occupying the queue")
	var first := _snapshot()
	var second_result: bool = bool(scene.call("open_reward", "factory", {"type": "implant", "kind": "damage"}))
	var second := _snapshot()
	_check(str(second.get("source", "")) == str(first.get("source", "")) and str(second.get("reward", {}).get("type", "")) == str(first.get("reward", {}).get("type", "")), "Opening another reward never replaces the visible modal")
	_check(not second_result and int(second.get("queued", 0)) == 0, "A direct second reward request is rejected instead of stacking another modal")
	if _flow_bool("is_open"):
		_flow_call("reset")
	await _frames(3)
	_check(not _flow_bool("is_open"), "Modal guard cleanup leaves no orphaned reward")
	scene.call("open_card_browser", &"all")
	_check(not _open_reward("enemy", {"type": "card", "options": ["punch", "roll"]}), "A reward cannot stack over the card browser")
	scene.call("close_card_browser")
	scene.call("toggle_city_map")
	_check(not _open_reward("enemy", {"type": "card", "options": ["punch", "roll"]}), "A reward cannot stack over the city map")
	scene.call("close_city_map")
	var shop: Node = scene.get("shop_system") as Node
	shop.call("open_inventory")
	_check(bool(shop.call("is_open")) and not _open_reward("enemy", {"type": "card", "options": ["punch", "roll"]}), "A reward cannot stack over the implant inventory")
	shop.call("close")


func _test_queued_rewards() -> void:
	await _call_scene_restart()
	if not _flow_has("enqueue_reward"):
		_check(false, "Reward flow exposes the queued-reward API")
		return
	var before: int = int(deck.get("total_cards"))
	_check(_open_reward("enemy", {"type": "card", "options": ["punch", "roll"]}), "The first reward in a queue opens immediately")
	await _wait_for_choice("暂不携带", 120)
	_flow_call("enqueue_reward", "factory", {"type": "implant", "kind": "damage"})
	var first_skip := await _wait_for_choice("暂不携带", 120)
	_check(first_skip != null, "The first queued reward has a visible skip button")
	if first_skip != null:
		await _click(first_skip)
	await _frames(4)
	var second := await _wait_for_any_choice(120)
	var queued_snapshot := _snapshot()
	_check(second != null and str(queued_snapshot.get("source", "")) == "factory", "The next queued reward appears after the first choice")
	if second != null:
		var skip_second := _find_button("暂不携带")
		if skip_second != null:
			await _click(skip_second)
	await _frames(4)
	_check(int(deck.get("total_cards")) == before and not _flow_bool("is_open"), "Skipping both queued rewards changes neither deck nor modal state")


func _test_same_frame_enemy_deaths() -> void:
	await _call_scene_restart()
	var encounters: Array = scene.get("encounters") as Array
	if encounters.size() < 2:
		_check(false, "The generated floor has two encounters for the same-frame death test")
		return
	var foe_a: Node = encounters[0].get("foe") as Node
	var foe_b: Node = encounters[1].get("foe") as Node
	_check(is_instance_valid(foe_a) and is_instance_valid(foe_b), "Two encounter enemies are available for the same-frame test")
	if not is_instance_valid(foe_a) or not is_instance_valid(foe_b):
		return
	encounters[0].set_physics_process(false)
	encounters[1].set_physics_process(false)
	foe_a.set_physics_process(false)
	foe_b.set_physics_process(false)
	(foe_a as Node3D).global_position = player.global_position + Vector3(-0.65, 0.0, -0.65)
	(foe_b as Node3D).global_position = player.global_position + Vector3(0.65, 0.0, -0.65)
	foe_a.call("take_damage", 70.0)
	foe_b.call("take_damage", 70.0)
	var death_frames: Array[int] = []
	foe_a.connect("defeated", func() -> void: death_frames.append(Engine.get_physics_frames()))
	foe_b.connect("defeated", func() -> void: death_frames.append(Engine.get_physics_frames()))
	_check(bool(player.call("request_card", "front_kick")), "The real roundhouse card begins an area attack against two nearby guards")
	await _frames(70)
	_check(bool(foe_a.get("is_dead")) and bool(foe_b.get("is_dead")) and death_frames.size() == 2 and death_frames[0] == death_frames[1], "The real AOE defeats both enemies in the same physics frame")
	var first := await _wait_for_choice("暂不携带", 120)
	_check(first != null, "The first same-frame defeat produces a reward")
	if first != null:
		await _click(first)
	await _frames(4)
	var second := await _wait_for_any_choice(120)
	_check(second != null, "The second same-frame defeat remains queued as another reward")
	if second != null:
		var final_skip := _find_button("暂不携带")
		if final_skip != null:
			await _click(final_skip)
	await _frames(5)
	_check(not _flow_bool("is_open"), "Both same-frame rewards can be dismissed in order")


func _test_restart_clears_run_cards() -> void:
	await _call_scene_restart()
	var before: int = int(deck.get("total_cards"))
	_check(_open_reward("enemy", {"type": "card", "options": ["shot", "blink"]}), "A run card reward opens before restart")
	var card_button := await _wait_for_choice("携带", 120)
	if card_button != null:
		await _click(card_button)
	await _frames(4)
	_check(int(deck.get("total_cards")) == before + 1, "Selecting the reward adds a run card")
	await _call_scene_restart()
	_check(int(deck.get("total_cards")) == 10, "R removes run-only reward cards from the rebuilt deck")


func _open_reward(source: String, payload: Dictionary) -> bool:
	return bool(scene.call("open_reward", source, payload))


func _call_scene_restart() -> void:
	if is_instance_valid(scene):
		scene.call("restart")
		await _frames(4)


func _wait_for_choice(needle: String, max_frames: int) -> Button:
	for _index in max_frames:
		await process_frame
		var button := _find_button(needle)
		if button != null and not _flow_bool("is_transitioning"):
			return button
	return null


func _wait_for_any_choice(max_frames: int) -> Button:
	for _index in max_frames:
		await process_frame
		if not _flow_bool("is_transitioning"):
			var button := _find_button("暂不携带")
			if button == null:
				button = _find_button("携带")
			if button != null:
				return button
	return null


func _find_button(needle: String) -> Button:
	if not is_instance_valid(flow):
		return null
	var panel: Node = flow.get("panel") as Node
	if not is_instance_valid(panel) or not bool(panel.get("visible")):
		return null
	for candidate: Node in panel.find_children("*", "Button", true, false):
		var button: Button = candidate as Button
		if is_instance_valid(button) and str(button.text).contains(needle) and not button.disabled:
			return button
	return null


func _click(button: Button) -> void:
	# Feed the complete viewport/GUI path.  RewardPanel sits below a CanvasLayer,
	# so get_global_transform_with_canvas() is required when the test window uses
	# the project's 1280x720 override for a 960x540 logical viewport.
	var point: Vector2 = button.get_global_transform_with_canvas() * (button.size * 0.5)
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	get_root().push_input(motion, true)
	await process_frame
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.button_mask = MOUSE_BUTTON_MASK_LEFT
	down.pressed = true
	down.position = point
	down.global_position = point
	get_root().push_input(down, true)
	await process_frame
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = point
	up.global_position = point
	get_root().push_input(up, true)
	await process_frame
	await process_frame


func _tap_key(code: Key) -> void:
	var down := InputEventKey.new()
	down.keycode = code
	down.physical_keycode = code
	down.pressed = true
	Input.parse_input_event(down)
	await process_frame
	var up := down.duplicate() as InputEventKey
	up.pressed = false
	Input.parse_input_event(up)
	await process_frame
	await process_frame


func _snapshot() -> Dictionary:
	if not _flow_has("snapshot"):
		return {}
	var raw: Variant = _flow_call("snapshot")
	return raw as Dictionary if raw is Dictionary else {}


func _snapshot_source() -> String:
	return str(_snapshot().get("source", ""))


func _flow_has(method_name: String) -> bool:
	return is_instance_valid(flow) and flow.has_method(method_name)


func _flow_bool(method_name: String) -> bool:
	if not _flow_has(method_name):
		return false
	return bool(flow.call(method_name))


func _flow_call_bool(method_name: String, arg: Variant) -> bool:
	if not _flow_has(method_name):
		return false
	return bool(flow.call(method_name, arg))


func _flow_call(method_name: String, arg1: Variant = null, arg2: Variant = null) -> Variant:
	if not _flow_has(method_name):
		return null
	if arg1 == null:
		return flow.call(method_name)
	if arg2 == null:
		return flow.call(method_name, arg1)
	return flow.call(method_name, arg1, arg2)


func _frames(count: int) -> void:
	for _index in count:
		await process_frame


func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
		print("PASS: " + description)
	else:
		failed += 1
		print("FAIL: " + description)
