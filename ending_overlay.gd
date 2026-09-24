extends Control
## The screen-space half of the Boss-victory ending.
##
## `floor_ending.gd` owns the 3D collapse, the water and the camera; this
## Control owns everything the player reads: the cinematic letterbox, the quote
## that hangs over the water, and the digital "shop entrance" gate that hides the
## switch to the next floor. It draws with `_draw()` and the bundled Noto Sans SC
## font, so it needs no textures of its own.
##
##     var overlay := ENDING_OVERLAY.new()
##     canvas_layer.add_child(overlay)
##     overlay.show_quote("你我犹如隔镜视物，所见无非虚幻迷蒙", 1.7)
##     overlay.start_digital("接入商店协议", "第二层 · 深巷回廊")
##     overlay.set_load_progress(0.42)
##     overlay.cover_digital()      # emits `digital_covered` once the gate fills the screen
##
## The node sits above the HUD (`z_index` 96) but below `matrix_transition`
## (100), runs while the tree is paused, and never takes the mouse: the ending is
## read, not clicked.

## Emitted when the gate has completely covered the screen, so the owner may
## swap scenes without the player seeing the change.
signal digital_covered
## Emitted when the quote has finished its own fade-in, hold and fade-out.
signal quote_finished

const UI_FONT = preload("res://assets/fonts/NotoSansSC-Regular.ttf")
const DIGIT_GREEN := Color("3dff7a")
const DIGIT_BRIGHT := Color("e8fff1")
const DIGIT_MID := Color("22c96a")
const DIGIT_DEEP := Color("0a3f24")
const QUOTE_COLOR := Color("dceef5")
const CAPTION_COLOR := Color("7c98a8")
## Fraction of the viewport height each cinematic bar covers when extended.
const LETTERBOX_RATIO := 0.11
## The door's size as a fraction of the viewport once the intro has resolved.
const DOOR_RATIO := Vector2(0.34, 0.56)
const STREAM_GLYPHS := "0123456789ABCDEF<>/\\[]{}#$%&*+=:;·"
const MIN_COLUMN_WIDTH := 22.0
const MIN_STREAM_LENGTH := 8
const MAX_STREAM_LENGTH := 22
## Seconds the gate takes to grow out of the data rain.
const DIGITAL_INTRO := 1.35
## Seconds of fade for the full-screen darkening.
const DIM_RATE := 0.85
const COVER_DURATION := 0.55

enum Phase { IDLE, WATER, DIGITAL, DONE }

