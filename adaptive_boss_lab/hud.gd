extends Control
## Screen-space card presentation; the deck and actor own all game rules.

signal card_requested(slot_index: int)
signal reset_requested()
signal pause_requested()
signal browser_requested(view: StringName)
signal browser_close_requested()

const VIEW_SIZE := Vector2(960.0, 540.0)
const DRAW_PILE := Rect2(18.0, 230.0, 64.0, 78.0)
const DISCARD_PILE := Rect2(878.0, 230.0, 64.0, 78.0)
const DECK_CONTROL := Rect2(12.0, 344.0, 104.0, 28.0)
const RESET_CONTROL := Rect2(758.0, 500.0, 96.0, 24.0)
const PAUSE_CONTROL := Rect2(862.0, 500.0, 80.0, 24.0)
const CYBERNETIC_PANEL := Rect2(736.0, 14.0, 206.0, 68.0)
const CYBERNETIC_BAR := Rect2(744.0, 56.0, 190.0, 3.0)
const ENERGY_BAR := Rect2(268.0, 529.0, 424.0, 6.0)
const HEALTH_BAR := Rect2(20.0, 84.0, 174.0, 5.0)
const SHIELD_BAR := Rect2(20.0, 115.0, 174.0, 5.0)
const CARD_SIZE := Vector2(100.0, 80.0)
const CARD_GAP := 8.0
const HAND_ORIGIN := Vector2(268.0, 424.0)
const SLOT_COUNT := 4

const BG := Color("071019")
const PANEL := Color("0c1b28")
const PANEL_RAISED := Color("11293a")
const GRID := Color("254254")
const MUTED := Color("8ca5b6")
const TEXT := Color("e1eef3")
const TEAL := Color("74f3d1")
const BLUE := Color("81ceff")
const ORANGE := Color("ffad68")
const PURPLE := Color("c8a5ff")
const RED := Color("ff6f7f")
const UI_FONT = preload("res://assets/fonts/NotoSansSC-Regular.ttf")
const CARD_BROWSER = preload("res://card_browser.gd")
const CATALOG = preload("res://card_catalog.gd")

var player: CharacterBody3D
var deck: Node
var current_energy := 10.0
var max_energy := 10.0
var current_health := 100.0
var max_health := 100.0
var current_shield := 0.0
var _shield_display_max := 10.0
var status_text := "选择手牌"
var status_is_error := false
var last_action := "—"
var last_action_time := -1.0
var paused := false
var card_browser: Control

var _labels: Dictionary = {}
var _pause_shade: ColorRect
var _defeat_shade: ColorRect
var _player_defeated := false
var _damage_flash := 0.0
var _last_damage := 0.0
var _hover_slot := -1
var _font: FontVariation
var _heading_font: FontVariation
var _camera_hint := "左键拖动旋转  /  双指捏合、滚轮缩放"
var _slot_flash: Array[float] = [0.0, 0.0, 0.0, 0.0]
var _draw_flash := 0.0
var _discard_flash := 0.0
var _shuffle_flash := 0.0
var _notice_time := 0.0
var _cycle_notice := ""
var _flights: Array[Dictionary] = []
var _cybernetic_time_left := 0.0
var _cybernetic_cooldown_left := 0.0
var _cybernetic_active := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_font = FontVariation.new()
	_font.base_font = UI_FONT
	_heading_font = FontVariation.new()
	_heading_font.base_font = UI_FONT
	_heading_font.variation_embolden = 0.7
	_create_interface()
	_update_dynamic_labels()
	_update_pause_label()
	queue_redraw()


func setup(actor: CharacterBody3D, card_deck: Node) -> void:
	_disconnect_signal(player, "energy_changed", _on_energy_changed)
	_disconnect_signal(player, "action_played", _on_action_played)
	_disconnect_signal(player, "status_changed", _on_status_changed)
	_disconnect_signal(player, "cybernetic_changed", _on_cybernetic_changed)
	_disconnect_signal(player, "health_changed", _on_health_changed)
	_disconnect_signal(player, "shield_changed", _on_shield_changed)
	_disconnect_signal(player, "damaged", _on_damaged)
	_disconnect_signal(player, "defeated", _on_defeated)
	_disconnect_signal(deck, "piles_changed", _on_piles_changed)
	_disconnect_signal(deck, "card_drawn", _on_card_drawn)
	_disconnect_signal(deck, "card_discarded", _on_card_discarded)
	_disconnect_signal(deck, "reshuffled", _on_reshuffled)
	_disconnect_signal(deck, "card_unlocked", _on_card_unlocked)
	player = actor
	deck = card_deck
	last_action = "—"
	last_action_time = -1.0
	status_text = "选择手牌"
	status_is_error = false
	_cybernetic_time_left = 0.0
	_cybernetic_cooldown_left = 0.0
	_cybernetic_active = false
	current_health = 100.0
	max_health = 100.0
	current_shield = 0.0
	_shield_display_max = 10.0
	_player_defeated = false
	_damage_flash = 0.0
	_last_damage = 0.0
	_flashes_reset()
	if is_instance_valid(player):
		player.connect("energy_changed", _on_energy_changed)
		player.connect("action_played", _on_action_played)
		player.connect("status_changed", _on_status_changed)
		if player.has_signal("cybernetic_changed"):
			player.connect("cybernetic_changed", _on_cybernetic_changed)
		if player.has_signal("health_changed"):
			player.connect("health_changed", _on_health_changed)
			_on_health_changed(float(player.get("health")), float(player.get("max_health")))
		if player.has_signal("shield_changed"):
			player.connect("shield_changed", _on_shield_changed)
			_on_shield_changed(float(player.get("shield")))
		if player.has_signal("damaged"):
			player.connect("damaged", _on_damaged)
		if player.has_signal("defeated"):
			player.connect("defeated", _on_defeated)
		_on_energy_changed(float(player.get("energy")), float(player.get("max_energy")))
		_sync_cybernetic_state()
	if is_instance_valid(deck):
		deck.connect("piles_changed", _on_piles_changed)
		deck.connect("card_drawn", _on_card_drawn)
		deck.connect("card_discarded", _on_card_discarded)
		deck.connect("reshuffled", _on_reshuffled)
		if deck.has_signal("card_unlocked"):
			deck.connect("card_unlocked", _on_card_unlocked)
	_update_dynamic_labels()
	if is_browser_open():
		card_browser.open_view(card_browser.current_view, deck, player)
	queue_redraw()


