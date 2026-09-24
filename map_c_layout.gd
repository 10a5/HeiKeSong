extends RefCounted
class_name MapCLayout

## Planning-only implementation of the C-map rules in map_c_generation_logic.md.
## Coordinates are metres in a 100 by 100 XY plane. The 3D adapter can map
## (x, y) to Godot's XZ plane with Vector3(x, height, -y).

const EPS := 0.000001
## Floor one's square planning area. Larger floors pass `options["map_size"]`
## to `plan()` instead of editing this default, so the growth rules themselves
## stay identical and only the available area changes.
const MAP_SIZE := 100.0
const MAP_BOUNDS := Rect2(0.0, 0.0, MAP_SIZE, MAP_SIZE)
const MAIN_ANGLE := deg_to_rad(68.0)
const MAIN_WIDTH := 10.0
const BRANCH_WIDTH := 4.0
const BRANCH_COUNT_PER_SIDE := 3
const BRANCH_STARTS := [0.18, 0.50, 0.82]
const BRANCH_START_JITTER := 0.045
const BRANCH_ANGLE_JITTER := 25.0
const HOUSE_SHORT_SIDE := 6.0
const ROAD_SETBACK := 1.0
const HOUSE_GAP := 2.0
const MIN_FRONTAGE_OVERLAP := 2.0
const ROAD_PICK_PROBABILITY := 0.42
const SWAP_SIDES_PROBABILITY := 0.30
const RANDOM_FAILURE_LIMIT := 2200
const SCAN_STEP := 0.5
const HASH_CELL := 12.0

var _rng := RandomNumberGenerator.new()
var _seed := 0
## Planning rectangle for this run. Defaults to the first floor's 100 x 100
## square and is replaced by `options["map_size"]` for later, larger floors.
var _bounds := MAP_BOUNDS
var _roads: Array[Dictionary] = []
var _road_anchors: Array[Dictionary] = []
var _house_anchors: Array[Dictionary] = []
var _houses: Array[Dictionary] = []
var _house_hash: Dictionary = {}
var _templates: Array[Dictionary] = []
var _template_counts: Dictionary = {}
var _next_house_id := 0
var _attempts := 0
var _random_attempts := 0
var _scan_attempts := 0
var _random_failures := 0
var _accepted_random := 0
var _accepted_scan := 0
var _last_candidate_remaining := -1
var _saturation_verified := false
var _elapsed_ms := 0


func plan(seed_value: int, templates: Array[Dictionary] = [], options: Dictionary = {}) -> Dictionary:
	var started_ms := Time.get_ticks_msec()
	_seed = seed_value
	_rng.seed = seed_value
	# A bigger floor keeps every planning rule (road angle, widths, setback,
	# house gap, growth order) and only widens the square the city grows into.
	var requested_size := float(options.get("map_size", MAP_SIZE))
	_bounds = Rect2(0.0, 0.0, maxf(requested_size, 20.0), maxf(requested_size, 20.0))
	_reset(templates)
	_build_roads()
	var failure_streak := 0
	while failure_streak < int(options.get("random_failure_limit", RANDOM_FAILURE_LIMIT)):
		var accepted := _try_random_placement()
		if accepted:
			failure_streak = 0
		else:
			failure_streak += 1
	_random_failures = failure_streak
	_scan_anchors()
	var verify_saturation := bool(options.get("verify_saturation", false))
	if verify_saturation:
		_last_candidate_remaining = _count_remaining_scan_candidates()
		_saturation_verified = true
	else:
		_last_candidate_remaining = -1
	_elapsed_ms = Time.get_ticks_msec() - started_ms
	return _result()


func _reset(input_templates: Array[Dictionary]) -> void:
	_roads.clear()
	_road_anchors.clear()
	_house_anchors.clear()
	_houses.clear()
	_house_hash.clear()
	_template_counts.clear()
	_next_house_id = 0
	_attempts = 0
	_random_attempts = 0
	_scan_attempts = 0
	_random_failures = 0
	_accepted_random = 0
	_accepted_scan = 0
	_last_candidate_remaining = -1
	_saturation_verified = false
	_elapsed_ms = 0
	_templates.clear()
	for raw in input_templates:
		var template := raw.duplicate(true)
		template["short_side"] = HOUSE_SHORT_SIDE
		template["long_side"] = maxf(HOUSE_SHORT_SIDE, float(template.get("long_side", 10.0)))
		template["key"] = str(template.get("key", "template_%d" % _templates.size()))
		template["kind"] = str(template.get("kind", "residential"))
		template["model_index"] = int(template.get("model_index", 0))
		template["weight"] = maxf(0.0, float(template.get("weight", 1.0)))
		_templates.append(template)
		_template_counts[template["key"]] = 0
	if _templates.is_empty():
		_templates.append({"key": "default", "kind": "residential", "model_index": 0, "short_side": HOUSE_SHORT_SIDE, "long_side": 10.0, "weight": 1.0})
		_template_counts["default"] = 0


