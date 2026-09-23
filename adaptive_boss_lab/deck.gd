extends Node
## Physical card instances circulate between three disjoint zones.
## An empty hand slot refills after a short delay, drawing without replacement.

signal piles_changed()
signal card_drawn(card: Dictionary, slot: int)
signal card_discarded(card: Dictionary, slot: int)
signal reshuffled(count: int)
signal card_unlocked(kind: String)

const CATALOG = preload("res://card_catalog.gd")

const STARTING_KINDS: Array[String] = [
	"slash", "slash", "slash",
	"shield", "shield", "shield",
	"roll", "roll",
	"dash_slash", "front_kick"
]

@export var refill_delay: float = 1.0

var hand_size: int = 4
var total_cards: int = STARTING_KINDS.size()
var hand: Array[Dictionary] = []
var draw_pile: Array[Dictionary] = []
var discard_pile: Array[Dictionary] = []
var refill_time_left: Array[float] = []
var player: CharacterBody3D
var _rng := RandomNumberGenerator.new()
var _playing := false
var _unlocked_kinds: Array[String] = CATALOG.STARTING_UNLOCKS.duplicate()
var _next_card_id := STARTING_KINDS.size()


func _ready() -> void:
	# Main keeps processing camera/pause controls while the deck must freeze.
	process_mode = Node.PROCESS_MODE_PAUSABLE


func setup(actor: CharacterBody3D, seed_value: int = -1) -> void:
	player = actor
	reset_deck(seed_value)


func is_kind_unlocked(kind: String) -> bool:
	return kind in _unlocked_kinds


func unlock_kind(kind: String) -> bool:
	if not CATALOG.has_kind(kind) or is_kind_unlocked(kind):
		return false
	_unlocked_kinds.append(kind)
	draw_pile.append({"id": _next_card_id, "kind": kind})
	_next_card_id += 1
	total_cards += 1
	card_unlocked.emit(kind)
	piles_changed.emit()
	return true


func get_catalog_snapshot() -> Array[Dictionary]:
	# A discovery entry is a card type, not an extra physical card in a pile.
	var result: Array[Dictionary] = []
	for kind in CATALOG.kinds():
		var entry := CATALOG.get_card(kind)
		entry["unlocked"] = is_kind_unlocked(kind)
		entry["zone"] = &"catalog"
		result.append(entry)
	return result


func get_card_snapshot(view: StringName = &"all") -> Array[Dictionary]:
	# Viewing cards never draws, shuffles, sorts a live pile, or advances the RNG.
	var result: Array[Dictionary] = []
	if view not in [&"all", &"draw", &"discard"]:
		return result
	for zone: StringName in [&"hand", &"draw", &"discard"]:
		if view != &"all" and view != zone:
			continue
		var source: Array[Dictionary] = hand if zone == &"hand" else (draw_pile if zone == &"draw" else discard_pile)
		for index in range(source.size()):
			if source[index].is_empty():
				continue
			var card := source[index].duplicate(true)
			card["zone"] = zone
			if zone == &"hand":
				card["hand_slot"] = index
			result.append(card)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if str(a["kind"]) != str(b["kind"]):
			return str(a["kind"]) < str(b["kind"])
		return int(a["id"]) < int(b["id"])
	)
	return result


func reset_deck(seed_value: int = -1) -> void:
	if seed_value >= 0:
		_rng.seed = seed_value
	else:
		_rng.randomize()
	_playing = false
	hand.clear()
	draw_pile.clear()
	discard_pile.clear()
	refill_time_left.clear()
	for slot in range(hand_size):
		hand.append({})
		refill_time_left.append(0.0)
	for index in range(STARTING_KINDS.size()):
		draw_pile.append({"id": index, "kind": STARTING_KINDS[index]})
	_next_card_id = STARTING_KINDS.size()
	for kind in _unlocked_kinds:
		if kind not in CATALOG.STARTING_UNLOCKS:
			draw_pile.append({"id": _next_card_id, "kind": kind})
			_next_card_id += 1
	total_cards = draw_pile.size()
	for slot in range(hand_size):
		draw_to_slot(slot)
	piles_changed.emit()


func _physics_process(delta: float) -> void:
	for slot in range(hand_size):
		if refill_time_left[slot] > 0.0:
			refill_time_left[slot] = maxf(0.0, refill_time_left[slot] - delta)
			if refill_time_left[slot] <= 0.0:
				draw_to_slot(slot)


func play_slot(slot: int) -> bool:
	if _playing or get_tree().paused or not is_instance_valid(player):
		return false
	if slot < 0 or slot >= hand.size() or hand[slot].is_empty():
		return false
	var card: Dictionary = hand[slot]
	# Actor validation is the single source of truth for costs and action locks.
	# Failed actions leave all card zones and refill timers untouched.
	_playing = true
	var accepted: bool = player.request_card(str(card["kind"]))
	if accepted:
		hand[slot] = {}
		discard_pile.append(card)
		refill_time_left[slot] = maxf(0.0, refill_delay)
		card_discarded.emit(card.duplicate(), slot)
		piles_changed.emit()
		if refill_delay <= 0.0:
			draw_to_slot(slot)
	_playing = false
	return accepted


func draw_to_slot(slot: int) -> bool:
	if get_tree().paused or slot < 0 or slot >= hand.size() or not hand[slot].is_empty():
		return false
	# Recycling is demand-driven: an empty pile alone does not cause a shuffle.
	if draw_pile.is_empty():
		if discard_pile.is_empty():
			return false
		draw_pile.append_array(discard_pile)
		discard_pile.clear()
		# Shuffle only the discard pile; cards still held are never included.
		for index in range(draw_pile.size() - 1, 0, -1):
			var other := _rng.randi_range(0, index)
			var temporary: Dictionary = draw_pile[index]
			draw_pile[index] = draw_pile[other]
			draw_pile[other] = temporary
		reshuffled.emit(draw_pile.size())
	var random_index := _rng.randi_range(0, draw_pile.size() - 1)
	var card: Dictionary = draw_pile.pop_at(random_index)
	hand[slot] = card
	refill_time_left[slot] = 0.0
	card_drawn.emit(card.duplicate(), slot)
	piles_changed.emit()
	return true
