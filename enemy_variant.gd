extends "res://enemy.gd"
## Street enemy variants used by the first-floor encounters.
##
## The base enemy remains the deterministic training opponent.  This subclass
## keeps its damage/take_damage API and collision behaviour, but gives street
## encounters three readable patterns:
##   sword  - slow, high-damage melee, then retreats to recover;
##   boxer  - fast, low-damage melee; its first approach starts concealed and
##            fades into view while it rushes the player;
##   sniper - a stationary sentry. It never leaves its nest, holds a frozen
##            firing pose under the optical cloak, warns the player the moment
##            they enter its firing range, and shoots down a visible tracer.
##            Only a direct hit exposes its body, and it stays exposed until
##            the knockdown animation takes it down.

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
## `Slash_001` is 3.00 s long and holds the whole fight: the rig stands in guard
## until 0.60 s, raises the greatsword from 0.60 s to the apex at 1.10 s, chops
## through 1.25-1.85 s (fastest wrist travel around 1.55 s), settles back into
## guard by 2.40 s and holds that pose to the end. The controller starts the clip
## on its authored preparation pose, commits the strike exactly when the blade
## reaches the chop, and keeps the clip running through the follow-through
## instead of seeking backwards into the guard pose.
const SWORD_SLASH_CLIP := "Slash_001"
const SWORD_SLASH_START_TIME := 0.48
const SWORD_SLASH_HIT_TIME := 1.55
const SWORD_SLASH_FOLLOW_TIME := 1.95
const SWORD_IDLE_TIME := 2.35
## The greatsword is meant to feel heavy, so the whole clip plays at 0.72x and
## the 3 s slash stretches to about 4.2 s of wall time. The telegraph and the
## active window are *derived* from this factor, so the hitbox always coincides
## with the authored impact pose instead of drifting against the animation.
## This single number is the slow-motion knob: lower it for a heavier, more
## deliberate wind-up, raise it towards 1.0 for the authored clip speed.
const SWORD_SWING_SPEED := 0.72
const SWORD_WINDUP_DURATION := (SWORD_SLASH_HIT_TIME - SWORD_SLASH_START_TIME) / SWORD_SWING_SPEED
const SWORD_STRIKE_DURATION := (SWORD_SLASH_FOLLOW_TIME - SWORD_SLASH_HIT_TIME) / SWORD_SWING_SPEED
## The committed, no-longer-tracking tail of the telegraph. Longer than the
## training foe's 0.30 s because every part of this swing is slower.
const SWORD_AIM_LOCK_DURATION := 0.45
## Yaw rate the rig uses while turning to face the player. Snapping the heading
## every frame made the greatsword slide sideways; a limited turn makes the
## lock-on readable instead (a half turn takes about 0.45 s).
const VARIANT_TURN_SPEED := 7.0
## `shoot_001` walks the rig forward and drops it prone (authored root motion),
## which fights a sentry that must not move. The standing `fire_001` clip is the
## only sniper clip the controller plays; both the hold pose and the shot read
## from it. `defeat_03_001` is the authored knockdown.
const SNIPER_SHOT_CLIP := "fire_001"
const SNIPER_DEFEAT_CLIP := "defeat_03_001"
## Solved muzzle point of the assembled rifle. The constant is expressed in the
## weapon's own vertex space (centimetres), the same space
## model/sniper_rifle/README.md §4 measures the grip and barrel in, so it has to
## be transformed by the rifle node: that transform already carries both the
## assembly's 1.8424 and the weapon's own 0.00669371 scale.
const SNIPER_MUZZLE_LOCAL := Vector3(-47.85, 10.10, 22.45)
## Fallback shot origin when the rifle assembly is unavailable. Matches the
## shoulder height of the 1.8 m street presentation.
const SNIPER_MUZZLE_HEIGHT := 1.45
## The round stays a travelling projectile rather than a hitscan line, but at
## the tuned 50 m/s a 20 m shot crosses in about 0.4 s, so the round's own
## travel reads as a fast snap. Readability therefore comes from the bright cyan
## streak and from the 0.55 s frozen trail left at the impact point, which stays
## on screen long after the round itself has landed.
const SNIPER_BULLET_CORE_RADIUS := 0.085
const SNIPER_BULLET_HEAD_RADIUS := 0.14
## Seconds the frozen streak stays on screen after the round lands or is stopped
## by cover. This tail is what makes the trajectory readable after the fact.
const SNIPER_TRAIL_LINGER := 0.55
const SNIPER_FLASH_LIFETIME := 0.20
const SNIPER_FLASH_RADIUS := 0.24
## Muzzle flash light. Short and bright: it marks the firing point of an
## otherwise invisible rifle for a fraction of a second.
const SNIPER_MUZZLE_LIGHT_ENERGY := 6.0
const SNIPER_MUZZLE_LIGHT_RANGE := 9.0
## Street health for the two variants that are not the boxer. This is the same
## number as the base class default; it is written explicitly so that
## `_apply_variant_stats()` is complete for every variant. Without it,
## re-configuring a live instance from `boxer` back to `sword` or `sniper` would
## leave the boxer's 55 HP behind, since only the boxer branch writes max_health.
const STREET_ENEMY_HEALTH := 100.0

