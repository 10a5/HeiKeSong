extends Node3D
## Deterministic first-floor greybox. Streets stay open; only land and the
## surrounding one-block shelf have collision floors.

const GRID_SIZE := 5
const TILE_SIZE := 2.0
const CELL_SIZE := 12.0 * TILE_SIZE
const STREET_WIDTH := 4.0 * TILE_SIZE
const BUILDING_WIDTH := 8.0 * TILE_SIZE
const SHALLOW_WIDTH := CELL_SIZE
const DEEP_WIDTH := 100.0
const WATER_HEIGHT := -0.12
const HALF_GRID_SPAN := float(GRID_SIZE) * CELL_SIZE * 0.5
const LAND_HALF_EXTENT := HALF_GRID_SPAN + STREET_WIDTH * 0.5
const STREET_COORDINATES: Array[float] = [-60.0, -36.0, -12.0, 12.0, 36.0, 60.0]
const KIND_COLORS := {
	"residential": Color("a4afb7"),
	"shop": Color("e9b866"),
	"office": Color("749cac"),
	"medical": Color("85c3ab"),
	"police": Color("879dc6"),
}
const KIND_NAMES := {
	"residential": "住宅", "shop": "商店", "office": "写字楼",
	"medical": "医疗", "police": "公安",
}
const KIND_ACCENTS := {
	"residential": Color("728795"), "shop": Color("ffbd72"),
	"office": Color("bba2ef"), "medical": Color("74edba"), "police": Color("79baff"),
}
const LABEL_FONT = preload("res://assets/fonts/NotoSansSC-Regular.ttf")
const RESIDENTIAL_MODEL = preload("res://model/居民楼.glb")
const WET_STREET_SHADER = preload("res://materials/wet_street.gdshader")
const RESIDENTIAL_SHADER = preload("res://materials/weathered_residential.gdshader")
const WATER_SHADER = preload("res://materials/water_surface.gdshader")
const OCCLUSION_SHADER = preload("res://materials/occlusion_tech.gdshader")
const WATER_EFFECTS = preload("res://water_effects.gd")
const OCCLUSION_TRANSPARENCY := 0.68
const OCCLUSION_FADE_SPEED := 5.5

var seed_value: int = 104729
var land_rect := Rect2(-LAND_HALF_EXTENT, -LAND_HALF_EXTENT, LAND_HALF_EXTENT * 2.0, LAND_HALF_EXTENT * 2.0)
var shallow_rect := land_rect.grow(SHALLOW_WIDTH)
var world_rect := shallow_rect.grow(DEEP_WIDTH)
var spawn_position := Vector3(-CELL_SIZE * 0.5, 0.0, HALF_GRID_SPAN)
var road_width: float = STREET_WIDTH
var block_size: float = CELL_SIZE
var building_data: Array[Dictionary] = []
var encounters_data: Array[Dictionary] = []
var water_rects: Array[Rect2] = []
var water_effects: Node
var _generated: Node3D
var _building_visuals: Dictionary = {}
var _materials: Dictionary = {}
var _occluded_ids: Array[int] = []
var _residential_bounds := AABB()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE


func _process(delta: float) -> void:
	_update_occlusion_fades(delta)


func generate(new_seed_value: int = 104729) -> void:
	if not is_inside_tree():
		push_error("FirstFloorMap.generate must be called after adding the map to the scene tree")
		return
	seed_value = new_seed_value
	if is_instance_valid(_generated):
		remove_child(_generated)
		_generated.queue_free()
	building_data.clear()
	encounters_data.clear()
	_building_visuals.clear()
	_occluded_ids.clear()
	_materials.clear()
	land_rect = Rect2(-LAND_HALF_EXTENT, -LAND_HALF_EXTENT, LAND_HALF_EXTENT * 2.0, LAND_HALF_EXTENT * 2.0)
	shallow_rect = land_rect.grow(SHALLOW_WIDTH)
	world_rect = shallow_rect.grow(DEEP_WIDTH)
	water_rects = _rect_bands(land_rect, shallow_rect)
	_generated = Node3D.new()
	_generated.name = "GeneratedCity"
	add_child(_generated)
	_create_materials()
	_create_ground()
	_create_streets()
	_prepare_residential_model()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	_create_building_data(rng)
	for data in building_data:
		_create_building(data)
	_create_encounters(rng)
	_create_spawn_marker()