func _disconnect_signal(source: Node, signal_name: StringName, callback: Callable) -> void:
	if is_instance_valid(source) and source.has_signal(signal_name) and source.is_connected(signal_name, callback):
		source.disconnect(signal_name, callback)


func _flashes_reset() -> void:
	_slot_flash = [0.0, 0.0, 0.0, 0.0]
	_draw_flash = 0.0
	_discard_flash = 0.0
	_shuffle_flash = 0.0
	_notice_time = 0.0
	_cycle_notice = ""
	_flights.clear()


func set_paused(value: bool) -> void:
	paused = value
	_update_pause_label()
	_update_dynamic_labels()
	queue_redraw()


func show_browser(view: StringName) -> void:
	card_browser.open_view(view, deck, player)
	_update_pause_label()
	queue_redraw()


func hide_browser() -> void:
	card_browser.close_view()
	_update_pause_label()
	queue_redraw()


func is_browser_open() -> bool:
	return is_instance_valid(card_browser) and card_browser.visible


func set_camera_hint(value: String) -> void:
	_camera_hint = value
	if _labels.has("camera_hint"):
		_labels["camera_hint"].text = value


func set_location(title: String, subtitle: String, reset_text: String) -> void:
	if not _labels.has("title"):
		return
	_labels["title"].text = title
	_labels["subtitle"].text = subtitle
	_labels["reset"].text = reset_text
	_labels["pause_hint"].text = "按 ESC 继续  /  按 R 重新开始"


func set_defeat_text(main_text: String, hint: String) -> void:
	if not _labels.has("defeat"):
		return
	_labels["defeat"].text = main_text
	_labels["defeat_hint"].text = hint


func _process(delta: float) -> void:
	_sync_cybernetic_state()
	if not paused:
		if last_action_time >= 0.0:
			last_action_time += delta
			if last_action_time > 2.4:
				last_action = "—"
				last_action_time = -1.0
		for slot in SLOT_COUNT:
			_slot_flash[slot] = maxf(0.0, _slot_flash[slot] - delta)
		_draw_flash = maxf(0.0, _draw_flash - delta)
		_discard_flash = maxf(0.0, _discard_flash - delta)
		_shuffle_flash = maxf(0.0, _shuffle_flash - delta)
		_damage_flash = maxf(0.0, _damage_flash - delta)
		_notice_time = maxf(0.0, _notice_time - delta)
		for index in range(_flights.size() - 1, -1, -1):
			_flights[index]["age"] = float(_flights[index]["age"]) + delta
			if float(_flights[index]["age"]) >= float(_flights[index]["duration"]):
				_flights.remove_at(index)
	var mouse := get_local_mouse_position()
	_hover_slot = _slot_at(mouse)
	var card_hovered := _hover_slot >= 0 and not _card(_hover_slot).is_empty() and not paused and not _player_defeated
	var control_hovered := RESET_CONTROL.has_point(mouse) or PAUSE_CONTROL.has_point(mouse) or DECK_CONTROL.has_point(mouse)
	control_hovered = control_hovered or DRAW_PILE.grow(6.0).has_point(mouse) or DISCARD_PILE.grow(6.0).has_point(mouse)
	Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND if not is_browser_open() and (card_hovered or control_hovered) else Input.CURSOR_ARROW)
	_update_dynamic_labels()
	queue_redraw()


func _sync_cybernetic_state() -> void:
	if not is_instance_valid(player) or not player.has_signal("cybernetic_changed"):
		return
	var active_value = player.get("is_cybernetic_active")
	_cybernetic_active = bool(active_value) if active_value != null else false
	var active_time = player.get("cybernetic_time_left")
	var cooldown_time = player.get("cybernetic_cooldown_left")
	_cybernetic_time_left = maxf(0.0, float(active_time)) if active_time != null else 0.0
	_cybernetic_cooldown_left = maxf(0.0, float(cooldown_time)) if cooldown_time != null else 0.0


func _unhandled_input(event: InputEvent) -> void:
	if is_browser_open():
		return
	if not event is InputEventMouseButton:
		return
	# Releases must reach Main even if a scene drag ends over a card.
	if not event.pressed or event.button_index != MOUSE_BUTTON_LEFT:
		return
	var mouse: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
	var slot := _slot_at(mouse)
	if RESET_CONTROL.has_point(mouse):
		reset_requested.emit()
	elif PAUSE_CONTROL.has_point(mouse):
		pause_requested.emit()
	elif DECK_CONTROL.has_point(mouse):
		browser_requested.emit(&"all")
	elif slot >= 0:
		if not paused and not _player_defeated and not _card(slot).is_empty():
			card_requested.emit(slot)
	elif DRAW_PILE.grow(6.0).has_point(mouse):
		browser_requested.emit(&"draw")
	elif DISCARD_PILE.grow(6.0).has_point(mouse):
		browser_requested.emit(&"discard")
	else:
		return
	# HUD controls intercept clicks; transparent gaps remain camera space.
	get_viewport().set_input_as_handled()


