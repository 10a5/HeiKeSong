extends Node
## Interactive, self-contained lab for validating:
## player telemetry -> world-model summary -> bounded strategy -> local FSM reaction.
##
## The lab intentionally uses a simulated player. It can run without the main
## game, an internet connection, or an external LLM. The same signal contract
## can later be connected to the real Player node.

const BRAIN = preload("res://boss_brain.gd")
const CARD_CATALOG = preload("res://card_catalog.gd")
const STRATEGY_ADAPTER = preload("res://strategy_adapter.gd")

class SimPlayer extends Node:
	signal action_played(action_name: String, cost: float)
	signal action_attempted(action_name: String, accepted: bool, reason: String)
	signal damaged(amount: float)
	signal cybernetic_changed(active_time_left: float, cooldown_left: float)

	var energy: float = 10.0
	var max_energy: float = 10.0
	var health: float = 100.0
	var global_position := Vector3.ZERO
	var velocity := Vector3.ZERO
	var is_rolling := false
	var is_dashing := false
	var is_diving := false
	var is_dead := false
	var is_cybernetic_active := false
	var slash_time_left: float = 0.0
	var roll_direction := Vector3.FORWARD

	func reset_state() -> void:
		energy = max_energy
		health = 100.0
		global_position = Vector3.ZERO
		velocity = Vector3.ZERO
		is_rolling = false
		is_dashing = false
		is_diving = false
		is_dead = false
		is_cybernetic_active = false
		slash_time_left = 0.0

	func set_context(context: Dictionary) -> void:
		if context.has("energy"):
			energy = clampf(float(context["energy"]), 0.0, max_energy)
		if context.has("distance"):
			global_position = Vector3(float(context["distance"]), 0.0, 0.0)
		if context.has("is_rolling"):
			is_rolling = bool(context["is_rolling"])
		if context.has("is_dashing"):
			is_dashing = bool(context["is_dashing"])
		if context.has("is_diving"):
			is_diving = bool(context["is_diving"])
		if context.has("velocity") and context["velocity"] is Vector3:
			velocity = context["velocity"]

	func play_action(action_name: String, cost: float, context: Dictionary = {}) -> void:
		set_context(context)
		# Replay JSON stores energy_before. The telemetry signal observes the
		# post-cost value so the brain can reconstruct the commitment exactly.
		energy = maxf(0.0, energy - cost)
		is_rolling = action_name == "roll"
		is_dashing = action_name in ["blink", "dash_slash"]
		is_diving = action_name in ["airborne_slash", "dive_slash"]
		slash_time_left = 0.35 if CARD_CATALOG.category(action_name) in ["attack", "hybrid"] else 0.0
		action_played.emit(action_name, cost)

	func attempt_action(action_name: String, accepted: bool, reason: String, cost: float = 0.0, context: Dictionary = {}) -> void:
		set_context(context)
		action_attempted.emit(action_name, accepted, reason)
		if accepted:
			play_action(action_name, cost, context)

	func emit_damage(amount: float) -> void:
		health = maxf(0.0, health - amount)
		damaged.emit(amount)

	func emit_cybernetic(active_time_left: float, cooldown_left: float = 0.0) -> void:
		is_cybernetic_active = active_time_left > 0.0
		cybernetic_changed.emit(active_time_left, cooldown_left)


class SimBoss extends Node:
	signal reaction_applied(reaction: StringName, payload: Dictionary)
	var global_position := Vector3.ZERO
	var last_reaction: StringName = &"none"
	var last_payload: Dictionary = {}
	var reaction_count: int = 0
	var evade_count: int = 0
	var last_evade_payload: Dictionary = {}

	func apply_reaction(reaction: StringName, payload: Dictionary) -> void:
		last_reaction = reaction
		last_payload = payload.duplicate(true)
		reaction_count += 1
		if reaction == &"evade":
			evade_count += 1
			last_evade_payload = payload.duplicate(true)
		reaction_applied.emit(reaction, payload)

	func reset_reaction() -> void:
		last_reaction = &"none"
		last_payload.clear()
		reaction_count = 0
		evade_count = 0
		last_evade_payload.clear()


