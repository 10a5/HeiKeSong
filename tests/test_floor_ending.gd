extends SceneTree
## Boss-victory ending: the arena collapses, 素子 falls into the basin, 雾子 is
## seen from above under the mirror quote, and the digital shop gate covers the
## switch to the next floor.
##
##   godot --headless --path . --fixed-fps 60 --script tests/test_floor_ending.gd
##
## Every stage is driven through the director's own explicit `_process(delta)`
## hook, so the suite covers the whole sequence without waiting for wall-clock
## time and without a rendering device.

const LEVELS = preload("res://level_stats.gd")
const ENDING = preload("res://floor_ending.gd")
const OVERLAY = preload("res://ending_overlay.gd")
const QUOTE := "你我犹如隔镜视物，所见无非虚幻迷蒙"

const TEST_SEED := 7331
const MAX_WAIT_FRAMES := 420

var passed := 0
var failed := 0
var _floor: Node3D
var _player: CharacterBody3D
var _ending: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("Testing the Boss-victory ending...")
	_test_contract()
	await _test_victory_starts_ending()
	await _test_retry_interrupts_ending()
	await _test_stage_progression_and_resume()
	await _test_next_floor_hand_off()
	print("FLOOR ENDING RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


# ------------------------------------------------------------------- contract

func _test_contract() -> void:
	_check(ENDING.QUOTE == QUOTE, "The ending carries the mirror quote verbatim")
	_check(ENDING.STAGE_COLLAPSE == &"collapse" and ENDING.STAGE_SUBMERGE == &"submerge", "The ending names its collapse and submerge stages")
	_check(ENDING.STAGE_MIRROR == &"mirror" and ENDING.STAGE_DIGITAL == &"digital", "The ending names its mirror and digital stages")
	var overlay := OVERLAY.new()
	for method in ["begin_show", "show_quote", "start_digital", "set_load_progress", "set_load_ready", "cover_digital", "is_covered", "reset"]:
		_check(overlay.has_method(method), "The ending overlay exposes %s()" % method)
	overlay.free()
	var ends_with_next := LEVELS.next_floor(LEVELS.FLOOR_ONE) == LEVELS.FLOOR_TWO and LEVELS.next_floor(LEVELS.FLOOR_THREE) == LEVELS.FLOOR_THREE
	_check(ends_with_next, "The ending is reached on every floor and only floor one and two have a next scene")


# --------------------------------------------------------- real duel -> ending

func _test_victory_starts_ending() -> void:
	await _new_floor(LEVELS.FLOOR_ONE)
	_check(not is_instance_valid(_floor.get("ending")), "No ending director exists before the mirror dies")
	await _reach_victory()
	if not await _ending_started():
		return
	_ending = _floor.get("ending")
	_check(int(_floor.get("floor_index")) == LEVELS.FLOOR_ONE, "The first floor owns this ending")
	_check(str(_ending.call("stage")) == "collapse", "The ending opens on the collapse")
	_check(_ending.get("_next_scene") == LEVELS.scene_path(LEVELS.FLOOR_TWO), "Floor one streams floor two while the quote plays")
	_check(bool(_ending.get("_load_requested")), "The destination is requested from the resource loader before the gate opens")
	_check(_floor.get("paused") and paused, "The ending pauses the run it interrupts")
	_check(_floor.get("hud").visible == false and _floor.get("city_overlay").visible == false, "The HUD and the city overlay step aside for the cinematic")


# ------------------------------------------------------------------ retry (R)

func _test_retry_interrupts_ending() -> void:
	if not is_instance_valid(_ending):
		return
	var world := _floor.get_node_or_null("WorldEnvironment") as WorldEnvironment
	var hud: Control = _floor.get("hud")
	var city_overlay: Control = _floor.get("city_overlay")
	_floor.call("regenerate_floor", TEST_SEED)
	await _steps(3)
	_check(not is_instance_valid(_floor.get("ending")), "R frees the ending director")
	_check(_floor.get("hud").visible and _floor.get("city_overlay").visible, "R restores the HUD and the city overlay")
	_check(not paused and not bool(_floor.get("paused")), "R releases the pause the ending held")
	_check(world != null and world.environment != null and world.environment.sky != null, "R restores the district sky the ending had replaced")
	_check(is_equal_approx(_player.rotation_degrees.x, 0.0), "R clears the limp fall pose from the player body")
	var city_map: Node3D = _floor.get("city_map")
	_check(_player.global_position.distance_to(city_map.spawn_position) < 12.0, "R returns the player to the regenerated district spawn")
	_check(hud.visible and is_instance_valid(city_overlay), "The restored HUD is the same instance the floor keeps using")


# ----------------------------------------- staged sequence and deepest floor

func _test_stage_progression_and_resume() -> void:
	# The deepest authored floor has no next scene: it plays the same ending and
	# then hands the arena back, which is also the cheapest way to watch every
	# stage of the sequence without triggering a scene switch.
	await _new_floor(LEVELS.FLOOR_THREE)
	await _reach_victory()
	if not await _ending_started():
		return
	_ending = _floor.get("ending")
	_check(_ending.get("_next_scene") == "", "The deepest floor streams nothing and keeps its own arena")

	var water: Node3D = _ending.get("_water")
	var mirror: Node3D = _ending.get("_mirror_holder")
	var mirror_visual: Node = _ending.get("_mirror_visual")
	_check(is_instance_valid(water) and is_instance_valid(mirror), "The ending builds its basin and the mirror figure")
	_check(is_instance_valid(mirror_visual), "雾子 reuses the player's rig as a mirror double")
	if is_instance_valid(water) and is_instance_valid(mirror):
		var surface: float = float(_ending.get("_flood_y"))
		_check(water.global_position.y < float(_ending.get("_floor_surface").y) - 4.0, "The basin is authored below the duel floor, so the fall drops into it")
		_check(absf(mirror.global_position.y - surface) < 1.2, "雾子 floats on the basin surface")
		_check(absf(float(mirror.rotation_degrees.x) + 90.0) < 6.0, "雾子 is laid flat rather than left standing")
	_check(_ending.get("_arena_water").visible == false, "The arena's own shallow sheet is retired under the basin")

	var overlay: Control = _ending.get("_overlay")
	_check(is_instance_valid(overlay) and overlay.visible, "The ending overlay draws over the hidden HUD")

	var saw_fall := await _advance_until(func() -> bool: return _stage_is("submerge"), 90, 0.12)
	_check(saw_fall, "The collapse resolves into the fall")
	var saw_mirror := await _advance_until(func() -> bool: return _stage_is("mirror"), 90, 0.12)
	_check(saw_mirror, "The fall resolves into the overhead shot of 雾子")
	var quoted := await _advance_until(func() -> bool: return overlay.call("is_quote_visible"), 60, 0.12)
	_check(quoted, "The mirror shot carries the quote")
	if is_instance_valid(overlay):
		_check(overlay.get("_quote_text") == QUOTE, "The quote on screen is the authored line")
	var digitised := await _advance_until(func() -> bool: return _stage_is("digital"), 140, 0.12)
	_check(digitised, "The quote resolves into the digital shop gate")
	if is_instance_valid(overlay):
		_check(bool(overlay.call("is_digital")), "The overlay swaps to its digital gate")

	# The director frees itself the moment it completes, so the signal — not the
	# instance — is what proves the gate actually closed.
	var finished := [false]
	_ending.connect("completed", func() -> void: finished[0] = true)
	_ending.call("finish_now")
	var covered := await _advance_until(func() -> bool: return bool(finished[0]), 60, 0.2)
	_check(covered, "The gate closes the sequence")
	var gate_closed := await _advance_until(func() -> bool: return !is_instance_valid(_ending), 30, 0.1)
	_check(gate_closed, "The gate resolves once the digital flare has covered the screen")
	# Completing on the deepest floor restores the arena instead of switching.
	await _steps(4)
	_check(not is_instance_valid(_floor.get("ending")), "The deepest floor drops the ending director when it finishes")
	_check(not paused and not bool(_floor.get("paused")), "The deepest floor resumes play after the gate")
	_check(_floor.get("hud").visible, "The deepest floor restores its HUD")
	_check(not bool(_floor.get("_boss_active")), "The resumed arena no longer counts as an active duel")
	_check(_player.health >= _player.max_health - 0.01, "The resumed player is handed back alive")
	# The arena sank with 素子 during the ending, so resuming has to put the floor
	# back under the spawn point, not leave the player over an empty basin.
	var arena: Node3D = _floor.get("boss_arena")
	if is_instance_valid(arena):
		var arena_spawn: Vector3 = arena.call("player_spawn")
		var offset := _player.global_position.distance_to(arena_spawn)
		_check(offset < 2.5, "The resumed player stands on the restored duel floor, not over the basin (%.2f m from spawn)" % offset)


# --------------------------------------------------- real hand-off to floor two

func _test_next_floor_hand_off() -> void:
	# Mirrors tests/test_tutorial_exit.gd: this is the shipped exit path, driven
	# to a real change_scene_to_file instead of a harness callback.
	if is_instance_valid(_floor):
		_floor.queue_free()
	await _steps(2)
	await _new_floor(LEVELS.FLOOR_ONE)
	current_scene = _floor
	await _reach_victory()
	if not await _ending_started():
		current_scene = null
		return
	_ending = _floor.get("ending")
	_ending.call("finish_now")
	var switched := false
	for _index in range(240):
		await _steps(1)
		if current_scene != null and current_scene.name == "SecondFloor":
			switched = true
			break
	_check(switched, "Finishing the gate hands the tree to the real second-floor scene")
	if switched:
		var script_path := ""
		if current_scene.get_script() != null:
			script_path = current_scene.get_script().resource_path
		_check(script_path == "res://floor_two.gd", "The second floor runs its own floor_two.gd script")
		_check(int(current_scene.get("floor_index")) == LEVELS.FLOOR_TWO, "The handed-off scene plays the second floor")
		_check(not paused, "The scene switch leaves the tree unpaused")
	if is_instance_valid(current_scene):
		current_scene.queue_free()
	current_scene = null
	await _steps(2)


# --------------------------------------------------------------------- helpers

func _stage_is(stage: String) -> bool:
	return is_instance_valid(_ending) and str(_ending.call("stage")) == stage


## One manual `_process` step per iteration, then a real frame: the director's
## animation is fully delta-driven, so this both exercises and accelerates it.
func _advance_until(predicate: Callable, limit: int, step: float) -> bool:
	for _index in range(limit):
		if bool(predicate.call()):
			return true
		if is_instance_valid(_ending):
			_ending.call("_process", step)
		await process_frame
	return bool(predicate.call())


func _new_floor(floor_index: int) -> void:
	var packed: PackedScene = load(LEVELS.scene_path(floor_index))
	_floor = packed.instantiate() as Node3D
	root.add_child(_floor)
	await _steps(3)
	_floor.set("floor_index", floor_index)
	_floor.call("regenerate_floor", TEST_SEED)
	await _steps(4)
	_player = _floor.get("player")


## Real erosion threshold, real Matrix hand-off, real lethal hit on the mirror:
## the ending has to start from the shipped victory path, not from a test hook.
func _reach_victory() -> void:
	var erosion: Node = _floor.get("erosion")
	erosion.call("reset", 99)
	erosion.call("set_combat_active", false)
	erosion.call("process_activity", 1.0, true, false)
	var entered := await _wait_until(func() -> bool: return bool(_floor.get("_boss_active")), MAX_WAIT_FRAMES)
	if not entered:
		_check(false, "The duel starts from the erosion threshold")
		return
	var boss: Node = _floor.get("boss_target")
	boss.set("entrance_time_left", 0.0)
	boss.set("is_entering", false)
	boss.call("take_damage", 99999.0, true)
	await _steps(2)


func _ending_started() -> bool:
	var started := await _wait_until(func() -> bool: return is_instance_valid(_floor.get("ending")), 90)
	_check(started, "Beating the mirror Boss starts the ending")
	return started


func _wait_until(predicate: Callable, limit: int) -> bool:
	for _index in range(limit):
		if bool(predicate.call()):
			return true
		await _steps(1)
	return bool(predicate.call())


func _steps(count: int) -> void:
	for _index in range(count):
		await physics_frame
		await process_frame


func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
		print("PASS: " + description)
	else:
		failed += 1
		push_error("FAIL: " + description)