func card_rect(slot: int) -> Rect2:
	return Rect2(HAND_ORIGIN + Vector2(float(slot) * (CARD_SIZE.x + CARD_GAP), 0.0), CARD_SIZE)


func _slot_at(point: Vector2) -> int:
	for slot in SLOT_COUNT:
		if card_rect(slot).has_point(point):
			return slot
	return -1


func _create_interface() -> void:
	_add_label("title", "神经断层", Vector2(18, 12), 22, TEXT)
	_add_label("subtitle", "3D 训练场", Vector2(118, 22), 10, MUTED)
	_add_label("camera_hint", _camera_hint, Vector2(20, 42), 10, TEXT)
	_add_label("health", "生命  100 / 100", Vector2(20, 63), 12, TEXT)
	_add_label("damage", "", Vector2(204, 63), 12, RED)
	_add_label("shield", "护盾  0", Vector2(20, 94), 12, BLUE)
	_add_label("shield_decay", "", Vector2(97, 98), 9, BLUE)
	_add_label("combat_tip", "抬手时翻滚", Vector2(20, 126), 10, TEXT)
	_add_label("cybernetic_key", "Q", Vector2(750, 23), 14, TEAL)
	_add_label("cybernetic_title", "爆发加速", Vector2(775, 18), 14, TEXT)
	_add_label("cybernetic_state", "可用 · 按 Q 激活", Vector2(775, 38), 10, TEAL)
	_add_label("cybernetic_hint", "", Vector2(744, 64), 9, TEXT)

	_add_label("energy_title", "中枢能量", Vector2(268, 512), 10, TEXT)
	_add_label("energy_value", "10.0 / 10.0", Vector2(323, 509), 13, TEXT)
	var regen_label := _add_label("regen", "自动恢复 +2.0 / 秒", Vector2(584, 513), 9, TEAL)
	regen_label.size.x = 108.0
	regen_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_center_label("total", "牌组 10 张", Rect2(12, 316, 76, 16), 9, TEXT)
	_center_label("hand_count", "手牌 0 / 4", Rect2(872, 316, 76, 16), 9, TEXT)
	var deck_label := _center_label("deck_control", "查看卡组", DECK_CONTROL, 12, TEXT)
	deck_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var status_label := _center_label("status", status_text, Rect2(268, 402, 424, 18), 10, TEXT)
	status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var cycle_label := _center_label("cycle", "", Rect2(280, 18, 400, 18), 10, TEXT)
	cycle_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS

	for pile_name in ["draw", "discard"]:
		var rect: Rect2 = DRAW_PILE if pile_name == "draw" else DISCARD_PILE
		var accent: Color = TEAL if pile_name == "draw" else PURPLE
		_center_label(pile_name + "_title", "抽牌堆" if pile_name == "draw" else "弃牌堆", Rect2(rect.position + Vector2(0, 6), Vector2(rect.size.x, 18)), 11, accent)
		_center_label(pile_name + "_count", "0", Rect2(rect.position + Vector2(0, 23), Vector2(rect.size.x, 30)), 23, TEXT)
		_center_label(pile_name + "_hint", "点击查看", Rect2(rect.position + Vector2(0, 60), Vector2(rect.size.x, 14)), 9, TEXT)
	for slot in SLOT_COUNT:
		var rect := card_rect(slot)
		var prefix := "slot%d_" % slot
		_add_label(prefix + "key", str(slot + 1), rect.position + Vector2(10, 3), 12, TEXT)
		var cost_label := _add_label(prefix + "cost", "", rect.position + Vector2(37, 5), 9, TEXT)
		cost_label.size.x = 55.0
		cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_center_label(prefix + "name", "等待补牌", Rect2(rect.position + Vector2(3, 43), Vector2(94, 20)), 13, TEXT)
		_center_label(prefix + "ready", "", Rect2(rect.position + Vector2(3, 64), Vector2(94, 14)), 9, TEXT)

	_add_label("footer", "WASD 移动 · 空格 跳跃 · B 总结", Vector2(20, 507), 10, TEXT)
	_add_label("reset", "R  重置训练", RESET_CONTROL.position + Vector2(6, 6), 10, TEXT)
	_add_label("pause_control", "ESC  暂停", PAUSE_CONTROL.position + Vector2(6, 6), 10, TEXT)
	_defeat_shade = ColorRect.new()
	_defeat_shade.position = Vector2(308, 204)
	_defeat_shade.size = Vector2(344, 76)
	_defeat_shade.color = Color(0.07, 0.035, 0.055, 0.94)
	_defeat_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_defeat_shade.visible = false
	add_child(_defeat_shade)
	_center_label("defeat", "训练失败 · 按 R 重试", Rect2(318, 215, 324, 28), 20, RED)
	_center_label("defeat_hint", "抬手后翻滚", Rect2(318, 251, 324, 18), 11, TEXT)
	_pause_shade = ColorRect.new()
	_pause_shade.position = Vector2(280, 188)
	_pause_shade.size = Vector2(400, 100)
	_pause_shade.color = Color(0.025, 0.06, 0.09, 0.92)
	_pause_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_shade.visible = false
	add_child(_pause_shade)
	_add_label("pause", "模拟已暂停", Vector2(417, 204), 22, TEXT)
	_add_label("pause_hint", "按 ESC 继续  /  按 R 重置训练场", Vector2(380, 248), 12, MUTED)
	# Added last so the modal is above both the pause and defeat presentation.
	card_browser = Control.new()
	card_browser.name = "CardBrowser"
	card_browser.set_script(CARD_BROWSER)
	card_browser.close_requested.connect(func() -> void: browser_close_requested.emit())
	add_child(card_browser)


