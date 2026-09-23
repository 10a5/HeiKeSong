extends Node3D
## A street-level service marker. The city generator owns building geometry.

const CATALOG = preload("res://card_catalog.gd")
const UI_FONT = preload("res://assets/fonts/NotoSansSC-Regular.ttf")
const COLORS := {
	"residential": Color("728795"), "shop": Color("ffbd72"),
	"factory": Color("bba2ef"), "medical": Color("74edba"),
	"police": Color("79baff")
}
const NAMES := {"residential": "住宅", "shop": "商店", "factory": "工厂", "medical": "医疗站", "police": "公安局"}

@export var interaction_radius := 2.2
var kind := "residential"
var building_id: int = 0
var used := false
var event_index := 0
var data: Dictionary = {}
var _player: CharacterBody3D
var _deck: Node
var _controller: Node
var _label: Label3D
var _prompt: Label3D
var _material: StandardMaterial3D


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_build_marker()
	_update_marker()


func setup(building_data: Dictionary, actor: CharacterBody3D, card_deck: Node, floor_controller: Node) -> void:
	data = building_data.duplicate(true)
	kind = str(data.get("kind", "residential"))
	building_id = int(data.get("id", 0))
	_player = actor
	_deck = card_deck
	_controller = floor_controller
	position = data.get("door_position", data.get("position", Vector3.ZERO))
	var rng := RandomNumberGenerator.new()
	rng.seed = int(_controller.get("map_seed")) * 1009 + building_id * 7919 + 31
	event_index = rng.randi_range(0, 2)
	_update_marker()


func can_interact() -> bool:
	if kind == "residential" or (used and kind != "shop"):
		return false
	return _is_nearby()


func _is_nearby() -> bool:
	if not is_instance_valid(_player) or not is_instance_valid(_controller) or not is_instance_valid(_deck):
		return false
	if not is_inside_tree() or get_tree().paused or _player.is_dead or _player.is_action_locked():
		return false
	var offset := _player.global_position - global_position
	return absf(offset.y) <= 1.6 and Vector2(offset.x, offset.z).length() <= interaction_radius


func interact() -> bool:
	if not can_interact():
		return false
	match kind:
		"shop":
			if _has_locked_cards():
				if not bool(_controller.call("spend_credits", 20)):
					_message("信用不足 · 需要 20", true)
					return false
				var unlocked := str(_controller.call("unlock_next_card"))
				if unlocked.is_empty():
					_controller.call("add_credits", 20)
					return false
				_message("购得记忆：%s" % CATALOG.card_name(unlocked))
			else:
				if _player.energy >= _player.max_energy:
					_message("能量已满")
					return false
				if not bool(_controller.call("spend_credits", 10)):
					_message("信用不足 · 需要 10", true)
					return false
				_refill_energy()
				_message("补给完成 · 能量已满")
		"medical":
			var restored := float(_controller.call("restore_health", 40.0))
			if restored <= 0.0:
				_message("生命已满 · 医疗补给仍保留")
				return false
			used = true
			_message("治疗完成 · 生命 +%.0f" % restored)
		"factory":
			used = true
			match event_index:
				0:
					_controller.call("add_credits", 15)
					_message("找到留存信用 · +15")
				1:
					_refill_energy()
					_message("接通备用电源 · 能量已满")
				2:
					var unlocked := str(_controller.call("unlock_next_card"))
					if unlocked.is_empty():
						_controller.call("add_credits", 15)
						_message("记忆已齐全 · 回收信用 +15")
					else:
						_message("找回记忆：%s" % CATALOG.card_name(unlocked))
		"police":
			used = true
			var unlocked := str(_controller.call("unlock_next_card"))
			_controller.call("add_credits", 20)
			_message("装备箱 · %s / 信用 +20" % CATALOG.card_name(unlocked) if not unlocked.is_empty() else "装备箱 · 信用 +20")
		_:
			return false
	_update_marker()
	return true


func reset_service() -> void:
	used = false
	_update_marker()


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


func _process(_delta: float) -> void:
	if not is_instance_valid(_prompt):
		return
	var nearby := _is_nearby() and kind != "residential"
	_prompt.visible = nearby
	_label.visible = nearby
	if not nearby:
		return
	if used and kind != "shop":
		_prompt.text = "已使用"
		return
	match kind:
		"shop": _prompt.text = "E  购买记忆 · 20 信用" if _has_locked_cards() else "E  能量补给 · 10 信用"
		"medical": _prompt.text = "E  免费治疗 · +40 生命"
		"factory": _prompt.text = "E  搜索遗留物"
		"police": _prompt.text = "E  打开装备箱"


func _update_marker() -> void:
	if not is_instance_valid(_label):
		return
	visible = kind != "residential"
	_label.text = str(NAMES.get(kind, kind))
	_label.visible = false
	_prompt.visible = false
	var accent: Color = COLORS.get(kind, Color.WHITE)
	_material.albedo_color = accent.darkened(0.65) if used else accent
	_material.emission = accent
	_material.emission_energy_multiplier = 0.05 if used else 0.5
	_label.modulate = Color("92a2ab") if used else accent


func _build_marker() -> void:
	_material = StandardMaterial3D.new()
	_material.emission_enabled = true
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var ring_mesh := CylinderMesh.new()
	ring_mesh.top_radius = 0.62
	ring_mesh.bottom_radius = 0.62
	ring_mesh.height = 0.035
	ring_mesh.radial_segments = 16
	var ring := MeshInstance3D.new()
	ring.name = "ServiceMarker"
	ring.mesh = ring_mesh
	ring.position.y = 0.05
	ring.material_override = _material
	add_child(ring)
	var sign_mesh := BoxMesh.new()
	sign_mesh.size = Vector3(0.32, 0.45, 0.10)
	var sign := MeshInstance3D.new()
	sign.mesh = sign_mesh
	sign.position.y = 1.10
	sign.material_override = _material
	add_child(sign)
	_label = _make_label("ServiceName", Vector3(0.0, 1.85, 0.0), 29)
	_prompt = _make_label("ServicePrompt", Vector3(0.0, 2.25, 0.0), 24)


func _make_label(node_name: String, at: Vector3, font_size: int) -> Label3D:
	var label := Label3D.new()
	label.name = node_name
	label.position = at
	label.font = UI_FONT
	label.font_size = font_size
	label.pixel_size = 0.004
	label.outline_size = 5
	label.outline_modulate = Color("10202a")
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(label)
	return label
