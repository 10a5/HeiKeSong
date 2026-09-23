extends SceneTree
## Godot --headless --path . --fixed-fps 60 --script tests/test_shop.gd
## Real-floor shop transitions, UI events, atomic transactions and run cleanup.

const TEST_SEED := 7331
var scene: Node3D
var player: CharacterBody3D
var deck: Node
var inventory: Node
var shop: Node
var panel: Control
var service: Node3D
var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	scene = load("res://floor_one.tscn").instantiate() as Node3D
	root.add_child(scene)
	await process_frame
	scene.set_process(false)
	scene.regenerate_floor(TEST_SEED)
	_sync()
	await _steps(3)
	await _test_enter_and_transition()
	await _test_transactions()
	await _test_equipment_and_sale()
	await _test_modal_inputs()
	await _test_reopen_and_backpack()
	await _test_cancel_transition()
	await _test_new_runs()
	shop.close()
	paused = false
	print("SHOP RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_enter_and_transition() -> void:
	_check(not shop.open_shop(service.building_id), "A distant shop cannot be opened through the public API")
	await _park_shop()
	_check(service.can_interact(), "The imported shop's real service anchor is reachable")
	var cards_before: int = deck.total_cards
	await _tap_key(KEY_E)
	_check(shop.is_open() and shop.is_transitioning() and scene.hud.matrix_transition.is_playing(), "Physical E begins the green digit transition before presenting the shop")
	_check(paused and scene.paused, "Entering the shop pauses the world throughout the transition")
	_check(scene.credits == 40 and deck.total_cards == cards_before and inventory.get_items().is_empty(), "Opening the shop never charges currency or grants an unsolicited purchase")
	var offers: Array = shop.snapshot()["offers"]
	_check(offers.size() == 6 and _offers_of_type("card").size() == 3 and _offers_of_type("implant").size() == 3, "Each shop stocks exactly three card instances and three accessories")
	_check(not shop.buy_offer(str(offers[0]["id"])) and scene.credits == 40, "Transactions are rejected while the digit transition is active")
	await _wait_ready()
	_check(panel.is_open() and not shop.is_transitioning() and not scene.hud.matrix_transition.visible, "Digit transition ends with the shop visible and world still paused")
	await _steps(60)
	_check(panel.get_node("ShopFrame/Offers").get_child_count() == 6, "The actual shop panel displays all six products")
	var all_revealed := true
	for entry: Dictionary in panel.get("_offers"):
		all_revealed = all_revealed and bool(entry["ready"]) and float(entry["material"].get_shader_parameter("blur_radius")) <= 0.01
	_check(all_revealed, "Product presentation resolves its blur into fully revealed cards and accessories")


func _test_transactions() -> void:
	var card: Dictionary = _offers_of_type("card")[0]
	var cards_before: Array = deck.get_card_snapshot()
	var hand_before: Array = deck.hand.duplicate(true)
	var money_before: int = scene.credits
	var buy_button: Button = panel.get_node("ShopFrame/Offers/Offer_%s/BuyButton" % card["id"])
	buy_button.pressed.emit()
	_check(scene.credits == money_before - int(card["price"]), "Clicking a product purchase button spends its displayed price")
	_check(deck.total_cards == cards_before.size() + 1 and deck.hand == hand_before, "A purchased card adds one physical copy without replacing the current hand")
	var previous_ids := {}
	for entry: Dictionary in cards_before:
		previous_ids[entry["id"]] = true
	var added: Array[Dictionary] = []
	for entry: Dictionary in deck.get_card_snapshot():
		if not previous_ids.has(entry["id"]):
			added.append(entry)
	_check(added.size() == 1 and added[0]["kind"] == card["kind"] and added[0]["zone"] == &"draw" and _deck_valid(), "The new card has a unique identity in the draw pile and conserves all old cards")
	_check(_offer(str(card["id"]))["sold"] and buy_button.disabled, "A purchased product becomes sold out in both stock and UI")
	var after_purchase := _financial_snapshot()
	_check(not shop.buy_offer(str(card["id"])) and _financial_snapshot() == after_purchase, "A double purchase of sold stock cannot charge or duplicate a card")
	_check(not shop.buy_offer("missing") and _financial_snapshot() == after_purchase, "An invalid offer identity leaves currency and ownership unchanged")
	scene.credits = 0
	var broke := _financial_snapshot()
	_check(not shop.buy_offer(str(_offers_of_type("card")[1]["id"])) and _financial_snapshot() == broke, "Insufficient funds preserve all inventory and card zones")
	scene.credits = 500
	var accessory: Dictionary = _offers_of_type("implant")[0]
	_check(shop.buy_offer(str(accessory["id"])), "An affordable accessory purchase succeeds")
	_check(scene.credits == 500 - int(accessory["price"]) and inventory.get_items().size() == 1 and inventory.get_equipped_count() == 1, "Accessory purchase spends once and automatically equips into a free slot")
	for _i in range(4):
		inventory.add_item("damage")
	var full_offer: Dictionary = _offers_of_type("implant")[1]
	var full_money: int = scene.credits
	_check(shop.buy_offer(str(full_offer["id"])) and scene.credits == full_money - int(full_offer["price"]), "Buying another accessory is allowed while all five slots are equipped")
	var items: Array[Dictionary] = inventory.get_items()
	_check(items.size() == 6 and inventory.get_equipped_count() == 5 and not items.back()["equipped"], "A sixth accessory goes into the backpack without granting a sixth bonus")
	_check(not shop.equip_item(int(items.back()["id"])) and inventory.get_equipped_count() == 5, "Shop equip controls enforce the five-accessory limit")


func _test_equipment_and_sale() -> void:
	var damage_item := {}
	for item: Dictionary in inventory.get_items():
		if item["kind"] == "damage" and item["equipped"]:
			damage_item = item
			break
	var item_id := int(damage_item["id"])
	var attack_before: float = player.get_attack_damage(10.0)
	_check(shop.unequip_item(item_id) and _near(player.get_attack_damage(10.0), attack_before - 2.0), "Shop unequip removes the accessory's attack bonus immediately")
	_check(shop.equip_item(item_id) and _near(player.get_attack_damage(10.0), attack_before), "Equipping an owned accessory restores exactly its original bonus")
	var money_before: int = scene.credits
	var owned_before: int = inventory.get_items().size()
	_check(shop.sell_item(item_id), "An owned equipped accessory can be sold from the shop")
	_check(scene.credits == money_before + int(damage_item["sell_price"]) and inventory.get_items().size() == owned_before - 1 and _near(player.get_attack_damage(10.0), attack_before - 2.0), "Selling pays the catalog sell price and removes both ownership and active bonus")
	var after_sale := _financial_snapshot()
	_check(not shop.sell_item(item_id) and not shop.sell_item(-123) and _financial_snapshot() == after_sale, "A stale or nonexistent item cannot be sold for repeated currency")
	_check(not shop.equip_item(item_id) and not shop.unequip_item(item_id), "An item sold from equipment cannot be reused by stale controls")


func _test_modal_inputs() -> void:
	var seed_before: int = scene.map_seed
	var camera_before := Vector3(scene.camera_yaw, scene.camera_pitch, scene.camera_distance)
	var position_before := player.global_position
	var energy_before: float = player.energy
	var hand_before: Array = deck.hand.duplicate(true)
	for code in [KEY_1, KEY_2, KEY_Q, KEY_SPACE, KEY_N, KEY_M, KEY_T, KEY_TAB, KEY_E]:
		await _tap_key(code)
	var mouse := InputEventMouseButton.new()
	mouse.position = Vector2(6, 6)
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = true
	Input.parse_input_event(mouse)
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(9, 9)
	motion.relative = Vector2(45, 35)
	Input.parse_input_event(motion)
	var release := mouse.duplicate() as InputEventMouseButton
	release.pressed = false
	Input.parse_input_event(release)
	var wheel := InputEventMouseButton.new()
	wheel.position = Vector2(6, 6)
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	Input.parse_input_event(wheel)
	await _steps(3)
	_check(shop.is_open() and panel.is_open() and scene.map_seed == seed_before, "N and other scene hotkeys cannot regenerate or dismiss the shop")
	_check(not scene.city_overlay.map_open and not scene.hud.is_browser_open() and not scene.hud.matrix_transition.is_playing(), "M, Tab and T cannot open competing overlays beneath the shop")
	_check(deck.hand == hand_before and _near(player.energy, energy_before) and player.cybernetic_time_left <= 0.0 and player.global_position.is_equal_approx(position_before), "Card keys, Q and Space cannot play actions, spend energy or move during shopping")
	_check(camera_before.is_equal_approx(Vector3(scene.camera_yaw, scene.camera_pitch, scene.camera_distance)) and not scene.get("_orbiting"), "Shop mouse clicks, dragging and scrolling do not leak to the game camera")


func _test_reopen_and_backpack() -> void:
	var stock: Array = shop.snapshot()["offers"].duplicate(true)
	await _tap_key(KEY_ESCAPE)
	_check(not shop.is_open() and not panel.visible and not paused and not scene.paused, "Escape closes the shop and resumes gameplay")
	await _park_shop()
	_check(shop.open_shop(service.building_id), "The same shop can be visited more than once")
	await _wait_ready()
	_check(shop.snapshot()["offers"] == stock, "Reopening preserves the exact stock and sold-out state instead of rerolling it")
	shop.close()
	_check(shop.open_inventory() and panel.is_open() and paused and shop.snapshot()["offers"].is_empty(), "The field inventory opens a paused equipment view without shop stock")
	var items: Array[Dictionary] = inventory.get_items()
	var money_before: int = scene.credits
	_check(not shop.sell_item(int(items[0]["id"])) and scene.credits == money_before, "Field equipment view cannot sell accessories for remote currency")
	_check(not shop.buy_offer(str(stock[0]["id"])), "Field equipment view cannot use a remembered shop offer")
	var equipped_id := -1
	for item in items:
		if item["equipped"]:
			equipped_id = int(item["id"])
			break
	_check(shop.unequip_item(equipped_id) and shop.equip_item(equipped_id), "Field inventory still permits changing the equipped loadout")
	await _tap_key(KEY_I)
	_check(not shop.is_open() and not paused, "I closes the equipment view and restores gameplay")


func _test_cancel_transition() -> void:
	await _park_shop()
	shop.open_shop(service.building_id)
	await _steps(2)
	await _tap_key(KEY_ESCAPE)
	await _steps(70)
	_check(not shop.is_open() and not panel.visible and not scene.hud.matrix_transition.is_playing() and not paused, "Cancelling during digit fade-in produces no delayed popup or retained pause")
	await _park_shop()
	shop.open_shop(service.building_id)
	for _i in range(60):
		if panel.visible:
			break
		await _steps(1)
	_check(panel.visible and shop.is_transitioning(), "The shop becomes covered and prepared before its transition fully completes")
	shop.close()
	await _steps(70)
	_check(not shop.is_open() and not panel.visible and not scene.hud.matrix_transition.is_playing(), "Cancelling between cover and reveal invalidates the pending reveal callback")


func _test_new_runs() -> void:
	await _park_shop()
	shop.open_shop(service.building_id)
	await _wait_ready()
	inventory.add_item("hand_slot")
	var old_seed: int = scene.map_seed
	await _tap_key(KEY_R)
	_sync()
	_check(scene.map_seed == old_seed and scene.credits == 40 and inventory.get_items().is_empty() and deck.hand_size == 4 and deck.total_cards == 10, "R from the shop resets purchases, accessories, slots and currency while preserving the map seed")
	await _steps(60)
	_check(not shop.is_open() and not panel.visible and not paused and not scene.hud.matrix_transition.is_playing(), "Retry cannot resurrect the previous modal or delayed transition")
	await _park_shop()
	_check(shop.open_shop(service.building_id), "A freshly reset run can enter its shop again")
	await _wait_ready()
	var stock: Array = shop.snapshot()["offers"]
	var sold_count := 0
	for entry: Dictionary in stock:
		if entry["sold"]:
			sold_count += 1
	_check(sold_count == 0, "Retry resets all shop sold-out flags")
	shop.buy_offer(str(_offers_of_type("card")[0]["id"]))
	inventory.add_item("hand_slot")
	shop.close()
	await _tap_key(KEY_N)
	_sync()
	_check(scene.map_seed != old_seed and scene.credits == 40 and inventory.get_items().is_empty() and deck.hand_size == 4 and deck.total_cards == 10, "N outside the modal starts a different map with no carried purchased cards or accessories")
	await _park_shop()
	_check(shop.open_shop(service.building_id), "The newly generated district also has an accessible working shop")
	shop.close()


func _sync() -> void:
	player = scene.player
	deck = scene.deck
	inventory = scene.inventory
	shop = scene.shop_system
	panel = scene.shop_panel
	for candidate in scene.services:
		if candidate.kind == "shop":
			service = candidate
			break
	for encounter in scene.encounters:
		encounter.set_physics_process(false)
	for target in get_nodes_in_group("combat_targets"):
		target.set_physics_process(false)


func _park_shop() -> void:
	shop.close()
	player.reset_player()
	player.global_position = service.global_position
	player.velocity = Vector3.ZERO
	await _steps(2)


func _wait_ready() -> void:
	for _i in range(160):
		if not shop.is_transitioning():
			return
		await _steps(1)
	_check(false, "Shop transition completes within its bounded duration")


func _offers_of_type(type: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for entry: Dictionary in shop.snapshot()["offers"]:
		if entry["type"] == type:
			result.append(entry)
	return result


func _offer(offer_id: String) -> Dictionary:
	for entry: Dictionary in shop.snapshot()["offers"]:
		if entry["id"] == offer_id:
			return entry
	return {}


func _financial_snapshot() -> Dictionary:
	return {"credits": scene.credits, "cards": deck.get_card_snapshot(), "items": inventory.get_items(), "offers": shop.snapshot()["offers"]}


func _deck_valid() -> bool:
	var seen := {}
	for entry: Dictionary in deck.get_card_snapshot():
		if seen.has(entry["id"]):
			return false
		seen[entry["id"]] = true
	return seen.size() == deck.total_cards


func _tap_key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	await _steps(1)
	event.pressed = false
	Input.parse_input_event(event)
	await _steps(1)


func _steps(count: int) -> void:
	for _i in range(count):
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
