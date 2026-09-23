extends Node
## Shared reward flow for street combat and factory discoveries.
## It pauses the owning floor, shows the choice under the Matrix transition, and
## only commits the selected item when the player presses a button.

const PANEL = preload("res://reward_panel.gd")
const CARDS = preload("res://card_catalog.gd")
const IMPLANTS = preload("res://implant_catalog.gd")

var _controller: Node
var _hud: Control
var _deck: Node
var _inventory: Node
var panel: Control
var _open := false
var _previous_paused := false
var _pending: Dictionary = {}
var _token := 0
var _covered_callback: Callable
var _finished_callback: Callable
var _queue: Array[Dictionary] = []
var _claiming := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)


func setup(controller: Node, canvas: CanvasLayer, floor_hud: Control, card_deck: Node, implant_inventory: Node) -> void:
	_controller = controller
	_hud = floor_hud
	_deck = card_deck
	_inventory = implant_inventory
	if is_instance_valid(panel):
		panel.queue_free()
	panel = PANEL.new()
	panel.name = "RewardPanel"
	canvas.add_child(panel)
	panel.card_selected.connect(_on_card_selected)
	panel.implant_selected.connect(_on_implant_selected)
	panel.skipped.connect(_on_skipped)


func is_open() -> bool:
	return _open


func is_transitioning() -> bool:
	return _open and is_instance_valid(_hud) and _hud.is_matrix_transition_playing()


func snapshot() -> Dictionary:
	return {"open": _open, "source": str(_pending.get("source", "")), "reward": _pending.get("reward", {}).duplicate(true), "queued": _queue.size()}


func open_reward(source: String, reward: Dictionary) -> bool:
	if _open or not _can_present() or not _valid_reward(reward):
		return false
	_open = true
	_pending = {"source": source, "reward": reward.duplicate(true)}
	_previous_paused = bool(_controller.get("paused"))
	_controller.set("paused", true)
	get_tree().paused = true
	_controller.set("_orbiting", false)
	_hud.set_paused(true)
	for name in ["pause", "pause_hint"]:
		var node := _hud.get_node_or_null(name)
		if node:
			node.hide()
	var shade: Variant = _hud.get("_pause_shade")
	if shade is CanvasItem:
		shade.hide()
	_token += 1
	var token := _token
	var effect: Control = _hud.matrix_transition
	_covered_callback = _on_covered.bind(token)
	effect.covered.connect(_covered_callback, CONNECT_ONE_SHOT)
	effect.play_in(0.24)
	return true


func enqueue_reward(source: String, reward: Dictionary) -> bool:
	if not _valid_reward(reward):
		return false
	# Present after the complete hit loop, so an AOE can defeat several enemies
	# without its first reward pausing damage to the remaining targets.
	_queue.append({"source": source, "reward": reward.duplicate(true)})
	set_process(true)
	return true


func _process(_delta: float) -> void:
	if _open or bool(_controller.paused):
		return
	_open_next_queued()


func _can_present() -> bool:
	if not is_instance_valid(_controller) or not is_instance_valid(_hud) or _controller.player.is_dead:
		return false
	if _hud.is_browser_open():
		return false
	var shop: Node = _controller.get("shop_system")
	if is_instance_valid(shop) and shop.is_open():
		return false
	return not (_controller.has_method("is_city_map_open") and _controller.is_city_map_open())


func _valid_reward(reward: Dictionary) -> bool:
	match str(reward.get("type", "")):
		"card":
			var raw: Variant = reward.get("options", [])
			if not raw is Array or raw.size() != 2:
				return false
			return raw[0] != raw[1] and CARDS.has_kind(str(raw[0])) and CARDS.has_kind(str(raw[1]))
		"implant":
			return IMPLANTS.has_kind(str(reward.get("kind", "")))
	return false


func choose_card(index: int) -> bool:
	if not _open or _claiming or _controller.player.is_dead or _is_revealing() or str(_pending.get("reward", {}).get("type", "")) != "card":
		return false
	var options: Array = _pending["reward"].get("options", [])
	if index < 0 or index >= options.size():
		return false
	var kind := str(options[index])
	_claiming = true
	var accepted := is_instance_valid(_deck) and bool(_deck.call("add_reward_card", kind))
	if accepted:
		_finish("获得卡牌：%s" % CARDS.card_name(kind))
	_claiming = false
	return accepted


