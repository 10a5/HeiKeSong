extends Node3D
## The Boss-victory ending: the duel arena collapses into water, 素子 sinks, the
## camera cuts to an overhead shot of 雾子 floating on the surface under a quote,
## and a digital shop gate covers the switch to the next floor while that floor
## loads on a worker thread.
##
## The floor pauses the tree before handing control here, so every node this
## director adds runs with `PROCESS_MODE_ALWAYS` and is animated explicitly: no
## physics, no timers and no awaits on gameplay nodes. The whole sequence is
## therefore reproducible in a window, in a headless test, and after a
## mid-cinematic `R`; `finish_now()` resolves it without waiting for wall-clock
## time.
##
##     var ending := FLOOR_ENDING.new()
##     floor.add_child(ending)
##     ending.completed.connect(_on_ending_completed)
##     ending.setup({"floor": self, "arena": boss_arena, ...})
##     ending.start()

## Emitted once the digital gate has covered the screen and the run may move on.
signal completed

const OVERLAY = preload("res://ending_overlay.gd")
const WATER_SHADER = preload("res://materials/boss_water.gdshader")
const CHARACTER_VISUAL = preload("res://character_visual.gd")

const STAGE_COLLAPSE: StringName = &"collapse"
const STAGE_SUBMERGE: StringName = &"submerge"
const STAGE_MIRROR: StringName = &"mirror"
const STAGE_DIGITAL: StringName = &"digital"
const STAGE_DONE: StringName = &"done"

## 攻壳机动队式的镜面台词：打赢镜像 Boss 之后，镜中人就是自己。
const QUOTE := "你我犹如隔镜视物，所见无非虚幻迷蒙"
const RIPPLE_CAPACITY := 16
const RIPPLE_LIFETIME := 2.2
const GRAVITY := 22.0
const DEBRIS_COUNT := 22
## Floor plates that shear off the duel floor around 素子.
const SLAB_COUNT := 9
## Depth of the basin the duel floor collapses into. The water is authored below
## the arena rather than on it, so 素子 visibly falls into it.
const BASIN_DEPTH := 9.0
## How far the arena settles below its authored position: far enough that the
## whole duel floor ends up under the surface.
const SINK_DEPTH := 26.0
## How far 素子 keeps sinking after she breaks the surface.
const PLAYER_SINK := 19.0

@export_group("Timing")
@export var collapse_duration := 2.9
@export var submerge_duration := 2.1
@export var mirror_hold := 5.8
@export var mirror_fade_in := 1.7
@export var digital_min_duration := 2.5
## Failsafe: the gate opens even if the threaded load never reports success, so
## a cinematic can never strand the player in front of a progress bar.
@export var digital_timeout := 14.0
## Hold used when the player skips the collapse with any key.
@export var skip_mirror_hold := 2.0

var _floor: Node
var _arena: Node3D
var _arena_model: Node3D
var _arena_water: Node3D
var _player: CharacterBody3D
var _boss: Node3D
var _camera: Camera3D
var _overlay: Control
var _hud: Control

var _water: MeshInstance3D
var _water_material: ShaderMaterial
var _ripples := PackedVector4Array()
var _next_ripple := 0
var _wave_time := 0.0
var _debris: Array[Dictionary] = []
var _mirror_holder: Node3D
var _mirror_visual: Node3D
var _mirror_ripple_clock := 0.0
var _stage_light: OmniLight3D

var _stage: StringName = STAGE_COLLAPSE
var _stage_time := 0.0
var _elapsed := 0.0
var _hold_left := 0.0
var _finished := false
var _started := false

var _floor_surface := Vector3.ZERO
var _arena_bounds := AABB()
var _flood_y := 0.0
var _arena_start_position := Vector3.ZERO
var _arena_start_rotation := Vector3.ZERO
var _player_start := Vector3.ZERO
var _player_entry_y := 0.0
var _boss_start := Vector3.ZERO
var _splash_done := false
var _arena_splash_done := false
var _shake := 1.0
var _camera_height := 12.2
var _camera_fov := 48.0
var _environment_snapshot: Dictionary = {}
var _light_snapshots: Array[Dictionary] = []
var _hud_was_visible := true
var _city_overlay: Control
var _city_overlay_was_visible := true

var _next_scene := ""
var _digital_target := ""
var _load_requested := false
var _load_ready := false
var _load_progress := 0.0
var _cover_requested := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


