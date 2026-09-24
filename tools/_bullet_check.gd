extends SceneTree
## Throwaway visual harness for the sniper's travelling round.

const PLAYER_SCRIPT = preload("res://player.gd")
const VARIANT_SCRIPT = preload("res://enemy_variant.gd")
const OUTPUT_DIR := "res://_visual_check"

var _world: Node3D
var _sniper: Node3D
var _camera: Camera3D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	_world = Node3D.new()
	root.add_child(_world)
	_add_environment()
	_add_floor()

	var player = PLAYER_SCRIPT.new()
	player.spawn_position = Vector3(-6.0, 0.0, 0.0)
	_world.add_child(player)
	player.set_physics_process(false)
	player.global_position = Vector3(-6.0, 0.0, 0.0)

	_sniper = VARIANT_SCRIPT.new()
	_sniper.set("variant", &"sniper")
	_sniper.call("configure_variant", &"sniper")
	_sniper.set("spawn_position", Vector3(6.0, 0.0, 0.0))
	_world.add_child(_sniper)
	_sniper.call("setup", player)
	_sniper.set("combat_enabled", true)
	_sniper.global_position = Vector3(6.0, 0.0, 0.0)
	_sniper.call("reset_enemy")
	for _index in range(10):
		await physics_frame
	# Expose the body so the shot can be seen leaving the rifle.
	_sniper.call("take_damage", 5.0)
	_sniper.set("_sniper_suppression_left", 0.0)

	_camera = Camera3D.new()
	_camera.fov = 50.0
	_world.add_child(_camera)
	_camera.current = true
	_camera.global_position = Vector3(0.4, 3.1, 8.6)
	_camera.look_at(Vector3(0.0, 1.1, 0.0))

	for _index in range(6):
		await physics_frame
	_sniper.call("_fire_sniper")
	print("LAUNCH origin=%s target=%s blocked=%s speed=%s" % [
		_sniper.get("last_shot_origin"), _sniper.get("last_shot_target"),
		_sniper.get("last_shot_blocked"), _sniper.get("sniper_bullet_speed")])
	for frame in range(22):
		await physics_frame
		if frame in [2, 6, 11, 15, 21]:
			print("  frame %2d traveled=%.2f in_flight=%s" % [
				frame, _traveled(), _sniper.call("is_shot_in_flight")])
			await _capture("bullet_f%02d" % frame)
	quit(0)


func _traveled() -> float:
	var rounds: Array = _sniper.get("_sniper_tracers") as Array
	if rounds.is_empty():
		return -1.0
	return float((rounds[0] as Dictionary).get("traveled", -1.0))


func _add_environment() -> void:
	var holder := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("1d2732")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("9fb2c2")
	environment.ambient_light_energy = 0.55
	holder.environment = environment
	_world.add_child(holder)
	var light := DirectionalLight3D.new()
	light.rotation = Vector3(deg_to_rad(-58.0), deg_to_rad(24.0), 0.0)
	light.light_energy = 0.35
	_world.add_child(light)


func _add_floor() -> void:
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, 0.2, 40.0)
	collision.shape = box
	collision.position.y = -0.1
	body.add_child(collision)
	_world.add_child(body)
	var mesh := MeshInstance3D.new()
	var plane := BoxMesh.new()
	plane.size = Vector3(40.0, 0.2, 40.0)
	mesh.mesh = plane
	mesh.position.y = -0.1
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("39434e")
	mesh.material_override = material
	_world.add_child(mesh)


func _capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("%s/%s.png" % [OUTPUT_DIR, label])