## StringName keeps runtime comparisons allocation-free; the inspector can
## still set the same values even without the typed enum annotation.
@export var variant: StringName = VARIANT_SWORD
@export var retreat_distance: float = 4.5
@export var retreat_speed: float = 4.2
## Authored sentry round damage. `attack_damage` is the value that actually
## resolves the hit, so this field stays pinned to the unscaled base and a floor
## multiplier is applied to `attack_damage` only.
const AUTHORED_SNIPER_DAMAGE: float = 20.0
@export var sniper_damage: float = AUTHORED_SNIPER_DAMAGE
## Range at which the sentry wakes, warns the player and opens fire. It is the
## same number for all three so the prompt never fires without the threat.
@export var sniper_max_distance: float = 20.0
@export var sniper_aim_duration: float = 1.6
@export var sniper_fire_duration: float = 0.14
@export var sniper_cooldown_duration: float = 2.8
## Travel speed of the round in metres per second. Lower is easier to read and
## easier to dodge; raise it towards hitscan by making it very large.
@export var sniper_bullet_speed: float = 50.0
## Radius around the round's flight path that still counts as hitting a body.
@export var sniper_bullet_hit_radius: float = 0.6
## Seconds the sentry is barred from firing after every accepted hit. Each new
## hit restarts the window, so sustained fire keeps the rifle silent.
@export var sniper_suppression_duration: float = 3.0
## How long the body takes to materialize once a hit exposes it.
@export var sniper_reveal_duration: float = 0.55
## Normalized point inside the standing shot clip that the concealed sentry
## freezes on. 0.5 of `fire_001` is the authored aim, before the recoil.
@export_range(0.0, 1.0, 0.05) var sniper_hold_pose_fraction: float = 0.5
@export var boxer_reveal_distance: float = 5.8
@export var boxer_reveal_duration: float = 0.72
## Set false on a lesson foe that must be read from the first frame, such as the
## onboarding training opponent: the boxer then stands fully materialized instead
## of spending its first approach under the optical cloak. Street encounters keep
## the default so the concealed first rush is unchanged.
@export var boxer_cloak_enabled: bool = true
## Boxer activation starts at `aggro_range`; once an encounter is active it
## may keep chasing until this larger leash distance.
@export var boxer_leash_range: float = 20.0
## The boxer's jab is the readable half of the exchange. At 0.20 s of telegraph
## and 0.12 s of active frames the whole attack was over in about a third of a
## second, which is less time than the authored `box_01` punch takes to travel:
## the clip was cut off mid-swing and the fist never read as a punch. These two
## windows are now long enough to be read on sight, and `_boxer_punch_speed`
## stretches the clip across exactly their sum so the fist and the hitbox agree.
@export var boxer_windup_duration: float = 0.6
@export var boxer_active_duration: float = 0.2
## The committed, no-longer-tracking tail of the telegraph. Held at about the
## same share of the wind-up as the greatsword's own 0.45 / 1.49 lock, so a dodge
## started after the red sector locks still beats the punch.
@export var boxer_aim_lock_duration: float = 0.2
## Seconds the boxer stands locked in place once its post-attack retreat ends.
## It cannot walk, re-aim or punch for this whole window: this is the punish
## window a player earns by reading and dodging the jab, and it is what stops the
## boxer from being a source of permanent, unanswerable pressure.
@export var boxer_stun_duration: float = 1.5
## A fast archetype must not be as durable as the slow heavy. The boxer
## inherited the base 100 HP, which made it strictly better than the greatsword
## (same health, 7.4 vs 5.0 m/s) and meant trading hits was never punished.
## At 55 HP three slashes or six punches are enough to close the exchange.
@export var boxer_max_health: float = 55.0
@export var model_scale: float = 1.84
## Per-floor tuning. Later floors raise these instead of editing the archetype
## constants above, so the first floor keeps its exact street numbers, the
## archetype identities (slow heavy / fast fragile / stationary sentry) stay
## intact, and only health and damage change. `apply_stat_multipliers()` is the
## only writer, and it re-runs inside every `reset_enemy()`.
@export var health_multiplier: float = 1.0
@export var damage_multiplier: float = 1.0
## Base health and damage for the current variant, after normalization but
## before the multipliers. Kept so a repeated multiply can never compound.
var _base_max_health: float = STREET_ENEMY_HEALTH
var _base_attack_damage: float = 0.0

var _variant_visual: Node3D
var _variant_animation: AnimationPlayer
var _visibility_alpha: float = 1.0
var _visibility_target: float = 1.0
var _visibility_speed: float = 8.0
var _boxer_first_approach := false
var _boxer_reveal_started := false
var _sniper_shot_done := false
## A sentry starts under the cloak and is only ever exposed by being hit. The
## flag survives cooldown, disengagement and death so the body never flickers.
var _sniper_revealed := false
var _sniper_range_warning := false
## Seconds left of the post-hit firing lockout.
var _sniper_suppression_left := 0.0
var _sniper_muzzle: Node3D
var _sniper_weapon_mount: Node3D
var _sniper_rifle: Node3D
var _sniper_tracers: Array[Dictionary] = []
var _sniper_assembly_loaded := false
## Exposed for tests and HUD diagnostics: the last resolved trajectory.
var last_shot_origin := Vector3.ZERO
var last_shot_target := Vector3.ZERO
var last_shot_blocked := false
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


## Floor-level tuning hook. The street encounter calls this before the enemy
## enters the tree; a floor with no scaling keeps 1.0 / 1.0 and therefore the
## original first-floor numbers.
func apply_stat_multipliers(health_scale: float, damage_scale: float) -> void:
	health_multiplier = maxf(0.01, health_scale)
	damage_multiplier = maxf(0.01, damage_scale)
	_apply_variant_stats()
	if is_inside_tree():
		reset_enemy()


