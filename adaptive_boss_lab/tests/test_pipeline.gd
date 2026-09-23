extends SceneTree
## Independent integration checks for the full telemetry -> decision -> reaction path.
## Run from the repository root:
## Godot --headless --path adaptive_boss_lab --fixed-fps 60 --script tests/test_pipeline.gd

const BRAIN = preload("res://boss_brain.gd")
const ADAPTER = preload("res://strategy_adapter.gd")

class FakePlayer extends Node:
	signal action_played(action_name: String, cost: float)
	signal action_attempted(action_name: String, accepted: bool, reason: String)
	signal damaged(amount: float)
	signal cybernetic_changed(active_time_left: float, cooldown_left: float)
	var energy := 10.0
	var max_energy := 10.0
	var health := 100.0
	var global_position := Vector3.ZERO
	var velocity := Vector3.ZERO
	var is_rolling := false
	var is_dashing := false
	var is_diving := false
	var is_dead := false
	var is_cybernetic_active := false
	var slash_time_left := 0.0
	var roll_direction := Vector3.FORWARD

class FakeBoss extends Node:
	var global_position := Vector3.ZERO
	var received := 0
	var last_reaction: StringName = &"none"
	var last_payload: Dictionary = {}

	func apply_reaction(reaction: StringName, payload: Dictionary) -> void:
		received += 1
		last_reaction = reaction
		last_payload = payload.duplicate(true)

var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var brain := BRAIN.new()
	root.add_child(brain)
	var player := FakePlayer.new()
	root.add_child(player)
	var boss := FakeBoss.new()
	root.add_child(boss)
	brain.attach_player(player)
	brain.attach_opponent(boss)
	brain.reaction_requested.connect(boss.apply_reaction)
	player.global_position = Vector3(2.0, 0.0, 0.0)
	var adapter := ADAPTER.new()
	await process_frame

	for _i in range(4):
		player.is_rolling = true
		player.energy = 10.0
		player.action_played.emit("roll", 3.0)
		player.is_rolling = false
		player.energy = 8.0
		player.action_played.emit("slash", 2.0)
	var summary: Dictionary = brain.snapshot()
	var patterns: Dictionary = summary.get("patterns", {})
	_check(int(summary.get("actions_seen", 0)) == 8, "接受动作进入世界模型")
	_check(int(summary.get("total_actions_seen", 0)) == 8, "累计样本数与动作流一致")
	_check(int(patterns.get("roll_count", 0)) == 4, "世界模型识别翻滚样本")
	_check(int(patterns.get("roll_attack_count", 0)) == 4, "世界模型识别 roll→攻击 连招")
	_check(float(patterns.get("roll_attack_rate", 0.0)) > 0.99, "世界模型计算连招比例")
	_check(str(summary.get("recommended_response", "")) == "evade_roll_then_punish", "策略层给出针对性建议")
	_check(float(summary.get("distance", {}).get("bucket_mix", {}).get("near", 0.0)) > 0.0, "世界模型记录玩家与 Boss 的距离分桶")
	_check(float(patterns.get("weighted_roll_attack_count", 0.0)) > 0.0, "连招证据使用时间权重")
	var directive: Dictionary = adapter.decide(brain.get_llm_context())
	_check(str(directive.get("roll_response", "")) == "evade", "策略适配器根据世界模型选择闪避")
	_check(brain.apply_llm_directive(directive), "策略判断通过有限白名单进入脑")
	_check(str(brain.strategy.get("name", "")) == "roll_counter", "脑保存策略层的判断结果")

	var high_plan: Dictionary = brain.plan_reaction({"is_rolling": true, "energy": 8.0})
	_check(str(high_plan.get("reaction", "")) == "evade", "有证据且能量足够时 FSM 请求闪避")
	_check(str(high_plan.get("payload", {}).get("reason", "")) == "predicted_roll_attack", "反应包含机器可读原因")
	_check(str(high_plan.get("payload", {}).get("punish_after", "")) == "roll_recovery", "反应包含翻滚恢复后的惩罚窗口")

	player.is_rolling = true
	player.energy = 8.0
	player.action_played.emit("roll", 3.0)
	_check(boss.received > 0 and boss.last_reaction == &"evade", "玩家信号一路触发到 Boss 接收器")
	_check(str(boss.last_payload.get("reason", "")) == "predicted_roll_attack", "Boss 收到完整反应 payload")
	var reactions_before_duplicate := boss.received
	player.action_played.emit("roll", 3.0)
	_check(boss.received == reactions_before_duplicate, "相同反应在冷却窗口内会合并")
	var low_plan: Dictionary = brain.plan_reaction({"is_rolling": true, "energy": 1.0})
	_check(str(low_plan.get("reaction", "")) == "observe", "低能量时不执行针对性闪避")
	var compact_context: Dictionary = adapter.get_context(brain.get_llm_context())
	_check(compact_context.has("recommended_response") and not compact_context.has("action_history"), "策略适配器只消费紧凑世界模型")
	var distance_directive: Dictionary = adapter.decide({"world_model": {"recommended_response": "keep_distance", "confidence": 0.7, "evidence": {"roll_samples": 0}}})
	_check(str(distance_directive.get("name", "")) == "keep_distance" and str(distance_directive.get("roll_response", "")) == "disengage", "复合动作画像可以进入保持距离策略")

	brain.reset_observation()
	player.is_rolling = false
	player.action_played.emit("roll", 3.0)
	_check(str(brain.snapshot().get("recommended_response", "")) == "observe_and_probe", "混合或单次样本不会立即形成强策略")
	_check(brain.snapshot().get("patterns", {}).get("roll_attack_count", 0) == 0, "清空画像会清除旧连招证据")

	player.action_attempted.emit("dash_slash", false, "insufficient_energy")
	player.action_attempted.emit("roll", false, "cooldown")
	summary = brain.snapshot()
	_check(int(summary.get("attempts", {}).get("rejected", 0)) == 2, "失败尝试进入 attempts.rejected")
	_check(float(summary.get("attempts", {}).get("rejection_rate", 0.0)) > 0.5, "世界模型计算拒绝率")

	var context_text := JSON.stringify(brain.get_llm_context())
	_check(not context_text.contains("hand") and not context_text.contains("deck") and not context_text.contains("future_random"), "LLM 摘要不泄露手牌牌堆或未来随机结果")
	_check(brain.apply_llm_directive({"aggression": 0.9, "roll_response": "evade", "exploration_rate": 0.3}), "有限 LLM 策略可被安全应用")
	_check(not brain.apply_llm_directive({"roll_response": "deal_infinite_damage"}), "非法 LLM 反应被白名单拒绝")
	brain._clock = 20.0
	brain._infer_world_model()
	_check(float(brain.snapshot().get("confidence", 1.0)) < 0.4 and str(brain.snapshot().get("recommended_response", "")) == "observe_and_probe", "长期未见新动作后旧连招会衰减")

	brain.reset_observation()
	_check(int(brain.snapshot().get("actions_seen", -1)) == 0, "R/重置操作让画像回到空状态")
	print("PIPELINE RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
		print("PASS: ", description)
	else:
		failed += 1
		push_error("FAIL: " + description)
