extends Node
class_name AdaptiveBossBrain
## Three-layer adaptive-boss prototype.
##
## Layer 1 (telemetry/world model): records accepted player actions, short
## action chains, energy commitment, and movement/combat state.  The summary
## is intentionally JSON-shaped so it can be sent to an LLM outside the game.
## Layer 2 (strategy): an optional, slow policy update can be supplied through
## apply_llm_directive().  The game never waits for that update.
## Layer 3 (reaction FSM): emits a bounded, low-latency reaction intent every
## physics tick.  A boss controller can turn that intent into movement/attacks.

signal world_model_updated(summary: Dictionary)
## Compatibility name from the design guide; callers can treat this as the
## compact player-profile stream without depending on the internal model name.
signal player_pattern_updated(profile_snapshot: Dictionary)
signal strategy_updated(strategy: Dictionary)
signal reaction_requested(reaction: StringName, payload: Dictionary)
signal telemetry_recorded(event: Dictionary)

const CARD_CATALOG = preload("res://card_catalog.gd")

@export var sample_interval: float = 0.05
@export var inference_interval: float = 0.45
@export var recency_half_life: float = 8.0
## The final boss remembers the latest 40 accepted cards by default.  This is
## long enough to detect a habit while allowing a changed habit to replace it.
@export var action_history_limit: int = 40
@export var reaction_cooldown: float = 0.12
@export var pattern_window: float = 0.85
@export var roll_attack_threshold: float = 0.42
@export var predicted_attack_cost: float = 2.0

var player: Node
var opponent: Node
var world_model: Dictionary = {}
var strategy: Dictionary = {
	"name": "observe_and_probe",
	"aggression": 0.5,
	"exploration_rate": 0.2,
	"roll_response": "disengage",
	"slash_response": "guard",
	"dash_response": "sidestep",
}

var reaction_state: StringName = &"observe"
var reaction_state_time: float = 0.0
var last_reaction: StringName = &"none"
var last_reaction_time: float = -INF

var _clock: float = 0.0
var _sample_clock: float = 0.0
var _inference_clock: float = 0.0
var _action_history: Array[Dictionary] = []
var _total_actions_seen: int = 0
var _rejected_attempts: int = 0
var _action_counts: Dictionary = {}
var _category_counts: Dictionary = {"attack": 0.0, "movement": 0.0, "hybrid": 0.0, "unknown": 0.0}
var _transition_counts: Dictionary = {}
var _outcome_counts: Dictionary = {}
var _event_counts: Dictionary = {}
var _last_action_kind: String = ""
var _last_action_time: float = -INF
var _last_snapshot: Dictionary = {}
var _last_cybernetic_active: bool = false
var _was_attached := false


func _ready() -> void:
	# The brain is allowed to observe while a scene is paused.  Its reaction
	# callback should still check the boss/player gameplay pause state before
	# applying any actual attack. Preserve an explicit caller choice (the live
	# game sets PROCESS_MODE_PAUSABLE); standalone lab scenes default to ALWAYS
	# so their asynchronous observation harness keeps working while paused.
	if process_mode == Node.PROCESS_MODE_INHERIT:
		process_mode = Node.PROCESS_MODE_ALWAYS
	_reset_model()


func _physics_process(delta: float) -> void:
	_clock += maxf(delta, 0.0)
	reaction_state_time += maxf(delta, 0.0)
	_sample_clock += maxf(delta, 0.0)
	_inference_clock += maxf(delta, 0.0)
	if not is_instance_valid(player):
		return
	if _sample_clock >= sample_interval:
		_sample_clock = 0.0
		_sample_player_state()
	if _inference_clock >= inference_interval:
		_inference_clock = 0.0
		_infer_world_model()
	_evaluate_reaction(false)


