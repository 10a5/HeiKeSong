extends Control
## A modal presentation of shop/inventory snapshots. Rules and currency live in
## the owner; this view only sends explicit requests for the selected instance.

signal close_requested()
signal buy_requested(offer_id: String)
signal equip_requested(item_id: int)
signal unequip_requested(item_id: int)
signal sell_requested(item_id: int)

const UI_FONT = preload("res://assets/fonts/NotoSansSC-Regular.ttf")
const REVEAL_SHADER = preload("res://materials/shop_reveal.gdshader")
const TEXT := Color("e3f1ed")
const MUTED := Color("88a69c")
const GREEN := Color("7ae9b4")
const CYAN := Color("7bdcd9")
const GOLD := Color("f2cf83")
const LINE := Color("27483e")
const CARD_BG := Color("10271f")
const CARD_SIZE := Vector2(202, 152)

var _snapshot: Dictionary = {}
var _shop_mode := true
var _frame: Panel
var _title: Label
var _subtitle: Label
var _credits: Label
var _equipped: Label
var _message: Label
var _section_cards: Label
var _section_implants: Label
var _inventory_title: Label
var _inventory_hint: Label
var _empty: Label
var _items_scroll: ScrollContainer
var _items_list: VBoxContainer
var _items_panel: Panel
var _goods_root: Control
var _offers: Array[Dictionary] = []
var _slot_lights: Array[ColorRect] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	z_index = 50
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_create_interface()
	visible = false
	set_process(false)


func open_shop(snapshot: Dictionary) -> void:
	_open(snapshot, true)


func open_inventory(snapshot: Dictionary) -> void:
	_open(snapshot, false)


func _open(snapshot: Dictionary, shop_mode: bool) -> void:
	_shop_mode = shop_mode
	_snapshot = snapshot.duplicate(true)
	visible = true
	_items_scroll.scroll_vertical = 0
	_layout_mode()
	_build_offers(true)
	refresh(snapshot)


func refresh(snapshot: Dictionary) -> void:
	_snapshot = snapshot.duplicate(true)
	_credits.text = "%d  金币" % int(_snapshot.get("credits", 0))
	var equipped_count := int(_snapshot.get("equipped_count", 0))
	_equipped.text = "已装备 %d / 5" % equipped_count
	for index in _slot_lights.size():
		_slot_lights[index].color = GREEN if index < equipped_count else Color("29463c")
	var message := str(_snapshot.get("message", ""))
	_message.text = message if not message.is_empty() else ("购买的卡牌加入牌库  ·  义体购买后可在右侧装备" if _shop_mode else "至多同时装备 5 件义体  ·  同类强化可以叠加")
	_message.add_theme_color_override("font_color", GREEN if not message.is_empty() else MUTED)
	_update_stats_summary()
	if _shop_mode:
		var ids: Array[String] = []
		for offer: Dictionary in _snapshot.get("offers", []):
			ids.append(str(offer.get("id", "")))
		var shown_ids: Array[String] = []
		for entry: Dictionary in _offers:
			shown_ids.append(str(entry["id"]))
		if ids != shown_ids:
			_build_offers(false)
	_update_offer_controls()
	_refresh_items()


func close_panel() -> void:
	visible = false
	for entry: Dictionary in _offers:
		var tween: Tween = entry.get("tween")
		if tween and tween.is_valid():
			tween.kill()
		var viewport: SubViewport = entry["viewport"]
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	get_viewport().gui_release_focus()


func is_open() -> bool:
	return visible


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouse or event is InputEventScreenTouch or event is InputEventScreenDrag or event is InputEventGesture:
		accept_event()


func _draw() -> void:
	if not visible:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.012, 0.035, 0.025, 0.88))
	for x in range(0, 961, 32):
		draw_line(Vector2(x, 0), Vector2(x, 540), Color(0.15, 0.34, 0.26, 0.06))
	for y in range(0, 541, 32):
		draw_line(Vector2(0, y), Vector2(960, y), Color(0.15, 0.34, 0.26, 0.06))