func _center_label(id: String, value: String, rect: Rect2, font_size: int, color: Color) -> Label:
	var label := _add_label(id, value, rect.position, font_size, color)
	label.size = rect.size
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return label


func _add_label(id: String, value: String, label_position: Vector2, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.name = id
	label.text = value
	label.position = label_position
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_override("font", _heading_font if id == "title" else _font)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	# Outlined type stays readable on the arena without an opaque HUD backdrop.
	label.add_theme_color_override("font_outline_color", Color(0.025, 0.055, 0.07, 0.95))
	label.add_theme_constant_override("outline_size", 3)
	label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.68))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(label)
	_labels[id] = label
	return label


func _update_dynamic_labels() -> void:
	if not _labels.has("energy_value"):
		return
	_labels["energy_value"].text = "%.1f / %.1f" % [current_energy, max_energy]
	_labels["energy_value"].add_theme_color_override("font_color", RED if current_energy < 2.0 else TEXT)
	_labels["health"].text = "生命  %.0f / %.0f" % [current_health, max_health]
	_labels["health"].add_theme_color_override("font_color", RED if current_health <= max_health * 0.3 else TEXT)
	_labels["shield"].text = "护盾  %.0f" % current_shield
	_labels["shield_decay"].text = "−1 / 0.5 秒" if current_shield > 0.0 else ""
	_labels["damage"].text = "−%.0f" % _last_damage if _damage_flash > 0.0 else ""
	_labels["regen"].text = "行动已结束" if _player_defeated else "自动恢复 +%.1f / 秒" % _regen_rate()
	_labels["status"].text = status_text
	_labels["status"].add_theme_color_override("font_color", RED if status_is_error else TEXT)
	_labels["cycle"].text = _cycle_notice if _notice_time > 0.0 else ""
	_labels["cycle"].add_theme_color_override("font_color", PURPLE if _shuffle_flash > 0.0 else (TEAL if _notice_time > 0.0 else MUTED))
	_labels["draw_count"].text = str(_pile_count("draw_pile"))
	_labels["discard_count"].text = str(_pile_count("discard_pile"))
	_labels["draw_hint"].text = "点击查看"
	var occupied := 0
	for slot in SLOT_COUNT:
		if not _card(slot).is_empty():
			occupied += 1
		_update_card_labels(slot)
	var total := int(deck.get("total_cards")) if is_instance_valid(deck) else 10
	var hand_size := int(deck.get("hand_size")) if is_instance_valid(deck) else SLOT_COUNT
	_labels["total"].text = "牌组 %d 张" % total
	_labels["hand_count"].text = "手牌 %d / %d" % [occupied, hand_size]
	_labels["pause_control"].text = "ESC  继续" if paused else "ESC  暂停"
	_update_defeat_label()
	_update_cybernetic_labels()


func _update_cybernetic_labels() -> void:
	if not _labels.has("cybernetic_state"):
		return
	var state := "可用 · 按 Q 激活"
	if _cybernetic_active:
		state = "激活剩余 %.1f 秒" % _cybernetic_time_left
	elif _cybernetic_cooldown_left > 0.0:
		state = "冷却剩余 %.1f 秒" % _cybernetic_cooldown_left
	if paused:
		state = "可用 · 已暂停" if not _cybernetic_active and _cybernetic_cooldown_left <= 0.0 else state + " · 暂停"
	if _player_defeated:
		state = "行动已结束"
	var accent := _cybernetic_color()
	_labels["cybernetic_state"].text = state
	_labels["cybernetic_state"].add_theme_color_override("font_color", accent)
	_labels["cybernetic_key"].add_theme_color_override("font_color", accent)
	_labels["cybernetic_hint"].text = "普通移动 ×%.1f · 不耗能" % _cybernetic_setting("cybernetic_speed_multiplier", 1.8)


func _cybernetic_setting(property_name: String, fallback: float) -> float:
	if not is_instance_valid(player) or not player.has_signal("cybernetic_changed"):
		return fallback
	var value = player.get(property_name)
	return float(value) if value != null else fallback


func _cybernetic_color() -> Color:
	if paused or _player_defeated:
		return MUTED
	if _cybernetic_active:
		return ORANGE
	return BLUE if _cybernetic_cooldown_left > 0.0 else TEAL


