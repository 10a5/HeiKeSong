extends Node3D
## One encounter is anchored to a graph edge, while a boxer may pursue beyond
## that edge before disengaging at its own detection limit.

const VARIANT_ENEMY = preload("res://enemy_variant.gd")
## Cyan completion colour for a finished encounter. The same value is used by
## the world ring below and by the city map's cleared dot, so "sniper nest
## cleared" reads identically in the street and on the overview map.
const CLEARED_MARKER_COLOR := Color("42f6e0")
const CLEARED_MARKER_EMISSION := Color("16d9d0")
var state: StringName = &"dormant"
var foe: CharacterBody3D
var data: Dictionary = {}
var _actor: CharacterBody3D
var _floor: Node
var _axis := Vector3.RIGHT
var _half_length := 12.0
var _half_width := 4.0
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
	_half_width = float(data.get("road_width", 8.0)) * 0.5
	# New procedural floors carry a seeded role on each street edge. Older
	# hand-authored encounters without a field resolve to the sword default.
	var enemy_type := StringName(str(data.get("enemy_type", "sword")))
	foe = VARIANT_ENEMY.new()
	foe.name = "StreetGuard_%s" % String(enemy_type)
	foe.configure_variant(enemy_type)
	# Per-floor scaling is applied before the foe enters the tree so its very
	# first reset already carries the scaled pool. The defaults keep every other
	# caller at the first floor's street numbers.
	var health_scale := float(data.get("enemy_health_multiplier", 1.0))
	var damage_scale := float(data.get("enemy_damage_multiplier", 1.0))
	if foe.has_method("apply_stat_multipliers"):
		foe.apply_stat_multipliers(health_scale, damage_scale)
	foe.spawn_position = global_position
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
	_sync_marker_visibility()


func _physics_process(_delta: float) -> void:
	_sync_marker_visibility()
	if not is_instance_valid(foe) or state == &"cleared":
		return
	if not is_instance_valid(_actor) or _actor.is_dead:
		_end_combat()
		return
	var is_boxer: bool = foe.get_variant_kind() == &"boxer"
	var is_sniper: bool = foe.get_variant_kind() == &"sniper"
	var nearby := _sniper_can_engage() if is_sniper else (_boxer_can_engage() if is_boxer else _player_on_street())
	if state == &"dormant" and nearby:
		state = &"active"
		_material.albedo_color = Color("fb8966")
	elif state == &"active" and not nearby:
		_end_combat()
	foe.combat_enabled = nearby and state == &"active"
	# No transform writes on disengagement. A boxer can leave its original
	# segment to close its full detection distance; move_and_slide still keeps
	# it outside solid buildings. The sniper never leaves its nest, so clamping
	# it to a street rectangle would only fight the sentry controller.
	if not foe.combat_enabled or is_boxer or is_sniper:
		return
	var guard_offset := foe.global_position - global_position
	var guard_along := clampf(guard_offset.dot(_axis), -_half_length + 0.6, _half_length - 0.6)
	var side := Vector3(-_axis.z, 0.0, _axis.x)
	var lateral_limit := maxf(0.5, _half_width - 0.65)
	var guard_across := clampf(guard_offset.dot(side), -lateral_limit, lateral_limit)
	var bounded := global_position + _axis * guard_along + side * guard_across
	foe.global_position.x = bounded.x
	foe.global_position.z = bounded.z


func _sync_marker_visibility() -> void:
	# The fixed street marker must not disclose a concealed enemy's spawn point.
	if is_instance_valid(_marker):
		_marker.visible = state == &"cleared" or (is_instance_valid(foe) and foe.is_fully_revealed())


## Whether the city map may plot this encounter's position. A sniper sentry
## answers no while it is still under its optical cloak: its dot would hand the
## player exactly the nest the cloak exists to hide. A hit that exposes it also
## puts it on the map — red while the encounter is unfinished, and the ordinary
## cyan cleared dot once it is defeated. The 遭遇 n/8 counter always tracks it.
func shows_on_city_map() -> bool:
	if not is_instance_valid(foe):
		return true
	# A finished encounter always belongs on the map, whatever killed it.
	if state == &"cleared":
		return true
	if not foe.has_method("is_permanently_revealed"):
		return true
	return bool(foe.call("is_permanently_revealed"))


func _player_on_street() -> bool:
	var offset := _actor.global_position - global_position
	var along := offset.dot(_axis)
	var across := (offset - _axis * along).length()
	return absf(along) < _half_length - 1.25 and across < _half_width - 0.2 and absf(offset.y) < 2.6


func _boxer_can_engage() -> bool:
	# Range is measured from the current enemy, not the old encounter marker.
	# Seeing a player on an adjacent stretch of road can start a pursuit.
	var offset := _actor.global_position - foe.global_position
	var distance := Vector2(offset.x, offset.z).length()
	# A boxer wakes at its original 10 m activation radius, then gets a
	# forgiving 20 m leash while already engaged. Crossing the leash ends the
	# encounter in place; returning inside activation range can wake it again.
	var max_range: float = float(foe.boxer_leash_range if state == &"active" else foe.aggro_range)
	if absf(offset.y) >= 2.6 or distance > max_range:
		return false
	if state == &"active":
		return true
	var ray := PhysicsRayQueryParameters3D.create(
		foe.global_position + Vector3.UP * 1.0,
		_actor.global_position + Vector3.UP * 1.0, 1
	)
	ray.exclude = [foe.get_rid(), _actor.get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(ray).is_empty()


func _sniper_can_engage() -> bool:
	# The sentry never leaves its nest, so its own firing range — not the old
	# street rectangle — decides when it wakes. That is deliberately the same
	# number the controller uses for the range prompt, so the warning appears
	# exactly when the rifle is armed, never earlier and never without a threat.
	# Beyond it the encounter keeps a short leash band so pacing on the boundary
	# cannot flicker the prompt.
	var offset := _actor.global_position - foe.global_position
	var distance := Vector2(offset.x, offset.z).length()
	var max_range: float = float(foe.aggro_range if state == &"active" else foe.sniper_max_distance)
	if absf(offset.y) >= 2.6 or distance > max_range:
		return false
	if state == &"active":
		return true
	var ray := PhysicsRayQueryParameters3D.create(
		foe.global_position + Vector3.UP * 1.0,
		_actor.global_position + Vector3.UP * 1.0, 1
	)
	ray.exclude = [foe.get_rid(), _actor.get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(ray).is_empty()


func _end_combat() -> void:
	if state == &"active" or foe.combat_enabled:
		foe.disengage()
	state = &"dormant"
	_material.albedo_color = Color("d6a361")
	_material.emission_enabled = false


func _on_cleared() -> void:
	if state == &"cleared":
		return
	state = &"cleared"
	foe.combat_enabled = false
	# A defeated sentry leaves a cyan "already cleared" point on the map. The
	# world ring and the city-map dot share this colour, so a sniper nest the
	# player has beaten reads as finished instead of as an open threat.
	_material.albedo_color = CLEARED_MARKER_COLOR
	_material.emission_enabled = true
	_material.emission = CLEARED_MARKER_EMISSION
	_material.emission_energy_multiplier = 2.4
	_sync_marker_visibility()
	# The floor awards credits and opens the one-time Matrix reward choice.
	# Passing this encounter lets the floor derive a stable seed for its drop.
	# Credits settle now; the reward flow queues the modal until hit resolution
	# is complete, including other enemies hit by this same area attack.
	_floor.encounter_cleared(self)
