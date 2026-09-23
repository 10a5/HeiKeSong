extends Node3D
## Seeded first-floor district. A planning-only port of the handoff's
## dispersed-city graph supplies building cells, roads and ground routes;
## this node still owns the project's GLB geometry, water and occlusion.

const ROGUELIKE_LAYOUT = preload("res://roguelike_map_layout.gd")
const GRID_COLUMNS := 8
const GRID_ROWS := 8
const TILE_SIZE := 2.0
const CELL_WIDTH := 11.0 * TILE_SIZE
const CELL_DEPTH := 9.0 * TILE_SIZE
const STREET_WIDTH := 4.0 * TILE_SIZE
const BUILDING_WIDTH := 7.0 * TILE_SIZE
const BUILDING_DEPTH := 5.0 * TILE_SIZE
const RESIDENTIAL_FLOOR_HEIGHT := 3.0
const RESIDENTIAL_FLOORS := 5
const RESIDENTIAL_TARGET_HEIGHT := RESIDENTIAL_FLOOR_HEIGHT * RESIDENTIAL_FLOORS
const SHALLOW_MARGIN_X := 18.0
const SHALLOW_MARGIN_Z := 18.0
const DEEP_WIDTH := 100.0
const WATER_HEIGHT := -0.12
const HALF_GRID_SPAN_X := float(GRID_COLUMNS) * CELL_WIDTH * 0.5
const HALF_GRID_SPAN_Z := float(GRID_ROWS) * CELL_DEPTH * 0.5
const LAND_HALF_EXTENT_X := HALF_GRID_SPAN_X + STREET_WIDTH * 0.5
const LAND_HALF_EXTENT_Z := HALF_GRID_SPAN_Z + STREET_WIDTH * 0.5
const KIND_COLORS := {
	"residential": Color("a4afb7"),
	"shop": Color("e9b866"),
	"factory": Color("749cac"),
	"medical": Color("85c3ab"),
	"police": Color("879dc6"),
}
const KIND_NAMES := {
	"residential": "住宅", "shop": "商店", "factory": "工厂",
	"medical": "医疗", "police": "公安",
}
const KIND_ACCENTS := {
	"residential": Color("728795"), "shop": Color("ffbd72"),
	"factory": Color("bba2ef"), "medical": Color("74edba"), "police": Color("79baff"),
}
const LABEL_FONT = preload("res://assets/fonts/NotoSansSC-Regular.ttf")
const RESIDENTIAL_MODELS: Array[PackedScene] = [
	preload("res://model/居民楼.glb"), preload("res://model/居民楼(1).glb"),
	preload("res://model/居民楼3.glb"), preload("res://model/居民楼4.glb"),
	preload("res://model/居民楼5.glb"),
]
const FACTORY_MODELS: Array[PackedScene] = [preload("res://model/工厂1.glb"), preload("res://model/工业机房楼.glb")]
const SHOP_MODEL = preload("res://model/商店.glb")
const MEDICAL_MODEL = preload("res://model/医疗点.glb")
const RESIDENTIAL_COLLISIONS: Array[Shape3D] = [
	preload("res://assets/collisions/buildings/residential_0.res"),
	preload("res://assets/collisions/buildings/residential_1.res"),
	preload("res://assets/collisions/buildings/residential_2.res"),
	preload("res://assets/collisions/buildings/residential_3.res"),
	preload("res://assets/collisions/buildings/residential_4.res"),
]
const FACTORY_COLLISIONS: Array[Shape3D] = [
	preload("res://assets/collisions/buildings/factory_0.res"),
	preload("res://assets/collisions/buildings/factory_1.res"),
]
const SHOP_COLLISION = preload("res://assets/collisions/buildings/shop.res")
const MEDICAL_COLLISION = preload("res://assets/collisions/buildings/medical.res")
const WET_STREET_SHADER = preload("res://materials/wet_street.gdshader")
const RESIDENTIAL_SHADER = preload("res://materials/weathered_residential.gdshader")
const WATER_SHADER = preload("res://materials/water_surface.gdshader")
const OCCLUSION_SHADER = preload("res://materials/occlusion_tech.gdshader")
const WATER_EFFECTS = preload("res://water_effects.gd")
const OCCLUSION_TRANSPARENCY := 0.68
const OCCLUSION_FADE_SPEED := 5.5
const CAMERA_OCCLUSION_MASK := 1 << 3
const OCCLUSION_REQUIRED_SAMPLES := 5