func get_stat_multipliers() -> Vector2:
	return Vector2(health_multiplier, damage_multiplier)


func set_variant(kind: StringName) -> void:
	configure_variant(kind)


func get_variant_kind() -> StringName:
	return variant


func take_damage(amount: float) -> bool:
	var accepted := super.take_damage(amount)
	if not accepted:
		return accepted
	if variant == VARIANT_SNIPER:
		_expose_sniper()
		return accepted
	if variant != VARIANT_SWORD:
		return accepted
	if is_dead:
		_play_variant_animation(&"dead")
	elif state not in [&"windup", &"strike"]:
		# Do not interrupt a committed attack. Outside an attack, use the new
		# GLB's short reaction clip and return to the guard pose afterward.
		_play_variant_animation(&"hit")
	return accepted


## A direct hit is the only thing that drops a sentry's optical cloak, and it is
## also what silences the rifle: every accepted hit restarts a full
## `sniper_suppression_duration` window during which the sentry may not fire, and
## aborts whatever aim cycle was already running. Pressing the attack is
## therefore the counterplay, not just the reveal.
func _expose_sniper() -> void:
	_sniper_revealed = true
	_sniper_suppression_left = sniper_suppression_duration
	_visibility_speed = 1.0 / maxf(sniper_reveal_duration, 0.05)
	_set_visibility_target(1.0)
	if is_dead:
		_clear_range_warning()
		_play_variant_animation(&"dead")
	elif state != &"idle":
		# Cancel the telegraph in place. The committed shot never resolves because
		# the state is dropped before it can reach `sniper_fire`.
		state = &"idle"
		state_time_left = 0.0
		_sniper_shot_done = true
		_play_variant_animation(&"idle")
	_apply_visibility()


## Remaining seconds of the post-hit firing lockout. Exposed for tests and HUD.
func get_sniper_suppression_left() -> float:
	return _sniper_suppression_left if variant == VARIANT_SNIPER else 0.0


func is_suppressed() -> bool:
	return variant == VARIANT_SNIPER and _sniper_suppression_left > 0.0


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
	if variant == VARIANT_SNIPER:
		_clear_range_warning()
		_play_variant_animation(&"idle")
	elif variant == VARIANT_SWORD:
		_play_variant_animation(&"idle")
	_update_model()


func is_optically_hidden() -> bool:
	# Match the renderer's root visibility threshold exactly: a hidden enemy has
	# no body, weapon, or shadow left to disclose its position.
	return _visibility_alpha <= 0.001


## True once this enemy's cloak is permanently gone. The boxer and sword always
## answer true (they are only ever briefly concealed during a first approach);
## the sentry answers true only after a hit has exposed it, which is also what
## the city map uses to decide whether its nest may be plotted.
func is_permanently_revealed() -> bool:
	if variant != VARIANT_SNIPER:
		return true
	return _sniper_revealed


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
		"sniper_revealed": _sniper_revealed,
		"sniper_in_range": _sniper_range_warning,
		"sniper_suppression_left": _sniper_suppression_left,
		"shot_in_flight": is_shot_in_flight(),
		"last_shot_origin": last_shot_origin,
		"last_shot_target": last_shot_target,
		"last_shot_blocked": last_shot_blocked,
		"health": health,
	}


func reset_enemy() -> void:
	_apply_variant_stats()
	super.reset_enemy()
	_boxer_first_approach = variant == VARIANT_BOXER and boxer_cloak_enabled
	_boxer_reveal_started = false
	_sniper_shot_done = false
	_sniper_revealed = false
	_sniper_suppression_left = 0.0
	_clear_range_warning()
	_clear_sniper_tracers()
	_visibility_alpha = 0.0 if _starts_concealed() else 1.0
	_visibility_target = 1.0
	if _starts_concealed():
		_set_visibility_target(0.0)
	else:
		_set_visibility_target(1.0)
	_play_variant_animation(&"idle")
	_apply_visibility()


## Only the boxer's first approach and the sentry's cloak begin invisible. A
## lesson boxer opts out through `boxer_cloak_enabled`.
func _starts_concealed() -> bool:
	if variant == VARIANT_BOXER:
		return boxer_cloak_enabled
	return variant == VARIANT_SNIPER


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
	_sniper_weapon_mount = null
	_sniper_rifle = null
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
	# Apply the multiplier on top of the instantiated root's authored scale.
	# Assigning it outright used to erase the assembly's own 1.8424 factor and
	# left the sniper at the raw 0.977 m GLB height — roughly half the size of
	# the player and of every other street variant.
	_variant_visual.scale *= visual_scale
	# Every street rig — the player, the boxer, the sniper and the sword — is
	# authored facing +Z: the imported skeleton's toe chain runs from the ankle
	# towards +Z, and a camera sitting on +Z sees the face rather than the back.
	# The controller's forward is -Z, so each imported root needs a half turn.
	# Leaving the greatsword unrotated made it walk *and* swing with its back to
	# the player, which is what made the slash read as backwards and wrong.
	_variant_visual.rotation.y = PI
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
	_sniper_weapon_mount = _find_node_by_name(_variant_visual, ["WeaponMount"])
	_sniper_rifle = _find_node_by_name(_variant_visual, ["Rifle"])
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


## A despawned sentry cannot clear its own prompt. The player prunes freed
## reporters lazily, so retire the range warning the moment the node leaves the
## tree; that covers `queue_free()` during a floor rebuild.
func _exit_tree() -> void:
	if variant == VARIANT_SNIPER:
		_clear_range_warning()


