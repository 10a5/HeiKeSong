extends Control
## Compact street overview; the floor controller owns pausing and map shortcuts.

signal close_requested()
signal map_toggle_requested()

const FONT = preload("res://assets/fonts/NotoSansSC-Regular.ttf")
const SERVICE = preload("res://city_building.gd")
const MINI := Rect2(810, 94, 128, 120)
const PANEL := Rect2(166, 32, 628, 462)
const MAP := Rect2(204, 88, 354, 354)
const CLOSE := Rect2(694, 47, 80, 26)
const TEXT := Color("e1eef3")
const MUTED := Color("8ca5b6")
const TEAL := Color("74f3d1")
const DANGER := Color("ff797e")

var map_open := false
var _controller: Node
var _hidden_by_cards := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_floor(controller: Node) -> void:
	_controller = controller
	queue_redraw()


func toggle_map() -> void:
	map_open = not map_open
	mouse_filter = Control.MOUSE_FILTER_STOP if map_open else Control.MOUSE_FILTER_IGNORE
	queue_redraw()


func close_map() -> void:
	map_open = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()


func _process(_delta: float) -> void:
	_hidden_by_cards = false
	if is_instance_valid(_controller):
		var hud = _controller.get("hud")
		if is_instance_valid(hud) and hud.has_method("is_browser_open"):
			_hidden_by_cards = bool(hud.call("is_browser_open"))
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if map_open or _hidden_by_cards or not is_instance_valid(_controller):
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var point: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
		if MINI.has_point(point):
			map_toggle_requested.emit()
			get_viewport().set_input_as_handled()


func _gui_input(event: InputEvent) -> void:
	if not map_open:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if CLOSE.has_point(event.position):
			close_requested.emit()
	if event is InputEventMouse:
		accept_event()


func _draw() -> void:
	if not is_instance_valid(_controller) or _hidden_by_cards:
		return
	var cleared := int(_controller.call("cleared_encounters")) if _controller.has_method("cleared_encounters") else 0
	var credits := int(_controller.get("credits"))
	var total := 8
	var encounters = _controller.get("encounters")
	if encounters is Array and not encounters.is_empty():
		total = encounters.size()
	if not map_open:
		_text(Vector2(20, 152), "金币 %d  ·  遭遇 %d/%d" % [credits, cleared, total], 11, TEXT)
		var zone := str(_controller.get("water_zone"))
		var water_hint := "水边谨慎 · M 查看地图"
		var accent := MUTED
		if zone in ["shallow", "浅水", "shallow_water"]:
			water_hint = "浅水区 · 可站立"
			accent = Color("81ceff")
		elif zone in ["deep", "深水", "deep_water"] or bool(_controller.get("lost_in_water")):
			water_hint = "深水区 · 返回岸边"
			accent = DANGER
		_text(Vector2(20, 170), water_hint, 10, accent)
		draw_rect(MINI.grow(2), Color("0c1b28"))
		_draw_city(MINI, false)
		draw_rect(MINI.grow(2), Color("3e6071"), false, 1.0)
		_text(Vector2(810, 227), "M  城市地图", 10, TEXT)
		return
	draw_rect(Rect2(0, 0, 960, 540), Color(0.015, 0.03, 0.05, 0.84))
	draw_rect(PANEL, Color("0c1b28"))
	draw_rect(PANEL, Color("395366"), false, 1)
	_text(Vector2(204, 65), "%s · 城市街区" % _floor_label(), 21, TEXT)
	_text(Vector2(514, 65), "种子 %d" % int(_controller.get("map_seed")), 10, MUTED)
	draw_rect(CLOSE, Color("193346"))
	draw_rect(CLOSE, Color("507184"), false, 1)
	_text(Vector2(705, 65), "关闭  M", 12, TEXT)
	_draw_city(MAP, true)
	draw_rect(MAP, Color("3e6071"), false, 1)
	_text(Vector2(584, 105), "金币 %d" % credits, 16, TEAL)
	_text(Vector2(584, 132), "已清理遭遇 %d/%d" % [cleared, total], 12, TEXT)
	var index := 0
	for kind in ["residential", "shop", "factory", "medical", "police"]:
		var y := 166.0 + index * 27.0
		draw_rect(Rect2(585, y - 10, 11, 11), SERVICE.COLORS[kind])
		_text(Vector2(605, y), SERVICE.NAMES[kind], 12, TEXT)
		index += 1
	draw_circle(Vector2(590, 313), 4, DANGER)
	_text(Vector2(605, 317), "未完成遭遇", 12, TEXT)
	draw_circle(Vector2(590, 340), 4, TEAL)
	_text(Vector2(605, 344), "已清理遭遇", 12, TEXT)
	draw_circle(Vector2(590, 367), 4, Color.WHITE)
	_text(Vector2(605, 371), "当前位置", 12, TEXT)
	_text(Vector2(584, 394), "隐形敌人显形后才标出位置", 11, MUTED)
	_text(Vector2(584, 410), "浅水可站立", 11, Color("7cc8d9"))
	_text(Vector2(584, 430), "深水会迷失", 11, DANGER)
	_text(Vector2(204, 463), "查看期间暂停 · E 贴近建筑交互 · M / Esc 返回", 11, MUTED)
	_text(Vector2(204, 483), "R  重试本图  ·  N  生成新地图", 11, MUTED)


