extends Node
## Shop stock, atomic transactions and modal/transition lifetime.
## The floor owns gold; the deck and implant inventory own the purchased items.

const CARDS = preload("res://card_catalog.gd")
const IMPLANTS = preload("res://implant_catalog.gd")

var _controller: Node
var _panel: Control
var _inventory: Node
var _deck: Node
var _stocks: Dictionary = {}
var _mode: StringName = &"closed"
var _shop_id := -1
var _busy := false
var _transaction := false
var _previous_paused := false
var _message := ""
var _token := 0
var _covered_callback: Callable
var _finished_callback: Callable


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func setup(controller: Node, panel: Control, inventory: Node, card_deck: Node) -> void:
	_controller = controller
	_panel = panel
	_inventory = inventory
	_deck = card_deck
	_panel.close_requested.connect(close)
	_panel.buy_requested.connect(buy_offer)
	_panel.equip_requested.connect(equip_item)
	_panel.unequip_requested.connect(unequip_item)
	_panel.sell_requested.connect(sell_item)


func is_open() -> bool:
	return _mode != &"closed"


func is_shop_open() -> bool:
	return _mode == &"shop"


func is_transitioning() -> bool:
	return _busy


func open_shop(building_id: int) -> bool:
	if not _can_open() or not _controller.has_method("is_shop_building"):
		return false
	# The public entry point still requires an actual nearby service anchor.
	if not _controller.is_shop_building(building_id):
		return false
	_shop_id = building_id
	_ensure_stock(building_id)
	_mode = &"shop"
	_message = "购买的卡牌进入抽牌堆；配件有空位时自动装备。"
	_begin_modal()
	_busy = true
	_token += 1
	var effect: Control = _controller.hud.matrix_transition
	_covered_callback = _on_covered.bind(_token)
	effect.covered.connect(_covered_callback, CONNECT_ONE_SHOT)
	effect.play_in(0.26)
	return true


func open_inventory() -> bool:
	if not _can_open():
		return false
	_mode = &"inventory"
	_shop_id = -1
	_message = "最多装备五件配件；出售请前往商店。"
	_begin_modal()
	_panel.open_inventory(snapshot())
	return true


func _can_open() -> bool:
	var rewards: Node = _controller.get("reward_flow") if is_instance_valid(_controller) else null
	if is_instance_valid(rewards) and rewards.is_open():
		return false
	if is_open() or not is_instance_valid(_controller) or _controller.player.is_dead:
		return false
	if _controller.player.is_action_locked() or _controller.hud.is_browser_open():
		return false
	if _controller.has_method("is_city_map_open") and _controller.is_city_map_open():
		return false
	return true


func _begin_modal() -> void:
	_previous_paused = _controller.paused
	_controller.paused = true
	get_tree().paused = true
	_controller.set("_orbiting", false)
	_controller.hud.set_paused(true)
	# The shop itself supplies the pause presentation.
	for name in ["pause", "pause_hint"]:
		_controller.hud.get_node(name).hide()
	_controller.hud.get("_pause_shade").hide()


func _on_covered(token: int) -> void:
	if token != _token or not is_shop_open():
		return
	_panel.open_shop(snapshot())
	get_tree().create_timer(0.18, true).timeout.connect(_reveal_shop.bind(token))


func _reveal_shop(token: int) -> void:
	if token != _token or not is_shop_open():
		return
	var effect: Control = _controller.hud.matrix_transition
	_finished_callback = _on_transition_finished.bind(token)
	effect.finished.connect(_finished_callback, CONNECT_ONE_SHOT)
	effect.play_out(0.36)


func _on_transition_finished(token: int) -> void:
	if token == _token and is_shop_open():
		_busy = false


func close() -> void:
	if not is_open():
		return
	_token += 1
	var effect: Control = _controller.hud.matrix_transition
	if _covered_callback.is_valid() and effect.covered.is_connected(_covered_callback):
		effect.covered.disconnect(_covered_callback)
	if _finished_callback.is_valid() and effect.finished.is_connected(_finished_callback):
		effect.finished.disconnect(_finished_callback)
	effect.stop()
	_panel.close_panel()
	_mode = &"closed"
	_busy = false
	_shop_id = -1
	_controller.paused = _previous_paused
	get_tree().paused = _previous_paused
	_controller.set("_orbiting", false)
	_controller.hud.set_paused(_previous_paused)


