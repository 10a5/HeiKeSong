extends Control
## Read-only snapshots of the physical cards. Main owns pausing and shortcuts.

signal close_requested()

const UI_FONT = preload("res://assets/fonts/NotoSansSC-Regular.ttf")
const CATALOG = preload("res://card_catalog.gd")
const PANEL := Color("0c1b28")
const CARD := Color("11293a")
const LINE := Color("254254")
const TEXT := Color("e1eef3")
const MUTED := Color("8ca5b6")
const TEAL := Color("74f3d1")
const BLUE := Color("81ceff")
const ORANGE := Color("ffad68")
const PURPLE := Color("c8a5ff")

var current_view: StringName = &"all"
var discovery_hint: String = ""
var displayed_cards: Array[Dictionary] = []
var _deck: Node
var _player: CharacterBody3D
var _panel: Panel
var _title: Label
var _count: Label
var _summary: Label
var _empty: Label
var _scroll: ScrollContainer
var _grid: GridContainer
var _tabs: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_create_interface()
	visible = false


func open_view(view: StringName, card_deck: Node, actor: CharacterBody3D) -> void:
	_deck = card_deck
	_player = actor
	current_view = view if view in [&"all", &"draw", &"discard", &"catalog"] else &"all"
	visible = true
	_scroll.scroll_vertical = 0
	refresh()


func close_view() -> void:
	visible = false
	get_viewport().gui_release_focus()


func refresh() -> void:
	displayed_cards.clear()
	if is_instance_valid(_deck):
		if current_view == &"catalog" and _deck.has_method("get_catalog_snapshot"):
			displayed_cards = _deck.get_catalog_snapshot()
		elif _deck.has_method("get_card_snapshot"):
			displayed_cards = _deck.get_card_snapshot(current_view)
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	var totals := {"attack": 0, "movement": 0, "hybrid": 0}
	var unlocked_count := 0
	for card in displayed_cards:
		var kind := str(card.get("kind", "slash"))
		var category := CATALOG.category(kind)
		totals[category] = int(totals.get(category, 0)) + 1
		if bool(card.get("unlocked", false)):
			unlocked_count += 1
		_grid.add_child(_create_card(card))
	_title.text = _view_title(current_view)
	_count.text = "%d 张" % displayed_cards.size()
	_summary.text = "攻击 %d 张  ·  位移 %d 张  ·  复合 %d 张" % [totals["attack"], totals["movement"], totals["hybrid"]]
	if current_view == &"catalog":
		_count.text = "%d/%d 种" % [unlocked_count, displayed_cards.size()]
		_summary.text = "靠近训练场中的记忆终端按 E 恢复  ·  每种新动作立即加入 1 张卡牌"
		if not discovery_hint.is_empty():
			_summary.text = "获取途径：%s  ·  每种新动作立即加入 1 张卡牌" % discovery_hint
	_empty.visible = displayed_cards.is_empty()
	_scroll.visible = not displayed_cards.is_empty()
	match current_view:
		&"draw": _empty.text = "抽牌堆暂时为空\n下次需要抽牌时，弃牌会洗回抽牌堆。"
		&"discard": _empty.text = "弃牌堆暂时为空\n打出的卡牌会进入这里。"
		_: _empty.text = "卡组中还没有卡牌。"
	for view: StringName in _tabs:
		var button: Button = _tabs[view]
		button.set_pressed_no_signal(view == current_view)
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	# Consume the modal background, including wheel/motion events outside the grid.
	# Child controls receive GUI events first, so scrolling remains available.
	if event is InputEventMouse or event is InputEventScreenTouch or event is InputEventScreenDrag:
		accept_event()


func _create_interface() -> void:
	var shade := ColorRect.new()
	shade.color = Color(0.015, 0.035, 0.055, 0.78)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	_panel = Panel.new()
	_panel.name = "Panel"
	_panel.position = Vector2(100, 45)
	_panel.size = Vector2(760, 440)
	_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_panel.add_theme_stylebox_override("panel", _style(PANEL, LINE, 8))
	add_child(_panel)
	_title = _label(_panel, "完整卡组", Rect2(24, 16, 440, 31), 23, TEXT)
	_count = _label(_panel, "0 张", Rect2(510, 22, 112, 22), 15, TEAL)
	_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label(_panel, "查看期间战斗暂停  ·  每张牌都是一份可用的动作记忆", Rect2(24, 51, 650, 18), 11, MUTED)
	var close_button := _button("CloseButton", "关闭  Esc", Rect2(638, 18, 98, 30))
	close_button.pressed.connect(func() -> void: close_requested.emit())
	for index in 4:
		var view: StringName = [&"all", &"draw", &"discard", &"catalog"][index]
		var node_name: String = ["AllTab", "DrawTab", "DiscardTab", "CatalogTab"][index]
		var button := _button(node_name, _view_title(view), Rect2(24 + index * 150, 82, 140, 32))
		button.toggle_mode = true
		button.pressed.connect(_select_view.bind(view))
		_tabs[view] = button
	_summary = _label(_panel, "", Rect2(24, 123, 700, 19), 11, MUTED)
	_scroll = ScrollContainer.new()
	_scroll.name = "CardScroll"
	_scroll.position = Vector2(24, 146)
	_scroll.size = Vector2(712, 258)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_child(_scroll)
	_grid = GridContainer.new()
	_grid.name = "CardGrid"
	_grid.columns = 5
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	_grid.mouse_filter = Control.MOUSE_FILTER_PASS
	_scroll.add_child(_grid)
	_empty = _label(_panel, "", Rect2(50, 210, 660, 100), 16, MUTED)
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label(_panel, "抽牌随机，展示顺序不代表抽取顺序  ·  卡牌仅供查看", Rect2(24, 413, 712, 18), 10, MUTED)