var brain
var player: SimPlayer
var boss: SimBoss
var event_log: Array[String] = []
var event_log_label: RichTextLabel
var model_label: RichTextLabel
var strategy_label: RichTextLabel
var reaction_label: RichTextLabel
var status_label: Label
var confidence_bar: ProgressBar
var play_timer: Timer
var playing := false
var current_replay_name := ""
var replay_catalog: Dictionary = {}
var strategy_adapter
var strategy_timer: Timer
var last_directive: Dictionary = {}

const REPLAYS := {
	"roll_slash": [
		{"type": "action", "kind": "roll", "cost": 3.0, "energy": 10.0, "distance": 2.8},
		{"type": "action", "kind": "slash", "cost": 2.0, "energy": 7.0, "distance": 2.1},
		{"type": "action", "kind": "roll", "cost": 3.0, "energy": 10.0, "distance": 2.7},
		{"type": "action", "kind": "slash", "cost": 2.0, "energy": 7.0, "distance": 2.0},
		{"type": "action", "kind": "roll", "cost": 3.0, "energy": 10.0, "distance": 2.6},
		{"type": "action", "kind": "slash", "cost": 2.0, "energy": 7.0, "distance": 2.0},
		{"type": "action", "kind": "roll", "cost": 3.0, "energy": 10.0, "distance": 2.4}
	],
	"mixed": [
		{"type": "action", "kind": "shot", "cost": 2.0, "energy": 8.0, "distance": 10.0},
		{"type": "action", "kind": "blink", "cost": 3.0, "energy": 6.0, "distance": 8.0, "is_dashing": true},
		{"type": "action", "kind": "dash_slash", "cost": 5.0, "energy": 5.0, "distance": 4.0, "is_dashing": true},
		{"type": "action", "kind": "airborne_slash", "cost": 4.0, "energy": 8.0, "distance": 5.0},
		{"type": "action", "kind": "dash_slash", "cost": 5.0, "energy": 5.0, "distance": 3.5, "is_dashing": true},
		{"type": "action", "kind": "shot", "cost": 2.0, "energy": 8.0, "distance": 9.0},
		{"type": "action", "kind": "dive_slash", "cost": 5.0, "energy": 6.0, "distance": 4.0, "is_diving": true}
	],
	"low_energy": [
		{"type": "attempt", "kind": "dash_slash", "accepted": false, "reason": "insufficient_energy", "energy": 1.0},
		{"type": "attempt", "kind": "roll", "accepted": false, "reason": "insufficient_energy", "energy": 1.0},
		{"type": "action", "kind": "punch", "cost": 1.0, "energy": 1.0, "distance": 3.0},
		{"type": "attempt", "kind": "dash_slash", "accepted": false, "reason": "insufficient_energy", "energy": 1.0}
	]
}


func _ready() -> void:
	replay_catalog = REPLAYS.duplicate(true)
	_load_replays_from_disk()
	brain = BRAIN.new()
	brain.name = "LocalAdaptiveBrain"
	add_child(brain)
	player = SimPlayer.new()
	player.name = "SimulatedPlayer"
	add_child(player)
	boss = SimBoss.new()
	boss.name = "ReactionReceiver"
	add_child(boss)
	brain.attach_player(player)
	brain.attach_opponent(boss)
	brain.reaction_requested.connect(boss.apply_reaction)
	brain.telemetry_recorded.connect(_on_telemetry)
	brain.world_model_updated.connect(_on_model_updated)
	strategy_adapter = STRATEGY_ADAPTER.new()
	boss.reaction_applied.connect(_on_reaction_applied)
	_create_ui()
	play_timer = Timer.new()
	play_timer.wait_time = 0.24
	play_timer.one_shot = false
	play_timer.timeout.connect(_play_next_step)
	add_child(play_timer)
	strategy_timer = Timer.new()
	strategy_timer.wait_time = 0.2
	strategy_timer.one_shot = false
	strategy_timer.timeout.connect(_run_strategy_update)
	add_child(strategy_timer)
	strategy_timer.start()
	_add_event("系统", "本地 FSM 已就绪；等待玩家事件")
	_refresh_ui()


