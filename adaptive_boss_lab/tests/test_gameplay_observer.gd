extends SceneTree
## Godot --headless --path adaptive_boss_lab --script tests/test_gameplay_observer.gd

const OBSERVER = preload("res://gameplay_observer.gd")

class FakePlayer extends Node3D:
	var grounded := true
	func is_on_floor() -> bool:
		return grounded

class FakeBrain extends Node:
	var events: Array[Dictionary] = []
	var outcomes: Array[Dictionary] = []
	func record_event(event_name: String, payload: Dictionary) -> void:
		events.append({"name": event_name, "payload": payload.duplicate(true)})
	func record_action_outcome(kind: String, result: String, value: float) -> void:
		outcomes.append({"kind": kind, "result": result, "value": value})

var passed := 0
var failed := 0
var observer: Node
var player: FakePlayer
var brain: FakeBrain
var target: Node3D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	player = FakePlayer.new()
	root.add_child(player)
	brain = FakeBrain.new()
	root.add_child(brain)
	target = Node3D.new()
	root.add_child(target)
	observer = OBSERVER.new()
	root.add_child(observer)
	observer.set_physics_process(false)
	observer.setup(player, brain, target)
	_test_movement_and_distance()
	_test_pause_and_jump()
	_test_attack_evidence()
	_test_window_and_reset()
	_test_optional_target()
	print("GAMEPLAY OBSERVER RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_movement_and_distance() -> void:
	# Two moving intervals, one stationary interval and one vertical jump.
	player.position = Vector3.ZERO
	observer.reset()
	for _step in range(2):
		player.position.x += 1.0
		target.position = player.position + Vector3.FORWARD * 2.0
		observer._physics_process(0.2)
	target.position = player.position + Vector3.FORWARD * 5.0
	observer._physics_process(0.2)
	player.grounded = false
	player.position.y += 1.0
	target.position = player.position + Vector3.FORWARD * 10.0
	observer._physics_process(0.2)
	var result: Dictionary = observer.summary()
	var movement: Dictionary = result["movement"]
	_check(_near(float(result["observed_seconds"]), 0.8) and int(result["sample_count"]) == 4, "每 0.2 秒产生公开状态样本")
	_check(_near(float(movement["moving_ratio"]), 0.75) and _near(float(movement["stationary_ratio"]), 0.25), "移动与静止按活动时间统计")
	_check(_near(float(movement["airborne_ratio"]), 0.25), "空中时间独立统计并允许与移动重叠")
	_check(_near(float(movement["distance_m"]), 3.0) and _near(float(movement["horizontal_distance_m"]), 2.0) and _near(float(movement["vertical_distance_m"]), 1.0), "路程保留水平及第三维度移动")
	_check(_near(float(movement["mean_speed_mps"]), 3.75) and _near(float(movement["mean_moving_speed_mps"]), 5.0), "均速含静止时间，移动均速单独计算")
	var distance: Dictionary = result["opponent_distance"]
	_check(_near(float(distance["mean_m"]), 4.75), "对手距离按观测时间求均值")
	_check(_near(float(distance["bucket_mix"]["near"]), 0.5) and _near(float(distance["bucket_mix"]["mid"]), 0.25) and _near(float(distance["bucket_mix"]["far"]), 0.25), "近中远距离分布完整归一")
	# A return trip within a sample must not collapse to zero displacement.
	observer.reset()
	player.grounded = true
	player.position.x += 0.5
	observer._physics_process(0.1)
	player.position.x -= 0.5
	observer._physics_process(0.1)
	_check(_near(float(observer.summary()["movement"]["distance_m"]), 1.0), "采样间隔内折返不会丢失实际路程")


func _test_pause_and_jump() -> void:
	observer.reset()
	brain.events.clear()
	observer.record_jump(true)
	observer.record_jump(false)
	observer._physics_process(0.2)
	var before: Dictionary = observer.summary()
	paused = true
	observer._physics_process(10.0)
	observer.record_jump(false)
	paused = false
	var after: Dictionary = observer.summary()
	_check(before == after, "暂停不推进时间、不采样、不加入跳跃尝试")
	_check(after["jumps"] == {"accepted": 1, "rejected": 1}, "跳跃结果来自真实 request_jump 返回值")
	_check(brain.events.size() == 2 and brain.events[0]["name"] == "jump_attempt", "跳跃尝试传入行为脑且不重复义体统计")
	_check(int(after["attack_results"]["miss"]) == 0, "无攻击结果证据时不自行猜测未命中")


func _test_attack_evidence() -> void:
	observer.reset()
	brain.outcomes.clear()
	observer.record_attack_result("slash", true, 25.0)
	observer.record_attack_result("shot", false, 18.0)
	observer.record_attack_result("punch", true, -3.0)
	observer.record_attack_result("", true, 50.0)
	var result: Dictionary = observer.summary()["attack_results"]
	_check(int(result["hit"]) == 2 and int(result["miss"]) == 1 and _near(float(result["damage"]), 25.0), "只记录明确命中/未命中，伤害不为负且未命中不算伤害")
	_check(brain.outcomes.size() == 3 and brain.outcomes[0] == {"kind": "slash", "result": "hit", "value": 1.0}, "结果转发给脑时计数为一而非伤害数值")
	_check(int(result["by_kind"]["shot"]["miss"]) == 1 and _near(float(result["by_kind"]["shot"]["damage"]), 0.0), "按动作保留有证据的结果")
	# Returned dictionaries are safe to merge into an LLM context or inspect.
	result["by_kind"]["slash"]["hit"] = 99
	_check(int(observer.summary()["attack_results"]["by_kind"]["slash"]["hit"]) == 1, "修改摘要不会改变观测历史")


func _test_window_and_reset() -> void:
	observer.reset()
	observer.record_jump(true)
	observer.record_attack_result("slash", true, 25.0)
	player.position.x += 1.0
	observer._physics_process(0.2)
	# Sixty later seconds of standing evict all old travel and event evidence.
	observer._physics_process(60.0)
	var result: Dictionary = observer.summary()
	_check(_near(float(result["observed_seconds"]), 60.0) and int(result["sample_count"]) <= 301, "滑动窗口最多保留最近 60 秒样本")
	_check(_near(float(result["movement"]["distance_m"]), 0.0) and _near(float(result["movement"]["stationary_ratio"]), 1.0), "窗口过期的路程与移动时间不会留在画像中")
	_check(result["jumps"] == {"accepted": 0, "rejected": 0} and int(result["attack_results"]["hit"]) == 0, "跳跃与攻击证据同样遵守最近 60 秒窗口")
	# A half sample at the oldest edge is clipped proportionally.
	observer.window_duration = 0.3
	observer.reset()
	player.position.x += 1.0
	observer._physics_process(0.2)
	observer._physics_process(0.2)
	result = observer.summary()
	_check(_near(float(result["observed_seconds"]), 0.3) and _near(float(result["movement"]["distance_m"]), 0.5), "窗口边界按剩余采样时长裁剪")
	observer.window_duration = 60.0
	observer.reset()
	result = observer.summary()
	_check(_near(float(result["observed_seconds"]), 0.0) and int(result["sample_count"]) == 0 and observer.player == player and observer.brain == brain, "reset 清空画像并保留绑定")
	observer._physics_process(0.2)
	_check(_near(float(observer.summary()["movement"]["distance_m"]), 0.0), "重置位置基准，不把传送或重试算作路程")


func _test_optional_target() -> void:
	observer.setup(player, brain)
	observer._physics_process(0.1)
	var result: Dictionary = observer.summary()
	_check(_near(float(result["observed_seconds"]), 0.1), "未满 0.2 秒的有效时间也可用于即时摘要")
	_check(result["opponent_distance"]["mean_m"] == null and result["opponent_distance"]["bucket_mix"] == {"near": 0.0, "mid": 0.0, "far": 0.0}, "未绑定对手时距离未知，不伪装为零距离")
	var encoded := JSON.stringify(result)
	_check(not encoded.contains("draw_pile") and not encoded.contains("hand") and not encoded.contains("position"), "紧凑摘要不泄露牌区、未来随机或原始位置日志")
	_check(str(result["interpretation"]).contains("移动") and str(result["interpretation"]).contains("跳跃"), "摘要包含可读中文描述")


func _near(actual: float, expected: float) -> bool:
	return absf(actual - expected) < 0.0001


func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
		print("PASS: ", description)
	else:
		failed += 1
		push_error("FAIL: " + description)