func attach_player(actor: Node) -> void:
	if is_instance_valid(player):
		_disconnect_player_signals(player)
	player = actor
	_was_attached = is_instance_valid(player)
	if not _was_attached:
		return
	if player.has_signal("action_played"):
		var action_callable := Callable(self, "_on_player_action")
		if not player.is_connected("action_played", action_callable):
			player.connect("action_played", action_callable)
	if player.has_signal("action_attempted"):
		var attempted_callable := Callable(self, "_on_player_action_attempted")
		if not player.is_connected("action_attempted", attempted_callable):
			player.connect("action_attempted", attempted_callable)
	if player.has_signal("damaged"):
		var damaged_callable := Callable(self, "_on_player_damaged")
		if not player.is_connected("damaged", damaged_callable):
			player.connect("damaged", damaged_callable)
	if player.has_signal("cybernetic_changed"):
		var cybernetic_callable := Callable(self, "_on_cybernetic_changed")
		if not player.is_connected("cybernetic_changed", cybernetic_callable):
			player.connect("cybernetic_changed", cybernetic_callable)
	_sample_player_state()


func attach_opponent(actor: Node) -> void:
	## Optional recipient of reaction intents.  Keeping this reference in the
	## brain lets a training foe and the future Mirror boss share the same API;
	## the brain never mutates the opponent directly.
	opponent = actor


func detach_opponent() -> void:
	opponent = null


func detach_player() -> void:
	if is_instance_valid(player):
		_disconnect_player_signals(player)
	player = null
	_was_attached = false


func _disconnect_player_signals(actor: Node) -> void:
	var action_callable := Callable(self, "_on_player_action")
	var attempted_callable := Callable(self, "_on_player_action_attempted")
	var damaged_callable := Callable(self, "_on_player_damaged")
	var cybernetic_callable := Callable(self, "_on_cybernetic_changed")
	if actor.has_signal("action_played"):
		if actor.is_connected("action_played", action_callable):
			actor.disconnect("action_played", action_callable)
	if actor.has_signal("action_attempted"):
		if actor.is_connected("action_attempted", attempted_callable):
			actor.disconnect("action_attempted", attempted_callable)
	if actor.has_signal("damaged"):
		if actor.is_connected("damaged", damaged_callable):
			actor.disconnect("damaged", damaged_callable)
	if actor.has_signal("cybernetic_changed"):
		if actor.is_connected("cybernetic_changed", cybernetic_callable):
			actor.disconnect("cybernetic_changed", cybernetic_callable)


func reset_observation() -> void:
	strategy = {
		"name": "observe_and_probe", "aggression": 0.5, "exploration_rate": 0.2,
		"roll_response": "disengage", "slash_response": "guard", "dash_response": "sidestep",
	}
	roll_attack_threshold = 0.42
	_reset_model()
	_clock = 0.0
	_sample_clock = 0.0
	_inference_clock = 0.0
	_reaction_state_reset()
	_sample_player_state()


func observe(action_name: String, cost: float = 0.0, context: Dictionary = {}) -> void:
	## Public, scene-independent telemetry API.  A replay system or a player
	## proxy can call this when it does not expose `action_played`.
	_record_action(action_name, cost, context)


func snapshot() -> Dictionary:
	## Return a safe copy suitable for saving, debugging, or LLM serialization.
	return world_model.duplicate(true)