func reset_run() -> void:
	close()
	_token += 1
	_stocks.clear()
	_message = ""


func snapshot() -> Dictionary:
	return {
		"credits": int(_controller.get("credits")) if _controller.has_method("is_shop_building") else 0,
		"equipped_count": _inventory.get_equipped_count(),
		"items": _inventory.get_items(),
		"offers": _stocks.get(_shop_id, []).duplicate(true) if is_shop_open() else [],
		"message": _message,
		# Start the goods reveal as the digit mask clears, keeping its blur
		# visible to the player instead of finishing it behind the black mask.
		"reveal_delay": 0.48 if _busy else 0.0,
		"stats": {
			"hand_size": _deck.hand_size,
			"damage_multiplier": _controller.player.implant_damage_multiplier,
			"damage_taken_multiplier": _controller.player.implant_damage_reduction_multiplier,
			"move_speed": _controller.player.move_speed,
			"max_energy": _controller.player.max_energy,
			"energy_regen": _controller.player.energy_regen_per_second,
		},
	}


func _refresh() -> void:
	if is_open():
		_panel.refresh(snapshot())


func _ensure_stock(building_id: int) -> void:
	if _stocks.has(building_id):
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = int(_controller.map_seed) * 10007 + building_id * 7919 + 1337
	var card_kinds := CARDS.kinds()
	var implant_kinds := IMPLANTS.kinds()
	var offers: Array[Dictionary] = []
	for index in 3:
		var kind: String = card_kinds.pop_at(rng.randi_range(0, card_kinds.size() - 1))
		var offer := CARDS.get_card(kind)
		offer.merge({"id": "%d_card_%d" % [building_id, index], "type": "card", "price": 24 if CARDS.category(kind) == "hybrid" else (18 if CARDS.category(kind) == "movement" else 16), "sold": false}, true)
		offers.append(offer)
	for index in 3:
		var kind: String = implant_kinds.pop_at(rng.randi_range(0, implant_kinds.size() - 1))
		var offer := IMPLANTS.get_item(kind)
		offer.merge({"id": "%d_implant_%d" % [building_id, index], "type": "implant", "sold": false}, true)
		offers.append(offer)
	_stocks[building_id] = offers


func buy_offer(offer_id: String) -> bool:
	if not is_shop_open() or _busy or _transaction or _controller.player.is_dead:
		return false
	var offers: Array = _stocks.get(_shop_id, [])
	for offer: Dictionary in offers:
		if str(offer["id"]) != offer_id:
			continue
		if bool(offer["sold"]):
			return false
		var price := int(offer["price"])
		if int(_controller.credits) < price:
			_message = "金币不足，还需要 %d 金币。" % (price - int(_controller.credits))
			_refresh()
			return false
		_transaction = true
		# No awaits: a double-click cannot spend twice or reuse a sold offer.
		_controller.credits -= price
		var accepted: bool
		if offer["type"] == "card":
			accepted = _deck.add_purchased_card(str(offer["kind"]))
		else:
			accepted = int(_inventory.add_item(str(offer["kind"]))) >= 0
		if accepted:
			offer["sold"] = true
			_message = "已购入：%s" % str(offer["name"])
		else:
			_controller.credits += price
		_transaction = false
		_refresh()
		return accepted
	return false


func equip_item(item_id: int) -> bool:
	if not is_open() or _busy or _transaction:
		return false
	var accepted: bool = _inventory.equip_item(item_id)
	_message = "配件已装备。" if accepted else "最多装备五件，请先卸下一个配件。"
	_refresh()
	return accepted


func unequip_item(item_id: int) -> bool:
	if not is_open() or _busy or _transaction:
		return false
	var accepted: bool = _inventory.unequip_item(item_id)
	_message = "配件已放入背包。" if accepted else "无法卸下该配件。"
	_refresh()
	return accepted


func sell_item(item_id: int) -> bool:
	if not is_shop_open() or _busy or _transaction or _controller.player.is_dead:
		return false
	for item: Dictionary in _inventory.get_items():
		if int(item["id"]) != item_id:
			continue
		_transaction = true
		var accepted: bool = _inventory.remove_item(item_id)
		if accepted:
			_controller.credits += int(item["sell_price"])
			_message = "已出售 %s · +%d 金币" % [item["name"], item["sell_price"]]
		_transaction = false
		_refresh()
		return accepted
	return false
