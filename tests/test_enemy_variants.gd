extends SceneTree
## Godot --headless --path . --fixed-fps 60 --script tests/test_enemy_variants.gd
## Focused checks for the three street enemy behaviours.  The test uses the
## real Player controller so the normal take_damage/roll API is exercised.

const PLAYER_SCRIPT = preload("res://player.gd")
const VARIANT_SCRIPT = preload("res://enemy_variant.gd")
const SWORD_MODEL_PATH := "res://model/female+cyberpunk+warrior+3d+model.glb"

var world: Node3D
var player: CharacterBody3D
var foe: CharacterBody3D
var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _test_sword()
	await _test_sword_reaction_and_death()
	await _test_boxer()
	await _test_boxer_close_reveal_windup()
	await _test_sniper()
	await _test_sniper_repeat_cloak_and_pause()
	print("ENEMY VARIANT RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_sword() -> void:
	await _reset_variant(&"sword", Vector3(0.0, 0.0, -3.0))
	_check(foe.get_variant_kind() == &"sword", "Sword variant can be selected")
	var sword_visual: Node3D = foe.get("_variant_visual") as Node3D
	var sword_animation: AnimationPlayer = foe.get("_variant_animation") as AnimationPlayer
	_check(is_instance_valid(sword_visual) and bool(foe.get("_variant_model_imported")), "Sword uses the imported cyberpunk warrior model")
	_check(is_instance_valid(sword_visual) and String(sword_visual.scene_file_path) == SWORD_MODEL_PATH, "Sword visual points to the new GLB")
	var sword_animation_names := _animation_names(sword_animation)
	_check("Slash_001" in sword_animation_names and "hit_to_head_001" in sword_animation_names and "defeat_03_001" in sword_animation_names, "Sword imports slash, hit, and defeat animations")
	_check(_is_sword_guard(sword_animation), "Sword reset holds Slash's 2.35 second guard pose without playing")
	_check(_near(float(foe.attack_damage), 25.0), "Sword damage is 25")
	var animation_starts: Array[String] = []
	sword_animation.animation_started.connect(func(animation_name: StringName) -> void: animation_starts.append(String(animation_name)))
	_check(await _wait_for_state(&"windup", 40), "Sword enters a readable windup at close range")
	_check(_animation_current(foe) == "Slash_001" and sword_animation.is_playing(), "Sword windup plays the imported Slash animation")
	_check(_near(_animation_position(sword_animation), 0.48, 0.04), "Sword windup starts at the authored preparation pose")
	var windup: float = foe.state_time_left
	_check(windup > 0.45, "Sword has the longer telegraph")
	_check(foe.take_damage(5.0) and _animation_current(foe) == "Slash_001", "A nonlethal hit does not replace the sword's committed windup with a reaction")
	var previous_position := _animation_position(sword_animation)
	var windup_is_continuous := true
	for frame in range(60):
		if foe.state != &"windup":
			break
		await _steps(1)
		var current_position := _animation_position(sword_animation)
		windup_is_continuous = windup_is_continuous and current_position >= previous_position - 0.001 and current_position - previous_position < 0.05
		previous_position = current_position
	_check(foe.state == &"strike", "Sword enters its actual strike state after windup")
	_check(_animation_current(foe) == "Slash_001" and sword_animation.is_playing(), "Sword is still playing Slash when the strike opens")
	_check(windup_is_continuous and _near(_animation_position(sword_animation), 1.10, 0.05), "The strike reaches Slash's hit pose near 1.10 seconds without restarting or seeking")
	var strike_position := _animation_position(sword_animation)
	_check(await _wait_for_state(&"retreat", 20), "Sword retreats after its active strike")
	var retreat_position := _animation_position(sword_animation)
	_check(_animation_current(foe) == "Slash_001" and sword_animation.is_playing() and retreat_position > strike_position and retreat_position < 1.35, "Retreat continues the authored swing after the strike instead of snapping to guard")
	_check(animation_starts.count("Slash_001") == 1, "Windup, strike, and retreat start the Slash clip only once")
	_check(_near(player.health, 75.0), "Sword's committed hit deals one 25-damage strike")
	await _steps(12)
	_check(_animation_current(foe) == "Slash_001" and sword_animation.is_playing() and _animation_position(sword_animation) > retreat_position + 0.15, "Slash follow-through keeps advancing while the sword backs away")
	_check(foe.velocity.length() > 0.01 or foe.state == &"recovery", "Sword moves away during its recovery window")
	_check(_near(player.health, 75.0), "The continued animation cannot apply a second strike during retreat")


func _test_sword_reaction_and_death() -> void:
	# Keep combat disabled throughout this lifecycle so a new attack cannot
	# accidentally satisfy a reaction-to-guard assertion by playing Slash.
	await _reset_variant(&"sword", Vector3(0.0, 0.0, -14.0))
	foe.combat_enabled = false
	foe.reset_enemy()
	var animation := foe.get("_variant_animation") as AnimationPlayer
	var animation_starts: Array[String] = []
	var animation_finishes: Array[String] = []
	animation.animation_started.connect(func(animation_name: StringName) -> void: animation_starts.append(String(animation_name)))
	animation.animation_finished.connect(func(animation_name: StringName) -> void: animation_finishes.append(String(animation_name)))
	await _steps(20)
	_check(_is_sword_guard(animation) and foe.state == &"idle", "An inactive sword keeps its paused guard pose stable")
	_check(foe.take_damage(5.0), "An inactive sword accepts a nonlethal hit")
	_check(animation.assigned_animation == "hit_to_head_001" and animation.is_playing(), "A nonlethal hit plays the imported reaction outside combat")
	await _steps(90)
	_check(animation.assigned_animation == "hit_to_head_001" and animation.is_playing() and _animation_position(animation) >= 1.45, "The reaction reaches its final half-second without being replaced by idle")
	var reached_guard := false
	for frame in range(60):
		if _is_sword_guard(animation):
			reached_guard = true
			break
		await _steps(1)
	_check(reached_guard, "The complete nonlethal reaction returns to the paused guard pose")
	_check(animation_starts.count("hit_to_head_001") == 1 and animation_finishes.count("hit_to_head_001") == 1, "A single hit starts and finishes its complete reaction exactly once")
	_check(animation_starts.count("Slash_001") == 1, "Reaction completion restores the guard pose once")
	await _steps(120)
	_check(_is_sword_guard(animation) and animation_starts.count("Slash_001") == 1 and animation_finishes.count("hit_to_head_001") == 1, "Further idle frames neither replay the reaction nor repeatedly restore guard")
	_check(_near(foe.health, 95.0) and _near(player.health, 100.0), "The isolated reaction leaves health and combat damage unchanged")

	# Kill the sword during a second reaction. A pending reaction completion
	# must never replace its death clip with Slash or start defeat repeatedly.
	foe.take_damage(5.0)
	await _steps(20)
	_check(foe.take_damage(100.0), "A lethal hit is accepted during the second reaction")
	_check(foe.is_dead and foe.state == &"dead" and animation.assigned_animation == "defeat_03_001" and animation.is_playing(), "Lethal damage immediately starts the authored defeat animation")
	await _steps(150)
	_check(animation.assigned_animation == "defeat_03_001" and animation.is_playing() and _animation_position(animation) > 2.4, "Defeat keeps advancing beyond the superseded reaction deadline")
	_check(animation_starts.count("defeat_03_001") == 1 and animation_starts.count("Slash_001") == 1, "Dead physics frames do not restart defeat or restore guard")
	var death_position := _animation_position(animation)
	_check(not foe.take_damage(10.0) and animation.assigned_animation == "defeat_03_001" and is_equal_approx(_animation_position(animation), death_position), "Further hits on the defeated sword do not restart its animation")
	await _steps(220)
	_check(animation.assigned_animation == "defeat_03_001" and not animation.is_playing() and _near(_animation_position(animation), animation.get_animation("defeat_03_001").length, 0.02), "Defeat completes and holds its final pose")
	_check(animation_starts.count("defeat_03_001") == 1 and animation_finishes.count("defeat_03_001") == 1 and animation_starts.count("Slash_001") == 1, "Defeat finishes once and never restores guard before reset")
	foe.reset_enemy()
	_check(not foe.is_dead and foe.state == &"idle" and _near(foe.health, foe.max_health), "Reset revives the sword with full health")
	_check(_is_sword_guard(animation) and foe.collision_layer == 4 and foe.collision_mask == 1, "Reset restores the guard pose and living collision after defeat")
	await _steps(120)
	_check(_is_sword_guard(animation), "Reset clears old reaction and death playback through later idle frames")
	foe.global_position = Vector3(0.0, 0.0, -2.0)
	foe.combat_enabled = true
	_check(await _wait_for_state(&"windup", 5), "The reset sword can begin a new attack")
	_check(animation.assigned_animation == "Slash_001" and animation.is_playing() and _near(_animation_position(animation), 0.48, 0.04), "The revived sword begins Slash at its preparation pose")


func _test_boxer() -> void:
	await _reset_variant(&"boxer", Vector3(0.0, 0.0, 6.0))
	_check(foe.get_variant_kind() == &"boxer", "Boxer variant can be selected")
	_check(_near(float(foe.attack_damage), 12.0), "Boxer damage is 12")
	_check(_near(float(foe.aggro_range), 10.0), "Boxer activation uses its original 10 metre detection range")
	_check(_near(float(foe.boxer_leash_range), 20.0), "Boxer keeps aggro through a separate 20 metre leash")
	_check(_near(_visual_yaw(foe), PI, 0.01), "Boxer visual faces the player-facing -Z controller direction")
	_check(foe.is_optically_hidden(), "Boxer is concealed before its first approach reveals it")
	_check(_cloak_is_ghost(foe) and not _visual_root_visible(foe), "Boxer starts as a fully hidden holographic cloak with no visible body shell")
	await _steps(3)
	_check(foe.state == &"chase" or foe.state == &"idle", "Boxer starts by pursuing rather than attacking from spawn")
	foe.global_position = Vector3(0.0, 0.0, 4.0)
	await _steps(3)
	_check(not foe.is_optically_hidden(), "Boxer fades into view while rushing the player")
	_check(_cloak_is_ghost(foe) and _visual_root_visible(foe), "Boxer reveal uses the moving cyan ghost layer before restoring its body material")
	_check(await _wait_for_visibility(foe, 0.99, 60), "Boxer completes the hologram-to-body transition")
	_check(not _cloak_is_ghost(foe) and _visual_root_visible(foe), "Boxer restores the original textured material after revealing")
	_check(await _wait_for_state(&"retreat", 80), "Boxer completes a fast attack and retreat")
	_check(_near(player.health, 88.0), "Boxer's committed hit deals one 12-damage strike")


func _test_sniper() -> void:
	await _reset_variant(&"sniper", Vector3(0.0, 0.0, 12.0))
	_check(foe.get_variant_kind() == &"sniper", "Sniper variant can be selected")
	_check(_near(_visual_yaw(foe), PI, 0.01), "Sniper visual faces the player-facing -Z controller direction")
	_check(foe.is_optically_hidden(), "Sniper remains concealed outside its aim state")
	_check(_cloak_is_ghost(foe) and not _visual_root_visible(foe), "Sniper is fully hidden, including its weapon and shadow, before aiming")
	_check(await _wait_for_state(&"sniper_aim", 30), "Sniper enters aim state at long range")
	await _steps(3)
	_check(not foe.is_optically_hidden() and foe.is_aiming(), "Sniper is visible while aiming")
	_check(_cloak_is_ghost(foe) and _visual_root_visible(foe), "Sniper aim begins with the flowing hologram layer")
	_check(await _wait_for_visibility(foe, 0.99, 60), "Sniper completes its reveal before the shot")
	_check(not _cloak_is_ghost(foe), "Sniper restores the original model material after the reveal")
	var health_before: float = player.health
	_check(await _wait_for_state(&"sniper_cooldown", 150), "Sniper fires and enters cooldown after two seconds")
	_check(player.health < health_before, "Sniper applies one ranged shot after the aim delay")
	_check(await _wait_until_hidden(foe, 60), "Sniper fades back to complete optical invisibility during cooldown")


func _test_boxer_close_reveal_windup() -> void:
	# Spawning in striking distance must not let a concealed boxer spend its
	# telegraph under the cloak or land a hit before the player can see it.
	await _reset_variant(&"boxer", Vector3(0.0, 0.0, 1.5))
	var health_before: float = player.health
	var reveal_frames := 0
	var reveal_was_safe := true
	while not foe.is_fully_revealed() and reveal_frames < 75:
		reveal_was_safe = reveal_was_safe and foe.state not in [&"windup", &"strike"] and _near(player.health, health_before)
		await _steps(1)
		reveal_frames += 1
	_check(reveal_frames > 20 and foe.is_fully_revealed(), "A close boxer spends a visible interval materializing before attacking")
	_check(reveal_was_safe and _near(player.health, health_before), "A close boxer cannot begin its telegraph or damage the player during reveal")
	_check(await _wait_for_state(&"windup", 5), "A fully revealed close boxer starts its normal windup")
	_check(foe.state_time_left >= 0.18 and _near(float(foe.windup_duration), 0.20, 0.001), "The boxer still has a full 0.20 second windup after materializing")
	await _steps(10)
	_check(_near(player.health, health_before), "The first ten frames of the visible boxer windup do not deal damage")
	_check(await _wait_for_state(&"retreat", 40), "The revealed boxer completes its attack and retreats")
	_check(_near(player.health, health_before - 12.0), "The revealed close boxer deals exactly one normal 12 damage hit")


func _test_sniper_repeat_cloak_and_pause() -> void:
	await _reset_variant(&"sniper", Vector3(0.0, 0.0, 12.0))
	for cycle in range(2):
		_check(await _wait_for_state(&"sniper_aim", 240), "Sniper begins aiming in cloak cycle %d" % (cycle + 1))
		if cycle == 0:
			await _steps(6)
			var alpha_before: float = foe.get("_visibility_alpha")
			var aim_time_before: float = foe.state_time_left
			_check(alpha_before > 0.0 and alpha_before < 1.0, "Pause test catches the sniper partway through its reveal")
			paused = true
			for frame in range(12):
				await process_frame
			_check(is_equal_approx(float(foe.get("_visibility_alpha")), alpha_before), "Pausing freezes the sniper materialization progress")
			_check(is_equal_approx(float(foe.state_time_left), aim_time_before), "Pausing also freezes the sniper aim countdown")
			paused = false
		_check(await _wait_for_visibility(foe, 0.999, 60), "Sniper fully materializes in cloak cycle %d" % (cycle + 1))
		var health_before: float = player.health
		_check(await _wait_for_state(&"sniper_cooldown", 150), "Sniper fires once in cloak cycle %d" % (cycle + 1))
		_check(_near(player.health, health_before - float(foe.sniper_damage)), "Sniper deals one shot of damage in cloak cycle %d" % (cycle + 1))
		_check(await _wait_until_hidden(foe, 60), "Sniper becomes completely invisible in cooldown cycle %d" % (cycle + 1))
		_check(not _visual_root_visible(foe), "Sniper renderer is disabled after cooldown fade %d" % (cycle + 1))


func _reset_variant(kind: StringName, foe_position: Vector3) -> void:
	if is_instance_valid(world):
		world.queue_free()
		await process_frame
	world = Node3D.new()
	root.add_child(world)
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(30.0, 0.2, 30.0)
	floor_shape.shape = floor_box
	floor_shape.position.y = -0.1
	floor_body.add_child(floor_shape)
	world.add_child(floor_body)
	player = PLAYER_SCRIPT.new()
	player.name = "VariantTestPlayer"
	player.spawn_position = Vector3.ZERO
	world.add_child(player)
	await process_frame
	player.global_position = Vector3.ZERO
	player.set_physics_process(false)
	foe = VARIANT_SCRIPT.new()
	foe.name = "VariantTestFoe"
	foe.spawn_position = foe_position
	foe.variant = kind
	foe.configure_variant(kind)
	world.add_child(foe)
	foe.setup(player)
	foe.combat_enabled = true
	await process_frame
	foe.reset_enemy()
	await _steps(2)


func _wait_for_state(expected: StringName, limit: int) -> bool:
	for _index in range(limit):
		if foe.state == expected:
			return true
		await _steps(1)
	return foe.state == expected


func _wait_until_hidden(target: Node, limit: int) -> bool:
	for _index in range(limit):
		if target.is_optically_hidden():
			return true
		await _steps(1)
	return target.is_optically_hidden()


func _wait_for_visibility(target: Node, minimum: float, limit: int) -> bool:
	for _index in range(limit):
		if float(target.get("_visibility_alpha")) >= minimum:
			return true
		await _steps(1)
	return float(target.get("_visibility_alpha")) >= minimum


func _steps(count: int) -> void:
	for _index in range(count):
		await physics_frame


func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		push_error("FAIL: " + description)


func _near(left: float, right: float, tolerance: float = 0.06) -> bool:
	return absf(left - right) <= tolerance


func _visual_yaw(target: Node) -> float:
	var visual: Node3D = target.get("_variant_visual") as Node3D
	return visual.rotation.y if is_instance_valid(visual) else -999.0


func _visual_root_visible(target: Node) -> bool:
	var visual: Node3D = target.get("_variant_visual") as Node3D
	return is_instance_valid(visual) and visual.visible


func _animation_names(player_animation: AnimationPlayer) -> Array[String]:
	var names: Array[String] = []
	if not is_instance_valid(player_animation):
		return names
	for library_name in player_animation.get_animation_library_list():
		var library := player_animation.get_animation_library(library_name)
		for animation_name in library.get_animation_list():
			names.append(String(animation_name))
	return names


func _animation_current(target: Node) -> String:
	var player_animation := target.get("_variant_animation") as AnimationPlayer
	return String(player_animation.current_animation) if is_instance_valid(player_animation) else ""


func _animation_position(player_animation: AnimationPlayer) -> float:
	return player_animation.current_animation_position if is_instance_valid(player_animation) else -1.0


func _is_sword_guard(player_animation: AnimationPlayer) -> bool:
	# current_animation becomes empty when AnimationPlayer.pause() is called;
	# assigned_animation retains the actual clip whose sampled pose is held.
	return is_instance_valid(player_animation) and player_animation.assigned_animation == "Slash_001" and not player_animation.is_playing() and _near(_animation_position(player_animation), 2.35, 0.02)


func _cloak_is_ghost(target: Node) -> bool:
	var records: Array = target.get("_cloak_records") as Array
	var ghost: Material = target.get("_cloak_material") as Material
	if records.is_empty() or ghost == null:
		return false
	var geometry: GeometryInstance3D = records[0]["node"] as GeometryInstance3D
	return is_instance_valid(geometry) and geometry.material_override == ghost
