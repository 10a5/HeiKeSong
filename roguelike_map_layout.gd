extends RefCounted
class_name RoguelikeMapLayout

## Planning-only port of roguelike_map_handoff/drop_in/tools/graybox_layout.gd.
## The original handoff creates eight-metre elevated bridges.  This adapter
## keeps its seeded graph and road planning, while leaving geometry and
## collision to first_floor_map.gd.

const GRID_SIZE := 8
const CELL := 12.0
const DISTRIBUTED: Array[Vector2i] = [
	Vector2i(0, 0), Vector2i(2, 0), Vector2i(6, 0), Vector2i(5, 1),
	Vector2i(7, 1), Vector2i(0, 2), Vector2i(4, 2), Vector2i(6, 2),
	Vector2i(1, 3), Vector2i(7, 3), Vector2i(0, 4), Vector2i(2, 4),
	Vector2i(5, 4), Vector2i(1, 5), Vector2i(6, 5), Vector2i(0, 6),
	Vector2i(4, 6), Vector2i(7, 6), Vector2i(2, 7), Vector2i(5, 7),
]
const SERVICES := {
	Vector2i(2, 0): "shop",
	Vector2i(4, 2): "medical",
	Vector2i(2, 4): "shop",
	Vector2i(4, 6): "medical",
}
const START := Vector2i(3, 7)
const GOAL := Vector2i(3, 0)
const BASE_DEAD_END_RULES: Array[Dictionary] = [
	{"start": Vector2i(1, 0), "end": Vector2i(1, 1)},
]

var cells: Array[Vector2i] = DISTRIBUTED.duplicate()
var nodes: Array[Vector2] = []
var dead_end_rules: Array[Dictionary] = BASE_DEAD_END_RULES.duplicate(true)
var transform_id := 0


func _init() -> void:
	for cell in cells:
		nodes.append(Vector2((cell.x - 3.5) * CELL, (cell.y - 3.5) * CELL))


func _transform_cell(cell: Vector2i, symmetry: int) -> Vector2i:
	match symmetry:
		1:
			return Vector2i(GRID_SIZE - 1 - cell.y, cell.x)
		2:
			return Vector2i(GRID_SIZE - 1 - cell.x, GRID_SIZE - 1 - cell.y)
		3:
			return Vector2i(cell.y, GRID_SIZE - 1 - cell.x)
		4:
			return Vector2i(GRID_SIZE - 1 - cell.x, cell.y)
		5:
			return Vector2i(cell.x, GRID_SIZE - 1 - cell.y)
		6:
			return Vector2i(cell.y, cell.x)
		7:
			return Vector2i(GRID_SIZE - 1 - cell.y, GRID_SIZE - 1 - cell.x)
	return cell


func _inverse_transform_cell(cell: Vector2i, symmetry: int) -> Vector2i:
	match symmetry:
		1:
			return _transform_cell(cell, 3)
		3:
			return _transform_cell(cell, 1)
		_:
			return _transform_cell(cell, symmetry)


func _prepare_layout(seed_value: int) -> void:
	# Seed 7331 keeps the original handoff orientation; adjacent seeds cycle
	# through the eight rotations and reflections of the square grid.
	transform_id = ((seed_value - 7331) % 8 + 8) % 8
	cells.clear()
	nodes.clear()
	for cell in DISTRIBUTED:
		var transformed := _transform_cell(cell, transform_id)
		cells.append(transformed)
		nodes.append(Vector2((transformed.x - 3.5) * CELL, (transformed.y - 3.5) * CELL))
	dead_end_rules.clear()
	for rule in BASE_DEAD_END_RULES:
		dead_end_rules.append({
			"start": _transform_cell(rule["start"], transform_id),
			"end": _transform_cell(rule["end"], transform_id),
		})


func avenue(cell: Vector2i) -> bool:
	var canonical := _inverse_transform_cell(cell, transform_id)
	return canonical.x == 3 or canonical.y == 2 or canonical.y == 4