func _physics_process(delta: float) -> void:
	# The base implementation supplies gravity, move_and_slide, common damage,
	# and the single-hit melee geometry.  Our custom sniper states deliberately
	# avoid the base `state == strike` branch and apply a single ray-shot below.
	_visibility_alpha = move_toward(_visibility_alpha, _visibility_target, _visibility_speed * delta)
	super._physics_process(delta)
	_advance_sniper_tracers(delta)
	if variant != VARIANT_SNIPER:
		return
	# A sentry is exposed only by a hit. Everything else — cooldown, leaving the
	# street trigger, dying mid-telegraph — keeps it cloaked.
	_set_visibility_target(1.0 if _sniper_revealed else 0.0)
	# The firing lockout is a property of the rifle, not of the encounter, so it
	# keeps running while the sentry is disengaged or out of range.
	_sniper_suppression_left = maxf(0.0, _sniper_suppression_left - delta)
	if not combat_enabled or is_dead:
		# The base controller drops the encounter or the actor on this frame, so
		# the prompt must not outlive the threat.
		_update_sniper_range_warning(false)


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
				# The boxer's hit-and-run identity is kept: it still breaks off
				# and opens the gap first. The stun then lands on top of that
				# retreat rather than replacing it, so the punish window is
				# "it backed off and is now standing still", not "it froze in
				# the player's face". During the stun the boxer is fully inert:
				# the recovery branch below zeroes its velocity every frame and
				# no attack can start until the timer expires.
				state_time_left = boxer_stun_duration if is_boxer else 0.8
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
	# The greatsword commits to a far slower and harder-hitting swing than the
	# boxer's jab: its telegraph and active window are the authored clip timings
	# divided by the slow-motion playback factor, so the strike lands on the
	# chop instead of on the raised apex. The boxer's windows are authored
	# directly and its clip is stretched to match them (`_boxer_punch_speed`).
	windup_duration = boxer_windup_duration if is_boxer else SWORD_WINDUP_DURATION
	aim_lock_duration = boxer_aim_lock_duration if is_boxer else SWORD_AIM_LOCK_DURATION
	active_duration = boxer_active_duration if is_boxer else SWORD_STRIKE_DURATION
	state_time_left = windup_duration
	_hit_this_swing = false
	if not offset.is_zero_approx():
		attack_direction = offset.normalized()
		_heading.rotation.y = _direction_yaw(attack_direction)
	_play_variant_animation(&"aim" if is_boxer else &"windup")


## Stationary sentry loop. The sniper never walks: it holds the spawn point,
## faces the player, fires while they stand inside its range, and stays under
## the cloak until a hit exposes it.
func _update_sniper(delta: float) -> void:
	# Movement stays disabled in every state, including the dead pose.
	velocity.x = 0.0
	velocity.z = 0.0
	var offset := _actor.global_position - global_position
	offset.y = 0.0
	var distance := offset.length()
	var in_range := distance <= sniper_max_distance
	_update_sniper_range_warning(in_range)
	if not offset.is_zero_approx():
		attack_direction = offset.normalized()
		_heading.rotation.y = _direction_yaw(attack_direction)
	# A recent hit locks the trigger, whether or not the player is still inside
	# the range. The lockout itself counts down in `_physics_process` so leaving
	# the fight cannot pause it.
	if _sniper_suppression_left > 0.0:
		if state != &"idle":
			state = &"idle"
			state_time_left = 0.0
			_play_variant_animation(&"idle")
		return
	if not in_range:
		# Out of range the sentry simply keeps holding the firing pose.
		if state != &"idle":
			state = &"idle"
			state_time_left = 0.0
			_play_variant_animation(&"idle")
		return
	match state:
		&"idle", &"chase":
			_begin_sniper_aim()
		&"sniper_aim":
			state_time_left = maxf(0.0, state_time_left - delta)
			if state_time_left <= 0.0:
				state = &"sniper_fire"
				state_time_left = sniper_fire_duration
				_sniper_shot_done = false
				_play_variant_animation(&"fire")
		&"sniper_fire":
			if not _sniper_shot_done:
				_sniper_shot_done = true
				_fire_sniper()
			state_time_left = maxf(0.0, state_time_left - delta)
			if state_time_left <= 0.0:
				state = &"sniper_cooldown"
				state_time_left = sniper_cooldown_duration
				_play_variant_animation(&"cooldown")
		&"sniper_cooldown":
			state_time_left = maxf(0.0, state_time_left - delta)
			if state_time_left <= 0.0:
				state = &"idle"
				_play_variant_animation(&"idle")


func _begin_sniper_aim() -> void:
	state = &"sniper_aim"
	state_time_left = sniper_aim_duration
	_sniper_shot_done = false
	_play_variant_animation(&"aim")


## Entering the firing range is the player's only warning that an unseen rifle
## is already trained on them; leaving it clears the prompt again.
func _update_sniper_range_warning(in_range: bool) -> void:
	if in_range == _sniper_range_warning:
		return
	_sniper_range_warning = in_range
	_report_sniper_range_warning()


func _clear_range_warning() -> void:
	_sniper_range_warning = false
	_report_sniper_range_warning()


func _report_sniper_range_warning() -> void:
	if not is_instance_valid(_actor) or not _actor.has_method("set_threat_warning"):
		return
	_actor.call("set_threat_warning", self, "⚠ 进入狙击手射程", _sniper_range_warning)


