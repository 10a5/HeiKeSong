extends "res://main.gd"
## A short, deterministic onboarding range. Each step teaches one verb and
## unlocks the next space only after the player performs it once.

const STEP_COUNT := 5
## The lesson controls the hand by hand, so automatic refill is parked far out
## of reach for the duration of the tutorial.
const FROZEN_REFILL_DELAY := 9999.0
const ROLL_LESSON_HAND: Array[String] = ["roll"]
const ATTACK_LESSON_HAND: Array[String] = ["slash", "slash", "slash", "roll"]
var step := 0
var tutorial_canvas: CanvasLayer
var instruction: Label
var progress_label: Label
var continue_button: Button
var spawn_position := Vector3(0, 0, 6)
var beacon_position := Vector3(0, 0, 1)
var jump_position := Vector3(0, 0, -3)
var enemy_position := Vector3(0, 0, -6)
var _jump_seen := false
var _card_seen := false
var _roll_seen := false
var _finished := false
var _combat_intro_left := 0.0

func _ready() -> void:
	super._ready()
	player.spawn_position = spawn_position
	player.reset_player()
	for terminal in unlock_terminals:
		if is_instance_valid(terminal): terminal.queue_free()
	unlock_terminals.clear()
	if is_instance_valid(enemy):
		enemy.spawn_position = enemy_position
		enemy.max_health = 45.0
		enemy.attack_damage = 6.0
		enemy.visible = false
		enemy.process_mode = Node.PROCESS_MODE_DISABLED
	_create_tutorial_geometry()
	_create_tutorial_hud()
	if is_instance_valid(deck):
		deck.refill_delay = FROZEN_REFILL_DELAY
	player.action_played.connect(_on_action_played)
	player.status_changed.connect(_on_player_status)
	_show_step(0)

func _create_tutorial_geometry() -> void:
	var room := Node3D.new()
	room.name = "TutorialRoute"
	add_child(room)
	_box(room, "MovePad", Vector3(3.6, 0.04, 5.0), Vector3(0, 0.04, 3.5), "teal")
	_box(room, "JumpBarrier", Vector3(3.2, 0.72, 0.65), Vector3(0, 0.36, -1.8), "orange", true)
	_box(room, "CombatPad", Vector3(5.0, 0.04, 5.0), Vector3(0, 0.04, -5.4), "marking")
	_ring(room, beacon_position + Vector3.UP * 0.03, 1.15, "teal")
	_ring(room, jump_position + Vector3.UP * 0.03, 1.15, "orange")
	_ring(room, enemy_position + Vector3.UP * 0.03, 1.45, "orange")
	_add_sign(room, "移动训练\nWASD / 方向键", beacon_position + Vector3(0, 1.9, 0), Color("9ff7ed"))
	_add_sign(room, "跳过低墙\n空格", jump_position + Vector3(0, 1.7, 0), Color("ffd19b"))
	_add_sign(room, "读抬手 → 翻滚 → 反击", enemy_position + Vector3(0, 2.5, 0), Color("ffb3a7"))

func _add_sign(parent: Node3D, text_value: String, at: Vector3, color: Color) -> void:
	var sign := Label3D.new()
	sign.text = text_value
	sign.font_size = 34
	sign.pixel_size = 0.005
	sign.modulate = color
	sign.outline_size = 8
	sign.outline_modulate = Color("14212b")
	sign.position = at
	parent.add_child(sign)

func _create_tutorial_hud() -> void:
	tutorial_canvas = CanvasLayer.new()
	tutorial_canvas.name = "TutorialHUD"
	add_child(tutorial_canvas)
	var panel := ColorRect.new()
	panel.position = Vector2(24, 22)
	panel.size = Vector2(450, 116)
	panel.color = Color(0.035, 0.08, 0.11, 0.92)
	tutorial_canvas.add_child(panel)
	progress_label = Label.new()
	progress_label.position = Vector2(18, 12)
	progress_label.add_theme_color_override("font_color", Color("78ded0"))
	progress_label.add_theme_font_size_override("font_size", 16)
	panel.add_child(progress_label)
	instruction = Label.new()
	instruction.position = Vector2(18, 42)
	instruction.size = Vector2(400, 62)
	instruction.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	instruction.add_theme_color_override("font_color", Color("edf8f6"))
	instruction.add_theme_font_size_override("font_size", 15)
	panel.add_child(instruction)
	continue_button = Button.new()
	continue_button.text = "跳过教学，进入第一层"
	continue_button.position = Vector2(690, 28)
	continue_button.size = Vector2(246, 38)
	continue_button.tooltip_text = "熟悉操作后可直接探索水岸街区"
	continue_button.pressed.connect(_skip_to_first_floor)
	tutorial_canvas.add_child(continue_button)

