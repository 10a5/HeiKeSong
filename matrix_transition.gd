extends Control
## 全屏绿色数字雨转场效果。
##
## 组件默认隐藏，可以直接作为 CanvasLayer 的子节点使用：
##
##     var transition := preload("res://matrix_transition.gd").new()
##     canvas_layer.add_child(transition)
##     transition.play_transition()
##
## `finished` 会在淡出完成后发出。组件使用 `_draw()` 绘制，不依赖额外
## 纹理或字体资源；它的鼠标过滤始终为 IGNORE，不会挡住游戏 HUD。

signal finished
signal covered

const FALLBACK_FONT_SIZE := 18
const MIN_COLUMN_WIDTH := 16.0
const MIN_STREAM_LENGTH := 10
const MAX_STREAM_LENGTH := 28
const MATRIX_GREEN := Color("36ff65")
const MATRIX_BRIGHT := Color("d3ffde")

enum Phase {
	IDLE,
	FADE_IN,
	HOLD,
	FADE_OUT,
}

@export_range(8, 48, 1) var font_size := FALLBACK_FONT_SIZE
@export_range(16.0, 60.0, 1.0) var column_width := 21.0
@export_range(20.0, 600.0, 1.0) var stream_speed := 150.0
@export_range(0.0, 1.0) var trail_alpha := 0.9
@export_range(0.0, 1.0) var background_alpha := 1.0
@export_range(0.0, 0.25) var scanline_alpha := 0.045
@export_range(0.0, 3.0) var jitter_amount := 0.25

var _font: Font
var _rng := RandomNumberGenerator.new()
var _phase := Phase.IDLE
var _phase_time := 0.0
var _fade_in_duration := 0.24
var _hold_duration := 0.85
var _fade_out_duration := 0.34
var _fade_out_start_opacity := 1.0
var _auto_fade_out := true
var _opacity := 0.0
var _elapsed := 0.0
var _streams: Array[Dictionary] = []
var _columns := 0
var _last_size := Vector2.ZERO


func _ready() -> void:
	# 转场应在暂停界面或场景切换期间继续播放。
	process_mode = Node.PROCESS_MODE_ALWAYS
	# The map overlay is a sibling of HUD. Keep the effect above it too.
	z_index = 100
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rng.randomize()
	_font = ThemeDB.fallback_font
	_last_size = size
	_rebuild_streams()
	_phase = Phase.IDLE
	_opacity = 0.0
	hide()
	set_process(false)
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and size != _last_size:
		_last_size = size
		_rebuild_streams()
		queue_redraw()


## 播放完整转场：淡入数字雨，保持遮罩一段时间，再淡出并发出 finished。
func play_transition(
	fade_in_duration: float = 0.24,
	hold_duration: float = 0.85,
	fade_out_duration: float = 0.34
) -> void:
	_fade_in_duration = maxf(0.01, fade_in_duration)
	_hold_duration = maxf(0.0, hold_duration)
	_fade_out_duration = maxf(0.01, fade_out_duration)
	_auto_fade_out = true
	_rebuild_streams()
	_elapsed = 0.0
	_phase_time = 0.0
	_opacity = 0.0
	_phase = Phase.FADE_IN
	show()
	set_process(true)
	queue_redraw()


## `play()` 是给外部调用的简短别名。
func play(
	fade_in_duration: float = 0.24,
	hold_duration: float = 0.85,
	fade_out_duration: float = 0.34
) -> void:
	play_transition(fade_in_duration, hold_duration, fade_out_duration)


## 只播放淡入，完成后保持遮罩，直到调用 play_out() 或 stop()。
func play_in(duration: float = 0.24) -> void:
	_fade_in_duration = maxf(0.01, duration)
	_auto_fade_out = false
	_phase_time = 0.0
	_opacity = 0.0
	_phase = Phase.FADE_IN
	show()
	set_process(true)
	queue_redraw()


## 只播放淡出。完成后隐藏并发出 finished。
func play_out(duration: float = 0.34) -> void:
	_fade_out_duration = maxf(0.01, duration)
	_fade_out_start_opacity = _opacity
	_phase_time = 0.0
	_phase = Phase.FADE_OUT
	show()
	set_process(true)
	queue_redraw()


func stop() -> void:
	_phase = Phase.IDLE
	_opacity = 0.0
	hide()
	set_process(false)
	queue_redraw()


func is_playing() -> bool:
	return _phase != Phase.IDLE


func _process(delta: float) -> void:
	_elapsed += delta
	_phase_time += delta
	for stream in _streams:
		stream["head"] = float(stream["head"]) + float(stream["speed"]) * delta
		# 让每一列循环经过屏幕后重新开始，避免创建和销毁节点。
		if float(stream["head"]) - float(stream["length"]) * float(stream["cell_height"]) > size.y + 32.0:
			stream["head"] = -_rng.randf_range(0.0, size.y * 0.12)
			stream["speed"] = stream_speed * float(stream["depth_speed"]) * _rng.randf_range(0.65, 1.35)
			stream["length"] = _rng.randi_range(MIN_STREAM_LENGTH, MAX_STREAM_LENGTH)

	match _phase:
		Phase.FADE_IN:
			_opacity = _ease_out(_phase_time / _fade_in_duration)
			if _phase_time >= _fade_in_duration:
				_opacity = 1.0
				_phase_time = 0.0
				_phase = Phase.HOLD
				covered.emit()
		Phase.HOLD:
			_opacity = 1.0
			if _auto_fade_out and _phase_time >= _hold_duration:
				_phase_time = 0.0
				_fade_out_start_opacity = _opacity
				_phase = Phase.FADE_OUT
		Phase.FADE_OUT:
			_opacity = _fade_out_start_opacity * (1.0 - _ease_in(_phase_time / _fade_out_duration))
			if _phase_time >= _fade_out_duration:
				_opacity = 0.0
				_phase = Phase.IDLE
				hide()
				set_process(false)
				finished.emit()

	queue_redraw()


