extends SceneTree
## The real first-floor scene: seeded geometry, services, street fights and water.
## Godot --headless --path . --fixed-fps 60 --script tests/test_first_floor.gd

const TEST_SEED := 7331
const STREETS_X: Array[float] = [-55.0, -33.0, -11.0, 11.0, 33.0, 55.0]
const STREETS_Z: Array[float] = [-36.0, -18.0, 0.0, 18.0, 36.0]
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
	_check(not player.bounds_enabled and _near(player.global_position.x, -11.0) and _near(player.global_position.z, 36.0), "Player spawns in the south street with greybox bounds disabled")
	await _test_seeded_layout()
	await _test_city_geometry()
	await _test_occlusion_transparency()
	await _test_water_physics()
	await _test_water_effects()
	await _test_services()
	await _test_encounters()
	await _test_restart_and_new_floor()
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
	_check(buildings.size() == 20 and floor_scene.services.size() == 20, "A 5 by 4 rectangular district contains exactly 20 building cells and service records")
	var ids: Dictionary = {}
	var cells: Dictionary = {}
	var counts := {"residential": 0, "shop": 0, "factory": 0, "medical": 0, "police": 0}
	var valid_grid := true
	var valid_sizes := true
	var valid_doors := true
	for data: Dictionary in buildings:
		var cell: Vector2i = data["cell"]
		var at: Vector3 = data["position"]
		var door: Vector3 = data["door_position"]
		valid_grid = valid_grid and cell.x in range(5) and cell.y in range(4) and not ids.has(data["id"]) and not cells.has(cell)
		valid_grid = valid_grid and _near(at.x, -44.0 + cell.x * 22.0) and _near(at.z, -27.0 + cell.y * 18.0)
		var height: float = data["height"]
		var valid_height := height > 15.0 and height < 15.5 if data["kind"] == "residential" else height >= 7.0 and height <= 10.0
		valid_sizes = valid_sizes and _near(float(data["width"]), 14.0) and _near(float(data["depth"]), 10.0) and valid_height
		valid_doors = valid_doors and _near(door.x, at.x) and door.z > at.z + 5.0 and door.z < at.z + 8.0
		ids[data["id"]] = true
		cells[cell] = true
		if counts.has(data["kind"]):
			counts[data["kind"]] += 1
		else:
			valid_grid = false
	_check(valid_grid and ids.size() == 20 and cells.size() == 20, "Every rectangular grid cell has one unique building ID")
	_check(valid_sizes, "Buildings use a compact 14 by 10 metre rectangular footprint; residences use a 3m-per-floor calibrated height")
	_check(valid_doors, "Service doors lie outside their building footprint on the south access strip")
	_check(counts == {"residential": 12, "shop": 3, "factory": 3, "medical": 1, "police": 1}, "Every seed includes residential, shop, factory, medical and police categories")
	_check(_near(city_map.road_width, 8.0) and _near(city_map.block_size_x, 22.0) and _near(city_map.block_size_z, 18.0), "Street gaps are eight metres around compact rectangular buildings")
	_check(city_map.land_rect == Rect2(-59.0, -40.0, 118.0, 80.0), "Land follows the compact rectangular district")
	_check(city_map.shallow_rect == Rect2(-81.0, -58.0, 162.0, 116.0), "The shallow shelf follows every rectangular land edge")
	_check(city_map.encounters_data.size() == 8 and floor_scene.encounters.size() == 8, "Eight street encounters are generated")
	var unique_encounters: Dictionary = {}
	var valid_encounters := true
	for data: Dictionary in city_map.encounters_data:
		var at: Vector3 = data["position"]
		var a: Vector3 = data["endpoint_a"]
		var b: Vector3 = data["endpoint_b"]
		var axis: Vector3 = data["axis"]
		valid_encounters = valid_encounters and not unique_encounters.has(at) and (_near(a.distance_to(b), 22.0) or _near(a.distance_to(b), 18.0)) and at.is_equal_approx((a + b) * 0.5)
		valid_encounters = valid_encounters and (axis.is_equal_approx(Vector3.RIGHT) or axis.is_equal_approx(Vector3.BACK))
		valid_encounters = valid_encounters and (_on_street_line(at.x) or _on_street_line(at.z)) and at.distance_to(city_map.spawn_position) > 10.0
		unique_encounters[at] = true
	_check(valid_encounters, "Encounters occupy unique street segments and leave the initial spawn clear")


