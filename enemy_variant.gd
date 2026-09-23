extends "res://enemy.gd"
## Street enemy variants used by the first-floor encounters.
##
## The base enemy remains the deterministic training opponent.  This subclass
## keeps its damage/take_damage API and collision behaviour, but gives street
## encounters three readable patterns:
##   sword  - slow, high-damage melee, then retreats to recover;
##   boxer  - fast, low-damage melee; its first approach starts concealed and
##            fades into view while it rushes the player;
##   sniper - stays at a long distance, appears only while aiming, waits two
##            seconds, fires once, then moves during the cooldown.

const VARIANT_SWORD: StringName = &"sword"
const VARIANT_BOXER: StringName = &"boxer"
const VARIANT_SNIPER: StringName = &"sniper"

const SWORD_MODEL := "res://model/female+cyberpunk+warrior+3d+model.glb"
const BOXER_MODEL := "res://model/拳击手.glb"
const SNIPER_ASSEMBLY := "res://model/sniper_rifle/sniper_rifle.tscn"
const SNIPER_CHARACTER := "res://model/sniper_rifle/assets/sniper.glb"
const CLOAK_SHADER = preload("res://materials/occlusion_tech.gdshader")
## The ghost is deliberately kept separate from the imported GLB materials.
## This lets the model return to its original textured materials once the
## travelling scan has finished, instead of leaving a blue tint behind.
const CLOAK_BODY_THRESHOLD := 0.40
## Slash_001 contains the full windup, swing, and return-to-guard pose. The
## combat state machine keeps its short 0.62 s telegraph, so start the clip in
## its preparation and let the animation reach the swing as the strike opens.
const SWORD_SLASH_START_TIME := 0.48
const SWORD_SLASH_HIT_TIME := 1.10
const SWORD_IDLE_TIME := 2.35

## StringName keeps runtime comparisons allocation-free; the inspector can
## still set the same values even without the typed enum annotation.
@export var variant: StringName = VARIANT_SWORD
@export var retreat_distance: float = 4.5
@export var retreat_speed: float = 4.2
@export var sniper_damage: float = 20.0
@export var sniper_min_distance: float = 7.0
@export var sniper_ideal_distance: float = 12.0
@export var sniper_max_distance: float = 20.0
@export var sniper_aim_duration: float = 2.0
@export var sniper_fire_duration: float = 0.14
@export var sniper_cooldown_duration: float = 2.8
@export var boxer_reveal_distance: float = 5.8
@export var boxer_reveal_duration: float = 0.72
## Boxer activation starts at `aggro_range`; once an encounter is active it
## may keep chasing until this larger leash distance.
@export var boxer_leash_range: float = 20.0
@export var model_scale: float = 1.84

var _variant_visual: Node3D
var _variant_animation: AnimationPlayer
var _visibility_alpha: float = 1.0
var _visibility_target: float = 1.0
var _visibility_speed: float = 8.0
var _boxer_first_approach := false
var _boxer_reveal_started := false
var _sniper_shot_done := false
var _sniper_muzzle: Node3D
var _sniper_assembly_loaded := false
var _variant_model_imported := false
var _cloak_material: ShaderMaterial
var _cloak_records: Array[Dictionary] = []
var _applied_cloak_alpha := -1.0


func _ready() -> void:
	_apply_variant_stats()
	super._ready()


## Configure immediately after `new()` and before/after adding the node.
## Calling this after the node entered the tree also refreshes the model and
## keeps the same `setup(actor)` and `take_damage()` contract.
func configure_variant(kind: StringName) -> void:
	variant = _normalize_variant(kind)
	_apply_variant_stats()
	if is_inside_tree():
		_replace_variant_visual()
		reset_enemy()


func set_variant(kind: StringName) -> void:
	configure_variant(kind)


func get_variant_kind() -> StringName:
	return variant