var _phase := Phase.IDLE
var _clock := 0.0
var _digital_time := 0.0
var _font: FontVariation
var _last_size := Vector2.ZERO
var _dim := 0.0
var _dim_target := 0.0
var _letterbox := 0.0
var _letterbox_target := 0.0
var _quote_alpha := 0.0
var _quote_target := 0.0
var _quote_text := ""
var _quote_hold := 0.0
var _quote_timer := 0.0
var _quote_state := 0
var _line_grow := 0.0
var _caption := "断层 · 水面"
var _hint := "任意键 跳过"
var _hint_alpha := 0.0
var _digital_title := "接入商店协议"
var _digital_latin := "SHOP UPLINK"
var _digital_target := ""
var _load_progress := 0.0
var _load_ready := false
var _cover := 0.0
var _covering := false
var _streams: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	z_index = 96
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_font = FontVariation.new()
	_font.base_font = UI_FONT
	_font.variation_embolden = 0.25
	_rng.randomize()
	_last_size = size
	_rebuild_streams()
	hide()
	set_process(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and size != _last_size:
		_last_size = size
		_rebuild_streams()
		queue_redraw()


# ------------------------------------------------------------------ public API

## Cinematic bars, darkening and the skip hint. Called once by the director
## before the collapse starts.
func begin_show(caption: String, hint: String) -> void:
	_caption = caption
	_hint = hint
	_phase = Phase.WATER
	_dim = 0.0
	_dim_target = 0.30
	_letterbox = 0.0
	_letterbox_target = 1.0
	_hint_alpha = 0.0
	_cover = 0.0
	_covering = false
	show()
	set_process(true)
	queue_redraw()


## Full-screen darkening, used to bury the sinking arena during the fall and to
## hand the frame over to the water cut.
func set_dim(target: float) -> void:
	_dim_target = clampf(target, 0.0, 1.0)


## Fade the quote in, hold it for `hold` seconds, then fade it out. The text is
## the one string the ending is built around, so it is drawn alone in the middle
## of the frame with nothing else competing for attention.
func show_quote(text: String, hold: float) -> void:
	_quote_text = text
	_quote_hold = maxf(0.0, hold)
	_quote_state = 1
	_quote_timer = 0.0
	_quote_target = 1.0
	_letterbox_target = 1.0
	_hint_alpha = 0.0


func hide_quote() -> void:
	_quote_state = 3
	_quote_target = 0.0


func is_quote_visible() -> bool:
	return _quote_alpha > 0.01


## Swap the frame to the digital gate. `title` is the protocol line above the
## door, `target` is the destination named under the progress bar.
func start_digital(title: String, latin: String, target: String) -> void:
	_digital_title = title
	_digital_latin = latin
	_digital_target = target
	_phase = Phase.DIGITAL
	_digital_time = 0.0
	_load_progress = 0.0
	_load_ready = false
	_cover = 0.0
	_covering = false
	_letterbox_target = 0.0
	_quote_target = 0.0
	_quote_state = 0
	_rebuild_streams()
	show()
	set_process(true)
	queue_redraw()


func set_load_progress(ratio: float) -> void:
	_load_progress = clampf(maxf(_load_progress, ratio), 0.0, 1.0)


func set_load_ready() -> void:
	_load_ready = true
	_load_progress = 1.0


func is_load_ready() -> bool:
	return _load_ready


func is_digital() -> bool:
	return _phase == Phase.DIGITAL


## Flare the gate open until the screen is covered; `digital_covered` follows.
func cover_digital() -> void:
	if _covering:
		return
	_covering = true
	_phase = Phase.DIGITAL
	show()
	set_process(true)


func is_covered() -> bool:
	return _cover >= 0.999


## Drop every layer and stop drawing. Safe to call at any point in the sequence.
func reset() -> void:
	_phase = Phase.IDLE
	_dim = 0.0
	_dim_target = 0.0
	_letterbox = 0.0
	_letterbox_target = 0.0
	_quote_alpha = 0.0
	_quote_target = 0.0
	_quote_state = 0
	_hint_alpha = 0.0
	_cover = 0.0
	_covering = false
	_load_ready = false
	_load_progress = 0.0
	hide()
	set_process(false)
	queue_redraw()


# -------------------------------------------------------------------- internal

func _process(delta: float) -> void:
	_clock += delta
	_dim = move_toward(_dim, _dim_target, DIM_RATE * delta)
	_letterbox = move_toward(_letterbox, _letterbox_target, 2.4 * delta)
	_quote_alpha = move_toward(_quote_alpha, _quote_target, 0.62 * delta)
	_line_grow = move_toward(_line_grow, _quote_target, 0.55 * delta)
	_hint_alpha = move_toward(_hint_alpha, 1.0 if _phase == Phase.WATER and _dim > 0.08 else 0.0, 0.5 * delta)
	if _phase == Phase.DIGITAL:
		_digital_time += delta
	if _covering:
		_cover = move_toward(_cover, 1.0, delta / COVER_DURATION)
		if _cover >= 0.999 and _phase != Phase.DONE:
			_phase = Phase.DONE
			digital_covered.emit()
	_advance_quote(delta)
	_advance_streams(delta)
	queue_redraw()


func _advance_quote(delta: float) -> void:
	if _quote_state == 0:
		return
	_quote_timer += delta
	match _quote_state:
		1:
			# Wait for the fade-in to finish before starting the hold clock.
			if _quote_alpha >= 0.995:
				_quote_state = 2
				_quote_timer = 0.0
		2:
			if _quote_timer >= _quote_hold:
				_quote_state = 3
				_quote_target = 0.0
		3:
			if _quote_alpha <= 0.005:
				_quote_state = 0
				quote_finished.emit()


func _advance_streams(delta: float) -> void:
	if _phase != Phase.DIGITAL and _phase != Phase.DONE:
		return
	for stream in _streams:
		stream["head"] = float(stream["head"]) + float(stream["speed"]) * delta
		if float(stream["head"]) - float(stream["length"]) * float(stream["cell"]) > size.y + 40.0:
			stream["head"] = -_rng.randf_range(4.0, size.y * 0.18)
			stream["speed"] = _rng.randf_range(150.0, 420.0)
			stream["length"] = _rng.randi_range(MIN_STREAM_LENGTH, MAX_STREAM_LENGTH)


func _rebuild_streams() -> void:
	_streams.clear()
	if size.x <= 1.0 or size.y <= 1.0:
		return
	var columns := clampi(ceili(size.x / MIN_COLUMN_WIDTH), 1, 120)
	for column in columns:
		var near_centre := absf(float(column) / maxf(1.0, float(columns - 1)) - 0.5) < 0.30
		_streams.append({
			"x": (float(column) + 0.5) * size.x / float(columns),
			"head": _rng.randf_range(-size.y * 0.4, size.y),
			"speed": _rng.randf_range(150.0, 420.0) * (1.25 if near_centre else 0.75),
			"length": _rng.randi_range(MIN_STREAM_LENGTH, MAX_STREAM_LENGTH),
			"cell": 15.0,
			"bright": _rng.randf_range(0.45, 1.0),
			"phase": _rng.randf_range(0.0, TAU),
		})


func _glyph(index: int, row: int) -> String:
	var bucket := int(floor(_clock * 9.0 + float(index % 5) * 0.37))
	var value := index * 7919 + row * 104729 + bucket * 31337
	value = ((value ^ (value >> 6)) * 16807) & 0x7fffffff
	return STREAM_GLYPHS[value % STREAM_GLYPHS.length()]


func _door_rect(progress: float) -> Rect2:
	var target := Vector2(size.x * DOOR_RATIO.x, size.y * DOOR_RATIO.y)
	var current := Vector2(
		lerpf(size.x * 0.14, target.x, progress),
		lerpf(size.y * 0.20, target.y, progress)
	)
	return Rect2((size - current) * 0.5, current)


# ---------------------------------------------------------------------- drawing

func _draw() -> void:
	if _dim <= 0.001 and _phase == Phase.IDLE and _cover <= 0.001:
		return
	var full := Rect2(Vector2.ZERO, size)
	if _dim > 0.001:
		draw_rect(full, Color(0.004, 0.010, 0.016, _dim))
	if _phase == Phase.DIGITAL or _phase == Phase.DONE:
		_draw_digital()
	else:
		_draw_cinema()
	if _cover > 0.001:
		_draw_cover()


func _draw_cinema() -> void:
	var bar := size.y * LETTERBOX_RATIO * _letterbox
	if bar > 0.5:
		draw_rect(Rect2(0.0, 0.0, size.x, bar), Color(0.0, 0.0, 0.0, 0.93))
		draw_rect(Rect2(0.0, size.y - bar, size.x, bar), Color(0.0, 0.0, 0.0, 0.93))
		draw_line(Vector2(0.0, bar), Vector2(size.x, bar), Color(0.16, 0.45, 0.38, 0.35 * _letterbox), 1.0)
		draw_line(Vector2(0.0, size.y - bar), Vector2(size.x, size.y - bar), Color(0.16, 0.45, 0.38, 0.35 * _letterbox), 1.0)
	var caption_size := clampi(int(size.y * 0.024), 9, 18)
	if bar > 4.0 and _letterbox > 0.5:
		draw_string(_font, Vector2(28.0, size.y - bar * 0.34), _caption, HORIZONTAL_ALIGNMENT_LEFT, -1, caption_size, Color(CAPTION_COLOR, 0.85 * _letterbox))
	if _hint_alpha > 0.01:
		var hint := _hint
		var hint_width := _font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, caption_size).x
		draw_string(_font, Vector2(size.x - 28.0 - hint_width, size.y - bar * 0.34), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, caption_size, Color(CAPTION_COLOR, 0.75 * _hint_alpha))
	if _quote_alpha <= 0.001:
		return
	var font_size := clampi(int(size.y * 0.056), 16, 46)
	var baseline := size.y * 0.5
	var text_width := _font.get_string_size(_quote_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string_outline(_font, Vector2(0.0, baseline), _quote_text, HORIZONTAL_ALIGNMENT_CENTER, size.x, font_size, 8, Color(0.0, 0.02, 0.03, 0.8 * _quote_alpha))
	draw_string(_font, Vector2(0.0, baseline), _quote_text, HORIZONTAL_ALIGNMENT_CENTER, size.x, font_size, Color(QUOTE_COLOR, _quote_alpha))
	# A pair of thin rules grows out of the text as it settles, the way a
	# subtitle plate would be drawn on rather than cut in.
	var half := text_width * 0.5 + 34.0
	var gap := font_size * 0.62
	for offset: float in [-1.0, 1.0]:
		var y: float = baseline + offset * gap
		draw_line(Vector2(size.x * 0.5 - half, y), Vector2(size.x * 0.5 + half, y), Color(0.34, 0.78, 0.68, 0.36 * _quote_alpha * _line_grow), 1.0)
	var tick := 6.0
	for x: float in [size.x * 0.5 - half, size.x * 0.5 + half]:
		draw_line(Vector2(x, baseline - gap), Vector2(x, baseline - gap + tick), Color(0.62, 0.96, 0.88, 0.55 * _quote_alpha), 1.0)
		draw_line(Vector2(x, baseline + gap), Vector2(x, baseline + gap - tick), Color(0.62, 0.96, 0.88, 0.55 * _quote_alpha), 1.0)


func _draw_digital() -> void:
	var full := Rect2(Vector2.ZERO, size)
	var backdrop := clampf(_digital_time / 0.4, 0.0, 1.0)
	var intro := _ease_out(clampf(_digital_time / DIGITAL_INTRO, 0.0, 1.0))
	draw_rect(full, Color(0.002, 0.014, 0.007, 0.92 * backdrop))
	for y in range(0, int(size.y), 4):
		draw_line(Vector2(0.0, y), Vector2(size.x, y), Color(0.0, 0.0, 0.0, 0.12))
	var sweep := fmod(_clock * 90.0, maxf(size.y, 1.0))
	draw_line(Vector2(0.0, sweep), Vector2(size.x, sweep), Color(0.25, 1.0, 0.58, 0.05))
	_draw_streams(intro)
	var door := _door_rect(intro)
	_draw_door(door, intro)
	_draw_door_text(door, intro)
	_draw_corner_readouts()


func _draw_streams(intro: float) -> void:
	if _streams.is_empty():
		return
	var stream_font := _font
	for index in _streams.size():
		var stream: Dictionary = _streams[index]
		var x := float(stream["x"])
		var head := float(stream["head"])
		var length := int(stream["length"])
		var cell := float(stream["cell"])
		var brightness := float(stream["bright"])
		var phase := float(stream["phase"])
		for row in length:
			var y := head - float(row) * cell
			if y < -cell or y > size.y + cell:
				continue
			var fade := clampf(1.0 - float(row) / maxf(1.0, float(length)), 0.0, 1.0)
			var flicker := 0.78 + 0.22 * sin(_clock * 9.0 + phase + float(row) * 1.9)
			var alpha := clampf(fade * flicker * brightness * 0.85, 0.0, 1.0)
			if row == 0:
				alpha = clampf(brightness, 0.0, 1.0)
			var color := DIGIT_BRIGHT if row == 0 else DIGIT_GREEN
			var position := Vector2(x - 5.0, y)
			if row < 3:
				draw_string_outline(stream_font, position, _glyph(index, row), HORIZONTAL_ALIGNMENT_CENTER, 10, 14, 2, Color(DIGIT_GREEN, alpha * 0.14))
			draw_string(stream_font, position, _glyph(index, row), HORIZONTAL_ALIGNMENT_CENTER, 10, 14, Color(color, alpha * (0.35 + 0.65 * intro)))


func _draw_door(door: Rect2, intro: float) -> void:
	var centre := door.get_center()
	# Halo first, so the frame reads as a lit aperture in the rain.
	for ring in range(3, 0, -1):
		var grow := float(ring) * 5.0
		draw_rect(door.grow(grow), Color(DIGIT_GREEN, 0.045 * intro * float(4 - ring) * 0.5), false, 1.0)
	draw_rect(door, Color(DIGIT_DEEP, 0.86 * intro))
	var fill_top := door.position.y + door.size.y * (1.0 - (0.22 + 0.66 * _load_progress))
	var filled := Rect2(Vector2(door.position.x, fill_top), Vector2(door.size.x, door.end.y - fill_top))
	if filled.size.y > 0.5:
		draw_rect(filled, Color(DIGIT_MID, 0.20))
		# Code inside the aperture: rows of glyphs scroll upward as it fills.
		var rows := int(filled.size.y / 16.0)
		var columns := int(door.size.x / 13.0)
		for row in mini(rows, 34):
			var y := filled.end.y - float(row) * 16.0
			if y < filled.position.y:
				break
			var alpha := clampf(1.0 - float(row) / maxf(1.0, float(mini(rows, 34))), 0.15, 1.0)
			for column in mini(columns, 40):
				var glyph := _glyph(row * 41 + column, int(_clock * 6.0) + column)
				var x := door.position.x + 6.0 + float(column) * 13.0
				draw_string(_font, Vector2(x, y), glyph, HORIZONTAL_ALIGNMENT_LEFT, 10, 11, Color(DIGIT_GREEN, 0.42 * alpha * intro))
		draw_line(Vector2(door.position.x, fill_top), Vector2(door.end.x, fill_top), Color(DIGIT_BRIGHT, (0.55 + 0.35 * sin(_clock * 12.0)) * intro), 1.6)
	# Frame, corner brackets and the rotating scan ring.
	draw_rect(door, Color(DIGIT_GREEN, 0.92 * intro), false, 2.0)
	var arm := minf(door.size.x, door.size.y) * 0.10
	for corner in range(4):
		var origin := door.position
		var sx := 1.0
		var sy := 1.0
		if corner & 1:
			origin.x = door.end.x
			sx = -1.0
		if corner & 2:
			origin.y = door.end.y
			sy = -1.0
		draw_line(origin, origin + Vector2(arm * sx, 0.0), Color(DIGIT_BRIGHT, 0.9 * intro), 2.0)
		draw_line(origin, origin + Vector2(0.0, arm * sy), Color(DIGIT_BRIGHT, 0.9 * intro), 2.0)
	var ring_radius := door.size.y * 0.46
	draw_arc(centre, ring_radius, _clock * 2.1, _clock * 2.1 + 1.5, 28, Color(DIGIT_GREEN, 0.55 * intro), 1.4, true)
	draw_arc(centre, ring_radius * 0.86, -_clock * 1.5, -_clock * 1.5 + 0.9, 20, Color(DIGIT_GREEN, 0.30 * intro), 1.0, true)


func _draw_door_text(door: Rect2, intro: float) -> void:
	var title_size := clampi(int(size.y * 0.038), 12, 30)
	draw_string_outline(_font, Vector2(0.0, door.position.y - 34.0), _digital_title, HORIZONTAL_ALIGNMENT_CENTER, size.x, title_size, 6, Color(0.0, 0.06, 0.03, 0.75 * intro))
	draw_string(_font, Vector2(0.0, door.position.y - 34.0), _digital_title, HORIZONTAL_ALIGNMENT_CENTER, size.x, title_size, Color(DIGIT_BRIGHT, intro))
	var latin_size := clampi(int(size.y * 0.020), 8, 15)
	draw_string(_font, Vector2(0.0, door.position.y - 14.0), _digital_latin, HORIZONTAL_ALIGNMENT_CENTER, size.x, latin_size, Color(DIGIT_MID, 0.85 * intro))
	# Progress rail under the door.
	var rail := Rect2(door.position.x, door.end.y + 30.0, door.size.x, 6.0)
	draw_rect(rail, Color(DIGIT_DEEP, 0.85 * intro))
	draw_rect(Rect2(rail.position, Vector2(rail.size.x * _load_progress, rail.size.y)), Color(DIGIT_MID, 0.85 * intro))
	var head_x := rail.position.x + rail.size.x * _load_progress
	draw_rect(Rect2(head_x - 1.5, rail.position.y - 3.0, 3.0, rail.size.y + 6.0), Color(DIGIT_BRIGHT, 0.95 * intro))
	var status := ""
	if _load_ready:
		status = "同步完成 · 进入 %s" % _digital_target
	else:
		status = "%s  %d%%" % [_digital_target, roundi(_load_progress * 100.0)]
	var status_size := clampi(int(size.y * 0.026), 10, 19)
	var status_alpha := intro
	if _load_ready:
		status_alpha = (0.75 + 0.25 * sin(_clock * 6.0)) * intro
	draw_string(_font, Vector2(0.0, rail.end.y + 24.0), status, HORIZONTAL_ALIGNMENT_CENTER, size.x, status_size, Color(DIGIT_BRIGHT, status_alpha))
	var hint := _hint
	var hint_width := _font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, latin_size).x
	draw_string(_font, Vector2(size.x - 28.0 - hint_width, size.y - 22.0), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, latin_size, Color(CAPTION_COLOR, 0.6 * intro))


