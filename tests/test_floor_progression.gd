extends SceneTree
## Second and third floors: larger district, tougher streets, thicker Boss.
##
## Godot --headless --path . --fixed-fps 60 --script tests/test_floor_progression.gd
##
## The first floor's own behaviour is covered by tests/test_first_floor.gd. This
## suite checks the three things the later floors are allowed to change — map
## size, street enemy numbers and the mirror Boss health pool — and that nothing
## else moved: every card, service, water and erosion rule is reached through the
## same inherited first-floor controller.

const LEVELS = preload("res://level_stats.gd")
const VARIANT_ENEMY = preload("res://enemy_variant.gd")
const BOSS_ARENA = preload("res://boss_arena.gd")
const MIRROR_BOSS = preload("res://mirror_boss.gd")

const TEST_SEED := 7331
const ACTIONS: Array[String] = ["move_left", "move_right", "move_up", "move_down", "hand_1", "hand_2", "hand_3", "hand_4", "jump", "cybernetic_boost", "interact"]

var passed := 0
var failed := 0
var _floors: Dictionary = {}
var _players: Dictionary = {}
## Planned house count per floor, captured before a floor scene is freed so the
## "later floors are denser" check compares two real districts.
var _house_counts: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("Testing second and third floor scaling...")
	_test_config_table()
	_test_enemy_scaling_isolated()
	_test_boss_scaling_isolated()
	# Floor one is loaded first so the later floors can be compared against real
	# first-floor geometry instead of a hard-coded house count.
	await _load_floor(LEVELS.FLOOR_ONE)
	await _load_floor(LEVELS.FLOOR_TWO)
	await _load_floor(LEVELS.FLOOR_THREE)
	await _test_floor_one()
	await _test_floor_two()
	await _test_floor_three()
	await _test_boss_victory_advances()
	_release_all()
	for index in _floors.keys():
		var floor_scene: Node3D = _floors[index]
		if is_instance_valid(floor_scene):
			floor_scene.queue_free()
	await process_frame
	print("FLOOR PROGRESSION RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


# ---------------------------------------------------------------- config table

func _test_config_table() -> void:
	_check(LEVELS.floors() == [1, 2, 3], "Exactly three authored floors are registered")
	var scenes_valid := true
	for floor_index in LEVELS.floors():
		var path := LEVELS.scene_path(floor_index)
		scenes_valid = scenes_valid and path.begins_with("res://") and ResourceLoader.exists(path)
	_check(scenes_valid, "Every authored floor resolves to an existing scene")
	_check(LEVELS.config(9).is_empty() and LEVELS.scene_path(9).is_empty(), "An unknown floor returns no configuration instead of silently falling back to floor one")
	_check(LEVELS.clamp_floor(0) == 1 and LEVELS.clamp_floor(4) == 3, "Floor requests are clamped into the authored range")
	_check(LEVELS.next_floor(1) == 2 and LEVELS.next_floor(2) == 3 and LEVELS.next_floor(3) == 3, "Floor one advances to two, two to three, and three stays on three")
	var larger := true
	var tougher := true
	var thicker := true
	var more_enemies := true
	for floor_index in [2, 3]:
		larger = larger and LEVELS.map_size(floor_index) > LEVELS.map_size(floor_index - 1)
		tougher = tougher and LEVELS.is_harder_than(floor_index, floor_index - 1)
		thicker = thicker and LEVELS.boss_health_multiplier(floor_index) > LEVELS.boss_health_multiplier(floor_index - 1)
		more_enemies = more_enemies and int(LEVELS.config(floor_index)["encounter_count"]) > int(LEVELS.config(floor_index - 1)["encounter_count"])
	_check(larger, "Each later floor grows the district square")
	_check(tougher, "Each later floor raises street enemy health and damage")
	_check(thicker, "Each later floor deepens the mirror Boss health pool")
	_check(more_enemies, "Each later floor places more street encounters")
	_check(LEVELS.enemy_health_multiplier(1) == 1.0 and LEVELS.enemy_damage_multiplier(1) == 1.0 and LEVELS.boss_health_multiplier(1) == 1.0, "Floor one keeps the original 1.0 street and Boss multipliers")


# --------------------------------------------------------- isolated enemy stats

func _test_enemy_scaling_isolated() -> void:
	var baseline := _make_enemy(&"sword", 1.0, 1.0)
	_check(_near(baseline.max_health, 100.0) and _near(baseline.attack_damage, 40.0), "An unscaled greatsword keeps the first-floor 100 HP / 40 damage")
	var floor_two := _make_enemy(&"sword", LEVELS.enemy_health_multiplier(2), LEVELS.enemy_damage_multiplier(2))
	var floor_three := _make_enemy(&"sword", LEVELS.enemy_health_multiplier(3), LEVELS.enemy_damage_multiplier(3))
	_check(floor_two.max_health > baseline.max_health and floor_two.attack_damage > baseline.attack_damage, "The second floor's greatsword is both tougher and harder-hitting")
	_check(floor_three.max_health > floor_two.max_health and floor_three.attack_damage > floor_two.attack_damage, "The third floor's greatsword outclasses the second floor's")
	_check(_near(floor_two.max_health, 140.0) and _near(floor_two.attack_damage, 50.0), "The second floor applies its 1.4 health / 1.25 damage scale exactly once")
	var boxer_two := _make_enemy(&"boxer", LEVELS.enemy_health_multiplier(2), LEVELS.enemy_damage_multiplier(2))
	_check(_near(boxer_two.max_health, 77.0) and _near(boxer_two.attack_damage, 15.0), "The fast boxer keeps its fragile identity while scaling with the floor")
	var sniper_two := _make_enemy(&"sniper", LEVELS.enemy_health_multiplier(2), LEVELS.enemy_damage_multiplier(2))
	_check(_near(sniper_two.attack_damage, 25.0), "The sentry's resolved hit carries the scaled damage, not the unscaled 20")
	_check(_near(sniper_two.sniper_damage, VARIANT_ENEMY.AUTHORED_SNIPER_DAMAGE), "The sentry's authored base damage stays unscaled so the multiplier cannot compound across resets")
	# A reset re-applies the archetype table, so the scale must survive it
	# without compounding into 140 / 196 / ... on every retry.
	floor_two.reset_enemy()
	_check(_near(floor_two.max_health, 140.0) and _near(floor_two.attack_damage, 50.0), "Repeated resets re-apply the floor scale instead of compounding it")
	# Re-configuring the same instance must rebuild from the archetype numbers.
	floor_two.apply_stat_multipliers(1.0, 1.0)
	_check(_near(floor_two.max_health, 100.0) and _near(floor_two.attack_damage, 40.0), "Clearing the multipliers restores the first-floor street numbers")
	baseline.free()
	floor_two.free()
	floor_three.free()
	boxer_two.free()
	sniper_two.free()


func _make_enemy(kind: StringName, health_scale: float, damage_scale: float) -> Node:
	var foe := VARIANT_ENEMY.new()
	foe.configure_variant(kind)
	foe.apply_stat_multipliers(health_scale, damage_scale)
	return foe


# ----------------------------------------------------------- isolated boss pool

func _test_boss_scaling_isolated() -> void:
	var baseline = MIRROR_BOSS.new()
	_check(_near(float(baseline.max_health), 500.0), "An unscaled mirror Boss keeps its authored 500 HP duel")
	baseline.free()
	var floor_two = MIRROR_BOSS.new()
	floor_two.set_floor_scaling(LEVELS.boss_health_multiplier(2), LEVELS.boss_damage_multiplier(2))
	_check(_near(float(floor_two.max_health), 1000.0), "The second floor doubles the mirror health pool to 1000")
	_check(float(floor_two.slash_damage) > float(MIRROR_BOSS.AUTHORED_SLASH_DAMAGE), "The second floor's mirror lands harder hits")
	# The arena calls this before `add_child()`, so the first entrance, HUD bar
	# and first reset must already see the scaled pool.
	floor_two.set_floor_scaling(LEVELS.boss_health_multiplier(2), LEVELS.boss_damage_multiplier(2))
	_check(_near(float(floor_two.max_health), 1000.0), "Re-scaling the same Boss does not compound its health pool")
	_check(_near(float(floor_two.health), float(floor_two.max_health)), "A scaled Boss starts from a full pool")
	floor_two.free()
	var floor_three = MIRROR_BOSS.new()
	floor_three.set_floor_scaling(LEVELS.boss_health_multiplier(3), LEVELS.boss_damage_multiplier(3))
	_check(_near(float(floor_three.max_health), 1600.0), "The third floor's mirror pool is 1600 HP")
	var arena := BOSS_ARENA.new()
	arena.set_floor_scaling(LEVELS.boss_health_multiplier(3), LEVELS.boss_damage_multiplier(3))
	_check(_near(arena.boss_health_multiplier, 3.2) and _near(arena.boss_damage_multiplier, 1.45), "The arena forwards the floor's Boss scaling before the duel loads")
	arena.free()
	floor_three.free()


# --------------------------------------------------------------- live floors

func _load_floor(floor_index: int) -> void:
	if _floors.has(floor_index):
		return
	var scene := load(LEVELS.scene_path(floor_index)) as PackedScene
	var floor_scene := scene.instantiate() as Node3D
	root.add_child(floor_scene)
	await process_frame
	floors()[floor_index] = floor_scene
	_players[floor_index] = floor_scene.get("player")
	# Street AI and the adaptive brain are not what this suite measures, and
	# freezing them keeps a 190-house district from fighting the test.
	floor_scene.set_process(false)
	floor_scene.set_physics_process(false)
	floor_scene.set("floor_index", floor_index)
	floor_scene.call("regenerate_floor", TEST_SEED)
	await _steps(3)
	_freeze_floor(floor_scene)


func floors() -> Dictionary:
	return _floors


func _freeze_floor(floor_scene: Node3D) -> void:
	for encounter in floor_scene.get("encounters"):
		if is_instance_valid(encounter):
			encounter.set_physics_process(false)
			var foe: Variant = encounter.get("foe")
			if is_instance_valid(foe):
				foe.set_physics_process(false)


func _test_floor_two() -> void:
	var floor_scene: Node3D = _floors[LEVELS.FLOOR_TWO]
	var city_map: Node3D = floor_scene.get("city_map")
	var player: CharacterBody3D = _players[LEVELS.FLOOR_TWO]
	_check(int(floor_scene.get("floor_index")) == 2, "The second-floor scene reports floor index 2")
	_check(player.bounds_enabled == false, "The second floor keeps the greybox bounds disabled")
	_check(city_map.map_size == LEVELS.map_size(2), "The second-floor map plans inside the configured 160 metre square")
	_check(city_map.land_rect.size == Vector2(160.0, 160.0), "The second-floor land rectangle is 160 by 160 metres")
	_check(city_map.shallow_rect == Rect2(-98.0, -98.0, 196.0, 196.0), "The second-floor shallow shelf grows with the larger land rectangle")
	_check(city_map.land_rect.size.x > 100.0 and city_map.land_rect.size.y > 100.0, "The second floor's land is strictly larger than the first floor's")
	var layout: Dictionary = city_map.get("map_plan")
	var houses := (layout.get("houses", []) as Array).size()
	_house_counts[LEVELS.FLOOR_TWO] = houses
	var first_floor_houses := int(_house_counts.get(LEVELS.FLOOR_ONE, 0))
	_check(houses > 60 and houses > first_floor_houses, "The larger square grows a denser district (%d houses vs floor one's %d)" % [houses, first_floor_houses])
	_check(city_map.road_data.size() == 7 and _near(city_map.road_width, 10.0), "The second floor keeps one ten-metre main road and six four-metre branches")
	var roads_in_bounds := true
	var longest := 0.0
	for road: Dictionary in city_map.road_data:
		var points: Array = road["ground_points"]
		longest = maxf(longest, points[0].distance_to(points[1]))
		for point: Vector2 in road["footprint"]:
			roads_in_bounds = roads_in_bounds and point.x >= -80.001 and point.x <= 80.001 and point.y >= -80.001 and point.y <= 80.001
	_check(roads_in_bounds, "Every second-floor road is clipped to the new 160 metre land boundary")
	_check(longest > 100.0, "The second-floor roads are longer than the first floor's, not merely more numerous")
	var buildings: Array = city_map.get("building_data")
	var sizes_valid := true
	var stats: Dictionary = layout.get("stats", {})
	for data: Dictionary in buildings:
		sizes_valid = sizes_valid and _near(minf(float(data["width"]), float(data["depth"])), 6.0, 0.01)
	_check(sizes_valid and buildings.size() == houses, "Second-floor buildings keep the six-metre short side and match the planned houses")
	_check(float(stats.get("min_house_gap_m", 0.0)) >= 1.99 and float(stats.get("min_road_gap_m", 0.0)) >= 0.99, "The larger district still preserves the two-metre house gap and one-metre road setback")
	# Road centrelines are clipped exactly to the land edge, so an endpoint can
	# legitimately sit on the boundary, which `Rect2.has_point` reads as the
	# shelf. Test the interior instead: every midpoint and every point pulled two
	# metres back from an end must be dry land.
	var landed := true
	var land: Rect2 = city_map.land_rect
	for road: Dictionary in city_map.road_data:
		var a: Vector3 = road["ground_points"][0]
		var b: Vector3 = road["ground_points"][1]
		var direction := (b - a).normalized()
		for point in [a + direction * 2.0, b - direction * 2.0, (a + b) * 0.5]:
			landed = landed and land.has_point(Vector2(point.x, point.z)) and city_map.get_water_zone(point) == "land"
	_check(landed, "The new land boundary classifies the wider street grid as dry land")
	_check(city_map.get_water_zone(Vector3(0.0, 0.0, 90.0)) == "shallow", "The second floor's shallow shelf sits outside its own land edge, not inside floor one's")
	var config := LEVELS.config(2)
	_check(floor_scene.get("encounters").size() == int(config["encounter_count"]), "The second floor generates its configured encounter count")
	var types: Dictionary = {}
	for data: Dictionary in city_map.get("encounters_data"):
		types[String(data.get("enemy_type", ""))] = true
	_check(types.has("sword") and types.has("boxer") and types.has("sniper"), "Second-floor streets still mix sword, boxer and sniper roles")
	_check(_near(float(floor_scene.get("credits")), float(config["starting_credits"])), "The second floor starts with its configured credit allowance")
	# Street foes are created by the encounter, so read one real instance rather
	# than only the isolated numbers above.
	var sample: Variant = (floor_scene.get("encounters")[0] as Node).get("foe")
	_check(is_instance_valid(sample), "Second-floor encounters create real combat targets")
	if is_instance_valid(sample):
		var expected_health := 100.0 * LEVELS.enemy_health_multiplier(2)
		var expected_damage := 40.0 * LEVELS.enemy_damage_multiplier(2)
		if String(sample.get_variant_kind()) == "boxer":
			expected_health = 55.0 * LEVELS.enemy_health_multiplier(2)
			expected_damage = 12.0 * LEVELS.enemy_damage_multiplier(2)
		elif String(sample.get_variant_kind()) == "sniper":
			expected_damage = 20.0 * LEVELS.enemy_damage_multiplier(2)
		_check(_near(float(sample.max_health), expected_health) and _near(float(sample.attack_damage), expected_damage), "A live second-floor %s carries the scaled values" % String(sample.get_variant_kind()))
	# Services, water and the erosion rule are inherited, so a later floor must
	# still expose every building interaction type and the same 100-point meter.
	var kinds: Dictionary = {}
	for service in floor_scene.get("services"):
		kinds[str(service.kind)] = true
	_check(kinds.has("residential") and kinds.has("shop") and kinds.has("factory") and kinds.has("medical") and kinds.has("police"), "The second floor still spawns every building interaction type")
	_check(_near(float(floor_scene.get("erosion").max_value), 100.0), "The second floor keeps the first floor's 100-point erosion meter")
	_check(_near(float(floor_scene.get("player").max_health), 100.0), "The player's own health is unchanged on the second floor")
	await _test_encounter_reward(LEVELS.FLOOR_TWO)


func _test_floor_three() -> void:
	var floor_scene: Node3D = _floors[LEVELS.FLOOR_THREE]
	var city_map: Node3D = floor_scene.get("city_map")
	_check(int(floor_scene.get("floor_index")) == 3, "The third-floor scene reports floor index 3")
	_check(city_map.map_size == LEVELS.map_size(3), "The third-floor map plans inside the configured 180 metre square")
	_check(city_map.land_rect.size == Vector2(180.0, 180.0), "The third-floor land rectangle is 180 by 180 metres")
	var layout: Dictionary = city_map.get("map_plan")
	var houses := (layout.get("houses", []) as Array).size()
	_house_counts[LEVELS.FLOOR_THREE] = houses
	_check(houses > int(_house_counts.get(LEVELS.FLOOR_TWO, 0)), "The third floor grows an even denser district (%d houses)" % houses)
	_check(city_map.get_water_zone(Vector3(0.0, 0.0, 100.0)) == "shallow", "The third floor's shelf is placed from its own land edge")
	_check(floor_scene.get("encounters").size() == int(LEVELS.config(3)["encounter_count"]), "The third floor generates its configured encounter count")
	var sample: Variant = (floor_scene.get("encounters")[0] as Node).get("foe")
	if is_instance_valid(sample):
		var baseline_health := 100.0 if String(sample.get_variant_kind()) != "boxer" else 55.0
		_check(float(sample.max_health) > baseline_health, "A live third-floor %s is tougher than the first floor's" % String(sample.get_variant_kind()))
	_check(_near(float(floor_scene.get("credits")), float(LEVELS.config(3)["starting_credits"])), "The third floor starts with its configured credit allowance")
	await _test_encounter_reward(LEVELS.FLOOR_THREE)


func _test_encounter_reward(floor_index: int) -> void:
	var floor_scene: Node3D = _floors[floor_index]
	var encounter: Node = floor_scene.get("encounters")[0]
	var credits_before := int(floor_scene.get("credits"))
	floor_scene.call("encounter_cleared", encounter)
	await _steps(2)
	var expected := credits_before + int(LEVELS.config(floor_index)["encounter_credits"])
	_check(int(floor_scene.get("credits")) == expected, "A cleared encounter on floor %d awards its configured credit" % floor_index)
	var reward_flow: Node = floor_scene.get("reward_flow")
	if is_instance_valid(reward_flow) and reward_flow.is_open():
		reward_flow.call("skip")
	await _steps(2)
	_check(not floor_scene.get("paused"), "Skipping a later floor's reward resumes exploration")
	# The same encounter must not pay twice.
	floor_scene.call("encounter_cleared", encounter)
	await _steps(2)
	_check(int(floor_scene.get("credits")) == expected, "A later floor's encounter cannot pay its credit twice")


## The floors share one controller, so the first floor must still behave like the
## 100-metre, eight-encounter, unscaled district documented in docs/first-floor.md.
func _test_floor_one() -> void:
	var floor_scene: Node3D = _floors[LEVELS.FLOOR_ONE]
	var city_map: Node3D = floor_scene.get("city_map")
	var layout: Dictionary = city_map.get("map_plan")
	_house_counts[LEVELS.FLOOR_ONE] = (layout.get("houses", []) as Array).size()
	_check(int(floor_scene.get("floor_index")) == 1, "The first-floor scene default is still floor one")
	_check(_near(city_map.map_size, 100.0) and city_map.land_rect == Rect2(-50.0, -50.0, 100.0, 100.0), "Floor one still plans inside the original 100 by 100 metre square")
	_check(city_map.shallow_rect == Rect2(-68.0, -68.0, 136.0, 136.0), "Floor one still uses its original 18-metre shallow shelf")
	_check(floor_scene.get("encounters").size() == 8, "Floor one still generates exactly eight encounters")
	_check(_near(float(floor_scene.get("credits")), 40.0), "Floor one still starts with 40 credit")
	_check(int(LEVELS.config(1)["encounter_credits"]) == 15, "Floor one still awards the original 15 credit per cleared encounter")
	_check(city_map.enemy_health_multiplier == 1.0 and city_map.enemy_damage_multiplier == 1.0, "Floor one's street enemies keep unscaled health and damage")
	var sample: Variant = (floor_scene.get("encounters")[0] as Node).get("foe")
	if is_instance_valid(sample):
		var expected := 100.0 if String(sample.get_variant_kind()) != "boxer" else 55.0
		_check(_near(float(sample.max_health), expected), "A live first-floor foe keeps its documented health")
	var hud: Node = floor_scene.get("hud")
	_check(is_instance_valid(hud) and str(hud.get_location_subtitle()).begins_with("第一层"), "Floor one's HUD still names the water-front district")


## Beating the mirror Boss is what moves the run to the next floor. The check is
## driven directly so the suite does not have to simulate a full duel.
func _test_boss_victory_advances() -> void:
	var floor_scene: Node3D = _floors[LEVELS.FLOOR_TWO]
	_check(floor_scene.has_method("_check_boss_victory"), "The floor controller owns the Boss victory rule")
	_check(floor_scene.get("_boss_active") == false, "No victory can trigger before the duel loads")
	floor_scene.call("_check_boss_victory")
	await _steps(1)
	_check(floor_scene.get("_boss_victory_reached") == false, "A Boss that has not died cannot advance the run")
	_check(LEVELS.next_floor(3) == 3, "The last floor has no next scene to advance into")


# --------------------------------------------------------------------- helpers

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