func _create_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "LabUI"
	add_child(layer)
	var root_control := Control.new()
	root_control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(root_control)
	var background := ColorRect.new()
	background.color = Color("091421")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_control.add_child(background)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	root_control.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	var title := Label.new()
	title.text = "ADAPTIVE BOSS LAB  /  玩家行为分析 → 判断 → 反应"
	title.add_theme_font_size_override("font_size", 25)
	title.add_theme_color_override("font_color", Color("8fe4ff"))
	column.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "独立实验项目 · 本地可复现 · LLM 只做低频策略摘要，不进入实时命中路径"
	subtitle.add_theme_color_override("font_color", Color("91aabd"))
	column.add_child(subtitle)

	var controls := HBoxContainer.new()
	controls.add_theme_constant_override("separation", 8)
	column.add_child(controls)
	_add_button(controls, "1  翻滚→劈砍习惯", func(): _start_replay("roll_slash"))
	_add_button(controls, "2  混合打法", func(): _start_replay("mixed"))
	_add_button(controls, "3  能量不足", func(): _start_replay("low_energy"))
	_add_button(controls, "Space  自动播放", func(): _start_replay("roll_slash"))
	_add_button(controls, "R  清空画像", _reset_lab)

	status_label = Label.new()
	status_label.text = "状态：等待事件"
	status_label.add_theme_color_override("font_color", Color("d1e7f2"))
	column.add_child(status_label)
	confidence_bar = ProgressBar.new()
	confidence_bar.min_value = 0.0
	confidence_bar.max_value = 1.0
	confidence_bar.value = 0.0
	confidence_bar.show_percentage = true
	confidence_bar.custom_minimum_size.y = 18
	column.add_child(confidence_bar)

	var panels := HBoxContainer.new()
	panels.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panels.add_theme_constant_override("separation", 12)
	column.add_child(panels)
	var events_panel := _make_panel("① 玩家事件流", 0.30)
	var model_panel := _make_panel("② 世界模型 / 画像", 0.34)
	var response_panel := _make_panel("③ 策略判断 / FSM 反应", 0.36)
	panels.add_child(events_panel)
	panels.add_child(model_panel)
	panels.add_child(response_panel)
	event_log_label = events_panel.find_child("Body", true, false)
	model_label = model_panel.find_child("Body", true, false)
	strategy_label = response_panel.find_child("Strategy", true, false)
	reaction_label = response_panel.find_child("Reaction", true, false)

	var footer := Label.new()
	footer.text = "快捷键：1/2/3 播放回放   Space 播放目标习惯   R 清空画像       证据达到 3 次 roll 后才允许针对性闪避"
	footer.add_theme_color_override("font_color", Color("7893a4"))
	column.add_child(footer)


func _make_panel(title_text: String, ratio: float) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = ratio
	var style := StyleBoxFlat.new()
	style.bg_color = Color("102334")
	style.border_color = Color("234963")
	style.set_border_width_all(1)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	panel.add_theme_stylebox_override("panel", style)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)
	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", Color("bcefff"))
	column.add_child(title)
	var body := RichTextLabel.new()
	body.name = "Body"
	body.bbcode_enabled = true
	body.fit_content = false
	body.scroll_active = true
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_font_size_override("normal_font_size", 14)
	column.add_child(body)
	if title_text.begins_with("③"):
		var strategy := RichTextLabel.new()
		strategy.name = "Strategy"
		strategy.bbcode_enabled = true
		strategy.custom_minimum_size.y = 115
		strategy.add_theme_font_size_override("normal_font_size", 14)
		column.add_child(strategy)
		var reaction := RichTextLabel.new()
		reaction.name = "Reaction"
		reaction.bbcode_enabled = true
		reaction.size_flags_vertical = Control.SIZE_EXPAND_FILL
		reaction.add_theme_font_size_override("normal_font_size", 15)
		column.add_child(reaction)
	return panel


