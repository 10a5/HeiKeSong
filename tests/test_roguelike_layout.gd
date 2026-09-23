extends SceneTree
## Seeded planner contracts without loading the rendered first-floor scene.
## Godot --headless --path . --fixed-fps 60 --script tests/test_roguelike_layout.gd

const LAYOUT = preload("res://roguelike_map_layout.gd")
const BASE_CELLS: Array[Vector2i] = [
	Vector2i(0, 0), Vector2i(2, 0), Vector2i(6, 0), Vector2i(5, 1),
	Vector2i(7, 1), Vector2i(0, 2), Vector2i(4, 2), Vector2i(6, 2),
	Vector2i(1, 3), Vector2i(7, 3), Vector2i(0, 4), Vector2i(2, 4),
	Vector2i(5, 4), Vector2i(1, 5), Vector2i(6, 5), Vector2i(0, 6),
	Vector2i(4, 6), Vector2i(7, 6), Vector2i(2, 7), Vector2i(5, 7),
]
const BASE_SERVICES := {
	Vector2i(2, 0): "shop",
	Vector2i(4, 2): "medical",
	Vector2i(2, 4): "shop",
	Vector2i(4, 6): "medical",
}

var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var planner = LAYOUT.new()
	var layout_signatures: Dictionary = {}
	var all_contracts_hold := true
	for seed_value in range(7331, 7395):
		var plan: Dictionary = planner.plan(seed_value)
		var repeated: Dictionary = planner.plan(seed_value)
		planner.plan(seed_value + 1)
		var repeated_after_other: Dictionary = planner.plan(seed_value)
		var deterministic := _same_plan(plan, repeated) and _same_plan(plan, repeated_after_other)
		_check(deterministic, "Seed %d is reproducible when reusing one planner instance" % seed_value)
		var symmetry := ((seed_value - 7331) % 8 + 8) % 8
		var expected_cells: Array[Vector2i] = []
		for cell in BASE_CELLS:
			expected_cells.append(_transform_cell(cell, symmetry))
		var unique_cells: Dictionary = {}
		var valid_cells: bool = plan["cells"].size() == 20
		for cell: Vector2i in plan["cells"]:
			valid_cells = valid_cells and cell.x in range(8) and cell.y in range(8) and not unique_cells.has(cell)
			unique_cells[cell] = true
		valid_cells = valid_cells and plan["cells"] == expected_cells
		var expected_services: Dictionary = {}
		for cell: Vector2i in BASE_SERVICES:
			expected_services[_transform_cell(cell, symmetry)] = BASE_SERVICES[cell]
		var service_counts := {"shop": 0, "medical": 0}
		var services_valid: bool = plan["services"] == expected_services and plan["services"].size() == 4
		for cell: Vector2i in plan["services"]:
			var service_type := str(plan["services"][cell])
			services_valid = services_valid and cell in unique_cells and service_counts.has(service_type)
			if service_counts.has(service_type):
				service_counts[service_type] += 1
		services_valid = services_valid and service_counts == {"shop": 2, "medical": 2}
		var start: Vector2i = _transform_cell(Vector2i(3, 7), symmetry)
		var goal: Vector2i = _transform_cell(Vector2i(3, 0), symmetry)
		var anchors_valid: bool = plan["start"] == start and plan["goal"] == goal and start not in unique_cells and goal not in unique_cells
		_check(valid_cells and services_valid and anchors_valid, "Seed %d transforms unique buildings, typed services, start and goal together" % seed_value)
		var roads_valid := _roads_connected(plan)
		_check(roads_valid, "Seed %d has a unique, open, connected road-cell network" % seed_value)
		var graph_valid := _graph_connected(plan)
		_check(graph_valid and plan["connected"], "Seed %d has an actually connected building graph" % seed_value)
		var streets_valid := _streets_follow_layout(plan, symmetry)
		_check(streets_valid, "Seed %d preserves avenue width and transformed dead-end rules" % seed_value)
		all_contracts_hold = all_contracts_hold and deterministic and valid_cells and services_valid and anchors_valid and roads_valid and graph_valid and plan["connected"] and streets_valid
		layout_signatures[str(plan["cells"])] = true
	_check(layout_signatures.size() == 8, "64 seeds produce all eight D4 building layouts")
	_check(all_contracts_hold, "All seeded planner contracts hold across 64 seeds")
	print("ROGUELIKE LAYOUT RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _transform_cell(cell: Vector2i, symmetry: int) -> Vector2i:
	match symmetry:
		1:
			return Vector2i(7 - cell.y, cell.x)
		2:
			return Vector2i(7 - cell.x, 7 - cell.y)
		3:
			return Vector2i(cell.y, 7 - cell.x)
		4:
			return Vector2i(7 - cell.x, cell.y)
		5:
			return Vector2i(cell.x, 7 - cell.y)
		6:
			return Vector2i(cell.y, cell.x)
		7:
			return Vector2i(7 - cell.y, 7 - cell.x)
	return cell


func _inverse_transform_cell(cell: Vector2i, symmetry: int) -> Vector2i:
	match symmetry:
		1:
			return _transform_cell(cell, 3)
		3:
			return _transform_cell(cell, 1)
		_:
			return _transform_cell(cell, symmetry)


func _same_plan(first: Dictionary, second: Dictionary) -> bool:
	for key in ["seed", "cells", "nodes", "services", "start", "goal", "edges", "roads", "streets", "dead_ends", "degree", "connected"]:
		if first.get(key) != second.get(key):
			return false
	return true


func _roads_connected(plan: Dictionary) -> bool:
	var road_cells: Array = plan["roads"]
	var road_set: Dictionary = {}
	var building_set: Dictionary = {}
	for cell: Vector2i in plan["cells"]:
		building_set[cell] = true
	for cell: Vector2i in road_cells:
		if road_set.has(cell) or building_set.has(cell) or cell.x not in range(8) or cell.y not in range(8):
			return false
		road_set[cell] = true
	# The planner's reachability flood starts at the transformed center road.
	var origin := _transform_cell(Vector2i(3, 3), ((int(plan["seed"]) - 7331) % 8 + 8) % 8)
	if not road_set.has(origin) or not road_set.has(plan["start"]) or not road_set.has(plan["goal"]):
		return false
	var reached: Dictionary = {origin: true}
	var queue: Array[Vector2i] = [origin]
	while not queue.is_empty():
		var current: Vector2i = queue.pop_front()
		for step in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			var next: Vector2i = current + step
			if road_set.has(next) and not reached.has(next):
				reached[next] = true
				queue.append(next)
	if reached.size() != road_set.size() or road_set.size() <= 20:
		return false
	# Verify the traversable street graph too: dead-end filtering must not
	# isolate cells that were present in the earlier reachability flood.
	var adjacency: Dictionary = {}
	for cell: Vector2i in road_cells:
		adjacency[cell] = []
	for street: Dictionary in plan["streets"]:
		var first: Vector2i = street["a"]
		var second: Vector2i = street["b"]
		if not adjacency.has(first) or not adjacency.has(second):
			return false
		adjacency[first].append(second)
		adjacency[second].append(first)
	reached = {origin: true}
	queue = [origin]
	while not queue.is_empty():
		var current: Vector2i = queue.pop_front()
		for next: Vector2i in adjacency[current]:
			if not reached.has(next):
				reached[next] = true
				queue.append(next)
	return reached.size() == road_set.size()


func _graph_connected(plan: Dictionary) -> bool:
	var node_count: int = plan["cells"].size()
	var adjacency: Array[Array] = []
	for _index in range(node_count):
		adjacency.append([])
	var edges_valid := true
	for edge: Dictionary in plan["edges"]:
		var first := int(edge["a"])
		var second := int(edge["b"])
		if first < 0 or second < 0 or first >= node_count or second >= node_count or first == second:
			edges_valid = false
			continue
		adjacency[first].append(second)
		adjacency[second].append(first)
	var reached: Dictionary = {0: true}
	var queue: Array[int] = [0]
	while not queue.is_empty():
		var current: int = queue.pop_front()
		for next: int in adjacency[current]:
			if not reached.has(next):
				reached[next] = true
				queue.append(next)
	return edges_valid and reached.size() == node_count and plan["edges"].size() >= node_count - 1


func _streets_follow_layout(plan: Dictionary, symmetry: int) -> bool:
	var expected_dead_ends := [{
		"start": _transform_cell(Vector2i(1, 0), symmetry),
		"end": _transform_cell(Vector2i(1, 1), symmetry),
	}]
	if plan["dead_ends"] != expected_dead_ends:
		return false
	var road_set: Dictionary = {}
	for cell: Vector2i in plan["roads"]:
		road_set[cell] = true
	for street: Dictionary in plan["streets"]:
		var first: Vector2i = street["a"]
		var second: Vector2i = street["b"]
		var canonical_first := _inverse_transform_cell(first, symmetry)
		var canonical_second := _inverse_transform_cell(second, symmetry)
		var expected_wide := (canonical_first.x == 3 or canonical_first.y == 2 or canonical_first.y == 4) and (canonical_second.x == 3 or canonical_second.y == 2 or canonical_second.y == 4)
		if bool(street["wide"]) != expected_wide:
			return false
		for rule: Dictionary in plan["dead_ends"]:
			var rule_start: Vector2i = rule["start"]
			var rule_end: Vector2i = rule["end"]
			if (first == rule_start or second == rule_start) and first != rule_end and second != rule_end:
				return false
		if not road_set.has(first) or not road_set.has(second):
			return false
	return true


func _check(condition: bool, label: String) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		push_error("FAIL: " + label)