func _create_interface() -> void:
	_frame = Panel.new()
	_frame.name = "ShopFrame"
	_frame.position = Vector2(22, 19)
	_frame.size = Vector2(916, 502)
	_frame.mouse_filter = Control.MOUSE_FILTER_PASS
	_frame.add_theme_stylebox_override("panel", _style(Color("071a12"), LINE, 12))
	add_child(_frame)
	_rect(_frame, Rect2(19, 0, 115, 2), GREEN)
	_title = _label(_frame, "义体黑市", Rect2(18, 11, 360, 34), 24, TEXT)
	_subtitle = _label(_frame, "城市补给终端  /  连接已加密", Rect2(19, 48, 500, 19), 11, MUTED)
	_credits = _label(_frame, "0  金币", Rect2(553, 13, 220, 29), 20, GOLD)
	_credits.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_equipped = _label(_frame, "已装备 0 / 5", Rect2(642, 49, 132, 19), 11, MUTED)
	_equipped.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	for index in 5:
		_slot_lights.append(_rect(_frame, Rect2(560 + index * 13, 55, 8, 4), LINE))
	var close := _button(_frame, "关闭  Esc", Rect2(795, 17, 101, 34), MUTED)
	close.name = "CloseButton"
	close.pressed.connect(func() -> void: close_requested.emit())
	_rect(_frame, Rect2(18, 78, 880, 1), LINE)
	_section_cards = _label(_frame, "动作卡牌", Rect2(18, 84, 500, 23), 13, CYAN)
	_section_implants = _label(_frame, "义体配件", Rect2(18, 277, 500, 23), 13, GREEN)
	_goods_root = Control.new()
	_goods_root.name = "Offers"
	_goods_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_goods_root.position = Vector2(18, 109)
	_goods_root.size = Vector2(626, 345)
	_frame.add_child(_goods_root)
	_items_panel = Panel.new()
	_items_panel.name = "OwnedImplants"
	_items_panel.position = Vector2(660, 84)
	_items_panel.size = Vector2(238, 370)
	_items_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_items_panel.add_theme_stylebox_override("panel", _style(Color("0b2017"), LINE, 8))
	_frame.add_child(_items_panel)
	_inventory_title = _label(_items_panel, "我的义体", Rect2(12, 8, 216, 25), 15, TEXT)
	_inventory_hint = _label(_items_panel, "装备生效 · 卸下保留在背包", Rect2(12, 37, 216, 20), 10, MUTED)
	_items_scroll = ScrollContainer.new()
	_items_scroll.name = "ImplantScroll"
	_items_scroll.position = Vector2(10, 66)
	_items_scroll.size = Vector2(218, 292)
	_items_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_items_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	_items_panel.add_child(_items_scroll)
	_items_list = VBoxContainer.new()
	_items_list.name = "ImplantList"
	_items_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_items_list.add_theme_constant_override("separation", 8)
	_items_list.mouse_filter = Control.MOUSE_FILTER_PASS
	_items_scroll.add_child(_items_list)
	_empty = _label(_items_panel, "还没有义体配件\n\n购买配件，定制你的身体。", Rect2(14, 122, 210, 92), 12, MUTED)
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_message = _label(_frame, "", Rect2(19, 473, 878, 20), 11, MUTED)
	_rect(_frame, Rect2(18, 465, 880, 1), LINE)


func _layout_mode() -> void:
	_title.text = "义体黑市" if _shop_mode else "义体配置"
	_subtitle.text = "城市补给终端  /  连接已加密" if _shop_mode else "神经接口管理  /  最多装备 5 件义体"
	_goods_root.visible = _shop_mode
	_section_cards.visible = _shop_mode
	_section_implants.visible = _shop_mode
	_inventory_title.text = "我的义体" if _shop_mode else "装备与背包"
	_inventory_hint.text = "装备生效 · 卸下保留在背包" if _shop_mode else "点击装备或卸下  ·  出售请前往商店"
	_items_panel.position = Vector2(660, 84) if _shop_mode else Vector2(18, 94)
	_items_panel.size = Vector2(238, 370) if _shop_mode else Vector2(880, 360)
	_items_scroll.size = Vector2(218, 292) if _shop_mode else Vector2(860, 282)
	_inventory_hint.size.x = 216 if _shop_mode else 700
	_empty.position = Vector2(14, 122) if _shop_mode else Vector2(220, 120)
	_empty.size.x = 210 if _shop_mode else 440
	queue_redraw()


func _update_stats_summary() -> void:
	if _shop_mode:
		return
	var stats: Dictionary = _snapshot.get("stats", {})
	if stats.is_empty():
		_inventory_hint.text = "点击装备或卸下  ·  出售请前往商店"
		_inventory_hint.add_theme_color_override("font_color", MUTED)
		return
	_inventory_hint.text = "当前属性  ·  手牌 %d  ·  伤害 %.0f%%  ·  承伤 %.0f%%  ·  移速 %.1f  ·  能量 %.1f  ·  恢复 %.1f/秒" % [
		int(stats.get("hand_size", 4)), float(stats.get("damage_multiplier", 1.0)) * 100.0,
		float(stats.get("damage_taken_multiplier", 1.0)) * 100.0,
		float(stats.get("move_speed", 0.0)), float(stats.get("max_energy", 0.0)),
		float(stats.get("energy_regen", 0.0))]
	_inventory_hint.add_theme_color_override("font_color", GREEN)