func plan_reaction(player_state_override: Dictionary = {}) -> Dictionary:
	## Pure planner view of the local FSM.  It does not emit a signal and can be
	## unit-tested before a real boss controller is connected.
	var state := _state_snapshot() if player_state_override.is_empty() else player_state_override.duplicate(true)
	var patterns: Dictionary = world_model.get("patterns", {})
	var requested: StringName = &"observe"
	var payload: Dictionary = {
		"source": "world_model",
		"confidence": float(world_model.get("confidence", 0.0)),
		"exploration_rate": float(strategy.get("exploration_rate", 0.2)),
		"player_state": state,
		"world_model": world_model.duplicate(true),
	}
	if bool(state.get("is_dead", false)):
		return {"reaction": &"observe", "payload": payload}
	if bool(state.get("is_rolling", false)):
		var can_afford_attack := float(state.get("energy", 0.0)) >= predicted_attack_cost
		var roll_samples := int(patterns.get("roll_count", 0))
		var enough_evidence := roll_samples >= 3 and float(world_model.get("confidence", 0.0)) >= 0.4
		if enough_evidence and float(patterns.get("roll_attack_rate", 0.0)) >= roll_attack_threshold and can_afford_attack:
			# Evidence alone must not bypass the slow strategy layer. The
			# strategy (local rule or LLM directive) authorizes the response.
			requested = StringName(str(strategy.get("roll_response", "disengage")))
			payload["reason"] = "predicted_roll_attack" if requested == &"evade" else "policy_roll_response"
			payload["policy"] = str(strategy.get("name", "observe_and_probe"))
			if requested == &"evade":
				payload["punish_after"] = "roll_recovery"
		elif can_afford_attack:
			requested = &"disengage"
			payload["reason"] = "unknown_roll_intent"
	elif bool(state.get("is_dashing", false)):
		requested = StringName(str(strategy.get("dash_response", "sidestep")))
		payload["reason"] = "dash_started"
	elif float(state.get("slash_time_left", 0.0)) > 0.0:
		requested = StringName(str(strategy.get("slash_response", "guard")))
		payload["reason"] = "attack_active"
	elif float(world_model.get("confidence", 0.0)) >= 0.5 and float(strategy.get("aggression", 0.5)) > 0.65:
		requested = &"pressure"
		payload["reason"] = "high_confidence_pressure"
	return {"reaction": requested, "payload": payload}


func _reset_model() -> void:
	_action_history.clear()
	_total_actions_seen = 0
	_rejected_attempts = 0
	_action_counts.clear()
	_category_counts = {"attack": 0.0, "movement": 0.0, "hybrid": 0.0, "unknown": 0.0}
	_transition_counts.clear()
	_outcome_counts.clear()
	_event_counts.clear()
	_last_action_kind = ""
	_last_action_time = -INF
	_last_snapshot.clear()
	_last_cybernetic_active = false
	world_model = _empty_summary()


func _empty_summary() -> Dictionary:
	return {
		"schema": 1,
		"time": 0.0,
		"actions_seen": 0,
		"total_actions_seen": 0,
		"confidence": 0.0,
		"dominant_action": "",
		"dominant_category": "",
		"action_counts": {},
		"category_mix": {"attack": 0.0, "movement": 0.0, "hybrid": 0.0, "unknown": 0.0},
		"top_transitions": [],
		"patterns": {
			"roll_attack_rate": 0.0,
			"roll_attack_count": 0,
			"roll_count": 0,
			"hybrid_rate": 0.0,
			"burst_rate": 0.0,
		},
		"energy": {"last": 0.0, "max": 0.0, "mean_commitment": 0.0},
		"distance": {"last": 0.0, "bucket_mix": {}},
		"evidence": {"roll_samples": 0, "window_size": action_history_limit},
		"outcomes": {},
		"attempts": {"accepted": 0, "rejected": 0, "rejection_rate": 0.0},
		"state": {},
		"recommended_response": "observe_and_probe",
	}


func _on_player_action(action_name: String, cost: float) -> void:
	_record_action(action_name, cost, {})


