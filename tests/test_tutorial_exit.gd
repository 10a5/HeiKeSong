extends SceneTree
## Verifies the shipped exit path itself: with no harness injected, the tutorial
## must hand the tree over to the real first floor scene.
## Godot --headless --path . --fixed-fps 60 --script tests/test_tutorial_exit.gd

const TUTORIAL = preload("res://tutorial.tscn")
var passed := 0
var failed := 0
var frames := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var tutorial: Node = TUTORIAL.instantiate()
	root.add_child(tutorial)
	current_scene = tutorial
	await _steps(10)
	_check(current_scene.name == "Tutorial", "The tutorial is the live scene")
	_check(not tutorial.get("exit_requested").is_valid(), "No exit override is installed in the shipped configuration")
	tutorial.call("_skip_to_first_floor")
	await _steps(30)
	_check(current_scene != null and current_scene.name == "FirstFloor", "Skip hands the tree to the real first floor scene")
	var script_path := ""
	if current_scene != null and current_scene.get_script() != null:
		script_path = current_scene.get_script().resource_path
	_check(script_path == "res://floor_one.gd", "The first floor runs its own floor_one.gd script")
	print("TUTORIAL EXIT RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _steps(count: int) -> void:
	for _frame in range(count):
		frames += 1
		if frames > 600:
			push_error("FAIL: exit suite exceeded its frame budget")
			print("TUTORIAL EXIT RESULT: %d passed, %d failed (aborted)" % [passed, failed + 1])
			quit(1)
			return
		await physics_frame
		await process_frame


func _check(condition: bool, label: String) -> void:
	if condition:
		passed += 1
		print("PASS: ", label)
	else:
		failed += 1
		push_error("FAIL: %s" % label)