var seed_value: int = 104729
var land_rect := Rect2(-LAND_HALF_EXTENT_X, -LAND_HALF_EXTENT_Z, LAND_HALF_EXTENT_X * 2.0, LAND_HALF_EXTENT_Z * 2.0)
var shallow_rect := Rect2(land_rect.position - Vector2(SHALLOW_MARGIN_X, SHALLOW_MARGIN_Z), land_rect.size + Vector2(SHALLOW_MARGIN_X, SHALLOW_MARGIN_Z) * 2.0)
var world_rect := shallow_rect.grow(DEEP_WIDTH)
var spawn_position := Vector3(-CELL_WIDTH * 0.5, 0.0, HALF_GRID_SPAN_Z)
var road_width: float = STREET_WIDTH
var block_size: float = CELL_WIDTH
var block_size_x: float = CELL_WIDTH
var block_size_z: float = CELL_DEPTH
var building_data: Array[Dictionary] = []
var encounters_data: Array[Dictionary] = []
var water_rects: Array[Rect2] = []
var water_effects: Node
var _generated: Node3D
var _building_visuals: Dictionary = {}
var _materials: Dictionary = {}
var _occluded_ids: Array[int] = []
var _residential_bounds := AABB()
var _model_bounds: Dictionary = {}
var map_plan: Dictionary = {}
var bridge_data: Array[Dictionary] = []
var map_generation := "roguelike_graph"
var goal_position := Vector3.ZERO
var graph_connected := false
var graph_edge_count := 0
var road_cells: Array[Vector2i] = []
var _street_lines_x: Array[float] = []
var _street_lines_z: Array[float] = []


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
	bridge_data.clear()
	map_plan.clear()
	road_cells.clear()
	_building_visuals.clear()
	_occluded_ids.clear()
	_materials.clear()
	var planner = ROGUELIKE_LAYOUT.new()
	map_plan = planner.plan(seed_value)
	graph_connected = bool(map_plan.get("connected", false))
	graph_edge_count = int(map_plan.get("edges", []).size())
	goal_position = _cell_world(map_plan.get("goal", Vector2i(3, 0)))
	road_cells.assign(map_plan.get("roads", []))
	_street_lines_x.clear()
	_street_lines_z.clear()
	for column in range(GRID_COLUMNS):
		_street_lines_x.append((float(column) - 3.5) * CELL_WIDTH)
	for row in range(GRID_ROWS):
		_street_lines_z.append((float(row) - 3.5) * CELL_DEPTH)
	land_rect = Rect2(-LAND_HALF_EXTENT_X, -LAND_HALF_EXTENT_Z, LAND_HALF_EXTENT_X * 2.0, LAND_HALF_EXTENT_Z * 2.0)
	shallow_rect = Rect2(land_rect.position - Vector2(SHALLOW_MARGIN_X, SHALLOW_MARGIN_Z), land_rect.size + Vector2(SHALLOW_MARGIN_X, SHALLOW_MARGIN_Z) * 2.0)
	world_rect = shallow_rect.grow(DEEP_WIDTH)
	spawn_position = _cell_world(map_plan.get("start", Vector2i(3, 7)))
	water_rects = _rect_bands(land_rect, shallow_rect)
	_generated = Node3D.new()
	_generated.name = "GeneratedCity"
	add_child(_generated)
	_create_materials()
	_create_ground()
	_create_streets()
	_prepare_building_models()
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
	# A single ray grazing a ledge or passing above a shoulder used to fade
	# the whole building. Require coverage of the torso's projected area, and
	# query only visible upper surfaces (never the wider walkable plinth).
	var next_ids: Array[int] = []
	var coverage: Dictionary = {}
	var camera_right := camera.global_basis.x.normalized()
	for height in [0.75, 1.10, 1.45]:
		for side in [-0.18, 0.0, 0.18]:
			var target: Vector3 = actor.global_position + Vector3.UP * height + camera_right * side
			if camera.is_position_behind(target):
				continue
			# Begin at the rendered near plane: geometry behind the camera or
			# clipped out of its image must not trigger a hologram.
			var screen_point := camera.unproject_position(target)
			var origin := camera.project_position(screen_point, camera.near)
			var exclusions: Array[RID] = []
			for _iteration in range(GRID_COLUMNS * GRID_ROWS):
				var query := PhysicsRayQueryParameters3D.create(origin, target, CAMERA_OCCLUSION_MASK)
				query.exclude = exclusions
				query.hit_from_inside = true
				var hit := get_world_3d().direct_space_state.intersect_ray(query)
				if hit.is_empty():
					break
				var body: Object = hit["collider"]
				if not is_instance_valid(body) or not body.has_meta("city_building_id"):
					break
				var building_id := int(body.get_meta("city_building_id"))
				coverage[building_id] = int(coverage.get(building_id, 0)) + 1
				exclusions.append(body.get_rid())
	for building_id: int in coverage:
		if int(coverage[building_id]) >= OCCLUSION_REQUIRED_SAMPLES:
			next_ids.append(building_id)
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
	# fade into a holographic material. Walking collision is untouched.
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
	for line in _street_lines_x:
		_create_shore_ramp(Vector3(line, 0.0, land_rect.end.y), 0.0)
		_create_shore_ramp(Vector3(line, 0.0, land_rect.position.y), PI)
	for line in _street_lines_z:
		_create_shore_ramp(Vector3(land_rect.end.x, 0.0, line), PI * 0.5)
		_create_shore_ramp(Vector3(land_rect.position.x, 0.0, line), -PI * 0.5)
	# The dispersed grid has no centre line; retain a central entry on each
	# shore so approaches from open land can also return from the shelf.
	_create_shore_ramp(Vector3(0.0, 0.0, land_rect.end.y), 0.0)
	_create_shore_ramp(Vector3(0.0, 0.0, land_rect.position.y), PI)
	_create_shore_ramp(Vector3(land_rect.end.x, 0.0, 0.0), PI * 0.5)
	_create_shore_ramp(Vector3(land_rect.position.x, 0.0, 0.0), -PI * 0.5)
	# Non-solid short edge dashes distinguish the shelf without building a wall.
	for index in range(22):
		var along_x := land_rect.position.x + 2.0 + float(index) * 6.0
		var along_z := land_rect.position.y + 2.0 + float(index) * 6.0
		for sign_value in [-1.0, 1.0]:
			if along_x <= land_rect.end.x - 1.0:
				_box(_generated, "ShoreEdge", Vector3(2.5, 0.015, 0.20), Vector3(along_x, 0.011, sign_value * (LAND_HALF_EXTENT_Z - 0.13)), _materials["shore"])
			if along_z <= land_rect.end.y - 1.0:
				_box(_generated, "ShoreEdge", Vector3(0.20, 0.015, 2.5), Vector3(sign_value * (LAND_HALF_EXTENT_X - 0.13), 0.011, along_z), _materials["shore"])