## Wires the director to the live floor. Must be called before `start()`.
func setup(context: Dictionary) -> void:
	_floor = context.get("floor")
	_arena = context.get("arena")
	_player = context.get("player")
	_boss = context.get("boss")
	_camera = context.get("camera")
	_hud = context.get("hud")
	_next_scene = str(context.get("next_scene", ""))
	_digital_target = str(context.get("next_title", ""))
	if _arena != null:
		_arena_model = _arena.get("arena") as Node3D
		_arena_water = _arena.get("water") as Node3D
	var canvas := context.get("canvas") as CanvasLayer
	_overlay = OVERLAY.new()
	_overlay.name = "EndingOverlay"
	if canvas != null:
		canvas.add_child(_overlay)
	else:
		add_child(_overlay)
	_overlay.digital_covered.connect(_on_digital_covered)


## Starts the sequence. The caller owns the pause: the tree is expected to be
## paused already so gameplay nodes hold still while this director animates.
func start() -> void:
	if _started or _player == null or _camera == null:
		return
	_started = true
	_floor_surface = _player.global_position
	# The basin sits below the duel floor, so the collapse drops the arena, the
	# debris and 素子 through the surface one after another.
	_flood_y = _floor_surface.y - BASIN_DEPTH
	_player_start = _player.global_position
	_boss_start = _boss.global_position if is_instance_valid(_boss) else Vector3.ZERO
	if _arena_model != null:
		_arena_start_position = _arena_model.position
		_arena_start_rotation = _arena_model.rotation_degrees
	_capture_environment()
	_apply_cinematic_environment()
	_measure_arena()
	# A slightly long lens flattens the overhead shot into a readable plate and
	# keeps the collapse from showing the whole district behind the arena.
	_camera_fov = _camera.fov
	_camera.fov = 38.0
	if _hud != null:
		_hud_was_visible = _hud.visible
		_hud.visible = false
	# The city overlay (minimap, credit line) is a sibling of the HUD inside the
	# same CanvasLayer, so hiding the HUD alone would leave it over the water.
	_city_overlay = _floor.get("city_overlay") as Control
	if _city_overlay != null:
		_city_overlay_was_visible = _city_overlay.visible
		_city_overlay.visible = false
	_build_flood()
	_build_debris()
	_build_mirror()
	_build_stage_light()
	if _arena_water != null:
		_arena_water.visible = false
	_overlay.begin_show("断层 · 水面", "任意键 跳过")
	_enter_stage(STAGE_COLLAPSE)


## The stage currently playing: `collapse`, `submerge`, `mirror`, `digital` or
## `done`. Read by the tests and the capture tool.
func stage() -> StringName:
	return _stage


# ------------------------------------------------------------------ skip hooks

## Any key or click during the cinematic: the collapse is the only part worth
## cutting short, since the quote and the gate are the payoff.
func skip() -> void:
	if _finished or not _started:
		return
	match _stage:
		STAGE_COLLAPSE, STAGE_SUBMERGE:
			_enter_stage(STAGE_MIRROR)
			_hold_left = minf(_hold_left, skip_mirror_hold)
			_overlay.show_quote(QUOTE, maxf(0.15, _hold_left - mirror_fade_in * 0.5))
		STAGE_MIRROR:
			_hold_left = 0.0
		STAGE_DIGITAL:
			_cover_digital()


## Test/CI hook: jump straight to the gate and let it cover the screen. Keeps
## the headless suite from simulating twenty seconds of drifting water.
func finish_now() -> void:
	if _finished or not _started:
		return
	if _stage != STAGE_DIGITAL:
		_enter_stage(STAGE_DIGITAL)
	_cover_digital()


## Undoes every change this director made to the floor and frees its staging.
## Called by the floor when a retry interrupts the cinematic.
func restore() -> void:
	_finished = true
	_restore_environment()
	if is_instance_valid(_player):
		_player.rotation_degrees = Vector3.ZERO
	if is_instance_valid(_camera):
		_camera.fov = _camera_fov
	if is_instance_valid(_arena_model):
		_arena_model.position = _arena_start_position
		_arena_model.rotation_degrees = _arena_start_rotation
	if is_instance_valid(_arena_water):
		_arena_water.visible = true
	if is_instance_valid(_boss):
		# The mirror sinks with the plate during the ending; a resumed arena needs
		# its floor, its corpse and its shallow water back where they were.
		_boss.global_position = _boss_start
		_boss.rotation_degrees = Vector3.ZERO
	if is_instance_valid(_hud):
		_hud.visible = _hud_was_visible
	if is_instance_valid(_city_overlay):
		_city_overlay.visible = _city_overlay_was_visible
	if is_instance_valid(_overlay):
		_overlay.reset()
		_overlay.queue_free()
		_overlay = null
	set_process(false)


