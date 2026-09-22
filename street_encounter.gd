extends Node3D
## One encounter belongs to one graph edge, not to an interior building cell.

const ENEMY = preload("res://enemy.gd")
var state: StringName = &"dormant"
var foe: CharacterBody3D
var data: Dictionary = {}
var _actor: CharacterBody3D
var _floor: Node
var _axis := Vector3.RIGHT
var _half_length := 12.0
var _marker: MeshInstance3D
var _material: StandardMaterial3D


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE


func setup(edge: Dictionary, actor: CharacterBody3D, controller: Node) -> void:
	data = edge.duplicate(true)
	_actor = actor
	_floor = controller
	global_position = data["position"]
	_axis = data["axis"]
	_half_length = Vector3(data["endpoint_a"]).distance_to(data["endpoint_b"]) * 0.5
	foe = ENEMY.new()
	foe.name = "StreetGuard"
	foe.display_name = "街道守卫"
	foe.spawn_position = global_position
	foe.aggro_range = 12.0
	foe.combat_enabled = false
	add_child(foe)
	foe.setup(actor)
	foe.defeated.connect(_on_cleared)
	_marker = MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.7
	ring.outer_radius = 0.78
	ring.rings = 24
	ring.ring_segments = 6
	_marker.mesh = ring
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color("d6a361")
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_marker.material_override = _material
	_marker.position.y = 0.035
	add_child(_marker)


func _physics_process(_delta: float) -> void:
	if not is_instance_valid(foe) or state == &"cleared":
		return
	if _actor.is_dead:
		foe.combat_enabled = false
		return
	var offset := _actor.global_position - global_position
	var along := offset.dot(_axis)
	var across := (offset - _axis * along).length()
	var nearby := absf(along) < _half_length - 1.25 and across < 3.8 and absf(offset.y) < 2.6
	if state == &"dormant" and nearby:
		state = &"active"
		_material.albedo_color = Color("fb8966")
	foe.combat_enabled = nearby and state == &"active"
	# This prototype keeps each guard on its original street. No teleporting
	# through buildings to chase a player who takes a different street.
	if not nearby and foe.global_position.distance_to(foe.spawn_position) > 0.2:
		foe.global_position = foe.spawn_position
		foe.velocity = Vector3.ZERO
	var guard_offset := foe.global_position - global_position
	var guard_along := clampf(guard_offset.dot(_axis), -_half_length + 0.6, _half_length - 0.6)
	var side := Vector3(-_axis.z, 0.0, _axis.x)
	var guard_across := clampf(guard_offset.dot(side), -3.35, 3.35)
	var bounded := global_position + _axis * guard_along + side * guard_across
	foe.global_position.x = bounded.x
	foe.global_position.z = bounded.z


func _on_cleared() -> void:
	if state == &"cleared":
		return
	state = &"cleared"
	foe.combat_enabled = false
	_material.albedo_color = Color("78cfb1")
	_floor.encounter_cleared()
