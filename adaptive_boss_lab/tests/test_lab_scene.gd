extends SceneTree
## Scene-level smoke test: load the interactive lab, replay the JSON sample,
## and verify that strategy output reaches the simulated Boss receiver.

var passed := 0
var failed := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	scene._start_replay("roll_slash")
	await create_timer(2.2).timeout
	_check(scene.replay_catalog.get("roll_slash", []).size() == 7, "场景从 JSON 回放目录载入 7 个事件")
	_check(scene.brain.strategy.get("roll_response", "") == "evade", "低频策略更新把摘要判断应用为 evade")
	_check(scene.boss.evade_count > 0, "回放中最终翻滚触发 Boss 的 evade")
	_check(scene.boss.last_evade_payload.get("reason", "") == "predicted_roll_attack", "场景 Boss 收到预测原因")
	_check(not scene.player.is_rolling and not scene.player.is_dashing, "回放结束清理瞬时动作状态")
	scene._start_replay("mixed")
	await create_timer(2.2).timeout
	_check(scene.brain.strategy.get("name", "") == "keep_distance", "混合复合动作回放进入保持距离策略")
	scene._start_replay("low_energy")
	await create_timer(1.2).timeout
	_check(int(scene.brain.snapshot().get("attempts", {}).get("rejected", 0)) == 3, "能量不足回放保留三次失败尝试")
	_check(scene.brain.strategy.get("name", "") == "observe_and_probe", "低证据回放回到观察策略")
	print("LAB SCENE RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)

func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
		print("PASS: ", description)
	else:
		failed += 1
		push_error("FAIL: " + description)
