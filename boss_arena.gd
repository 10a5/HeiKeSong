extends Node3D
## The authored duel arena and mirror fighter shared with adaptive_boss_lab.
## Place this node anywhere before spawning the actors; positions and bounds
## exposed below are in world space while surface_point takes local X/Z.

const ARENA_SCENE: PackedScene = preload("res://model/决战场景.glb")
const BOSS_SCRIPT = preload("res://mirror_boss.gd")
## The duel floor is intentionally twice the original lab footprint.  Keep
## every world-space measurement below derived from this authored scale so
## collision, spawns and the actors' playable bounds stay in sync.
const ARENA_SCALE: float = 0.6
const SURFACE_RAY_UP: float = 50.0
const SURFACE_RAY_DOWN: float = 20.0

@export var arena_rect := Rect2(-19.0, -15.0, 38.0, 30.0)

var arena: Node3D
var boss: CharacterBody3D


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
	boss.spawn_position = surface_point(0.0, -1.0)
	boss.arena_rect = world_bounds()
	boss.arena_center = global_position
	boss.bounds_enabled = true
	add_child(boss)
	boss.setup(player)
	return boss