# ------------------------------------------------------------------- lifecycle

func _process(delta: float) -> void:
	if _finished:
		return
	_elapsed += delta
	_stage_time += delta
	_wave_time += delta
	_advance_ripples(delta)
	match _stage:
		STAGE_COLLAPSE:
			_process_collapse(delta)
		STAGE_SUBMERGE:
			_process_submerge(delta)
		STAGE_MIRROR:
			_process_mirror(delta)
		STAGE_DIGITAL:
			_process_digital(delta)
	_upload_water()


func _enter_stage(stage: StringName) -> void:
	_stage = stage
	_stage_time = 0.0
	match stage:
		STAGE_COLLAPSE:
			_apply_limp_pose()
		STAGE_SUBMERGE:
			_player_entry_y = _player.global_position.y
		STAGE_MIRROR:
			_hold_left = mirror_hold
			_cut_to_overhead()
			_overlay.set_dim(0.20)
			_overlay.show_quote(QUOTE, maxf(0.2, _hold_left - mirror_fade_in * 2.0))
		STAGE_DIGITAL:
			_overlay.set_dim(1.0)
			_overlay.start_digital("接入商店协议", "SHOP UPLINK // 神经断层", _digital_target)
			_poll_load()


func _process_collapse(delta: float) -> void:
	var progress := clampf(_stage_time / maxf(0.01, collapse_duration), 0.0, 1.0)
	# The authored floor gives way as one plate: it keeps its tilt, gains a roll
	# and falls toward the basin below.
	_sink_arena(_ease_in_out(progress) * SINK_DEPTH * 0.55, 20.0 * progress)
	_update_debris(delta)
	# 素子 topples back as the floor goes, then drops into the dark with it.
	var topple := clampf((_stage_time - 0.45) / 0.9, 0.0, 1.0)
	var drop := clampf((_stage_time - 1.15) / maxf(0.2, collapse_duration - 1.15), 0.0, 1.0)
	_player.rotation_degrees = Vector3(-84.0 * topple, 10.0 * topple, 16.0 * topple)
	_player.global_position = _player_start + Vector3(0.0, -6.4 * _ease_in(drop), 0.0) \
		+ Vector3(sin(_stage_time * 1.4) * 0.25, 0.0, cos(_stage_time * 1.2) * 0.2) * topple
	_frame_fall_camera(
		(_player.global_position + Vector3(0.0, 1.2, 0.0)).lerp(
			Vector3(_floor_surface.x, _floor_surface.y - 1.0, _floor_surface.z), 0.28),
		Vector3(3.6, 3.2, -8.6), 1.0, _flood_y + 3.0)
	_overlay.set_dim(0.24 + 0.20 * progress)
	if progress >= 1.0:
		_enter_stage(STAGE_SUBMERGE)


func _process_submerge(delta: float) -> void:
	var progress := clampf(_stage_time / maxf(0.01, submerge_duration), 0.0, 1.0)
	_sink_arena(SINK_DEPTH * 0.55 + _ease_in(progress) * SINK_DEPTH * 0.45, 20.0 + 12.0 * progress)
	_update_debris(delta)
	var fall := _ease_in(progress)
	_player.global_position = Vector3(
		_player_start.x + sin(_stage_time * 0.9) * 0.4,
		lerpf(_player_entry_y, _flood_y - PLAYER_SINK, fall),
		_player_start.z + cos(_stage_time * 0.8) * 0.35
	)
	_player.rotation_degrees = Vector3(-84.0, 10.0 + 26.0 * progress, 16.0 + 34.0 * progress)
	# The surface breaks once; after that the camera keeps watching the hole she
	# made while the water and the darkening take the body.
	if not _splash_done and _player.global_position.y <= _flood_y:
		_splash_done = true
		_splash(Vector3(_player.global_position.x, _flood_y, _player.global_position.z), 1.6)
		_splash(Vector3(_player.global_position.x + 0.5, _flood_y, _player.global_position.z - 0.4), 1.1)
		_shake = maxf(_shake, 0.7)
	_shake = maxf(0.0, _shake - delta * 0.55)
	# Past the splash the camera holds on the hole she made instead of chasing
	# her down: the expanding rings are the last thing on screen before the cut.
	var entry := Vector3(_player_start.x, _flood_y, _player_start.z)
	var focus := (_player.global_position + Vector3(0.0, 0.9, 0.0)).lerp(entry, clampf(progress * 1.4, 0.0, 1.0))
	_frame_fall_camera(focus, Vector3(3.0, 3.0, -7.0), 1.0 - progress * 0.55, _flood_y + 4.0)
	_overlay.set_dim(0.44 + 0.50 * progress)
	if progress >= 1.0:
		_enter_stage(STAGE_MIRROR)


