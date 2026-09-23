extends SceneTree
## Godot --headless --path . --fixed-fps 60 --script tests/test_implants.gd
## Exercise real inventory, hand zones and combat consequences of accessories.

const PLAYER = preload("res://player.gd")
const DECK = preload("res://deck.gd")
const ENEMY = preload("res://enemy.gd")
const INVENTORY = preload("res://implant_inventory.gd")
const CATALOG = preload("res://implant_catalog.gd")

var scene: Node3D
var player: CharacterBody3D
var enemy: CharacterBody3D
var deck: Node
var inventory: Node
var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	scene = Node3D.new()
	root.add_child(scene)
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60.0, 1.0, 60.0)
	floor_shape.shape = box
	floor_body.position.y = -0.5
	floor_body.add_child(floor_shape)
	scene.add_child(floor_body)
	player = PLAYER.new()
	player.spawn_position = Vector3.ZERO
	scene.add_child(player)
	player.set_physics_process(false)
	deck = DECK.new()
	scene.add_child(deck)
	deck.setup(player, 42)
	deck.set_physics_process(false)
	inventory = INVENTORY.new()
	scene.add_child(inventory)
	inventory.setup(player, deck)
	enemy = ENEMY.new()
	enemy.spawn_position = Vector3(0.0, 0.0, -1.0)
	scene.add_child(enemy)
	enemy.combat_enabled = false
	enemy.set_physics_process(false)
	await _steps(2)
	_test_inventory()
	_test_stats_and_energy()
	_test_slots()
	_test_armor()
	await _test_attacks()
	await _test_movement()
	print("IMPLANTS RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_inventory() -> void:
	_check(CATALOG.kinds().size() == 6, "All six accessory effects have shop definitions")
	for kind in CATALOG.kinds():
		var item := CATALOG.get_item(kind)
		_check(item["kind"] == kind and int(item["price"]) > int(item["sell_price"]) and int(item["sell_price"]) > 0, "%s has a valid identity and buy/sell prices" % kind)
	_check(inventory.add_item("unknown") == -1 and inventory.get_items().is_empty(), "Unknown accessories cannot enter the inventory")
	var ids: Array[int] = []
	for _i in range(6):
		ids.append(inventory.add_item("damage"))
	_check(inventory.get_items().size() == 6 and inventory.get_equipped_count() == 5, "Five purchased accessories auto-equip and a sixth remains in the backpack")
	_check(_near(player.get_attack_damage(10.0), 20.0), "Five damage accessories add 100 percent of base damage")
	_check(not inventory.equip_item(ids[5]), "The sixth accessory cannot equip into a full loadout")
	_check(inventory.unequip_item(ids[0]) and _near(player.get_attack_damage(10.0), 18.0), "Unequipping immediately removes exactly one additive bonus")
	_check(inventory.equip_item(ids[5]) and _near(player.get_attack_damage(10.0), 20.0), "A backpack accessory can occupy the newly opened slot")
	_check(not inventory.equip_item(ids[5]) and not inventory.unequip_item(ids[0]), "Repeated equip and unequip requests cannot duplicate bonuses")
	var snapshot: Array[Dictionary] = inventory.get_items()
	snapshot[0]["equipped"] = true
	snapshot[0]["name"] = "changed"
	_check(not bool(inventory.get_items()[0]["equipped"]) and inventory.get_items()[0]["name"] != "changed", "Inventory snapshots cannot mutate live ownership or catalog metadata")
	_check(inventory.remove_item(ids[5]) and _near(player.get_attack_damage(10.0), 18.0), "Selling an equipped item removes its bonus before payout")
	_check(not inventory.remove_item(ids[5]), "A sold identity cannot be sold twice")
	inventory.reset_inventory()
	_check(inventory.get_items().is_empty() and _near(player.get_attack_damage(10.0), 10.0), "Reset clears items and restores unmodified damage")
	var next_id: int = inventory.add_item("armor")
	_check(next_id > ids[5] and not inventory.remove_item(ids[0]), "Reset never reuses old identities, protecting against stale shop controls")
	inventory.reset_inventory()


func _test_stats_and_energy() -> void:
	var base_move: float = player.move_speed
	var base_roll: float = player.roll_speed
	var base_dash: float = player.dash_speed
	var base_jump: float = player.jump_speed
	player.energy = 4.0
	inventory.add_item("move_speed")
	inventory.add_item("move_speed")
	var capacity_id: int = inventory.add_item("energy_capacity")
	inventory.add_item("energy_regen")
	inventory.add_item("energy_regen")
	_check(_near(player.move_speed, base_move * 1.4), "Two speed accessories add forty percent of base walking speed")
	_check(_near(player.roll_speed, base_roll) and _near(player.dash_speed, base_dash) and _near(player.jump_speed, base_jump), "Speed accessories preserve authored roll, dash and jump speeds")
	_check(_near(player.max_energy, 12.0) and _near(player.energy, 4.0), "Energy capacity increases without granting free energy")
	_check(_near(player.energy_regen_per_second, 2.8), "Two regeneration accessories add forty percent of base recovery")
	player._physics_process(0.5)
	_check(_near(player.energy, 5.4), "The live player update restores energy at the equipped rate")
	player.energy = 12.0
	_check(inventory.unequip_item(capacity_id) and _near(player.max_energy, 10.0) and _near(player.energy, 10.0), "Removing capacity clamps current energy to the lower maximum")
	inventory.equip_item(capacity_id)
	_check(_near(player.energy, 10.0), "Re-equipping a battery does not refund previously clamped energy")
	inventory.reset_inventory()
	_check(_near(player.move_speed, base_move) and _near(player.max_energy, 10.0) and _near(player.energy_regen_per_second, 2.0), "Removing all accessories restores authored movement and energy values")
	for _i in range(8):
		var item_id: int = inventory.add_item("move_speed")
		inventory.remove_item(item_id)
	_check(_near(player.move_speed, base_move), "Repeated purchase and sale cycles never compound or drift the movement baseline")


func _test_slots() -> void:
	var original_count: int = deck.total_cards
	var slot_ids: Array[int] = []
	for _i in range(5):
		slot_ids.append(inventory.add_item("hand_slot"))
	_check(deck.hand_size == 9 and deck.hand.size() == 9, "Five cognitive accessories expand four hand slots to nine")
	_check(deck.get_card_snapshot().size() == original_count, "Expanding a hand neither duplicates nor destroys physical cards")
	inventory.remove_item(slot_ids[0])
	_check(deck.hand_size == 8 and deck.get_card_snapshot().size() == original_count, "Selling a slot accessory safely returns its held card to the deck")
	inventory.reset_inventory()
	_check(deck.hand_size == 4 and deck.get_card_snapshot().size() == original_count, "Reset restores four slots while conserving every card")
	paused = true
	var item_id: int = inventory.add_item("hand_slot")
	_check(deck.hand_size == 5 and deck.hand[4].is_empty(), "Buying a cognitive accessory while shopping creates a paused empty slot")
	paused = false
	deck._physics_process(deck.refill_delay + 0.01)
	_check(not deck.hand[4].is_empty(), "The new slot draws normally when gameplay resumes")
	inventory.remove_item(item_id)


func _test_armor() -> void:
	_reset_pair()
	inventory.add_item("armor")
	player.add_shield(10.0)
	player.take_damage(20.0)
	_check(_near(player.health, 94.0) and _near(player.shield, 0.0), "Armor reduces twenty damage to sixteen before ten shield absorbs it")
	_reset_pair()
	inventory.add_item("armor")
	inventory.add_item("armor")
	player.take_damage(20.0)
	_check(_near(player.health, 87.2), "Two armor layers compound to a 0.64 incoming damage multiplier")
	player.add_shield(30.0)
	player.is_rolling = true
	player.become_lost()
	_check(player.is_dead and _near(player.health, 0.0) and _near(player.shield, 0.0), "Deep water remains lethal through armor, shield and rolling immunity")
	_reset_pair()
	player.take_damage(20.0)
	_check(_near(player.health, 80.0), "Removing armor restores ordinary incoming damage")


func _test_attacks() -> void:
	for entry in [{"kind": "punch", "damage": 14.4}, {"kind": "slash", "damage": 30.0}, {"kind": "sweep", "damage": 26.4}, {"kind": "charged_slash", "damage": 54.0}, {"kind": "airborne_slash", "damage": 24.0}]:
		_reset_pair()
		inventory.add_item("damage")
		player.request_card(str(entry["kind"]))
		if str(entry["kind"]) == "charged_slash":
			player._update_charge(0.3)
		_check(_near(enemy.health, 100.0 - float(entry["damage"])), "%s applies the equipped damage bonus to its actual hit" % entry["kind"])
	_reset_pair()
	inventory.add_item("damage")
	enemy.global_position = Vector3(1.0, 0.0, 0.0)
	player.request_card("front_kick")
	player._update_visual_timers(0.79)
	_check(_near(enemy.health, 100.0), "A damage accessory does not bypass the roundhouse's 0.8-second delay")
	player._update_visual_timers(0.02)
	_check(_near(enemy.health, 40.0), "The delayed roundhouse area hit receives the damage bonus")
	_reset_pair()
	inventory.add_item("damage")
	player.request_card("dash_slash")
	player.global_position = Vector3(0.0, 0.0, -2.0)
	player._apply_dash_path_hits(Vector3.ZERO)
	_check(_near(enemy.health, 46.0), "Dash path damage receives the attack bonus")
	player._start_slash_visual(Vector3.BACK, true)
	_check(_near(enemy.health, 46.0), "The boosted dash endpoint cannot damage a path target twice")
	_reset_pair()
	inventory.add_item("damage")
	await _steps(2)
	player.request_card("shot")
	_check(_near(enemy.health, 78.4), "The ranged shot receives the same attack bonus")
	_reset_pair()
	inventory.add_item("damage")
	player._physics_process(1.0 / 60.0)
	player.is_diving = true
	player.dive_startup_left = 0.0
	player.dive_direction = Vector3.FORWARD
	player._advance_dive(1.0 / 60.0)
	_check(_near(enemy.health, 28.0), "The landing dive area hit receives the attack bonus")


func _test_movement() -> void:
	_reset_pair()
	enemy.global_position = Vector3(10.0, 0.0, 10.0)
	inventory.add_item("move_speed")
	Input.action_press("move_up")
	player._physics_process(1.0 / 60.0)
	_check(_near(Vector2(player.velocity.x, player.velocity.z).length(), 6.6), "Ordinary movement uses the accessory's increased speed")
	player.activate_cybernetic()
	player._physics_process(1.0 / 60.0)
	_check(_near(Vector2(player.velocity.x, player.velocity.z).length(), 11.88), "The Q burst multiplies the already enhanced walking speed")
	Input.action_release("move_up")
	_reset_pair()
	await _steps(1)


func _reset_pair() -> void:
	paused = false
	inventory.reset_inventory()
	player.reset_player()
	player.set_physics_process(false)
	enemy.reset_enemy()
	enemy.set_physics_process(false)


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
