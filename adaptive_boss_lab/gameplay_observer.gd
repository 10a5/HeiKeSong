extends Node
## Public gameplay telemetry for the recent 60 seconds of active play.
## Positions are used only to aggregate travel; no hand, pile or random state
## enters this observer or its compact summary. Airborne time may overlap
## moving time. Attack outcomes must be supplied by the combat controller.

@export var sample_interval: float = 0.2
@export var window_duration: float = 60.0
@export var movement_threshold: float = 0.1
@export var near_distance: float = 3.5
@export var far_distance: float = 8.0

var player: Node
var brain: Node
var target: Node

var _clock := 0.0
var _samples: Array[Dictionary] = []
var _jumps: Array[Dictionary] = []
var _attacks: Array[Dictionary] = []
var _period: Dictionary = {}
var _last_position := Vector3.ZERO
var _has_last_position := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_clear_period()


func setup(actor: Node, source_brain: Node, opponent: Node = null) -> void:
	player = actor
	brain = source_brain
	target = opponent
	reset()


func reset() -> void:
	## Preserve the current attachments while beginning a fresh observation.
	_clock = 0.0
	_samples.clear()
	_jumps.clear()
	_attacks.clear()
	_clear_period()
	_has_last_position = false
	if is_instance_valid(player):
		var position: Variant = player.get("global_position")
		if position is Vector3:
			_last_position = position
			_has_last_position = true


func _physics_process(delta: float) -> void:
	if _is_paused() or not is_instance_valid(player) or delta <= 0.0 or not is_finite(delta):
		return
	var position: Variant = player.get("global_position")
	if not position is Vector3:
		return
	var displacement: Vector3 = position - _last_position if _has_last_position else Vector3.ZERO
	_last_position = position
	_has_last_position = true
	var distance := displacement.length()
	var horizontal_distance := Vector2(displacement.x, displacement.z).length()
	var moving := distance / delta > movement_threshold
	var airborne := false
	if player.has_method("is_on_floor"):
		airborne = not bool(player.call("is_on_floor"))
	var opponent_distance := -1.0
	if is_instance_valid(target):
		var target_position: Variant = target.get("global_position")
		if target_position is Vector3:
			opponent_distance = position.distance_to(target_position)
	# Accumulate each physics step's travel, rather than measuring a straight
	# chord every 0.2 s. A player circling or reversing still covers distance.
	var remaining := delta
	var interval := maxf(sample_interval, 0.01)
	while remaining > 0.000001:
		var duration := minf(remaining, interval - float(_period["seconds"]))
		var fraction := duration / delta
		_clock += duration
		_period["seconds"] = float(_period["seconds"]) + duration
		_period["distance"] = float(_period["distance"]) + distance * fraction
		_period["horizontal_distance"] = float(_period["horizontal_distance"]) + horizontal_distance * fraction
		_period["vertical_distance"] = float(_period["vertical_distance"]) + absf(displacement.y) * fraction
		if moving:
			_period["moving"] = float(_period["moving"]) + duration
			_period["moving_distance"] = float(_period["moving_distance"]) + distance * fraction
		if airborne:
			_period["airborne"] = float(_period["airborne"]) + duration
		if opponent_distance >= 0.0:
			_period["distance_known"] = float(_period["distance_known"]) + duration
			_period["distance_integral"] = float(_period["distance_integral"]) + opponent_distance * duration
			var bucket := "near" if opponent_distance < near_distance else ("mid" if opponent_distance < far_distance else "far")
			_period[bucket] = float(_period[bucket]) + duration
		remaining -= duration
		if float(_period["seconds"]) >= interval - 0.000001:
			var sample := _period.duplicate()
			sample["end"] = _clock
			_samples.append(sample)
			_clear_period()
	_expire_old_records()


func record_jump(accepted: bool) -> void:
	## Call once with the result of player.request_jump(). A rejected request
	## is an attempted jump, never an airborne transition inferred as success.
	if _is_paused():
		return
	_jumps.append({"time": _clock, "accepted": accepted})
	if is_instance_valid(brain) and brain.has_method("record_event"):
		brain.call("record_event", "jump_attempt", {"accepted": accepted})
	_expire_old_records()


func record_attack_result(kind: String, hit: bool, damage: float = 0.0) -> void:
	## Report only resolved evidence. The caller owns grouping a multi-target
	## action into one result; this observer never turns a timeout into a miss.
	if _is_paused() or kind.is_empty():
		return
	var applied_damage := maxf(damage, 0.0) if hit and is_finite(damage) else 0.0
	_attacks.append({"time": _clock, "kind": kind, "hit": hit, "damage": applied_damage})
	if is_instance_valid(brain) and brain.has_method("record_action_outcome"):
		# The brain's value is an outcome count, not an amount of damage.
		brain.call("record_action_outcome", kind, "hit" if hit else "miss", 1.0)
	_expire_old_records()