func _process_mirror(delta: float) -> void:
	# 雾子 lies on the surface: a slow bob, a slow turn, and ripples leaving her
	# arms and legs so the water never looks like a still image.
	if is_instance_valid(_mirror_holder):
		var bob := sin(_elapsed * 0.85) * 0.05 + sin(_elapsed * 1.9) * 0.015
		_mirror_holder.global_position = Vector3(
			_floor_surface.x,
			_flood_y - 0.055 + bob,
			_floor_surface.z
		)
		_mirror_holder.rotation_degrees = Vector3(
			-90.0 + sin(_elapsed * 0.6) * 2.2,
			6.0 + sin(_elapsed * 0.21) * 5.0,
			sin(_elapsed * 0.47) * 3.0
		)
		if is_instance_valid(_mirror_visual):
			_mirror_visual.position = Vector3(sin(_elapsed * 0.55) * 0.06, 0.0, 0.9)
	_mirror_ripple_clock -= delta
	if _mirror_ripple_clock <= 0.0:
		_mirror_ripple_clock = 1.15
		var offset := Vector3(sin(_elapsed * 1.7) * 0.55, 0.0, cos(_elapsed * 1.3) * 0.95)
		_splash(Vector3(_floor_surface.x + offset.x, _flood_y, _floor_surface.z + offset.z), 0.75)
	# The overhead frame pushes in and drifts slightly; the gate takes over from
	# exactly this framing. The drift stays small so 雾子 keeps her place in the
	# plate instead of wandering out of the quote's band.
	_camera_height = move_toward(_camera_height, 7.8, delta * 0.9)
	_camera.global_position = Vector3(
		_floor_surface.x + sin(_elapsed * 0.17) * 0.9,
		_flood_y + _camera_height,
		_floor_surface.z + cos(_elapsed * 0.14) * 0.9
	)
	_camera.rotation_degrees = Vector3(-90.0, sin(_elapsed * 0.1) * 6.0, 0.0)
	_hold_left -= delta
	if _hold_left <= 0.0:
		_enter_stage(STAGE_DIGITAL)


func _process_digital(_delta: float) -> void:
	_poll_load()
	if _cover_requested:
		return
	var long_enough := _stage_time >= digital_min_duration
	var gave_up := _stage_time >= digital_timeout
	if _next_scene.is_empty():
		# The deepest authored floor has nothing to stream; its gate is timing
		# only, and the floor returns to the arena afterwards.
		if long_enough:
			_cover_digital()
	elif long_enough and (_load_ready or gave_up):
		_cover_digital()


func _cover_digital() -> void:
	if _cover_requested:
		return
	_cover_requested = true
	if is_instance_valid(_overlay):
		_overlay.cover_digital()


func _on_digital_covered() -> void:
	if _finished:
		return
	_finished = true
	_stage = STAGE_DONE
	set_process(false)
	completed.emit()


func _poll_load() -> void:
	if _next_scene.is_empty():
		if is_instance_valid(_overlay):
			_overlay.set_load_ready()
		_load_ready = true
		return
	if not _load_requested:
		return
	# `load_threaded_get_status` reports the state as its return value and writes
	# the 0..1 progress into the array passed alongside it.
	var progress: Array = []
	var state := ResourceLoader.load_threaded_get_status(_next_scene, progress)
	if not progress.is_empty():
		_load_progress = maxf(_load_progress, clampf(float(progress[0]), 0.0, 1.0))
		if is_instance_valid(_overlay):
			_overlay.set_load_progress(_load_progress)
	if state == ResourceLoader.THREAD_LOAD_LOADED:
		_load_ready = true
		if is_instance_valid(_overlay):
			_overlay.set_load_ready()


