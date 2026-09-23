extends Node3D
## Plays the sniper's clips one after another so the assembly can be eyeballed
## without wiring anything up.
##
## The camera tracks the rig's hips rather than sitting still, because
## `shoot_001` carries root motion: the sniper walks a couple of metres and
## drops prone inside the clip.  Without a tracking camera the character walks
## out of frame, which is exactly the surprise this scene exists to surface.
##
## Controls:  N next clip · R restart clip · Space pause · Esc release mouse

@export var character_path: NodePath
@export var camera_path: NodePath
@export var label_path: NodePath
## Clips are shown in this order; empty means "every clip on the character".
@export var clips: PackedStringArray = PackedStringArray()
## Seconds each clip is shown before advancing (0 = play to the end).
@export var seconds_per_clip := 4.0
## Camera offset from the hips, in world space.
@export var camera_offset := Vector3(2.1, 1.15, 2.1)
@export var camera_look_offset := Vector3(0.0, 0.30, 0.0)
@export var camera_lerp := 6.0

@export var hips_bone: StringName = &"mixamorig_Hips"

var _player: AnimationPlayer
var _skeleton: Skeleton3D
var _hips := -1
var _order: PackedStringArray = PackedStringArray()
var _index := 0
var _elapsed := 0.0
var _paused := false


func _ready() -> void:
	var character := get_node_or_null(character_path)
	if character == null:
		push_error("Showcase: no character at %s" % character_path)
		return
	_skeleton = _find_skeleton(character)
	_player = _find_anim_player(character)
	if _player == null:
		push_error("Showcase: the character has no AnimationPlayer")
		return
	if _skeleton != null:
		_hips = _skeleton.find_bone(hips_bone)

	_order = clips
	if _order.is_empty():
		for lib_name in _player.get_animation_library_list():
			var lib := _player.get_animation_library(lib_name)
			for anim_name in lib.get_animation_list():
				_order.append(String(anim_name))
	_play(0)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not (event as InputEventKey).pressed:
		return
	match (event as InputEventKey).keycode:
		KEY_N:
			_play((_index + 1) % maxi(_order.size(), 1))
		KEY_R:
			_play(_index)
		KEY_SPACE:
			_paused = not _paused
			_player.speed_scale = 0.0 if _paused else 1.0
		KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _process(delta: float) -> void:
	if _player == null:
		return
	_elapsed += delta
	var length: float = _player.current_animation_length
	var limit := seconds_per_clip if seconds_per_clip > 0.0 else length
	if _elapsed >= limit and _player.current_animation_position >= length - 0.05:
		_play((_index + 1) % maxi(_order.size(), 1))
	_update_camera(delta)
	_update_label()


func _play(index: int) -> void:
	if _order.is_empty():
		return
	_index = index
	_elapsed = 0.0
	_player.play(_order[_index])


func _update_camera(delta: float) -> void:
	var camera := get_node_or_null(camera_path) as Camera3D
	if camera == null:
		return
	var focus := global_position
	if _skeleton != null and _hips >= 0:
		focus = (_skeleton.global_transform * _skeleton.get_bone_global_pose(_hips)).origin
	var weight := clampf(camera_lerp * delta, 0.0, 1.0)
	camera.global_position = camera.global_position.lerp(focus + camera_offset, weight)
	camera.look_at(focus + camera_look_offset, Vector3.UP)


func _update_label() -> void:
	var label := get_node_or_null(label_path) as Label
	if label == null:
		return
	label.text = "%s  (%d/%d)   [N] next   [R] restart   [Space] pause" % [
		_player.current_animation, _index + 1, _order.size()]


static func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null


static func _find_anim_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var found := _find_anim_player(child)
		if found != null:
			return found
	return null