func summary() -> Dictionary:
	var totals := _empty_period()
	var cutoff := _clock - maxf(window_duration, 0.01)
	var sample_count := 0
	for sample in _samples:
		if _add_sample(totals, sample, cutoff):
			sample_count += 1
	if float(_period.get("seconds", 0.0)) > 0.0:
		var pending := _period.duplicate()
		pending["end"] = _clock
		_add_sample(totals, pending, cutoff)
	var seconds := float(totals["seconds"])
	var moving_seconds := float(totals["moving"])
	var known_seconds := float(totals["distance_known"])
	var accepted := 0
	var rejected := 0
	for event in _jumps:
		if float(event["time"]) <= cutoff:
			continue
		if bool(event["accepted"]):
			accepted += 1
		else:
			rejected += 1
	var hit_count := 0
	var miss_count := 0
	var total_damage := 0.0
	var by_kind: Dictionary = {}
	for event in _attacks:
		if float(event["time"]) <= cutoff:
			continue
		var kind := str(event["kind"])
		if not by_kind.has(kind):
			by_kind[kind] = {"hit": 0, "miss": 0, "damage": 0.0}
		var outcome := "hit" if bool(event["hit"]) else "miss"
		by_kind[kind][outcome] = int(by_kind[kind][outcome]) + 1
		by_kind[kind]["damage"] = float(by_kind[kind]["damage"]) + float(event["damage"])
		if bool(event["hit"]):
			hit_count += 1
		else:
			miss_count += 1
		total_damage += float(event["damage"])
	var moving_ratio := moving_seconds / seconds if seconds > 0.0 else 0.0
	var airborne_ratio := float(totals["airborne"]) / seconds if seconds > 0.0 else 0.0
	var mean_speed := float(totals["distance"]) / seconds if seconds > 0.0 else 0.0
	return {
		"window_seconds": maxf(window_duration, 0.01),
		"observed_seconds": seconds,
		"sample_count": sample_count,
		"movement": {
			"moving_ratio": moving_ratio,
			"stationary_ratio": 1.0 - moving_ratio if seconds > 0.0 else 0.0,
			"airborne_ratio": airborne_ratio,
			"distance_m": float(totals["distance"]),
			"horizontal_distance_m": float(totals["horizontal_distance"]),
			"vertical_distance_m": float(totals["vertical_distance"]),
			"mean_speed_mps": mean_speed,
			"mean_moving_speed_mps": float(totals["moving_distance"]) / moving_seconds if moving_seconds > 0.0 else 0.0,
		},
		"opponent_distance": {
			"observed_seconds": known_seconds,
			"mean_m": float(totals["distance_integral"]) / known_seconds if known_seconds > 0.0 else null,
			"bucket_mix": {
				"near": float(totals["near"]) / known_seconds if known_seconds > 0.0 else 0.0,
				"mid": float(totals["mid"]) / known_seconds if known_seconds > 0.0 else 0.0,
				"far": float(totals["far"]) / known_seconds if known_seconds > 0.0 else 0.0,
			},
			"near_below_m": near_distance,
			"far_from_m": far_distance,
		},
		"jumps": {"accepted": accepted, "rejected": rejected},
		"attack_results": {"hit": hit_count, "miss": miss_count, "damage": total_damage, "by_kind": by_kind},
		"interpretation": "近 %.1f 秒：移动 %.0f%%，空中 %.0f%%，行进 %.1f 米，平均 %.1f 米/秒；跳跃成功 %d 次、失败 %d 次。" % [seconds, moving_ratio * 100.0, airborne_ratio * 100.0, float(totals["distance"]), mean_speed, accepted, rejected],
	}


func _add_sample(totals: Dictionary, sample: Dictionary, cutoff: float) -> bool:
	var duration := float(sample["seconds"])
	var retained := clampf(float(sample["end"]) - cutoff, 0.0, duration)
	if duration <= 0.0 or retained <= 0.0:
		return false
	var fraction := retained / duration
	for key in totals:
		totals[key] = float(totals[key]) + float(sample[key]) * fraction
	return true


func _expire_old_records() -> void:
	var cutoff := _clock - maxf(window_duration, 0.01)
	while not _samples.is_empty() and float(_samples[0]["end"]) <= cutoff:
		_samples.pop_front()
	while not _jumps.is_empty() and float(_jumps[0]["time"]) <= cutoff:
		_jumps.pop_front()
	while not _attacks.is_empty() and float(_attacks[0]["time"]) <= cutoff:
		_attacks.pop_front()


func _clear_period() -> void:
	_period = _empty_period()


func _empty_period() -> Dictionary:
	return {
		"seconds": 0.0, "moving": 0.0, "airborne": 0.0,
		"distance": 0.0, "horizontal_distance": 0.0, "vertical_distance": 0.0,
		"moving_distance": 0.0, "distance_known": 0.0, "distance_integral": 0.0,
		"near": 0.0, "mid": 0.0, "far": 0.0,
	}


func _is_paused() -> bool:
	return is_inside_tree() and get_tree().paused