## Registers the destination with the resource loader before the gate opens, so
## the eventual scene change is a cache hit instead of a stall behind the flare.
func request_scene_load(path: String) -> void:
	if path.is_empty() or _load_requested:
		return
	_load_requested = true
	var error := ResourceLoader.load_threaded_request(path)
	if error != OK:
		_load_requested = false
		_load_ready = true


# ----------------------------------------------------------------- 3D staging

func _sink_arena(depth: float, extra_roll: float) -> void:
	if not is_instance_valid(_arena_model):
		return
	# The moment the whole plate reaches the basin the water takes it: one wide
	# ring under the arena plus a ring of smaller impacts around its rim.
	if not _arena_splash_done and depth >= BASIN_DEPTH:
		_arena_splash_done = true
		_splash(Vector3(_floor_surface.x, _flood_y, _floor_surface.z), 1.8)
		for index in 6:
			var angle := TAU * float(index) / 6.0
			_splash(Vector3(
				_floor_surface.x + cos(angle) * 4.6,
				_flood_y,
				_floor_surface.z + sin(angle) * 4.6
			), 1.2)
		_shake = maxf(_shake, 1.0)
	_arena_model.position.y = _arena_start_position.y - depth
	_arena_model.rotation_degrees.x = _arena_start_rotation.x - 6.0 - extra_roll * 0.35
	_arena_model.rotation_degrees.y = _arena_start_rotation.y + extra_roll * 0.6
	if is_instance_valid(_boss):
		_boss.global_position = _boss_start + Vector3(0.0, -depth, 0.0)
		_boss.rotation_degrees = Vector3(extra_roll * 0.4, extra_roll * 0.3, -12.0)


## 素子 falls limp: the authored dead presentation already lays the rig down and
## retires the blade, so the director only has to tumble the body.
func _apply_limp_pose() -> void:
	if not is_instance_valid(_player):
		return
	var visual: Node = _player.get("_character_visual")
	if is_instance_valid(visual) and visual.has_method("apply_state"):
		visual.call("apply_state", {
			"time": _elapsed,
			"dead": true,
			"move_amount": 0.0,
			"damage_flash": 0.0,
		})


## Frames one shot of the fall. `min_height` keeps the lens above the water, so
## the splash and the closing surface stay visible instead of the camera diving
## after the body into a dark basin.
func _frame_fall_camera(focus: Vector3, offset: Vector3, shake_scale: float, min_height: float) -> void:
	var jitter := Vector3.ZERO
	if _shake > 0.001:
		jitter = Vector3(
			sin(_elapsed * 37.0) * 0.34,
			sin(_elapsed * 41.0 + 1.7) * 0.26,
			cos(_elapsed * 33.0 + 0.6) * 0.34
		) * _shake * shake_scale
	_camera.global_position = focus + offset + jitter
	_camera.global_position.y = maxf(_camera.global_position.y, min_height)
	_camera.look_at(focus - Vector3(0.0, 1.6, 0.0), Vector3.UP)
	_camera.rotation_degrees.x = clampf(_camera.rotation_degrees.x, -84.0, -6.0)


func _build_flood() -> void:
	_water_material = ShaderMaterial.new()
	_water_material.shader = WATER_SHADER
	_water_material.set_shader_parameter("water_color", Color("123c4a"))
	# Seen from straight above the fresnel term is at its weakest, so the sheet
	# needs a higher base alpha and amplified waves to read as water rather than
	# as a window into the wreck below it.
	_water_material.set_shader_parameter("water_alpha", 0.78)
	_water_material.set_shader_parameter("wave_scale", 2.2)
	_water_material.set_shader_parameter("ripple_scale", 2.6)
	_ripples.resize(RIPPLE_CAPACITY)
	_ripples.fill(Vector4.ZERO)
	_water_material.set_shader_parameter("ripple_data", _ripples)
	_water = MeshInstance3D.new()
	_water.name = "EndingFlood"
	var plane := PlaneMesh.new()
	plane.size = Vector2(180.0, 180.0)
	plane.subdivide_width = 6
	plane.subdivide_depth = 6
	_water.mesh = plane
	_water.material_override = _water_material
	_water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_water)
	_place_water()


func _place_water() -> void:
	if is_instance_valid(_water):
		_water.global_position = Vector3(_floor_surface.x, _flood_y, _floor_surface.z)


