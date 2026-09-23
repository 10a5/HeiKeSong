extends Control
## Modal choice view for rewards found on defeated street guards and in factories.
## The floor controller owns the run rules; this panel only emits a choice.

signal card_selected(index: int)
signal implant_selected()
signal skipped()

const UI_FONT = preload("res://assets/fonts/NotoSansSC-Regular.ttf")
const CATALOG = preload("res://card_catalog.gd")
const IMPLANTS = preload("res://implant_catalog.gd")

const TEXT := Color("e1eef3")
const MUTED := Color("8ca5b6")
const TEAL := Color("74f3d1")
const GOLD := Color("f2cf83")
const PURPLE := Color("c8a5ff")
const PANEL := Color("091a26")
const LINE := Color("2b5362")

var _source := ""
var _reward: Dictionary = {}
var _frame: Panel
var _title: Label
var _subtitle: Label
var _choice_root: Control
var _skip: Button
var _equipped_count := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	z_index = 80
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_create_interface()
	visible = false


func open_reward(source: String, reward: Dictionary, equipped_count: int = 0) -> void:
	_source = source
	_reward = reward.duplicate(true)
	_equipped_count = equipped_count
	visible = true
	_title.text = "战利品回收" if source == "enemy" else "工厂补给"
	_subtitle.text = "两张卡牌中选择一张加入抽牌堆，或不携带" if str(reward.get("type", "")) == "card" else ("义体槽位已满 · 领取后放入背包，可在义体配置中更换" if equipped_count >= 5 else "发现一件义体配件 · 领取后自动装备（%d / 5）" % equipped_count)
	_build_choices()
	queue_redraw()


func close_reward() -> void:
	visible = false
	get_viewport().gui_release_focus()
	_reward.clear()
	_source = ""
	for child in _choice_root.get_children():
		_choice_root.remove_child(child)
		child.queue_free()


func set_interactive(enabled: bool) -> void:
	for button: Button in find_children("*", "Button", true, false):
		button.disabled = not enabled


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouse or event is InputEventGesture or event is InputEventScreenTouch or event is InputEventScreenDrag:
		accept_event()


func _create_interface() -> void:
	_frame = Panel.new()
	_frame.name = "RewardFrame"
	_frame.position = Vector2(106, 86)
	_frame.size = Vector2(748, 368)
	_frame.mouse_filter = Control.MOUSE_FILTER_PASS
	_frame.add_theme_stylebox_override("panel", _style(PANEL, LINE, 12))
	add_child(_frame)
	_rect(_frame, Rect2(22, 0, 160, 2), TEAL)
	_title = _label(_frame, "战利品回收", Rect2(24, 18, 430, 32), 24, TEXT)
	_subtitle = _label(_frame, "选择一项带走，或暂时放弃", Rect2(25, 55, 698, 20), 12, MUTED)
	_choice_root = Control.new()
	_choice_root.name = "Choices"
	_choice_root.position = Vector2(24, 93)
	_choice_root.size = Vector2(700, 184)
	_choice_root.mouse_filter = Control.MOUSE_FILTER_PASS
	_frame.add_child(_choice_root)
	_skip = _button(_frame, "暂不携带", Rect2(284, 301, 180, 34), MUTED)
	_skip.name = "SkipButton"
	_skip.pressed.connect(func() -> void: skipped.emit())
	_label(_frame, "Esc 放弃奖励 · 选择后继续探索", Rect2(24, 344, 700, 16), 10, MUTED)


func _build_choices() -> void:
	for child in _choice_root.get_children():
		_choice_root.remove_child(child)
		child.queue_free()
	var kind := str(_reward.get("type", ""))
	if kind == "card":
		var options: Array = _reward.get("options", [])
		for index in range(mini(options.size(), 2)):
			_create_card_choice(index, str(options[index]))
		_skip.visible = true
	else:
		_create_implant_choice(str(_reward.get("kind", "")))
		_skip.visible = true


