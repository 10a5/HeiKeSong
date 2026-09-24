extends "res://main.gd"
## First floor: Map C grows model-sized buildings along generated street edges.

const CITY = preload("res://first_floor_map.gd")
const ENCOUNTER = preload("res://street_encounter.gd")
const BUILDING = preload("res://city_building.gd")
const OVERLAY = preload("res://city_overlay.gd")
const CATALOG = preload("res://card_catalog.gd")
const EROSION = preload("res://erosion_system.gd")
const BOSS_ARENA = preload("res://boss_arena.gd")
const FLOOR_ENDING = preload("res://floor_ending.gd")
const LEVELS = preload("res://level_stats.gd")

## Which authored floor this scene plays. The subclass scenes set this before
## `_ready()` runs; the value selects one row of `level_stats.gd`, which owns
## the map size, street enemy scaling and Boss health for that floor.
@export var floor_index: int = LEVELS.FLOOR_ONE

var city_map: Node3D
var services: Array[Node3D] = []
var encounters: Array[Node3D] = []
var city_overlay: Control
var hud_canvas: CanvasLayer
var credits: int = 40
var map_seed: int = 0
var water_zone: String = "land"
var lost_in_water := false
var _event_rng := RandomNumberGenerator.new()
var _paused_before_map := false
var _window_lights: Array[OmniLight3D] = []
var _light_update_left := 0.0
var erosion: Node
var boss_arena: Node3D
var boss_target: CharacterBody3D
var _boss_transitioning := false
var _boss_active := false
var _boss_pending := false
var _boss_transition_callback: Callable
var _boss_victory_reached := false
## The Boss-victory ending director (`floor_ending.gd`), live from the moment the
## mirror falls until the next floor takes the tree.
var ending
## Destination streamed while the ending plays. Empty on the deepest floor, which
## returns to the arena instead of changing scenes.
var _ending_next_scene := ""
## Duel-floor spawn captured before the arena sinks. The deepest floor hands the
## player back here, and it has to be sampled while the floor is still standing:
## a static body's transform change is not visible to a ray cast in the same frame.
var _ending_arena_spawn := Vector3.ZERO
## Set once the victory Matrix fade has covered the screen, so the scene switch
## cannot run twice from a repeated death report.
var _floor_complete := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	floor_index = LEVELS.clamp_floor(floor_index)
	_create_materials()
	_create_environment()
	deck = DECK_SCRIPT.new()
	deck.name = "Deck"
	add_child(deck)
	deck.setup(player)
	inventory = IMPLANT_INVENTORY.new()
	inventory.name = "ImplantInventory"
	add_child(inventory)
	inventory.setup(player, deck)
	_create_camera()
	camera.far = 350.0
	var canvas := CanvasLayer.new()
	canvas.name = "HUD"
	add_child(canvas)
	hud_canvas = canvas
	hud = HUD_SCRIPT.new()
	hud.name = "Interface"
	canvas.add_child(hud)
	hud.setup(player, deck)
	hud.set_implant_inventory(inventory)
	hud.card_requested.connect(_on_card_requested)
	hud.reset_requested.connect(restart)
	hud.pause_requested.connect(toggle_pause)
	hud.browser_requested.connect(open_card_browser)
	hud.browser_close_requested.connect(close_card_browser)
	_setup_adaptive_brain()
	_setup_reward_flow(canvas)
	city_overlay = OVERLAY.new()
	city_overlay.name = "CityOverlay"
	canvas.add_child(city_overlay)
	city_overlay.set_floor(self)
	city_overlay.map_toggle_requested.connect(toggle_city_map)
	city_overlay.close_requested.connect(close_city_map)
	_setup_shop_system(canvas)
	erosion = EROSION.new()
	erosion.name = "ErosionSystem"
	add_child(erosion)
	erosion.changed.connect(_on_erosion_changed)
	erosion.boss_threshold_reached.connect(_start_boss_transition)
	erosion.phase_changed.connect(_on_erosion_phase_changed)
	erosion.depleted.connect(_on_boss_erosion_depleted)
	hud.set_erosion_state(erosion.value, erosion.max_value, false, "移动 +1/秒 · 静止 +1/3秒")
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


