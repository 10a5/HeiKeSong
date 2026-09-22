extends "res://main.gd"
## First floor: grid cells contain buildings, graph edges host encounters.

const CITY = preload("res://first_floor_map.gd")
const ENCOUNTER = preload("res://street_encounter.gd")
const BUILDING = preload("res://city_building.gd")
const OVERLAY = preload("res://city_overlay.gd")
const CATALOG = preload("res://card_catalog.gd")

var city_map: Node3D
var services: Array[Node3D] = []
var encounters: Array[Node3D] = []
var city_overlay: Control
var credits: int = 40
var map_seed: int = 0
var water_zone: String = "land"
var lost_in_water := false
var _event_rng := RandomNumberGenerator.new()
var _paused_before_map := false
var _window_lights: Array[OmniLight3D] = []
var _light_update_left := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_create_materials()
	_create_environment()
	deck = DECK_SCRIPT.new()
	deck.name = "Deck"
	add_child(deck)
	deck.setup(player)
	_create_camera()
	camera.far = 350.0
	var canvas := CanvasLayer.new()
	canvas.name = "HUD"
	add_child(canvas)
	hud = HUD_SCRIPT.new()
	hud.name = "Interface"
	canvas.add_child(hud)
	hud.setup(player, deck)
	hud.card_requested.connect(_on_card_requested)
	hud.reset_requested.connect(restart)
	hud.pause_requested.connect(toggle_pause)
	hud.browser_requested.connect(open_card_browser)
	hud.browser_close_requested.connect(close_card_browser)
	city_overlay = OVERLAY.new()
	city_overlay.name = "CityOverlay"
	canvas.add_child(city_overlay)
	city_overlay.set_floor(self)
	city_overlay.map_toggle_requested.connect(toggle_city_map)
	city_overlay.close_requested.connect(close_city_map)
	for index in range(4):
		var light := OmniLight3D.new()
		light.name = "WindowLight%d" % index
		light.light_color = Color("ffc27b")
		light.light_energy = 1.35
		light.omni_range = 10.5
		light.omni_attenuation = 1.4
		light.shadow_enabled = false
		add_child(light)
		_window_lights.append(light)
	regenerate_floor()


func _create_environment() -> void:
	super._create_environment()
	# A cloudy sky supplies broad reflections even on the Compatibility renderer.
	var environment: Environment = get_node("WorldEnvironment").environment
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color("293e56")
	sky_material.sky_horizon_color = Color("7a929f")
	sky_material.ground_bottom_color = Color("182b3a")
	sky_material.ground_horizon_color = Color("607889")
	sky_material.sky_energy_multiplier = 0.75
	var sky := Sky.new()
	sky.sky_material = sky_material
	environment.sky = sky
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.background_color = Color("334c61")
	environment.ambient_light_color = Color("a6bacb")
	environment.ambient_light_energy = 0.62
	environment.fog_enabled = true
	environment.fog_light_color = Color("586f86")
	environment.fog_density = 0.002
	var key_light: DirectionalLight3D = get_node("KeyLight")
	key_light.light_color = Color("c6d7e6")
	key_light.light_energy = 0.48
	key_light.directional_shadow_max_distance = 80.0
	var fill_light: DirectionalLight3D = get_node("FillLight")
	fill_light.light_color = Color("8caccc")
	fill_light.light_energy = 0.25


func regenerate_floor(seed_value: int = -1) -> void:
	# Every entry/new district uses a fresh seed. Fixed seeds are for replay/tests.
	if seed_value < 0:
		var random := RandomNumberGenerator.new()
		random.randomize()
		seed_value = random.randi_range(1, 2147483646)
		if seed_value == map_seed:
			seed_value = (seed_value % 2147483646) + 1
	map_seed = seed_value
	_event_rng.seed = map_seed + 104729
	paused = false
	get_tree().paused = false
	_paused_before_browser = false
	_paused_before_map = false
	hud.hide_browser()
	city_overlay.close_map()
	for building in services:
		building.free()
	services.clear()
	for foe in encounters:
		foe.free()
	encounters.clear()
	if is_instance_valid(city_map):
		city_map.free()
	city_map = CITY.new()
	city_map.name = "GeneratedDistrict"
	add_child(city_map)
	city_map.generate(map_seed)
	for data: Dictionary in city_map.building_data:
		var building := BUILDING.new()
		building.name = "Building_%s" % str(data["id"])
		add_child(building)
		building.setup(data, player, deck, self)
		services.append(building)
	credits = 40
	for data: Dictionary in city_map.encounters_data:
		var encounter := ENCOUNTER.new()
		encounter.name = "StreetEncounter%d" % encounters.size()
		add_child(encounter)
		encounter.setup(data, player, self)
		encounters.append(encounter)
	enemy = encounters[0].foe if not encounters.is_empty() else null
	player.bounds_enabled = false
	player.spawn_position = city_map.spawn_position
	player.reset_player()
	city_map.water_effects.follow_actor(player)
	deck.reset_deck()
	water_zone = "land"
	lost_in_water = false
	_orbiting = false
	camera_yaw = DEFAULT_YAW
	camera_pitch = 0.93
	camera_distance = 30.0
	player.movement_yaw = camera_yaw
	_camera_target = player.global_position + Vector3.UP * 0.65
	_update_camera()
	hud.setup(player, deck)
	hud.set_paused(false)
	_configure_floor_hud()
	_light_update_left = 0.0
	_update_window_lights()
	player.status_changed.emit("第一层 · 沿街探索，E 交互", false)


