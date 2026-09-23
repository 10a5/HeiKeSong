extends Node3D
## A shallow, visual-only water sheet for the imported Boss arena.
## The GLB remains the only collision source; this node adds waves and contact
## ripples without creating an invisible floor or boundary of its own.

const WATER_SHADER = preload("res://materials/boss_water.gdshader")
const RIPPLE_CAPACITY := 16
const RIPPLE_LIFETIME := 2.2
const STEP_DISTANCE := 0.72
const STEP_INTERVAL := 0.12

var surface: MeshInstance3D
var material: ShaderMaterial
var water_rect := Rect2()
var wave_time := 0.0
var ripples := PackedVector4Array()
var actors: Array[Node3D] = []
var _next_ripple := 0
var _last_positions: Dictionary = {}
var _was_touching: Dictionary = {}
var _travel_since_ripple: Dictionary = {}
var _ripple_cooldown: Dictionary = {}


func setup(center: Vector3, size: Vector2, tilt_degrees: float, height: float) -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	water_rect = Rect2(center.x - size.x * 0.5, center.z - size.y * 0.5, size.x, size.y)
	ripples.resize(RIPPLE_CAPACITY)
	ripples.fill(Vector4.ZERO)
	material = ShaderMaterial.new()
	material.shader = WATER_SHADER
	material.set_shader_parameter("water_color", Color("347c89"))
	material.set_shader_parameter("water_alpha", 0.26)
	surface = MeshInstance3D.new()
	surface.name = "BossWaterSurface"
	var plane := PlaneMesh.new()
	plane.size = size
	plane.subdivide_width = 8
	plane.subdivide_depth = 8
	surface.mesh = plane
	surface.material_override = material
	surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(surface)
	# `center` is a world-space point. Use global_position so a BossArena
	# placed at a translated origin (as in the first-floor transition) does not
	# offset the overlay twice.
	surface.global_position = Vector3(center.x, height, center.z)
	surface.rotation_degrees.x = tilt_degrees
	_upload()


func align_to_surface(center: Vector3) -> void:
	if not is_instance_valid(surface):
		return
	surface.global_position.y = center.y + 0.035


func set_actors(next_actors: Array) -> void:
	actors.clear()
	_last_positions.clear()
	_was_touching.clear()
	_travel_since_ripple.clear()
	_ripple_cooldown.clear()
	for candidate in next_actors:
		if candidate is Node3D and is_instance_valid(candidate):
			var actor := candidate as Node3D
			actors.append(actor)
			var key := actor.get_instance_id()
			_last_positions[key] = actor.global_position
			_was_touching[key] = false
			_travel_since_ripple[key] = 0.0
			_ripple_cooldown[key] = 0.0


func add_actor(actor: Node3D) -> void:
	var next := actors.duplicate()
	if actor != null:
		next.append(actor)
	set_actors(next)


func _physics_process(delta: float) -> void:
	wave_time += delta
	for index in range(ripples.size()):
		var ripple := ripples[index]
		if ripple.w > 0.0:
			ripple.z += delta
			if ripple.z >= RIPPLE_LIFETIME:
				ripple.w = 0.0
			ripples[index] = ripple
	for actor in actors:
		if is_instance_valid(actor):
			_track_actor(actor, delta)
	_upload()


func _track_actor(actor: Node3D, delta: float) -> void:
	var key := actor.get_instance_id()
	var at := actor.global_position
	var previous: Vector3 = _last_positions.get(key, at)
	var offset := at - previous
	var distance := Vector2(offset.x, offset.z).length()
	var grounded := true
	if actor.has_method("is_on_floor"):
		grounded = bool(actor.call("is_on_floor"))
	var touching := grounded and water_rect.has_point(Vector2(at.x, at.z))
	var cooldown := maxf(0.0, float(_ripple_cooldown.get(key, 0.0)) - delta)
	_ripple_cooldown[key] = cooldown
	var travel := float(_travel_since_ripple.get(key, 0.0))
	if touching:
		if not bool(_was_touching.get(key, false)):
			_emit_ripple(at, 0.9, key)
		elif distance > 0.002:
			travel += distance
			if travel >= STEP_DISTANCE and cooldown <= 0.0:
				_emit_ripple(at, clampf(0.60 + distance / maxf(delta, 0.001) * 0.03, 0.60, 1.20), key)
		else:
			travel = 0.0
	else:
		travel = 0.0
	_was_touching[key] = touching
	_last_positions[key] = at
	_travel_since_ripple[key] = travel


func _emit_ripple(at: Vector3, strength: float, actor_key: int) -> void:
	ripples[_next_ripple] = Vector4(at.x, at.z, 0.0, strength)
	_next_ripple = (_next_ripple + 1) % RIPPLE_CAPACITY
	# Only the actor that generated the ripple needs a movement cooldown. The
	# shared shader pool still allows the player and Boss to leave overlapping
	# rings without allocating a node per footstep.
	_ripple_cooldown[actor_key] = STEP_INTERVAL
	_travel_since_ripple[actor_key] = 0.0


func _upload() -> void:
	if material == null:
		return
	material.set_shader_parameter("wave_time", wave_time)
	material.set_shader_parameter("ripple_data", ripples)
