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
## Captured while the boxer case is live so the sniper can be compared against
## a real street variant instead of a hard-coded number.
var _boxer_visual_scale := 0.0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _test_sword()
	await _test_sword_lock_on()
	await _test_sword_reaction_and_death()
	await _test_boxer()
	await _test_boxer_close_reveal_windup()
	await _test_sniper()
	await _test_sniper_cover_blocks_the_shot()
	await _test_sniper_suppression()
	await _test_sniper_pause_and_repeat()
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
	_check(_near(float(foe.attack_damage), 40.0), "Sword damage is 40")
	var animation_starts: Array[String] = []
	sword_animation.animation_started.connect(func(animation_name: StringName) -> void: animation_starts.append(String(animation_name)))
	_check(await _wait_for_state(&"windup", 40), "Sword enters a readable windup at close range")
	_check(_animation_current(foe) == "Slash_001" and sword_animation.is_playing(), "Sword windup plays the imported Slash animation")
	_check(_near(_animation_position(sword_animation), 0.48, 0.04), "Sword windup starts at the authored preparation pose")
	var windup: float = foe.state_time_left
	_check(windup > 1.0 and _near(float(foe.windup_duration), VARIANT_SCRIPT.SWORD_WINDUP_DURATION, 0.001), "Sword has a slow, heavy telegraph instead of the old 0.62 second jab")
	_check(_near(foe.get("_variant_animation").speed_scale, 1.0, 0.001) and _near(sword_animation.get_playing_speed(), VARIANT_SCRIPT.SWORD_SWING_SPEED, 0.01), "The greatsword clip is played at the slow-motion playback factor")
	_check(foe.take_damage(5.0) and _animation_current(foe) == "Slash_001", "A nonlethal hit does not replace the sword's committed windup with a reaction")
	var previous_position := _animation_position(sword_animation)
	var windup_is_continuous := true
	for frame in range(150):
		if foe.state != &"windup":
			break
		await _steps(1)
		var current_position := _animation_position(sword_animation)
		windup_is_continuous = windup_is_continuous and current_position >= previous_position - 0.001 and current_position - previous_position < 0.05
		previous_position = current_position
	_check(foe.state == &"strike", "Sword enters its actual strike state after windup")
	_check(_animation_current(foe) == "Slash_001" and sword_animation.is_playing(), "Sword is still playing Slash when the strike opens")
	_check(windup_is_continuous and _near(_animation_position(sword_animation), 1.55, 0.05), "The strike opens on Slash's authored chop pose near 1.55 seconds without restarting or seeking")
	var strike_position := _animation_position(sword_animation)
	_check(await _wait_for_state(&"retreat", 90), "Sword retreats after its active strike")
	var retreat_position := _animation_position(sword_animation)
	_check(_animation_current(foe) == "Slash_001" and sword_animation.is_playing() and retreat_position > strike_position and retreat_position < 2.10, "Retreat continues the authored swing after the strike instead of snapping to guard")
	_check(animation_starts.count("Slash_001") == 1, "Windup, strike, and retreat start the Slash clip only once")
	_check(_near(player.health, 60.0), "Sword's committed hit deals one 40-damage strike")
	await _steps(24)
	_check(_animation_current(foe) == "Slash_001" and sword_animation.is_playing() and _animation_position(sword_animation) > retreat_position + 0.15, "Slash follow-through keeps advancing while the sword backs away")
	_check(foe.velocity.length() > 0.01 or foe.state == &"recovery", "Sword moves away during its recovery window")
	_check(_near(player.health, 60.0), "The continued animation cannot apply a second strike during retreat")