func regenerate(new_seed_value: int = -1) -> void:
	generate(seed_value if new_seed_value < 0 else new_seed_value)


func get_water_zone(pos: Vector3) -> String:
	var ground_point := Vector2(pos.x, pos.z)
	if land_rect.has_point(ground_point):
		return "land"
	if shallow_rect.has_point(ground_point):
		return "shallow"
	return "deep"


func update_occlusion(camera: Camera3D, actor: Node3D) -> void:
	if not is_instance_valid(camera) or not is_instance_valid(actor) or not is_inside_tree():
		return
	# Ray-query actual collision geometry. Exclude each hit building and keep
	# tracing so two overlapping blocks can never conceal the actor together.
	var next_ids: Array[int] = []
	var exclusions: Array[RID] = []
	if actor is CollisionObject3D:
		exclusions.append(actor.get_rid())
	var origin := camera.global_position
	for offset in [Vector3.UP * 0.85, Vector3.UP * 1.5]:
		var target: Vector3 = actor.global_position + offset
		for _iteration in range(GRID_SIZE * GRID_SIZE):
			var query := PhysicsRayQueryParameters3D.create(origin, target, 1)
			query.exclude = exclusions
			query.hit_from_inside = true
			var hit := get_world_3d().direct_space_state.intersect_ray(query)
			if hit.is_empty():
				break
			var body: Object = hit["collider"]
			if not is_instance_valid(body) or not body.has_meta("city_building_id"):
				break
			var building_id := int(body.get_meta("city_building_id"))
			if building_id not in next_ids:
				next_ids.append(building_id)
			exclusions.append(body.get_rid())
	for building_id in _occluded_ids:
		if building_id not in next_ids:
			_set_building_occluded(building_id, false)
	for building_id in next_ids:
		if building_id not in _occluded_ids:
			_set_building_occluded(building_id, true)
	_occluded_ids = next_ids


func _set_building_occluded(building_id: int, obscured: bool) -> void:
	if not _building_visuals.has(building_id):
		return
	var visuals: Dictionary = _building_visuals[building_id]
	# Keep the full facade in the scene, but make the sight-blocking geometry
	# fade into a holographic material. The full-size solid collision body is
	# deliberately untouched.
	var upper: Node3D = visuals["upper"]
	upper.visible = true
	if not visuals.has("occlusion_records"):
		visuals["occlusion_records"] = _capture_occlusion_materials(upper)
	if not visuals.has("occlusion_material"):
		visuals["occlusion_material"] = _occlusion_material()
	var records: Array = visuals["occlusion_records"]
	var ghost: ShaderMaterial = visuals["occlusion_material"]
	if obscured:
		for record: Dictionary in records:
			var geometry: GeometryInstance3D = record["node"]
			geometry.material_override = ghost
			geometry.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		visuals["occlusion_target"] = 1.0
		visuals["occlusion_animating"] = true
	else:
		# Keep the ghost override in place while it fades out, then restore each
		# geometry's original material and shadow setting in _update_occlusion_fades.
		visuals["occlusion_target"] = 0.0
		visuals["occlusion_animating"] = true
	var outline: MeshInstance3D = visuals["outline"]
	outline.visible = obscured or float(visuals.get("occlusion_amount", 0.0)) > 0.01


func _update_occlusion_fades(delta: float) -> void:
	for building_id in _building_visuals:
		var visuals: Dictionary = _building_visuals[building_id]
		if not visuals.get("occlusion_animating", false):
			continue
		var current := float(visuals.get("occlusion_amount", 0.0))
		var target := float(visuals.get("occlusion_target", 0.0))
		var next := move_toward(current, target, delta * OCCLUSION_FADE_SPEED)
		visuals["occlusion_amount"] = next
		var ghost: ShaderMaterial = visuals["occlusion_material"]
		ghost.set_shader_parameter("fade", next)
		var outline: MeshInstance3D = visuals["outline"]
		outline.visible = target > 0.0 or next > 0.01
		if target <= 0.0 and next <= 0.001:
			for record: Dictionary in visuals["occlusion_records"]:
				var geometry: GeometryInstance3D = record["node"]
				geometry.material_override = record["material"]
				geometry.cast_shadow = record["cast_shadow"]
			outline.visible = false
			visuals["occlusion_animating"] = false


