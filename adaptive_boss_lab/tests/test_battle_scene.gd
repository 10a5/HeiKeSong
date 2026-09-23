extends SceneTree
## Exercise the real scene, player input, collisions, deck and JSON export.
var passed := 0
var failed := 0
func _initialize() -> void:
	_run.call_deferred()
func _run() -> void:
	var scene = load("res://battle_scene.tscn").instantiate()
	root.add_child(scene)
	for i in range(120):
		await physics_frame
		if scene.initialized:
			break
	_check(scene.initialized, "决战场初始化完成")
	if not scene.initialized:
		quit(1)
		return
	scene.llm_bridge.configure({"enabled": false})
	scene.target.combat_enabled = false
	await _frames(20)
	_check(scene.player.get_script() == load("res://player.gd"), "决战场使用真实 player.gd")
	_check(scene.deck.hand.size() == 4 and scene.deck.total_cards == 18, "真实全解锁牌库发出四张手牌")
	_check(scene.arena.find_children("*", "StaticBody3D", true, false).size() > 0, "决战 GLB 表面有真实碰撞")
	_check(scene.player.is_on_floor(), "玩家出生在模型表面，稳定落地")
	_check(scene.brain.player == scene.player and scene.brain.opponent == scene.target, "行为脑绑定真实玩家及训练敌人")
	var start: Vector3 = scene.player.global_position
	Input.action_press("move_right")
	await _frames(35)
	Input.action_release("move_right")
	await _frames(2)
	_check(scene.player.global_position.distance_to(start) > 0.5, "WASD 输入驱动真实角色位移")
	_check(scene.gameplay_observer.summary()["movement"]["distance_m"] > 0.5, "真实移动路程进入行为摘要")
	Input.action_press("jump")
	await _frames(2)
	Input.action_release("jump")
	await _frames(10)
	_check(not scene.player.is_on_floor(), "空格输入可以真实起跳")
	_check(int(scene.gameplay_observer.summary()["jumps"]["accepted"]) == 1, "跳跃成功结果被记录")
	await _frames(70)
	_check(scene.player.is_on_floor(), "跳跃后落回场景网格")
	Input.action_press("cybernetic_boost")
	await _frames(2)
	Input.action_release("cybernetic_boost")
	_check(scene.player.is_cybernetic_active, "Q 输入触发真实义体")
	scene.deck.reset_deck(77)
	var before := int(scene.brain.snapshot().get("total_actions_seen", 0))
	var physical_card: Dictionary = scene.deck.hand[0].duplicate()
	Input.action_press("hand_1")
	await _frames(2)
	Input.action_release("hand_1")
	_check(int(scene.brain.snapshot().get("total_actions_seen", 0)) == before + 1, "数字键经真实牌库出牌后进入画像")
	_check(scene.deck.discard_pile.has(physical_card) and scene.deck.hand[0].is_empty(), "实体牌进弃牌，原槽位等待补牌")
	_check(scene.player.energy < scene.player.max_energy, "真实出牌消耗能量")
	await _frames(70)
	_check(not scene.deck.hand[0].is_empty(), "一秒后随机补牌")
	_check(scene.deck.hand.size() + scene.deck.draw_pile.size() + scene.deck.discard_pile.size() == scene.deck.total_cards, "牌组总量守恒")
	# An actual close-range hit passes through the same geometry and damage code.
	scene.player.reset_player()
	scene.target.reset_enemy()
	scene.target.combat_enabled = false
	scene.player.global_position = scene._surface_point(0, 1)
	scene.target.global_position = scene._surface_point(0, 0)
	scene.gameplay_observer.reset()
	await _frames(8)
	var health_before: float = scene.target.health
	_check(scene.player.request_card("slash"), "近战攻击正常执行")
	_check(scene.target.health < health_before, "真实几何判定扣除敌人血量")
	_check(scene.gameplay_observer.summary()["attack_results"]["hit"] > 0, "已发生的命中结果进入摘要")
	await _frames(20)
	scene.player.facing = Vector3.RIGHT
	_check(scene.player.request_card("shot"), "点射正常执行")
	_check(scene.gameplay_observer.summary()["attack_results"]["miss"] > 0, "射线确实未击中目标时才记录落空")
	var before_pause: float = scene.brain.snapshot()["time"]
	var observer_before: float = scene.gameplay_observer.summary()["observed_seconds"]
	scene._toggle_analysis()
	await _frames(20)
	_check(paused, "查看总结时暂停战斗")
	_check(is_equal_approx(scene.brain.snapshot()["time"], before_pause), "暂停时世界模型不衰减证据")
	_check(is_equal_approx(scene.gameplay_observer.summary()["observed_seconds"], observer_before), "暂停时间不混入操作习惯")
	scene._toggle_analysis()
	scene._open_browser(&"draw")
	_check(paused and scene.hud.is_browser_open(), "查看牌堆沿用真实游戏暂停机制")
	scene._close_browser()
	_check(not paused, "关闭牌堆恢复战斗")
	scene._request_llm()
	_check(scene.last_sent_context.is_empty(), "离线请求不会伪装成已发送上下文")
	_check(not scene.llm_bridge.busy, "未配置模型时手动请求不会启动网络等待")
	var report_path := "user://test_live_behavior.json"
	_check(scene.export_report(report_path) == OK, "可导出行为总结 JSON")
	var report: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(report_path))
	_check(report["source"] == "live_player" and report["context"]["world_model"].has("gameplay"), "导出包含真实动作与移动总结")
	_check(not _has_forbidden_key(report), "导出不含手牌、牌堆、随机种子或密钥")
	_check(not scene.llm_bridge.busy and not scene.auto_send.button_pressed, "离线默认不请求真实 LLM")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(report_path))
	scene._reset_battle()
	_check(int(scene.brain.snapshot()["actions_seen"]) == 0, "新观察清空画像")
	_check(scene.gameplay_observer.summary()["observed_seconds"] == 0, "重置不把传送距离当作移动")
	scene.queue_free()
	await process_frame
	print("BATTLE SCENE RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)
func _frames(count: int) -> void:
	for i in range(count):
		await physics_frame
func _has_forbidden_key(value: Variant) -> bool:
	if value is Dictionary:
		for key in value:
			if str(key) in ["hand", "draw_pile", "discard_pile", "api_key", "seed"] or _has_forbidden_key(value[key]):
				return true
	elif value is Array:
		for item in value:
			if _has_forbidden_key(item): return true
	return false
func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
		print("PASS: ", description)
	else:
		failed += 1
		push_error("FAIL: " + description)