func _build_roads() -> void:
	var center := _bounds.get_center()
	var reference := center + Vector2(_rng.randf_range(-6.0, 6.0), _rng.randf_range(-6.0, 6.0))
	var main_direction := Vector2(cos(MAIN_ANGLE), sin(MAIN_ANGLE))
	var main_line := _line_through_rect(reference, main_direction, _bounds)
	_add_road("main", MAIN_WIDTH, main_line[0], main_line[1])
	var main_a: Vector2 = main_line[0]
	var main_b: Vector2 = main_line[1]
	var main_delta := main_b - main_a
	var length_ratios := [0.67, 0.80, 1.0]
	var length_weights := [0.20, 0.25, 0.55]
	var branch_index := 0
	for side in [-1.0, 1.0]:
		for base_fraction in BRANCH_STARTS:
			var fraction := clampf(base_fraction + _rng.randf_range(-BRANCH_START_JITTER, BRANCH_START_JITTER), 0.02, 0.98)
			var start := main_a + main_delta * fraction
			var delta_angle := _rng.randf_range(-BRANCH_ANGLE_JITTER, BRANCH_ANGLE_JITTER)
			var branch_angle: float = MAIN_ANGLE + float(side) * (PI * 0.5 + deg_to_rad(delta_angle))
			var direction := Vector2(cos(branch_angle), sin(branch_angle)).normalized()
			var available := _ray_to_rect(start, direction, _bounds)
			var ratio := _weighted_choice(length_ratios, length_weights)
			var finish := start + direction * available * ratio
			_add_road("branch_%d" % branch_index, BRANCH_WIDTH, start, finish)
			branch_index += 1


func _add_road(id: String, width: float, a: Vector2, b: Vector2) -> void:
	var direction := (b - a).normalized()
	var normal := Vector2(-direction.y, direction.x) * width * 0.5
	var polygon := _clip_polygon_to_bounds(PackedVector2Array([a + normal, b + normal, b - normal, a - normal]))
	# A line can be clipped at its end points, but its width still needs to
	# be represented by a convex polygon for exact distance checks.
	if _polygon_area(polygon) < 0.0:
		polygon.reverse()
	var road := {"id": id, "width": width, "a": a, "b": b, "polygon": polygon, "kind": "main" if id == "main" else "branch", "u": direction, "length": a.distance_to(b)}
	_roads.append(road)
	if polygon.size() < 4:
		return
	for index in range(polygon.size()):
		var p: Vector2 = polygon[index]
		var q: Vector2 = polygon[(index + 1) % polygon.size()]
		var edge_u := (q - p).normalized()
		# Cropping creates map-boundary edges too. Only the two original
		# centreline-parallel sides can provide road-growth anchors.
		if absf(edge_u.cross(direction)) > EPS:
			continue
		var edge_n := Vector2(edge_u.y, -edge_u.x)
		_road_anchors.append(_make_anchor(p, q, edge_n, "road", id, ROAD_SETBACK))


func _try_random_placement() -> bool:
	var anchor: Dictionary = _choose_random_anchor()
	if anchor.is_empty():
		return false
	var template := _template_for_attempt()
	var swapped := _rng.randf() < SWAP_SIDES_PROBABILITY
	var width := float(template["long_side"]) if swapped else HOUSE_SHORT_SIDE
	var depth := HOUSE_SHORT_SIDE if swapped else float(template["long_side"])
	var low := -width + MIN_FRONTAGE_OVERLAP
	var high := float(anchor["length"]) - MIN_FRONTAGE_OVERLAP
	_attempts += 1
	_random_attempts += 1
	if high < low:
		return false
	var offset := _rng.randf_range(low, high)
	return _place_from_anchor(anchor, offset, width, depth, template, "random")