func _build_offers(animate: bool) -> void:
	for entry: Dictionary in _offers:
		var tween: Tween = entry.get("tween")
		if tween and tween.is_valid():
			tween.kill()
	_offers.clear()
	for child in _goods_root.get_children():
		_goods_root.remove_child(child)
		child.queue_free()
	if not _shop_mode:
		return
	var card_index := 0
	var implant_index := 0
	for offer: Dictionary in _snapshot.get("offers", []):
		var is_card := str(offer.get("type", "card")) == "card"
		var index := card_index if is_card else implant_index
		if index >= 3:
			continue
		if is_card:
			card_index += 1
		else:
			implant_index += 1
		_create_offer(offer, Vector2(index * 212, 0 if is_card else 193), animate, index + (0 if is_card else 3))


func _create_offer(offer: Dictionary, origin: Vector2, animate: bool, order: int) -> void:
	var holder := Control.new()
	holder.name = "Offer_" + str(offer.get("id", order))
	holder.position = origin
	holder.size = CARD_SIZE
	holder.tooltip_text = str(offer.get("effect", ""))
	holder.mouse_filter = Control.MOUSE_FILTER_PASS
	_goods_root.add_child(holder)
	var viewport := SubViewport.new()
	viewport.name = "ProductTexture"
	viewport.size = Vector2i(CARD_SIZE * 2)
	viewport.transparent_bg = true
	viewport.gui_disable_input = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	holder.add_child(viewport)
	var surface := Control.new()
	surface.size = CARD_SIZE
	surface.scale = Vector2(2, 2)
	surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport.add_child(surface)
	var accent := _offer_color(offer)
	var card := Panel.new()
	card.size = CARD_SIZE
	card.add_theme_stylebox_override("panel", _style(CARD_BG, accent.darkened(0.63), 7))
	surface.add_child(card)
	_rect(surface, Rect2(12, 11, 3, 13), accent)
	var is_card := str(offer.get("type", "card")) == "card"
	_label(surface, "动作记忆" if is_card else "身体强化", Rect2(22, 9, 130, 18), 10, accent)
	var spec := "%02d" % (order + 1)
	if is_card and offer.has("cost"):
		spec = "%s 能量" % str(offer["cost"])
	var serial := _label(surface, spec, Rect2(130, 9, 60, 18), 9, MUTED)
	serial.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label(surface, str(offer.get("name", "未命名配件")), Rect2(12, 31, 179, 25), 17, TEXT)
	var effect := _label(surface, str(offer.get("effect", "")), Rect2(12, 58, 178, 48), 10, MUTED)
	effect.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	effect.max_lines_visible = 3
	effect.add_theme_constant_override("line_spacing", -3)
	_rect(surface, Rect2(12, 110, 178, 1), accent.darkened(0.75))
	var reveal_material := ShaderMaterial.new()
	reveal_material.shader = REVEAL_SHADER
	reveal_material.set_shader_parameter("blur_radius", 16.0 if animate else 0.0)
	reveal_material.set_shader_parameter("reveal", 0.0 if animate else 1.0)
	var texture := TextureRect.new()
	texture.name = "BlurReveal"
	texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	texture.texture = viewport.get_texture()
	texture.material = reveal_material
	texture.size = CARD_SIZE
	texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(texture)
	var buy := _button(holder, "购买", Rect2(12, 117, 178, 27), accent)
	buy.name = "BuyButton"
	buy.add_theme_font_size_override("font_size", 12)
	buy.modulate.a = 0.0 if animate else 1.0
	buy.disabled = true
	buy.pressed.connect(_request_buy.bind(str(offer.get("id", ""))))
	var entry := {"id": str(offer.get("id", "")), "viewport": viewport, "material": reveal_material, "buy": buy, "ready": not animate}
	_offers.append(entry)
	if animate:
		var tween := create_tween()
		entry["tween"] = tween
		tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
		tween.tween_interval(maxf(0.0, float(_snapshot.get("reveal_delay", 0.0))) + order * 0.045)
		tween.tween_property(reveal_material, "shader_parameter/reveal", 1.0, 0.65).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tween.parallel().tween_property(reveal_material, "shader_parameter/blur_radius", 0.0, 0.65).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tween.parallel().tween_property(buy, "modulate:a", 1.0, 0.28).set_delay(0.37)
		tween.tween_callback(_offer_revealed.bind(entry))


func _offer_revealed(entry: Dictionary) -> void:
	entry["ready"] = true
	_update_offer_controls()


func _update_offer_controls() -> void:
	var credits := int(_snapshot.get("credits", 0))
	for entry: Dictionary in _offers:
		var offer := _find_offer(str(entry["id"]))
		var button: Button = entry["buy"]
		var price := int(offer.get("price", 0))
		var sold := bool(offer.get("sold", false))
		button.text = "已售罄" if sold else ("购买  ·  %d 金币" % price if credits >= price else "%d 金币  ·  余额不足" % price)
		button.disabled = sold or credits < price or not bool(entry["ready"])
		button.tooltip_text = "该商品已经售出" if sold else "购买 " + str(offer.get("name", ""))


