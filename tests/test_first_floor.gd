extends SceneTree
## The real first-floor scene: seeded geometry, services, street fights and water.
## Godot --headless --path . --fixed-fps 60 --script tests/test_first_floor.gd

const TEST_SEED := 7331
const ACTIONS: Array[String] = ["move_left", "move_right", "move_up", "move_down", "hand_1", "hand_2", "hand_3", "hand_4", "jump", "cybernetic_boost", "interact"]
const CATALOG = preload("res://card_catalog.gd")

var floor_scene: Node3D
var player: CharacterBody3D
var deck: Node
var city_map: Node3D
var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("Testing first-floor exploration...")
	floor_scene = load("res://floor_one.tscn").instantiate() as Node3D
	root.add_child(floor_scene)
	await process_frame
	player = floor_scene.get("player") as CharacterBody3D
	deck = floor_scene.get("deck") as Node
	floor_scene.set_process(false)
	await _new_floor(TEST_SEED)
	_check(str(ProjectSettings.get_setting("application/run/main_scene")) == "res://floor_one.tscn", "The first floor is the default playable scene")
	var adaptive_brain: Node = floor_scene.get("boss_brain") as Node
	_check(adaptive_brain != null and adaptive_brain.get("player") == player, "First floor attaches the adaptive brain despite overriding main ready")
	_check(not player.bounds_enabled and player.global_position.distance_to(city_map.spawn_position) < 0.01, "Player spawns at the planner's south road start with greybox bounds disabled")
	await _test_seeded_layout()
	await _test_city_geometry()
	await _test_occlusion_transparency()
	await _test_water_physics()
	await _test_water_effects()
	await _test_services()
	await _test_encounters()
	await _test_restart_and_new_floor()
	await _test_reward_choices()
	_release_all()
	if floor_scene.paused:
		floor_scene.toggle_pause()
	print("FIRST FLOOR RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_seeded_layout() -> void:
	var first_layout := _layout_snapshot()
	var first_events := _factory_events()
	await _new_floor(TEST_SEED)
	_check(first_layout == _layout_snapshot(), "A fixed seed reproduces building types, dimensions and encounter locations")
	_check(first_events == _factory_events(), "Factory events are deterministic for the same map seed")
	await _new_floor(TEST_SEED + 1)
	_check(first_layout != _layout_snapshot(), "A different seed produces a different district layout")
	await _new_floor(TEST_SEED)
	var buildings: Array = city_map.building_data
	var planned_houses: Array = city_map.map_plan.get("houses", [])
	_check(buildings.size() == planned_houses.size() and floor_scene.services.size() == buildings.size() and buildings.size() >= 20, "Map C creates a continuous set of houses and matching service records")
	var ids: Dictionary = {}
	var counts := {"residential": 0, "shop": 0, "factory": 0, "medical": 0, "police": 0}
	var valid_footprints := true
	var valid_sizes := true
	var valid_doors := true
	for data: Dictionary in buildings:
		var at: Vector3 = data["position"]
		var door: Vector3 = data["door_position"]
		var footprint: PackedVector2Array = data.get("footprint", PackedVector2Array())
		valid_footprints = valid_footprints and footprint.size() == 4 and not ids.has(data["id"])
		for point: Vector2 in footprint:
			valid_footprints = valid_footprints and point.x >= -50.001 and point.x <= 50.001 and point.y >= -50.001 and point.y <= 50.001
		var height: float = data["height"]
		var width := float(data["width"])
		var depth := float(data["depth"])
		var rotation := float(data.get("rotation_y", 0.0))
		var valid_height := height > 3.0 and height < 20.0
		var short_side := minf(width, depth)
		valid_sizes = valid_sizes and _near(short_side, 6.0, 0.01) and width >= 6.0 and depth >= 6.0 and valid_height and is_finite(rotation)
		var door_offset := door - at
		valid_doors = valid_doors and door_offset.length() > 0.5 and door_offset.length() < maxf(width, depth) + 3.0
		ids[data["id"]] = true
		if counts.has(data["kind"]):
			counts[data["kind"]] += 1
		else:
			valid_footprints = false
	_check(valid_footprints and ids.size() == buildings.size(), "Every Map C house has one unique ID and a complete in-bounds footprint")
	_check(valid_sizes, "Imported buildings use a six-metre short side with model-derived long sides")
	_check(valid_doors, "Every service anchor is placed near its model footprint")
	_check(counts["residential"] > 0 and counts["shop"] > 0 and counts["factory"] > 0 and counts["medical"] > 0 and counts["police"] > 0, "Every generated district includes residential, shop, factory, medical and police categories")
	_check(city_map.map_plan.get("roads", []).size() == 7 and city_map.road_data.size() == 7 and _near(city_map.road_width, 10.0), "Map C uses one ten-metre main road and six four-metre branches")
	_check(city_map.land_rect == Rect2(-50.0, -50.0, 100.0, 100.0), "Map C uses the configured 100 by 100 metre land rectangle")
	_check(city_map.shallow_rect == Rect2(-68.0, -68.0, 136.0, 136.0), "The shallow shelf follows the Map C land boundary")
	var stats: Dictionary = city_map.map_plan.get("stats", {})
	_check(float(stats.get("min_house_gap_m", 0.0)) >= 1.99 and float(stats.get("min_road_gap_m", 0.0)) >= 0.99, "Map C preserves the two-metre house gap and one-metre road setback")
	_check(city_map.encounters_data.size() == 8 and floor_scene.encounters.size() == 8, "Eight street encounters are generated from Map C roads")
	var enemy_types: Dictionary = {}
	for encounter_data: Dictionary in city_map.encounters_data:
		enemy_types[String(encounter_data.get("enemy_type", ""))] = int(enemy_types.get(String(encounter_data.get("enemy_type", "")), 0)) + 1
	_check(enemy_types.has("sword") and enemy_types.has("boxer") and enemy_types.has("sniper"), "Seeded street encounters include sword, boxer and sniper roles")
	var unique_encounters: Dictionary = {}
	var valid_encounters := true
	for data: Dictionary in city_map.encounters_data:
		var at: Vector3 = data["position"]
		var a: Vector3 = data["endpoint_a"]
		var b: Vector3 = data["endpoint_b"]
		var axis: Vector3 = data["axis"]
		valid_encounters = valid_encounters and not unique_encounters.has(at) and a.distance_to(b) > 4.0 and at.is_equal_approx((a + b) * 0.5)
		valid_encounters = valid_encounters and _near(axis.y, 0.0) and _near(axis.length(), 1.0) and at.distance_to(city_map.spawn_position) > 10.0
		unique_encounters[at] = true
	_check(valid_encounters, "Encounters occupy unique street segments and leave the initial spawn clear")


func _test_city_geometry() -> void:
	var roads_valid := true
	var roads_clear := true
	for road: Dictionary in city_map.road_data:
		var points: Array = road["ground_points"]
		var footprint: PackedVector2Array = road["footprint"]
		roads_valid = roads_valid and points.size() == 2 and footprint.size() >= 4
		roads_valid = roads_valid and points[0].distance_to(points[1]) > 10.0
		roads_clear = roads_clear and _ray_clear(points[0] + Vector3.UP * 0.8, points[1] + Vector3.UP * 0.8)
		for point: Vector2 in footprint:
			roads_valid = roads_valid and point.x >= -50.001 and point.x <= 50.001 and point.y >= -50.001 and point.y <= 50.001
	_check(roads_valid and city_map.road_data.size() == 7, "Map C renders one clipped main road and six clipped branches")
	_check(roads_clear, "All seven road centrelines remain physically open for the player")
	var house_geometry_valid := true
	for data: Dictionary in city_map.building_data:
		var footprint: PackedVector2Array = data["footprint"]
		var expected_area := float(data["width"]) * float(data["depth"])
		house_geometry_valid = house_geometry_valid and footprint.size() == 4 and _near(absf(_polygon_area(footprint)), expected_area, 0.08)
		var node := city_map._generated.get_node("Building_%02d_%s" % [data["id"], data["kind"]]) as Node3D
		house_geometry_valid = house_geometry_valid and is_instance_valid(node) and _near(node.rotation.y, float(data["rotation_y"]), 0.001)
	_check(house_geometry_valid, "Every generated house keeps its rotated rectangular footprint and world transform")
	var stats: Dictionary = city_map.map_plan.get("stats", {})
	_check(float(stats.get("min_house_gap_m", 0.0)) >= 1.99 and float(stats.get("min_road_gap_m", 0.0)) >= 0.99, "Rotated houses keep the configured road setback and inter-house gap")
	var start: Vector3 = city_map.spawn_position
	await _park(start)
	var first_road: Dictionary = city_map.road_data[0]
	var road_axis: Vector3 = (first_road["ground_points"][1] - first_road["ground_points"][0]).normalized()
	player.movement_yaw = _yaw_for_direction(road_axis)
	Input.action_press("move_up")
	await _steps(90)
	_release_all()
	_check(player.is_on_floor() and player.global_position.distance_to(start) > 3.0, "The player can leave the Map C start road without snagging a house")
	var surface_collisions := true
	var shared_shapes: Dictionary = {}
	var variant_count := 0
	var residence: Dictionary = {}
	for data: Dictionary in city_map.building_data:
		if data["kind"] == "police":
			continue
		var building_node: Node3D = city_map._generated.get_node("Building_%02d_%s" % [data["id"], data["kind"]])
		var body := building_node.get_node("BuildingCollision") as StaticBody3D
		var surface := body.get_node_or_null("ModelSurface") as CollisionShape3D
		surface_collisions = surface_collisions and surface != null and surface.shape is ConcavePolygonShape3D
		for child in body.get_children():
			if child is CollisionShape3D and child.shape is BoxShape3D:
				surface_collisions = surface_collisions and child.shape.size.y <= 0.221
		var key := "%s_%d" % [data["kind"], data["model_index"]]
		if shared_shapes.has(key):
			surface_collisions = surface_collisions and surface.shape == shared_shapes[key]
		else:
			shared_shapes[key] = surface.shape
			variant_count += 1
		if data["kind"] == "residential" and data["model_index"] == 0 and residence.is_empty():
			residence = data
	_check(surface_collisions and variant_count >= 5, "Imported buildings share baked surface collisions; only the visible 22 cm plinth is a box")
	_check(not residence.is_empty(), "The geometry test seed includes the reference residence")
	var residential_center: Vector3 = residence["position"]
	var residential_outward: Vector3 = (residence["door_position"] - residential_center).normalized()
	await _park(residence["door_position"] + residential_outward * 0.45)
	player.movement_yaw = _yaw_for_direction(-residential_outward)
	Input.action_press("move_up")
	await _steps(70)
	_release_all()
	_check(player.global_position.distance_to(residential_center) > 0.9 and player.global_position.distance_to(residential_center) < maxf(float(residence["width"]), float(residence["depth"])) * 0.8, "The player reaches the residence footprint and cannot walk through its visible wall")
	_check(player.is_on_floor() and player.global_position.y >= 0.20, "Walking onto the visible building plinth needs no jump")


func _test_occlusion_transparency() -> void:
	for kind in ["residential", "shop", "factory", "medical"]:
		await _test_building_occlusion(_service(kind).data)


func _test_building_occlusion(data: Dictionary) -> void:
	var building_id := int(data["id"])
	city_map._set_building_occluded(building_id, true)
	city_map._update_occlusion_fades(1.0 / 60.0)
	var visuals: Dictionary = city_map._building_visuals[building_id]
	var upper: Node3D = visuals["upper"]
	var outline: MeshInstance3D = visuals["outline"]
	var geometry: Array[Node] = upper.find_children("*", "GeometryInstance3D", true, false)
	var ghost: Material = visuals["occlusion_material"]
	var fade_mid := float((ghost as ShaderMaterial).get_shader_parameter("fade")) if ghost is ShaderMaterial else 0.0
	var translucent := not geometry.is_empty()
	var tech_shader := false
	var animated_shader := false
	var shader_opacity := 0.0
	var line_speed := 0.0
	var line_density := 0.0
	if ghost is ShaderMaterial:
		var shader_material := ghost as ShaderMaterial
		var shader := shader_material.shader
		tech_shader = is_instance_valid(shader) and str(shader.resource_path).ends_with("occlusion_tech.gdshader")
		if is_instance_valid(shader):
			var shader_code := shader.code
			animated_shader = shader_code.contains("TIME") and shader_code.contains("smoothstep") and shader_code.contains("scan_phase")
		shader_opacity = float(shader_material.get_shader_parameter("opacity"))
		line_speed = float(shader_material.get_shader_parameter("line_speed"))
		line_density = float(shader_material.get_shader_parameter("line_density"))
	for item: Node in geometry:
		var override: Material = (item as GeometryInstance3D).material_override
		var alpha_valid := false
		if override is StandardMaterial3D:
			alpha_valid = _near((override as StandardMaterial3D).albedo_color.a, 0.32, 0.001)
		elif override is ShaderMaterial:
			alpha_valid = _near(float((override as ShaderMaterial).get_shader_parameter("opacity")), shader_opacity, 0.001)
		translucent = translucent and override == ghost and alpha_valid
	_check(upper.visible and translucent and outline.visible, "A sight-blocking building remains visible as translucent geometry with a footprint outline")
	_check(tech_shader and animated_shader and shader_opacity > 0.0 and shader_opacity < 1.0 and line_speed > 0.0 and line_density > 0.0, "Occluded buildings use a gradient shader with animated scan-line parameters")
	_check(fade_mid > 0.0 and fade_mid < 1.0, "Occlusion enters through a smooth fade instead of an instant material swap")
	var collision: Node = city_map._generated.get_node("Building_%02d_%s/BuildingCollision" % [building_id, data["kind"]])
	_check(is_instance_valid(collision) and collision is StaticBody3D, "Occlusion keeps the building collision body active")
	city_map._set_building_occluded(building_id, false)
	await _steps(20)
	var restored := true
	for record: Dictionary in visuals["occlusion_records"]:
		restored = restored and (record["node"] as GeometryInstance3D).material_override == record["material"]
	_check(restored and not outline.visible, "Restoring the camera view returns the building to full opacity")
	# The runtime ray must still discover the building after the parcel-wide
	# collider is removed; rendering and collision remain independent.
	var camera := Camera3D.new()
	floor_scene.add_child(camera)
	var center: Vector3 = data["position"]
	var local_axis := Vector3(0.0, 0.0, 1.0).rotated(Vector3.UP, float(data.get("rotation_y", 0.0)))
	camera.global_position = center - local_axis * 9.0 + Vector3.UP * 2.5
	await _park(center + local_axis * 7.0)
	camera.look_at(player.global_position + Vector3.UP * 1.1)
	city_map.update_occlusion(camera, player)
	_check(building_id in city_map._occluded_ids, "Camera occlusion rays detect the actual %s model surfaces" % data["kind"])
	city_map._set_building_occluded(building_id, false)
	city_map._update_occlusion_fades(1.0)
	camera.queue_free()


func _test_water_physics() -> void:
	var land: Rect2 = city_map.land_rect
	var shallow: Rect2 = city_map.shallow_rect
	var margin_x: float = (shallow.size.x - land.size.x) * 0.25
	var margin_z: float = (shallow.size.y - land.size.y) * 0.25
	var zones_valid := true
	for point in [Vector3(0, 0, land.end.y - 1.0), Vector3(land.end.x - 1.0, 0, 0), Vector3(land.position.x + 1.0, 0, land.position.y + 1.0)]:
		zones_valid = zones_valid and city_map.get_water_zone(point) == "land"
	var shelf_points: Array[Vector3] = [Vector3(0, 0.5, land.end.y + margin_z), Vector3(0, 0.5, land.position.y - margin_z), Vector3(land.end.x + margin_x, 0.5, 0), Vector3(land.position.x - margin_x, 0.5, 0), Vector3(land.end.x + margin_x, 0.5, land.end.y - margin_z), Vector3(land.position.x - margin_x, 0.5, land.end.y - margin_z), Vector3(land.end.x + margin_x, 0.5, land.position.y + margin_z), Vector3(land.position.x - margin_x, 0.5, land.position.y + margin_z)]
	for point in shelf_points:
		zones_valid = zones_valid and city_map.get_water_zone(point) == "shallow"
	for point in [Vector3(0, 0, shallow.end.y + 10.0), Vector3(shallow.end.x + 10.0, 0, 0), Vector3(shallow.position.x - 10.0, 0, shallow.position.y - 10.0)]:
		zones_valid = zones_valid and city_map.get_water_zone(point) == "deep"
	_check(zones_valid, "Water classification distinguishes land, all shelf sides and corners, and deep water")
	for point in shelf_points:
		await _park(point)
		await _steps(50)
		_check(player.is_on_floor() and not player.is_dead and player.global_position.y > -0.7 and player.global_position.y < -0.25 and floor_scene.water_zone == "shallow", "Shallow water has a real standing shelf at %s" % str(Vector2(point.x, point.z)))
	await _park(Vector3(0.0, 0.0, land.end.y - 2.0))
	Input.action_press("move_down")
	await _steps(100)
	_release_all()
	_check(floor_scene.water_zone == "shallow" and player.is_on_floor(), "Ordinary walking can enter the shallow shelf at a street end")
	Input.action_press("move_up")
	await _steps(150)
	_release_all()
	_check(floor_scene.water_zone == "land" and player.is_on_floor() and player.global_position.y > -0.05, "A shore ramp permits ordinary walking back to land without jumping")
	# Water-zone classification must not alter airborne motion at the shore.
	# Check every side with a rising and a falling actor, where the former
	# near-edge snap incorrectly zeroed both position and vertical velocity.
	var shore_air_points: Array[Vector3] = [Vector3(0.0, 1.1, land.end.y + 0.25), Vector3(0.0, 1.1, land.position.y - 0.25), Vector3(land.end.x + 0.25, 1.1, 0.0), Vector3(land.position.x - 0.25, 1.1, 0.0)]
	for shore_air_point in shore_air_points:
		for vertical_speed in [4.0, -4.0]:
			await _park(shore_air_point)
			player.global_position = shore_air_point
			player.velocity = Vector3(0.0, vertical_speed, 0.0)
			floor_scene._update_water()
			_check(player.global_position.is_equal_approx(shore_air_point) and _near(player.velocity.y, vertical_speed) and floor_scene.water_zone == "shallow", "Shore classification preserves airborne height and velocity at %s moving %s" % [str(Vector2(shore_air_point.x, shore_air_point.z)), str(vertical_speed)])
	await _park(Vector3(0.0, 0.1, shallow.end.y + 10.0))
	await _steps(15)
	_check(not player.is_on_floor() and player.global_position.y < -0.3 and floor_scene.water_zone == "deep", "Deep water has no floor and the character genuinely sinks")
	var depth := player.global_position.y
	var velocity_before := player.velocity
	floor_scene.toggle_pause()
	await _steps(30)
	_check(_near(player.global_position.y, depth) and player.velocity.is_equal_approx(velocity_before) and not floor_scene.lost_in_water, "Pause freezes sinking and prevents a hidden loss transition")
	floor_scene.toggle_pause()
	await _steps(55)
	_check(floor_scene.lost_in_water and player.is_dead and player.global_position.y < -2.4, "Sinking below the deep-water threshold causes cognitive loss")
	_send_key(KEY_R)
	await _steps(3)
	_sync_map()
	_freeze_encounters()
	_check(not floor_scene.lost_in_water and not player.is_dead and floor_scene.water_zone == "land" and player.global_position.distance_to(city_map.spawn_position) < 0.1, "R recovers from deep-water loss at the same district's safe spawn")
	await _park(Vector3(0.0, -2.2, shallow.end.y + 10.0))
	player.velocity.y = -10.0
	_check(player.request_card("roll"), "A roll can still begin while sinking before the loss threshold")
	_check(not player.take_damage(20.0), "The test roll has its normal combat evasion window")
	await _steps(5)
	_check(floor_scene.lost_in_water and player.is_dead, "Combat roll invulnerability cannot bypass deep-water loss")
	await _new_floor(TEST_SEED)


func _test_water_effects() -> void:
	var shallow_start: Vector3 = Vector3(0.0, 0.5, city_map.land_rect.end.y + (city_map.shallow_rect.size.y - city_map.land_rect.size.y) * 0.25)
	await _park(shallow_start)
	await _steps(190)
	_check(_active_ripple_count() == 0, "Standing in water lets the initial contact ripple expire")
	Input.action_press("move_right")
	await _steps(45)
	_release_all()
	var effects: Node = city_map.water_effects
	_check(player.is_on_floor() and floor_scene.water_zone == "shallow" and _active_ripple_count() >= 3, "Walking through the real shallow shelf leaves successive water ripples")
	_check(effects.material.get_shader_parameter("ripple_data") == effects.ripples, "The water material receives the active movement ripples")
	var frozen_time: float = effects.wave_time
	var frozen_ripples: PackedVector4Array = effects.ripples.duplicate()
	floor_scene.toggle_pause()
	await _steps(30)
	_check(effects.wave_time == frozen_time and effects.ripples == frozen_ripples, "Pause freezes both the water animation clock and every ripple age")
	floor_scene.toggle_pause()
	await _steps(12)
	await _steps(133)
	_check(_active_ripple_count() == 0 and effects.wave_time > frozen_time, "After movement stops, ripples expire within 2.2 seconds while background waves resume")
	player.request_jump()
	await _steps(6)
	Input.action_press("move_right")
	await _steps(14)
	_release_all()
	_check(not player.is_on_floor() and player.global_position.y > 0.2 and _active_ripple_count() == 0, "Moving above the water during a real jump does not leave surface footsteps")
	await _steps(35)
	_check(player.is_on_floor() and _active_ripple_count() > 0, "Landing back into shallow water produces a fresh contact ripple")
	_send_key(KEY_R)
	await _steps(3)
	_sync_map()
	_freeze_encounters()
	_check(floor_scene.water_zone == "land" and _active_ripple_count() == 0, "Retry clears the previous district's live water ripples")
	Input.action_press("move_right")
	await _steps(40)
	_release_all()
	_check(floor_scene.water_zone == "land" and _active_ripple_count() == 0, "Ordinary walking on the street produces no water ripples")
	await _park(shallow_start)
	await _steps(45)
	_check(_active_ripple_count() > 0, "The actor is followed by water effects after retrying")
	await _new_floor(TEST_SEED)
	_check(floor_scene.water_zone == "land" and _active_ripple_count() == 0, "Generating another district clears all previous water ripples")


func _active_ripple_count() -> int:
	var active := 0
	for ripple: Vector4 in city_map.water_effects.ripples:
		if ripple.w > 0.0:
			active += 1
	return active


func _test_services() -> void:
	var shop := _service("shop")
	var medical := _service("medical")
	var police := _service("police")
	var factory := _service("factory")
	var residential := _service("residential")
	_check(shop != null and medical != null and police != null and factory != null and residential != null, "Every building interaction type is present in the actual scene")
	var shop_upper: Node = city_map._generated.get_node("Building_%02d_shop/OccludableUpper" % int(shop.data["id"]))
	var factory_upper: Node = city_map._generated.get_node("Building_%02d_factory/OccludableUpper" % int(factory.data["id"]))
	var old_overlay_names := ["FunctionBand", "BuildingFunction", "ShopAwning", "OfficeSkylight", "DoorPath"]
	var overlays_removed := shop.get_child_count() == 0 and factory.get_child_count() == 0
	for old_name in old_overlay_names:
		overlays_removed = overlays_removed and shop_upper.find_child(old_name, true, false) == null and factory_upper.find_child(old_name, true, false) == null
	_check(overlays_removed, "Imported shop and factory keep their model surfaces without generated labels, stripes or service markers")
	_check(floor_scene.credits == 40 and not floor_scene.try_interact(), "The run begins with 40 credit and cannot activate remote buildings")
	await _park(_service_access_position(shop))
	_check(shop.can_interact(), "The shop model edge is reachable from its street")
	var total_before: int = deck.total_cards
	var hand_before: Array = deck.hand.duplicate(true)
	floor_scene.toggle_pause()
	_check(not floor_scene.try_interact() and floor_scene.credits == 40, "Paused building interaction cannot spend credit")
	floor_scene.toggle_pause()
	floor_scene.open_card_browser(&"all")
	_check(not floor_scene.try_interact(), "An open deck browser prevents building interaction")
	floor_scene.close_card_browser()
	player.global_position.y += 4.0
	_check(not floor_scene.try_interact(), "A player high above a door cannot use its service")
	player.global_position = _service_access_position(shop)
	await _steps(2)
	await _press_interact()
	_check(floor_scene.shop_system.is_shop_open() and floor_scene.paused and floor_scene.credits == 40 and deck.total_cards == total_before, "Physical E opens the shop and pauses combat without spending gold")
	await _steps(90)
	var offers: Array = floor_scene.shop_system.snapshot()["offers"]
	_check(offers.size() == 6, "The shop stocks three action cards and three implant accessories")
	floor_scene.credits = 100
	_check(floor_scene.shop_system.buy_offer(offers[0]["id"]), "The first displayed card can be purchased")
	_check(floor_scene.credits == 100 - int(offers[0]["price"]) and deck.total_cards == total_before + 1 and deck.hand == hand_before, "A purchase spends the displayed gold and adds one physical card without replacing the hand")
	_check(floor_scene.shop_system.buy_offer(offers[1]["id"]) and deck.total_cards == total_before + 2, "A second in-stock card can be purchased")
	floor_scene.credits = 0
	var no_money_snapshot: Array = deck.get_card_snapshot()
	_check(not floor_scene.shop_system.buy_offer(offers[2]["id"]), "An unaffordable offer is rejected")
	_check(floor_scene.credits == 0 and deck.get_card_snapshot() == no_money_snapshot, "Insufficient gold cannot consume money or create a card")
	floor_scene.shop_system.close()
	await _park(_service_access_position(medical))
	await _press_interact()
	_check(not medical.used and _near(player.health, player.max_health), "Full health preserves the one-use medical supply")
	player.take_damage(60.0)
	await _press_interact()
	_check(medical.used and _near(player.health, 80.0) and floor_scene.credits == 0, "Medical interaction restores 40 health once without spending credit")
	player.take_damage(20.0)
	await _press_interact()
	_check(_near(player.health, 60.0), "An exhausted medical station cannot heal again")
	await _park(_service_access_position(police))
	total_before = deck.total_cards
	await _press_interact()
	_check(police.used and floor_scene.credits == 20 and deck.total_cards == total_before + 1, "Police equipment awards one card and 20 credit")
	await _press_interact()
	_check(floor_scene.credits == 20 and deck.total_cards == total_before + 1, "The police cache cannot be claimed twice")
	await _park(_service_access_position(factory))
	var credits_before: int = floor_scene.credits
	total_before = deck.total_cards
	await _press_interact()
	var factory_flow: Node = floor_scene.get("reward_flow") as Node
	var factory_reward_open: bool = factory_flow != null and factory_flow.is_open() and floor_scene.paused and factory.used
	var factory_reward_valid := false
	if factory_reward_open:
		var pending: Dictionary = factory_flow.get("_pending")
		var reward: Dictionary = pending.get("reward", {})
		factory_reward_valid = (int(factory.event_index) == 0 and str(reward.get("type", "")) == "card" and (reward.get("options", []) as Array).size() == 2) or (int(factory.event_index) == 1 and str(reward.get("type", "")) == "implant" and not str(reward.get("kind", "")).is_empty())
		factory_flow.skip()
	await _steps(2)
	_check(factory_reward_open and factory_reward_valid and floor_scene.credits == credits_before and deck.total_cards == total_before, "Factory E opens a seeded card double-choice or implant reward")
	credits_before = floor_scene.credits
	total_before = deck.total_cards
	await _press_interact()
	_check(floor_scene.credits == credits_before and deck.total_cards == total_before, "The same factory event cannot award resources twice")
	await _park(_service_access_position(residential))
	_check(not floor_scene.try_interact(), "Residential blocks remain scenery without an unintended reward")
	for kind in CATALOG.kinds():
		deck.unlock_kind(kind)
	var full_collection_count: int = deck.total_cards
	await _park(_service_access_position(shop))
	floor_scene.credits = 50
	await _press_interact()
	_check(floor_scene.credits == 50 and deck.total_cards == full_collection_count, "Reopening the shop leaves gold and cards untouched")
	await _steps(90)
	player.energy = 1.0
	_check(floor_scene.shop_system.buy_offer(offers[2]["id"]), "Known action types can still be purchased as extra copies")
	_check(floor_scene.credits == 50 - int(offers[2]["price"]) and _near(player.energy, 1.0) and deck.total_cards == full_collection_count + 1, "The shop purchases a card rather than silently refilling energy")
	floor_scene.shop_system.close()
	_check(_deck_valid(), "Exploration rewards preserve unique physical card IDs and zone conservation")


func _test_encounters() -> void:
	await _new_floor(TEST_SEED)
	var all_dormant := true
	for encounter in floor_scene.encounters:
		all_dormant = all_dormant and str(encounter.state) == "dormant"
	_check(all_dormant, "Every street encounter is dormant at a fresh spawn")
	var tested := 0
	for encounter in floor_scene.encounters:
		await _park(encounter.global_position)
		encounter.set_physics_process(true)
		if tested == 0:
			floor_scene.toggle_pause()
			await _steps(10)
			_check(str(encounter.state) == "dormant", "Paused proximity cannot activate a street encounter")
			floor_scene.toggle_pause()
		await _steps(3)
		_check(str(encounter.state) == "active", "Entering street segment %d activates its encounter once" % tested)
		var foes := _encounter_foes(encounter)
		_check(not foes.is_empty(), "Encounter %d creates real combat targets" % tested)
		for foe in foes:
			foe.set_physics_process(false)
		var credits_before: int = floor_scene.credits
		for foe in foes:
			foe.take_damage(10000.0)
		await _steps(3)
		_check(str(encounter.state) == "cleared" and floor_scene.credits == credits_before + 15, "Clearing encounter %d awards exactly 15 credit" % tested)
		var reward_flow: Node = floor_scene.get("reward_flow") as Node
		_check(reward_flow != null and reward_flow.is_open() and floor_scene.paused, "Encounter %d opens a paused Matrix reward choice" % tested)
		if reward_flow != null and reward_flow.is_open():
			reward_flow.skip()
		await _steps(2)
		_check(not reward_flow.is_open() and not floor_scene.paused, "Skipping encounter %d reward resumes exploration" % tested)
		for foe in foes:
			if is_instance_valid(foe):
				foe.take_damage(10000.0)
		await _steps(12)
		_check(str(encounter.state) == "cleared" and floor_scene.credits == credits_before + 15, "A cleared segment %d cannot respawn or award credit repeatedly" % tested)
		tested += 1
	_check(tested == 8 and floor_scene.credits == 160, "Clearing all eight encounters produces 120 credit over the initial 40")
	_check(floor_scene.cleared_encounters() == 8, "The floor exposes all eight completed encounters to its UI")


func _test_restart_and_new_floor() -> void:
	var previous_seed: int = floor_scene.map_seed
	var layout_before := _layout_snapshot()
	var cards_before: int = deck.total_cards
	var factories_before := _factory_events()
	_send_key(KEY_R)
	await _steps(3)
	_sync_map()
	_freeze_encounters()
	_check(floor_scene.map_seed == previous_seed and _layout_snapshot() == layout_before, "R retries the same seeded district")
	_check(_factory_events() == factories_before and floor_scene.credits == 40, "Retry resets credit while preserving seeded factory outcomes")
	_check(deck.total_cards == cards_before and _deck_valid(), "Retry preserves discovered actions and reconstructs their physical cards")
	var state_reset := true
	for service in floor_scene.services:
		state_reset = state_reset and not service.used
	for encounter in floor_scene.encounters:
		state_reset = state_reset and str(encounter.state) == "dormant"
	_check(state_reset and floor_scene.cleared_encounters() == 0, "Retry restores service supplies and all eight dormant encounters")
	_check(player.global_position.distance_to(city_map.spawn_position) < 0.1 and _near(player.health, player.max_health), "Retry restores the player at the safe spawn with full health")
	floor_scene.regenerate_floor()
	await _steps(3)
	_sync_map()
	_freeze_encounters()
	_check(floor_scene.map_seed != previous_seed and _layout_snapshot() != layout_before, "Requesting a new floor chooses a different seed and layout")
	_check(deck.total_cards == cards_before and _deck_valid(), "A new district preserves the session's discovered card collection")


func _test_reward_choices() -> void:
	# Exercise both reward payloads through the same Matrix-backed modal used by
	# enemies and factories. This runs after reset assertions so run-local rewards
	# do not alter the earlier card-conservation checks.
	var reward_flow: Node = floor_scene.get("reward_flow") as Node
	var cards_before: int = deck.total_cards
	_check(floor_scene.open_reward("enemy", {"type": "card", "options": ["punch", "sweep"]}), "A card reward opens from an enemy payload")
	await _steps(40)
	_check(reward_flow.is_open() and floor_scene.paused and reward_flow.panel.visible and not floor_scene.hud.matrix_transition.is_playing(), "Card reward reveals after the Matrix transition")
	_check(reward_flow.choose_card(1), "The player can choose one of two offered cards")
	await _steps(2)
	_check(deck.total_cards == cards_before + 1 and not reward_flow.is_open() and not floor_scene.paused, "Chosen card enters the deck and closes the reward")
	var items_before: int = floor_scene.inventory.get_items().size()
	_check(floor_scene.open_reward("factory", {"type": "implant", "kind": "armor"}), "An implant reward opens from a factory payload")
	await _steps(40)
	_check(reward_flow.choose_implant(), "The player can carry the offered implant")
	await _steps(2)
	_check(floor_scene.inventory.get_items().size() == items_before + 1 and not reward_flow.is_open(), "Chosen implant enters the inventory")
	_check(floor_scene.open_reward("enemy", {"type": "card", "options": ["blink", "shot"]}), "A second reward can be opened after the first is resolved")
	await _steps(40)
	_check(reward_flow.skip(), "The player can decline a card reward")
	await _steps(2)
	_check(deck.total_cards == cards_before + 1 and not reward_flow.is_open(), "Declining leaves the deck unchanged")


func _new_floor(seed_value: int) -> void:
	_release_all()
	floor_scene.regenerate_floor(seed_value)
	await _steps(3)
	_sync_map()
	_freeze_encounters()
	player.movement_yaw = 0.0


func _sync_map() -> void:
	city_map = floor_scene.get("city_map") as Node3D
	player = floor_scene.get("player") as CharacterBody3D
	deck = floor_scene.get("deck") as Node


func _freeze_encounters() -> void:
	for encounter in floor_scene.encounters:
		encounter.set_physics_process(false)
		for foe in _encounter_foes(encounter):
			foe.set_physics_process(false)


func _park(location: Vector3) -> void:
	_release_all()
	if floor_scene.paused:
		floor_scene.toggle_pause()
	player.reset_player()
	player.global_position = location
	player.velocity = Vector3.ZERO
	player.movement_yaw = 0.0
	await _steps(2)


func _service(kind: String) -> Node3D:
	for service in floor_scene.services:
		if str(service.kind) == kind:
			return service
	return null


func _service_access_position(service: Node3D) -> Vector3:
	var data: Dictionary = service.data
	var center: Vector3 = data["position"]
	var yaw := float(data.get("rotation_y", 0.0))
	var half_extents: Vector2 = data["interaction_half_extents"]
	var local_entrance := (Vector3(data["door_position"]) - center).rotated(Vector3.UP, -yaw)
	var local_point := Vector3.ZERO
	if absf(local_entrance.x) / half_extents.x > absf(local_entrance.z) / half_extents.y:
		local_point.x = signf(local_entrance.x) * (half_extents.x + 0.65)
	else:
		local_point.z = signf(local_entrance.z) * (half_extents.y + 0.65)
	return center + local_point.rotated(Vector3.UP, yaw)


func _yaw_for_direction(direction: Vector3) -> float:
	return atan2(-direction.x, -direction.z)


func _polygon_area(polygon: PackedVector2Array) -> float:
	var area := 0.0
	for index in range(polygon.size()):
		area += polygon[index].cross(polygon[(index + 1) % polygon.size()])
	return area * 0.5


func _encounter_foes(encounter: Node) -> Array[CharacterBody3D]:
	var result: Array[CharacterBody3D] = []
	for target in get_nodes_in_group("combat_targets"):
		if target is CharacterBody3D and encounter.is_ancestor_of(target):
			result.append(target)
	return result


func _layout_snapshot() -> Dictionary:
	return {"buildings": city_map.building_data.duplicate(true), "encounters": city_map.encounters_data.duplicate(true)}


func _factory_events() -> Dictionary:
	var events: Dictionary = {}
	for service in floor_scene.services:
		if str(service.kind) == "factory":
			events[service.building_id] = service.event_index
	return events


func _ray_clear(from: Vector3, to: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)
	var excluded: Array[RID] = [player.get_rid()]
	for target in get_nodes_in_group("combat_targets"):
		if target is CollisionObject3D:
			excluded.append(target.get_rid())
	query.exclude = excluded
	return player.get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _deck_valid() -> bool:
	var seen: Dictionary = {}
	for zone in [deck.hand, deck.draw_pile, deck.discard_pile]:
		for card in zone:
			if card.is_empty():
				continue
			if seen.has(card["id"]) or not deck.is_kind_unlocked(card["kind"]):
				return false
			seen[card["id"]] = true
	return seen.size() == deck.total_cards


func _press_interact() -> void:
	Input.action_press("interact")
	await _steps(2)
	Input.action_release("interact")
	await _steps(1)


func _send_key(keycode: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	Input.parse_input_event(event)


func _steps(count: int) -> void:
	for _index in range(count):
		await physics_frame
		await process_frame


func _release_all() -> void:
	for action in ACTIONS:
		Input.action_release(action)


func _near(a: float, b: float, tolerance: float = 0.01) -> bool:
	return absf(a - b) <= tolerance


func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
		print("PASS: " + description)
	else:
		failed += 1
		push_error("FAIL: " + description)