func _create_streets() -> void:
	# The planner marks non-building cells as roads.  They stay on the shared
	# land floor, so these meshes are purely visual and cannot create an air wall.
	var roads: Array = map_plan.get("roads", [])
	for cell: Vector2i in roads:
		var center := _cell_world(cell)
		_box(_generated, "PlannedRoadCell", Vector3(CELL_WIDTH - 0.35, 0.012, CELL_DEPTH - 0.35), center + Vector3.UP * 0.012, _materials["pavement"])
		_box(_generated, "RoadDash", Vector3(0.16, 0.014, 2.8), center + Vector3.UP * 0.025, _materials["line"])
	for street: Dictionary in map_plan.get("streets", []):
		var start := _cell_world(street["a"])
		var finish := _cell_world(street["b"])
		var middle := (start + finish) * 0.5 + Vector3.UP * 0.022
		var length := start.distance_to(finish)
		var wide := STREET_WIDTH if bool(street.get("wide", false)) else 5.6
		var dimensions := Vector3(length + wide, 0.014, wide) if absf(finish.x - start.x) > absf(finish.z - start.z) else Vector3(wide, 0.014, length + wide)
		_box(_generated, "PlannedStreet", dimensions, middle, _materials["road"])
	# Render every segment of the seeded graph on the shared land floor.
	# Doglegs must affect the visible streets as well as encounter placement.
	var routes := Node3D.new()
	routes.name = "GroundGraphRoutes"
	_generated.add_child(routes)
	for edge: Dictionary in map_plan.get("edges", []):
		var points := _graph_ground_points(edge)
		for index in range(points.size() - 1):
			var start := points[index]
			var finish := points[index + 1]
			var offset := finish - start
			var length := offset.length()
			var heading := atan2(offset.x, offset.z)
			var road := _box(routes, "RouteSegment", Vector3(5.6, 0.012, length + 0.35), (start + finish) * 0.5 + Vector3.UP * 0.042, _materials["road"])
			road.rotation.y = heading
			for dash_index in range(int(length / 6.0)):
				var along := (float(dash_index) + 0.5) * 6.0
				var dash := _box(road, "RouteDash", Vector3(0.14, 0.012, 2.4), Vector3(0.0, 0.016, along - length * 0.5), _materials["line"])
				dash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _create_building_data(rng: RandomNumberGenerator) -> void:
	# Sixteen non-service cells plus the four planner service cells fill the map.
	var available_kinds: Array[String] = []
	for _index in range(12):
		available_kinds.append("residential")
	available_kinds.append_array(["factory", "factory", "factory", "police"])
	_shuffle(available_kinds, rng)
	var service_kinds: Dictionary = {}
	# Preserve both the handoff's service cells and their assigned service type.
	for cell: Vector2i in map_plan.get("services", {}):
		service_kinds[cell] = str(map_plan["services"][cell])
	var index := 0
	for cell: Vector2i in map_plan.get("cells", []):
		var kind: String = str(service_kinds[cell]) if service_kinds.has(cell) else str(available_kinds.pop_back())
		var center := _cell_world(cell)
		var height := rng.randf_range(6.5, 10.0) if kind == "residential" else rng.randf_range(7.0, 10.0)
		var model_index := -1
		if kind == "residential":
			model_index = rng.randi_range(0, RESIDENTIAL_MODELS.size() - 1)
			height = RESIDENTIAL_TARGET_HEIGHT + 0.22
		elif kind == "factory":
			model_index = rng.randi_range(0, FACTORY_MODELS.size() - 1)
		building_data.append({
			"id": index,
			"cell": cell, "kind": kind,
			"position": center,
			"door_position": center + _door_offset(cell),
			"height": height,
			"width": BUILDING_WIDTH,
			"depth": BUILDING_DEPTH,
			"model_index": model_index,
		})
		index += 1