func _update_card_labels(slot: int) -> void:
	var card := _card(slot)
	var prefix := "slot%d_" % slot
	if card.is_empty():
		_labels[prefix + "name"].text = "等待补牌"
		_labels[prefix + "name"].add_theme_color_override("font_color", MUTED)
		_labels[prefix + "cost"].text = ""
		_labels[prefix + "ready"].text = "行动已结束" if _player_defeated else ("已暂停" if paused else ("%.1f 秒后补入" % _refill_time(slot) if _refill_time(slot) > 0.0 else "正在抽牌…"))
		_labels[prefix + "ready"].add_theme_color_override("font_color", MUTED)
		return
	var kind := str(card.get("kind", "slash"))
	var accent := _accent(kind)
	var ready := _card_ready(kind)
	_labels[prefix + "name"].text = _card_name(kind)
	_labels[prefix + "name"].add_theme_color_override("font_color", TEXT if ready else MUTED)
	_labels[prefix + "cost"].text = "%.0f 能量" % _cost(kind)
	_labels[prefix + "cost"].add_theme_color_override("font_color", accent if current_energy >= _cost(kind) else RED)
	_labels[prefix + "ready"].text = _card_availability(kind, slot)
	_labels[prefix + "ready"].add_theme_color_override("font_color", accent if ready else MUTED)


func _card(slot: int) -> Dictionary:
	if not is_instance_valid(deck) or slot < 0 or slot >= SLOT_COUNT:
		return {}
	var hand: Array = deck.get("hand")
	return hand[slot] if slot < hand.size() else {}


func _pile_count(property_name: String) -> int:
	if not is_instance_valid(deck):
		return 0
	var pile: Array = deck.get(property_name)
	return pile.size()


func _refill_time(slot: int) -> float:
	if not is_instance_valid(deck):
		return 0.0
	var refill_times: Array = deck.get("refill_time_left")
	return maxf(0.0, float(refill_times[slot])) if slot < refill_times.size() else 0.0


func _card_name(kind: String) -> String:
	return CATALOG.card_name(kind)


func _accent(kind: String) -> Color:
	return CATALOG.accent(kind)


func _cost(kind: String) -> float:
	if is_instance_valid(player) and player.has_method("get_card_cost"):
		return float(player.call("get_card_cost", kind))
	return CATALOG.cost(kind)


func _regen_rate() -> float:
	return float(player.get("energy_regen_per_second")) if is_instance_valid(player) else 2.0


func _action_locked() -> bool:
	return bool(player.call("is_action_locked")) if is_instance_valid(player) else false


func _card_ready(kind: String) -> bool:
	var chainable := bool(player.call("can_chain_card", kind)) if is_instance_valid(player) and player.has_method("can_chain_card") else not _action_locked()
	return current_energy >= _cost(kind) and chainable and not paused and not _player_defeated


func _card_availability(kind: String, slot: int) -> String:
	if _player_defeated:
		return "行动已结束"
	if paused:
		return "已暂停"
	var chainable := bool(player.call("can_chain_card", kind)) if is_instance_valid(player) and player.has_method("can_chain_card") else not _action_locked()
	if _action_locked() and not chainable:
		return "动作执行中"
	if _action_locked() and chainable:
		return "连段 · 按 %d" % (slot + 1)
	if current_energy < _cost(kind):
		return "能量恢复 %.1fs" % ((_cost(kind) - current_energy) / _regen_rate()) if _regen_rate() > 0.0 else "能量不足"
	return "点击 / 按 %d 出牌" % (slot + 1) if _hover_slot == slot else "就绪 · 按 %d" % (slot + 1)


func _update_pause_label() -> void:
	if _labels.has("pause"):
		var show_pause := paused and not is_browser_open()
		_labels["pause"].visible = show_pause
		_labels["pause_hint"].visible = show_pause
		_pause_shade.visible = show_pause
	_update_defeat_label()


func _update_defeat_label() -> void:
	if _labels.has("defeat"):
		var show_defeat := _player_defeated and not paused and not is_browser_open()
		_labels["defeat"].visible = show_defeat
		_labels["defeat_hint"].visible = show_defeat
		_defeat_shade.visible = show_defeat


func _on_health_changed(current: float, maximum: float) -> void:
	var was_defeated := _player_defeated
	max_health = maxf(0.0, maximum)
	current_health = clampf(current, 0.0, max_health)
	_player_defeated = current_health <= 0.0
	if was_defeated and not _player_defeated:
		_damage_flash = 0.0
		_last_damage = 0.0
	_update_dynamic_labels()
	queue_redraw()


func _on_shield_changed(current: float) -> void:
	current_shield = maxf(0.0, current)
	# Keep a stable bar while it drains; another card can grow its capacity.
	# The number is the shield pool, not a cap on stackable protection.
	_shield_display_max = maxf(_shield_display_max, ceilf(current_shield / 10.0) * 10.0) if current_shield > 0.0 else 10.0
	_update_dynamic_labels()
	queue_redraw()


func _on_damaged(amount: float) -> void:
	_last_damage = maxf(0.0, amount)
	_damage_flash = 0.45
	_update_dynamic_labels()
	queue_redraw()


func _on_defeated() -> void:
	_player_defeated = true
	_update_dynamic_labels()
	queue_redraw()


func _on_energy_changed(current: float, maximum: float) -> void:
	current_energy = current
	max_energy = maximum
	queue_redraw()


func _on_cybernetic_changed(active_time_left: float, cooldown_left: float) -> void:
	_cybernetic_time_left = maxf(0.0, active_time_left)
	_cybernetic_cooldown_left = maxf(0.0, cooldown_left)
	_cybernetic_active = _cybernetic_time_left > 0.0
	_update_cybernetic_labels()
	queue_redraw()


func _on_action_played(action_name: String, _cost_value: float) -> void:
	last_action = _card_name(action_name)
	last_action_time = 0.0
	queue_redraw()


func _on_status_changed(message: String, is_error: bool) -> void:
	status_text = message
	status_is_error = is_error
	if message.begins_with("准备就绪"):
		last_action = "—"
		last_action_time = -1.0
	queue_redraw()