func _capture_occlusion_materials(node: Node) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for child: Node in node.find_children("*", "GeometryInstance3D", true, false):
		var geometry := child as GeometryInstance3D
		records.append({
			"node": geometry,
			"material": geometry.material_override,
			"cast_shadow": geometry.cast_shadow,
		})
	return records


func _occlusion_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = OCCLUSION_SHADER
	# Keep the same overall opacity as the previous ghost material while the
	# shader adds a smooth vertical colour gradient, rim light and animated
	# scan/grid lines. These uniforms are intentionally exposed so the effect
	# can be tuned without changing the imported building meshes.
	material.set_shader_parameter("base_color", Color(0.08, 0.32, 0.48, 1.0))
	material.set_shader_parameter("highlight_color", Color(0.20, 0.84, 1.0, 1.0))
	material.set_shader_parameter("line_color", Color(0.40, 0.94, 1.0, 1.0))
	material.set_shader_parameter("opacity", 1.0 - OCCLUSION_TRANSPARENCY)
	material.set_shader_parameter("line_speed", 0.75)
	material.set_shader_parameter("line_density", 2.8)
	material.set_shader_parameter("grid_density", 0.16)
	material.set_shader_parameter("line_strength", 0.72)
	material.set_shader_parameter("fade", 0.0)
	return material


func _create_materials() -> void:
	_materials["road"] = _wet_ground_material(Color("4b5c68"))
	_materials["pavement"] = _wet_ground_material(Color("798080"), true)
	_materials["curb"] = _wet_ground_material(Color("aab3ad"), false, true)
	_materials["line"] = _wet_ground_material(Color("bcaf83"), false, true)
	_materials["glass"] = _material(Color("314e63"))
	_materials["roof"] = _wet_ground_material(Color("57636b"), true)
	_materials["door"] = _material(Color("233d48"))
	_materials["sand"] = _material(Color("7a9c94"))
	_materials["shore"] = _material(Color("aec7bd"))
	_materials["spawn"] = _material(Color("83e5d0"), true)
	_materials["water"] = _water_material()
	_materials["residential_weather"] = _residential_weather_material()
	for level in ["bright", "dim"]:
		var window := StandardMaterial3D.new()
		window.albedo_color = Color("9f7042")
		window.vertex_color_use_as_albedo = true
		window.roughness = 0.34
		window.cull_mode = BaseMaterial3D.CULL_DISABLED
		window.emission_enabled = true
		window.emission = Color("ffbd6b")
		window.emission_energy_multiplier = 0.72 if level == "bright" else 0.24
		_materials["window_" + level] = window
	for kind in KIND_COLORS:
		_materials[kind] = _material(KIND_COLORS[kind])
		_materials[kind + "_sign"] = _material(KIND_ACCENTS[kind], true)


func _create_ground() -> void:
	_rect_box(_generated, "LandFloor", land_rect, -0.25, 0.5, _materials["road"], true)
	for index in range(water_rects.size()):
		var band := water_rects[index]
		# Every shelf collider ends exactly at shallow_rect, including corners.
		_rect_box(_generated, "ShallowSeabed%d" % index, band, -0.70, 0.5, _materials["sand"], true)
	# Render continuous water independently of the invisible shelf boundary.
	var surface_bands := _rect_bands(land_rect, world_rect)
	for index in range(surface_bands.size()):
		_water_surface("WaterSurface%d" % index, surface_bands[index], _materials["water"])
	water_effects = WATER_EFFECTS.new()
	water_effects.name = "WaterEffects"
	water_effects.setup(_materials["water"], land_rect, WATER_HEIGHT)
	_generated.add_child(water_effects)
	# CharacterBody3D does not auto-step over the 0.45 m quay. Short ramps at
	# every street end let ordinary walking return from the shallow shelf.
	for line in STREET_COORDINATES:
		_create_shore_ramp(Vector3(line, 0.0, land_rect.end.y), 0.0)
		_create_shore_ramp(Vector3(line, 0.0, land_rect.position.y), PI)
		_create_shore_ramp(Vector3(land_rect.end.x, 0.0, line), PI * 0.5)
		_create_shore_ramp(Vector3(land_rect.position.x, 0.0, line), -PI * 0.5)
	# Non-solid short edge dashes distinguish the shelf without building a wall.
	for index in range(22):
		var along := -LAND_HALF_EXTENT + 2.0 + float(index) * 6.0
		for sign_value in [-1.0, 1.0]:
			_box(_generated, "ShoreEdge", Vector3(2.5, 0.015, 0.20), Vector3(along, 0.011, sign_value * (LAND_HALF_EXTENT - 0.13)), _materials["shore"])
			_box(_generated, "ShoreEdge", Vector3(0.20, 0.015, 2.5), Vector3(sign_value * (LAND_HALF_EXTENT - 0.13), 0.011, along), _materials["shore"])


