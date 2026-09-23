extends SceneTree
## Godot --headless --path . --script tests/test_erosion_system.gd

const EROSION = preload("res://erosion_system.gd")
var system: Node
var passed := 0
var failed := 0
var thresholds := 0
var depletions := 0
var changes: Array[Vector2i] = []
var phases: Array[bool] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	system = EROSION.new()
	root.add_child(system)
	system.changed.connect(func(current: int, maximum: int) -> void: changes.append(Vector2i(current, maximum)))
	system.boss_threshold_reached.connect(func() -> void: thresholds += 1)
	system.depleted.connect(func() -> void: depletions += 1)
	system.phase_changed.connect(func(in_boss: bool) -> void: phases.append(in_boss))
	_test_activity()
	_test_pause_and_combat()
	_test_facilities()
	_test_threshold_and_boss()
	_test_reset_and_invalid_time()
	system.free()
	print("EROSION SYSTEM RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_activity() -> void:
	system.process_activity(0.6, true, false)
	_check(system.value == 0, "Movement waits for its first complete second")
	system.process_activity(0.4, true, false)
	_check(system.value == 1, "One second of movement adds exactly one point")
	system.process_activity(2.8, false, false)
	_check(system.value == 1, "Idle waits for its first three seconds")
	system.process_activity(0.2, false, false)
	_check(system.value == 2, "Three idle seconds add one point")
	system.process_activity(9.0, false, false)
	_check(system.value == 5, "A long idle frame credits all complete intervals")
	system.process_activity(12.0, true, true)
	system.process_activity(12.0, false, true)
	_check(system.value == 5, "Card or jump activity is not charged as pure walking or idle")
	system.process_activity(0.75, true, false)
	system.process_activity(1.5, false, false)
	system.process_activity(0.25, true, false)
	_check(system.value == 6, "Switching activity retains incomplete movement seconds")
	system.process_activity(1.5, false, false)
	_check(system.value == 7, "Switching activity retains incomplete idle seconds")
	_check(changes.back() == Vector2i(7, 100), "Changes expose the value and maximum for the HUD")


func _test_pause_and_combat() -> void:
	system.reset()
	system.process_activity(0.8, true, false)
	system.set_combat_active(true)
	system.process_activity(9.0, true, false)
	system.process_activity(9.0, false, false)
	_check(system.value == 0, "Combat freezes both activity timers")
	system.set_combat_active(false)
	system.process_activity(0.2, true, false)
	_check(system.value == 1, "Leaving combat resumes the precombat movement remainder")
	system.process_activity(2.9, false, false)
	system.set_paused(true)
	system.process_activity(10.0, false, false)
	_check(system.value == 1, "Explicit pause freezes erosion")
	system.set_paused(false)
	system.process_activity(0.1, false, false)
	_check(system.value == 2, "Explicit pause retains the idle remainder")
	paused = true
	system.process_activity(20.0, true, false)
	_check(system.value == 2, "SceneTree pause also freezes explicitly supplied activity")
	paused = false


func _test_facilities() -> void:
	system.reset()
	for kind in [&"medical", &"factory", &"shop"]:
		_check(system.record_facility_entry(kind), "%s is a supported facility entry" % kind)
	_check(system.value == 30, "Medical, factory and shop entries each add ten points")
	_check(not system.record_facility_entry(&"police") and system.value == 30, "Unlisted facilities do not charge erosion")
	paused = true
	_check(system.record_facility_entry(&"hospital") and system.value == 40, "A successful entry still charges after its UI pauses the tree")
	paused = false


func _test_threshold_and_boss() -> void:
	system.reset(95)
	var threshold_before := thresholds
	system.record_facility_entry(&"shop")
	_check(system.value == 100 and thresholds == threshold_before + 1, "An entry clamps at one hundred and requests the Boss once")
	system.process_activity(25.0, true, false)
	system.value = 100
	_check(not system.record_facility_entry(&"shop") and thresholds == threshold_before + 1, "Pending transition cannot charge or dispatch another Boss")
	system.start_boss_phase()
	system.start_boss_phase()
	_check(system.boss_phase and phases.back(), "Starting the Boss phase emits its active state")
	system.set_combat_active(true)
	system.process_activity(0.75, true, true)
	_check(system.value == 100, "Boss drain also waits for a full second")
	system.set_paused(true)
	system.process_activity(10.0, false, false)
	system.set_paused(false)
	system.process_activity(0.25, true, true)
	_check(system.value == 99, "Boss time drains during combat and retains pause remainder")
	_check(not system.record_facility_entry(&"medical") and system.value == 99, "Facility costs cannot interrupt Boss drainage")
	var depletion_before := depletions
	system.process_activity(1000.0, false, false)
	_check(system.value == 0 and depletions == depletion_before + 1, "Boss drainage clamps to zero and emits depleted")
	system.process_activity(10.0, false, false)
	_check(system.value == 0 and depletions == depletion_before + 1, "Zero remains stable without duplicate depletion events")
	system.stop_boss_phase()
	_check(not system.boss_phase and not system.combat_active and not phases.back(), "Stopping Boss restores exploration mode")
	system.process_activity(100.0, true, false)
	_check(system.value == 100 and thresholds == threshold_before + 2, "A later exploration phase can reach the threshold again")


func _test_reset_and_invalid_time() -> void:
	system.start_boss_phase()
	system.set_paused(true)
	system.reset()
	_check(system.value == 0 and not system.boss_phase and not system.combat_active and not system.paused, "Reset clears phase, combat and explicit pause")
	system.process_activity(0.3, true, false)
	system.reset()
	system.process_activity(0.7, true, false)
	_check(system.value == 0, "Reset discards old timing remainders")
	system.process_activity(-2.0, true, false)
	system.process_activity(INF, true, false)
	system.process_activity(NAN, true, false)
	system.process_activity(0.3, true, false)
	_check(system.value == 1, "Invalid elapsed time cannot corrupt the activity clock")
	system.value = -20
	_check(system.value == 0, "External value updates are clamped at zero")
	system.reset(150)
	_check(system.value == 100, "Initial reset value is clamped at the maximum")


func _check(condition: bool, message: String) -> void:
	if condition:
		passed += 1
		print("PASS: " + message)
	else:
		failed += 1
		push_error("FAIL: " + message)