func _test_sword_lock_on() -> void:
	# The greatsword rig is authored facing +Z while the controller's forward is
	# -Z. Left unrotated it walked and swung with its back to the player, which is
	# what made the slash read as backwards. The rig must carry the half turn, and
	# it must also pivot its heading onto the player instead of sliding sideways.
	await _reset_variant(&"sword", Vector3(0.0, 0.0, -8.0))
	_check(_near(_visual_yaw(foe), PI, 0.01), "Sword visual faces the player-facing -Z controller direction")
	var heading := foe.get("_heading") as Node3D
	# Park the player off to one side, inside the 12 m aggro radius but outside
	# the 2.6 m attack range, and start the rig facing exactly the other way.
	foe.global_position = Vector3(0.0, 0.0, -8.0)
	player.global_position = Vector3(6.0, 0.0, -8.0)
	heading.rotation.y = PI
	var target_yaw := atan2(-1.0, 0.0)
	_check(absf(wrapf(heading.rotation.y - target_yaw, -PI, PI)) > 1.0, "The lock-on case starts with the rig pointed away from the player")
	# A half turn at 7 rad/s takes about 14 frames; 20 frames is enough to lock
	# on while still leaving 3.4 m of approach before the telegraph could open.
	await _steps(20)
	_check(foe.state in [&"chase", &"windup"], "An engaged greatsword keeps closing instead of idling mid-turn")
	_check(absf(wrapf(heading.rotation.y - target_yaw, -PI, PI)) < 0.05, "The greatsword actively turns its heading onto the player")
	_check(_near(_visual_yaw(foe), PI, 0.01), "The half turn survives the lock-on turn and stays on the rig root")


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
	_boxer_visual_scale = _visual_scale(foe)
	_check(foe.get_variant_kind() == &"boxer", "Boxer variant can be selected")
	_check(_near(float(foe.attack_damage), 12.0), "Boxer damage is 12")
	_check(_near(float(foe.max_health), 55.0), "Boxer health is the fast-archetype 55, not the greatsword's 100")
	_check(_near(float(foe.windup_duration), 0.60, 0.001), "Boxer telegraphs for a readable 0.60 seconds")
	_check(_near(float(foe.boxer_active_duration), 0.20, 0.001), "Boxer's active window is 0.20 seconds")
	_check(_near(float(foe.boxer_stun_duration), 1.5, 0.001), "Boxer's post-attack stun is 1.5 seconds")
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
	# The punish window. After the retreat ends the boxer must stand fully inert
	# for the whole 1.5 s: no velocity and no new telegraph. Dodging the jab has
	# to buy a real counter-attack instead of merely resetting the approach.
	_check(await _wait_for_state(&"recovery", 80), "Boxer enters its post-attack stun once the retreat ends")
	var stun_frames := 0
	var stayed_inert := true
	while foe.state == &"recovery" and stun_frames < 200:
		stayed_inert = stayed_inert and Vector2(foe.velocity.x, foe.velocity.z).length() < 0.01
		await _steps(1)
		stun_frames += 1
	_check(stayed_inert, "Boxer holds still for the whole post-attack stun")
	_check(stun_frames >= 80, "Boxer's post-attack stun runs the full 1.5 seconds, not the old 0.45")