func _create_streets() -> void:
	# Shared continuous land collision avoids street seams or curb steps.
	for line in STREET_COORDINATES:
		for cell in range(GRID_SIZE):
			var center := -HALF_GRID_SPAN + CELL_SIZE * 0.5 + float(cell) * CELL_SIZE
			for delta in [-7.0, 0.0, 7.0]:
				_box(_generated, "RoadDash", Vector3(0.15, 0.014, 2.5), Vector3(line, 0.012, center + delta), _materials["line"])
				_box(_generated, "RoadDash", Vector3(2.5, 0.014, 0.15), Vector3(center + delta, 0.012, line), _materials["line"])
	# Crosswalks stop outside junction centers; they also show the grid clearly.
	for x in STREET_COORDINATES:
		for z in STREET_COORDINATES:
			for stripe in range(4):
				var across := -2.7 + float(stripe) * 1.8
				var crossing_z := z - 4.9 if z == HALF_GRID_SPAN else z + 4.9
				_box(_generated, "Crosswalk", Vector3(0.84, 0.015, 1.5), Vector3(x + across, 0.015, crossing_z), _materials["curb"])


func _create_building_data(rng: RandomNumberGenerator) -> void:
	var available_kinds: Array[String] = []
	for _index in range(15):
		available_kinds.append("residential")
	available_kinds.append_array(["shop", "shop", "office", "office", "office", "medical", "police", "police"])
	_shuffle(available_kinds, rng)
	var nearby_cells: Array[int] = [0, 1, 2]
	_shuffle(nearby_cells, rng)
	var nearby_kinds: Array[String] = ["shop", "medical"]
	_shuffle(nearby_kinds, rng)
	for row in range(GRID_SIZE):
		for column in range(GRID_SIZE):
			var kind: String
			# The initial corner of the island always offers two useful doors.
			if row == GRID_SIZE - 1 and column == nearby_cells[0]:
				kind = nearby_kinds[0]
			elif row == GRID_SIZE - 1 and column == nearby_cells[1]:
				kind = nearby_kinds[1]
			else:
				kind = available_kinds.pop_back()
			var center := Vector3(-HALF_GRID_SPAN + CELL_SIZE * 0.5 + column * CELL_SIZE, 0.0, -HALF_GRID_SPAN + CELL_SIZE * 0.5 + row * CELL_SIZE)
			var height := rng.randf_range(6.5, 10.0) if kind == "residential" else rng.randf_range(6.0, 8.0)
			if kind == "residential":
				# Keep the imported building's vertical proportions relative to its
				# longest side; the existing square parcel remains eight tiles wide.
				height = _residential_bounds.size.y * _residential_scale().y + 0.22
			building_data.append({
				"id": row * GRID_SIZE + column,
				"cell": Vector2i(column, row), "kind": kind,
				"position": center,
				"door_position": center + Vector3(0.0, 0.0, 10.3),
				"height": height,
				"width": BUILDING_WIDTH,
			})