func _build_debris() -> void:
	var materials: Dictionary = {}
	if _floor != null:
		var floor_materials: Variant = _floor.get("_materials")
		if floor_materials is Dictionary:
			materials = floor_materials
	var keys: Array[String] = ["concrete", "dark", "rail", "base"]
	var rng := RandomNumberGenerator.new()
	rng.seed = int(_floor.get("map_seed") if _floor != null else 0) * 7919 + 977
	for index in DEBRIS_COUNT:
		var chunk := MeshInstance3D.new()
		chunk.name = "Debris%d" % index
		var box := BoxMesh.new()
		var length := rng.randf_range(0.35, 1.35)
		box.size = Vector3(length, rng.randf_range(0.25, 0.8), rng.randf_range(0.35, length + 0.5))
		chunk.mesh = box
		var material: Variant = materials.get(keys[index % keys.size()])
		if material is Material:
			chunk.material_override = material
		chunk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(chunk)
		var angle := rng.randf_range(0.0, TAU)
		var radius := rng.randf_range(3.4, 13.5)
		chunk.global_position = _floor_surface + Vector3(
			cos(angle) * radius,
			rng.randf_range(4.0, 15.0),
			sin(angle) * radius
		)
		chunk.rotation = Vector3(rng.randf_range(0.0, TAU), rng.randf_range(0.0, TAU), rng.randf_range(0.0, TAU))
		_debris.append({
			"node": chunk,
			"velocity": Vector3(rng.randf_range(-1.8, 1.8), rng.randf_range(-1.2, 0.2), rng.randf_range(-1.8, 1.8)),
			"spin": Vector3(rng.randf_range(-5.0, 5.0), rng.randf_range(-5.0, 5.0), rng.randf_range(-5.0, 5.0)),
			"wet": false,
		})
	_build_slabs(rng, materials)


## The duel floor itself shears away around 素子: flat plates start on the plate
## she is standing on and tumble after her into the basin, which reads as the
## ground giving way rather than as rubble simply raining from above.
func _build_slabs(rng: RandomNumberGenerator, materials: Dictionary) -> void:
	var material: Variant = materials.get("rail", materials.get("concrete"))
	for index in SLAB_COUNT:
		var slab := MeshInstance3D.new()
		slab.name = "FloorSlab%d" % index
		var box := BoxMesh.new()
		var side := rng.randf_range(1.5, 3.0)
		box.size = Vector3(side, rng.randf_range(0.16, 0.3), rng.randf_range(1.5, 2.6))
		slab.mesh = box
		if material is Material:
			slab.material_override = material
		slab.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(slab)
		var angle := rng.randf_range(0.0, TAU)
		var radius := rng.randf_range(1.6, 6.4)
		slab.global_position = _floor_surface + Vector3(cos(angle) * radius, rng.randf_range(-0.2, 0.4), sin(angle) * radius)
		slab.rotation = Vector3(rng.randf_range(-0.2, 0.2), rng.randf_range(0.0, TAU), rng.randf_range(-0.2, 0.2))
		var outward := Vector3(cos(angle), 0.0, sin(angle)) * rng.randf_range(0.4, 1.4)
		_debris.append({
			"node": slab,
			"velocity": outward + Vector3(0.0, rng.randf_range(0.2, 0.8), 0.0),
			"spin": Vector3(rng.randf_range(-2.4, 2.4), rng.randf_range(-2.4, 2.4), rng.randf_range(-2.4, 2.4)),
			"wet": false,
		})


func _update_debris(delta: float) -> void:
	for chunk in _debris:
		var node: MeshInstance3D = chunk["node"]
		if not is_instance_valid(node):
			continue
		var velocity: Vector3 = chunk["velocity"]
		var spin: Vector3 = chunk["spin"]
		if bool(chunk["wet"]):
			# Water drag: the chunk stops tumbling, then drops out of the frame
			# while the camera waits on the surface above it.
			velocity.y = maxf(velocity.y - GRAVITY * delta * 0.12, -2.4)
			velocity *= 0.985
			spin *= 0.985
		else:
			velocity.y -= GRAVITY * delta
		var position := node.global_position + velocity * delta
		if not bool(chunk["wet"]) and position.y <= _flood_y:
			chunk["wet"] = true
			_splash(Vector3(position.x, _flood_y, position.z), clampf(0.45 + absf(velocity.y) * 0.05, 0.45, 1.25))
			velocity = Vector3(velocity.x * 0.45, absf(velocity.y) * 0.22, velocity.z * 0.45)
			spin *= 0.30
		node.global_position = position
		node.rotation += spin * delta
		chunk["velocity"] = velocity
		chunk["spin"] = spin
		if node.global_position.y < _flood_y - 24.0 and node.visible:
			node.visible = false