func _request_buy(offer_id: String) -> void:
	if not visible or not _shop_mode:
		return
	buy_requested.emit(offer_id)


func _find_offer(offer_id: String) -> Dictionary:
	for offer: Dictionary in _snapshot.get("offers", []):
		if str(offer.get("id", "")) == offer_id:
			return offer
	return {}


func _refresh_items() -> void:
	var scroll_position := _items_scroll.scroll_vertical
	for child in _items_list.get_children():
		_items_list.remove_child(child)
		child.queue_free()
	var items: Array = _snapshot.get("items", [])
	var sorted_items := items.duplicate()
	sorted_items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if bool(a.get("equipped", false)) != bool(b.get("equipped", false)):
			return bool(a.get("equipped", false))
		return int(a.get("id", 0)) < int(b.get("id", 0)))
	_empty.visible = items.is_empty()
	_items_scroll.visible = not items.is_empty()
	for item: Dictionary in sorted_items:
		_create_item(item)
	_items_scroll.set_deferred("scroll_vertical", scroll_position)


func _create_item(item: Dictionary) -> void:
	var equipped := bool(item.get("equipped", false))
	var item_id := int(item.get("id", 0))
	var accent := _offer_color(item)
	var row := PanelContainer.new()
	row.name = "Implant_%d" % item_id
	row.custom_minimum_size = Vector2(202, 112 if _shop_mode else 72)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_stylebox_override("panel", _style(Color("122d21") if equipped else Color("0b1a13"), accent.darkened(0.52) if equipped else Color("263c31"), 5))
	_items_list.add_child(row)
	var content := Control.new()
	content.custom_minimum_size = row.custom_minimum_size
	content.mouse_filter = Control.MOUSE_FILTER_PASS
	var full_effect := str(item.get("effect", ""))
	content.tooltip_text = str(item.get("name", "义体")) + "\n" + full_effect
	row.add_child(content)
	var name_label := _label(content, str(item.get("name", "义体")), Rect2(10, 6, 182 if _shop_mode else 420, 23), 13, TEXT)
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.tooltip_text = str(item.get("name", "义体")) + "  #%03d" % item_id
	var effect_summary := full_effect.get_slice("\n", 0) if _shop_mode else full_effect.replace("\n", "  ·  ")
	var effect := _label(content, effect_summary, Rect2(10, 31, 184 if _shop_mode else 620, 19), 10 if _shop_mode else 12, MUTED)
	effect.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	effect.max_lines_visible = 1
	effect.tooltip_text = full_effect
	_label(content, ("已装备" if equipped else "背包") + "  #%03d" % item_id, Rect2(10, 54 if _shop_mode else 52, 170, 17), 9, accent if equipped else MUTED)
	var equip_button := _button(content, "卸下" if equipped else "装备", Rect2(10, 77, 77, 26) if _shop_mode else Rect2(684, 20, 130, 30), accent)
	equip_button.name = "UnequipButton" if equipped else "EquipButton"
	equip_button.add_theme_font_size_override("font_size", 11)
	equip_button.disabled = not equipped and int(_snapshot.get("equipped_count", 0)) >= 5
	if equip_button.disabled:
		equip_button.text = "槽位已满"
	equip_button.pressed.connect(func() -> void:
		if equipped:
			unequip_requested.emit(item_id)
		else:
			equip_requested.emit(item_id))
	if _shop_mode:
		var sell := _button(content, "出售 +%d" % int(item.get("sell_price", 0)), Rect2(94, 77, 99, 26), GOLD)
		sell.name = "SellButton"
		sell.add_theme_font_size_override("font_size", 10)
		sell.tooltip_text = "出售此件义体" + ("，同时解除装备" if equipped else "")
		sell.pressed.connect(func() -> void: sell_requested.emit(item_id))


func _offer_color(offer: Dictionary) -> Color:
	var raw: Variant = offer.get("color", GREEN if str(offer.get("type", "implant")) == "implant" else CYAN)
	if raw is Color:
		return raw
	return Color.from_string(str(raw), GREEN)


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
	button.add_theme_color_override("font_disabled_color", Color("70897d"))
	button.add_theme_stylebox_override("normal", _style(Color("18372a"), accent.darkened(0.48), 4))
	button.add_theme_stylebox_override("hover", _style(Color("28533d"), accent, 4))
	button.add_theme_stylebox_override("pressed", _style(Color("10231a"), accent, 4))
	button.add_theme_stylebox_override("disabled", _style(Color("102019"), Color("2a3c31"), 4))
	button.add_theme_stylebox_override("focus", _style(Color(0, 0, 0, 0), accent, 4))
	parent.add_child(button)
	return button