func _rebuild_streams() -> void:
	if size.x <= 1.0 or size.y <= 1.0:
		return
	_streams.clear()
	# Two scales give the rain depth. Pre-fill the viewport so even a one-second
	# transition has digits across the whole screen immediately.
	for layer in 2:
		var far_layer := layer == 0
		var spacing := maxf(MIN_COLUMN_WIDTH, column_width) * (0.72 if far_layer else 1.0)
		var columns := clampi(ceili(size.x / spacing), 1, 160)
		var glyph_size := maxi(8, roundi(float(font_size) * (0.64 if far_layer else 1.0)))
		var cell_height := float(glyph_size) * 1.18
		var speed_factor := 0.45 if far_layer else 1.0
		for i in columns:
			var length := _rng.randi_range(MIN_STREAM_LENGTH, MAX_STREAM_LENGTH)
			_streams.append({
				"x": (float(i) + (0.25 if far_layer else 0.5)) * size.x / float(columns),
				"head": _rng.randf_range(0.0, size.y + float(length) * cell_height * 0.55),
				"speed": stream_speed * speed_factor * _rng.randf_range(0.65, 1.35),
				"depth_speed": speed_factor,
				"brightness": _rng.randf_range(0.16, 0.28) if far_layer else _rng.randf_range(0.64, 1.0),
				"far": far_layer,
				"length": length,
				"font_size": glyph_size,
				"cell_height": cell_height,
				"phase": _rng.randf_range(0.0, TAU),
			})
	_columns = _streams.size()


func _draw() -> void:
	if not visible or _opacity <= 0.001:
		return
	var overlay_alpha := clampf(background_alpha * _opacity, 0.0, 1.0)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.001, 0.007, 0.003, overlay_alpha))
	if _streams.is_empty():
		return
	var text_font := _font if _font != null else ThemeDB.fallback_font
	for stream_index in _streams.size():
		var stream: Dictionary = _streams[stream_index]
		var head := float(stream["head"])
		var length := int(stream["length"])
		var x := float(stream["x"])
		var phase := float(stream["phase"])
		var cell_height := float(stream["cell_height"])
		var glyph_size := int(stream["font_size"])
		var brightness := float(stream["brightness"])
		var far_layer := bool(stream["far"])
		for row in length:
			var y := head - float(row) * cell_height
			if y < -cell_height or y > size.y + cell_height:
				continue
			var fade := 1.0 - float(row) / maxf(1.0, float(length))
			fade = clampf(fade, 0.0, 1.0)
			var flicker := 0.8 + 0.2 * sin(_elapsed * 8.0 + phase + float(row) * 1.7)
			var alpha := clampf(fade * flicker * trail_alpha * brightness * _opacity, 0.0, 1.0)
			if row == 0:
				alpha = clampf(brightness * _opacity, 0.0, 1.0)
			var glyph := _glyph(stream_index, row)
			var color := MATRIX_GREEN
			if row == 0 and not far_layer:
				color = MATRIX_BRIGHT
			var jitter := sin(_elapsed * 11.0 + phase + float(row)) * jitter_amount
			var glyph_position := Vector2(x - float(glyph_size) * 0.5 + jitter, y)
			# Small, local halos work in Compatibility without a full-screen glow pass.
			if not far_layer and row < 3:
				draw_string_outline(text_font, glyph_position, glyph, HORIZONTAL_ALIGNMENT_CENTER, glyph_size, glyph_size, 2, Color(MATRIX_GREEN, alpha * 0.13))
			draw_string(text_font, glyph_position, glyph, HORIZONTAL_ALIGNMENT_CENTER, glyph_size, glyph_size, Color(color, alpha))

	# 轻微扫描纹理，不用全屏白闪。
	for y in range(0, int(size.y), 4):
		draw_line(Vector2(0, y), Vector2(size.x, y), Color(0, 0, 0, 0.11 * _opacity), 1.0)
	var scan_y := fmod(_elapsed * 74.0, maxf(size.y, 1.0))
	draw_line(Vector2(0.0, scan_y), Vector2(size.x, scan_y), Color(0.2, 1.0, 0.56, scanline_alpha * _opacity), 1.0)
	draw_line(Vector2(0.0, scan_y + 1.0), Vector2(size.x, scan_y + 1.0), Color(0.1, 0.8, 0.36, scanline_alpha * 0.42 * _opacity), 1.0)


func _glyph(stream_index: int, row: int) -> String:
	# 使用稳定的整数哈希让字符在每帧保持可读的随机闪动。
	var bucket := int(floor(_elapsed * 8.0 + float(stream_index % 7) * 0.31))
	var hash_value := stream_index * 92821 + row * 68917 + bucket * 31337
	hash_value = ((hash_value ^ (hash_value >> 7)) * 16807) & 0x7fffffff
	return str(hash_value % 10)


func _ease_in(value: float) -> float:
	return clampf(value, 0.0, 1.0) * clampf(value, 0.0, 1.0)


func _ease_out(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return 1.0 - (1.0 - t) * (1.0 - t)
