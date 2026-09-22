extends Node
## Visual-only water motion. The shelf colliders still decide standing/sinking.

const RIPPLE_CAPACITY := 16
const RIPPLE_LIFETIME := 2.2
const STEP_DISTANCE := 0.75
const STEP_INTERVAL := 0.12

var material: ShaderMaterial
var actor: Node3D
var land_rect := Rect2()
var surface_height := -0.12
var wave_time := 0.0
var ripples := PackedVector4Array()
var _next_ripple := 0
var _last_position := Vector3.ZERO
var _was_touching := false
var _travel_since_ripple := 0.0
var _ripple_cooldown := 0.0


func setup(water_material: ShaderMaterial, dry_land: Rect2, water_height: float) -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	material = water_material
	land_rect = dry_land
	surface_height = water_height
	ripples.resize(RIPPLE_CAPACITY)
	ripples.fill(Vector4.ZERO)
	_upload()


func follow_actor(water_actor: Node3D) -> void:
	actor = water_actor
	_last_position = actor.global_position
	_was_touching = false
	_travel_since_ripple = 0.0


func _physics_process(delta: float) -> void:
	if material == null:
		return
	wave_time += delta
	_ripple_cooldown = maxf(0.0, _ripple_cooldown - delta)
	for index in range(ripples.size()):
		var ripple := ripples[index]
		if ripple.w > 0.0:
			ripple.z += delta
			if ripple.z >= RIPPLE_LIFETIME:
				ripple.w = 0.0
			ripples[index] = ripple
	if is_instance_valid(actor):
		_track_contact(delta)
	_upload()


func _track_contact(delta: float) -> void:
	var at := actor.global_position
	var offset := at - _last_position
	var distance := Vector2(offset.x, offset.z).length()
	# The actor origin is at its feet. Above the surface means airborne;
	# once the whole body is submerged it can no longer disturb the surface.
	var touching := not land_rect.has_point(Vector2(at.x, at.z)) \
		and at.y <= surface_height + 0.04 and at.y >= surface_height - 1.65
	if touching:
		if not _was_touching or distance > 8.0:
			var fall_speed := maxf(0.0, -offset.y / maxf(delta, 0.001))
			_emit_ripple(at, clampf(0.75 + fall_speed * 0.045, 0.75, 1.25))
		elif distance > 0.002:
			_travel_since_ripple += distance
			if _travel_since_ripple >= STEP_DISTANCE and _ripple_cooldown <= 0.0:
				var speed := distance / maxf(delta, 0.001)
				_emit_ripple(at, clampf(0.55 + speed * 0.035, 0.6, 1.15))
	else:
		_travel_since_ripple = 0.0
	_was_touching = touching
	_last_position = at


func _emit_ripple(at: Vector3, strength: float) -> void:
	# A fixed pool prevents allocations or a growing list during long walks.
	ripples[_next_ripple] = Vector4(at.x, at.z, 0.0, strength)
	_next_ripple = (_next_ripple + 1) % RIPPLE_CAPACITY
	_travel_since_ripple = 0.0
	_ripple_cooldown = STEP_INTERVAL


func _upload() -> void:
	material.set_shader_parameter("wave_time", wave_time)
	material.set_shader_parameter("ripple_data", ripples)