func _test_city_geometry() -> void:
	var all_clear := true
	for line in STREETS_X:
		all_clear = all_clear and _ray_clear(Vector3(line, 0.8, -36.0), Vector3(line, 0.8, 36.0))
	for line in STREETS_Z:
		all_clear = all_clear and _ray_clear(Vector3(-55.0, 0.8, line), Vector3(55.0, 0.8, line))
	_check(all_clear, "All rectangular north-south and east-west streets are physically open end to end")
	var visited := {Vector2i(0, 0): true}
	var queue: Array[Vector2i] = [Vector2i.ZERO]
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_front()
		for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var neighbour: Vector2i = cell + step
			if neighbour.x < 0 or neighbour.x > 5 or neighbour.y < 0 or neighbour.y > 4 or visited.has(neighbour):
				continue
			var from := Vector3(STREETS_X[cell.x], 0.8, STREETS_Z[cell.y])
			var to := Vector3(STREETS_X[neighbour.x], 0.8, STREETS_Z[neighbour.y])
			if _ray_clear(from, to):
				visited[neighbour] = true
				queue.append(neighbour)
	_check(visited.size() == 30, "Actual collision geometry connects all 30 rectangular street intersections")
	await _park(Vector3(-11.0, 0.0, 36.0))
	Input.action_press("move_up")
	await _steps(120)
	_release_all()
	_check(player.is_on_floor() and player.global_position.z < 29.5 and _near(player.global_position.x, -11.0, 0.03), "The player can walk along the north-south street without snagging buildings")
	await _park(Vector3(-11.0, 0.0, 36.0))
	Input.action_press("move_right")
	await _steps(140)
	_release_all()
	_check(player.is_on_floor() and player.global_position.x > -0.5 and _near(player.global_position.z, 36.0, 0.03), "The player can walk along the east-west street and cross an intersection")
	var surface_collisions := true
	var shared_shapes: Dictionary = {}
	var variant_count := 0
	var residence: Dictionary = {}
	for data: Dictionary in city_map.building_data:
		if data["kind"] in ["medical", "police"]:
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
		if data["kind"] == "residential" and data["model_index"] == 0:
			residence = data
	_check(surface_collisions and variant_count >= 5, "Imported buildings share baked surface collisions; only the visible 22 cm plinth is a box")
	_check(not residence.is_empty(), "The geometry test seed includes the reference residence")
	var residential_center: Vector3 = residence["position"]
	# This facade is recessed from the 14 x 10 lot edge. The capsule must step
	# onto its concrete plinth and reach the actual wall, not stop at the parcel.
	await _park(residential_center + Vector3(0.0, 0.0, 6.5))
	Input.action_press("move_up")
	await _steps(90)
	_release_all()
	_check(player.global_position.z < residential_center.z + 4.8 and player.global_position.z > residential_center.z + 2.5, "The player reaches the recessed residence facade and cannot walk through its visible wall")
	_check(player.is_on_floor() and player.global_position.y >= 0.20, "Walking onto the visible building plinth needs no jump")


func _test_occlusion_transparency() -> void:
	for kind in ["residential", "shop", "factory"]:
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
	camera.global_position = center + Vector3(0.0, 2.5, -9.0)
	await _park(center + Vector3(0.0, 0.0, 7.0))
	camera.look_at(player.global_position + Vector3.UP * 1.1)
	city_map.update_occlusion(camera, player)
	_check(building_id in city_map._occluded_ids, "Camera occlusion rays detect the actual %s model surfaces" % data["kind"])
	city_map._set_building_occluded(building_id, false)
	city_map._update_occlusion_fades(1.0)
	camera.queue_free()


func _test_water_physics() -> void:
	var zones_valid := true
	for point in [Vector3(0, 0, 39), Vector3(58, 0, 0), Vector3(-58, 0, -39)]:
		zones_valid = zones_valid and city_map.get_water_zone(point) == "land"
	var shelf_points: Array[Vector3] = [Vector3(0, 0.5, 50), Vector3(0, 0.5, -50), Vector3(70, 0.5, 0), Vector3(-70, 0.5, 0), Vector3(70, 0.5, 50), Vector3(-70, 0.5, 50), Vector3(70, 0.5, -50), Vector3(-70, 0.5, -50)]
	for point in shelf_points:
		zones_valid = zones_valid and city_map.get_water_zone(point) == "shallow"
	for point in [Vector3(0, 0, 100), Vector3(100, 0, 0), Vector3(-100, 0, -100)]:
		zones_valid = zones_valid and city_map.get_water_zone(point) == "deep"
	_check(zones_valid, "Water classification distinguishes land, all shelf sides and corners, and deep water")
	for point in shelf_points:
		await _park(point)
		await _steps(50)
		_check(player.is_on_floor() and not player.is_dead and player.global_position.y > -0.7 and player.global_position.y < -0.25 and floor_scene.water_zone == "shallow", "Shallow water has a real standing shelf at %s" % str(Vector2(point.x, point.z)))
	await _park(Vector3(-11.0, 0.0, 38.0))
	Input.action_press("move_down")
	await _steps(100)
	_release_all()
	_check(floor_scene.water_zone == "shallow" and player.is_on_floor(), "Ordinary walking can enter the shallow shelf at a street end")
	Input.action_press("move_up")
	await _steps(150)
	_release_all()
	_check(floor_scene.water_zone == "land" and player.is_on_floor() and player.global_position.y > -0.05, "A shore ramp permits ordinary walking back to land without jumping")
	await _park(Vector3(0.0, 0.1, 92.0))
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
	await _park(Vector3(0.0, -2.2, 92.0))
	player.velocity.y = -10.0
	_check(player.request_card("roll"), "A roll can still begin while sinking before the loss threshold")
	_check(not player.take_damage(20.0), "The test roll has its normal combat evasion window")
	await _steps(5)
	_check(floor_scene.lost_in_water and player.is_dead, "Combat roll invulnerability cannot bypass deep-water loss")
	await _new_floor(TEST_SEED)