func _cell_world(cell: Vector2i) -> Vector3:
	return Vector3((float(cell.x) - 3.5) * CELL_WIDTH, 0.0, (float(cell.y) - 3.5) * CELL_DEPTH)


func _door_offset(cell: Vector2i) -> Vector3:
	var roads: Array = map_plan.get("roads", [])
	var directions := [Vector2i.DOWN, Vector2i.RIGHT, Vector2i.UP, Vector2i.LEFT]
	for direction: Vector2i in directions:
		if cell + direction in roads:
			if direction.x != 0:
				return Vector3(direction.x * (BUILDING_WIDTH * 0.5 + 1.25), 0.0, 0.0)
			return Vector3(0.0, 0.0, direction.y * (BUILDING_DEPTH * 0.5 + 1.25))
	return Vector3(0.0, 0.0, BUILDING_DEPTH * 0.5 + 1.25)


func _create_building(data: Dictionary) -> void:
	var building := Node3D.new()
	building.name = "Building_%02d_%s" % [data["id"], data["kind"]]
	building.position = data["position"]
	_generated.add_child(building)
	var kind: String = data["kind"]
	var height: float = data["height"]
	var body_material: StandardMaterial3D = _materials[kind]
	_box(building, "Sidewalk", Vector3(BUILDING_WIDTH + 0.9, 0.018, BUILDING_DEPTH + 0.9), Vector3(0.0, 0.009, 0.0), _materials["pavement"])
	_box(building, "LowFootprint", Vector3(BUILDING_WIDTH, 0.22, BUILDING_DEPTH), Vector3(0.0, 0.11, 0.0), _materials["roof"])
	var upper := Node3D.new()
	upper.name = "OccludableUpper"
	building.add_child(upper)
	var outline := _box(building, "OcclusionFootprint", Vector3(BUILDING_WIDTH + 0.04, 0.016, BUILDING_DEPTH + 0.04), Vector3(0, 0.235, 0), _materials[kind + "_sign"])
	outline.visible = false
	_building_visuals[int(data["id"])] = {"upper": upper, "outline": outline}
	var model_fit: Node3D = null
	var model_collision: Shape3D = null
	# Interaction starts from the model footprint, not from the old street
	# marker. Greybox services keep the parcel-sized fallback below.
	data["interaction_center"] = data["position"]
	data["interaction_half_extents"] = Vector2(BUILDING_WIDTH * 0.5, BUILDING_DEPTH * 0.5)
	data["interaction_radius"] = 1.15
	if kind == "residential":
		model_fit = _add_building_model(upper, RESIDENTIAL_MODELS[int(data.get("model_index", 0))], _model_bounds["residential_%d" % int(data.get("model_index", 0))], height)
		model_collision = RESIDENTIAL_COLLISIONS[int(data.get("model_index", 0))]
	elif kind == "shop":
		model_fit = _add_building_model(upper, SHOP_MODEL, _model_bounds["shop"], height)
		model_collision = SHOP_COLLISION
	elif kind == "factory":
		var factory_index := int(data.get("model_index", 0))
		model_fit = _add_building_model(upper, FACTORY_MODELS[factory_index], _model_bounds["factory_%d" % factory_index], height)
		model_collision = FACTORY_COLLISIONS[factory_index]
	elif kind == "medical":
		model_fit = _add_building_model(upper, MEDICAL_MODEL, _model_bounds["medical"], height)
		model_collision = MEDICAL_COLLISION
	else:
		# Police remains a compact greybox facade until its new mesh is supplied.
		upper.scale = Vector3(BUILDING_WIDTH / 7.4, 1.0, BUILDING_DEPTH / 7.4)
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
		_create_building_identity(upper, kind, height, 7.4, 7.4)
	if model_fit != null:
		_create_model_collision(building, model_fit, int(data["id"]), model_collision)
		var visible_size: Vector3 = model_fit.get_meta("visible_size")
		data["interaction_half_extents"] = Vector2(maxf(visible_size.x * 0.5, 0.5), maxf(visible_size.z * 0.5, 0.5))
		# This is only an invisible representative position used to choose the
		# nearest service. E itself checks distance to the full model bounds.
		data["interaction_position"] = data["position"] + Vector3(0.0, 0.0, float(data["interaction_half_extents"].y) + 0.35)
	else:
		_create_box_collision(building, int(data["id"]), height + 0.16)