func _noise_for(seed_value: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = 0.18
	noise.fractal_octaves = 3
	return noise


func _socket(center: Vector2, toward: Vector2) -> Vector2:
	var direction := toward - center
	return center + direction * (4.8 / maxf(absf(direction.x), absf(direction.y)))


func _hits_box(a: Vector2, b: Vector2, center: Vector2, half_extent: float) -> bool:
	var lower := 0.0
	var upper := 1.0
	var direction := b - a
	for axis in range(2):
		if absf(direction[axis]) < 0.00001:
			if a[axis] < center[axis] - half_extent or a[axis] > center[axis] + half_extent:
				return false
			continue
		var t0 := (center[axis] - half_extent - a[axis]) / direction[axis]
		var t1 := (center[axis] + half_extent - a[axis]) / direction[axis]
		lower = maxf(lower, minf(t0, t1))
		upper = minf(upper, maxf(t0, t1))
		if lower > upper:
			return false
	return true


func _clear_path(points: Array, first: int, second: int) -> bool:
	for index in range(nodes.size()):
		if index == first or index == second:
			continue
		for segment in range(points.size() - 1):
			if _hits_box(points[segment], points[segment + 1], nodes[index], 5.95):
				return false
	return true


func _find_root(parents: Array[int], id: int) -> int:
	var current := id
	while parents[current] != current:
		current = parents[current]
	return current


func plan(seed_value: int) -> Dictionary:
	_prepare_layout(seed_value)
	var noise := _noise_for(seed_value)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var candidates: Array[Dictionary] = []
	for first in range(nodes.size()):
		for second in range(first + 1, nodes.size()):
			var start: Vector2 = nodes[first]
			var finish: Vector2 = nodes[second]
			var length := start.distance_to(finish)
			if length > 53.0:
				continue
			var points: Array = [_socket(start, finish), _socket(finish, start)]
			if not _clear_path(points, first, second):
				continue
			var midpoint := (start + finish) / 2.0
			var density := clampf((noise.get_noise_3d(midpoint.x, midpoint.y, float(first + second) * 0.31) + 1.0) * 0.5, 0.0, 1.0)
			var bend := Vector2(finish.x, start.y) if rng.randf() < 0.5 else Vector2(start.x, finish.y)
			var shape := "straight"
			if absf(start.x - finish.x) > 14.0 and absf(start.y - finish.y) > 14.0 and density > 0.43 and rng.randf() < 0.5:
				var bent: Array = [_socket(start, bend), bend, _socket(finish, bend)]
				if _clear_path(bent, first, second):
					points = bent
					shape = "elbow"
			var cost := length * (1.35 - density) + rng.randf_range(0.0, 9.0)
			candidates.append({"a": first, "b": second, "points": points, "density": density, "cost": cost, "shape": shape})
	candidates.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return left["cost"] < right["cost"])

	var parents: Array[int] = []
	var degree: Array[int] = []
	for index in range(nodes.size()):
		parents.append(index)
		degree.append(0)
	var edges: Array[Dictionary] = []
	var selected: Dictionary = {}
	for candidate in candidates:
		var root_a := _find_root(parents, int(candidate["a"]))
		var root_b := _find_root(parents, int(candidate["b"]))
		if root_a == root_b:
			continue
		parents[root_a] = root_b
		candidate["backbone"] = true
		edges.append(candidate)
		selected["%d:%d" % [candidate["a"], candidate["b"]]] = true
		degree[int(candidate["a"])] += 1
		degree[int(candidate["b"])] += 1
	var target := rng.randi_range(22, 26)
	for candidate in candidates:
		if edges.size() >= target:
			break
		var key := "%d:%d" % [candidate["a"], candidate["b"]]
		if selected.has(key) or degree[int(candidate["a"])] >= 4 or degree[int(candidate["b"])] >= 4:
			continue
		if rng.randf() > clampf(0.25 + float(candidate["density"]) * 0.7, 0.0, 1.0):
			continue
		candidate["backbone"] = false
		edges.append(candidate)
		selected[key] = true
		degree[int(candidate["a"])] += 1
		degree[int(candidate["b"])] += 1

	for edge in edges:
		if edge["shape"] != "straight" or rng.randf() > 0.42:
			continue
		var first_point: Vector2 = edge["points"][0]
		var last_point: Vector2 = edge["points"][edge["points"].size() - 1]
		if first_point.distance_to(last_point) < 8.0:
			continue
		var direction := (last_point - first_point).normalized()
		var offset := Vector2(-direction.y, direction.x) * rng.randf_range(1.2, 2.8)
		if rng.randf() < 0.5:
			offset = -offset
		var dogleg := [first_point, (first_point + last_point) * 0.5 + offset, last_point]
		if _clear_path(dogleg, int(edge["a"]), int(edge["b"])):
			edge["points"] = dogleg
			edge["shape"] = "dogleg"

	var road_cells: Array[Vector2i] = []
	for y in range(GRID_SIZE):
		for x in range(GRID_SIZE):
			var cell := Vector2i(x, y)
			if cell not in cells:
				road_cells.append(cell)
	var road_origin := _transform_cell(Vector2i(3, 3), transform_id)
	var reachable: Array[Vector2i] = [road_origin]
	var queue: Array[Vector2i] = [road_origin]
	while not queue.is_empty():
		var current: Vector2i = queue.pop_front()
		for step in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			var next: Vector2i = current + step
			if next in road_cells and next not in reachable:
				reachable.append(next)
				queue.append(next)
	road_cells = reachable
	var streets: Array[Dictionary] = []
	for cell in road_cells:
		for step in [Vector2i.RIGHT, Vector2i.DOWN]:
			var next: Vector2i = cell + step
			if next not in road_cells:
				continue
			var blocked := false
			for rule in dead_end_rules:
				if (cell == rule["start"] or next == rule["start"]) and cell != rule["end"] and next != rule["end"]:
					blocked = true
			if blocked:
				continue
			streets.append({"a": cell, "b": next, "wide": avenue(cell) and avenue(next)})
	var graph_root := _find_root(parents, 0)
	var graph_connected := true
	for index in range(1, parents.size()):
		if _find_root(parents, index) != graph_root:
			graph_connected = false
			break
	var transformed_services: Dictionary = {}
	for cell: Vector2i in SERVICES:
		transformed_services[_transform_cell(cell, transform_id)] = SERVICES[cell]
	return {
		"seed": seed_value,
		"cells": cells.duplicate(),
		"nodes": nodes.duplicate(),
		"services": transformed_services,
		"start": _transform_cell(START, transform_id),
		"goal": _transform_cell(GOAL, transform_id),
		"edges": edges,
		"roads": road_cells,
		"streets": streets,
		"dead_ends": dead_end_rules.duplicate(true),
		"degree": degree,
		"connected": graph_connected,
	}