func _template_for_attempt() -> Dictionary:
	var missing: Array[Dictionary] = []
	for template: Dictionary in _templates:
		if int(_template_counts.get(template["key"], 0)) == 0:
			missing.append(template)
	if not missing.is_empty():
		return missing[_rng.randi_range(0, missing.size() - 1)]
	return _weighted_template()


func _weighted_template() -> Dictionary:
	var total := 0.0
	for template: Dictionary in _templates:
		total += float(template["weight"])
	if total <= EPS:
		return _templates[_rng.randi_range(0, _templates.size() - 1)]
	var pick := _rng.randf() * total
	for template: Dictionary in _templates:
		pick -= float(template["weight"])
		if pick <= 0.0:
			return template
	return _templates.back()


func _choose_random_anchor() -> Dictionary:
	if _house_anchors.is_empty() or (_rng.randf() < ROAD_PICK_PROBABILITY and not _road_anchors.is_empty()):
		return _weighted_anchor(_road_anchors)
	return _house_anchors[_rng.randi_range(0, _house_anchors.size() - 1)]


func _weighted_anchor(anchors: Array[Dictionary]) -> Dictionary:
	if anchors.is_empty():
		return {}
	var total := 0.0
	for anchor: Dictionary in anchors:
		total += float(anchor["length"])
	var pick := _rng.randf() * maxf(total, EPS)
	for anchor: Dictionary in anchors:
		pick -= float(anchor["length"])
		if pick <= 0.0:
			return anchor
	return anchors.back()


func _place_from_anchor(anchor: Dictionary, offset: float, width: float, depth: float, template: Dictionary, phase: String) -> bool:
	var p0: Vector2 = anchor["p"] + anchor["u"] * offset + anchor["n"] * float(anchor["gap"])
	var p1: Vector2 = p0 + anchor["u"] * width
	var p2: Vector2 = p1 + anchor["n"] * depth
	var p3: Vector2 = p0 + anchor["n"] * depth
	var polygon := PackedVector2Array([p0, p1, p2, p3])
	if _polygon_area(polygon) < 0.0:
		polygon.reverse()
	if not _is_valid_house(polygon):
		return false
	var id := _next_house_id
	_next_house_id += 1
	var center: Vector2 = (p0 + p1 + p2 + p3) * 0.25
	var house := {
		"id": id,
		"center": center,
		"polygon": polygon,
		"width": width,
		"depth": depth,
		"angle": atan2(anchor["u"].y, anchor["u"].x),
		"template": template.duplicate(true),
		"parent_kind": anchor["kind"],
		"parent_id": anchor["parent"],
		"generation": int(anchor.get("generation", -1)) + 1,
		"placement_phase": phase,
		"entrance_candidate": (p0 + p1) * 0.5,
	}
	_houses.append(house)
	_template_counts[template["key"]] = int(_template_counts.get(template["key"], 0)) + 1
	_add_house_hash(house)
	for index in range(polygon.size()):
		var p: Vector2 = polygon[index]
		var q: Vector2 = polygon[(index + 1) % polygon.size()]
		var u := (q - p).normalized()
		var n := Vector2(u.y, -u.x)
		_house_anchors.append(_make_anchor(p, q, n, "house", id, HOUSE_GAP, int(house["generation"])))
	if phase == "random":
		_accepted_random += 1
	else:
		_accepted_scan += 1
	return true


func _is_valid_house(polygon: PackedVector2Array) -> bool:
	for point: Vector2 in polygon:
		if point.x < _bounds.position.x - EPS or point.y < _bounds.position.y - EPS or point.x > _bounds.end.x + EPS or point.y > _bounds.end.y + EPS:
			return false
	for road: Dictionary in _roads:
		if _polygons_within_distance(polygon, road["polygon"], ROAD_SETBACK - EPS):
			return false
	var query := _hash_query(polygon, HOUSE_GAP)
	var checked: Dictionary = {}
	for key in query:
		for house_id in _house_hash.get(key, []):
			if checked.has(house_id):
				continue
			checked[house_id] = true
			var other: Dictionary = _houses[int(house_id)]
			if _polygons_within_distance(polygon, other["polygon"], HOUSE_GAP - EPS):
				return false
	return true