func _prepare_building_models() -> void:
	_model_bounds.clear()
	for index in range(RESIDENTIAL_MODELS.size()):
		_model_bounds["residential_%d" % index] = _measure_packed_scene_bounds(RESIDENTIAL_MODELS[index])
	for index in range(FACTORY_MODELS.size()):
		_model_bounds["factory_%d" % index] = _measure_packed_scene_bounds(FACTORY_MODELS[index])
	_model_bounds["shop"] = _measure_packed_scene_bounds(SHOP_MODEL)
	_model_bounds["medical"] = _measure_packed_scene_bounds(MEDICAL_MODEL)
	_residential_bounds = _model_bounds["residential_0"]


func _measure_packed_scene_bounds(scene: PackedScene) -> AABB:
	var sample := scene.instantiate()
	var bounds := _measure_model_bounds(sample)
	sample.free()
	return bounds


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


func _add_building_model(parent: Node3D, scene: PackedScene, bounds: AABB, target_height: float) -> Node3D:
	var fit := Node3D.new()
	fit.name = "BuildingModelFit"
	# Put the long side along the rectangular parcel's long axis, including
	# variants whose source model faces across Z. Collision uses this same basis.
	var orientation := Basis(Vector3.UP, PI * 0.5) if bounds.size.z > bounds.size.x else Basis.IDENTITY
	var oriented_bounds := Transform3D(orientation, Vector3.ZERO) * bounds
	# Keep each imported facade's aspect ratio. The height establishes the
	# visual scale, then a footprint cap prevents unusual source-unit assets
	# from spilling into the eight-metre street.
	var uniform_scale := target_height / maxf(oriented_bounds.size.y, 0.001)
	var footprint_scale := minf((BUILDING_WIDTH - 0.55) / maxf(oriented_bounds.size.x, 0.001), (BUILDING_DEPTH - 0.55) / maxf(oriented_bounds.size.z, 0.001))
	uniform_scale = minf(uniform_scale, footprint_scale)
	fit.scale = Vector3.ONE * uniform_scale
	fit.position = Vector3(-oriented_bounds.get_center().x * uniform_scale, 0.22 - oriented_bounds.position.y * uniform_scale, -oriented_bounds.get_center().z * uniform_scale)
	fit.set_meta("collision_orientation", orientation)
	fit.set_meta("visible_height", fit.position.y + oriented_bounds.end.y * uniform_scale)
	fit.set_meta("visible_size", oriented_bounds.size * uniform_scale)
	parent.add_child(fit)
	# Preserve every GLB surface material. Occlusion is applied through
	# material_override, so imported colours and textures return intact after fade.
	var model := scene.instantiate()
	model.name = "BuildingModel"
	var oriented := Node3D.new()
	oriented.name = "ModelOrientation"
	oriented.basis = orientation
	fit.add_child(oriented)
	oriented.add_child(model)
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		# Godot's imported mesh LODs reduce the cost of the fifteen tall towers.
		mesh.lod_bias = 0.4
	return fit