func _test_sniper() -> void:
	await _reset_variant(&"sniper", Vector3(0.0, 0.0, 12.0))
	_check(foe.get_variant_kind() == &"sniper", "Sniper variant can be selected")
	_check(_near(_visual_yaw(foe), PI, 0.01), "Sniper visual faces the player-facing -Z controller direction")
	# The assembled rig is authored at the same 0.977 m as the sword and boxer
	# GLBs, so an identical root scale means an identical on-screen height. The
	# controller used to overwrite the assembly's own 1.8424 factor with 1.0 and
	# left the sniper at roughly half the size of every other character.
	_check(_near(_visual_scale(foe), 1.84, 0.05), "Sniper renders at the 1.8 m street scale instead of the raw GLB height")
	_check(_boxer_visual_scale > 0.0 and _near(_visual_scale(foe), _boxer_visual_scale, 0.03), "Sniper and boxer share exactly the same visual scale")
	_check(_cloak_is_ghost(foe) and not _visual_root_visible(foe), "Sniper starts fully hidden, including its weapon and shadow")

	# Start outside the range so the concealed holding pose is observable.
	player.global_position = Vector3(0.0, 0.0, 40.0)
	await _steps(4)
	_check(player.active_threat_message().is_empty(), "Standing outside the firing range raises no sniper prompt")
	_check(foe.state == &"idle" and foe.get_sniper_tracer_count() == 0, "An out-of-range sniper neither aims nor shoots")
	# The root-motion `shoot_001` clip used to walk the rig forward and drop it
	# prone. The sentry instead freezes one authored frame of the standing shot.
	# Pausing empties current_animation, so read the assigned clip instead.
	_check(_assigned_animation(foe) == "fire_001" and not _sniper_animation_playing(foe), "Sniper holds the authored standing shooting pose while concealed")
	_check(_near(_sniper_animation_position(foe), _sniper_hold_time(foe), 0.02), "The concealed pose is frozen at the configured frame of the shot clip")
	var spawn_position := foe.global_position
	await _steps(30)
	_check(foe.global_position.distance_to(spawn_position) < 0.001, "A cloaked sniper stands motionless on its spawn position")
	_check(Vector2(foe.velocity.x, foe.velocity.z).length() < 0.01, "A stationary sentry never builds horizontal velocity")

	# Crossing the boundary is what arms the rifle, and the prompt must precede
	# the first shot by a full telegraph. The player stands 12 m up the street.
	player.global_position = Vector3(0.0, 0.0, 0.0)
	await _steps(2)
	_check(player.active_threat_message().contains("狙击手射程"), "Entering the sniper's range raises the range prompt")
	_check(await _wait_for_state(&"sniper_aim", 10), "The armed sentry begins its aim telegraph")
	_check(foe.is_optically_hidden() and not _visual_root_visible(foe), "Aiming alone never exposes the sentry; only a hit does")

	var health_before: float = player.health
	_check(await _wait_for_state(&"sniper_fire", 150), "Sniper commits its shot after the aim telegraph")
	# The shot launches on the frame after the state opens, exactly like the
	# melee variants' committed strike.
	await _steps(1)
	_check(foe.get_sniper_tracer_count() > 0 and _tracer_node_count(foe) > 0, "The shot launches a visible round along its trajectory")
	_check(foe.is_shot_in_flight(), "The round is a travelling projectile rather than an instant hit")
	_check(_near(float(foe.sniper_bullet_speed), 50.0, 0.01), "The round flies at the requested 50 m/s speed")
	_check(_sniper_tracer_core_radius(foe) >= 0.08, "The tracer is a thickened beam instead of a hairline")
	_check(VARIANT_SCRIPT.SNIPER_TRAIL_LINGER >= 0.5, "The frozen trajectory lingers long enough to read after the impact")
	_check(_near(player.health, health_before), "A round still in flight has not damaged anyone yet")
	_check(foe.last_shot_origin.distance_to(foe.global_position) < 2.2, "The round starts at the sentry and not at the world origin")
	_check(foe.last_shot_origin.distance_to(foe.last_shot_target) > 10.0, "The solved line spans the whole street")
	_check(foe.last_shot_target.distance_to(player.global_position + Vector3.UP * 0.85) < 0.05, "The line ends exactly on the player when nothing blocks the shot")
	_check(not foe.last_shot_blocked, "The open-street shot is not reported as blocked")
	# 12 m at 50 m/s is about 14 physics frames. The round is fast, but it must
	# still be a real travelling projectile rather than an instant hit, and the
	# per-frame segment test must not let it tunnel through the player.
	var flight_frames := 0
	while foe.is_shot_in_flight() and flight_frames < 120:
		await _steps(1)
		flight_frames += 1
	_check(not foe.is_shot_in_flight(), "The round reaches its target instead of flying forever")
	_check(flight_frames >= 8, "The round is visibly in flight instead of resolving instantly (%d frames)" % flight_frames)
	_check(flight_frames <= 40, "The fast 50 m/s round still crosses the street promptly (%d frames)" % flight_frames)
	_check(_near(player.health, health_before - float(foe.sniper_damage)), "The travelling round deals exactly one sniper_damage hit")
	_check(await _wait_for_state(&"sniper_cooldown", 20), "Sniper enters its cooldown after firing")
	_check(foe.is_optically_hidden(), "The sniper stays cloaked after firing, so the round is the only clue to its position")

	# A direct hit is the reveal trigger and the firing lockout.
	var health_of_foe: float = foe.health
	_check(foe.take_damage(10.0), "The cloaked sentry accepts damage")
	_check(bool(foe.get("_sniper_revealed")), "A hit marks the sentry as exposed")
	_check(_near(foe.health, health_of_foe - 10.0), "The hit removes exactly its own damage from the sentry")
	_check(foe.is_suppressed(), "Taking a hit locks the sentry's trigger")
	_check(_near(foe.get_sniper_suppression_left(), 3.0, 0.06), "The firing lockout starts at a full three seconds")
	_check(foe.state == &"idle" and is_zero_approx(foe.state_time_left), "The hit drops whatever aim cycle was running")
	# The lockout is enforced at the launch point as well as in the state
	# machine, so no path can slip a round through the three-second window.
	var tracers_before: int = foe.get_sniper_tracer_count()
	foe.call("_fire_sniper")
	_check(foe.get_sniper_tracer_count() == tracers_before and not foe.is_shot_in_flight(), "A suppressed sentry cannot launch a round even when firing is forced directly")
	_check(await _wait_for_visibility(foe, 0.99, 60), "The hit materializes the sniper body")
	_check(not _cloak_is_ghost(foe) and _visual_root_visible(foe), "The exposed sniper restores its textured body material")
	_check(_health_label_visible(foe), "The exposed sniper shows its health label")
	# The lockout has to survive the rest of the three seconds, then release.
	var protected_health: float = player.health
	await _steps(110)
	_check(foe.is_suppressed() and _near(player.health, protected_health) and foe.get_sniper_tracer_count() == 0, "A suppressed sentry fires nothing inside its lockout")
	_check(foe.is_fully_revealed() and _visual_root_visible(foe), "An exposed sniper never re-cloaks during the lockout")
	await _steps(60)
	_check(not foe.is_suppressed(), "The firing lockout runs out on its own")
	_check(foe.state == &"sniper_aim", "The sentry re-arms itself after the lockout")
	_check(foe.global_position.distance_to(spawn_position) < 0.001, "Being exposed and suppressed never moves the sentry off its spawn position")

	# Lethal damage is the authored knockdown, and the body must stay visible.
	_check(foe.take_damage(1000.0), "The exposed sniper can be defeated")
	_check(foe.is_dead and foe.state == &"dead", "Lethal damage puts the sentry into its dead state")
	_check(_assigned_animation(foe) == "defeat_03_001" and _sniper_animation_playing(foe), "Death plays the authored knockdown animation")
	_check(player.active_threat_message().is_empty(), "The range prompt clears the moment the sentry dies")
	_check(Vector2(foe.velocity.x, foe.velocity.z).length() < 0.01, "A dead sentry stops moving immediately")
	await _steps(60)
	_check(foe.is_fully_revealed() and _visual_root_visible(foe), "The knocked-down body stays visible through the death animation")
	_check(_assigned_animation(foe) == "defeat_03_001", "The knockdown clip is never replaced by the cloak or a guard pose")
	_check(not foe.take_damage(10.0), "Further hits on the defeated sentry are rejected")


