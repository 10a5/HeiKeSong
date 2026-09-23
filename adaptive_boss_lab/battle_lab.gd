extends Node3D
## Isolated hands-on arena: real game movement, animation, deck, HUD and combat.
## The observer consumes public gameplay; the optional LLM receives summaries.
const PLAYER_SCRIPT = preload("res://player.gd")
const DECK_SCRIPT = preload("res://deck.gd")
const HUD_SCRIPT = preload("res://hud.gd")
const ENEMY_SCRIPT = preload("res://mirror_boss.gd")
const BRAIN_SCRIPT = preload("res://boss_brain.gd")
const ADAPTER_SCRIPT = preload("res://strategy_adapter.gd")
const OBSERVER_SCRIPT = preload("res://gameplay_observer.gd")
const BRIDGE_SCRIPT = preload("res://llm_bridge.gd")
const CATALOG = preload("res://card_catalog.gd")
const ARENA_SCENE = preload("res://决战场景.glb")
const UI_FONT = preload("res://assets/fonts/NotoSansSC-Regular.ttf")
const CAMERA_YAW := 0.0
const CAMERA_PITCH := 1.02
const CAMERA_DISTANCE := 12.0

var player: CharacterBody3D
var deck: Node
var brain: Node
var target: CharacterBody3D
var arena: Node3D
var camera: Camera3D
var hud: Control
var gameplay_observer: Node
var llm_bridge: Node
var strategy_adapter = ADAPTER_SCRIPT.new()
var initialized := false
var paused := false
var orbiting := false
var camera_yaw := CAMERA_YAW
var camera_pitch := CAMERA_PITCH
var camera_distance := CAMERA_DISTANCE
var camera_target := Vector3.ZERO
var _paused_before_modal := false
var _refresh_clock := 0.0
var _auto_clock := 0.0
var _last_llm_actions := -1
var _has_llm_policy := false
var _last_directive: Dictionary = {}
var _last_enemy_state := ""
var _last_reaction := "observe"
var _last_reaction_reason := ""
var _llm_summary := "尚无模型回复。先操作人物，再查看或导出行为总结。"
var _llm_status := "LLM 未配置"
var _notice := ""
var llm_context_text := ""
var last_sent_context: Dictionary = {}
var telemetry_label: Label
var boss_health_bar: ProgressBar
var boss_energy_bar: ProgressBar
var boss_energy_label: Label
var analysis_panel: PanelContainer
var analysis_label: RichTextLabel
var llm_label: RichTextLabel
var notice_label: Label
var send_button: Button
var auto_send: CheckButton
var report_dialog: FileDialog
var config_dialog: FileDialog


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_create_environment()
	_create_arena()
	# Wait for static mesh collision to reach the physics server before choosing
	# spawn points on the downloaded arena's actual, slightly curved floor.
	await get_tree().physics_frame
	await get_tree().physics_frame
	_create_actors()
	_create_deck_and_brain()
	_create_camera()
	_create_ui()
	initialized = true
	_refresh_analysis()


func _create_environment() -> void:
	var world := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("080e1b")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("b4d3ed")
	environment.ambient_light_energy = 0.7
	world.environment = environment
	add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -25, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 40
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-35, 145, 0)
	fill.light_color = Color("95bcf9")
	fill.light_energy = 0.35
	add_child(fill)


func _create_arena() -> void:
	arena = ARENA_SCENE.instantiate() as Node3D
	arena.name = "DuelArena"
	# Source mesh is about 93 x 67 x 97 units and its floor tilts 15 degrees.
	arena.scale = Vector3.ONE * 0.3
	arena.rotation_degrees.x = -15.0
	arena.position.y = -5.0
	add_child(arena)
	for mesh: MeshInstance3D in arena.find_children("*", "MeshInstance3D", true, false):
		mesh.create_trimesh_collision()
		for body in mesh.get_children():
			if body is StaticBody3D:
				body.collision_layer = 1
				body.collision_mask = 2 | 4