func _on_piles_changed() -> void:
	if is_browser_open():
		card_browser.refresh()
	_update_dynamic_labels()
	queue_redraw()


func _on_card_unlocked(kind: String) -> void:
	_cycle_notice = "记忆恢复：%s → 抽牌堆" % _card_name(kind)
	_notice_time = 3.5
	_draw_flash = 1.2
	queue_redraw()


func _on_card_drawn(card: Dictionary, slot: int) -> void:
	if slot < 0 or slot >= SLOT_COUNT:
		return
	var kind := str(card.get("kind", "slash"))
	_slot_flash[slot] = 0.6
	_draw_flash = 0.5
	_add_flight(DRAW_PILE.get_center(), card_rect(slot).get_center(), kind, 0.38)
	if _shuffle_flash <= 0.0:
		_cycle_notice = "补牌：%s %d" % [_card_name(kind), slot + 1]
		_notice_time = 1.5
	_on_piles_changed()


func _on_card_discarded(card: Dictionary, slot: int) -> void:
	if slot < 0 or slot >= SLOT_COUNT:
		return
	var kind := str(card.get("kind", "slash"))
	_discard_flash = 0.55
	_add_flight(card_rect(slot).get_center(), DISCARD_PILE.get_center(), kind, 0.32)
	_cycle_notice = "%s → 弃牌" % _card_name(kind)
	_notice_time = 1.0
	_on_piles_changed()


func _on_reshuffled(count: int) -> void:
	_shuffle_flash = 1.6
	_draw_flash = 1.0
	_discard_flash = 1.0
	_cycle_notice = "洗牌：%d 张" % count
	_notice_time = 2.4
	_add_flight(DISCARD_PILE.get_center(), DRAW_PILE.get_center(), "shuffle", 0.58)
	_on_piles_changed()


func _add_flight(from: Vector2, to: Vector2, kind: String, duration: float) -> void:
	_flights.append({"from": from, "to": to, "kind": kind, "age": 0.0, "duration": duration})
	if _flights.size() > 12:
		_flights.pop_front()


func _draw() -> void:
	# No full-width header or hand backdrop: the arena remains visible through UI.
	_draw_cybernetic_panel()
	_draw_health_bar()
	_draw_shield_bar()
	_draw_energy_bar()
	_draw_pile(DRAW_PILE, TEAL, _pile_count("draw_pile"), _draw_flash)
	_draw_pile(DISCARD_PILE, PURPLE, _pile_count("discard_pile"), _discard_flash)
	for slot in SLOT_COUNT:
		_draw_card(slot)
	_draw_flights()
	var mouse := get_local_mouse_position()
	for rect: Rect2 in [RESET_CONTROL, PAUSE_CONTROL, DECK_CONTROL]:
		draw_rect(rect, PANEL)
		draw_rect(rect, Color(TEAL, 0.42), false, 1.0)
		if rect.has_point(mouse):
			draw_rect(rect, Color(TEAL, 0.18))
	_draw_damage_edges()


func _draw_health_bar() -> void:
	draw_rect(HEALTH_BAR, Color(BG, 0.9))
	var fill_ratio := clampf(current_health / max_health if max_health > 0.0 else 0.0, 0.0, 1.0)
	if fill_ratio > 0.0:
		draw_rect(Rect2(HEALTH_BAR.position, Vector2(HEALTH_BAR.size.x * fill_ratio, HEALTH_BAR.size.y)), RED)
	draw_rect(HEALTH_BAR, Color(RED, 0.5), false, 1.0)


func _draw_shield_bar() -> void:
	draw_rect(SHIELD_BAR, Color(BG, 0.9))
	var fill_ratio := clampf(current_shield / _shield_display_max, 0.0, 1.0)
	if fill_ratio > 0.0:
		draw_rect(Rect2(SHIELD_BAR.position, Vector2(SHIELD_BAR.size.x * fill_ratio, SHIELD_BAR.size.y)), BLUE)
	draw_rect(SHIELD_BAR, Color(BLUE, 0.5), false, 1.0)


func _draw_damage_edges() -> void:
	if _damage_flash <= 0.0:
		return
	var intensity := clampf(_damage_flash / 0.45, 0.0, 1.0)
	# Thin edge bands communicate damage while leaving the arena unobscured.
	for inset in range(0, 16, 2):
		var edge := Rect2(Vector2(inset, inset), VIEW_SIZE - Vector2(inset * 2, inset * 2))
		draw_rect(edge, Color(RED, intensity * 0.65 * (1.0 - float(inset) / 16.0)), false, 2.0)


func _draw_cybernetic_panel() -> void:
	var accent := _cybernetic_color()
	draw_rect(CYBERNETIC_PANEL, Color(BG, 0.9))
	draw_rect(CYBERNETIC_PANEL, Color(accent, 0.35), false, 1.0)
	draw_rect(Rect2(CYBERNETIC_PANEL.position, Vector2(2, CYBERNETIC_PANEL.size.y)), Color(accent, 0.8))
	var key_rect := Rect2(744, 22, 24, 26)
	draw_rect(key_rect, Color(accent, 0.08))
	draw_rect(key_rect, Color(accent, 0.55), false, 1.0)
	draw_rect(CYBERNETIC_BAR, Color(GRID, 0.8))
	var fill_ratio := 1.0
	if _cybernetic_active:
		fill_ratio = _cybernetic_time_left / maxf(0.001, _cybernetic_setting("cybernetic_duration", 3.0))
	elif _cybernetic_cooldown_left > 0.0:
		fill_ratio = 1.0 - _cybernetic_cooldown_left / maxf(0.001, _cybernetic_setting("cybernetic_cooldown", 8.0))
	fill_ratio = clampf(fill_ratio, 0.0, 1.0)
	if fill_ratio > 0.0:
		draw_rect(Rect2(CYBERNETIC_BAR.position, Vector2(CYBERNETIC_BAR.size.x * fill_ratio, CYBERNETIC_BAR.size.y)), accent)


