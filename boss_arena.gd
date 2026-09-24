extends Node3D
## The authored duel arena and mirror fighter shared with adaptive_boss_lab.
## Place this node anywhere before spawning the actors; positions and bounds
## exposed below are in world space while surface_point takes local X/Z.

const ARENA_SCENE: PackedScene = preload("res://model/决战场景.glb")
const BOSS_SCRIPT = preload("res://mirror_boss.gd")
const BOSS_WATER_SCRIPT = preload("res://boss_water.gd")
## The duel floor is intentionally twice the original lab footprint. Keep
## every world-space measurement below derived from this authored scale so
## collision, spawns and navigation metadata stay in sync. `arena_rect` is
## retained for spawn/navigation queries; Boss movement does not clamp to it.
const ARENA_SCALE: float = 0.6
const SURFACE_RAY_UP: float = 50.0
const SURFACE_RAY_DOWN: float = 20.0

@export var arena_rect := Rect2(-19.0, -15.0, 38.0, 30.0)
## Per-floor duel tuning, forwarded to the mirror Boss when it is created.
## Floor one keeps 1.0 / 1.0 and therefore the authored 500 HP duel; later
## floors raise both so the mirror's health pool and landed hits grow while
## every combo, telegraph and card effect stays the same.
@export var boss_health_multiplier: float = 1.0
@export var boss_damage_multiplier: float = 1.0

var arena: Node3D
var boss: CharacterBody3D
var water: Node3D


## Must be called before `spawn_boss()`. The values also drive a live boss so a
## floor can retune an arena that is already standing.
func set_floor_scaling(health_scale: float, damage_scale: float) -> void:
	boss_health_multiplier = health_scale if health_scale > 0.0 else 1.0
	boss_damage_multiplier = damage_scale if damage_scale > 0.0 else 1.0
	if is_instance_valid(boss) and boss.has_method("set_floor_scaling"):
		boss.call("set_floor_scaling", boss_health_multiplier, boss_damage_multiplier)


func _ready() -> void:
	name = "BossArena"
	arena = ARENA_SCENE.instantiate() as Node3D
	arena.name = "DuelArena"
	# Match the imported floor's 15 degree slope while giving the duel twice
	# the original lab footprint.
	arena.scale = Vector3.ONE * ARENA_SCALE
	arena.rotation_degrees.x = -15.0
	arena.position.y = -5.0
	add_child(arena)
	for mesh: MeshInstance3D in arena.find_children("*", "MeshInstance3D", true, false):
		mesh.create_trimesh_collision()
		for body in mesh.get_children():
			if body is StaticBody3D:
				body.collision_layer = 1
				body.collision_mask = 2 | 4
	_create_water_overlay()
	_align_water_overlay.call_deferred()


func _create_water_overlay() -> void:
	water = BOSS_WATER_SCRIPT.new()
	water.name = "BossShallowWater"
	add_child(water)
	# The imported arena is larger than the old logical play rectangle. Extend
	# the visual sheet over the full authored floor while keeping it non-solid.
	var water_size := arena_rect.size + Vector2(18.0, 18.0)
	water.setup(global_position, water_size, -15.0, global_position.y - 4.8)


func _align_water_overlay() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	if is_instance_valid(water):
		water.align_to_surface(surface_point(0.0, 0.0))


func world_bounds() -> Rect2:
	return Rect2(arena_rect.position + Vector2(global_position.x, global_position.z), arena_rect.size)


func surface_point(x: float, z: float) -> Vector3:
	# Allow two physics frames after add_child before querying imported static
	# collision, just as the lab does. Offset both ends of the vertical ray.
	var origin := global_position + Vector3(x, SURFACE_RAY_UP, z)
	var end := global_position + Vector3(x, -SURFACE_RAY_DOWN, z)
	var query := PhysicsRayQueryParameters3D.create(origin, end, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		push_error("BossArena has no floor at requested spawn: %s" % Vector2(x, z))
		return global_position + Vector3(x, 1.0, z)
	return (hit["position"] as Vector3) + Vector3.UP * 0.05


func player_spawn() -> Vector3:
	return surface_point(0.0, 8.0)


func spawn_boss(player: CharacterBody3D) -> CharacterBody3D:
	if is_instance_valid(boss):
		return boss
	boss = BOSS_SCRIPT.new()
	boss.name = "MirrorBoss"
	boss.display_name = "镜像 Boss"
	# Scale before `add_child()`: the mirror derives its pool and damage in
	# `_init()`, so setting this afterwards would leave the first entrance and
	# the HUD bar on the unscaled 500.
	if boss.has_method("set_floor_scaling"):
		boss.call("set_floor_scaling", boss_health_multiplier, boss_damage_multiplier)
	boss.spawn_position = surface_point(0.0, -1.0)
	boss.arena_rect = world_bounds()
	boss.arena_center = global_position
	# The GLB's real floor and obstacles remain collidable. The old rectangular
	# clamp was an invisible air wall that prevented open movement across the
	# authored arena, so both actors use free world movement here.
	boss.bounds_enabled = false
	player.bounds_enabled = false
	add_child(boss)
	boss.setup(player)
	if is_instance_valid(water):
		water.set_actors([player, boss])
	return boss