func _draw_city(rect: Rect2, expanded: bool) -> void:
	var city_map = _controller.get("city_map")
	if not is_instance_valid(city_map):
		return
	var land: Rect2 = city_map.get("land_rect")
	var shallow: Rect2 = city_map.get("shallow_rect")
	var bounds := shallow.grow(3.0)
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return
	draw_rect(rect, Color("285265"))
	draw_rect(_world_rect(land, rect, bounds), Color("263540"))
	for road: Dictionary in city_map.get("road_data"):
		var polygon := PackedVector2Array()
		for point: Vector2 in road["footprint"]:
			polygon.append(_world_point(point, rect, bounds))
		draw_colored_polygon(polygon, Color("536774"))
	var buildings: Array = city_map.get("building_data")
	for building: Dictionary in buildings:
		var at: Vector3 = building.get("position", Vector3.ZERO)
		var polygon := PackedVector2Array()
		for point: Vector2 in building["footprint"]:
			polygon.append(_world_point(point, rect, bounds))
		var kind := str(building.get("kind", "residential"))
		var color: Color = SERVICE.COLORS.get(kind, MUTED)
		draw_colored_polygon(polygon, color.darkened(0.15))
		if expanded:
			var center := _world_point(Vector2(at.x, at.z), rect, bounds)
			_text(center + Vector2(-6, 4), str(SERVICE.NAMES.get(kind, ""))[0], 11, Color("10212a"))
	var encounters = _controller.get("encounters")
	if encounters is Array:
		for encounter in encounters:
			if not is_instance_valid(encounter):
				continue
			var color := encounter_map_color(encounter)
			# A fully transparent answer means "leave this encounter unplotted".
			if color.a <= 0.0:
				continue
			var at: Vector3 = encounter.global_position
			draw_circle(_world_point(Vector2(at.x, at.z), rect, bounds), 3.5 if expanded else 1.8, color)
	var player = _controller.get("player")
	if is_instance_valid(player):
		var at: Vector3 = player.global_position
		var marker := _world_point(Vector2(at.x, at.z), rect, bounds)
		marker = marker.clamp(rect.position + Vector2.ONE * 3.0, rect.end - Vector2.ONE * 3.0)
		draw_circle(marker, 5.0 if expanded else 3.0, Color("06111a"))
		draw_circle(marker, 3.5 if expanded else 2.0, Color.WHITE)


func _world_point(point: Vector2, rect: Rect2, bounds: Rect2) -> Vector2:
	return rect.position + (point - bounds.position) / bounds.size * rect.size


## "第一层" / "第二层" / "第三层" for the panel header. The floor controller owns
## the label so the overlay never needs its own floor table.
func _floor_label() -> String:
	if is_instance_valid(_controller) and _controller.has_method("_district_short_name"):
		return str(_controller.call("_district_short_name"))
	return "第一层"


## Dot colour for one encounter, or a transparent colour when it must not be
## plotted at all. A concealed enemy opts out through `shows_on_city_map()`;
## everything else keeps the two-state legend (unfinished / cleared).
func encounter_map_color(encounter: Node) -> Color:
	if not is_instance_valid(encounter):
		return Color(0.0, 0.0, 0.0, 0.0)
	if encounter.has_method("shows_on_city_map") and not bool(encounter.call("shows_on_city_map")):
		return Color(0.0, 0.0, 0.0, 0.0)
	return TEAL if str(encounter.get("state")) == "cleared" else DANGER


func _world_rect(world: Rect2, rect: Rect2, bounds: Rect2) -> Rect2:
	return Rect2(_world_point(world.position, rect, bounds), world.size / bounds.size * rect.size)


func _text(at: Vector2, value: String, font_size: int, color: Color) -> void:
	draw_string_outline(FONT, at, value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 3, Color("071019"))
	draw_string(FONT, at, value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