func _configure_floor_hud() -> void:
	hud.set_location("神经断层", "第一层 · 水岸街区", "R  重试本图")
	hud.card_browser.discovery_hint = "商店 / 写字楼 / 公安局"
	hud.get_node("pause_hint").text = "ESC 继续 / R 重试 / N 新地图"
	hud.set_defeat_text("探索失败 · 按 R 重试", "N 生成新的第一层")


func restart() -> void:
	regenerate_floor(map_seed)


func _physics_process(delta: float) -> void:
	if paused or player.is_dead:
		return
	super._physics_process(delta)
	_update_water()
	city_map.update_occlusion(camera, player)
	_light_update_left -= delta
	if _light_update_left <= 0.0:
		_light_update_left = 0.20
		_update_window_lights()


func _update_window_lights() -> void:
	# Emissive windows do not illuminate streets in Compatibility. Pool four
	# shadow-free lights near the player instead of adding a light per window.
	var candidates: Array[Vector3] = []
	for building: Dictionary in city_map.building_data:
		if building["kind"] == "residential":
			candidates.append(building["position"] + Vector3(0, 2.4, 8.55))
	candidates.sort_custom(func(a: Vector3, b: Vector3) -> bool:
		return a.distance_squared_to(player.global_position) < b.distance_squared_to(player.global_position)
	)
	for index in range(_window_lights.size()):
		_window_lights[index].visible = index < candidates.size()
		if index < candidates.size():
			_window_lights[index].global_position = candidates[index]


func _update_water() -> void:
	var next_state: String = city_map.get_water_zone(player.global_position)
	if next_state != water_zone:
		water_zone = next_state
		if water_zone == "shallow":
			player.status_changed.emit("浅水 · 可站立", false)
		elif water_zone == "deep":
			player.status_changed.emit("深水 · 尽快返回浅水", true)
	if player.global_position.y < -2.4:
		lost_in_water = true
		player.become_lost()
		hud.set_defeat_text("沉入深水 · 意识迷失", "R 返回本图起点 / N 新地图")


func cleared_encounters() -> int:
	var count := 0
	for encounter in encounters:
		if encounter.state == &"cleared":
			count += 1
	return count


func encounter_cleared() -> void:
	add_credits(15)
	if cleared_encounters() == encounters.size():
		message("第一层街道已清理 · 信用 +15")
	else:
		message("街道已清理 · 信用 +15")


func try_interact() -> bool:
	if paused or player.is_dead or player.is_action_locked():
		return false
	var nearest: Node3D = null
	var closest := INF
	for building in services:
		if building.can_interact():
			var distance: float = player.global_position.distance_squared_to(building.global_position)
			if distance < closest:
				closest = distance
				nearest = building
	return bool(nearest.interact()) if nearest != null else false


func spend_credits(amount: int) -> bool:
	if amount < 0 or amount > credits or paused or player.is_dead:
		return false
	credits -= amount
	return true


func add_credits(amount: int) -> void:
	credits += maxi(0, amount)


func message(text: String, is_error := false) -> void:
	player.status_changed.emit(text, is_error)


func restore_health(amount: float) -> float:
	if player.is_dead or paused:
		return 0.0
	var restored := minf(maxf(amount, 0.0), player.max_health - player.health)
	player.health += restored
	player.health_changed.emit(player.health, player.max_health)
	return restored


func unlock_next_card() -> String:
	var locked: Array[String] = []
	for kind in CATALOG.kinds():
		if not deck.is_kind_unlocked(kind):
			locked.append(kind)
	if locked.is_empty():
		return ""
	var kind := locked[_event_rng.randi_range(0, locked.size() - 1)]
	return kind if deck.unlock_kind(kind) else ""


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_N:
			regenerate_floor()
			get_viewport().set_input_as_handled()
			return
		if event.physical_keycode == KEY_M:
			if not hud.is_browser_open():
				toggle_city_map()
			get_viewport().set_input_as_handled()
			return
	if city_overlay.map_open:
		if event is InputEventKey and event.pressed and not event.echo:
			if event.keycode == KEY_ESCAPE or event.keycode == KEY_TAB:
				toggle_city_map()
			elif event.keycode == KEY_R:
				restart()
		if event is InputEventKey:
			get_viewport().set_input_as_handled()
		return
	super._input(event)


func toggle_city_map() -> void:
	if hud.is_browser_open():
		return
	if city_overlay.map_open:
		city_overlay.close_map()
		paused = _paused_before_map
	else:
		_paused_before_map = paused
		city_overlay.toggle_map()
		paused = true
	get_tree().paused = paused
	_orbiting = false
	# The map is the pause presentation; keep the generic pause banner hidden.
	hud.set_paused(paused)
	if city_overlay.map_open:
		hud.get_node("pause").visible = false
		hud.get_node("pause_hint").visible = false
		hud.get("_pause_shade").visible = false


func open_card_browser(view: StringName = &"all") -> void:
	if not city_overlay.map_open:
		super.open_card_browser(view)


func close_city_map() -> void:
	if city_overlay.map_open:
		toggle_city_map()


func _unhandled_input(event: InputEvent) -> void:
	if city_overlay.map_open:
		return
	super._unhandled_input(event)
