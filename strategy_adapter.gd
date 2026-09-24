extends RefCounted
class_name AdaptiveBossStrategyAdapter
## Local strategy adapter for the independent behavior lab.
##
## This is deliberately a deterministic placeholder for a future LLM.  It
## only consumes the compact dictionary returned by
## AdaptiveBossBrain.get_llm_context(); it never reads raw action history,
## hand/deck state, random seeds, or performs network requests.  The game can
## call decide() at a low frequency and pass the returned bounded directive to
## brain.apply_llm_directive().


func get_context(context: Dictionary) -> Dictionary:
	## Keep the adapter's input stable and small so replacing this local rule
	## with an LLM transport later does not change the brain's contract.
	var world_model_variant: Variant = context.get("world_model", {})
	var world_model: Dictionary = world_model_variant if world_model_variant is Dictionary else {}
	var evidence_variant: Variant = world_model.get("evidence", {})
	var evidence: Dictionary = evidence_variant if evidence_variant is Dictionary else {}
	return {
		"recommended_response": str(world_model.get("recommended_response", "observe_and_probe")),
		"confidence": clampf(float(world_model.get("confidence", 0.0)), 0.0, 1.0),
		"roll_samples": int(evidence.get("roll_samples", world_model.get("patterns", {}).get("roll_count", 0))),
	}


func decide(context: Dictionary) -> Dictionary:
	## Deterministic local rule, standing in for a future LLM judgment.
	## The output is intentionally limited to knobs accepted by
	## AdaptiveBossBrain.apply_llm_directive().
	var compact := get_context(context)
	var recommendation := str(compact.get("recommended_response", "observe_and_probe"))
	var confidence := float(compact.get("confidence", 0.0))
	var roll_samples := int(compact.get("roll_samples", 0))
	var has_evidence := confidence >= 0.4 and roll_samples >= 3
	if recommendation == "evade_roll_then_punish" and has_evidence:
		return {
			"name": "roll_counter",
			"roll_response": "evade",
			"aggression": 0.5,
			"exploration_rate": 0.2,
		}
	if recommendation == "keep_distance" and confidence >= 0.4:
		return {
			"name": "keep_distance",
			"roll_response": "disengage",
			"aggression": 0.35,
			"exploration_rate": 0.25,
		}
	# keep_distance and every unknown/low-confidence recommendation remain
	# conservative until more evidence is collected.
	return {
		"name": "observe_and_probe",
		"roll_response": "disengage",
		"aggression": 0.5,
		"exploration_rate": 0.2,
	}