func take_damage(amount: float) -> bool:
	var accepted := super.take_damage(amount)
	if not accepted or variant != VARIANT_SWORD:
		return accepted
	if is_dead:
		_play_variant_animation(&"dead")
	elif state not in [&"windup", &"strike"]:
		# Do not interrupt a committed attack. Outside an attack, use the new
		# GLB's short reaction clip and return to the guard pose afterward.
		_play_variant_animation(&"hit")
	return accepted


func disengage() -> void:
	# Cancel this encounter without resetting health, concealment history or the
	# world transform. Gravity remains enabled so an airborne enemy can land.
	combat_enabled = false
	velocity.x = 0.0
	velocity.z = 0.0
	if is_dead:
		return
	state = &"idle"
	state_time_left = 0.0
	_hit_this_swing = true
	_sniper_shot_done = true
	if is_instance_valid(_variant_animation):
		_variant_animation.pause()
	if variant == VARIANT_SWORD:
		_play_variant_animation(&"idle")
	_update_model()


func is_optically_hidden() -> bool:
	# Match the renderer's root visibility threshold exactly: a hidden enemy has
	# no body, weapon, or shadow left to disclose its position.
	return _visibility_alpha <= 0.001


func is_aiming() -> bool:
	return variant == VARIANT_SNIPER and state == &"sniper_aim"


func is_fully_revealed() -> bool:
	return _visibility_alpha >= 0.999


func get_variant_snapshot() -> Dictionary:
	return {
		"variant": String(variant),
		"state": String(state),
		"hidden": is_optically_hidden(),
		"visibility": _visibility_alpha,
		"attack_damage": attack_damage,
		"sniper_aiming": is_aiming(),
		"health": health,
	}


func reset_enemy() -> void:
	_apply_variant_stats()
	super.reset_enemy()
	_boxer_first_approach = variant == VARIANT_BOXER
	_boxer_reveal_started = false
	_sniper_shot_done = false
	_visibility_alpha = 0.0 if variant == VARIANT_BOXER or variant == VARIANT_SNIPER else 1.0
	_visibility_target = 1.0
	if variant == VARIANT_BOXER or variant == VARIANT_SNIPER:
		_set_visibility_target(0.0)
	else:
		_set_visibility_target(1.0)
	_play_variant_animation(&"idle")
	_apply_visibility()


func _build_model() -> void:
	# Keep the base warning sector, health label, collision shape, and greybox
	# fallback.  The imported character is layered on top and the greybox is
	# hidden after construction so old scenes continue to render if an asset is
	# not imported yet.
	super._build_model()
	if is_instance_valid(_body_pivot):
		_body_pivot.visible = false
	_replace_variant_visual()