func _sniper_shot_origin() -> Vector3:
	# Prefer the barrel tip of the assembled rifle so the tracer leaves the
	# muzzle rather than an abstract shoulder point. `is_mounted()` guards
	# against a weapon mount that has not locked onto the hand bone yet, which
	# would otherwise park the muzzle at the rig's feet.
	if is_instance_valid(_sniper_rifle) and _sniper_weapon_mounted():
		return _sniper_rifle.global_transform * SNIPER_MUZZLE_LOCAL
	if is_instance_valid(_sniper_muzzle):
		return _sniper_muzzle.global_position
	return global_position + Vector3.UP * SNIPER_MUZZLE_HEIGHT


func _sniper_weapon_mounted() -> bool:
	if not is_instance_valid(_sniper_weapon_mount):
		return false
	if not _sniper_weapon_mount.has_method("is_mounted"):
		return true
	return bool(_sniper_weapon_mount.call("is_mounted"))


func _fire_sniper() -> void:
	if is_dead or is_suppressed() or not is_instance_valid(_actor) or _actor.is_dead:
		return
	var origin := _sniper_shot_origin()
	var target := _actor.global_position + Vector3.UP * 0.85
	var ray := PhysicsRayQueryParameters3D.create(origin, target, 1)
	var exclusions: Array[RID] = [get_rid(), _actor.get_rid()]
	ray.exclude = exclusions
	var blocked := get_world_3d().direct_space_state.intersect_ray(ray)
	# The trajectory is drawn whether or not the shot lands: a streak that stops
	# on a corner is the player's proof that cover worked.
	var impact := target
	last_shot_blocked = false
	if not blocked.is_empty():
		impact = blocked["position"]
		last_shot_blocked = true
	last_shot_origin = origin
	last_shot_target = impact
	_launch_sniper_round(origin, impact, last_shot_blocked)


## Launch one travelling round. The line is solved here, once, against world
## geometry; the body check happens every frame along the flown segment, so the
## visible trajectory is exactly what decides the hit.
func _launch_sniper_round(from: Vector3, to: Vector3, blocked: bool) -> void:
	var offset := to - from
	var distance := offset.length()
	if distance <= 0.01:
		return
	_sniper_tracers.append({
		"origin": from,
		"direction": offset / distance,
		"distance": distance,
		"traveled": 0.0,
		"elapsed": 0.0,
		"speed": maxf(sniper_bullet_speed, 1.0),
		"blocked": blocked,
		"arrived": false,
		"life": 0.0,
		"beam": _make_sniper_beam(),
		"head": _make_sniper_round_head(),
		"flash": _make_sniper_flash(from),
	})


func _make_sniper_beam() -> MeshInstance3D:
	var beam := MeshInstance3D.new()
	beam.name = "SniperTracerBeam"
	var mesh := CylinderMesh.new()
	mesh.top_radius = SNIPER_BULLET_CORE_RADIUS
	mesh.bottom_radius = SNIPER_BULLET_CORE_RADIUS
	# Unit height: the flown segment is applied as a Y scale every frame.
	mesh.height = 1.0
	mesh.radial_segments = 12
	beam.mesh = mesh
	beam.material_override = _make_sniper_glow_material(Color("d8fbff"), Color("21e6ff"), 7.0, 0.98)
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beam.visible = false
	add_child(beam)
	# World space, so the streak never inherits the sentry's facing rotation.
	beam.top_level = true
	return beam


func _make_sniper_round_head() -> MeshInstance3D:
	var head := MeshInstance3D.new()
	head.name = "SniperTracerHead"
	var mesh := SphereMesh.new()
	mesh.radius = SNIPER_BULLET_HEAD_RADIUS
	mesh.height = SNIPER_BULLET_HEAD_RADIUS * 2.0
	mesh.radial_segments = 10
	mesh.rings = 6
	head.mesh = mesh
	head.material_override = _make_sniper_glow_material(Color("e9ffff"), Color("24f3ff"), 8.0, 1.0)
	head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(head)
	head.top_level = true
	# A short-lived light riding the round: this is what makes the trajectory
	# unmistakable on the wet street without depending on bloom.
	var light := OmniLight3D.new()
	light.name = "SniperRoundLight"
	light.light_color = Color("36edff")
	light.light_energy = 5.5
	light.omni_range = 10.0
	light.shadow_enabled = false
	head.add_child(light)
	return head


func _make_sniper_flash(at: Vector3) -> MeshInstance3D:
	var flash := MeshInstance3D.new()
	flash.name = "SniperTracerFlash"
	var mesh := SphereMesh.new()
	mesh.radius = SNIPER_FLASH_RADIUS
	mesh.height = SNIPER_FLASH_RADIUS * 2.0
	mesh.radial_segments = 10
	mesh.rings = 6
	flash.mesh = mesh
	flash.material_override = _make_sniper_glow_material(Color("efffff"), Color("32efff"), 10.0, 1.0)
	flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(flash)
	flash.top_level = true
	# A brief muzzle light: the streak says where the round is going, this says
	# exactly where the concealed rifle fired from. It rides the same fade as
	# the flash mesh and is toggled with it.
	var light := OmniLight3D.new()
	light.name = "SniperMuzzleLight"
	light.light_color = Color("46f0ff")
	light.light_energy = SNIPER_MUZZLE_LIGHT_ENERGY
	light.omni_range = SNIPER_MUZZLE_LIGHT_RANGE
	light.shadow_enabled = false
	flash.add_child(light)
	flash.global_position = at
	return flash