func _test_sniper_pause_and_repeat() -> void:
	# The sentry repeats its firing cycle for as long as the player stays inside
	# the range. Pausing must freeze the whole telegraph, prompt included.
	await _reset_variant(&"sniper", Vector3(0.0, 0.0, 12.0))
	_check(await _wait_for_state(&"sniper_aim", 60), "Sniper begins aiming at a player inside its range")
	await _steps(5)
	var aim_time_before: float = foe.state_time_left
	paused = true
	for _frame in range(12):
		await process_frame
	_check(is_equal_approx(float(foe.state_time_left), aim_time_before), "Pausing freezes the sniper aim countdown")
	paused = false
	var health_before: float = player.health
	_check(await _wait_for_state(&"sniper_fire", 150), "Sniper commits its shot")
	await _steps(2)
	# Pausing mid-flight freezes the round instead of letting it land.
	var traveled_before := _sniper_round_traveled(foe)
	_check(traveled_before > 0.0, "The round has already covered ground two frames after launch")
	paused = true
	for _frame in range(10):
		await process_frame
	_check(foe.is_shot_in_flight() and is_equal_approx(_sniper_round_traveled(foe), traveled_before), "Pausing freezes an in-flight round")
	paused = false
	_check(await _wait_for_state(&"sniper_cooldown", 150), "Sniper fires once per cycle")
	while foe.is_shot_in_flight():
		await _steps(1)
	_check(_near(player.health, health_before - float(foe.sniper_damage)), "Each cycle deals exactly one shot of damage")
	_check(await _wait_for_state(&"sniper_aim", 240), "The sentry re-arms itself for a second cycle without moving")
	_check(foe.is_optically_hidden(), "A repeating sentry is still cloaked before it is hit")
	# Leaving the range stands the sentry down again.
	player.global_position = Vector3(0.0, 0.0, 40.0)
	await _steps(4)
	_check(player.active_threat_message().is_empty(), "Leaving the range clears the sniper prompt")
	_check(foe.state == &"idle", "Leaving the range returns the sentry to its holding pose")


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
	_check(foe.state_time_left >= 0.18 and _near(float(foe.windup_duration), 0.60, 0.001), "The boxer still has its full 0.60 second telegraph after materializing")
	await _steps(10)
	_check(_near(player.health, health_before), "The first ten frames of the visible boxer windup do not deal damage")
	# The telegraph is now 36 frames plus a 12 frame active window, so the state
	# budget has to cover the longer read rather than the old 0.32 s exchange.
	_check(await _wait_for_state(&"retreat", 70), "The revealed boxer completes its attack and retreats")
	_check(_near(player.health, health_before - 12.0), "The revealed close boxer deals exactly one normal 12 damage hit")