func _replace_variant_visual() -> void:
	if is_instance_valid(_variant_visual):
		_variant_visual.queue_free()
		_variant_visual = null
	_variant_animation = null
	_sniper_muzzle = null
	_sniper_assembly_loaded = false
	var path := _model_path_for_variant()
	var packed := load(path) as PackedScene
	# The assembly is intentionally tried first for the sniper.  Its original
	# copied-folder paths may be unavailable in older checkouts, so use the
	# character GLB as a graceful fallback.
	if packed == null and variant == VARIANT_SNIPER:
		packed = load(SNIPER_CHARACTER) as PackedScene
	_sniper_assembly_loaded = variant == VARIANT_SNIPER and packed != null and path == SNIPER_ASSEMBLY
	var imported_model_loaded := packed != null
	_variant_model_imported = imported_model_loaded
	if packed != null:
		_variant_visual = packed.instantiate() as Node3D
	if not is_instance_valid(_variant_visual):
		_variant_visual = Node3D.new()
		_variant_visual.name = "MissingVariantModelFallback"
	else:
		_variant_visual.name = "VariantModel_%s" % String(variant)
	var visual_scale := model_scale
	if variant == VARIANT_SNIPER and _sniper_assembly_loaded:
		# The ready-made assembly already scales its character to 1.80 m.
		visual_scale = 1.0
	_variant_visual.scale = Vector3.ONE * visual_scale
	# The boxer and sniper rigs use the opposite authored forward axis. The new
	# sword GLB shares the old greatsword's axis, so keep its root unrotated.
	_variant_visual.rotation.y = PI if variant in [VARIANT_BOXER, VARIANT_SNIPER] else 0.0
	# The imported GLB origin is at the feet; keeping it on the floor avoids the
	# half-body sinking that the primitive training mannequin did not expose.
	_variant_visual.position = Vector3.ZERO
	if is_instance_valid(_heading):
		_heading.add_child(_variant_visual)
	else:
		add_child(_variant_visual)
	if is_instance_valid(_body_pivot):
		# Keep the original greybox visible if an external GLB is still importing
		# in the editor or was omitted from a lightweight build.
		_body_pivot.visible = not imported_model_loaded
	_variant_animation = _find_animation_player(_variant_visual)
	if is_instance_valid(_variant_animation):
		var finished_callback := Callable(self, "_on_variant_animation_finished")
		if not _variant_animation.animation_finished.is_connected(finished_callback):
			_variant_animation.animation_finished.connect(finished_callback)
	_sniper_muzzle = _find_node_by_name(_variant_visual, ["Muzzle", "muzzle", "MuzzleHint"])
	_setup_cloak_material()
	_apply_visibility()


func _model_path_for_variant() -> String:
	match variant:
		VARIANT_BOXER:
			return BOXER_MODEL
		VARIANT_SNIPER:
			return SNIPER_ASSEMBLY
		_:
			return SWORD_MODEL


func _physics_process(delta: float) -> void:
	# The base implementation supplies gravity, move_and_slide, common damage,
	# and the single-hit melee geometry.  Our custom sniper states deliberately
	# avoid the base `state == strike` branch and apply a single ray-shot below.
	_visibility_alpha = move_toward(_visibility_alpha, _visibility_target, _visibility_speed * delta)
	super._physics_process(delta)
	# A street encounter can deactivate while a sniper is midway through its
	# telegraph. The base controller moves it back to idle in that same frame;
	# force the optical cloak to follow the resulting state immediately.
	if variant == VARIANT_SNIPER and (not combat_enabled or (state != &"sniper_aim" and state != &"sniper_fire")):
		_set_visibility_target(0.0)


func _update_combat(delta: float) -> void:
	if variant == VARIANT_SNIPER:
		_update_sniper(delta)
	else:
		_update_melee_variant(delta)