## One row of `level_stats.gd` for the floor this scene plays. Everything the
## later floors change (map size, street stats, Boss pool, reward scale) is read
## from here, so a new floor is a scene plus one table row.
func _floor_config() -> Dictionary:
	return LEVELS.config(floor_index)


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
	# A retry must be able to interrupt the victory ending, which owns the
	# camera, the environment and a hidden HUD while it plays.
	_abort_boss_ending()
	# R/N may interrupt the Boss Matrix fade before its one-shot `covered`
	# callback runs. Disconnect it before reusing the same HUD transition node.
	if is_instance_valid(hud) and is_instance_valid(hud.matrix_transition):
		var effect: Control = hud.matrix_transition
		if _boss_transition_callback.is_valid() and effect.covered.is_connected(_boss_transition_callback):
			effect.covered.disconnect(_boss_transition_callback)
		effect.stop()
	_boss_transition_callback = Callable()
	_floor_complete = false
	if is_instance_valid(boss_arena):
		boss_arena.queue_free()
		boss_arena = null
	boss_target = null
	_boss_transitioning = false
	_boss_active = false
	_boss_pending = false
	_boss_victory_reached = false
	if is_instance_valid(erosion):
		erosion.reset()
	if is_instance_valid(reward_flow):
		reward_flow.reset()
	if is_instance_valid(shop_system):
		shop_system.reset_run()
	if is_instance_valid(inventory):
		inventory.reset_inventory()
	deck.clear_purchased_cards()
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
	var config := _floor_config()
	city_map = CITY.new()
	city_map.name = "GeneratedDistrict"
	add_child(city_map)
	# The floor table drives the district, not the map class: the same growth
	# algorithm produces a longer, denser street grid and tougher residents on
	# later floors while the first floor keeps its original numbers.
	city_map.map_size = float(config.get("map_size", 100.0))
	city_map.enemy_health_multiplier = float(config.get("street_enemy_health", 1.0))
	city_map.enemy_damage_multiplier = float(config.get("street_enemy_damage", 1.0))
	city_map.encounter_target = int(config.get("encounter_count", 8))
	city_map.generate(map_seed)
	for data: Dictionary in city_map.building_data:
		var building := BUILDING.new()
		building.name = "Building_%s" % str(data["id"])
		add_child(building)
		building.setup(data, player, deck, self)
		services.append(building)
	credits = int(config.get("starting_credits", 40))
	for data: Dictionary in city_map.encounters_data:
		var encounter := ENCOUNTER.new()
		encounter.name = "StreetEncounter%d" % encounters.size()
		add_child(encounter)
		encounter.setup(data, player, self)
		encounters.append(encounter)
	enemy = encounters[0].foe if not encounters.is_empty() else null
	if is_instance_valid(boss_brain):
		boss_brain.reset_observation()
		if boss_brain.has_method("attach_opponent"):
			boss_brain.attach_opponent(enemy)
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
	hud.set_boss_target(null)
	hud.set_erosion_state(erosion.value if is_instance_valid(erosion) else 0, erosion.max_value if is_instance_valid(erosion) else 100, false, "移动 +1/秒 · 静止 +1/3秒")
	hud.set_paused(false)
	_configure_floor_hud()
	_light_update_left = 0.0
	_update_window_lights()
	player.status_changed.emit("%s · 沿街探索，E 交互" % _district_short_name(), false)


## "第一层" / "第二层" / "第三层" without the district suffix, for status lines.
func _district_short_name() -> String:
	var district := LEVELS.district_title(floor_index)
	var separator := district.find(" · ")
	return district.substr(0, separator) if separator > 0 else district


func _configure_floor_hud() -> void:
	var config := _floor_config()
	hud.set_location(str(config.get("title", "神经断层")), LEVELS.district_title(floor_index), "R  重试本图")
	hud.card_browser.discovery_hint = "商店 / 工厂 / 公安局"
	hud.get_node("pause_hint").text = "ESC 继续 / R 重试 / N 新地图"
	hud.set_defeat_text("探索失败 · 按 R 重试", "N 生成新的%s" % _district_short_name())


func restart() -> void:
	regenerate_floor(map_seed)


func _physics_process(delta: float) -> void:
	if paused or player.is_dead:
		return
	super._physics_process(delta)
	_maybe_start_boss_transition()
	_check_boss_victory()
	if is_instance_valid(erosion) and not _boss_transitioning:
		var moving := Vector2(player.velocity.x, player.velocity.z).length() > 0.05
		erosion.set_combat_active(_is_in_combat())
		erosion.process_activity(delta, moving, player.is_action_locked())
	_update_water()
	_light_update_left -= delta
	if _light_update_left <= 0.0:
		_light_update_left = 0.20
		_update_window_lights()