func _test_sniper_cover_blocks_the_shot() -> void:
	# The trajectory is the player's proof that cover worked: the round has to
	# stop on the wall and the shot must not connect.
	await _reset_variant(&"sniper", Vector3(0.0, 0.0, 12.0), true)
	var health_before: float = player.health
	_check(await _wait_for_state(&"sniper_aim", 30), "A sniper behind cover still arms inside its range")
	_check(await _wait_for_state(&"sniper_fire", 150), "The covered sniper still commits its shot")
	await _steps(1)
	_check(foe.last_shot_blocked, "A wall between the sentry and the player blocks the shot")
	_check(foe.get_sniper_tracer_count() > 0, "A blocked round still draws its trajectory up to the obstacle")
	_check(foe.last_shot_target.z > 5.0 and foe.last_shot_target.z < 11.0, "The blocked round stops on the wall instead of reaching the player")
	while foe.is_shot_in_flight():
		await _steps(1)
	_check(_near(player.health, health_before), "Cover prevents the sniper round from dealing any damage")


func _test_sniper_suppression() -> void:
	# Shooting a sentry has to interrupt the telegraph it is already running, and
	# then keep the rifle silent for a full three seconds.
	await _reset_variant(&"sniper", Vector3(0.0, 0.0, 12.0))
	_check(await _wait_for_state(&"sniper_aim", 60), "The sentry arms itself before the interruption test")
	await _steps(24)
	var health_before: float = player.health
	_check(foe.state_time_left > 0.4, "The interrupted telegraph still had time left to run")
	_check(foe.take_damage(5.0), "The aiming sentry accepts a hit")
	_check(foe.state == &"idle" and is_zero_approx(foe.state_time_left), "The hit cancels the running telegraph on the spot")
	_check(foe.is_suppressed(), "The hit starts the firing lockout")
	# The player stays inside the range for the whole lockout, so only the
	# lockout itself can be holding the rifle.
	await _steps(170)
	_check(_near(player.health, health_before) and foe.get_sniper_tracer_count() == 0, "No round is fired anywhere inside the lockout")
	_check(foe.state == &"idle", "The locked-out sentry keeps holding its pose")
	# A fresh hit refreshes the window rather than letting the old one run down.
	_check(foe.take_damage(5.0), "A second hit is accepted during the lockout")
	_check(_near(foe.get_sniper_suppression_left(), 3.0, 0.06), "A fresh hit restarts the full three-second lockout")
	await _steps(200)
	_check(not foe.is_suppressed(), "The refreshed lockout also expires on its own")
	_check(foe.state == &"sniper_aim", "The sentry re-arms once the refreshed lockout ends")


