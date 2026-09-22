extends Node3D
## Runtime helper for the standalone character animation workspace.
## The actual authoring workflow uses Godot's native Skeleton3D and AnimationPlayer
## editors; this script only makes the preview scene pleasant to inspect.

@export var orbit_distance := 4.2
@export var orbit_height := 1.2
@export var camera_smooth := 8.0

@onready var character_pivot: Node3D = $CharacterPivot
@onready var camera_rig: Node3D = $CameraRig
@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var animation_player: AnimationPlayer = $CharacterPivot/CharacterRig/AnimationPlayer

var _yaw := 0.0
var _pitch := -0.08
var _dragging := false

func _ready() -> void:
	camera.current = true
	camera_rig.position = Vector3(0.0, orbit_height, orbit_distance)
	_update_camera_transform(1.0)

func _process(delta: float) -> void:
	if Input.is_action_just_pressed("lab_reset_camera"):
		_yaw = 0.0
		_pitch = -0.08
		_update_camera_transform(1.0)
	if Input.is_action_just_pressed("lab_play_preview"):
		if animation_player.is_playing():
			animation_player.stop()
		else:
			animation_player.play("idle_template")
	if Input.is_action_just_pressed("lab_save_pose"):
		print("Pose authoring note: use AnimationPlayer's key icon to insert a keyframe, then save the scene or AnimationLibrary to res://exports/.")
	if not _dragging:
		_update_camera_transform(delta * camera_smooth)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
	elif event is InputEventMouseMotion and _dragging:
		_yaw -= event.relative.x * 0.008
		_pitch = clampf(_pitch - event.relative.y * 0.006, -0.7, 0.55)
		_update_camera_transform(1.0)

func _update_camera_transform(weight: float) -> void:
	var target := Vector3(0.0, orbit_height, 0.0)
	var desired_pos := target + Vector3(
		sin(_yaw) * cos(_pitch) * orbit_distance,
		sin(_pitch) * orbit_distance,
		cos(_yaw) * cos(_pitch) * orbit_distance
	)
	camera_rig.position = camera_rig.position.lerp(desired_pos, clampf(weight, 0.0, 1.0))
	camera_rig.look_at(target, Vector3.UP)