## A single cool light hangs over the basin. Without it the sunlight is blocked
## by nothing but the water is too dark to show the body or the ripples.
func _build_stage_light() -> void:
	_stage_light = OmniLight3D.new()
	_stage_light.name = "EndingStageLight"
	_stage_light.light_color = Color("cbeef7")
	_stage_light.light_energy = 4.6
	_stage_light.omni_range = 30.0
	_stage_light.omni_attenuation = 1.0
	_stage_light.shadow_enabled = false
	add_child(_stage_light)
	# Deliberately off the zenith: a light directly over the mirror puts its
	# specular reflection into the middle of the overhead frame, which reads as a
	# hole in the water. From the side it rims the body and the arena instead.
	_stage_light.global_position = Vector3(_floor_surface.x + 9.5, _flood_y + 6.5, _floor_surface.z + 6.5)


func _build_mirror() -> void:
	_mirror_holder = Node3D.new()
	_mirror_holder.name = "Wuko"
	add_child(_mirror_holder)
	_mirror_visual = CHARACTER_VISUAL.new()
	_mirror_visual.name = "WukoVisual"
	_mirror_visual.show_tech_blade = false
	_mirror_visual.use_animation_player = false
	_mirror_visual.use_skill_animations = false
	_mirror_holder.add_child(_mirror_visual)
	# 雾子 is 素子's mirror: the same rig, without the blade, laid on her back.
	# The imported rig faces the heading's -Z (`player._direction_yaw`), so the
	# extra half turn makes the holder's -90 degree lay-back put her face up
	# instead of face down.
	_mirror_visual.rotation.y = PI
	_mirror_visual.call("setup")
	_mirror_visual.call("reset_pose")
	_mirror_visual.position = Vector3(0.0, 0.0, 0.9)
	_mirror_holder.global_position = Vector3(_floor_surface.x, _flood_y - 0.055, _floor_surface.z)
	_mirror_holder.rotation_degrees = Vector3(-90.0, 6.0, 0.0)
	var skeleton: Skeleton3D = _mirror_visual.call("get_skeleton")
	if skeleton != null:
		_splay_limbs(skeleton)


## Limbs float instead of standing: the imported rig splays sideways around its
## local X, and Z is the anatomical flexion axis (see `character_visual.gd`).
func _splay_limbs(skeleton: Skeleton3D) -> void:
	var pose := {
		"mixamorig_LeftArm": Vector3(0.42, 0.0, -0.16),
		"mixamorig_LeftForeArm": Vector3(0.0, 0.0, -0.42),
		"mixamorig_RightArm": Vector3(-0.30, 0.0, -0.10),
		"mixamorig_RightForeArm": Vector3(0.0, 0.0, -0.62),
		"mixamorig_LeftUpLeg": Vector3(0.06, 0.0, 0.0),
		"mixamorig_LeftLeg": Vector3(0.0, 0.0, 0.30),
		"mixamorig_RightUpLeg": Vector3(-0.20, 0.0, 0.0),
		"mixamorig_RightLeg": Vector3(0.0, 0.0, 0.10),
		"mixamorig_Spine": Vector3(0.0, 0.0, 0.05),
		"mixamorig_Head": Vector3(0.0, 0.16, 0.0),
	}
	for bone_name in pose:
		var index := skeleton.find_bone(String(bone_name))
		if index < 0:
			continue
		var rest := skeleton.get_bone_rest(index)
		skeleton.set_bone_pose_rotation(index, rest.basis.get_rotation_quaternion() * Quaternion.from_euler(pose[bone_name]))


func _cut_to_overhead() -> void:
	_camera_height = 12.2
	_camera.global_position = Vector3(_floor_surface.x + 0.4, _flood_y + _camera_height, _floor_surface.z + 0.4)
	_camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)


# ---------------------------------------------------------------------- water

func _advance_ripples(delta: float) -> void:
	for index in range(_ripples.size()):
		var ripple := _ripples[index]
		if ripple.w > 0.0:
			ripple.z += delta
			if ripple.z >= RIPPLE_LIFETIME:
				ripple.w = 0.0
			_ripples[index] = ripple


