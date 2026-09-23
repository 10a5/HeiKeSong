extends SceneTree
## Headless contract tests for the adaptive boss's three layers.
## Godot --headless --path . --fixed-fps 60 --script tests/test_boss_brain.gd

const BRAIN = preload("res://boss_brain.gd")

class FakePlayer extends Node:
	signal action_played(action_name: String, cost: float)
	signal damaged(amount: float)
	signal cybernetic_changed(active_time_left: float, cooldown_left: float)
	var energy: float = 10.0
	var max_energy: float = 10.0
	var health: float = 100.0
	var global_position := Vector3.ZERO
	var is_rolling := false
	var is_dashing := false
	var is_diving := false
	var is_dead := false
	var is_cybernetic_active := false
	var slash_time_left: float = 0.0

var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var brain := BRAIN.new()
	brain.name = "AdaptiveBossBrainTest"
	root.add_child(brain)
	var player := FakePlayer.new()
	root.add_child(player)
	brain.attach_player(player)
	await process_frame

	# Repeated roll -> slash is the concrete strategy the final boss should learn.
	for _i in range(6):
		player.is_rolling = true
		player.energy = 10.0
		player.action_played.emit("roll", 3.0)
		player.energy = 8.0
		player.action_played.emit("slash", 2.0)
		player.is_rolling = false
	var summary: Dictionary = brain.snapshot()
	var patterns: Dictionary = summary["patterns"]
	_check(int(summary["actions_seen"]) == 12, "world model records every accepted action")
	_check(int(patterns["roll_attack_count"]) == 6, "world model counts roll to attack chains")
	_check(float(patterns["roll_attack_rate"]) > 0.99, "world model estimates the learned roll attack rate")
	_check(str(summary["recommended_response"]) == "evade_roll_then_punish", "world model recommends the roll counter")

	var high_energy_plan: Dictionary = brain.plan_reaction({"is_rolling": true, "energy": 8.0})
	_check(str(high_energy_plan["reaction"]) == "evade", "FSM evades a learned roll plus affordable follow-up attack")
	_check(str(high_energy_plan["payload"]["reason"]) == "predicted_roll_attack", "FSM exposes a machine-readable reaction reason")
	var low_energy_plan: Dictionary = brain.plan_reaction({"is_rolling": true, "energy": 1.0})
	_check(str(low_energy_plan["reaction"]) == "observe", "FSM does not overreact to a roll with no affordable attack")

	brain.record_action_outcome("slash", "hit")
	brain.record_event("dodge_success", {"attack": "enemy_slash"})
	summary = brain.snapshot()
	_check(float(summary["outcomes"].get("slash:hit", 0.0)) == 1.0, "combat can report an action outcome")
	_check(int(brain.get_llm_context()["world_model"]["actions_seen"]) == 12, "LLM context contains the compact world model")

	_check(not brain.apply_llm_directive({"roll_response": "teleport_everywhere"}), "LLM cannot inject an unlisted reaction")
	_check(brain.apply_llm_directive({"aggression": 0.8, "roll_response": "evade", "exploration_rate": 0.25}), "LLM can update bounded strategy knobs")
	_check(float(brain.strategy["aggression"]) == 0.8 and float(brain.strategy["exploration_rate"]) == 0.25, "bounded strategy values are clamped and retained")

	var opponent := FakePlayer.new()
	opponent.global_position = Vector3(2.0, 0.0, 0.0)
	root.add_child(opponent)
	brain.attach_opponent(opponent)
	brain.reset_observation()
	player.energy = 1.0
	brain.observe("punch", 1.0)
	player.energy = 8.0
	brain.observe("slash", 2.0)
	var contextual: Dictionary = brain.snapshot()
	_check(float(contextual["energy"]["band_mix"].get("0_2", 0.0)) > 0.0, "world model keeps low-energy commitment bands")
	_check(float(contextual["distance"]["bucket_mix"].get("near", 0.0)) > 0.0, "world model records opponent distance buckets")

	brain.action_history_limit = 3
	for _i in range(5):
		brain.observe("punch", 1.0)
	contextual = brain.snapshot()
	_check(int(contextual["actions_seen"]) == 3 and int(contextual["total_actions_seen"]) == 7, "world model expires old actions while retaining total evidence")

	brain.detach_player()
	_check(brain.player == null, "brain detaches cleanly from a player proxy")
	print("BOSS BRAIN RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
		print("PASS: ", description)
	else:
		failed += 1
		push_error("FAIL: " + description)