func _create_building(data: Dictionary) -> void:
	var building := Node3D.new()
	building.name = "Building_%02d_%s" % [data["id"], data["kind"]]
	building.position = data["position"]
	_generated.add_child(building)
	var kind: String = data["kind"]
	var height: float = data["height"]
	var body_material: StandardMaterial3D = _materials[kind]
	_box(building, "Sidewalk", Vector3(18.6, 0.018, 18.6), Vector3(0.0, 0.009, 0.0), _materials["pavement"])
	_box(building, "LowFootprint", Vector3(BUILDING_WIDTH, 0.22, BUILDING_WIDTH), Vector3(0.0, 0.11, 0.0), _materials["roof"])
	var upper := Node3D.new()
	upper.name = "OccludableUpper"
	building.add_child(upper)
	var collision := StaticBody3D.new()
	collision.name = "BuildingCollision"
	collision.collision_layer = 1
	collision.collision_mask = 0
	collision.set_meta("city_building_id", int(data["id"]))
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	var collision_height := height if kind == "residential" else height + 0.16
	box_shape.size = Vector3(BUILDING_WIDTH, collision_height, BUILDING_WIDTH)
	shape.shape = box_shape
	shape.position.y = collision_height * 0.5
	collision.add_child(shape)
	building.add_child(collision)
	var outline := _box(building, "OcclusionFootprint", Vector3(BUILDING_WIDTH + 0.04, 0.016, BUILDING_WIDTH + 0.04), Vector3(0, 0.235, 0), _materials[kind + "_sign"])
	outline.visible = false
	_building_visuals[int(data["id"])] = {"upper": upper, "outline": outline}
	if kind == "residential":
		_add_residential_model(upper)
		return
	# Other building categories keep their existing greybox facades.
	upper.scale = Vector3(BUILDING_WIDTH / 7.4, 1.0, BUILDING_WIDTH / 7.4)
	_box(upper, "Facade", Vector3(7.4, height - 0.22, 7.4), Vector3(0.0, (height + 0.22) * 0.5, 0.0), body_material)
	_box(upper, "Roof", Vector3(7.62, 0.16, 7.62), Vector3(0.0, height + 0.08, 0.0), _materials["roof"])
	_box(upper, "Door", Vector3(1.15, 1.85, 0.045), Vector3(0.0, 0.925, 3.725), _materials["door"])
	_box(upper, "DoorLight", Vector3(1.35, 0.10, 0.08), Vector3(0.0, 1.94, 3.77), _materials[kind + "_sign"])
	var floors := 3 if height >= 8.5 else 2
	for level in range(floors):
		var window_y := 2.85 + level * 1.85
		for offset_x in [-2.35, 0.0, 2.35]:
			_box(upper, "Window", Vector3(1.22, 0.70, 0.04), Vector3(offset_x, window_y, 3.725), _materials["glass"])
			_box(upper, "Window", Vector3(1.22, 0.70, 0.04), Vector3(offset_x, window_y, -3.725), _materials["glass"])
		for offset_z in [-2.35, 0.0, 2.35]:
			_box(upper, "Window", Vector3(0.04, 0.70, 1.22), Vector3(3.725, window_y, offset_z), _materials["glass"])
			_box(upper, "Window", Vector3(0.04, 0.70, 1.22), Vector3(-3.725, window_y, offset_z), _materials["glass"])
	_create_building_identity(upper, kind, height)
	# Unobstructed walking strip to the southern road; no door collision.
	_box(building, "DoorPath", Vector3(2.2, 0.015, 2.3), Vector3(0.0, 0.022, 9.15), _materials["curb"])


func _prepare_residential_model() -> void:
	if not _residential_bounds.size.is_zero_approx():
		return
	var sample := RESIDENTIAL_MODEL.instantiate()
	_residential_bounds = _measure_model_bounds(sample)
	sample.free()


func _measure_model_bounds(node: Node, parent_transform := Transform3D.IDENTITY) -> AABB:
	var local_transform: Transform3D = parent_transform * node.transform if node is Node3D else parent_transform
	var bounds := AABB()
	if node is MeshInstance3D and node.mesh != null:
		bounds = local_transform * node.mesh.get_aabb()
	for child in node.get_children():
		var child_bounds := _measure_model_bounds(child, local_transform)
		if not child_bounds.size.is_zero_approx():
			bounds = child_bounds if bounds.size.is_zero_approx() else bounds.merge(child_bounds)
	return bounds


func _residential_scale() -> Vector3:
	var scale_x := BUILDING_WIDTH / maxf(_residential_bounds.size.x, 0.001)
	var scale_z := BUILDING_WIDTH / maxf(_residential_bounds.size.z, 0.001)
	return Vector3(scale_x, minf(scale_x, scale_z), scale_z)


