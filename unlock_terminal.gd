extends Node3D
## A memory fragment adds previously inaccessible actions to the live deck.
## Proximity is checked in three dimensions, so a distant airborne player
## cannot activate a terminal merely by passing over its map position.

signal memory_restored(kinds: Array[String])

const LABEL_FONT = preload("res://assets/fonts/NotoSansSC-Regular.ttf")

@export var interaction_radius: float = 2.1
@export var interaction_height: float = 1.65

var card_kinds: Array[String] = []
var is_restored := false
var _player: CharacterBody3D
var _deck: Node
var _title := ""
var _preview := ""
var _color := Color.WHITE
var _title_label: Label3D
var _prompt_label: Label3D
var _fragment: Node3D
var _fragment_material: StandardMaterial3D
var _elapsed := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_build_terminal()


func setup(actor: CharacterBody3D, card_deck: Node, title: String, kinds: Array, preview: String, color: Color) -> void:
	_player = actor
	_deck = card_deck
	_title = title
	_preview = preview
	_color = color
	card_kinds.assign(kinds)
	refresh_state()


func can_interact() -> bool:
	if is_restored or not is_instance_valid(_player) or not is_instance_valid(_deck):
		return false
	if get_tree().paused or _player.is_dead or _player.is_action_locked():
		return false
	var offset := _player.global_position - global_position
	return absf(offset.y) <= interaction_height and Vector2(offset.x, offset.z).length() <= interaction_radius


func interact() -> bool:
	if not can_interact():
		return false
	var restored: Array[String] = []
	for kind in card_kinds:
		if bool(_deck.call("unlock_kind", kind)):
			restored.append(kind)
	refresh_state()
	if restored.is_empty():
		return false
	_player.status_changed.emit("%s已恢复 · +%d 张" % [_title, restored.size()], false)
	memory_restored.emit(restored)
	return true


func refresh_state() -> void:
	if not is_instance_valid(_deck):
		return
	is_restored = true
	for kind in card_kinds:
		if not bool(_deck.call("is_kind_unlocked", kind)):
			is_restored = false
			break
	_title_label.text = _title + (" · 已恢复" if is_restored else "")
	_title_label.modulate = Color("9aabae") if is_restored else _color
	_fragment_material.albedo_color = Color("71838c") if is_restored else _color
	_fragment_material.emission = _fragment_material.albedo_color
	_fragment_material.emission_energy_multiplier = 0.12 if is_restored else 0.65
	_prompt_label.visible = false
	_fragment.rotation = Vector3.ZERO
	_fragment.position.y = 1.25


func _process(delta: float) -> void:
	_elapsed += delta
	var nearby := can_interact()
	_prompt_label.visible = nearby
	if nearby:
		_prompt_label.text = "E  恢复记忆\n" + _preview
	if not is_restored:
		_fragment.position.y = 1.25 + sin(_elapsed * 2.0) * 0.07
		_fragment.rotation.y += delta * 0.65


func _build_terminal() -> void:
	var body := StaticBody3D.new()
	body.name = "Pedestal"
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	var pedestal_shape := CylinderShape3D.new()
	pedestal_shape.radius = 0.48
	pedestal_shape.height = 0.72
	var collision := CollisionShape3D.new()
	collision.shape = pedestal_shape
	collision.position.y = 0.36
	body.add_child(collision)
	var pedestal_material := StandardMaterial3D.new()
	pedestal_material.albedo_color = Color("334751")
	pedestal_material.roughness = 0.7
	var pedestal_mesh := CylinderMesh.new()
	pedestal_mesh.top_radius = 0.4
	pedestal_mesh.bottom_radius = 0.48
	pedestal_mesh.height = 0.72
	pedestal_mesh.radial_segments = 8
	var pedestal := MeshInstance3D.new()
	pedestal.mesh = pedestal_mesh
	pedestal.material_override = pedestal_material
	pedestal.position.y = 0.36
	body.add_child(pedestal)
	_fragment_material = StandardMaterial3D.new()
	_fragment_material.emission_enabled = true
	_fragment_material.roughness = 0.4
	_fragment = Node3D.new()
	_fragment.name = "MemoryFragment"
	add_child(_fragment)
	for index in range(3):
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.38, 0.54, 0.055)
		var fragment := MeshInstance3D.new()
		fragment.mesh = mesh
		fragment.material_override = _fragment_material
		fragment.position = Vector3((index - 1) * 0.11, 0.0, (index - 1) * 0.07)
		fragment.rotation_degrees.z = (index - 1) * -13.0
		_fragment.add_child(fragment)
	_title_label = _make_label("Title", Vector3(0.0, 2.00, 0.0), 29, 0.005)
	_prompt_label = _make_label("Prompt", Vector3(0.0, 2.54, 0.0), 25, 0.004)
	_prompt_label.visible = false


func _make_label(node_name: String, location: Vector3, size: int, pixel_size: float) -> Label3D:
	var label := Label3D.new()
	label.name = node_name
	label.position = location
	label.font = LABEL_FONT
	label.font_size = size
	label.pixel_size = pixel_size
	label.outline_size = 5
	label.outline_modulate = Color("14212e")
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = false
	add_child(label)
	return label