func _draw_energy_bar() -> void:
	var bar_rect := ENERGY_BAR
	draw_rect(bar_rect, Color("142c3b"))
	var fill_ratio := clampf(current_energy / max_energy if max_energy > 0.0 else 0.0, 0.0, 1.0)
	if fill_ratio > 0.0:
		draw_rect(Rect2(bar_rect.position, Vector2(bar_rect.size.x * fill_ratio, bar_rect.size.y)), TEAL if current_energy >= 2.0 else RED)
	for index in range(1, 10):
		var x := bar_rect.position.x + bar_rect.size.x * float(index) / 10.0
		draw_line(Vector2(x, bar_rect.position.y), Vector2(x, bar_rect.end.y), Color(BG, 0.55), 1.0)
	draw_rect(bar_rect, Color(TEAL, 0.55), false, 1.0)


func _draw_pile(rect: Rect2, accent: Color, count: int, flash: float) -> void:
	if count > 0:
		for offset in [Vector2(6, -6), Vector2(3, -3)]:
			draw_rect(Rect2(rect.position + offset, rect.size), PANEL)
			draw_rect(Rect2(rect.position + offset, rect.size), Color(accent, 0.26), false, 1.0)
	draw_rect(rect, PANEL)
	if flash > 0.0:
		draw_rect(rect, Color(accent, minf(0.18, flash * 0.18)))
	draw_rect(rect, Color(accent, 0.5 if count > 0 else 0.22), false, 1.0)
	draw_line(rect.position + Vector2(12, 55), rect.position + Vector2(rect.size.x - 12, 55), Color(accent, 0.3), 1.0)
	if _shuffle_flash > 0.0:
		draw_rect(rect.grow(3.0), Color(PURPLE, 0.5 * minf(1.0, _shuffle_flash)), false, 1.5)


func _draw_card(slot: int) -> void:
	var rect := card_rect(slot)
	var card := _card(slot)
	if card.is_empty():
		draw_rect(rect, PANEL)
		draw_rect(rect, Color(GRID, 0.72), false, 1.0)
		var center := rect.position + Vector2(CARD_SIZE.x / 2.0, 32)
		draw_arc(center, 9, 0, TAU, 32, Color(GRID, 0.7), 1.5, true)
		var progress := 1.0 - clampf(_refill_time(slot), 0.0, 1.0)
		if progress > 0.0:
			draw_arc(center, 9, -PI / 2.0, -PI / 2.0 + TAU * progress, 32, TEAL, 1.5, true)
		_draw_keycap(rect, MUTED)
		return
	var kind := str(card.get("kind", "slash"))
	var accent := _accent(kind)
	var ready := _card_ready(kind)
	var hovered := _hover_slot == slot and not paused and not _player_defeated
	var fill := PANEL_RAISED if ready else PANEL
	if hovered:
		fill = fill.lightened(0.055)
	draw_rect(Rect2(rect.position + Vector2(0, 2), rect.size), Color(0.0, 0.0, 0.0, 0.32))
	draw_rect(rect, fill)
	draw_rect(rect, Color(accent, 1.0 if hovered else (0.68 if ready else 0.3)), false, 1.6 if hovered else 1.0)
	if _slot_flash[slot] > 0.0:
		draw_rect(rect.grow(2.0), Color(accent, _slot_flash[slot]), false, 1.0)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, 2)), Color(accent, 0.86 if ready else 0.36))
	draw_line(rect.position + Vector2(8, 63), rect.position + Vector2(rect.size.x - 8, 63), Color(accent, 0.25), 1.0)
	_draw_keycap(rect, accent if ready else MUTED)
	draw_set_transform(rect.position + Vector2(CARD_SIZE.x / 2.0, 31), 0.0, Vector2(0.65, 0.65))
	_draw_card_icon(Vector2.ZERO, kind, Color(accent, 1.0 if ready else 0.42))
	draw_set_transform(Vector2.ZERO)


func _draw_keycap(rect: Rect2, accent: Color) -> void:
	var key_rect := Rect2(rect.position + Vector2(5, 3), Vector2(18, 18))
	draw_rect(key_rect, Color(accent, 0.35), false, 1.0)