func _surface_point(x: float, z: float) -> Vector3:
	var query := PhysicsRayQueryParameters3D.create(Vector3(x, 25, z), Vector3(x, -10, z), 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		push_error("Arena has no floor at requested spawn")
		return Vector3(x, 1, z)
	return (hit["position"] as Vector3) + Vector3.UP * 0.05


func _create_actors() -> void:
	player = PLAYER_SCRIPT.new()
	player.name = "Player"
	player.process_mode = Node.PROCESS_MODE_PAUSABLE
	player.spawn_position = _surface_point(0, 4)
	player.arena_rect = Rect2(-9.5, -7.5, 19, 15)
	add_child(player)
	player.collision_mask |= 4
	target = ENEMY_SCRIPT.new()
	target.name = "MirrorBoss"
	target.display_name = "镜像 Boss"
	target.max_health = 500
	target.spawn_position = _surface_point(0, -0.5)
	target.arena_rect = player.arena_rect
	add_child(target)
	target.setup(player)


func _create_deck_and_brain() -> void:
	deck = DECK_SCRIPT.new()
	deck.name = "Deck"
	add_child(deck)
	deck.setup(player)
	# Testing starts with every current action unlocked; all card circulation,
	# costs, locks and random draws remain the game's real implementation.
	for kind in CATALOG.kinds():
		deck.unlock_kind(kind)
	deck.reset_deck()
	brain = BRAIN_SCRIPT.new()
	brain.name = "AdaptiveBossBrain"
	add_child(brain)
	brain.process_mode = Node.PROCESS_MODE_PAUSABLE
	brain.attach_player(player)
	brain.attach_opponent(target)
	brain.reaction_requested.connect(_on_reaction)
	gameplay_observer = OBSERVER_SCRIPT.new()
	add_child(gameplay_observer)
	gameplay_observer.setup(player, brain, target)
	player.attack_observed.connect(_on_attack_observed)
	target.dodge_observed.connect(func(): brain.record_event("dodge_success", {"attack": "boss_melee"}))
	target.combo_started.connect(func(combo: StringName): brain.record_event("opponent_combo_started", {"combo": str(combo)}))
	target.action_played.connect(func(kind: String, _cost: float): brain.record_event("opponent_action_" + kind))
	llm_bridge = BRIDGE_SCRIPT.new()
	llm_bridge.status_changed.connect(func(message: String): _llm_status = message)
	llm_bridge.request_failed.connect(func(message: String): _notice = message)
	llm_bridge.summary_received.connect(_on_llm_summary)
	add_child(llm_bridge)


func _create_camera() -> void:
	camera = Camera3D.new()
	camera.name = "OrbitCamera"
	camera.fov = 52
	camera.near = 0.1
	camera.far = 150
	camera.current = true
	add_child(camera)
	camera_target = player.global_position + Vector3.UP * 0.8
	_update_camera()


func _physics_process(_delta: float) -> void:
	if not initialized or paused or player.is_dead:
		return
	player.movement_yaw = camera_yaw
	if Input.is_action_just_pressed("cybernetic_boost"):
		player.activate_cybernetic()
	if Input.is_action_just_pressed("jump"):
		gameplay_observer.record_jump(player.request_jump())
	for slot in range(4):
		if Input.is_action_just_pressed("hand_%d" % (slot + 1)):
			deck.play_slot(slot)
			break
	if player.global_position.y < -8:
		player.become_lost()
	var enemy_state := str(target.state)
	if enemy_state != _last_enemy_state:
		_last_enemy_state = enemy_state
		brain.record_event("opponent_state", {"state": enemy_state})


func _process(delta: float) -> void:
	if not initialized:
		return
	if not paused:
		camera_target = camera_target.lerp(player.global_position + Vector3.UP * 0.8, 1.0 - exp(-8 * delta))
		_update_camera()
	_refresh_clock += delta
	if _refresh_clock >= 0.25:
		_refresh_clock = 0
		_refresh_analysis()
	if auto_send.button_pressed and not paused:
		_auto_clock += delta
		if _auto_clock >= 15.0:
			_auto_clock = 0
			var samples := int(brain.snapshot().get("total_actions_seen", 0))
			if samples != _last_llm_actions and samples >= 4 and llm_bridge.is_configured() and not llm_bridge.busy:
				_request_llm()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		orbiting = false
	if not initialized or not event is InputEventKey or not event.pressed or event.echo:
		return
	if analysis_panel.visible and event.keycode in [KEY_ESCAPE, KEY_B]:
		_toggle_analysis()
		get_viewport().set_input_as_handled()
	elif hud.is_browser_open() and event.keycode in [KEY_ESCAPE, KEY_TAB]:
		_close_browser()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not initialized:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_R: _reset_battle()
			KEY_ESCAPE: _set_paused(not paused)
			KEY_TAB: _open_browser(&"all")
			KEY_B: _toggle_analysis()
			KEY_F6: _request_llm()
			_: return
		get_viewport().set_input_as_handled()
		return
	if paused:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			orbiting = event.pressed
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera_distance = clampf(camera_distance - 1.25, 4, 45)
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera_distance = clampf(camera_distance + 1.25, 4, 45)
	elif event is InputEventMouseMotion and orbiting:
		camera_yaw = wrapf(camera_yaw - event.relative.x * 0.006, -PI, PI)
		camera_pitch = clampf(camera_pitch + event.relative.y * 0.005, 0.04, 1.50)
		player.movement_yaw = camera_yaw
	elif event is InputEventMagnifyGesture and is_finite(event.factor) and event.factor > 0:
		camera_distance = clampf(camera_distance / event.factor, 4, 45)
	elif event is InputEventPanGesture:
		camera_distance = clampf(camera_distance + event.delta.y * 1.25, 4, 45)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		orbiting = false


func _update_camera() -> void:
	var horizontal := cos(camera_pitch) * camera_distance
	var desired := camera_target + Vector3(sin(camera_yaw) * horizontal, sin(camera_pitch) * camera_distance, cos(camera_yaw) * horizontal)
	# Keep the orbit inside foreground arena walls instead of hiding the player.
	var ray := PhysicsRayQueryParameters3D.create(camera_target, desired, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	if not hit.is_empty():
		var direction := (desired - camera_target).normalized()
		desired = (hit["position"] as Vector3) - direction * 0.35
	camera.global_position = desired
	if camera.global_position.distance_to(camera_target) > 0.1:
		camera.look_at(camera_target)


func _on_attack_observed(kind: String, hit: bool, damage: float) -> void:
	gameplay_observer.record_attack_result(kind, hit, damage)


func _on_reaction(reaction: StringName, payload: Dictionary) -> void:
	_last_reaction = str(reaction)
	_last_reaction_reason = str(payload.get("reason", "观察中"))
	target.apply_adaptive_reaction(reaction, payload)


func build_llm_context() -> Dictionary:
	var context: Dictionary = brain.get_llm_context()
	context["world_model"]["gameplay"] = gameplay_observer.summary()
	context["world_model"]["interpretation"] = _behavior_summary(context["world_model"])
	context["opponent"] = {
		"controller": "fixed_combo_fsm", "state": str(target.state),
		"health": target.health, "energy": target.energy, "shield": target.shield,
		"entrance_invulnerable": target.is_entering, "entrance_time_left": target.entrance_time_left,
		"preferred_distance_m": target.get_preferred_distance(),
		"combos": [
			{"id": "roll_punches", "actions": ["roll_forward", "slash", "slash", "roll_backward"], "cost": target.get_combo_cost(&"roll_punches")},
			{"id": "dash_kick", "actions": ["dash_slash", "front_kick"], "cost": target.get_combo_cost(&"dash_kick")},
		],
		"close_defense": "shield",
	}
	context["limits"] = ["统计画像，非训练得到的因果世界模型", "命中与伤害来自本地真实结算", "未观察到结果不代表攻击落空", "不包含手牌、牌堆和未来随机数"]
	return context


func _behavior_summary(model: Dictionary) -> String:
	var pattern: Dictionary = model.get("patterns", {})
	var attempts: Dictionary = model.get("attempts", {})
	var text := "记录了 %d 次成功出牌、%d 次失败尝试。" % [int(model.get("total_actions_seen", 0)), int(attempts.get("rejected", 0))]
	var kind := str(model.get("dominant_action", ""))
	if not kind.is_empty():
		text += "近期常用「%s」。" % CATALOG.card_name(kind)
	text += "最近 %d 次翻滚中有 %d 次在 %.2f 秒内紧接攻击。" % [int(pattern.get("roll_count", 0)), int(pattern.get("roll_attack_count", 0)), brain.pattern_window]
	text += "当前建议：%s；证据评分 %.0f%%（样本量与时效指标，不是校准概率）。" % [str(model.get("recommended_response", "observe_and_probe")), float(model.get("confidence", 0)) * 100]
	return text


func _request_llm() -> void:
	if not initialized or llm_bridge.busy:
		return
	var context := build_llm_context()
	if llm_bridge.request_summary(context):
		last_sent_context = context
		_last_llm_actions = int(brain.snapshot().get("total_actions_seen", 0))
	_refresh_analysis()


func _on_llm_summary(summary_text: String, directive: Dictionary) -> void:
	_llm_summary = summary_text
	_has_llm_policy = brain.apply_llm_directive(directive)
	_notice = "已收到真实模型回复；有限策略已更新。" if _has_llm_policy else "已收到模型总结，没有更改战斗策略。"
	_refresh_analysis()


func export_report(path: String) -> Error:
	var report := {
		"schema": 1, "source": "live_player", "context": build_llm_context(),
		"last_sent_context": last_sent_context, "llm_status": _llm_status,
		"llm_summary": _llm_summary, "policy_source": "llm" if _has_llm_policy else "local_rule",
	}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(report, "  "))
	return OK


func _reset_battle() -> void:
	if not initialized:
		return
	llm_bridge.cancel_request()
	hud.hide_browser()
	analysis_panel.hide()
	_set_paused(false)
	player.reset_player()
	target.reset_enemy()
	deck.reset_deck()
	brain.reset_observation()
	gameplay_observer.reset()
	_has_llm_policy = false
	_last_directive.clear()
	last_sent_context.clear()
	_llm_summary = "已开始新的观察会话，等待操作。"
	_last_llm_actions = -1
	_auto_clock = 0
	_last_reaction = "observe"
	_last_reaction_reason = ""
	_last_enemy_state = ""
	camera_yaw = CAMERA_YAW
	camera_pitch = CAMERA_PITCH
	camera_distance = CAMERA_DISTANCE
	camera_target = player.global_position + Vector3.UP * 0.8
	hud.setup(player, deck)
	_refresh_analysis()


func _set_paused(value: bool) -> void:
	paused = value
	get_tree().paused = value
	orbiting = false
	hud.set_paused(value)


func _open_browser(view: StringName) -> void:
	if not hud.is_browser_open():
		_paused_before_modal = paused
	_set_paused(true)
	hud.show_browser(view)


func _close_browser() -> void:
	hud.hide_browser()
	_set_paused(_paused_before_modal)


func _toggle_analysis() -> void:
	if analysis_panel.visible:
		analysis_panel.hide()
		_set_paused(_paused_before_modal)
	else:
		_paused_before_modal = paused
		_set_paused(true)
		analysis_panel.show()
		_refresh_analysis()


func _create_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "HUD"
	add_child(canvas)
	hud = HUD_SCRIPT.new()
	canvas.add_child(hud)
	hud.setup(player, deck)
	hud.set_location("决战实验", "", "R  新观察")
	hud.card_requested.connect(func(slot: int): deck.play_slot(slot))
	hud.reset_requested.connect(_reset_battle)
	hud.pause_requested.connect(func(): _set_paused(not paused))
	hud.browser_requested.connect(_open_browser)
	hud.browser_close_requested.connect(_close_browser)
	var ui := Control.new()
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var theme := Theme.new()
	theme.default_font = UI_FONT
	theme.default_font_size = 13
	ui.theme = theme
	canvas.add_child(ui)
	var banner := VBoxContainer.new()
	banner.position = Vector2(315, 8)
	banner.size = Vector2(330, 82)
	banner.add_theme_constant_override("separation", 2)
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(banner)
	telemetry_label = Label.new()
	telemetry_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	telemetry_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	telemetry_label.add_theme_color_override("font_color", Color("ffd7cf"))
	telemetry_label.add_theme_color_override("font_outline_color", Color("10151f"))
	telemetry_label.add_theme_constant_override("outline_size", 4)
	banner.add_child(telemetry_label)
	boss_health_bar = _boss_bar(banner, Color("ec777e"), 8)
	boss_energy_label = Label.new()
	boss_energy_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	boss_energy_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	boss_energy_label.add_theme_font_size_override("font_size", 11)
	boss_energy_label.add_theme_color_override("font_color", Color("ffdb9f"))
	boss_energy_label.add_theme_color_override("font_outline_color", Color("10151f"))
	boss_energy_label.add_theme_constant_override("outline_size", 4)
	banner.add_child(boss_energy_label)
	boss_energy_bar = _boss_bar(banner, Color("efba66"), 5)
	var row := HBoxContainer.new()
	row.position = Vector2(740, 92)
	row.size = Vector2(200, 30)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	ui.add_child(row)
	_button(row, "B  行为总结 / LLM", _toggle_analysis)
	_button(row, "导出总结", _show_export)
	target.health_changed.connect(func(_current: float, _maximum: float): _refresh_boss_hud())
	target.energy_changed.connect(func(_current: float, _maximum: float): _refresh_boss_hud())
	target.shield_changed.connect(func(_current: float): _refresh_boss_hud())
	analysis_panel = PanelContainer.new()
	analysis_panel.position = Vector2(115, 82)
	analysis_panel.size = Vector2(730, 340)
	analysis_panel.hide()
	var style := StyleBoxFlat.new()
	style.bg_color = Color("0b1d2b")
	style.border_color = Color("4c948f")
	style.set_border_width_all(1)
	style.set_content_margin_all(15)
	analysis_panel.add_theme_stylebox_override("panel", style)
	ui.add_child(analysis_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 9)
	analysis_panel.add_child(column)
	var title := Label.new()
	title.text = "玩家操作 → 行为统计 → LLM 判断 → 本地反应"
	title.add_theme_font_size_override("font_size", 18)
	column.add_child(title)
	var body := HBoxContainer.new()
	body.custom_minimum_size = Vector2(700, 220)
	body.add_theme_constant_override("separation", 14)
	column.add_child(body)
	analysis_label = RichTextLabel.new()
	analysis_label.custom_minimum_size = Vector2(345, 220)
	analysis_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(analysis_label)
	llm_label = RichTextLabel.new()
	llm_label.custom_minimum_size = Vector2(340, 220)
	llm_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(llm_label)
	var actions := HBoxContainer.new()
	column.add_child(actions)
	send_button = _button(actions, "发送给 LLM", _request_llm)
	_button(actions, "导入配置", func(): config_dialog.popup_centered(Vector2i(740, 450)))
	_button(actions, "导出 JSON", _show_export)
	auto_send = CheckButton.new()
	auto_send.text = "每 15 秒发送"
	auto_send.focus_mode = Control.FOCUS_NONE
	actions.add_child(auto_send)
	_button(actions, "关闭", _toggle_analysis)
	var combat := CheckButton.new()
	combat.text = "Boss 自动战斗（关闭后可练习连招）"
	combat.button_pressed = true
	combat.focus_mode = Control.FOCUS_NONE
	combat.toggled.connect(func(enabled: bool): target.combat_enabled = enabled)
	column.add_child(combat)
	notice_label = Label.new()
	notice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice_label.custom_minimum_size.x = 700
	column.add_child(notice_label)
	report_dialog = FileDialog.new()
	report_dialog.access = FileDialog.ACCESS_FILESYSTEM
	report_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	report_dialog.filters = PackedStringArray(["*.json ; 行为总结"])
	report_dialog.title = "导出玩家行为总结"
	report_dialog.current_file = "player_behavior.json"
	report_dialog.file_selected.connect(func(path: String):
		_notice = "已导出：" + path if export_report(path) == OK else "导出失败，请检查保存位置。"
	)
	ui.add_child(report_dialog)
	config_dialog = FileDialog.new()
	config_dialog.access = FileDialog.ACCESS_FILESYSTEM
	config_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	config_dialog.filters = PackedStringArray(["*.json ; LLM 配置"])
	config_dialog.title = "选择 LLM 配置 JSON"
	config_dialog.file_selected.connect(_import_config)
	ui.add_child(config_dialog)


func _button(parent: Node, caption: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = caption
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _boss_bar(parent: Node, color: Color, height: float) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.custom_minimum_size.y = height
	bar.show_percentage = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var background := StyleBoxFlat.new()
	background.bg_color = Color("17232ee6")
	background.set_corner_radius_all(2)
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	fill.set_corner_radius_all(2)
	bar.add_theme_stylebox_override("background", background)
	bar.add_theme_stylebox_override("fill", fill)
	parent.add_child(bar)
	return bar


func _boss_state_name() -> String:
	if target.is_entering:
		return "入场护盾 · %.1f 秒" % target.entrance_time_left
	return str({
		"recover": "回能走位", "windup": "准备出招", "roll": "翻滚",
		"slash": "出拳", "dash_slash": "突进出拳", "front_kick": "回旋踢",
		"shield": "近身护盾", "dead": "已击败", "idle": "待机",
	}.get(str(target.state), "战斗中"))


func _refresh_boss_hud() -> void:
	if not is_instance_valid(boss_energy_bar):
		return
	telemetry_label.text = "%s  %.0f / %.0f  ·  护盾 %.0f" % [target.display_name, target.health, target.max_health, target.shield]
	if target.is_entering:
		telemetry_label.text = "%s  %.0f / %.0f  ·  无敌" % [target.display_name, target.health, target.max_health]
	boss_health_bar.max_value = target.max_health
	boss_health_bar.value = target.health
	boss_energy_bar.max_value = target.max_energy
	boss_energy_bar.value = target.energy
	boss_energy_label.text = "能量 %.1f / %.0f  ·  %s" % [target.energy, target.max_energy, _boss_state_name()]


func _show_export() -> void:
	if not analysis_panel.visible:
		_toggle_analysis()
	report_dialog.popup_centered(Vector2i(740, 450))


func _import_config(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > 8192:
		_notice = "配置文件无法读取或过大。"
		return
	var config: Variant = JSON.parse_string(file.get_as_text())
	if not config is Dictionary:
		_notice = "配置必须是 JSON 对象。"
		return
	if llm_bridge.configure(config):
		var saved := FileAccess.open("user://llm_config.json", FileAccess.WRITE)
		if saved:
			saved.store_string(JSON.stringify(config, "  "))
		_notice = "配置已保存。点击发送，收到有效回复后才会显示已连接。"


func _refresh_analysis() -> void:
	if not initialized:
		return
	var context := build_llm_context()
	llm_context_text = JSON.stringify(context, "  ")
	if not _has_llm_policy and not paused:
		var directive: Dictionary = strategy_adapter.decide(context)
		if directive != _last_directive:
			_last_directive = directive
			brain.apply_llm_directive(directive)
	var model: Dictionary = context["world_model"]
	var gameplay: Dictionary = model["gameplay"]
	var attacks: Dictionary = gameplay["attack_results"]
	var source := "LLM 策略" if _has_llm_policy else "本地规则"
	_refresh_boss_hud()
	analysis_label.text = "%s\n\n%s\n\n观察窗口内：已确认命中 %d 次 / 射击落空 %d 次，造成伤害 %.0f。\n\n行为判断建议：%s\n原因：%s\nBoss 执行：%s（固定连招 AI，尚未使用行为判断建议）。" % [_behavior_summary(model), str(gameplay["interpretation"]), int(attacks["hit"]), int(attacks["miss"]), float(attacks["damage"]), _last_reaction, _last_reaction_reason, _boss_state_name()]
	llm_label.text = "%s\n策略来源：%s\n\n%s\n\n只发送行为摘要。LLM 不决定命中、伤害、抽牌或胜负；网络等待期间角色仍可操作。" % [_llm_status, source, _llm_summary]
	notice_label.text = _notice
	send_button.disabled = llm_bridge.busy or not llm_bridge.is_configured()