func _process(delta: float) -> void:
	super._process(delta)
	_maybe_start_boss_transition()
	if paused or player.is_dead or not is_instance_valid(city_map):
		return
	# Match the camera pose used to draw this frame, including mouse orbit and
	# follow smoothing, instead of testing the previous physics frame's view.
	city_map.update_occlusion(camera, player)


func _update_window_lights() -> void:
	# Emissive windows do not illuminate streets in Compatibility. Pool four
	# shadow-free lights near the player instead of adding a light per window.
	var candidates: Array[Vector3] = []
	for building: Dictionary in city_map.building_data:
		if building["kind"] == "residential":
			candidates.append(building.get("door_position", building["position"]))
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


func encounter_cleared(encounter: Node = null) -> void:
	if not is_instance_valid(encounter) or encounter not in encounters or encounter.get_meta("reward_granted", false):
		return
	encounter.set_meta("reward_granted", true)
	var encounter_credits := int(_floor_config().get("encounter_credits", 15))
	add_credits(encounter_credits)
	if is_instance_valid(reward_flow):
		var reward_seed := map_seed + cleared_encounters() * 9176 + 29
		if is_instance_valid(encounter) and encounter.data.has("id"):
			reward_seed = map_seed + int(encounter.data["id"]) * 9176 + 29
		reward_flow.enqueue_reward("enemy", reward_flow.make_random_reward(reward_seed))
	if cleared_encounters() == encounters.size():
		message("%s街道已清理 · 金币 +%d" % [_district_short_name(), encounter_credits])
	else:
		message("街道已清理 · 金币 +%d" % encounter_credits)


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


func open_reward(source: String, reward: Dictionary) -> bool:
	return is_instance_valid(reward_flow) and bool(reward_flow.open_reward(source, reward))


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
	# The ending owns the frame while it plays: any key or click cuts the
	# collapse short, and R still restarts the floor.
	if is_instance_valid(ending) and _ending_allows_skip(event):
		ending.skip()
		get_viewport().set_input_as_handled()
		return
	if is_instance_valid(reward_flow) and reward_flow.is_open():
		super._input(event)
		return
	if is_instance_valid(shop_system) and shop_system.is_open():
		super._input(event)
		return
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
	if is_instance_valid(reward_flow) and reward_flow.is_open():
		return
	if is_instance_valid(shop_system) and shop_system.is_open():
		return
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


func is_city_map_open() -> bool:
	return is_instance_valid(city_overlay) and city_overlay.map_open


func is_shop_building(building_id: int) -> bool:
	for building in services:
		if building.building_id == building_id and building.kind == "shop":
			return building.can_interact()
	return false


func open_shop(building_id: int) -> bool:
	var opened: bool = bool(shop_system.open_shop(building_id))
	if opened and is_instance_valid(erosion):
		erosion.record_facility_entry(&"shop")
	return opened


func record_facility_entry(kind: StringName) -> bool:
	return is_instance_valid(erosion) and erosion.record_facility_entry(kind)


func _is_in_combat() -> bool:
	if _boss_active:
		return is_instance_valid(boss_target) and not boss_target.is_dead
	for encounter in encounters:
		if not is_instance_valid(encounter) or encounter.state != &"active":
			continue
		var foe: Variant = encounter.get("foe")
		if is_instance_valid(foe) and not bool(foe.get("is_dead")):
			return true
	return player.is_action_locked()


func _on_erosion_changed(current_value: int, maximum: int) -> void:
	if is_instance_valid(hud):
		hud.set_erosion_state(current_value, maximum, _boss_active, "Boss 战 · 每秒 −1" if _boss_active else "移动 +1/秒 · 静止 +1/3秒")


func _on_erosion_phase_changed(in_boss: bool) -> void:
	if is_instance_valid(hud):
		hud.set_erosion_state(erosion.value, erosion.max_value, in_boss, "Boss 战 · 每秒 −1" if in_boss else "移动 +1/秒 · 静止 +1/3秒")


func _start_boss_transition() -> void:
	if _boss_transitioning or _boss_active or not is_instance_valid(hud):
		return
	_boss_pending = true
	_maybe_start_boss_transition()


