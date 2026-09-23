extends SceneTree
## Exercise the entrance through real physics, damage and player controls.

const COMBAT = preload("res://combat_hit.gd")

var passed := 0
var failed := 0
var stage: Node3D
var player: Variant
var boss: Variant
var actions: Array[String] = []
var combo_starts: Array[StringName] = []
var dodge_count := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	stage = Node3D.new()
	root.add_child(stage)
	var floor_body := StaticBody3D.new()
	floor_body.position.y = -0.5
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, 1.0, 40.0)
	collision.shape = box
	floor_body.add_child(collision)
	stage.add_child(floor_body)
	player = load("res://player.gd").new()
	player.spawn_position = Vector3(0.0, 0.02, -4.0)
	player.bounds_enabled = false
	player.process_mode = Node.PROCESS_MODE_PAUSABLE
	stage.add_child(player)
	boss = load("res://mirror_boss.gd").new()
	boss.spawn_position = Vector3(0.0, 0.02, 0.0)
	boss.bounds_enabled = false
	stage.add_child(boss)
	boss.setup(player)
	boss.action_played.connect(func(kind: String, _cost: float): actions.append(kind))
	boss.combo_started.connect(func(kind: StringName): combo_starts.append(kind))
	boss.dodge_observed.connect(func(): dodge_count += 1)
	_check(is_equal_approx(boss.entrance_duration, 3.0), "默认入场给玩家 3 秒反应时间")
	_check(boss.is_entering and boss.state == &"entrance", "出生即进入受保护入场状态")
	_check(boss.get_node("EntranceShell").visible and boss.get_node("EntranceScanRing").visible, "出生时无敌盾与扫描光环可见")
	await _frames(12)
	await _test_protected_entrance()
	await _test_pause_and_disabled_combat()
	await _test_combat_and_reset()
	paused = false
	Input.action_release("move_right")
	stage.queue_free()
	await process_frame
	print("BOSS INTRO RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_protected_entrance() -> void:
	var origin: Vector3 = boss.global_position
	var player_origin: Vector3 = player.global_position
	var scan_height: float = boss.get_node("EntranceScanRing").position.y
	var shell_material: ShaderMaterial = boss.get_node("EntranceShell").material_override
	var shader_time: float = shell_material.get_shader_parameter("elapsed")
	Input.action_press("move_right")
	await _frames(24)
	Input.action_release("move_right")
	_check(boss.get_node("EntranceScanRing").position.y > scan_height + 0.2 and float(shell_material.get_shader_parameter("elapsed")) > shader_time + 0.3, "0.4 秒内扫描环上升且护盾着色动画推进")
	_check(_horizontal_distance(player.global_position, player_origin) > 0.4, "入场等待期间玩家仍可自由移动")
	_check(_horizontal_distance(boss.global_position, origin) < 0.01, "入场时 Boss 站定不追逐玩家")
	_check(actions.is_empty() and combo_starts.is_empty(), "满能量也不会在入场期间发动连招")
	_check(not boss.request_card("roll") and not boss.request_card("slash") and not boss.request_card("shield"), "入场期间直接出牌请求也被阻止")
	boss.energy = 6.0
	boss.shield = 5.0
	var health_before: float = boss.health
	_check(not boss.take_damage(1000000.0), "入场护盾拒绝百万伤害而非普通吸收盾")
	_check(not boss.is_dead and is_equal_approx(boss.health, health_before) and is_equal_approx(boss.shield, 5.0), "无敌命中不消耗生命或普通护盾")
	player.global_position = Vector3(0.0, boss.global_position.y, -1.3)
	player.velocity = Vector3.ZERO
	player.facing = Vector3.BACK
	await _frames(2)
	_check(COMBAT.can_hit(player, boss, Vector3.BACK, 2.1, deg_to_rad(48.0), 1.1), "真实玩家近战几何确实覆盖入场 Boss")
	_check(player.request_card("slash"), "入场期间玩家可以正常出拳")
	await _frames(18)
	player._fire_shot(Vector3.BACK)
	await _frames(2)
	_check(is_equal_approx(boss.health, health_before) and is_equal_approx(boss.shield, 5.0), "真实玩家近战和射线射击都无法穿透入场无敌盾")
	_check(is_equal_approx(boss.energy, 6.0), "入场等待不花费或恢复战斗能量")
	_check(actions.is_empty() and dodge_count == 0, "入场阻挡不伪造出牌或成功翻滚事件")


func _test_pause_and_disabled_combat() -> void:
	var time_before: float = boss.entrance_time_left
	var scan_height: float = boss.get_node("EntranceScanRing").position.y
	var shell_material: ShaderMaterial = boss.get_node("EntranceShell").material_override
	var shader_time: float = shell_material.get_shader_parameter("elapsed")
	paused = true
	await _frames(40)
	_check(boss.is_entering and is_equal_approx(boss.entrance_time_left, time_before), "分析界面暂停时入场倒计时冻结")
	_check(is_equal_approx(boss.get_node("EntranceScanRing").position.y, scan_height) and is_equal_approx(float(shell_material.get_shader_parameter("elapsed")), shader_time), "暂停时扫描环和护盾动画同步冻结")
	paused = false
	await _frames(6)
	_check(boss.entrance_time_left < time_before, "关闭暂停后继续原来的入场倒计时")
	time_before = boss.entrance_time_left
	boss.combat_enabled = false
	_check(boss.is_entering and boss.state == &"entrance" and is_equal_approx(boss.entrance_time_left, time_before), "关闭战斗不会跳过或重启入场")
	await _frames(12)
	_check(boss.entrance_time_left < time_before, "战斗开关关闭时入场动画仍自然结束")
	await _wait_for_entrance_end(180)
	_check(not boss.is_entering and boss.state == &"idle", "入场结束且战斗禁用时保持静止待机")
	_check(not boss.get_node("EntranceShell").visible and not boss.get_node("EntranceScanRing").visible and is_zero_approx(boss._character_visual.position.y), "结束后隐藏无敌盾与扫描环并归位角色模型")
	_check(actions.is_empty() and combo_starts.is_empty(), "禁用战斗不会在护盾结束时偷放连招")
	var health_before: float = boss.health
	_check(boss.take_damage(7.0), "入场结束后恢复正常命中")
	_check(is_equal_approx(boss.health, health_before - 2.0) and is_zero_approx(boss.shield), "结束后普通盾按数值吸收伤害，不残留无敌")


func _test_combat_and_reset() -> void:
	player.reset_player()
	boss.combat_enabled = true
	boss.reset_enemy()
	_check(boss.is_entering and is_equal_approx(boss.entrance_time_left, boss.entrance_duration), "重置重播完整入场时间")
	_check(boss.get_node("EntranceShell").visible and boss.get_node("EntranceScanRing").visible and is_zero_approx(float(boss.get_node("EntranceShell").material_override.get_shader_parameter("elapsed"))), "重置重新显示入场特效并从头播放动画")
	await _frames(120)
	_check(boss.is_entering and actions.is_empty() and not boss.combo_active, "入场两秒仍不允许提前行动")
	await _wait_for_entrance_end(80)
	for i in range(90):
		await physics_frame
		if not actions.is_empty():
			break
	_check(not boss.is_entering and not combo_starts.is_empty() and not actions.is_empty(), "入场结束后恢复自动连招")
	boss.reset_enemy()
	var player_health: float = player.health
	var action_count := actions.size()
	var origin: Vector3 = boss.global_position
	_check(not boss.combo_active and not boss.is_rolling and not boss.is_dashing and boss.slash_time_left <= 0.0, "战斗中重置清除原有连招与攻击窗口")
	_check(is_equal_approx(boss.health, boss.max_health) and is_equal_approx(boss.energy, boss.max_energy), "重新入场恢复完整生命与能量")
	await _frames(120)
	_check(boss.is_entering and actions.size() == action_count and is_equal_approx(player.health, player_health), "重新入场不会执行上一轮残留攻击")
	_check(_horizontal_distance(boss.global_position, origin) < 0.01, "重新入场不会保留翻滚或突进位移")


func _wait_for_entrance_end(max_frames: int) -> void:
	for i in range(max_frames):
		await physics_frame
		if not boss.is_entering:
			return


func _frames(count: int) -> void:
	for i in range(count):
		await physics_frame


func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
		print("PASS: ", description)
	else:
		failed += 1
		push_error("FAIL: " + description)