func _update_melee_variant(delta: float) -> void:
	var offset := _actor.global_position - global_position
	offset.y = 0.0
	var distance := offset.length()
	var is_boxer := variant == VARIANT_BOXER
	var engage_range := aggro_range
	if is_boxer and combat_enabled:
		# Street encounters keep combat_enabled true between the activation
		# radius and the leash radius. This prevents the AI from going idle
		# before the encounter gets a chance to disengage at 20 m.
		engage_range = boxer_leash_range
	if is_boxer and _boxer_first_approach and not _boxer_reveal_started and distance <= boxer_reveal_distance:
		_boxer_reveal_started = true
		_set_visibility_target(1.0)
		_visibility_speed = 1.0 / maxf(boxer_reveal_duration, 0.05)
		_play_variant_animation(&"reveal")
	match state:
		&"idle", &"chase":
			if distance > engage_range:
				state = &"idle"
				velocity.x = 0.0
				velocity.z = 0.0
			elif distance <= attack_start_range and (not is_boxer or is_fully_revealed()):
				# Finish materializing before the short 0.2 s windup begins, even
				# if the player walks directly into an initially hidden boxer.
				_begin_variant_windup(offset, is_boxer)
			else:
				state = &"chase"
				_move_toward(offset, delta, 1.55, move_speed)
		&"windup":
			var movement_window := maxf(0.0, state_time_left - aim_lock_duration)
			if movement_window > 0.0:
				_move_toward(offset, delta, 1.5, move_speed * 0.45)
			else:
				velocity.x = 0.0
				velocity.z = 0.0
			state_time_left = maxf(0.0, state_time_left - delta)
			if state_time_left <= 0.0:
				state = &"strike"
				state_time_left = active_duration
				velocity.x = 0.0
				velocity.z = 0.0
				_play_variant_animation(&"attack")
		&"strike":
			velocity.x = 0.0
			velocity.z = 0.0
			state_time_left = maxf(0.0, state_time_left - delta)
			if state_time_left <= 0.0:
				state = &"retreat"
				state_time_left = 1.25 if is_boxer else 1.65
				_play_variant_animation(&"retreat")
		&"retreat":
			_move_away(offset, delta, retreat_speed if is_boxer else retreat_speed * 0.82)
			state_time_left = maxf(0.0, state_time_left - delta)
			if distance >= retreat_distance or state_time_left <= 0.0:
				state = &"recovery"
				state_time_left = 0.45 if is_boxer else 0.8
				velocity.x = 0.0
				velocity.z = 0.0
		&"recovery":
			velocity.x = 0.0
			velocity.z = 0.0
			state_time_left = maxf(0.0, state_time_left - delta)
			if state_time_left <= 0.0:
				state = &"idle"
				if not (variant == VARIANT_SWORD and is_instance_valid(_variant_animation) and _variant_animation.current_animation == "hit_to_head_001"):
					_play_variant_animation(&"idle")


func _begin_variant_windup(offset: Vector3, is_boxer: bool) -> void:
	state = &"windup"
	windup_duration = 0.20 if is_boxer else 0.62
	aim_lock_duration = 0.10 if is_boxer else 0.30
	active_duration = 0.12
	state_time_left = windup_duration
	_hit_this_swing = false
	if not offset.is_zero_approx():
		attack_direction = offset.normalized()
		_heading.rotation.y = _direction_yaw(attack_direction)
	_play_variant_animation(&"aim" if is_boxer else &"windup")


func _update_sniper(delta: float) -> void:
	var offset := _actor.global_position - global_position
	offset.y = 0.0
	var distance := offset.length()
	_set_visibility_target(1.0 if state == &"sniper_aim" or state == &"sniper_fire" else 0.0)
	match state:
		&"idle", &"chase":
			# It may aim only after it has line-of-sight distance. While closing or
			# retreating it remains optically hidden.
			if distance < sniper_min_distance:
				state = &"chase"
				_move_away(offset, delta, move_speed * 0.9)
			elif distance > sniper_max_distance:
				state = &"chase"
				_move_toward(offset, delta, sniper_ideal_distance, move_speed * 0.8)
			else:
				_begin_sniper_aim(offset)
		&"sniper_aim":
			velocity.x = 0.0
			velocity.z = 0.0
			if not offset.is_zero_approx():
				attack_direction = offset.normalized()
				_heading.rotation.y = _direction_yaw(attack_direction)
			state_time_left = maxf(0.0, state_time_left - delta)
			if state_time_left <= 0.0:
				state = &"sniper_fire"
				state_time_left = sniper_fire_duration
				_sniper_shot_done = false
				_play_variant_animation(&"fire")
		&"sniper_fire":
			velocity.x = 0.0
			velocity.z = 0.0
			if not _sniper_shot_done:
				_sniper_shot_done = true
				_fire_sniper()
			state_time_left = maxf(0.0, state_time_left - delta)
			if state_time_left <= 0.0:
				state = &"sniper_cooldown"
				state_time_left = sniper_cooldown_duration
				_visibility_speed = 2.2
				_set_visibility_target(0.0)
				_play_variant_animation(&"cooldown")
		&"sniper_cooldown":
			# During cooldown it constantly adjusts its range and stays hidden.
			_set_visibility_target(0.0)
			if distance < sniper_ideal_distance - 0.8:
				_move_away(offset, delta, move_speed * 0.72)
			elif distance > sniper_ideal_distance + 0.8:
				_move_toward(offset, delta, sniper_ideal_distance, move_speed * 0.72)
			else:
				velocity.x = 0.0
				velocity.z = 0.0
			state_time_left = maxf(0.0, state_time_left - delta)
			if state_time_left <= 0.0:
				state = &"idle"
				_play_variant_animation(&"idle")