func _maybe_start_boss_transition() -> void:
	if not _boss_pending or _boss_transitioning or _boss_active or not is_instance_valid(hud):
		return
	if is_instance_valid(reward_flow) and reward_flow.is_open():
		return
	if is_instance_valid(shop_system) and shop_system.is_open():
		return
	if is_city_map_open() or hud.is_browser_open():
		return
	_boss_pending = false
	_boss_transitioning = true
	paused = true
	get_tree().paused = true
	erosion.set_paused(true)
	erosion.start_boss_phase()
	hud.set_boss_target(null)
	hud.set_location("侵蚀临界", "数字雨协议 · 决战场加载中", "R  重置本图")
	var effect: Control = hud.matrix_transition
	_boss_transition_callback = _on_boss_transition_covered
	effect.covered.connect(_boss_transition_callback, CONNECT_ONE_SHOT)
	effect.play_in(0.30)


func _on_boss_transition_covered() -> void:
	if not _boss_transitioning:
		return
	for service in services:
		if is_instance_valid(service):
			service.set_process(false)
	for encounter in encounters:
		if is_instance_valid(encounter):
			encounter.set_physics_process(false)
			var foe: Variant = encounter.get("foe")
			if is_instance_valid(foe):
				foe.set_physics_process(false)
	# Street threats are parked for the duel, so their prompts must not linger
	# over the arena: a frozen foe never gets another frame to retire them.
	if is_instance_valid(player) and player.has_method("clear_threat_warnings"):
		player.clear_threat_warnings()
	if is_instance_valid(city_map):
		city_map.visible = false
	for light in _window_lights:
		light.visible = false
	boss_arena = BOSS_ARENA.new()
	boss_arena.name = "BossArena"
	boss_arena.position = Vector3(0.0, 32.0, 0.0)
	# Later floors use the same duel with a thicker mirror health pool and
	# harder-hitting mirror combos; every telegraph and card effect is unchanged.
	if boss_arena.has_method("set_floor_scaling"):
		boss_arena.set_floor_scaling(float(_floor_config().get("boss_health_multiplier", 1.0)), float(_floor_config().get("boss_damage_multiplier", 1.0)))
	add_child(boss_arena)
	_finish_boss_load.call_deferred()


func _finish_boss_load() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not _boss_transitioning or not is_instance_valid(boss_arena):
		return
	player.spawn_position = boss_arena.player_spawn()
	player.global_position = player.spawn_position
	player.velocity = Vector3.ZERO
	# Boss fights use the imported arena mesh as the only physical boundary.
	# The former rectangular clamp created an invisible air wall around the
	# player; leave movement open so the duel can use the whole arena floor.
	player.bounds_enabled = false
	player.arena_rect = boss_arena.world_bounds()
	boss_target = boss_arena.spawn_boss(player)
	if is_instance_valid(boss_brain) and boss_brain.has_method("attach_opponent"):
		boss_brain.attach_opponent(boss_target)
	_boss_active = true
	_boss_transitioning = false
	_boss_victory_reached = false
	paused = false
	get_tree().paused = false
	erosion.set_paused(false)
	hud.set_location("决战协议", "镜像 Boss · 观察并适应你的连招", "R  重置决战")
	hud.set_boss_target(boss_target)
	hud.set_erosion_state(erosion.value, erosion.max_value, true, "Boss 战 · 每秒 −1")
	hud.matrix_transition.play_out(0.42)


func _on_boss_erosion_depleted() -> void:
	if not _boss_active:
		return
	# Reaching zero ends the drain, not the duel. Keep the Boss active so the
	# player can still finish the encounter; the victory check below consumes
	# this signal without changing the timer itself.
	message("侵蚀耗尽 · 决战继续", false)


## Victory rule. Beating the mirror Boss is what moves the run onward: the duel
## arena collapses, 素子 falls into the flooded basin, 雾子 is seen floating from
## above under the mirror quote, and a digital shop gate covers the switch to the
## next floor while that floor streams in. Floor one fades into floor two, floor
## two into floor three, and the last floor returns to its own arena. This is
## checked from the physics frame instead of a signal so it also works for a Boss
## that died to an area attack during its own entrance.
func _check_boss_victory() -> void:
	if not _boss_active or _boss_victory_reached or _floor_complete:
		return
	if not is_instance_valid(boss_target) or not bool(boss_target.get("is_dead")):
		return
	_boss_victory_reached = true
	message("镜像 Boss 已击败", false)
	_begin_boss_ending(LEVELS.next_floor(floor_index))