func _record_action(action_name: String, cost: float, context: Dictionary) -> void:
	var category := CARD_CATALOG.category(action_name)
	if category.is_empty():
		category = "unknown"
	var energy_after := _read_float("energy", 0.0)
	var energy_max := _read_float("max_energy", 0.0)
	var energy_before := minf(energy_max, energy_after + maxf(cost, 0.0)) if energy_max > 0.0 else energy_after + maxf(cost, 0.0)
	var elapsed := _clock - _last_action_time if is_finite(_last_action_time) else -1.0
	var observed_state := _state_snapshot()
	for key in context:
		observed_state[key] = context[key]
	var action := {
		"kind": action_name,
		"category": category,
		"cost": cost,
		"time": _clock,
		"dt": elapsed,
		"energy_before": energy_before,
		"energy_after": energy_after,
		"state": observed_state,
	}
	_action_history.append(action)
	_total_actions_seen += 1
	if _action_history.size() > action_history_limit:
		var expired: Dictionary = _action_history.pop_front()
		var expired_kind := str(expired.get("kind", ""))
		var expired_category := str(expired.get("category", "unknown"))
		_action_counts[expired_kind] = maxf(0.0, float(_action_counts.get(expired_kind, 0.0)) - 1.0)
		_category_counts[expired_category] = maxf(0.0, float(_category_counts.get(expired_category, 0.0)) - 1.0)
	_action_counts[action_name] = float(_action_counts.get(action_name, 0.0)) + 1.0
	_category_counts[category] = float(_category_counts.get(category, 0.0)) + 1.0
	_rebuild_transition_counts()
	_last_action_kind = action_name
	_last_action_time = _clock
	telemetry_recorded.emit(action.duplicate(true))
	_infer_world_model()
	# Action signals arrive in the same frame as the player's card request, so
	# evaluate immediately instead of waiting for the next inference interval.
	_evaluate_reaction(true)


func _rebuild_transition_counts() -> void:
	_transition_counts.clear()
	var previous_kind := ""
	var previous_time := -INF
	for action in _action_history:
		var current_kind := str(action.get("kind", ""))
		var current_time := float(action.get("time", 0.0))
		var elapsed := current_time - previous_time if is_finite(previous_time) else -1.0
		if not previous_kind.is_empty() and elapsed >= 0.0 and elapsed <= pattern_window:
			var transition := "%s->%s" % [previous_kind, current_kind]
			_transition_counts[transition] = int(_transition_counts.get(transition, 0)) + 1
		previous_kind = current_kind
		previous_time = current_time


func record_action_outcome(action_name: String, outcome: String, value: float = 1.0) -> void:
	## The combat controller can call this when an action hits, whiffs, or is
	## interrupted.  A card being accepted is already recorded as "started".
	var key := "%s:%s" % [action_name, outcome]
	_outcome_counts[key] = float(_outcome_counts.get(key, 0.0)) + maxf(value, 0.0)
	var event := {"type": "outcome", "action": action_name, "outcome": outcome, "value": value, "time": _clock}
	telemetry_recorded.emit(event)
	_infer_world_model()


func record_event(event_name: String, payload: Dictionary = {}) -> void:
	## Generic hook for dodge success, damage, terminal choices, or any event a
	## future world model may need.  Keep payload small and JSON serializable.
	_event_counts[event_name] = int(_event_counts.get(event_name, 0)) + 1
	var event := {"type": event_name, "payload": payload.duplicate(true), "time": _clock}
	telemetry_recorded.emit(event)
	_infer_world_model()


func _on_player_damaged(amount: float) -> void:
	record_event("damaged", {"amount": amount})


func _on_player_action_attempted(action_name: String, accepted: bool, reason: String) -> void:
	if accepted:
		return
	_rejected_attempts += 1
	record_event("action_rejected", {"action": action_name, "reason": reason})


func _on_cybernetic_changed(active_time_left: float, cooldown_left: float) -> void:
	var active := active_time_left > 0.0
	if active and not _last_cybernetic_active:
		record_event("cybernetic", {"cooldown": cooldown_left})
	_last_cybernetic_active = active


func _sample_player_state() -> void:
	var current := _state_snapshot()
	if not _last_snapshot.is_empty():
		if bool(current.get("is_rolling", false)) and not bool(_last_snapshot.get("is_rolling", false)):
			record_event("roll_started")
		if bool(current.get("is_dashing", false)) and not bool(_last_snapshot.get("is_dashing", false)):
			record_event("dash_started")
	_last_snapshot = current
	var active := bool(current.get("is_cybernetic_active", false))
	if active and not _last_cybernetic_active:
		record_event("cybernetic", {})
	_last_cybernetic_active = active


