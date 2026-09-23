extends Node3D
## Invisible service anchor. The city generator owns building geometry.

const CATALOG = preload("res://card_catalog.gd")
const IMPLANTS = preload("res://implant_catalog.gd")
## Kept as data for the 2D city map legend; these colors are no longer used
## for any world-space sign, ring or building stripe.
const COLORS := {
	"residential": Color("728795"), "shop": Color("ffbd72"),
	"factory": Color("bba2ef"), "medical": Color("74edba"),
	"police": Color("79baff")
}
const NAMES := {"residential": "住宅", "shop": "商店", "factory": "工厂", "medical": "医疗站", "police": "公安局"}
## The former ring, sign and floating labels are intentionally gone.  E is
## accepted when the player is close to the imported model's actual footprint.
@export var interaction_radius := 1.15
var kind := "residential"
var building_id: int = 0
var used := false
var event_index := 0
var data: Dictionary = {}
var _player: CharacterBody3D
var _deck: Node
var _controller: Node
var _interaction_center := Vector3.ZERO
var _interaction_half_extents := Vector2(7.0, 5.0)
var _interaction_rotation_y := 0.0
## Factory rewards are generated when the district is generated, so opening the
## same seeded map always presents the same choices.  The reward itself is
## claimed by floor_one's modal; no card or implant is added before the player
## makes that choice.
var reward_type: StringName = &""
var reward_card_options: Array[String] = []
var reward_implant_kind := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE


func setup(building_data: Dictionary, actor: CharacterBody3D, card_deck: Node, floor_controller: Node) -> void:
	data = building_data.duplicate(true)
	kind = str(data.get("kind", "residential"))
	building_id = int(data.get("id", 0))
	_player = actor
	_deck = card_deck
	_controller = floor_controller
	_interaction_center = data.get("interaction_center", data.get("position", Vector3.ZERO))
	_interaction_half_extents = data.get("interaction_half_extents", Vector2(7.0, 5.0))
	_interaction_rotation_y = float(data.get("interaction_rotation_y", 0.0))
	interaction_radius = float(data.get("interaction_radius", interaction_radius))
	# Keep this invisible node outside the model for nearest-service sorting.
	# The proximity test below uses the actual model bounds instead.
	position = data.get("interaction_position", _interaction_center)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(_controller.get("map_seed")) * 1009 + building_id * 7919 + 31
	# Factories have exactly two reward outcomes.  The seeded choice keeps a
	# retried district deterministic while still making each generated district
	# vary between card and implant discoveries.
	event_index = rng.randi_range(0, 1)
	reward_type = &""
	reward_card_options.clear()
	reward_implant_kind = ""
	if event_index == 0:
		reward_type = &"card"
		var cards := CATALOG.kinds()
		for _index in range(2):
			var picked_index := rng.randi_range(0, cards.size() - 1)
			reward_card_options.append(str(cards.pop_at(picked_index)))
	else:
		reward_type = &"implant"
		var implants := IMPLANTS.kinds()
		if not implants.is_empty():
			reward_implant_kind = str(implants[rng.randi_range(0, implants.size() - 1)])


func can_interact() -> bool:
	if kind == "residential" or (used and kind != "shop"):
		return false
	return _is_nearby()


func _is_nearby() -> bool:
	if not is_instance_valid(_player) or not is_instance_valid(_controller) or not is_instance_valid(_deck):
		return false
	if not is_inside_tree() or get_tree().paused or _player.is_dead or _player.is_action_locked():
		return false
	var offset := _player.global_position - _interaction_center
	if absf(offset.y) > 1.6:
		return false
	# Measure distance in the rotated building frame, matching its model/collider.
	offset = offset.rotated(Vector3.UP, -_interaction_rotation_y)
	# Distance to a model footprint, not to an arbitrary marker in the street.
	# Standing inside a real recessed entrance is also considered nearby.
	var dx := maxf(absf(offset.x) - _interaction_half_extents.x, 0.0)
	var dz := maxf(absf(offset.z) - _interaction_half_extents.y, 0.0)
	return Vector2(dx, dz).length() <= interaction_radius


func interact() -> bool:
	if not can_interact():
		return false
	match kind:
		"shop":
			return bool(_controller.call("open_shop", building_id))
		"medical":
			var restored := float(_controller.call("restore_health", 40.0))
			if restored <= 0.0:
				_message("生命已满 · 医疗补给仍保留")
				return false
			used = true
			if _controller.has_method("record_facility_entry"):
				_controller.call("record_facility_entry", &"medical")
			_message("治疗完成 · 生命 +%.0f" % restored)
		"factory":
			match event_index:
				0:
					# The floor owns the modal, pause state and final grant.  Marking
					# this service used only after the modal opened prevents a failed
					# open (for example while another overlay is active) from consuming
					# the one-time factory reward.
					if reward_card_options.size() < 2 or not _controller.has_method("open_reward"):
						return false
					var opened := bool(_controller.call("open_reward", "factory", {
						"type": "card",
						"options": reward_card_options.duplicate(),
					}))
					if not opened:
						return false
					used = true
					if _controller.has_method("record_facility_entry"):
						_controller.call("record_facility_entry", &"factory")
				1:
					if reward_implant_kind.is_empty() or not _controller.has_method("open_reward"):
						return false
					var opened := bool(_controller.call("open_reward", "factory", {
						"type": "implant",
						"kind": reward_implant_kind,
					}))
					if not opened:
						return false
					used = true
					if _controller.has_method("record_facility_entry"):
						_controller.call("record_facility_entry", &"factory")
		"police":
			used = true
			var unlocked := str(_controller.call("unlock_next_card"))
			_controller.call("add_credits", 20)
			_message("装备箱 · %s / 金币 +20" % CATALOG.card_name(unlocked) if not unlocked.is_empty() else "装备箱 · 金币 +20")
		_:
			return false
	return true


func reset_service() -> void:
	used = false


func _has_locked_cards() -> bool:
	for card_kind in CATALOG.kinds():
		if not bool(_deck.call("is_kind_unlocked", card_kind)):
			return true
	return false


func _refill_energy() -> void:
	_player.energy = _player.max_energy
	_player.energy_changed.emit(_player.energy, _player.max_energy)


func _message(text: String, is_error := false) -> void:
	_controller.call("message", text, is_error)
