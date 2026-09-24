extends Node
class_name AdaptiveBossRuntime
## Runtime bridge for the final duel's three-layer adaptive controller.
##
## The brain owns the compact world model and the low-latency reaction FSM.
## This node adds the optional 60-second gameplay observer, a bounded local
## strategy fallback, and an asynchronous OpenAI-compatible LLM transport.
## Network responses can only update the brain's validated strategy knobs;
## movement, hit tests, damage and victory remain local game code.

signal status_changed(message: String)
signal policy_updated(source: String, strategy: Dictionary)
signal reaction_updated(reaction: StringName, payload: Dictionary)

const OBSERVER_SCRIPT = preload("res://gameplay_observer.gd")
const BRIDGE_SCRIPT = preload("res://llm_bridge.gd")
const ADAPTER_SCRIPT = preload("res://strategy_adapter.gd")
const CARD_CATALOG = preload("res://card_catalog.gd")

@export_range(2.0, 60.0, 1.0) var llm_interval: float = 12.0
@export_range(1, 40, 1) var minimum_actions_for_llm: int = 4
@export_range(0.05, 2.0, 0.05) var local_update_interval: float = 0.25

var player: Node
var brain: Node
var boss: Node
var observer: Node
var llm_bridge: Node
var strategy_adapter = ADAPTER_SCRIPT.new()
var active := false
var llm_status := "LLM 未配置"
var llm_summary := "尚无模型回复。Boss 将先使用本地策略观察。"
var last_sent_context: Dictionary = {}
var last_directive: Dictionary = {}
var last_reaction: StringName = &"observe"
var last_reaction_reason := ""
var has_llm_policy := false

var _llm_clock := 0.0
var _local_clock := 0.0
var _last_llm_actions := -1
var _boss_connections: Array[Dictionary] = []
var _brain_connected := false


func _ready() -> void:
	# The bridge itself is PROCESS_MODE_ALWAYS so an in-flight HTTP request can
	# finish while a modal pauses gameplay. The observer/brain remain pausable.
	process_mode = Node.PROCESS_MODE_ALWAYS


func setup(actor: Node, source_brain: Node) -> void:
	player = actor
	brain = source_brain
	if not is_instance_valid(observer):
		observer = OBSERVER_SCRIPT.new()
		observer.name = "AdaptiveGameplayObserver"
		add_child(observer)
	observer.setup(player, brain, null)
	if not is_instance_valid(llm_bridge):
		llm_bridge = BRIDGE_SCRIPT.new()
		llm_bridge.name = "AdaptiveLLMBridge"
		llm_bridge.status_changed.connect(_on_llm_status)
		llm_bridge.summary_received.connect(_on_llm_summary)
		llm_bridge.request_failed.connect(_on_llm_failure)
		add_child(llm_bridge)
	if is_instance_valid(brain) and brain.has_signal("reaction_requested") and not _brain_connected:
		brain.reaction_requested.connect(_on_reaction)
		_brain_connected = true
	if is_instance_valid(player) and player.has_signal("attack_observed"):
		var attack_callable := Callable(self, "_on_player_attack_observed")
		if not player.is_connected("attack_observed", attack_callable):
			player.connect("attack_observed", attack_callable)


func attach_boss(target: Node, reset_model: bool = true) -> void:
	if not is_instance_valid(player) or not is_instance_valid(brain):
		return
	_disconnect_boss()
	boss = target
	active = is_instance_valid(boss)
	_llm_clock = 0.0
	_local_clock = 0.0
	_last_llm_actions = -1
	last_reaction = &"observe"
	last_reaction_reason = ""
	last_sent_context.clear()
	last_directive.clear()
	has_llm_policy = false
	llm_summary = "正在收集决战行为样本，等待模型分析。"
	if reset_model:
		brain.reset_observation()
	brain.attach_opponent(boss)
	if is_instance_valid(observer):
		observer.setup(player, brain, boss)
	_connect_boss()
	_apply_local_strategy()
	if active:
		_emit_status("自适应 Boss 已启动：世界模型 → LLM → 反应 FSM")


func detach_boss() -> void:
	active = false
	_disconnect_boss()
	boss = null
	last_reaction = &"observe"
	last_reaction_reason = ""
	if is_instance_valid(llm_bridge):
		llm_bridge.cancel_request()
	if is_instance_valid(observer):
		observer.target = null