func _begin_sniper_aim(offset: Vector3) -> void:
	state = &"sniper_aim"
	state_time_left = sniper_aim_duration
	_sniper_shot_done = false
	_visibility_speed = 1.8
	_set_visibility_target(1.0)
	if not offset.is_zero_approx():
		attack_direction = offset.normalized()
		_heading.rotation.y = _direction_yaw(attack_direction)
	_play_variant_animation(&"aim")


func _fire_sniper() -> void:
	if not is_instance_valid(_actor) or _actor.is_dead:
		return
	var origin := global_position + Vector3.UP * 1.35
	if is_instance_valid(_sniper_muzzle):
		origin = _sniper_muzzle.global_position
	var target := _actor.global_position + Vector3.UP * 0.85
	var ray := PhysicsRayQueryParameters3D.create(origin, target, 1)
	var exclusions: Array[RID] = [get_rid(), _actor.get_rid()]
	ray.exclude = exclusions
	var blocked := get_world_3d().direct_space_state.intersect_ray(ray)
	if not blocked.is_empty():
		return
	if _actor.has_method("take_damage"):
		_actor.call("take_damage", sniper_damage)
		if _actor.has_signal("status_changed"):
			_actor.status_changed.emit("狙击命中", false)


func _move_toward(offset: Vector3, delta: float, desired_distance: float, speed: float) -> void:
	if offset.is_zero_approx():
		velocity.x = 0.0
		velocity.z = 0.0
		return
	attack_direction = offset.normalized()
	_heading.rotation.y = _direction_yaw(attack_direction)
	var travel := clampf(offset.length() - desired_distance, -speed * delta, speed * delta)
	var actual_speed := travel / maxf(delta, 0.0001)
	velocity.x = attack_direction.x * actual_speed
	velocity.z = attack_direction.z * actual_speed


func _move_away(offset: Vector3, delta: float, speed: float) -> void:
	if offset.is_zero_approx():
		velocity.x = 0.0
		velocity.z = 0.0
		return
	var away := -offset.normalized()
	attack_direction = -away
	_heading.rotation.y = _direction_yaw(attack_direction)
	velocity.x = away.x * speed
	velocity.z = away.z * speed


func _update_model() -> void:
	# Let the base update warning sectors, attack arc, health label, and hit
	# tint.  It also remains useful as a greybox fallback for missing imports.
	super._update_model()
	if not is_instance_valid(_variant_visual):
		return
	if variant == VARIANT_SNIPER and state != &"sniper_aim" and state != &"sniper_fire":
		# Leaving an encounter cancels a telegraph immediately; the sniper should
		# not stay visible just because combat was disabled on that same frame.
		_set_visibility_target(0.0)
	_apply_visibility()


func _on_variant_animation_finished(animation_name: StringName) -> void:
	if variant != VARIANT_SWORD or animation_name != &"hit_to_head_001":
		return
	if not is_dead and state not in [&"windup", &"strike"]:
		_play_variant_animation(&"idle")