func _show_step(next_step: int) -> void:
	step = next_step
	progress_label.text = "神经断层 · 新手校准   %s" % ("完成" if step >= STEP_COUNT else "%d / %d" % [step + 1, STEP_COUNT])
	match step:
		0:
			instruction.text = "先熟悉移动：走到青色圆环。\nWASD / 方向键移动，鼠标拖动旋转视角。"
		1:
			instruction.text = "很好。越过低墙练习跳跃。\n走到橙色圆环，按空格起跳。"
		2:
			instruction.text = "动作由手牌驱动。\n按 1–4 或点击任意一张手牌，观察能量消耗。"
		3:
			instruction.text = "最后是战斗节奏。敌人将在 3 秒后开始攻击。\n靠近敌人，等它抬手出现红色预警，在落刀前打出【翻滚】躲开。"
			_lock_hand(ROLL_LESSON_HAND)
			_combat_intro_left = 3.0
			_show_combat_enemy()
		4:
			instruction.text = "闪避成功。趁敌人收招反击。\n手牌已换成攻击动作，打出【出拳】击败它。"
			_lock_hand(ATTACK_LESSON_HAND)
		5:
			instruction.text = "校准完成。你已经掌握移动、跳跃、出牌和闪避。\n点击右上角进入第一层。"
			continue_button.text = "进入第一层 →"
			_finished = true
			_restore_deck_rules()

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if _finished or player.is_dead: return
	# The buffer belongs to the enemy, not to a step: even a very fast roll must
	# not leave the tutorial foe permanently passive.
	if _combat_intro_left > 0.0:
		_combat_intro_left = maxf(0.0, _combat_intro_left - delta)
		if _combat_intro_left <= 0.0 and is_instance_valid(enemy):
			enemy.combat_enabled = true
	var flat_position := Vector2(player.global_position.x, player.global_position.z)
	match step:
		0:
			if flat_position.distance_to(Vector2(beacon_position.x, beacon_position.z)) < 1.8: _show_step(1)
		1:
			if player.global_position.y > 0.55 or (flat_position.distance_to(Vector2(jump_position.x, jump_position.z)) < 1.5 and player.global_position.y > 0.25): _jump_seen = true
			if _jump_seen and flat_position.y < -3.2: _show_step(2)
		2:
			if _card_seen: _show_step(3)
		3:
			if _roll_seen: _show_step(4)
		4:
			if is_instance_valid(enemy) and enemy.is_dead: _show_step(5)

func _on_action_played(action_name: String, _cost: float) -> void:
	if step == 2: _card_seen = true
	if step == 3 and action_name == "roll": _roll_seen = true

func _on_player_status(message: String, _is_error: bool) -> void:
	if step == 3 and message.contains("翻滚"): _roll_seen = true

func _show_combat_enemy() -> void:
	if not is_instance_valid(enemy): return
	enemy.visible = true
	enemy.process_mode = Node.PROCESS_MODE_INHERIT
	enemy.combat_enabled = false
	enemy.reset_enemy()

## Replace the hand with an exact lesson hand. Every physical card is kept and
## accounted for: the requested kinds move into the slots, the rest return to
## the draw pile. Empty slots never refill because refill is parked by
## FROZEN_REFILL_DELAY, so the player can only practise the taught verb.
func _lock_hand(kinds: Array[String]) -> void:
	if not is_instance_valid(deck): return
	var pool: Array = []
	for slot in range(deck.hand.size()):
		if not deck.hand[slot].is_empty():
			pool.append(deck.hand[slot])
			deck.hand[slot] = {}
	pool.append_array(deck.draw_pile)
	pool.append_array(deck.discard_pile)
	deck.draw_pile.clear()
	deck.discard_pile.clear()
	var selected: Array = []
	for kind in kinds:
		var taken := false
		for index in range(pool.size()):
			if str(pool[index].get("kind", "")) == kind:
				selected.append(pool[index])
				pool.remove_at(index)
				taken = true
				break
		if not taken:
			selected.append({"id": deck._next_card_id, "kind": kind})
			deck._next_card_id += 1
	for slot in range(deck.hand.size()):
		deck.hand[slot] = selected[slot] if slot < selected.size() else {}
		deck.refill_time_left[slot] = FROZEN_REFILL_DELAY
	if selected.size() > deck.hand.size():
		pool.append_array(selected.slice(deck.hand.size()))
	deck.draw_pile.append_array(pool)
	deck.total_cards = deck.hand.size() + deck.draw_pile.size() + deck.discard_pile.size()
	# A lesson hand must be usable the moment it appears.
	player.energy = player.max_energy
	player.energy_changed.emit(player.energy, player.max_energy)
	deck.piles_changed.emit()

func _restore_deck_rules() -> void:
	if not is_instance_valid(deck): return
	deck.refill_delay = 1.0
	for slot in range(deck.refill_time_left.size()):
		deck.refill_time_left[slot] = 0.0

func _skip_to_first_floor() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://floor_one.tscn")

func _on_enemy_defeated() -> void:
	if not _finished and step == 4: _show_step(5)

func restart() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()