func _test_water_effects() -> void:
	await _park(Vector3(0.0, 0.5, 50.0))
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
	await _park(Vector3(0.0, 0.5, 50.0))
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
	_check(floor_scene.credits == 40 and not floor_scene.try_interact(), "The run begins with 40 credit and cannot activate remote buildings")
	await _park(shop.global_position)
	_check(shop.can_interact(), "The shop service marker is reachable from its street")
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
	player.global_position = shop.global_position
	await _steps(2)
	await _press_interact()
	_check(floor_scene.credits == 20 and deck.total_cards == total_before + 1 and deck.hand == hand_before, "Physical E at the shop spends 20 credit and adds one card without replacing the hand")
	await _press_interact()
	_check(floor_scene.credits == 0 and deck.total_cards == total_before + 2, "The shop supports a second paid purchase")
	var no_money_snapshot: Array = deck.get_card_snapshot()
	await _press_interact()
	_check(floor_scene.credits == 0 and deck.get_card_snapshot() == no_money_snapshot, "Insufficient credit cannot consume money or create a card")
	await _park(medical.global_position)
	await _press_interact()
	_check(not medical.used and _near(player.health, player.max_health), "Full health preserves the one-use medical supply")
	player.take_damage(60.0)
	await _press_interact()
	_check(medical.used and _near(player.health, 80.0) and floor_scene.credits == 0, "Medical interaction restores 40 health once without spending credit")
	player.take_damage(20.0)
	await _press_interact()
	_check(_near(player.health, 60.0), "An exhausted medical station cannot heal again")
	await _park(police.global_position)
	total_before = deck.total_cards
	await _press_interact()
	_check(police.used and floor_scene.credits == 20 and deck.total_cards == total_before + 1, "Police equipment awards one card and 20 credit")
	await _press_interact()
	_check(floor_scene.credits == 20 and deck.total_cards == total_before + 1, "The police cache cannot be claimed twice")
	await _park(factory.global_position)
	player.energy = 2.0
	var credits_before: int = floor_scene.credits
	total_before = deck.total_cards
	await _press_interact()
	var event_correct := false
	match int(factory.event_index):
		0: event_correct = floor_scene.credits == credits_before + 15 and deck.total_cards == total_before
		1: event_correct = _near(player.energy, player.max_energy) and floor_scene.credits == credits_before
		2: event_correct = deck.total_cards == total_before + 1 and floor_scene.credits == credits_before
	_check(factory.used and event_correct, "Factory E interaction resolves its seeded credit, energy or memory event")
	credits_before = floor_scene.credits
	total_before = deck.total_cards
	await _press_interact()
	_check(floor_scene.credits == credits_before and deck.total_cards == total_before, "The same factory event cannot award resources twice")
	await _park(residential.global_position)
	_check(not floor_scene.try_interact(), "Residential blocks remain scenery without an unintended reward")
	for kind in CATALOG.kinds():
		deck.unlock_kind(kind)
	var full_collection_count := 10 + CATALOG.kinds().size() - CATALOG.STARTING_UNLOCKS.size()
	await _park(shop.global_position)
	floor_scene.credits = 20
	await _press_interact()
	_check(floor_scene.credits == 20 and deck.total_cards == full_collection_count, "A completed collection and full energy leave shop credit untouched")
	player.energy = 1.0
	await _press_interact()
	_check(floor_scene.credits == 10 and _near(player.energy, player.max_energy) and deck.total_cards == full_collection_count, "After every card is restored, the shop sells one energy refill for ten credit")
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
	return player.get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _on_street_line(value: float) -> bool:
	for line in STREETS_X + STREETS_Z:
		if _near(value, line):
			return true
	return false


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