func _apply_variant_stats() -> void:
	variant = _normalize_variant(variant)
	match variant:
		VARIANT_BOXER:
			display_name = "拳击手"
			attack_damage = 12.0
			move_speed = 7.4
			attack_start_range = 2.1
			# Enter combat at the original 10 m activation radius. The street
			# encounter supplies the separate 20 m leash while already active.
			aggro_range = 10.0
			windup_duration = 0.20
			recovery_duration = 0.55
		VARIANT_SNIPER:
			display_name = "狙击手"
			attack_damage = sniper_damage
			move_speed = 5.0
			attack_start_range = sniper_ideal_distance
			aggro_range = sniper_max_distance + 4.0
			windup_duration = sniper_aim_duration
			recovery_duration = sniper_cooldown_duration
		_:
			variant = VARIANT_SWORD
			display_name = "大剑敌人"
			attack_damage = 25.0
			move_speed = 5.0
			attack_start_range = 2.6
			aggro_range = 12.0
			windup_duration = 0.62
			recovery_duration = 0.8


func _normalize_variant(kind: StringName) -> StringName:
	var text := String(kind).to_lower()
	if text in ["boxer", "pugilist", "拳击手"]:
		return VARIANT_BOXER
	if text in ["sniper", "sniper_rifle", "狙击手"]:
		return VARIANT_SNIPER
	return VARIANT_SWORD


func _set_visibility_target(target: float) -> void:
	_visibility_target = clampf(target, 0.0, 1.0)