func _create_card_choice(index: int, kind: String) -> void:
	var card := CATALOG.get_card(kind)
	if card.is_empty():
		return
	var accent: Color = card.get("color", TEAL)
	var holder := Panel.new()
	holder.name = "CardChoice%d" % index
	holder.position = Vector2(index * 360, 0)
	holder.size = Vector2(340, 184)
	holder.add_theme_stylebox_override("panel", _style(Color("102536"), accent.darkened(0.52), 8))
	_choice_root.add_child(holder)
	_rect(holder, Rect2(16, 14, 4, 24), accent)
	_label(holder, "动作记忆", Rect2(31, 12, 140, 18), 10, accent)
	var cost := _label(holder, "%s · %s 能量" % [CATALOG.category_name(kind), str(card.get("cost", 0))], Rect2(161, 12, 163, 18), 10, accent)
	cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label(holder, str(card.get("name", kind)), Rect2(16, 43, 278, 28), 20, TEXT)
	var effect := _label(holder, str(card.get("effect", "")), Rect2(16, 77, 308, 56), 12, MUTED)
	effect.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var choose := _button(holder, "携带这张卡", Rect2(16, 143, 308, 30), accent)
	choose.name = "ChooseButton"
	choose.add_theme_font_size_override("font_size", 11)
	choose.pressed.connect(func() -> void: card_selected.emit(index))


func _create_implant_choice(kind: String) -> void:
	var item := IMPLANTS.get_item(kind)
	if item.is_empty():
		return
	var accent: Color = item.get("color", PURPLE)
	var holder := Panel.new()
	holder.name = "ImplantChoice"
	holder.position = Vector2(175, 0)
	holder.size = Vector2(350, 184)
	holder.add_theme_stylebox_override("panel", _style(Color("142533"), accent.darkened(0.52), 8))
	_choice_root.add_child(holder)
	_rect(holder, Rect2(18, 14, 4, 24), accent)
	_label(holder, "义体配件", Rect2(34, 12, 150, 18), 10, accent)
	_label(holder, str(item.get("name", kind)), Rect2(18, 43, 314, 28), 20, TEXT)
	var effect := _label(holder, str(item.get("effect", "")), Rect2(18, 77, 314, 56), 12, MUTED)
	effect.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var choose := _button(holder, "携带至背包" if _equipped_count >= 5 else "携带并装备", Rect2(18, 143, 314, 30), accent)
	choose.name = "ChooseButton"
	choose.add_theme_font_size_override("font_size", 11)
	choose.pressed.connect(func() -> void: implant_selected.emit())


func _draw() -> void:
	if not visible:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.012, 0.035, 0.05, 0.78))
	for x in range(0, 961, 32):
		draw_line(Vector2(x, 0), Vector2(x, 540), Color(0.13, 0.32, 0.38, 0.05))
	for y in range(0, 541, 32):
		draw_line(Vector2(0, y), Vector2(960, y), Color(0.13, 0.32, 0.38, 0.05))


func _style(background: Color, border: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	return style


func _label(parent: Node, text_value: String, rect: Rect2, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.position = rect.position
	label.size = rect.size
	label.add_theme_font_override("font", UI_FONT)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label


func _rect(parent: Node, rect: Rect2, color: Color) -> ColorRect:
	var node := ColorRect.new()
	node.position = rect.position
	node.size = rect.size
	node.color = color
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(node)
	return node


func _button(parent: Node, text_value: String, rect: Rect2, accent: Color) -> Button:
	var button := Button.new()
	button.text = text_value
	button.position = rect.position
	button.size = rect.size
	button.mouse_filter = Control.MOUSE_FILTER_STOP
	button.focus_mode = Control.FOCUS_ALL
	button.add_theme_font_override("font", UI_FONT)
	button.add_theme_font_size_override("font_size", 12)
	button.add_theme_color_override("font_color", TEXT)
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.add_theme_color_override("font_pressed_color", Color.WHITE)
	button.add_theme_stylebox_override("normal", _style(Color("163445"), accent.darkened(0.45), 4))
	button.add_theme_stylebox_override("hover", _style(Color("275264"), accent, 4))
	button.add_theme_stylebox_override("pressed", _style(Color("102633"), accent, 4))
	parent.add_child(button)
	return button
