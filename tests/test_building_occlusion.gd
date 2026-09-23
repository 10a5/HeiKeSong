extends SceneTree
## Occlusion must follow rendered upper surfaces, not parcels or a grazed edge.

const CITY = preload("res://first_floor_map.gd")
var city: Node3D
var camera: Camera3D
var actor: Node3D
var building: Node3D
var surface: BoxShape3D
var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	city = CITY.new()
	root.add_child(city)
	camera = Camera3D.new()
	root.add_child(camera)
	camera.position = Vector3(0, 1.1, 8)
	actor = Node3D.new()
	root.add_child(actor)
	camera.look_at(actor.position + Vector3.UP * 1.1)
	building = _fixture(0, Vector3(0, 1.5, 4), Vector3(1, 3, 1))
	surface = building.get_node("CameraOccluder").get_child(0).shape
	await _sync()
	_check(0 in city._occluded_ids, "A facade covering the torso fades")
	city._update_occlusion_fades(0.3)
	var geometry := building.get_node("Upper/Facade") as MeshInstance3D
	_check(geometry.material_override is ShaderMaterial, "A confirmed blocker uses the existing hologram material")
	building.position.x = 2.0
	await _sync()
	city._update_occlusion_fades(0.3)
	_check(city._occluded_ids.is_empty() and geometry.material_override == null, "Standing beside a small building restores its original appearance")
	# A wider walking collider is deliberately present. It must never be used
	# by the camera even though the ray intersects its invisible parcel area.
	var walking := StaticBody3D.new()
	walking.collision_layer = 1
	walking.set_meta("city_building_id", 0)
	var large := CollisionShape3D.new()
	var large_box := BoxShape3D.new()
	large_box.size = Vector3(14, 6, 10)
	large.shape = large_box
	walking.add_child(large)
	building.add_child(walking)
	await _sync()
	_check(city._occluded_ids.is_empty(), "Walking collision outside a reduced visual facade cannot fade the building")
	walking.queue_free()
	building.position = Vector3(0.62, 1.5, 4)
	await _sync()
	_check(city._occluded_ids.is_empty(), "A ray grazing a side corner does not fade an otherwise visible character's surroundings")
	# Only the upper row of torso probes meets this thin awning. The former
	# single head ray would fade the entire building for this sliver.
	building.position = Vector3(0, 1.29, 4)
	surface.size = Vector3(2, 0.1, 0.2)
	await _sync()
	_check(city._occluded_ids.is_empty(), "A thin ledge clipping just the head probes keeps the building solid")
	building.position = Vector3(0, 0.11, 4)
	surface.size = Vector3(1, 0.22, 1)
	await _sync()
	_check(city._occluded_ids.is_empty(), "A low building underneath the sight line does not fade")
	building.position = Vector3(0, 1.5, -4)
	surface.size = Vector3(1, 3, 1)
	await _sync()
	_check(city._occluded_ids.is_empty(), "A building beyond the character cannot trigger occlusion")
	building.position = Vector3(0, 1.1, 7.75)
	surface.size = Vector3(2, 3, 0.1)
	camera.near = 0.5
	await _sync()
	_check(city._occluded_ids.is_empty(), "A surface clipped before the camera's near plane cannot fade")
	camera.near = 0.05
	building.position = Vector3(0, 1.5, 4)
	surface.size = Vector3(1, 3, 1)
	var second := _fixture(1, Vector3(0, 1.5, 2), Vector3(1, 3, 0.5))
	await _sync()
	_check(0 in city._occluded_ids and 1 in city._occluded_ids, "Both buildings fade when their facades overlap the torso")
	camera.position = Vector3(5, 1.1, 8)
	camera.look_at(actor.position + Vector3.UP * 1.1)
	city.update_occlusion(camera, actor)
	_check(city._occluded_ids.is_empty(), "Orbiting to an unobstructed view clears the old camera's blockers immediately")
	second.queue_free()
	print("BUILDING OCCLUSION RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _fixture(id: int, position: Vector3, dimensions: Vector3) -> Node3D:
	var node := Node3D.new()
	node.position = position
	city.add_child(node)
	var upper := Node3D.new()
	upper.name = "Upper"
	node.add_child(upper)
	var mesh := MeshInstance3D.new()
	mesh.name = "Facade"
	var box := BoxMesh.new()
	box.size = dimensions
	mesh.mesh = box
	upper.add_child(mesh)
	var outline := MeshInstance3D.new()
	outline.mesh = BoxMesh.new()
	outline.visible = false
	node.add_child(outline)
	city._building_visuals[id] = {"upper": upper, "outline": outline}
	var shape := BoxShape3D.new()
	shape.size = dimensions
	city._create_building_occluder(node, id, shape, Transform3D.IDENTITY)
	return node


func _sync() -> void:
	(building.get_node("Upper/Facade").mesh as BoxMesh).size = surface.size
	await physics_frame
	await process_frame
	city.update_occlusion(camera, actor)


func _check(condition: bool, label: String) -> void:
	if condition:
		passed += 1
		print("PASS: ", label)
	else:
		failed += 1
		push_error("FAIL: %s; faded IDs %s" % [label, city._occluded_ids])