func _splash(at: Vector3, strength: float) -> void:
	_ripples[_next_ripple] = Vector4(at.x, at.z, 0.0, strength)
	_next_ripple = (_next_ripple + 1) % RIPPLE_CAPACITY


func _upload_water() -> void:
	if _water_material == null:
		return
	_water_material.set_shader_parameter("wave_time", _wave_time)
	_water_material.set_shader_parameter("ripple_data", _ripples)


# ---------------------------------------------------------------- environment

func _capture_environment() -> void:
	if _floor == null:
		return
	var world := _floor.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world == null or world.environment == null:
		return
	var environment := world.environment
	_environment_snapshot = {
		"background_mode": environment.background_mode,
		"background_color": environment.background_color,
		"ambient_light_color": environment.ambient_light_color,
		"ambient_light_energy": environment.ambient_light_energy,
		"reflected_light_source": environment.reflected_light_source,
		"sky": environment.sky,
		"fog_enabled": environment.fog_enabled,
		"fog_light_color": environment.fog_light_color,
		"fog_density": environment.fog_density,
	}
	for light_name in ["KeyLight", "FillLight"]:
		var light := _floor.get_node_or_null(light_name) as DirectionalLight3D
		if light == null:
			continue
		_light_snapshots.append({
			"node": light,
			"color": light.light_color,
			"energy": light.light_energy,
		})


func _apply_cinematic_environment() -> void:
	if _floor == null:
		return
	var world := _floor.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world != null and world.environment != null:
		var environment := world.environment
		# The basin at night: no sky, no city bounce light, and enough fog that
		# the arena fades out as it sinks instead of hanging in mid-air.
		environment.background_mode = Environment.BG_COLOR
		environment.background_color = Color("04080b")
		environment.sky = null
		environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
		environment.ambient_light_color = Color("4a6d7a")
		environment.ambient_light_energy = 0.32
		# Exponential fog, deliberately renderer-independent: the water sheet is
		# dense enough on its own to hide the basin, and the fog only keeps the
		# deepest wreckage from reading as a second floor.
		environment.fog_enabled = true
		environment.fog_light_color = Color("0a2531")
		environment.fog_density = 0.022
	for snapshot in _light_snapshots:
		var light: DirectionalLight3D = snapshot["node"]
		if not is_instance_valid(light):
			continue
		light.light_color = Color("a9d6e6")
		light.light_energy = 0.62 if light.name == "KeyLight" else 0.14


func _restore_environment() -> void:
	if not _environment_snapshot.is_empty() and _floor != null:
		var world := _floor.get_node_or_null("WorldEnvironment") as WorldEnvironment
		if world != null and world.environment != null:
			var environment := world.environment
			environment.background_mode = int(_environment_snapshot["background_mode"])
			environment.background_color = _environment_snapshot["background_color"]
			environment.ambient_light_color = _environment_snapshot["ambient_light_color"]
			environment.ambient_light_energy = float(_environment_snapshot["ambient_light_energy"])
			environment.reflected_light_source = int(_environment_snapshot["reflected_light_source"])
			environment.sky = _environment_snapshot["sky"]
			environment.fog_enabled = bool(_environment_snapshot["fog_enabled"])
			environment.fog_light_color = _environment_snapshot["fog_light_color"]
			environment.fog_density = float(_environment_snapshot["fog_density"])
	for snapshot in _light_snapshots:
		var light: DirectionalLight3D = snapshot["node"]
		if is_instance_valid(light):
			light.light_color = snapshot["color"]
			light.light_energy = float(snapshot["energy"])
	_environment_snapshot.clear()
	_light_snapshots.clear()


func _ease_in(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t


func _ease_in_out(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## World-space union of every mesh in the authored duel arena. The camera rig
## needs it because the imported arena is a walled circular structure: a low
## three-quarter camera looks straight into its panels, so the collapse is framed
## from an elevation that clears the rim, and the distance follows the plate.
func _measure_arena() -> void:
	if _arena == null:
		return
	var combined := AABB()
	var first := true
	for node in _arena.find_children("*", "MeshInstance3D", true, false):
		var instance := node as MeshInstance3D
		if instance == null or instance.mesh == null:
			continue
		var box: AABB = instance.global_transform * instance.get_aabb()
		combined = box if first else combined.merge(box)
		first = false
	if not first:
		_arena_bounds = combined


## Test hook: the measured arena box, empty when the arena could not be read.
func arena_bounds() -> AABB:
	return _arena_bounds
