extends SceneTree
## Render the live first floor with a reproducible layout and then exit.
## Godot --path . --script tools/preview_map_c.gd -- 7331

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	Engine.max_fps = 30
	root.size = Vector2i(1280, 720)
	var arguments := OS.get_cmdline_user_args()
	var preview_seed := int(arguments[0]) if not arguments.is_empty() else 7331
	var output := ProjectSettings.globalize_path("res://test-results/map-c")
	DirAccess.make_dir_recursive_absolute(output)
	var scene := load("res://floor_one.tscn").instantiate() as Node3D
	root.add_child(scene)
	scene.regenerate_floor(preview_seed)
	for _frame in range(5):
		await process_frame
	scene.set_process(false)
	scene.set_physics_process(false)
	paused = true
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join("runtime-%d.png" % preview_seed))
	scene.get_node("HUD").visible = false
	var camera: Camera3D = scene.camera
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 120.0
	camera.far = 600.0
	camera.global_position = Vector3(0, 145, 110)
	camera.look_at(Vector3.ZERO)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join("overview-%d.png" % preview_seed))
	camera.size = 114.0
	camera.global_position = Vector3(0, 180, 0)
	camera.look_at(Vector3.ZERO, Vector3.FORWARD)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join("topdown-%d.png" % preview_seed))
	var map: Node3D = scene.city_map
	var report := {"seed": preview_seed, "roads": map.road_data.size(), "buildings": map.building_data.size(), "stats": map.map_plan["stats"]}
	var file := FileAccess.open(output.path_join("summary-%d.json" % preview_seed), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	print("MAP C PREVIEW: " + JSON.stringify(report))
	print("Images saved to " + output)
	quit()