func _state_snapshot() -> Dictionary:
	if not is_instance_valid(player):
		return {}
	var position: Variant = player.get("global_position")
	var pos_data := {"x": 0.0, "y": 0.0, "z": 0.0}
	if position is Vector3:
		pos_data = {"x": position.x, "y": position.y, "z": position.z}
	var velocity: Variant = player.get("velocity")
	var velocity_data := {"x": 0.0, "y": 0.0, "z": 0.0}
	if velocity is Vector3:
		velocity_data = {"x": velocity.x, "y": velocity.y, "z": velocity.z}
	var roll_direction: Variant = player.get("roll_direction")
	var roll_data := {"x": 0.0, "y": 0.0, "z": 0.0}
	if roll_direction is Vector3:
		roll_data = {"x": roll_direction.x, "y": roll_direction.y, "z": roll_direction.z}
	var distance := 0.0
	var distance_bucket := ""
	if is_instance_valid(opponent):
		var opponent_position: Variant = opponent.get("global_position")
		if opponent_position is Vector3 and position is Vector3:
			distance = position.distance_to(opponent_position)
			distance_bucket = "near" if distance < 3.5 else ("mid" if distance < 8.0 else "far")
	return {
		"is_rolling": bool(player.get("is_rolling")),
		"is_dashing": bool(player.get("is_dashing")),
		"is_diving": bool(player.get("is_diving")),
		"is_dead": bool(player.get("is_dead")),
		"is_cybernetic_active": bool(player.get("is_cybernetic_active")),
		"energy": _read_float("energy", 0.0),
		"max_energy": _read_float("max_energy", 0.0),
		"health": _read_float("health", 0.0),
		"slash_time_left": _read_float("slash_time_left", 0.0),
		"position": pos_data,
		"velocity": velocity_data,
		"roll_direction": roll_data,
		"distance": distance,
		"distance_bucket": distance_bucket,
		"opponent_state": str(opponent.get("state")) if is_instance_valid(opponent) else "",
	}


func _read_float(property_name: String, fallback: float) -> float:
	if not is_instance_valid(player):
		return fallback
	var value = player.get(property_name)
	return float(value) if value is int or value is float else fallback