func _add_button(parent: Container, text: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(150, 34)
	button.pressed.connect(callback)
	parent.add_child(button)


func _start_replay(replay_name: String) -> void:
	if playing:
		return
	_reset_lab(false)
	playing = true
	current_replay_name = replay_name
	play_timer.set_meta("index", 0)
	status_label.text = "状态：正在播放「%s」" % _replay_title(replay_name)
	play_timer.start()
	_play_next_step()


func _play_next_step() -> void:
	var events: Array = replay_catalog.get(current_replay_name, [])
	var index := int(play_timer.get_meta("index", 0))
	if index >= events.size():
		play_timer.stop()
		playing = false
		player.is_rolling = false
		player.is_dashing = false
		player.is_diving = false
		player.slash_time_left = 0.0
		status_label.text = "状态：回放完成「%s」" % _replay_title(current_replay_name)
		_refresh_ui()
		return
	play_timer.set_meta("index", index + 1)
	_process_replay_event(events[index])
	_refresh_ui()


func _process_replay_event(event: Dictionary) -> void:
	var event_type := str(event.get("type", ""))
	if event_type == "action":
		var kind := str(event.get("kind", ""))
		var cost := float(event.get("cost", CARD_CATALOG.cost(kind)))
		player.play_action(kind, cost, event)
		_add_event("玩家", "%s  [%s]  cost %.1f  energy %.1f" % [CARD_CATALOG.card_name(kind), CARD_CATALOG.category_name(kind), cost, player.energy])
	elif event_type == "attempt":
		var kind := str(event.get("kind", ""))
		player.attempt_action(kind, bool(event.get("accepted", false)), str(event.get("reason", "rejected")), float(event.get("cost", CARD_CATALOG.cost(kind))), event)
		_add_event("玩家", "尝试 %s → 拒绝（%s）" % [CARD_CATALOG.card_name(kind), str(event.get("reason", "unknown"))])
	elif event_type == "event":
		var name := str(event.get("name", "event"))
		brain.record_event(name, event.get("payload", {}))
		_add_event("事件", name)


func _reset_lab(show_status: bool = true) -> void:
	if not is_instance_valid(brain):
		return
	if is_instance_valid(play_timer):
		play_timer.stop()
	playing = false
	current_replay_name = ""
	if is_instance_valid(play_timer):
		play_timer.set_meta("index", 0)
	player.reset_state()
	brain.reset_observation()
	boss.reset_reaction()
	last_directive.clear()
	event_log.clear()
	_run_strategy_update()
	if show_status:
		_add_event("系统", "画像已清空，策略回到 observe_and_probe")
		status_label.text = "状态：画像已清空"
	_refresh_ui()


func _on_telemetry(event: Dictionary) -> void:
	if str(event.get("type", "")) == "outcome":
		_add_event("反馈", "%s → %s" % [str(event.get("action", "")), str(event.get("outcome", ""))])
	elif str(event.get("type", "")) == "action_rejected":
		_add_event("分析", "记录拒绝尝试：%s" % str(event.get("payload", {}).get("reason", "unknown")))


func _on_model_updated(_summary: Dictionary) -> void:
	_refresh_ui()


func _run_strategy_update() -> void:
	if not is_instance_valid(brain) or strategy_adapter == null:
		return
	var directive: Dictionary = strategy_adapter.decide(brain.get_llm_context())
	if directive != last_directive:
		last_directive = directive.duplicate(true)
		brain.apply_llm_directive(directive)
		_add_event("策略", "摘要判断：%s → %s" % [str(directive.get("name", "observe_and_probe")), str(directive.get("roll_response", "disengage"))])
	_refresh_ui()


func _on_reaction_applied(reaction: StringName, payload: Dictionary) -> void:
	_add_event("Boss", "%s  ← %s" % [str(reaction), str(payload.get("reason", "local_fsm"))])
	_refresh_ui()


func _add_event(source: String, message: String) -> void:
	event_log.push_back("[color=#75c9e8]%s[/color]  %s" % [source, message])
	if event_log.size() > 18:
		event_log.pop_front()
	if is_instance_valid(event_log_label):
		event_log_label.text = "\n".join(event_log)
		event_log_label.scroll_to_line(maxi(0, event_log.size() - 1))


func _refresh_ui() -> void:
	if not is_instance_valid(brain) or not is_instance_valid(model_label):
		return
	var summary: Dictionary = brain.snapshot()
	var patterns: Dictionary = summary.get("patterns", {})
	var attempts: Dictionary = summary.get("attempts", {})
	var mix: Dictionary = summary.get("category_mix", {})
	confidence_bar.value = float(summary.get("confidence", 0.0))
	model_label.text = "[color=#d4f4ff]动作样本[/color]  %d / 40（累计 %d）\n" % [int(summary.get("actions_seen", 0)), int(summary.get("total_actions_seen", 0))]
	model_label.append_text("置信度  [color=#8fe4ff]%.0f%%[/color]\n" % (float(summary.get("confidence", 0.0)) * 100.0))
	model_label.append_text("主动作：%s\n主类别：%s\n" % [str(summary.get("dominant_action", "—")), str(summary.get("dominant_category", "—"))])
	model_label.append_text("类别：攻 %.0f%%  位移 %.0f%%  复合 %.0f%%\n" % [float(mix.get("attack", 0.0)) * 100.0, float(mix.get("movement", 0.0)) * 100.0, float(mix.get("hybrid", 0.0)) * 100.0])
	model_label.append_text("roll→攻击：%d / %d（%.0f%%）\n" % [int(patterns.get("roll_attack_count", 0)), int(patterns.get("roll_count", 0)), float(patterns.get("roll_attack_rate", 0.0)) * 100.0])
	model_label.append_text("拒绝尝试：%d（%.0f%%）" % [int(attempts.get("rejected", 0)), float(attempts.get("rejection_rate", 0.0)) * 100.0])

	strategy_label.text = "[color=#d4f4ff]策略层（摘要 → 有界判断）[/color]\n推荐：%s\n策略：%s\n翻滚应对：%s\n攻击倾向：%.2f  探索率：%.2f\n" % [str(summary.get("recommended_response", "observe_and_probe")), str(brain.strategy.get("name", "observe_and_probe")), str(brain.strategy.get("roll_response", "disengage")), float(brain.strategy.get("aggression", 0.5)), float(brain.strategy.get("exploration_rate", 0.2))]
	strategy_label.append_text("LLM 输入字段：world_model / strategy / fsm\n[font_size=12]不包含手牌、牌堆或未来随机结果[/font_size]")
	var plan: Dictionary = brain.plan_reaction()
	reaction_label.text = "[color=#d4f4ff]低延迟反应 FSM[/color]\n状态：%s（%.2fs）\n当前请求：[color=#ffcb76]%s[/color]\n" % [str(brain.reaction_state), brain.reaction_state_time, str(plan.get("reaction", "observe"))]
	reaction_label.append_text("Boss 接收：%s\n" % str(boss.last_reaction))
	if boss.evade_count > 0:
		reaction_label.append_text("最近一次针对性闪避：%d 次\n" % boss.evade_count)
	if not boss.last_payload.is_empty():
		reaction_label.append_text("原因：%s\n后续：%s" % [str(boss.last_payload.get("reason", "—")), str(boss.last_payload.get("punish_after", "—"))])


func _replay_title(key: String) -> String:
	return {"roll_slash": "翻滚→劈砍习惯", "mixed": "混合打法", "low_energy": "能量不足"}.get(key, key)


func _load_replays_from_disk() -> void:
	## JSON files model logs downloaded from a profiler or a previous run.
	## Hardcoded samples remain as a fallback so the lab is still self-contained.
	var paths := {
		"roll_slash": "res://replays/roll_slash_habit.json",
		"mixed": "res://replays/mixed_player.json",
		"low_energy": "res://replays/failed_attempts.json",
	}
	for key in paths:
		var path: String = paths[key]
		if not FileAccess.file_exists(path):
			continue
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		var parsed: Variant = JSON.parse_string(file.get_as_text())
		if parsed is Dictionary and parsed.get("events", null) is Array:
			replay_catalog[key] = parsed["events"]


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1: _start_replay("roll_slash")
			KEY_2: _start_replay("mixed")
			KEY_3: _start_replay("low_energy")
			KEY_R: _reset_lab()
			KEY_SPACE: _start_replay("roll_slash")
