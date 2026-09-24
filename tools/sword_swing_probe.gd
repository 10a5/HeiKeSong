extends SceneTree
## Temporary probe: drives a real sword-variant encounter and renders the frame
## where the chop resolves, so the facing, the lock-on and the swing pose can be
## checked by eye. Run with:
## Godot_v4.7.2-stable_win64_console.exe --path . --script tools/sword_swing_probe.gd

const VARIANT_SCRIPT = preload("res://enemy_variant.gd")
const PLAYER_SCRIPT = preload("res://player.gd")

var foe: CharacterBody3D
var player: CharacterBody3D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)

	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("2b3138")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("ffffff")
	environment.ambient_light_energy = 2.2
	env.environment = environment
	world.add_child(env)
	for angle in [-40.0, 40.0]:
		var light := DirectionalLight3D.new()
		light.rotation = Vector3(deg_to_rad(-30.0), deg_to_rad(angle), 0.0)
		light.light_energy = 2.0
		world.add_child(light)

	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(40.0, 0.2, 40.0)
	floor_shape.shape = floor_box
	floor_shape.position.y = -0.1
	floor_body.add_child(floor_shape)
	world.add_child(floor_body)

	player = PLAYER_SCRIPT.new()
	player.spawn_position = Vector3(0.0, 0.0, 0.0)
	world.add_child(player)
	await process_frame
	player.global_position = Vector3.ZERO
	player.set_physics_process(false)

	foe = VARIANT_SCRIPT.new()
	foe.spawn_position = Vector3(0.0, 0.0, -3.0)
	foe.variant = &"sword"
	foe.configure_variant(&"sword")
	world.add_child(foe)
	foe.setup(player)
	foe.combat_enabled = true
	await process_frame
	foe.global_position = Vector3(0.0, 0.0, -3.1)
	foe.reset_enemy()

	# Third-person-ish camera behind and to the right of the player, looking at
	# the enemy: this is the angle the player actually sees the attack from.
	var camera := Camera3D.new()
	camera.position = Vector3(2.6, 2.1, 2.6)
	camera.fov = 60.0
	world.add_child(camera)
	camera.current = true
	camera.look_at_from_position(camera.position, Vector3(0.0, 1.0, -2.4), Vector3.UP)

	var shots := {"windup": 0.55, "strike": 0.5, "retreat": 0.25}
	for label in shots:
		var fraction: float = shots[label]
		var guard := 0
		while foe.state != StringName(label) and guard < 400:
			await physics_frame
			guard += 1
		var duration := float(foe.active_duration) if label == "strike" else float(foe.windup_duration)
		var frames := int(duration * fraction * 60.0)
		for _index in range(maxi(frames, 1)):
			await physics_frame
		for _index in range(3):
			await process_frame
		var image := root.get_texture().get_image()
		var path := "res://tools/sword_%s.png" % label
		print("%s at t=%.2f state=%s health=%.0f saved=%d" % [label, float(foe.state_time_left), foe.state, player.health, image.save_png(path)])
		# Re-arm the swing for the next label by letting it finish and reset.
		if label != "retreat":
			foe.reset_enemy()
			await process_frame
			foe.global_position = Vector3(0.0, 0.0, -3.1)
			await physics_frame
	quit(0)