func _draw_card_icon(center: Vector2, kind: String, accent: Color) -> void:
	if kind == "shield":
		var points := PackedVector2Array([center + Vector2(0, -15), center + Vector2(13, -9), center + Vector2(10, 7), center + Vector2(0, 15), center + Vector2(-10, 7), center + Vector2(-13, -9), center + Vector2(0, -15)])
		draw_polyline(points, accent, 2.0, true)
		draw_line(center + Vector2(0, -7), center + Vector2(0, 7), accent, 2.0)
		draw_line(center + Vector2(-6, 0), center + Vector2(6, 0), accent, 2.0)
		return
	if kind == "front_kick":
		draw_arc(center, 18, -0.5, TAU - 1.0, 32, accent, 2.0, true)
		draw_line(center + Vector2(-8, -10), center + Vector2(-1, 2), accent, 3.0)
		draw_line(center + Vector2(-1, 2), center + Vector2(12, -3), accent, 3.0)
		draw_line(center + Vector2(12, -3), center + Vector2(15, 0), accent, 3.0)
		return
	if kind == "punch" or kind == "slash":
		draw_rect(Rect2(center + Vector2(-10, -8), Vector2(19, 16)), accent, false, 2.0)
		for index in range(3):
			var x := center.x - 5.0 + index * 5.0
			draw_line(Vector2(x, center.y - 8), Vector2(x, center.y - 2), accent, 1.5)
		draw_line(center + Vector2(9, -2), center + Vector2(14, 2), accent, 3.0)
		draw_line(center + Vector2(14, 2), center + Vector2(7, 10), accent, 3.0)
		return
	if kind == "sweep":
		draw_arc(center + Vector2(0, 5), 18, -0.25, PI + 0.25, 24, accent, 3.0, true)
		draw_line(center + Vector2(-13, 5), center + Vector2(-5, -8), accent, 2.0, true)
		draw_line(center + Vector2(13, 5), center + Vector2(5, -8), accent, 2.0, true)
		return
	if kind == "shot":
		draw_rect(Rect2(center + Vector2(-16, -4), Vector2(19, 8)), accent, false, 2.0)
		draw_line(center + Vector2(-12, 4), center + Vector2(-15, 12), accent, 4.0)
		for index in range(2):
			draw_line(center + Vector2(9 + index * 8, 0), center + Vector2(14 + index * 8, 0), accent, 2.0)
		return
	if kind == "blink":
		for x in [-15.0, 13.0]:
			draw_arc(center + Vector2(x, 0), 8, -PI / 2, PI / 2, 16, accent, 2.0, true)
		draw_line(center + Vector2(-9, 0), center + Vector2(11, 0), accent, 2.0)
		draw_line(center + Vector2(11, 0), center + Vector2(5, -5), accent, 2.0)
		draw_line(center + Vector2(11, 0), center + Vector2(5, 5), accent, 2.0)
		return
	if kind == "jet_jump":
		draw_colored_polygon(PackedVector2Array([center + Vector2(0, -14), center + Vector2(9, 2), center + Vector2(-9, 2)]), accent)
		for x in [-6.0, 0.0, 6.0]:
			draw_line(center + Vector2(x, 7), center + Vector2(x, 15 if x == 0.0 else 12), accent, 2.0)
		return
	if kind == "airborne_slash" or kind == "dive_slash":
		var direction := -1.0 if kind == "airborne_slash" else 1.0
		draw_line(center + Vector2(-7, -12 * direction), center + Vector2(8, 10 * direction), accent, 3.0)
		draw_line(center + Vector2(8, 10 * direction), center + Vector2(-1, 7 * direction), accent, 2.0)
		draw_line(center + Vector2(8, 10 * direction), center + Vector2(8, direction), accent, 2.0)
		draw_arc(center, 16, -2.7, -0.2, 20, Color(accent, 0.5), 1.5, true)
		if kind == "dive_slash":
			draw_line(center + Vector2(-14, 15), center + Vector2(16, 15), accent, 2.0)
		return
	if kind == "roll":
		draw_arc(center, 12, -2.5, 2.1, 28, accent, 2.0, true)
		var tip := center + Vector2.from_angle(2.1) * 12.0
		draw_line(tip, tip + Vector2(1, -6), accent, 2.0, true)
		draw_line(tip, tip + Vector2(6, 1), accent, 2.0, true)
		draw_circle(center, 3.0, Color(accent, 0.6))
	else:
		var blade := PackedVector2Array([center + Vector2(-6, 6), center + Vector2(7, -10), center + Vector2(12, -13), center + Vector2(11, -7), center + Vector2(-2, 9)])
		draw_colored_polygon(blade, accent)
		draw_line(center + Vector2(-9, 4), center + Vector2(0, 11), accent, 2.0, true)
		draw_line(center + Vector2(-5, 9), center + Vector2(-10, 14), accent, 3.0, true)
		if kind == "charged_slash":
			draw_arc(center, 20, -2.6, -0.3, 20, accent, 3.0, true)
			draw_arc(center, 25, -2.3, -0.6, 20, Color(accent, 0.5), 2.0, true)
		elif kind == "dash_slash":
			for index in 3:
				var y := center.y - 8.0 + float(index) * 6.0
				draw_line(Vector2(center.x - 23.0, y), Vector2(center.x - 9.0 + float(index) * 2.0, y), Color(accent, 0.72), 1.5, true)
		else:
			draw_arc(center + Vector2(1, -1), 19, -1.45, 0.4, 20, Color(accent, 0.42), 1.2, true)


func _draw_flights() -> void:
	for flight in _flights:
		var progress := clampf(float(flight["age"]) / float(flight["duration"]), 0.0, 1.0)
		var start: Vector2 = flight["from"]
		var finish: Vector2 = flight["to"]
		var point := start.lerp(finish, smoothstep(0.0, 1.0, progress))
		var kind := str(flight["kind"])
		point.y -= sin(progress * PI) * (74.0 if kind == "shuffle" else 38.0)
		var accent := PURPLE if kind == "shuffle" else _accent(kind)
		var rect := Rect2(point - Vector2(11, 15), Vector2(22, 30))
		draw_rect(rect, accent, false, 1.5)
		draw_line(point + Vector2(-5, -4), point + Vector2(5, -4), accent, 1.2)
		draw_line(point + Vector2(-5, 2), point + Vector2(3, 2), Color(accent, 0.5), 1.2)