func _select_view(view: StringName) -> void:
	current_view = view
	_scroll.scroll_vertical = 0
	refresh()


func _create_card(card: Dictionary) -> Panel:
	var kind := str(card.get("kind", "slash"))
	var locked: bool = card.get("zone", &"") == &"catalog" and not bool(card.get("unlocked", false))
	var accent := MUTED if locked else _accent(kind)
	var card_panel := Panel.new()
	card_panel.name = "Kind_" + kind if card.get("zone", &"") == &"catalog" else "Card%d" % int(card.get("id", -1))
	card_panel.custom_minimum_size = Vector2(132, 124)
	card_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	card_panel.add_theme_stylebox_override("panel", _style(PANEL if locked else CARD, Color(accent, 0.56), 5))
	_label(card_panel, _category(kind), Rect2(10, 8, 43, 15), 10, accent)
	var cost := _label(card_panel, "%.0f 能量" % _cost(kind), Rect2(54, 8, 68, 15), 10, accent)
	cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label(card_panel, _card_name(kind), Rect2(10, 28, 112, 24), 16, MUTED if locked else TEXT)
	var effect := _label(card_panel, _effect(kind), Rect2(10, 58, 112, 39), 11, MUTED if locked else TEXT)
	effect.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label(card_panel, _zone_name(card), Rect2(10, 103, 112 if current_view == &"catalog" else 85, 14), 9, MUTED)
	if current_view != &"catalog":
		var identifier := _label(card_panel, "#%02d" % (int(card.get("id", -1)) + 1), Rect2(94, 103, 28, 14), 9, MUTED)
		identifier.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	return card_panel


func _button(node_name: String, value: String, rect: Rect2) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = value
	button.position = rect.position
	button.size = rect.size
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_font_override("font", UI_FONT)
	button.add_theme_font_size_override("font_size", 12)
	button.add_theme_color_override("font_color", TEXT)
	button.add_theme_color_override("font_hover_color", TEXT)
	button.add_theme_color_override("font_pressed_color", TEAL)
	button.add_theme_stylebox_override("normal", _style(CARD, LINE, 4))
	button.add_theme_stylebox_override("hover", _style(Color("1a3b4e"), TEAL.darkened(0.3), 4))
	button.add_theme_stylebox_override("pressed", _style(Color("17453e"), TEAL, 4))
	button.add_theme_stylebox_override("hover_pressed", _style(Color("1e554b"), TEAL, 4))
	_panel.add_child(button)
	return button


func _label(parent: Control, value: String, rect: Rect2, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.position = rect.position
	label.size = rect.size
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_override("font", UI_FONT)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label


func _style(fill: Color, border: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	return style


func _view_title(view: StringName) -> String:
	match view:
		&"draw": return "抽牌堆"
		&"discard": return "弃牌堆"
		&"catalog": return "动作图鉴"
		_: return "完整卡组"


func _category(kind: String) -> String:
	return CATALOG.category_name(kind)


func _card_name(kind: String) -> String:
	return CATALOG.card_name(kind)


func _accent(kind: String) -> Color:
	return CATALOG.accent(kind)


func _cost(kind: String) -> float:
	if is_instance_valid(_player) and _player.has_method("get_card_cost"):
		return float(_player.call("get_card_cost", kind))
	return CATALOG.cost(kind)


func _effect(kind: String) -> String:
	return CATALOG.effect(kind)


func _zone_name(card: Dictionary) -> String:
	match str(card.get("zone", "")):
		"draw": return "位于抽牌堆"
		"discard": return "位于弃牌堆"
		"hand": return "手牌 · 槽位 %d" % (int(card.get("hand_slot", 0)) + 1)
		"catalog":
			if bool(card.get("unlocked", false)):
				return "已恢复 · 已加入牌组"
			if not discovery_hint.is_empty():
				return discovery_hint
			return "未恢复 · %s记忆" % _category(str(card.get("kind", "")))
		_: return ""