func _infer_world_model() -> void:
	var summary := _empty_summary()
	summary["time"] = _clock
	summary["actions_seen"] = _action_history.size()
	summary["total_actions_seen"] = _total_actions_seen
	var total_weight := 0.0
	var weighted_actions: Dictionary = {}
	var weighted_categories: Dictionary = {"attack": 0.0, "movement": 0.0, "hybrid": 0.0, "unknown": 0.0}
	var weighted_roll_count := 0.0
	var weighted_roll_attack_count := 0.0
	var previous_kind := ""
	var previous_time := -INF
	var commitment_sum := 0.0
	var commitment_weight := 0.0
	var weighted_energy_bands: Dictionary = {"0_2": 0.0, "3_7": 0.0, "8_10": 0.0}
	var weighted_distance_buckets: Dictionary = {"near": 0.0, "mid": 0.0, "far": 0.0}
	var last_distance := 0.0
	for action in _action_history:
		var age := maxf(0.0, _clock - float(action.get("time", _clock)))
		var weight := pow(0.5, age / maxf(recency_half_life, 0.01))
		var kind := str(action.get("kind", ""))
		var category := str(action.get("category", "unknown"))
		weighted_actions[kind] = float(weighted_actions.get(kind, 0.0)) + weight
		weighted_categories[category] = float(weighted_categories.get(category, 0.0)) + weight
		total_weight += weight
		if kind == "roll":
			weighted_roll_count += weight
		var current_time := float(action.get("time", _clock))
		var action_elapsed := current_time - previous_time if is_finite(previous_time) else -1.0
		if previous_kind == "roll" and action_elapsed >= 0.0 and action_elapsed <= pattern_window:
			if CARD_CATALOG.category(kind) == "attack" or CARD_CATALOG.category(kind) == "hybrid":
				weighted_roll_attack_count += weight
		previous_kind = kind
		previous_time = current_time
		var energy_max := float(action.get("energy_before", 0.0))
		if energy_max > 0.0:
			commitment_sum += minf(float(action.get("cost", 0.0)) / energy_max, 1.0) * weight
			commitment_weight += weight
			var energy_before := float(action.get("energy_before", 0.0))
			var energy_band := "0_2" if energy_before <= 2.0 else ("3_7" if energy_before <= 7.0 else "8_10")
			weighted_energy_bands[energy_band] = float(weighted_energy_bands.get(energy_band, 0.0)) + weight
			var action_state: Dictionary = action.get("state", {})
			var distance := float(action_state.get("distance", 0.0))
			last_distance = distance
			var distance_bucket := str(action_state.get("distance_bucket", ""))
			if weighted_distance_buckets.has(distance_bucket):
				weighted_distance_buckets[distance_bucket] = float(weighted_distance_buckets[distance_bucket]) + weight
	var dominant_action := _key_with_max(weighted_actions)
	var dominant_category := _key_with_max(weighted_categories)
	var normalized_categories: Dictionary = {}
	for key in weighted_categories:
		normalized_categories[key] = float(weighted_categories[key]) / maxf(total_weight, 0.001)
	var roll_count := int(_action_counts.get("roll", 0))
	var roll_attack_count := 0
	for transition in _transition_counts:
		if str(transition).begins_with("roll->"):
			var target := str(transition).split("->", false, 1)[1]
			if CARD_CATALOG.category(target) == "attack" or CARD_CATALOG.category(target) == "hybrid":
				roll_attack_count += int(_transition_counts[transition])
	var top_transitions: Array[Dictionary] = []
	for transition in _transition_counts:
		top_transitions.append({"transition": transition, "count": int(_transition_counts[transition])})
	top_transitions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["count"]) > int(b["count"])
	)
	if top_transitions.size() > 5:
		top_transitions.resize(5)
	var burst_count := int(_event_counts.get("cybernetic", 0))
	var event_total := 0
	for event_name in _event_counts:
		event_total += int(_event_counts[event_name])
	# Evidence confidence follows the same recency half-life as action weights;
	# an old habit therefore fades before the 40-action buffer is replaced.
	summary["confidence"] = clampf(total_weight / 12.0, 0.0, 1.0)
	summary["dominant_action"] = dominant_action
	summary["dominant_category"] = dominant_category
	summary["action_counts"] = _action_counts.duplicate(true)
	summary["category_mix"] = normalized_categories
	summary["top_transitions"] = top_transitions
	summary["patterns"] = {
		"roll_attack_rate": weighted_roll_attack_count / maxf(weighted_roll_count, 0.001),
		"roll_attack_count": roll_attack_count,
		"roll_count": roll_count,
		"weighted_roll_count": weighted_roll_count,
		"weighted_roll_attack_count": weighted_roll_attack_count,
		"hybrid_rate": float(normalized_categories.get("hybrid", 0.0)),
		"burst_rate": float(burst_count) / maxf(float(event_total), 1.0),
	}
	var snapshot := _state_snapshot()
	summary["energy"] = {
		"last": float(snapshot.get("energy", 0.0)),
		"max": float(snapshot.get("max_energy", 0.0)),
		"mean_commitment": commitment_sum / maxf(commitment_weight, 0.001),
		"band_mix": _normalize_weights(weighted_energy_bands),
	}
	summary["distance"] = {
		"last": last_distance,
		"bucket_mix": _normalize_weights(weighted_distance_buckets),
	}
	summary["evidence"] = {
		"roll_samples": roll_count,
		"window_size": action_history_limit,
	}
	summary["outcomes"] = _outcome_counts.duplicate(true)
	var attempts_total := _total_actions_seen + _rejected_attempts
	summary["attempts"] = {
		"accepted": _total_actions_seen,
		"rejected": _rejected_attempts,
		"rejection_rate": float(_rejected_attempts) / maxf(float(attempts_total), 1.0),
	}
	summary["state"] = snapshot
	summary["recommended_response"] = _recommendation(summary)
	world_model = summary
	world_model_updated.emit(summary.duplicate(true))
	player_pattern_updated.emit(summary.duplicate(true))