func _scan_anchors() -> void:
	var queue: Array[Dictionary] = []
	queue.append_array(_road_anchors.duplicate())
	queue.append_array(_house_anchors.duplicate())
	_shuffle(queue)
	var queue_index := 0
	while queue_index < queue.size():
		var anchor: Dictionary = queue[queue_index]
		queue_index += 1
		var orientations := [false, true]
		_shuffle(orientations)
		for swapped: bool in orientations:
			for template: Dictionary in _templates:
				var long_side := float(template["long_side"])
				var width := long_side if swapped else HOUSE_SHORT_SIDE
				var depth := HOUSE_SHORT_SIDE if swapped else long_side
				var low := -width + MIN_FRONTAGE_OVERLAP
				var high := float(anchor["length"]) - MIN_FRONTAGE_OVERLAP
				if high < low:
					continue
				var offsets: Array[float] = []
				var offset := low
				while offset <= high + EPS:
					offsets.append(offset)
					offset += SCAN_STEP
				_shuffle(offsets)
				for sampled_offset in offsets:
					_attempts += 1
					_scan_attempts += 1
					if _place_from_anchor(anchor, sampled_offset, width, depth, template, "scan"):
						var first_new := _house_anchors.size() - 4
						for edge_index in range(first_new, _house_anchors.size()):
							queue.append(_house_anchors[edge_index])


func _count_remaining_scan_candidates() -> int:
	var count := 0
	var all_anchors: Array[Dictionary] = []
	all_anchors.append_array(_road_anchors)
	all_anchors.append_array(_house_anchors)
	for anchor: Dictionary in all_anchors:
		for template: Dictionary in _templates:
			for swapped in [false, true]:
				var width := HOUSE_SHORT_SIDE if not swapped else float(template["long_side"])
				var depth := float(template["long_side"]) if not swapped else HOUSE_SHORT_SIDE
				var low := -width + MIN_FRONTAGE_OVERLAP
				var high := float(anchor["length"]) - MIN_FRONTAGE_OVERLAP
				if high < low:
					continue
				var offset := low
				while offset <= high + EPS:
					var p0: Vector2 = anchor["p"] + anchor["u"] * offset + anchor["n"] * float(anchor["gap"])
					var p1: Vector2 = p0 + anchor["u"] * width
					var p2: Vector2 = p1 + anchor["n"] * depth
					var p3: Vector2 = p0 + anchor["n"] * depth
					if _is_valid_house(PackedVector2Array([p0, p1, p2, p3])):
						count += 1
					offset += SCAN_STEP
	return count


func _make_anchor(p: Vector2, q: Vector2, n: Vector2, kind: String, parent: Variant, gap: float, generation := 0) -> Dictionary:
	var direction := (q - p).normalized()
	return {"p": p, "u": direction, "n": n.normalized(), "length": p.distance_to(q), "kind": kind, "parent": parent, "gap": gap, "generation": generation}


func _add_house_hash(house: Dictionary) -> void:
	for key in _hash_keys_for_polygon(house["polygon"], HOUSE_GAP):
		if not _house_hash.has(key):
			_house_hash[key] = []
		_house_hash[key].append(house["id"])


func _hash_query(polygon: PackedVector2Array, margin: float) -> Array:
	return _hash_keys_for_polygon(polygon, margin)


func _hash_keys_for_polygon(polygon: PackedVector2Array, margin: float) -> Array:
	var bounds := _polygon_bounds(polygon).grow(margin)
	var result: Array = []
	var min_cell := Vector2i(floori(bounds.position.x / HASH_CELL), floori(bounds.position.y / HASH_CELL))
	var max_point := bounds.position + bounds.size
	var max_cell := Vector2i(floori(max_point.x / HASH_CELL), floori(max_point.y / HASH_CELL))
	for y in range(min_cell.y, max_cell.y + 1):
		for x in range(min_cell.x, max_cell.x + 1):
			result.append(Vector2i(x, y))
	return result


func _polygon_distance(a: PackedVector2Array, b: PackedVector2Array) -> float:
	if _polygons_intersect(a, b):
		return 0.0
	var best := INF
	for i in range(a.size()):
		var a0: Vector2 = a[i]
		var a1: Vector2 = a[(i + 1) % a.size()]
		for j in range(b.size()):
			var b0: Vector2 = b[j]
			var b1: Vector2 = b[(j + 1) % b.size()]
			best = minf(best, _segment_distance(a0, a1, b0, b1))
	return best