func _draw_corner_readouts() -> void:
	var text_size := clampi(int(size.y * 0.019), 8, 14)
	var hex := "0x%08X" % (int(_clock * 733.0) & 0xffffffff)
	var lines := ["NEURO-FAULT // UPLINK", "SHOP GATE %s" % hex, "DEPTH %d" % (1 + int(_load_progress * 2.0))]
	for index in lines.size():
		draw_string(_font, Vector2(24.0, 30.0 + float(index) * (float(text_size) + 4.0)), lines[index], HORIZONTAL_ALIGNMENT_LEFT, -1, text_size, Color(DIGIT_MID, 0.55))
	var right := "链接 %d%%" % roundi(_load_progress * 100.0)
	var right_width := _font.get_string_size(right, HORIZONTAL_ALIGNMENT_LEFT, -1, text_size).x
	draw_string(_font, Vector2(size.x - 24.0 - right_width, 30.0), right, HORIZONTAL_ALIGNMENT_LEFT, -1, text_size, Color(DIGIT_GREEN, 0.7))


func _draw_cover() -> void:
	var grow := _ease_in(_cover)
	var door := _door_rect(1.0)
	var rect := Rect2(
		lerpf(door.position.x, -2.0, grow),
		lerpf(door.position.y, -2.0, grow),
		lerpf(door.size.x, size.x + 4.0, grow),
		lerpf(door.size.y, size.y + 4.0, grow)
	)
	draw_rect(rect, Color(DIGIT_BRIGHT, clampf(_cover * 1.15, 0.0, 1.0)))
	draw_rect(rect, Color(DIGIT_GREEN, 0.55 * _cover), false, 3.0)


func _ease_out(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return 1.0 - (1.0 - t) * (1.0 - t)


func _ease_in(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t