func _apply_visibility() -> void:
	if not is_instance_valid(_variant_visual):
		return
	# At exactly zero alpha the renderer should not keep a transparent shell or
	# shadow alive. The next reveal tick turns the root back on before the ghost
	# shader becomes visible.
	_variant_visual.visible = _visibility_alpha > 0.001
	if is_instance_valid(_body_pivot) and not _variant_model_imported:
		_body_pivot.visible = not is_optically_hidden()
	# Base model updates reset the warning visibility every frame. Keep helper
	# synchronization independent from expensive material updates below.
	var fully_visible := is_fully_revealed()
	if is_instance_valid(_health_label):
		_health_label.visible = fully_visible
	if is_instance_valid(_warning):
		_warning.visible = state == &"windup" and fully_visible
	if is_instance_valid(_slash_arc):
		_slash_arc.visible = state == &"strike" and fully_visible
	if _cloak_records.is_empty():
		_setup_cloak_material()
	if _cloak_material == null:
		return
	if _applied_cloak_alpha == _visibility_alpha:
		return
	_applied_cloak_alpha = _visibility_alpha
	# 0.0: no renderer shell. 0.0-0.40: the building-style hologram grows
	# from nothing. 0.40-1.0: the textured character fades in while the same
	# hologram fades out. The model only returns to its original materials at
	# the end, so this never reads as a blue tint suddenly becoming opaque.
	var ghost_phase := _visibility_alpha < CLOAK_BODY_THRESHOLD
	var body_progress := clampf(inverse_lerp(CLOAK_BODY_THRESHOLD, 1.0, _visibility_alpha), 0.0, 1.0)
	var ghost_fade := clampf(_visibility_alpha / CLOAK_BODY_THRESHOLD, 0.0, 1.0)
	if not ghost_phase:
		ghost_fade = 1.0 - body_progress
	_cloak_material.set_shader_parameter("fade", ghost_fade)
	for record: Dictionary in _cloak_records:
		var geometry: GeometryInstance3D = record["node"]
		if not is_instance_valid(geometry):
			continue
		if ghost_phase:
			geometry.material_override = _cloak_material
			# The authored overlay must not leak through the fully concealed phase.
			geometry.material_overlay = null
			geometry.transparency = 0.0
			_restore_surface_overrides(geometry, record["surfaces"])
			# A cloaked enemy must not give away its position through a normal
			# character shadow while its body is fading out.
			geometry.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		else:
			var fully_restored := fully_visible
			# Active materials were cached per surface, including any authored
			# override. Clearing this override lets those fade copies render.
			geometry.material_override = record["material"] if fully_restored else null
			geometry.material_overlay = record["overlay"] if fully_restored else _cloak_material
			geometry.transparency = float(record["transparency"])
			if not fully_restored:
				_apply_fade_surfaces(record["surfaces"], record["fade_materials"], record["base_alphas"], body_progress, geometry)
			else:
				_restore_surface_overrides(geometry, record["surfaces"])
			geometry.cast_shadow = record["cast_shadow"] if fully_restored else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _setup_cloak_material() -> void:
	_cloak_records.clear()
	_applied_cloak_alpha = -1.0
	if not is_instance_valid(_variant_visual):
		return
	_cloak_material = ShaderMaterial.new()
	_cloak_material.shader = CLOAK_SHADER
	# Match the building occlusion palette and travelling line speed. The
	# `fade` uniform is updated every frame by _apply_visibility().
	_cloak_material.set_shader_parameter("base_color", Color(0.08, 0.32, 0.48, 1.0))
	_cloak_material.set_shader_parameter("highlight_color", Color(0.20, 0.84, 1.0, 1.0))
	_cloak_material.set_shader_parameter("line_color", Color(0.40, 0.94, 1.0, 1.0))
	_cloak_material.set_shader_parameter("opacity", 0.68)
	_cloak_material.set_shader_parameter("line_speed", 0.9)
	_cloak_material.set_shader_parameter("line_density", 3.2)
	_cloak_material.set_shader_parameter("grid_density", 0.18)
	_cloak_material.set_shader_parameter("line_strength", 0.84)
	_cloak_material.set_shader_parameter("fade", 0.0)
	var visual_root := _variant_visual if _variant_model_imported else _body_pivot
	for node in visual_root.find_children("*", "MeshInstance3D", true, false):
		var geometry := node as GeometryInstance3D
		if geometry == null:
			continue
		var surfaces: Array[Dictionary] = []
		var fade_materials: Array[Material] = []
		var base_alphas: Array[float] = []
		if geometry is MeshInstance3D and (geometry as MeshInstance3D).mesh != null:
			var mesh := (geometry as MeshInstance3D).mesh
			for surface_index in range(mesh.get_surface_count()):
				var surface_material: Material = geometry.get_active_material(surface_index)
				var fade_material: Material = _make_fade_material(surface_material)
				surfaces.append({"index": surface_index, "material": geometry.get_surface_override_material(surface_index)})
				fade_materials.append(fade_material)
				base_alphas.append(_material_alpha(surface_material))
		_cloak_records.append({
			"node": geometry,
			"material": geometry.material_override,
			"overlay": geometry.material_overlay,
			"transparency": geometry.transparency,
			"cast_shadow": geometry.cast_shadow,
			"surfaces": surfaces,
			"fade_materials": fade_materials,
			"base_alphas": base_alphas,
		})


func _restore_surface_overrides(geometry: GeometryInstance3D, surfaces: Array) -> void:
	if not geometry is MeshInstance3D:
		return
	for surface: Dictionary in surfaces:
		(geometry as MeshInstance3D).set_surface_override_material(int(surface["index"]), surface["material"])


func _apply_fade_surfaces(surfaces: Array, fade_materials: Array, base_alphas: Array, progress: float, geometry: GeometryInstance3D) -> void:
	if not geometry is MeshInstance3D:
		return
	var mesh := geometry as MeshInstance3D
	for index in range(surfaces.size()):
		var fade_material: Material = fade_materials[index]
		if fade_material is BaseMaterial3D:
			var color := (fade_material as BaseMaterial3D).albedo_color
			color.a = float(base_alphas[index]) * clampf(progress, 0.0, 1.0)
			(fade_material as BaseMaterial3D).albedo_color = color
		mesh.set_surface_override_material(int(surfaces[index]["index"]), fade_material)


func _make_fade_material(source: Material) -> Material:
	if source == null:
		var fallback := StandardMaterial3D.new()
		fallback.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		return fallback
	if source is BaseMaterial3D:
		var duplicate := source.duplicate() as BaseMaterial3D
		duplicate.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		return duplicate
	return source