func choose_implant() -> bool:
	if not _open or _claiming or _controller.player.is_dead or _is_revealing() or str(_pending.get("reward", {}).get("type", "")) != "implant":
		return false
	var kind := str(_pending["reward"].get("kind", ""))
	_claiming = true
	var accepted := is_instance_valid(_inventory) and int(_inventory.call("add_item", kind)) >= 0
	if accepted:
		_finish("获得义体：%s" % IMPLANTS.get_item(kind).get("name", kind))
	_claiming = false
	return accepted


func skip() -> bool:
	if not _open or _claiming:
		return false
	_finish("已跳过奖励")
	return true


func _is_revealing() -> bool:
	return is_instance_valid(_hud) and _hud.has_method("is_matrix_transition_playing") and _hud.is_matrix_transition_playing()


func make_card_reward(seed_value: int = -1) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	if seed_value >= 0:
		rng.seed = seed_value
	else:
		rng.randomize()
	var pool: Array[String] = CARDS.kinds()
	var options: Array[String] = []
	while not pool.is_empty() and options.size() < 2:
		var index := rng.randi_range(0, pool.size() - 1)
		options.append(pool.pop_at(index))
	return {"type": "card", "options": options}


func make_implant_reward(seed_value: int = -1) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	if seed_value >= 0:
		rng.seed = seed_value
	else:
		rng.randomize()
	var kinds: Array[String] = IMPLANTS.kinds()
	return {"type": "implant", "kind": kinds[rng.randi_range(0, kinds.size() - 1)]} if not kinds.is_empty() else {}


func make_random_reward(seed_value: int = -1) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	if seed_value >= 0:
		rng.seed = seed_value
	else:
		rng.randomize()
	return make_card_reward(rng.randi()) if rng.randi_range(0, 1) == 0 else make_implant_reward(rng.randi())


func reset() -> void:
	_queue.clear()
	set_process(false)
	if _open:
		_close_now()
	_pending.clear()
	_token += 1


func _open_next_queued() -> void:
	if _queue.is_empty():
		set_process(false)
		return
	if _open or not _can_present():
		return
	var next: Dictionary = _queue.pop_front()
	open_reward(str(next.get("source", "enemy")), next.get("reward", {}))


func _on_covered(token: int) -> void:
	if not _open or token != _token:
		return
	panel.open_reward(str(_pending.get("source", "enemy")), _pending.get("reward", {}), _inventory.get_equipped_count())
	panel.set_interactive(false)
	_finished_callback = _on_revealed.bind(token)
	_hud.matrix_transition.finished.connect(_finished_callback, CONNECT_ONE_SHOT)
	# Reveal the selected reward while the Matrix layer fades away.
	_hud.matrix_transition.play_out(0.34)


func _on_revealed(token: int) -> void:
	if _open and token == _token:
		panel.set_interactive(true)


func _on_card_selected(index: int) -> void:
	choose_card(index)


func _on_implant_selected() -> void:
	choose_implant()


func _on_skipped() -> void:
	skip()


func _finish(message: String) -> void:
	if not _open:
		return
	if is_instance_valid(_controller) and _controller.has_method("message"):
		_controller.call("message", message)
	elif is_instance_valid(_controller):
		_controller.player.status_changed.emit(message, false)
	_close_now()


func _close_now() -> void:
	_token += 1
	_open = false
	_pending.clear()
	if is_instance_valid(_hud):
		var effect: Control = _hud.matrix_transition
		if _covered_callback.is_valid() and effect.covered.is_connected(_covered_callback):
			effect.covered.disconnect(_covered_callback)
		if _finished_callback.is_valid() and effect.finished.is_connected(_finished_callback):
			effect.finished.disconnect(_finished_callback)
		_covered_callback = Callable()
		_finished_callback = Callable()
	if is_instance_valid(panel):
		panel.close_reward()
	if is_instance_valid(_hud):
		_hud.matrix_transition.stop()
	if is_instance_valid(_controller):
		_controller.set("paused", _previous_paused)
		_controller.set("_orbiting", false)
	get_tree().paused = _previous_paused
	if is_instance_valid(_hud):
		_hud.set_paused(_previous_paused)