## Hands the frame to the ending director. The tree is paused here, exactly as it
## is for the two Matrix hand-offs, so gameplay nodes hold still while the
## director animates the collapse itself.
func _begin_boss_ending(next_floor_index: int) -> void:
	if _floor_complete or is_instance_valid(ending):
		return
	paused = true
	get_tree().paused = true
	_orbiting = false
	if is_instance_valid(erosion):
		erosion.set_paused(true)
	if is_instance_valid(hud):
		hud.set_boss_target(null)
		hud.set_location("断层崩塌", "水面协议 · 意识下潜", "")
	if is_instance_valid(player) and player.has_method("clear_threat_warnings"):
		player.clear_threat_warnings()
	var advances := next_floor_index > floor_index
	var next_scene := LEVELS.scene_path(next_floor_index) if advances else ""
	var next_title := LEVELS.district_title(next_floor_index) if advances else "%s 已清理" % _district_short_name()
	if is_instance_valid(boss_arena):
		_ending_arena_spawn = boss_arena.player_spawn()
	_ending_next_scene = next_scene
	ending = FLOOR_ENDING.new()
	ending.name = "FloorEnding"
	add_child(ending)
	ending.completed.connect(_on_boss_ending_completed)
	ending.setup({
		"floor": self,
		"arena": boss_arena,
		"player": player,
		"boss": boss_target,
		"camera": camera,
		"hud": hud,
		"canvas": hud_canvas,
		"next_scene": next_scene,
		"next_title": next_title,
	})
	# Stream the destination while the player watches the quote, so the gate at
	# the end of the sequence is a cache hit rather than a load screen.
	ending.request_scene_load(next_scene)
	ending.start()


func _on_boss_ending_completed() -> void:
	if _floor_complete:
		return
	if _ending_next_scene.is_empty():
		_resume_after_ending()
		return
	_advance_now()


## The deepest floor has nowhere to go, so the ending restores the arena and hands
## control back instead of changing scenes.
func _resume_after_ending() -> void:
	# The duel floor sank during the ending, so the spawn is the one sampled
	# before the collapse: a ray cast would still see the sunken plate this frame.
	_abort_boss_ending()
	_ending_next_scene = ""
	_boss_active = false
	_boss_victory_reached = true
	paused = false
	get_tree().paused = false
	if is_instance_valid(erosion):
		erosion.set_paused(false)
	var arena_spawn := _ending_arena_spawn
	if arena_spawn == Vector3.ZERO:
		arena_spawn = player.global_position
	player.spawn_position = arena_spawn
	player.reset_player()
	camera_yaw = DEFAULT_YAW
	camera_pitch = 0.93
	camera_distance = 30.0
	player.movement_yaw = camera_yaw
	_camera_target = player.global_position + Vector3.UP * 0.65
	_update_camera()
	if is_instance_valid(hud):
		hud.set_boss_target(null)
		hud.set_location("断层深处", "%s · 已清理" % _district_short_name(), "R  重置本图")
		message("%s已清理 · 这是目前最深的一层" % _district_short_name(), false)


## Frees the ending director and restores whatever it borrowed from the floor.
func _abort_boss_ending() -> void:
	if is_instance_valid(ending):
		ending.restore()
		ending.queue_free()
	ending = null


## The ending swallows any key or click as "skip the collapse"; R keeps its
## escape hatch so a live demo can always reset the floor.
func _ending_allows_skip(event: InputEvent) -> bool:
	if event is InputEventKey:
		return event.pressed and not event.echo and event.keycode != KEY_R and event.physical_keycode != KEY_R
	if event is InputEventMouseButton:
		return event.pressed
	if event is InputEventScreenTouch:
		return event.pressed
	return false


## Scene switch after the ending's digital gate has covered the screen: the swap
## itself is invisible, so this is only a pause release plus `change_scene`.
func _advance_now() -> void:
	var next_scene := _ending_next_scene
	if next_scene.is_empty() or _floor_complete:
		return
	_floor_complete = true
	_ending_next_scene = ""
	get_tree().paused = false
	get_tree().change_scene_to_file(next_scene)