func _create_box_collision(parent: Node3D, building_id: int, collision_height: float) -> void:
	var collision := StaticBody3D.new()
	collision.name = "BuildingCollision"
	collision.collision_layer = 1
	collision.collision_mask = 0
	collision.set_meta("city_building_id", building_id)
	# These two greybox buildings really are solid boxes; don't create fake
	# entrances through a visible wall. Imported buildings use their own surfaces.
	_add_collision_box(collision, Vector3(BUILDING_WIDTH, collision_height, BUILDING_DEPTH), Vector3(0.0, collision_height * 0.5, 0.0))
	parent.add_child(collision)
	var facade_shape := BoxShape3D.new()
	facade_shape.size = Vector3(BUILDING_WIDTH, collision_height - 0.22, BUILDING_DEPTH)
	_create_building_occluder(parent, building_id, facade_shape, Transform3D(Basis.IDENTITY, Vector3(0.0, (collision_height + 0.22) * 0.5, 0.0)))


func _create_model_collision(parent: Node3D, model_fit: Node3D, building_id: int, surface_shape: Shape3D) -> void:
	# Shared, offline-simplified surfaces preserve recessed facades, openings,
	# balconies and stairs without cooking millions of triangles on every entry.
	var collision := StaticBody3D.new()
	collision.name = "BuildingCollision"
	collision.collision_layer = 1
	collision.collision_mask = 0
	collision.set_meta("city_building_id", building_id)
	parent.add_child(collision)
	var surface := CollisionShape3D.new()
	surface.name = "ModelSurface"
	surface.shape = surface_shape
	surface.transform = model_fit.transform * Transform3D(model_fit.get_meta("collision_orientation"), Vector3.ZERO)
	collision.add_child(surface)
	_create_building_occluder(parent, building_id, surface_shape, surface.transform)
	# Match the visible 22 cm plinth exactly; the player's step solver climbs it.
	_add_collision_box(collision, Vector3(BUILDING_WIDTH, 0.22, BUILDING_DEPTH), Vector3(0.0, 0.11, 0.0))


func _create_building_occluder(parent: Node3D, building_id: int, surface_shape: Shape3D, surface_transform: Transform3D) -> void:
	# Share the compact mesh, but isolate camera queries from walking, combat,
	# the lot-sized foundation, and other non-fading geometry.
	var occluder := StaticBody3D.new()
	occluder.name = "CameraOccluder"
	occluder.collision_layer = CAMERA_OCCLUSION_MASK
	occluder.collision_mask = 0
	occluder.set_meta("city_building_id", building_id)
	var surface := CollisionShape3D.new()
	surface.shape = surface_shape
	surface.transform = surface_transform
	occluder.add_child(surface)
	parent.add_child(occluder)


func _add_collision_box(body: StaticBody3D, dimensions: Vector3, location: Vector3) -> void:
	if dimensions.x <= 0.01 or dimensions.y <= 0.01 or dimensions.z <= 0.01:
		return
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = dimensions
	shape.shape = box
	shape.position = location
	body.add_child(shape)