func _material_alpha(source: Material) -> float:
	return (source as BaseMaterial3D).albedo_color.a if source is BaseMaterial3D else 1.0


func _play_variant_animation(intent: StringName) -> void:
	if not is_instance_valid(_variant_animation):
		return
	var names: Array[String] = []
	for library_name in _variant_animation.get_animation_library_list():
		var library := _variant_animation.get_animation_library(library_name)
		for animation_name in library.get_animation_list():
			names.append(String(animation_name))
	if names.is_empty():
		return
	if variant == VARIANT_SWORD:
		if intent in [&"idle", &"retreat", &"recovery"]:
			# Let the imported Slash clip finish its follow-through while the AI
			# backs away. Only a fresh idle/recovery needs to snap to the guard
			# pose; restarting it at retreat would erase the visible swing.
			if intent != &"idle" and _variant_animation.current_animation == "Slash_001" and _variant_animation.is_playing():
				return
			# There is no authored idle clip. Hold the relaxed guard pose from
			# the end of Slash_001 instead of using the defeat animation as idle.
			if "Slash_001" in names:
				_variant_animation.play("Slash_001")
				_variant_animation.seek(SWORD_IDLE_TIME, true)
				_variant_animation.pause()
			else:
				_variant_animation.stop()
			return
		if intent == &"dead":
			if "defeat_03_001" in names:
				_variant_animation.play("defeat_03_001")
			return
		if intent == &"hit":
			if "hit_to_head_001" in names:
				_variant_animation.play("hit_to_head_001")
			return
		if intent in [&"windup", &"attack"] and "Slash_001" in names:
			# Keep the clip running from its telegraph start into the active
			# strike; restarting at the state boundary would skip the swing.
			if intent == &"windup" or _variant_animation.current_animation != "Slash_001":
				_variant_animation.play("Slash_001")
				_variant_animation.seek(SWORD_SLASH_START_TIME if intent == &"windup" else SWORD_SLASH_HIT_TIME, true)
			return
		return
	if variant == VARIANT_SNIPER:
		# Keep the long root-motion `shoot_001` clip for the visible two-second
		# telegraph.  Fire and cooldown use the short standing clip so the AI's
		# movement controller remains the only source of world translation.
		var preferred := ""
		match intent:
			&"aim": preferred = "shoot_001"
			&"fire", &"cooldown", &"retreat", &"idle": preferred = "fire_001"
		if preferred in names:
			_variant_animation.play(preferred)
			return
	# Choose clips by role instead of relying on the importer order. In
	# particular, `hit_to_head_001` contains the word "hit" but is a reaction
	# clip, not the boxer's attack.
	var preferred_tokens: Array = []
	match variant:
		VARIANT_BOXER:
			preferred_tokens = ["box_01", "box_02"] if intent in [&"attack", &"aim", &"windup"] else ["idle", "box_01"]
		VARIANT_SNIPER:
			# `shoot_001` contains root motion and a prone transition. Use the
			# short standing clip for the two-second telegraph and the shot.
			preferred_tokens = ["fire"] if intent in [&"aim", &"fire", &"cooldown"] else ["idle", "fire"]
		_:
			preferred_tokens = ["idle", "stand", "walk"]
	var selected := names[0]
	for token in preferred_tokens:
		for name in names:
			if name.to_lower().contains(token):
				selected = name
				break
		if selected.to_lower().contains(token):
			break
	_variant_animation.play(selected)


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var result := _find_animation_player(child)
		if result != null:
			return result
	return null


func _find_node_by_name(node: Node, names: Array[String]) -> Node3D:
	if node is Node3D and String(node.name) in names:
		return node as Node3D
	for child in node.get_children():
		var result := _find_node_by_name(child, names)
		if result != null:
			return result
	return null