func _add_residential_model(parent: Node3D) -> void:
	var fit := Node3D.new()
	fit.name = "ResidentialModelFit"
	fit.scale = _residential_scale()
	var center := _residential_bounds.get_center()
	fit.position = Vector3(-center.x * fit.scale.x, 0.22 - _residential_bounds.position.y * fit.scale.y, -center.z * fit.scale.z)
	parent.add_child(fit)
	# PackedScene instances share the original mesh and vertex-color materials.
	var model := RESIDENTIAL_MODEL.instantiate()
	model.name = "ResidentialModel"
	fit.add_child(model)
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		# Godot's imported mesh LODs reduce the cost of the fifteen tall towers.
		mesh.lod_bias = 0.4
		if mesh.mesh.get_surface_count() > 0:
			mesh.set_surface_override_material(0, _materials["residential_weather"])
		if mesh.mesh.get_surface_count() > 2:
			mesh.set_surface_override_material(1, _materials["window_bright"])
			mesh.set_surface_override_material(2, _materials["window_dim"])


func _create_building_identity(upper: Node3D, kind: String, height: float) -> void:
	if kind == "residential":
		_box(upper, "RoofUtility", Vector3(1.6, 0.38, 1.15), Vector3(-1.7, height + 0.35, -1.4), _materials["pavement"])
		return
	var accent: StandardMaterial3D = _materials[kind + "_sign"]
	_box(upper, "FunctionBand", Vector3(7.46, 0.24, 0.14), Vector3(0.0, height - 0.15, 3.78), accent)
	var label := Label3D.new()
	label.name = "BuildingFunction"
	label.font = LABEL_FONT
	label.text = KIND_NAMES[kind]
	label.font_size = 40
	label.pixel_size = 0.014
	label.outline_size = 5
	label.modulate = Color("edf6f1")
	label.position = Vector3(0.0, height - 0.75, 3.83)
	upper.add_child(label)
	label.scale.x = 7.4 / BUILDING_WIDTH
	match kind:
		"shop":
			_box(upper, "ShopAwning", Vector3(4.9, 0.15, 0.68), Vector3(0.0, 2.15, 3.78), accent)
		"medical":
			_box(upper, "MedicalCross", Vector3(1.65, 0.12, 0.5), Vector3(0.0, height + 0.23, 0.0), accent)
			_box(upper, "MedicalCross", Vector3(0.5, 0.12, 1.65), Vector3(0.0, height + 0.23, 0.0), accent)
		"police":
			_box(upper, "PoliceLight", Vector3(1.2, 0.23, 0.5), Vector3(0.0, height + 0.3, 0.0), accent)
			_box(upper, "PoliceLightDivider", Vector3(0.14, 0.25, 0.54), Vector3(0.0, height + 0.3, 0.0), _materials["door"])
		"office":
			_box(upper, "OfficeSkylight", Vector3(3.8, 0.14, 2.0), Vector3(0.0, height + 0.21, 0.0), _materials["glass"])


func _create_encounters(rng: RandomNumberGenerator) -> void:
	var candidates: Array[Dictionary] = []
	for line in STREET_COORDINATES:
		for segment in range(GRID_SIZE):
			var start := -HALF_GRID_SPAN + float(segment) * CELL_SIZE
			var horizontal_mid := Vector3(start + CELL_SIZE * 0.5, 0.0, line)
			var vertical_mid := Vector3(line, 0.0, start + CELL_SIZE * 0.5)
			if horizontal_mid.distance_to(spawn_position) > 10.0:
				candidates.append({"position": horizontal_mid, "axis": Vector3.RIGHT, "endpoint_a": Vector3(start, 0.0, line), "endpoint_b": Vector3(start + CELL_SIZE, 0.0, line)})
			if vertical_mid.distance_to(spawn_position) > 10.0:
				candidates.append({"position": vertical_mid, "axis": Vector3.BACK, "endpoint_a": Vector3(line, 0.0, start), "endpoint_b": Vector3(line, 0.0, start + CELL_SIZE)})
	_shuffle(candidates, rng)
	for index in range(mini(8, candidates.size())):
		var data: Dictionary = candidates[index].duplicate()
		data["id"] = index
		encounters_data.append(data)