func _create_building_identity(upper: Node3D, kind: String, height: float, facade_width: float, facade_depth: float) -> void:
	if kind == "residential":
		# Imported residences already include their own roof equipment.
		return
	var accent: StandardMaterial3D = _materials[kind + "_sign"]
	var front_z := facade_depth * 0.5 + 0.08
	_box(upper, "FunctionBand", Vector3(facade_width - 0.54, 0.24, 0.14), Vector3(0.0, height - 0.15, front_z), accent)
	var label := Label3D.new()
	label.name = "BuildingFunction"
	label.font = LABEL_FONT
	label.text = KIND_NAMES[kind]
	label.font_size = 40
	label.pixel_size = 0.014
	label.outline_size = 5
	label.modulate = Color("edf6f1")
	label.position = Vector3(0.0, height - 0.75, front_z + 0.05)
	upper.add_child(label)
	match kind:
		"shop":
			_box(upper, "ShopAwning", Vector3(4.9, 0.15, 0.68), Vector3(0.0, 2.15, front_z), accent)
		"medical":
			_box(upper, "MedicalCross", Vector3(1.65, 0.12, 0.5), Vector3(0.0, height + 0.23, 0.0), accent)
			_box(upper, "MedicalCross", Vector3(0.5, 0.12, 1.65), Vector3(0.0, height + 0.23, 0.0), accent)
		"police":
			_box(upper, "PoliceLight", Vector3(1.2, 0.23, 0.5), Vector3(0.0, height + 0.3, 0.0), accent)
			_box(upper, "PoliceLightDivider", Vector3(0.14, 0.25, 0.54), Vector3(0.0, height + 0.3, 0.0), _materials["door"])
		"factory":
			_box(upper, "OfficeSkylight", Vector3(3.8, 0.14, 2.0), Vector3(0.0, height + 0.21, 0.0), _materials["glass"])


func _create_encounters(rng: RandomNumberGenerator) -> void:
	var candidates: Array[Dictionary] = []
	# Handoff edges are bridge routes at y=8.  Project one clear segment of
	# each route onto the ground and retain the complete elevated representation
	# as bridge_data for a future stairs/flying traversal system.
	for edge: Dictionary in map_plan.get("edges", []):
		var points: Array = edge.get("points", [])
		if points.size() < 2:
			continue
		var longest := -1.0
		var selected_a := Vector2.ZERO
		var selected_b := Vector2.ZERO
		for point_index in range(points.size() - 1):
			var point_a: Vector2 = points[point_index]
			var point_b: Vector2 = points[point_index + 1]
			var segment_length := point_a.distance_to(point_b)
			if segment_length > longest:
				longest = segment_length
				selected_a = point_a
				selected_b = point_b
		var endpoint_a := _layout_point_to_world(selected_a)
		var endpoint_b := _layout_point_to_world(selected_b)
		var midpoint := (endpoint_a + endpoint_b) * 0.5
		var axis := (endpoint_b - endpoint_a).normalized()
		var bridge := edge.duplicate(true)
		bridge["ground_points"] = _graph_ground_points(edge)
		var elevated_points: Array[Vector3] = []
		for point: Vector3 in bridge["ground_points"]:
			elevated_points.append(point + Vector3.UP * 8.0)
		bridge["world_points"] = elevated_points
		bridge["endpoint_a"] = endpoint_a + Vector3.UP * 8.0
		bridge["endpoint_b"] = endpoint_b + Vector3.UP * 8.0
		bridge["ground_endpoint_a"] = endpoint_a
		bridge["ground_endpoint_b"] = endpoint_b
		bridge["elevation"] = 8.0
		bridge_data.append(bridge)
		if midpoint.distance_to(spawn_position) > 10.0:
			candidates.append({"position": midpoint, "axis": axis, "endpoint_a": endpoint_a, "endpoint_b": endpoint_b, "graph_edge": bridge})
	# A very short graph on an unusual seed should still produce the promised
	# eight fights.  Planner streets are the deterministic ground fallback.
	for street: Dictionary in map_plan.get("streets", []):
		if candidates.size() >= 16:
			break
		var endpoint_a := _cell_world(street["a"])
		var endpoint_b := _cell_world(street["b"])
		var midpoint := (endpoint_a + endpoint_b) * 0.5
		if midpoint.distance_to(spawn_position) > 10.0:
			candidates.append({"position": midpoint, "axis": (endpoint_b - endpoint_a).normalized(), "endpoint_a": endpoint_a, "endpoint_b": endpoint_b, "ground_route": true})
	_shuffle(candidates, rng)
	for index in range(mini(8, candidates.size())):
		var data: Dictionary = candidates[index].duplicate()
		data["id"] = index
		encounters_data.append(data)


func _layout_point_to_world(point: Vector2) -> Vector3:
	return Vector3(point.x * CELL_WIDTH / ROGUELIKE_LAYOUT.CELL, 0.0, point.y * CELL_DEPTH / ROGUELIKE_LAYOUT.CELL)


func _graph_ground_points(edge: Dictionary) -> Array[Vector3]:
	var points: Array[Vector3] = []
	for point: Vector2 in edge.get("points", []):
		points.append(_layout_point_to_world(point))
	return points


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
