extends SceneTree
## Boss-only sweep animation regression.  The card keeps its sweep gameplay
## values while its visual uses the authored roundhouse clip.

var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var stage := Node3D.new()
	root.add_child(stage)
	var arena: Variant = load("res://boss_arena.gd").new()
	stage.add_child(arena)
	await _frames(3)

	var player: Variant = load("res://player.gd").new()
	player.name = "Player"
	player.spawn_position = arena.player_spawn()
	player.arena_rect = arena.world_bounds()
	player.max_health = 10000.0
	player.collision_mask |= 4
	stage.add_child(player)
	var boss: CharacterBody3D = arena.spawn_boss(player)
	boss.entrance_duration = 0.0
	boss.combat_enabled = false
	boss.reset_enemy()
	await _frames(4)
	player.set_physics_process(false)
	boss.move_speed = 0.0
	boss.energy = 10.0
	boss._recovery_left = 10.0
	boss.shield_cooldown_left = 10.0
	boss.combat_enabled = true

	var visual: Variant = boss._character_visual
	_check(bool(visual.sweep_uses_front_kick_animation), "Boss enables roundhouse animation for sweep")
	var sweep_damage: float = boss.sweep_damage
	var sweep_reach: float = boss.sweep_reach
	_check(boss.request_card("sweep"), "Boss can still start the sweep card")
	await _frames(1)
	var animation_player := visual.animation_player as AnimationPlayer
	_check(animation_player != null, "Boss visual exposes AnimationPlayer")
	if animation_player != null:
		_check(animation_player.current_animation == "front_kick_02", "Boss sweep plays the authored roundhouse clip")
	_check(boss._active_attack_kind == "sweep", "Sweep attack kind remains unchanged for combat logic")
	_check(is_equal_approx(boss._active_melee_damage, sweep_damage), "Sweep damage remains unchanged")
	_check(is_equal_approx(boss._active_melee_reach, sweep_reach), "Sweep reach remains unchanged")
	_check(boss.slash_time_left > 0.0 and boss.slash_time_left <= boss.sweep_visual_duration + 0.001, "Sweep keeps its short hit window")

	stage.queue_free()
	await process_frame
	print("BOSS SWEEP ANIMATION RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _frames(count: int) -> void:
	for _index in range(count):
		await physics_frame


func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
		print("PASS: ", description)
	else:
		failed += 1
		push_error("FAIL: " + description)