func reset_run() -> void:
	detach_boss()
	if is_instance_valid(observer):
		observer.reset()
	if is_instance_valid(brain):
		brain.reset_observation()
	last_sent_context.clear()
	last_directive.clear()
	has_llm_policy = false
	llm_summary = "尚无模型回复。Boss 将先使用本地策略观察。"
	_last_llm_actions = -1


func request_llm_now() -> bool:
	if not active or not is_instance_valid(llm_bridge) or llm_bridge.busy:
		return false
	return _request_llm()


func record_jump(accepted: bool) -> void:
	## The player owns jump validation; the runtime only forwards the result to
	## the observer so a rejected attempt is distinguishable from no input.
	if is_instance_valid(observer):
		observer.record_jump(accepted)


func build_context() -> Dictionary:
	if not is_instance_valid(brain):
		return {}
	var context: Dictionary = brain.get_llm_context()
	var model_variant: Variant = context.get("world_model", {})
	var model: Dictionary = model_variant if model_variant is Dictionary else {}
	if is_instance_valid(observer):
		model["gameplay"] = observer.summary()
	model["interpretation"] = _behavior_summary(model)
	context["world_model"] = model
	if is_instance_valid(boss):
		context["opponent"] = {
			"controller": "adaptive_local_fsm",
			"state": str(boss.get("state")),
			"reaction": str(boss.get("adaptive_reaction")),
			"health": float(boss.get("health")),
			"energy": float(boss.get("energy")),
			"shield": float(boss.get("shield")),
			"entrance_invulnerable": bool(boss.get("is_entering")),
			"entrance_time_left": float(boss.get("entrance_time_left")),
			"preferred_distance_m": float(boss.call("get_preferred_distance")) if boss.has_method("get_preferred_distance") else 0.0,
			"combos": [
				{"id": "roll_punches", "actions": ["roll_forward", "slash", "slash", "roll_backward"], "cost": float(boss.call("get_combo_cost", &"roll_punches"))} if boss.has_method("get_combo_cost") else {},
				{"id": "dash_kick", "actions": ["dash_slash", "front_kick"], "cost": float(boss.call("get_combo_cost", &"dash_kick"))} if boss.has_method("get_combo_cost") else {},
			],
			"close_defense": "shield",
		}
	context["limits"] = [
		"统计画像，非训练得到的因果世界模型",
		"命中与伤害来自本地真实结算",
		"未观察到结果不代表攻击落空",
		"不包含手牌、牌堆、API 密钥和未来随机数",
	]
	return context


func snapshot() -> Dictionary:
	return {
		"active": active,
		"llm_configured": is_instance_valid(llm_bridge) and llm_bridge.is_configured(),
		"llm_busy": is_instance_valid(llm_bridge) and llm_bridge.busy,
		"llm_status": llm_status,
		"llm_summary": llm_summary,
		"policy_source": "llm" if has_llm_policy else "local_rule",
		"strategy": brain.strategy.duplicate(true) if is_instance_valid(brain) else {},
		"reaction": str(last_reaction),
		"reaction_reason": last_reaction_reason,
		"actions_seen": int(brain.snapshot().get("total_actions_seen", 0)) if is_instance_valid(brain) else 0,
	}


func _process(delta: float) -> void:
	if not active or not is_instance_valid(player) or not is_instance_valid(brain):
		return
	if get_tree().paused or bool(player.get("is_dead")) or (is_instance_valid(boss) and bool(boss.get("is_dead"))):
		return
	_local_clock += maxf(delta, 0.0)
	_llm_clock += maxf(delta, 0.0)
	if _local_clock >= local_update_interval:
		_local_clock = 0.0
		_apply_local_strategy()
	if _llm_clock >= llm_interval:
		_llm_clock = 0.0
		_request_llm()


func _apply_local_strategy() -> void:
	if not is_instance_valid(brain) or has_llm_policy:
		return
	var directive: Dictionary = strategy_adapter.decide(build_context())
	if directive == last_directive:
		return
	last_directive = directive.duplicate(true)
	if brain.apply_llm_directive(directive):
		policy_updated.emit("local_rule", brain.strategy.duplicate(true))


