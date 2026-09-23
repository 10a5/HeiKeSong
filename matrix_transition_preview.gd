extends Control
## 数字雨转场的独立预览场景。
##
## 直接运行 `matrix_transition_preview.tscn` 即可查看效果。数字雨会在
## 淡出后自动重新播放；按空格可以立即重播，按 Esc 退出预览。

const MATRIX_TRANSITION := preload("res://matrix_transition.gd")

@export var fade_in_duration := 0.24
@export var hold_duration := 5.0
@export var fade_out_duration := 0.34
@export var gap_duration := 0.18

var _matrix: Control
var _replay_token := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	focus_mode = Control.FOCUS_ALL
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	grab_focus()
	resized.connect(queue_redraw)

	_matrix = MATRIX_TRANSITION.new()
	_matrix.name = "MatrixTransition"
	add_child(_matrix)
	_matrix.finished.connect(_on_matrix_finished)
	call_deferred("_play_once")


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color.BLACK)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			_replay_token += 1
			_play_once()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE:
			get_tree().quit()


func _play_once() -> void:
	if not is_instance_valid(_matrix):
		return
	_matrix.play_transition(fade_in_duration, hold_duration, fade_out_duration)


func _on_matrix_finished() -> void:
	# 等待一个很短的间隔，让淡出和下一轮淡入之间保持干净的黑场。
	var token := _replay_token
	if gap_duration <= 0.0:
		_play_once()
		return
	await get_tree().create_timer(gap_duration).timeout
	if is_instance_valid(_matrix) and token == _replay_token:
		_play_once()