func _create_spawn_marker() -> void:
	var marker := MeshInstance3D.new()
	marker.name = "ArrivalRing"
	var mesh := TorusMesh.new()
	mesh.inner_radius = 0.95
	mesh.outer_radius = 1.02
	mesh.rings = 40
	mesh.ring_segments = 5
	marker.mesh = mesh
	marker.material_override = _materials["spawn"]
	marker.position = spawn_position + Vector3.UP * 0.024
	_generated.add_child(marker)


func _rect_bands(inner: Rect2, outer: Rect2) -> Array[Rect2]:
	return [
		Rect2(outer.position.x, outer.position.y, outer.size.x, inner.position.y - outer.position.y),
		Rect2(outer.position.x, inner.end.y, outer.size.x, outer.end.y - inner.end.y),
		Rect2(outer.position.x, inner.position.y, inner.position.x - outer.position.x, inner.size.y),
		Rect2(inner.end.x, inner.position.y, outer.end.x - inner.end.x, inner.size.y),
	]


func _create_shore_ramp(location: Vector3, yaw: float) -> void:
	var ramp := StaticBody3D.new()
	ramp.name = "ShoreRamp"
	ramp.position = location
	ramp.rotation.y = yaw
	ramp.collision_layer = 1
	ramp.collision_mask = 0
	var shape := ConvexPolygonShape3D.new()
	shape.points = PackedVector3Array([
		Vector3(-3.5, 0.0, -0.03), Vector3(3.5, 0.0, -0.03),
		Vector3(-3.5, -0.45, 2.4), Vector3(3.5, -0.45, 2.4),
		Vector3(-3.5, -0.72, -0.03), Vector3(3.5, -0.72, -0.03),
		Vector3(-3.5, -0.72, 2.4), Vector3(3.5, -0.72, 2.4),
	])
	var collision := CollisionShape3D.new()
	collision.shape = shape
	ramp.add_child(collision)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var normal := Vector3(0.0, 2.43, 0.45).normalized()
	for point in [Vector3(-3.5, 0.0, -0.03), Vector3(3.5, 0.0, -0.03), Vector3(-3.5, -0.45, 2.4), Vector3(3.5, 0.0, -0.03), Vector3(3.5, -0.45, 2.4), Vector3(-3.5, -0.45, 2.4)]:
		surface.set_normal(normal)
		surface.add_vertex(point)
	var visual := MeshInstance3D.new()
	visual.name = "RampSurface"
	visual.mesh = surface.commit()
	visual.material_override = _materials["pavement"]
	ramp.add_child(visual)
	_generated.add_child(ramp)


func _water_surface(node_name: String, area: Rect2, material: Material) -> void:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	var plane := PlaneMesh.new()
	plane.size = area.size
	instance.mesh = plane
	instance.position = Vector3(area.get_center().x, WATER_HEIGHT, area.get_center().y)
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_generated.add_child(instance)


func _rect_box(parent: Node3D, node_name: String, area: Rect2, center_y: float, thickness: float, material: Material, solid: bool) -> MeshInstance3D:
	return _box(parent, node_name, Vector3(area.size.x, thickness, area.size.y), Vector3(area.get_center().x, center_y, area.get_center().y), material, solid)


func _box(parent: Node3D, node_name: String, dimensions: Vector3, location: Vector3, material: Material, solid: bool = false) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = dimensions
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = location
	parent.add_child(instance)
	if solid:
		var body := StaticBody3D.new()
		body.name = node_name + "Collision"
		body.position = location
		body.collision_layer = 1
		body.collision_mask = 0
		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = dimensions
		shape.shape = box_shape
		body.add_child(shape)
		parent.add_child(body)
	return instance


func _material(color: Color, luminous: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.88
	if luminous:
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = 0.35
	return material


func _wet_ground_material(color: Color, paving := false, road_paint := false) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = WET_STREET_SHADER
	material.set_shader_parameter("base_color", color)
	material.set_shader_parameter("paving", paving)
	material.set_shader_parameter("road_paint", road_paint)
	return material


func _residential_weather_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = RESIDENTIAL_SHADER
	return material


func _water_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = WATER_SHADER
	return material


func _shuffle(items: Array, rng: RandomNumberGenerator) -> void:
	for index in range(items.size() - 1, 0, -1):
		var other := rng.randi_range(0, index)
		var saved: Variant = items[index]
		items[index] = items[other]
		items[other] = saved