func _polygons_within_distance(a: PackedVector2Array, b: PackedVector2Array, limit: float) -> bool:
	# Most candidates are far from most roads/buildings. The AABB lower bound
	# avoids all segment tests in that common case; exact convex edge distance
	# is used only when the boxes can be closer than the requested gap.
	if _polygon_bounds_distance(a, b) >= limit:
		return false
	if _polygons_intersect(a, b):
		return true
	for i in range(a.size()):
		var a0: Vector2 = a[i]
		var a1: Vector2 = a[(i + 1) % a.size()]
		for j in range(b.size()):
			var b0: Vector2 = b[j]
			var b1: Vector2 = b[(j + 1) % b.size()]
			if _segment_distance(a0, a1, b0, b1) < limit:
				return true
	return false


func _polygons_intersect(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	for point: Vector2 in a:
		if Geometry2D.is_point_in_polygon(point, b):
			return true
	for point: Vector2 in b:
		if Geometry2D.is_point_in_polygon(point, a):
			return true
	for i in range(a.size()):
		var a0: Vector2 = a[i]
		var a1: Vector2 = a[(i + 1) % a.size()]
		for j in range(b.size()):
			var b0: Vector2 = b[j]
			var b1: Vector2 = b[(j + 1) % b.size()]
			if Geometry2D.segment_intersects_segment(a0, a1, b0, b1) != null:
				return true
	return false


func _segment_distance(a0: Vector2, a1: Vector2, b0: Vector2, b1: Vector2) -> float:
	if Geometry2D.segment_intersects_segment(a0, a1, b0, b1) != null:
		return 0.0
	return minf(minf(_point_segment_distance(a0, b0, b1), _point_segment_distance(a1, b0, b1)), minf(_point_segment_distance(b0, a0, a1), _point_segment_distance(b1, a0, a1)))


func _point_segment_distance(point: Vector2, a: Vector2, b: Vector2) -> float:
	var delta := b - a
	var length_sq := delta.length_squared()
	if length_sq <= EPS:
		return point.distance_to(a)
	var t := clampf((point - a).dot(delta) / length_sq, 0.0, 1.0)
	return point.distance_to(a + delta * t)


func _polygon_area(polygon: PackedVector2Array) -> float:
	var area := 0.0
	for index in range(polygon.size()):
		var p: Vector2 = polygon[index]
		var q: Vector2 = polygon[(index + 1) % polygon.size()]
		area += p.x * q.y - q.x * p.y
	return area * 0.5


func _polygon_bounds(polygon: PackedVector2Array) -> Rect2:
	var bounds := Rect2(polygon[0], Vector2.ZERO)
	for point: Vector2 in polygon:
		bounds = bounds.expand(point)
	return bounds


func _polygon_bounds_distance(a: PackedVector2Array, b: PackedVector2Array) -> float:
	var first := _polygon_bounds(a)
	var second := _polygon_bounds(b)
	var dx := maxf(maxf(first.position.x - second.end.x, second.position.x - first.end.x), 0.0)
	var dy := maxf(maxf(first.position.y - second.end.y, second.position.y - first.end.y), 0.0)
	return sqrt(dx * dx + dy * dy)


func _line_through_rect(center: Vector2, direction: Vector2, rect: Rect2) -> Array:
	var far := maxf(rect.size.length() * 2.0, 220.0)
	var a := center - direction.normalized() * far
	var b := center + direction.normalized() * far
	var clipped := _clip_segment_to_rect(a, b, rect)
	return [clipped[0], clipped[1]]


func _ray_to_rect(start: Vector2, direction: Vector2, rect: Rect2) -> float:
	var result := INF
	var d := direction.normalized()
	for axis in range(2):
		if absf(d[axis]) <= EPS:
			continue
		var boundary := rect.position[axis] + (rect.size[axis] if d[axis] > 0.0 else 0.0)
		var distance := (boundary - start[axis]) / d[axis]
		if distance >= 0.0:
			var point := start + d * distance
			var tolerance := 0.0001
			if point.x >= rect.position.x - tolerance and point.y >= rect.position.y - tolerance and point.x <= rect.end.x + tolerance and point.y <= rect.end.y + tolerance:
				result = minf(result, distance)
	return result if is_finite(result) else 0.0


func _clip_segment_to_rect(a: Vector2, b: Vector2, rect: Rect2) -> Array:
	var low := 0.0
	var high := 1.0
	var delta := b - a
	for axis in range(2):
		if absf(delta[axis]) <= EPS:
			continue
		var t0 := (rect.position[axis] - a[axis]) / delta[axis]
		var t1 := (rect.end[axis] - a[axis]) / delta[axis]
		if t0 > t1:
			var swap := t0
			t0 = t1
			t1 = swap
		low = maxf(low, t0)
		high = minf(high, t1)
	return [a + delta * low, a + delta * high]


func _clip_polygon_to_bounds(polygon: PackedVector2Array) -> PackedVector2Array:
	var current: Array = []
	for point in polygon:
		current.append(point)
	for boundary in range(4):
		var next: Array = []
		if current.is_empty():
			break
		for index in range(current.size()):
			var first: Vector2 = current[index]
			var second: Vector2 = current[(index + 1) % current.size()]
			var first_inside := _inside_boundary(first, boundary)
			var second_inside := _inside_boundary(second, boundary)
			if first_inside and second_inside:
				next.append(second)
			elif first_inside and not second_inside:
				next.append(_boundary_intersection(first, second, boundary))
			elif not first_inside and second_inside:
				next.append(_boundary_intersection(first, second, boundary))
				next.append(second)
		current = next
	var result := PackedVector2Array()
	for point: Vector2 in current:
		result.append(point)
	return result


func _inside_boundary(point: Vector2, boundary: int) -> bool:
	match boundary:
		0: return point.x >= _bounds.position.x - EPS
		1: return point.x <= _bounds.end.x + EPS
		2: return point.y >= _bounds.position.y - EPS
		_: return point.y <= _bounds.end.y + EPS


func _boundary_intersection(a: Vector2, b: Vector2, boundary: int) -> Vector2:
	var axis := 0 if boundary < 2 else 1
	var value := _bounds.position[axis] if boundary == 0 or boundary == 2 else _bounds.end[axis]
	var delta := b[axis] - a[axis]
	if absf(delta) <= EPS:
		return a
	var t := (value - a[axis]) / delta
	return a + (b - a) * t


func _weighted_choice(values: Array, weights: Array) -> float:
	var total := 0.0
	for weight in weights:
		total += float(weight)
	var pick := _rng.randf() * maxf(total, EPS)
	for index in range(values.size()):
		pick -= float(weights[index])
		if pick <= 0.0:
			return float(values[index])
	return float(values.back())


func _shuffle(values: Array) -> void:
	for index in range(values.size() - 1, 0, -1):
		var other := _rng.randi_range(0, index)
		var swap = values[index]
		values[index] = values[other]
		values[other] = swap


func _result() -> Dictionary:
	var road_area := 0.0
	var house_area := 0.0
	for road: Dictionary in _roads:
		road_area += absf(_polygon_area(road["polygon"]))
	var min_house_gap := INF
	var min_road_gap := INF
	for index in range(_houses.size()):
		house_area += float(_houses[index]["width"]) * float(_houses[index]["depth"])
		for road: Dictionary in _roads:
			min_road_gap = minf(min_road_gap, _polygon_distance(_houses[index]["polygon"], road["polygon"]))
		for other in range(index):
			min_house_gap = minf(min_house_gap, _polygon_distance(_houses[index]["polygon"], _houses[other]["polygon"]))
	return {
		"map_id": "C",
		"seed": _seed,
		"bounds": _bounds,
		"roads": _roads.duplicate(true),
		"houses": _houses.duplicate(true),
		"anchors": {"road": _road_anchors.duplicate(true), "house": _house_anchors.duplicate(true)},
		"start": _roads[0]["a"] if not _roads.is_empty() else Vector2(50.0, 0.0),
		"goal": _roads[0]["b"] if not _roads.is_empty() else Vector2(50.0, 100.0),
		"stats": {
			"house_count": _houses.size(),
			"road_count": _roads.size(),
			"road_area_sum_m2": road_area,
			"house_area_sum_m2": house_area,
			"elapsed_ms": _elapsed_ms,
			"random_attempts": _random_attempts,
			"scan_attempts": _scan_attempts,
			"attempts": _attempts,
			"random_failure_streak": _random_failures,
			"accepted_random": _accepted_random,
			"accepted_scan": _accepted_scan,
			"template_counts": _template_counts.duplicate(true),
			"min_house_gap_m": 0.0 if _houses.size() < 2 else min_house_gap,
			"min_road_gap_m": 0.0 if _houses.is_empty() else min_road_gap,
			"remaining_scan_candidates": _last_candidate_remaining,
			"saturation_verified": _saturation_verified,
		},
	}