func _request_llm() -> bool:
	if not active or not is_instance_valid(llm_bridge) or not llm_bridge.is_configured() or llm_bridge.busy:
		return false
	var samples := int(brain.snapshot().get("total_actions_seen", 0))
	if samples < minimum_actions_for_llm or samples == _last_llm_actions:
		return false
	var context := build_context()
	if not llm_bridge.request_summary(context):
		return false
	last_sent_context = context
	_last_llm_actions = samples
	return true


func _on_llm_summary(summary_text: String, directive: Dictionary) -> void:
	if not active:
		return
	llm_summary = summary_text
	has_llm_policy = is_instance_valid(brain) and brain.apply_llm_directive(directive)
	policy_updated.emit("llm", brain.strategy.duplicate(true) if is_instance_valid(brain) else {})
	_emit_status("LLM 策略已更新：%s" % summary_text)


func _on_llm_status(message: String) -> void:
	llm_status = message
	# Configuration messages are useful to diagnostics but should not interrupt
	# play every frame; the caller can inspect snapshot() for the full status.
	if message.contains("已返回") or message.contains("失败") or message.contains("错误"):
		_emit_status(message)


func _on_llm_failure(message: String) -> void:
	has_llm_policy = false
	last_directive.clear()
	# Permit a later interval to retry the same evidence after a transient
	# network/API failure; local strategy remains active in the meantime.
	_last_llm_actions = -1
	_emit_status(message)
	_apply_local_strategy()


func _on_reaction(reaction: StringName, payload: Dictionary) -> void:
	last_reaction = reaction
	last_reaction_reason = str(payload.get("reason", "观察中"))
	if is_instance_valid(boss) and boss.has_method("apply_adaptive_reaction"):
		boss.apply_adaptive_reaction(reaction, payload)
	reaction_updated.emit(reaction, payload)


func _on_player_attack_observed(kind: String, hit: bool, damage: float) -> void:
	if is_instance_valid(observer):
		observer.record_attack_result(kind, hit, damage)


func _connect_boss() -> void:
	if not is_instance_valid(boss) or not is_instance_valid(brain):
		return
	if boss.has_signal("dodge_observed"):
		_connect_boss_signal("dodge_observed", func(): brain.record_event("dodge_success", {"attack": "boss_melee"}))
	if boss.has_signal("combo_started"):
		_connect_boss_signal("combo_started", func(combo: StringName): brain.record_event("opponent_combo_started", {"combo": str(combo)}))
	if boss.has_signal("combo_finished"):
		_connect_boss_signal("combo_finished", func(combo: StringName): brain.record_event("opponent_combo_finished", {"combo": str(combo)}))
	if boss.has_signal("action_played"):
		_connect_boss_signal("action_played", func(kind: String, _cost: float): brain.record_event("opponent_action_" + kind))
	if boss.has_signal("attack_observed"):
		_connect_boss_signal("attack_observed", func(kind: String, hit: bool, damage: float): brain.record_action_outcome("opponent_" + kind, "hit" if hit else "miss", 1.0))


func _connect_boss_signal(signal_name: StringName, callback: Callable) -> void:
	if not boss.is_connected(signal_name, callback):
		boss.connect(signal_name, callback)
		_boss_connections.append({"signal": signal_name, "callable": callback})


func _disconnect_boss() -> void:
	for item in _boss_connections:
		if is_instance_valid(boss) and boss.is_connected(item["signal"], item["callable"]):
			boss.disconnect(item["signal"], item["callable"])
	_boss_connections.clear()


func _behavior_summary(model: Dictionary) -> String:
	var pattern: Dictionary = model.get("patterns", {})
	var attempts: Dictionary = model.get("attempts", {})
	var text := "记录 %d 次成功出牌、%d 次失败尝试。" % [int(model.get("total_actions_seen", 0)), int(attempts.get("rejected", 0))]
	var kind := str(model.get("dominant_action", ""))
	if not kind.is_empty() and CARD_CATALOG.has_kind(kind):
		text += "近期常用「%s」。" % CARD_CATALOG.card_name(kind)
	text += "翻滚后短时间接攻击 %d / %d 次。" % [int(pattern.get("roll_attack_count", 0)), int(pattern.get("roll_count", 0))]
	return text


func _emit_status(message: String) -> void:
	status_changed.emit(message)
