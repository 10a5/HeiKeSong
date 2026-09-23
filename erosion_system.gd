extends Node
## Run-level erosion. The scene supplies actual activity once per physics frame;
## this node deliberately does not read input, detect combat or own scene changes.
## Partial movement/idle seconds survive actions, combat and modal pauses.

signal changed(current_value: int, maximum: int)
signal boss_threshold_reached
signal depleted
signal phase_changed(in_boss_phase: bool)

const MAX_VALUE := 100
const MOVEMENT_INTERVAL := 1.0
const IDLE_INTERVAL := 3.0
const BOSS_INTERVAL := 1.0
const FACILITY_COST := 10
const FACILITY_KINDS := [&"medical", &"hospital", &"factory", &"shop"]

var max_value: int = MAX_VALUE
var value: int:
	get:
		return _value
	set(next_value):
		_assign_value(next_value)
var boss_phase := false
var combat_active := false
var paused := false

var _value := 0
var _movement_elapsed := 0.0
var _idle_elapsed := 0.0
var _boss_elapsed := 0.0
var _threshold_latched := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE


func process_activity(delta: float, is_moving: bool, has_action: bool) -> void:
	if delta <= 0.0 or not is_finite(delta) or paused:
		return
	if is_inside_tree() and get_tree().paused:
		return
	# Boss time drains even while attacking. The entrance/transition can pause
	# this explicitly until the encounter is ready, just like any other modal.
	if boss_phase:
		if _value <= 0:
			return
		_boss_elapsed += delta
		var points := int(floor((_boss_elapsed + 0.000001) / BOSS_INTERVAL))
		if points > 0:
			_boss_elapsed = maxf(0.0, _boss_elapsed - float(points) * BOSS_INTERVAL)
			_assign_value(_value - points)
		return
	# Once full, wait for the owner to start the encounter; never emit repeated
	# transition requests while the numeric animation is covering the screen.
	if _threshold_latched or combat_active or has_action:
		return
	if is_moving:
		_movement_elapsed += delta
		var points := int(floor((_movement_elapsed + 0.000001) / MOVEMENT_INTERVAL))
		if points > 0:
			_movement_elapsed = maxf(0.0, _movement_elapsed - float(points) * MOVEMENT_INTERVAL)
			_assign_value(_value + points)
	else:
		_idle_elapsed += delta
		var points := int(floor((_idle_elapsed + 0.000001) / IDLE_INTERVAL))
		if points > 0:
			_idle_elapsed = maxf(0.0, _idle_elapsed - float(points) * IDLE_INTERVAL)
			_assign_value(_value + points)


func set_combat_active(active: bool) -> void:
	combat_active = active


func set_paused(active: bool) -> void:
	paused = active


func record_facility_entry(kind: StringName) -> bool:
	# Call once after a successful entry. A modal may already have paused the
	# tree, so this discrete entry cost is independent of timer pause state.
	if kind not in FACILITY_KINDS or boss_phase or _threshold_latched:
		return false
	_assign_value(_value + FACILITY_COST)
	return true


func start_boss_phase() -> void:
	if boss_phase:
		return
	boss_phase = true
	_threshold_latched = true
	_boss_elapsed = 0.0
	phase_changed.emit(true)


func stop_boss_phase() -> void:
	if not boss_phase:
		return
	boss_phase = false
	combat_active = false
	_boss_elapsed = 0.0
	_threshold_latched = _value >= max_value
	phase_changed.emit(false)


func reset(initial_value: int = 0) -> void:
	var was_boss_phase := boss_phase
	boss_phase = false
	combat_active = false
	paused = false
	_movement_elapsed = 0.0
	_idle_elapsed = 0.0
	_boss_elapsed = 0.0
	_threshold_latched = false
	_value = clampi(initial_value, 0, max_value)
	changed.emit(_value, max_value)
	if was_boss_phase:
		phase_changed.emit(false)
	_check_threshold()


func _assign_value(next_value: int) -> void:
	var previous := _value
	_value = clampi(next_value, 0, max_value)
	if _value != previous:
		changed.emit(_value, max_value)
	_check_threshold()
	if boss_phase and previous > 0 and _value == 0:
		depleted.emit()


func _check_threshold() -> void:
	if not boss_phase and _value >= max_value and not _threshold_latched:
		_threshold_latched = true
		boss_threshold_reached.emit()