func _recommendation(summary: Dictionary) -> String:
	var patterns: Dictionary = summary.get("patterns", {})
	var enough_evidence := int(patterns.get("roll_count", 0)) >= 3 and float(summary.get("confidence", 0.0)) >= 0.4
	if enough_evidence and float(patterns.get("roll_attack_rate", 0.0)) >= roll_attack_threshold:
		return "evade_roll_then_punish"
	if float(summary.get("confidence", 0.0)) >= 0.4 and float(patterns.get("hybrid_rate", 0.0)) >= 0.45:
		return "keep_distance"
	return "observe_and_probe"


func _key_with_max(values: Dictionary) -> String:
	var best := ""
	var best_value := -INF
	for key in values:
		if float(values[key]) > best_value:
			best = str(key)
			best_value = float(values[key])
	return best


func _normalize_weights(values: Dictionary) -> Dictionary:
	var total := 0.0
	for key in values:
		total += maxf(0.0, float(values[key]))
	var result: Dictionary = {}
	for key in values:
		result[key] = float(values[key]) / maxf(total, 0.001)
	return result


func apply_llm_directive(directive: Dictionary) -> bool:
	## Apply only bounded, validated knobs returned by an external LLM.  The LLM
	## should receive `get_llm_context()` and return a small JSON object such as
	## {"aggression": 0.8, "roll_response": "evade"}.
	if directive.is_empty():
		return false
	var changed := false
	for key in ["name", "roll_response", "slash_response", "dash_response"]:
		if not directive.has(key) or not directive[key] is String:
			continue
		var value := str(directive[key])
		if not _strategy_value_allowed(key, value):
			continue
		strategy[key] = value
		changed = true
	if _finite_number(directive.get("aggression")):
		strategy["aggression"] = clampf(float(directive["aggression"]), 0.0, 1.0)
		changed = true
	if _finite_number(directive.get("exploration_rate")):
		strategy["exploration_rate"] = clampf(float(directive["exploration_rate"]), 0.0, 0.35)
		changed = true
	if _finite_number(directive.get("roll_attack_threshold")):
		roll_attack_threshold = clampf(float(directive["roll_attack_threshold"]), 0.1, 0.95)
		changed = true
	if changed:
		strategy_updated.emit(strategy.duplicate(true))
	return changed


func _finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


func _strategy_value_allowed(key: String, value: String) -> bool:
	if key == "name":
		return not value.is_empty() and value.length() <= 64 and not value.contains("\n") and not value.contains("\r")
	var allowed := {
		"roll_response": ["evade", "disengage", "guard", "pressure"],
		"slash_response": ["guard", "evade", "disengage", "pressure"],
		"dash_response": ["sidestep", "guard", "disengage", "evade"],
	}
	return value in allowed.get(key, [])


func get_llm_context() -> Dictionary:
	## Stable interface for the optional local/server LLM adapter. Do not pass the
	## entire action log; the compact summary limits leakage and token growth.
	return {
		"world_model": world_model.duplicate(true),
		"strategy": strategy.duplicate(true),
		"fsm": {"state": str(reaction_state), "state_time": reaction_state_time},
	}


func _evaluate_reaction(immediate: bool) -> void:
	if not is_instance_valid(player):
		return
	var decision := plan_reaction()
	var requested: StringName = decision["reaction"]
	var payload: Dictionary = decision["payload"]
	var within_cooldown := _clock - last_reaction_time < reaction_cooldown
	# A card signal can request an urgent state change immediately, while
	# physics ticks coalesce noisy repeats under the local FSM cooldown.
	if within_cooldown and (not immediate or requested == last_reaction):
		return
	_set_reaction_state(requested)
	if requested != last_reaction:
		last_reaction = requested
		last_reaction_time = _clock
		reaction_requested.emit(requested, payload)


func _set_reaction_state(next_state: StringName) -> void:
	if reaction_state == next_state:
		return
	reaction_state = next_state
	reaction_state_time = 0.0


func _reaction_state_reset() -> void:
	reaction_state = &"observe"
	reaction_state_time = 0.0
	last_reaction = &"none"
	last_reaction_time = -INF