func _make_sniper_glow_material(albedo: Color, emission: Color, energy: float, alpha: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(albedo, alpha)
	material.emission_enabled = true
	material.emission = emission
	material.emission_energy_multiplier = energy
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material


func _advance_sniper_tracers(delta: float) -> void:
	if _sniper_tracers.is_empty():
		return
	for index in range(_sniper_tracers.size() - 1, -1, -1):
		var round_data: Dictionary = _sniper_tracers[index]
		if bool(round_data["arrived"]):
			round_data["life"] = float(round_data["life"]) - delta
			if float(round_data["life"]) <= 0.0:
				_free_sniper_round(round_data)
				_sniper_tracers.remove_at(index)
			else:
				_fade_sniper_round(round_data, float(round_data["life"]) / SNIPER_TRAIL_LINGER)
			continue
		_fly_sniper_round(round_data, delta)


func _fly_sniper_round(round_data: Dictionary, delta: float) -> void:
	var previous := float(round_data["traveled"])
	var distance := float(round_data["distance"])
	var traveled := minf(distance, previous + float(round_data["speed"]) * delta)
	round_data["traveled"] = traveled
	round_data["elapsed"] = float(round_data["elapsed"]) + delta
	_update_sniper_round_visuals(round_data)
	# A body standing on the flown segment stops the round. Cover is already
	# baked into the solved impact point, so a blocked round can never hit.
	if not bool(round_data["blocked"]) and _sniper_round_meets_actor(round_data, previous, traveled):
		round_data["distance"] = traveled
		_land_sniper_round(round_data)
		_apply_sniper_hit()
		return
	if traveled >= distance:
		_land_sniper_round(round_data)


func _land_sniper_round(round_data: Dictionary) -> void:
	round_data["arrived"] = true
	round_data["life"] = SNIPER_TRAIL_LINGER
	# The frozen streak keeps the whole line the round flew, so the trajectory
	# stays readable after the impact instead of leaving with the moving dot.
	_update_sniper_round_visuals(round_data)
	var flash: Node3D = round_data["flash"]
	if is_instance_valid(flash):
		flash.visible = false


func _sniper_round_meets_actor(round_data: Dictionary, from_distance: float, to_distance: float) -> bool:
	if not is_instance_valid(_actor) or _actor.is_dead or to_distance <= from_distance:
		return false
	var origin: Vector3 = round_data["origin"]
	var direction: Vector3 = round_data["direction"]
	var segment_start := origin + direction * from_distance
	var segment_end := origin + direction * to_distance
	var chest := _actor.global_position + Vector3.UP * 0.85
	var closest := Geometry3D.get_closest_point_to_segment(chest, segment_start, segment_end)
	return chest.distance_to(closest) <= sniper_bullet_hit_radius


func _apply_sniper_hit() -> void:
	if not is_instance_valid(_actor) or _actor.is_dead or not _actor.has_method("take_damage"):
		return
	if bool(_actor.call("take_damage", sniper_damage)) and _actor.has_signal("status_changed"):
		_actor.status_changed.emit("狙击命中", false)


func _update_sniper_round_visuals(round_data: Dictionary) -> void:
	var origin: Vector3 = round_data["origin"]
	var direction: Vector3 = round_data["direction"]
	var traveled: float = float(round_data["traveled"])
	var beam: Node3D = round_data["beam"]
	var head: Node3D = round_data["head"]
	if is_instance_valid(beam):
		# The streak grows with the round, so the head is never detached from the
		# line it came from.
		beam.visible = traveled > 0.02
		if beam.visible:
			beam.global_position = origin + direction * (traveled * 0.5)
			beam.quaternion = Quaternion(Vector3.UP, direction)
			beam.scale = Vector3(1.0, maxf(traveled, 0.02), 1.0)
	if is_instance_valid(head):
		head.global_position = origin + direction * traveled
	var flash: Node3D = round_data["flash"]
	if is_instance_valid(flash):
		var flash_alpha := clampf(1.0 - float(round_data["elapsed"]) / SNIPER_FLASH_LIFETIME, 0.0, 1.0)
		flash.visible = flash_alpha > 0.0
		var flash_material: StandardMaterial3D = flash.material_override
		flash_material.albedo_color.a = flash_alpha
		flash.scale = Vector3.ONE * lerpf(1.7, 1.0, flash_alpha)
		# The muzzle light fades with the flash mesh so the firing point reads
		# brightly for a moment and then leaves no light behind.
		var muzzle_light := flash.get_node_or_null("SniperMuzzleLight") as OmniLight3D
		if muzzle_light != null:
			muzzle_light.light_energy = SNIPER_MUZZLE_LIGHT_ENERGY * flash_alpha * flash_alpha


func _fade_sniper_round(round_data: Dictionary, alpha: float) -> void:
	var beam: Node3D = round_data["beam"]
	if is_instance_valid(beam):
		var beam_material: StandardMaterial3D = beam.material_override
		beam_material.albedo_color.a = alpha * 0.92
	var head: Node3D = round_data["head"]
	if is_instance_valid(head):
		var head_material: StandardMaterial3D = head.material_override
		head_material.albedo_color.a = alpha
		head.scale = Vector3.ONE * maxf(alpha, 0.2)


func _free_sniper_round(round_data: Dictionary) -> void:
	for key in ["beam", "head", "flash"]:
		var node: Node = round_data[key]
		if is_instance_valid(node):
			node.queue_free()


func _clear_sniper_tracers() -> void:
	for round_data: Dictionary in _sniper_tracers:
		_free_sniper_round(round_data)
	_sniper_tracers.clear()


## Number of live round effects, in flight or still fading out.
func get_sniper_tracer_count() -> int:
	return _sniper_tracers.size()


## True while a fired round has not reached its impact point yet. Callers that
## need to observe the hit wait on this instead of guessing a frame count.
func is_shot_in_flight() -> bool:
	for round_data: Dictionary in _sniper_tracers:
		if not bool(round_data["arrived"]):
			return true
	return false


func _move_toward(offset: Vector3, delta: float, desired_distance: float, speed: float) -> void:
	if offset.is_zero_approx():
		velocity.x = 0.0
		velocity.z = 0.0
		return
	attack_direction = offset.normalized()
	_turn_heading(offset, delta)
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
	# Backing off never breaks the lock-on: the rig keeps its front on the
	# player while it makes distance.
	_turn_heading(offset, delta)
	velocity.x = away.x * speed
	velocity.z = away.z * speed


## Rate-limited yaw tracking towards the actor. The rig pivots at a fixed speed
## instead of snapping, so the greatsword visibly swings around to face the
## player and only then commits to the telegraph.
func _turn_heading(offset: Vector3, delta: float) -> void:
	if offset.is_zero_approx() or not is_instance_valid(_heading):
		return
	var target_yaw := _direction_yaw(offset)
	_heading.rotation.y = _approach_angle(_heading.rotation.y, target_yaw, VARIANT_TURN_SPEED * delta)


func _approach_angle(current: float, target: float, max_step: float) -> float:
	var difference := wrapf(target - current, -PI, PI)
	if absf(difference) <= max_step:
		return target
	return current + signf(difference) * max_step


func _update_model() -> void:
	# Let the base update warning sectors, attack arc, health label, and hit
	# tint.  It also remains useful as a greybox fallback for missing imports.
	super._update_model()
	if not is_instance_valid(_variant_visual):
		return
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
			# 55 HP so the fast archetype still dies fast. The base 100 made the
			# boxer a straight upgrade over the greatsword, which is slower and
			# hits harder but lived exactly as long.
			max_health = boxer_max_health
			attack_damage = 12.0
			move_speed = 7.4
			attack_start_range = 2.1
			# Enter combat at the original 10 m activation radius. The street
			# encounter supplies the separate 20 m leash while already active.
			aggro_range = 10.0
			windup_duration = boxer_windup_duration
			# The variant state machine drives the post-attack window from
			# `boxer_stun_duration`, not from this field; keep them equal so the
			# HUD and any debug readout agree with the real lock-out.
			recovery_duration = boxer_stun_duration
		VARIANT_SNIPER:
			display_name = "狙击手"
			max_health = STREET_ENEMY_HEALTH
			attack_damage = sniper_damage
			# The sentry never walks, so move_speed is unused; keep it at the
			# street baseline for the shared HUD and debug readouts.
			move_speed = 5.0
			attack_start_range = sniper_max_distance
			# Stay armed for a short band past the firing range so a player
			# pacing on the boundary cannot flicker the prompt on and off.
			aggro_range = sniper_max_distance + 4.0
			windup_duration = sniper_aim_duration
			recovery_duration = sniper_cooldown_duration
		_:
			variant = VARIANT_SWORD
			display_name = "大剑敌人"
			max_health = STREET_ENEMY_HEALTH
			# A slow, committed two-handed chop: about 1.5 s of telegraph for a
			# hit that takes off 40% of the player's health, so it has to be read
			# and dodged rather than traded against.
			attack_damage = 40.0
			move_speed = 5.0
			attack_start_range = 2.6
			aggro_range = 12.0
			windup_duration = SWORD_WINDUP_DURATION
			recovery_duration = 0.8
	# The archetype tables above always write the unscaled numbers, so record
	# them and then apply the current floor's multipliers exactly once.
	_base_max_health = max_health
	_base_attack_damage = attack_damage
	max_health = _base_max_health * health_multiplier
	attack_damage = _base_attack_damage * damage_multiplier
	# `sniper_damage` is a base field, not a second scaled copy of
	# `attack_damage`: `_apply_variant_stats()` runs again on every reset (and
	# the class multiplies `attack_damage` by the floor scale), so feeding the
	# scaled number back into this field would compound the multiplier on each
	# pass. Pin it to the authored value and let `attack_damage`, which is what
	# actually resolves the sentry's hit, carry the floor scaling.
	if variant == VARIANT_SNIPER:
		sniper_damage = AUTHORED_SNIPER_DAMAGE


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
			if intent != &"idle" and _variant_animation.current_animation == SWORD_SLASH_CLIP and _variant_animation.is_playing():
				return
			# There is no authored idle clip. Hold the relaxed guard pose from
			# the end of Slash_001 instead of using the defeat animation as idle.
			if SWORD_SLASH_CLIP in names:
				_variant_animation.play(SWORD_SLASH_CLIP)
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
		if intent in [&"windup", &"attack"] and SWORD_SLASH_CLIP in names:
			# Keep the clip running from its telegraph start into the active
			# strike; restarting at the state boundary would skip the swing.
			if intent == &"windup" or _variant_animation.current_animation != SWORD_SLASH_CLIP:
				# The heavy weapon swings in slow motion: the clip drives the
				# raise, the chop and the follow-through at SWORD_SWING_SPEED.
				# Only the slash is slowed; the reaction and death clips keep
				# full speed.
				_variant_animation.play(SWORD_SLASH_CLIP, -1.0, SWORD_SWING_SPEED)
				_variant_animation.seek(SWORD_SLASH_START_TIME if intent == &"windup" else SWORD_SLASH_HIT_TIME, true)
			return
		return
	if variant == VARIANT_SNIPER:
		# Only the authored standing shot is used. `shoot_001` is a nine-second
		# clip with root motion: it walks the rig forward and lowers it into a
		# prone transition, which fights a sentry that must stay planted on its
		# spawn point. `fire_001` stays in place for the hold pose and the shot.
		var shot_clip := SNIPER_SHOT_CLIP if SNIPER_SHOT_CLIP in names else _sniper_clip_fallback(names)
		if shot_clip.is_empty():
			return
		if intent == &"dead":
			if SNIPER_DEFEAT_CLIP in names:
				_variant_animation.play(SNIPER_DEFEAT_CLIP)
			return
		if intent in [&"aim", &"fire", &"cooldown"]:
			# Let one pass of the clip run from raise to recoil; do not restart
			# it at the aim/fire boundary or the shot would visibly hitch.
			if _variant_animation.current_animation == shot_clip and _variant_animation.is_playing():
				return
			_variant_animation.play(shot_clip)
			return
		# Concealed idle, disengagement and reset all freeze the same authored
		# aim frame: the sentry must not move while it is invisible.
		_variant_animation.play(shot_clip)
		_variant_animation.seek(_sniper_hold_pose_time(shot_clip), true)
		_variant_animation.pause()
		return
	if variant == VARIANT_BOXER:
		var punch_clip := _boxer_attack_clip(names)
		match intent:
			&"windup", &"aim":
				if not punch_clip.is_empty():
					# Start the authored jab once, stretched across the whole
					# telegraph plus the active window, so the punch reads as one
					# continuous motion instead of a 0.32 s flash of the clip's
					# opening frames.
					_variant_animation.play(punch_clip, -1.0, _boxer_punch_speed(punch_clip))
					return
			&"attack":
				# Let the telegraph's clip run straight into the strike. The
				# strike state is the frame the hitbox opens, so restarting the
				# clip here would snap the fist back to the top of the wind-up
				# exactly when it is supposed to be landing. An empty clip name
				# must not be compared against `current_animation`: a stopped
				# AnimationPlayer reports "" and would silently skip the pose.
				if not punch_clip.is_empty() and _variant_animation.current_animation == punch_clip and _variant_animation.is_playing():
					return
				if not punch_clip.is_empty():
					_variant_animation.play(punch_clip, -1.0, _boxer_punch_speed(punch_clip))
					return
		# idle / retreat / recovery / hit / dead / reveal keep the shared role
		# lookup below: the boxer has no authored idle clip, so it returns to the
		# `box_01` pose exactly as it did before.
	# Choose clips by role instead of relying on the importer order. In
	# particular, `hit_to_head_001` contains the word "hit" but is a reaction
	# clip, not the boxer's attack. The sniper returned above.
	var preferred_tokens: Array = []
	match variant:
		VARIANT_BOXER:
			preferred_tokens = ["box_01", "box_02"] if intent in [&"attack", &"aim", &"windup"] else ["idle", "box_01"]
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


## Last-resort clip lookup if the delivery renames `fire_001`. `shoot_001` is
## deliberately never selected here because of its authored root motion.
func _sniper_clip_fallback(names: Array[String]) -> String:
	for name in names:
		var lowered := name.to_lower()
		if lowered.contains("fire") or lowered.contains("idle") or lowered.contains("stand"):
			return name
	return ""


func _sniper_hold_pose_time(clip_name: String) -> float:
	var clip := _variant_animation.get_animation(clip_name)
	if clip == null or clip.length <= 0.0:
		return 0.0
	return clampf(clip.length * sniper_hold_pose_fraction, 0.0, maxf(clip.length - 0.01, 0.0))


## The boxer's authored punch clips, most specific token first. This must return
## the same clip for the telegraph and for the strike: the shared role lookup
## below falls back to `idle` when no attack intent is passed, and swapping clips
## mid-punch would break the single continuous swing the strike relies on.
func _boxer_attack_clip(names: Array[String]) -> String:
	for token in ["box_01", "box_02", "box"]:
		for name in names:
			if name.to_lower().contains(token):
				return name
	return ""


## Playback rate that fits the punch clip into exactly the telegraph plus the
## active window, so the fist's travel stays coincident with the hitbox instead
## of drifting against it. This is derived rather than authored because the
## delivered `box_01` length is not known here, and it keeps working if the model
## is re-exported with different clip timings. The band is a sanity clamp only:
## a degenerate or missing clip falls back to authored speed.
func _boxer_punch_speed(clip_name: String) -> float:
	if clip_name.is_empty() or not is_instance_valid(_variant_animation):
		return 1.0
	var clip := _variant_animation.get_animation(clip_name)
	if clip == null or clip.length <= 0.0:
		return 1.0
	var window := maxf(boxer_windup_duration + boxer_active_duration, 0.05)
	return clampf(clip.length / window, 0.05, 4.0)


func _find_node_by_name(node: Node, names: Array[String]) -> Node3D:
	if node is Node3D and String(node.name) in names:
		return node as Node3D
	for child in node.get_children():
		var result := _find_node_by_name(child, names)
		if result != null:
			return result
	return null
