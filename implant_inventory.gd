extends Node
## Owned accessories have stable identities; only equipped items grant bonuses.

signal changed()

const CATALOG = preload("res://implant_catalog.gd")
const MAX_EQUIPPED: int = 5
const BASE_HAND_SIZE: int = 4

var player: CharacterBody3D
var deck: Node
var _items: Array[Dictionary] = []
var _next_item_id: int = 1


func setup(actor: CharacterBody3D, card_deck: Node) -> void:
	player = actor
	deck = card_deck
	_refresh_bonuses()


func add_item(kind: String) -> int:
	if not CATALOG.has_kind(kind):
		return -1
	var item_id := _next_item_id
	_next_item_id += 1
	_items.append({"id": item_id, "kind": kind, "equipped": get_equipped_count() < MAX_EQUIPPED})
	_refresh_bonuses()
	return item_id


func equip_item(item_id: int) -> bool:
	var index := _find_item(item_id)
	if index < 0 or bool(_items[index]["equipped"]) or get_equipped_count() >= MAX_EQUIPPED:
		return false
	_items[index]["equipped"] = true
	_refresh_bonuses()
	return true


func unequip_item(item_id: int) -> bool:
	var index := _find_item(item_id)
	if index < 0 or not bool(_items[index]["equipped"]):
		return false
	_items[index]["equipped"] = false
	_refresh_bonuses()
	return true


func remove_item(item_id: int) -> bool:
	var index := _find_item(item_id)
	if index < 0:
		return false
	_items.remove_at(index)
	_refresh_bonuses()
	return true


func get_items() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for instance in _items:
		var item := CATALOG.get_item(str(instance["kind"]))
		item["id"] = int(instance["id"])
		item["equipped"] = bool(instance["equipped"])
		result.append(item)
	return result


func get_equipped_count() -> int:
	var count := 0
	for item in _items:
		if bool(item["equipped"]):
			count += 1
	return count


func reset_inventory() -> void:
	_items.clear()
	# IDs are never reused: a stale sale/equip button cannot target a new item.
	_refresh_bonuses()


func _find_item(item_id: int) -> int:
	for index in range(_items.size()):
		if int(_items[index]["id"]) == item_id:
			return index
	return -1


func _refresh_bonuses() -> void:
	var bonuses := {
		"damage_bonus": 0.0,
		"damage_reduction_multiplier": 1.0,
		"move_speed_bonus": 0.0,
		"energy_capacity_bonus": 0.0,
		"energy_regen_bonus": 0.0,
	}
	var extra_slots := 0
	for item in _items:
		if not bool(item["equipped"]):
			continue
		match str(item["kind"]):
			"hand_slot": extra_slots += 1
			"damage": bonuses["damage_bonus"] += 0.2
			"armor": bonuses["damage_reduction_multiplier"] *= 0.8
			"move_speed": bonuses["move_speed_bonus"] += 0.2
			"energy_capacity": bonuses["energy_capacity_bonus"] += 0.2
			"energy_regen": bonuses["energy_regen_bonus"] += 0.2
	if is_instance_valid(player):
		player.apply_implant_bonuses(bonuses)
	if is_instance_valid(deck):
		deck.set_hand_size(BASE_HAND_SIZE + extra_slots)
	changed.emit()
