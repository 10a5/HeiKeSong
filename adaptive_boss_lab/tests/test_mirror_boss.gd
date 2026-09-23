extends SceneTree
## Physical integration tests for the mirror fighter on a small, flat arena.
## Uses the real player model and damage geometry without importing the arena.

var passed := 0
var failed := 0
var stage: Node3D
var player: Variant
var boss: Variant
var actions: Array[Dictionary] = []
var combo_starts: Array[String] = []
var combo_finishes: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	stage = Node3D.new()
	stage.name = "MirrorBossFixture"
	root.add_child(stage)
	_add_box(Vector3(0.0, -0.5, 0.0), Vector3(60.0, 1.0, 60.0))
	player = load("res://player.gd").new()
	player.name = "Player"
	player.spawn_position = Vector3(0.0, 0.05, -4.0)
	player.max_health = 10000.0
	player.bounds_enabled = false
	player.process_mode = Node.PROCESS_MODE_PAUSABLE
	stage.add_child(player)
	boss = load("res://mirror_boss.gd").new()
	boss.name = "MirrorBoss"
	# Entrance timing and invulnerability have a dedicated integration suite.
	boss.entrance_duration = 0.0
	boss.spawn_position = Vector3(0.0, 0.05, 0.0)
	boss.bounds_enabled = false
	boss.process_mode = Node.PROCESS_MODE_PAUSABLE
	stage.add_child(boss)
	boss.setup(player)
	boss.combat_enabled = false
	boss.action_played.connect(_on_action)
	boss.combo_started.connect(func(kind: StringName): combo_starts.append(str(kind)))
	boss.combo_finished.connect(func(kind: StringName): combo_finishes.append(str(kind)))
	await _frames(12)
	await _test_model_and_input()
	await _test_roll_combo()
	await _test_dash_combo()
	await _test_recovery_spacing()
	await _test_shield()
	await _test_hit_geometry()
	await _test_lifecycle()
	paused = false
	for input_name in ["move_left", "move_right", "move_up", "move_down"]:
		Input.action_release(input_name)
	stage.queue_free()
	await process_frame
	print("MIRROR BOSS RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_model_and_input() -> void:
	_check(boss.get_script().get_base_script() == player.get_script(), "Boss 继承真实玩家动作脚本")
	_check(boss._character_visual.get_script() == player._character_visual.get_script(), "Boss 与主角使用同一模型控制器")
	_check(boss._character_visual.model_root.scene_file_path == player._character_visual.model_root.scene_file_path, "Boss 与主角加载同一 GLB 外形")
	_check(boss._character_visual.animation_player != player._character_visual.animation_player, "双方拥有独立 AnimationPlayer")
	_check(boss._character_visual.skeleton != player._character_visual.skeleton, "双方骨骼实例独立")
	var boss_position: Vector3 = boss.global_position
	var player_position: Vector3 = player.global_position
	Input.action_press("move_right")
	await _frames(30)
	Input.action_release("move_right")
	_check(_horizontal_distance(player.global_position, player_position) > 0.5, "输入确实移动玩家")
	_check(_horizontal_distance(boss.global_position, boss_position) < 0.01, "玩家 WASD 不控制 Boss")


func _test_roll_combo() -> void:
	await _reset_fixture()
	boss.planned_combo = &"roll_punches"
	boss.energy = 9.9
	boss.combat_enabled = true
	await _frames(35)
	_check(combo_starts.is_empty() and actions.is_empty(), "不足整套 10 能量时不启动翻滚双拳")
	boss.energy = 10.0
	await _wait_for_finish(1, 200)
	_check(combo_starts == ["roll_punches"] and combo_finishes == ["roll_punches"], "足额后完整完成翻滚双拳连招")
	_check(_action_kinds() == ["roll", "slash", "slash", "roll"], "第一套依次前滚、出拳、出拳、后滚")
	_check(is_zero_approx(boss.energy), "第一套总共只花费 10 能量")
	_check(_minimum_energy() >= -0.001, "连招期间不会出现负能量")
	if actions.size() >= 4:
		var forward: Vector3 = actions[0]["direction"]
		var backward: Vector3 = actions[3]["direction"]
		_check(forward.dot(Vector3.FORWARD) > 0.8, "第一翻滚朝向玩家")
		_check(backward.dot(forward) < -0.8, "末尾翻滚方向确实向后")
		_check(float(actions[0]["heading_error"]) <= deg_to_rad(15.0), "前滚启动时身体朝向与翻滚方向差不超过 15 度")
		_check(float(actions[3]["heading_error"]) <= deg_to_rad(15.0), "后滚启动前完成转身，避免斜着翻滚")
		_check(_horizontal_distance(actions[1]["position"], player.global_position) < _horizontal_distance(actions[0]["position"], player.global_position), "前滚后在更近位置出拳")
		_check(_horizontal_distance(boss.global_position, player.global_position) > _horizontal_distance(actions[3]["position"], player.global_position) + 1.0, "后滚实际拉开距离")
	_check(player.health < player.max_health, "连招通过真实命中降低玩家血量")


func _test_dash_combo() -> void:
	await _reset_fixture()
	boss.planned_combo = &"dash_kick"
	boss.energy = 6.9
	boss.combat_enabled = true
	await _frames(20)
	_check(combo_starts.is_empty(), "不足整套 7 能量时不启动冲拳回旋踢")
	boss.energy = 7.0
	await _wait_for_finish(1, 180)
	_check(combo_finishes == ["dash_kick"], "7 能量可以完成第二套连招")
	_check(_action_kinds() == ["dash_slash", "front_kick"], "第二套依次向前冲拳、回旋踢")
	_check(is_zero_approx(boss.energy) and _minimum_energy() >= -0.001, "第二套花费 7 且不超支")
	_check(_horizontal_distance(boss.global_position, player.global_position) < 4.0, "冲拳实际向玩家位移")
	_check(player.health < player.max_health, "冲拳或回旋踢造成真实伤害")


func _test_recovery_spacing() -> void:
	await _reset_fixture()
	player.global_position = Vector3(0.0, 0.02, 0.0)
	boss.global_position = Vector3(0.0, 0.02, 8.0)
	boss.energy = 0.0
	boss.combat_enabled = true
	await _frames(180)
	var desired: float = boss.roll_speed * boss.roll_duration
	var far_result := _horizontal_distance(player.global_position, boss.global_position)
	_check(absf(far_result - desired) <= boss.distance_tolerance + 0.25, "回能时从远处接近到约一次翻滚距离")
	boss.global_position = Vector3(0.0, 0.02, 1.0)
	boss.velocity = Vector3.ZERO
	await _frames(180)
	var near_result := _horizontal_distance(player.global_position, boss.global_position)
	_check(absf(near_result - desired) <= boss.distance_tolerance + 0.25, "回能时玩家近身则后退到约一次翻滚距离")
	_check(actions.is_empty(), "无能量时移动不会凭空打出攻击或护盾")
	boss.energy_regen_per_second = 2.0
	await _frames(30)
	_check(boss.energy > 0.5 and boss.energy < 2.0, "保持距离期间正常恢复能量")
	boss.energy_regen_per_second = 0.0
	boss.energy = 0.0
	boss.global_position = Vector3(0.0, 0.02, 5.0)
	var wall := _add_box(Vector3(0.0, 1.5, 4.0), Vector3(20.0, 3.0, 0.3))
	await _frames(90)
	_check(boss.global_position.z > 4.3, "保持距离的移动受真实墙体碰撞限制")
	wall.queue_free()
	await _frames(2)
	boss.bounds_enabled = true
	boss.arena_rect = Rect2(-2.0, -2.0, 4.0, 4.0)
	boss.global_position = Vector3(0.0, 0.02, 1.5)
	player.global_position = Vector3(0.0, 0.02, 1.0)
	await _frames(90)
	_check(boss.global_position.z <= 2.0 - boss.radius + 0.01, "回避近身时遵守场地边界")


func _test_shield() -> void:
	await _reset_fixture()
	boss.move_speed = 0.0
	player.global_position = Vector3(0.0, 0.02, -1.2)
	boss.energy = 8.0
	boss.combat_enabled = true
	await _frames(5)
	_check(_action_kinds() == ["shield"], "玩家近身触发一次护盾")
	_check(is_equal_approx(boss.energy, 6.0) and is_equal_approx(boss.shield, 10.0), "近身护盾真实花费 2 能量获得 10 护盾")
	var health_before: float = boss.health
	_check(boss.take_damage(7.0), "护盾承受攻击并反馈命中")
	_check(is_equal_approx(boss.health, health_before) and is_equal_approx(boss.shield, 3.0), "护盾优先吸收伤害")
	boss.take_damage(8.0)
	_check(is_equal_approx(boss.health, health_before - 5.0) and is_zero_approx(boss.shield), "超出护盾的伤害扣除生命")
	await _frames(60)
	_check(_action_kinds() == ["shield"] and is_equal_approx(boss.energy, 6.0), "护盾破裂后不会每帧重刷，冷却期不重复扣费")
	await _frames(195)
	_check(_action_kinds() == ["shield", "shield"] and is_equal_approx(boss.energy, 4.0), "近身护盾冷却结束后才允许再次消费")


func _test_hit_geometry() -> void:
	await _reset_fixture()
	boss.move_speed = 0.0
	boss.energy = 0.0
	boss.combat_enabled = true
	player.global_position = Vector3(0.0, 0.02, -1.8)
	await _frames(3)
	var wall := _add_box(Vector3(0.0, 1.0, -0.9), Vector3(4.0, 2.0, 0.15))
	await _frames(3)
	var health_before: float = player.health
	boss._start_melee(Vector3.FORWARD, "slash", 25.0, 2.1, 0.14, deg_to_rad(48.0), 1.1)
	await _frames(12)
	_check(is_equal_approx(player.health, health_before), "墙体遮挡 Boss 的近战攻击")
	wall.queue_free()
	await _frames(3)
	var boss_health_before: float = boss.health
	boss._start_melee(Vector3.FORWARD, "slash", 25.0, 2.1, 0.14, deg_to_rad(48.0), 1.1)
	await _frames(12)
	_check(is_equal_approx(player.health, health_before - 25.0), "同一次近战攻击仅对玩家造成一次伤害")
	_check(is_equal_approx(boss.health, boss_health_before), "Boss 作为 combat_targets 不会击中自己")
	# Keep the rolling target inside the hitbox: this detects a deferred hit
	# incorrectly landing on the tail of a previously evaded swing.
	player.is_rolling = true
	player.roll_time_left = 0.05
	player.roll_speed = 0.0
	player.set_physics_process(true)
	health_before = player.health
	boss._start_melee(Vector3.FORWARD, "slash", 25.0, 2.1, 0.25, deg_to_rad(48.0), 1.1)
	await _frames(20)
	_check(not player.is_rolling, "测试中的翻滚已在攻击窗口结束前完成")
	_check(is_equal_approx(player.health, health_before), "翻滚已躲过的攻击不在翻滚尾帧补中")
	player.set_physics_process(false)


func _test_lifecycle() -> void:
	await _reset_fixture()
	boss.energy = 10.0
	boss.combat_enabled = true
	await _wait_for_combo(30)
	_check(boss.combo_active, "生命周期测试已开始连招")
	var position_before: Vector3 = boss.global_position
	var energy_before: float = boss.energy
	var actions_before := actions.size()
	paused = true
	await _frames(40)
	_check(boss.combo_active and actions.size() == actions_before and boss.global_position.is_equal_approx(position_before) and is_equal_approx(boss.energy, energy_before), "暂停冻结当前连招、移动与能量")
	paused = false
	await _frames(8)
	boss.combat_enabled = false
	var count_at_stop := actions.size()
	await _frames(90)
	_check(not boss.combo_active and not boss.is_rolling and not boss.is_dashing and boss.slash_time_left <= 0.0, "关闭战斗立刻清空连招和活动攻击")
	_check(actions.size() == count_at_stop, "关闭战斗后不会有延迟攻击")
	boss.reset_enemy()
	boss.energy_regen_per_second = 0.0
	boss.combat_enabled = true
	await _wait_for_combo(30)
	boss.reset_enemy()
	boss.combat_enabled = false
	_check(not boss.combo_active and is_equal_approx(boss.energy, boss.max_energy) and is_equal_approx(boss.health, boss.max_health), "重置取消队列并恢复生命能量")
	boss.combat_enabled = true
	await _wait_for_combo(30)
	# Kill during the telegraph, before rolling evasion becomes active.
	boss.is_rolling = false
	boss.take_damage(boss.health + boss.shield)
	count_at_stop = actions.size()
	await _frames(100)
	_check(boss.is_dead and not boss.combo_active, "死亡取消未完成连招")
	_check(actions.size() == count_at_stop, "死亡后不会继续出招")


func _reset_fixture() -> void:
	paused = false
	boss.combat_enabled = false
	boss.bounds_enabled = false
	boss.move_speed = 3.2
	boss.energy_regen_per_second = 0.0
	boss.reset_enemy()
	boss.combat_enabled = false
	player.reset_player()
	player.roll_speed = 7.0
	player.global_position = Vector3(0.0, 0.05, -4.0)
	boss.global_position = Vector3(0.0, 0.05, 0.0)
	await _frames(10)
	player.set_physics_process(false)
	actions.clear()
	combo_starts.clear()
	combo_finishes.clear()


func _on_action(kind: String, cost: float) -> void:
	var direction: Vector3 = boss.roll_direction if kind == "roll" else boss.facing
	var visual_yaw: float = boss._visual_yaw
	var heading_error := absf(wrapf(boss._direction_yaw(direction) - visual_yaw, -PI, PI))
	actions.append({"kind": kind, "cost": cost, "energy": boss.energy, "position": boss.global_position, "direction": direction, "facing": boss.facing, "visual_yaw": visual_yaw, "heading_error": heading_error})


func _action_kinds() -> Array[String]:
	var result: Array[String] = []
	for action in actions:
		result.append(action["kind"])
	return result


func _minimum_energy() -> float:
	var result: float = boss.energy
	for action in actions:
		result = minf(result, action["energy"])
	return result


func _wait_for_finish(count: int, maximum_frames: int) -> void:
	for i in range(maximum_frames):
		await physics_frame
		if combo_finishes.size() >= count:
			return


func _wait_for_combo(maximum_frames: int) -> void:
	for i in range(maximum_frames):
		await physics_frame
		if boss.combo_active:
			return


func _frames(count: int) -> void:
	for i in range(count):
		await physics_frame


func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _add_box(at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = at
	body.collision_layer = 1
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	stage.add_child(body)
	return body


func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
		print("PASS: ", description)
	else:
		failed += 1
		push_error("FAIL: " + description)