func _reset_variant(kind: StringName, foe_position: Vector3, blocker: bool = false) -> void:
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
	if blocker:
		var wall_body := StaticBody3D.new()
		wall_body.name = "CoverWall"
		wall_body.collision_layer = 1
		var wall_shape := CollisionShape3D.new()
		var wall_box := BoxShape3D.new()
		wall_box.size = Vector3(8.0, 4.0, 0.6)
		wall_shape.shape = wall_box
		wall_body.add_child(wall_shape)
		world.add_child(wall_body)
		wall_body.position = Vector3(0.0, 2.0, 6.0)
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


func _visual_scale(target: Node) -> float:
	var visual: Node3D = target.get("_variant_visual") as Node3D
	return visual.scale.y if is_instance_valid(visual) else -999.0


func _sniper_animation_playing(target: Node) -> bool:
	var animation := target.get("_variant_animation") as AnimationPlayer
	return is_instance_valid(animation) and animation.is_playing()


## The controller freezes the concealed sentry inside its shot clip; this is
## the same computation the behaviour uses, kept independent on purpose.
func _sniper_hold_time(target: Node) -> float:
	var animation := target.get("_variant_animation") as AnimationPlayer
	if not is_instance_valid(animation) or not animation.has_animation("fire_001"):
		return -1.0
	var clip := animation.get_animation("fire_001")
	return clip.length * float(target.get("sniper_hold_pose_fraction"))


func _tracer_node_count(target: Node) -> int:
	var count := 0
	for child in target.get_children():
		if String(child.name).begins_with("SniperTracer"):
			count += 1
	return count


## Radius of the flying streak's core cylinder. Read from the live mesh so the
## test proves the visible thickness, not just the exported constant.
func _sniper_tracer_core_radius(target: Node) -> float:
	for child in target.get_children():
		if String(child.name).begins_with("SniperTracerBeam"):
			var cylinder := (child as MeshInstance3D).mesh as CylinderMesh
			if cylinder != null:
				return cylinder.top_radius
	return -1.0


## Distance the first live round has already flown, in metres. Reading the
## simulation directly is the only way to prove a pause froze it mid-flight.
func _sniper_round_traveled(target: Node) -> float:
	var rounds: Array = target.get("_sniper_tracers") as Array
	if rounds.is_empty():
		return -1.0
	return float((rounds[0] as Dictionary).get("traveled", -1.0))


func _sniper_animation_position(target: Node) -> float:
	return _animation_position(target.get("_variant_animation") as AnimationPlayer)


func _health_label_visible(target: Node) -> bool:
	var label := target.get("_health_label") as Node3D
	return is_instance_valid(label) and label.visible


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


## The clip whose sampled pose is on screen. Unlike current_animation it
## survives AnimationPlayer.pause(), which is exactly how the frozen sentry and
## the sword guard pose are held.
func _assigned_animation(target: Node) -> String:
	var player_animation := target.get("_variant_animation") as AnimationPlayer
	return String(player_animation.assigned_animation) if is_instance_valid(player_animation) else ""


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
