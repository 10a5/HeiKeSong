extends SceneTree
## Godot --headless --path . --script tests/test_map_c_layout.gd

const LAYOUT = preload("res://map_c_layout.gd")
const MODEL_LONG_SIDES := [7.948, 6.669, 9.299, 11.752, 7.359, 7.649, 8.535, 6.708, 7.766, 8.0]
const MODEL_KINDS := ["residential", "residential", "residential", "residential", "residential", "factory", "factory", "shop", "medical", "police"]
const SEEDS := [419, 420, 104729]
const EPS := 0.00002

var passed := 0
var failed := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var planner = LAYOUT.new()
	var templates: Array[Dictionary] = []
	for index in range(MODEL_LONG_SIDES.size()):
		templates.append({"key": "model_%d" % index, "kind": MODEL_KINDS[index], "model_index": index, "short_side": 6.0, "long_side": MODEL_LONG_SIDES[index], "weight": 2.4 if index < 5 else 1.0})
	var signatures: Dictionary = {}
	for seed_value in SEEDS:
		var planned: Dictionary = planner.plan(seed_value, templates, {"verify_saturation": true})
		var repeated: Dictionary = planner.plan(seed_value, templates)
		_check(planned["houses"] == repeated["houses"] and planned["roads"] == repeated["roads"] and planned["anchors"] == repeated["anchors"], "Seed %d repeats full geometry" % seed_value)
		_check(not repeated["stats"]["saturation_verified"] and int(repeated["stats"]["remaining_scan_candidates"]) == -1, "Seed %d marks skipped saturation verification" % seed_value)
		_check(bool(planned["stats"]["saturation_verified"]) and int(planned["stats"]["remaining_scan_candidates"]) == 0, "Seed %d exhausts every final scan candidate" % seed_value)
		_check(planned["bounds"] == Rect2(0, 0, 100, 100), "Seed %d uses 100x100 metres" % seed_value)
		_check(planned["roads"].size() == 7 and planned["houses"].size() > 20, "Seed %d grows populated seven-road map" % seed_value)
		_check(int(planned["stats"]["random_failure_streak"]) == 2200, "Seed %d ends random growth after 2200 failures" % seed_value)
		_check(_roads_valid(planned), "Seed %d has valid main and branches" % seed_value)
		_check(_anchors_valid(planned), "Seed %d uses outward anchors" % seed_value)
		_check(_houses_valid(planned), "Seed %d preserves 6m short side and real long side" % seed_value)
		_check(_all_gaps_valid(planned), "Seed %d passes exact house and road gaps" % seed_value)
		_check(_all_templates_present(planned), "Seed %d includes all ten templates" % seed_value)
		var area := 0.0
		for house: Dictionary in planned["houses"]:
			area += _area(house["polygon"])
		_check(absf(area - float(planned["stats"]["house_area_sum_m2"])) < 0.05, "Seed %d reports actual building area" % seed_value)
		signatures[str(planned["houses"])] = true
		print("MAP C SEED %d: houses=%d random=%d scan=%d min_gaps=%.6f/%.6f elapsed_ms=%d" % [seed_value, planned["stats"]["house_count"], planned["stats"]["accepted_random"], planned["stats"]["accepted_scan"], planned["stats"]["min_house_gap_m"], planned["stats"]["min_road_gap_m"], planned["stats"]["elapsed_ms"]])
	_check(signatures.size() == SEEDS.size(), "Different seeds change geometry")
	print("MAP C RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)

func _roads_valid(plan: Dictionary) -> bool:
	var roads: Array = plan["roads"]
	var main: Dictionary = roads[0]
	var main_direction: Vector2 = (main["b"] - main["a"]).normalized()
	if absf(main_direction.angle() - deg_to_rad(68.0)) > EPS or absf(float(main["width"]) - 10.0) > EPS:
		return false
	for index in range(roads.size()):
		var road: Dictionary = roads[index]
		if _area(road["polygon"]) <= 0.0 or road["polygon"].size() < 3:
			return false
		if index > 0 and absf(float(road["width"]) - 4.0) > EPS:
			return false
		for point: Vector2 in road["polygon"]:
			if point.x < -EPS or point.y < -EPS or point.x > 100.0 + EPS or point.y > 100.0 + EPS:
				return false
	return true

func _anchors_valid(plan: Dictionary) -> bool:
	var roads: Dictionary = {}
	for road: Dictionary in plan["roads"]:
		roads[road["id"]] = road
	for anchor: Dictionary in plan["anchors"]["road"]:
		var road: Dictionary = roads[anchor["parent"]]
		if absf(Vector2(road["u"]).cross(anchor["u"])) > EPS:
			return false
		var midpoint: Vector2 = anchor["p"] + anchor["u"] * float(anchor["length"]) * 0.5
		if Geometry2D.is_point_in_polygon(midpoint + anchor["n"] * 0.1, road["polygon"]):
			return false
	for anchor: Dictionary in plan["anchors"]["house"]:
		var house: Dictionary = plan["houses"][int(anchor["parent"])]
		var midpoint: Vector2 = anchor["p"] + anchor["u"] * float(anchor["length"]) * 0.5
		if Geometry2D.is_point_in_polygon(midpoint + anchor["n"] * 0.1, house["polygon"]):
			return false
	return true

func _houses_valid(plan: Dictionary) -> bool:
	for house: Dictionary in plan["houses"]:
		var width := float(house["width"])
		var depth := float(house["depth"])
		var long_side := float(house["template"]["long_side"])
		if absf(minf(width, depth) - 6.0) > EPS or absf(maxf(width, depth) - long_side) > EPS:
			return false
		var polygon: PackedVector2Array = house["polygon"]
		if _area(polygon) <= 0.0:
			return false
		for point: Vector2 in polygon:
			if point.x < -EPS or point.y < -EPS or point.x > 100.0 + EPS or point.y > 100.0 + EPS:
				return false
		if house["parent_kind"] == "house" and int(house["parent_id"]) >= int(house["id"]):
			return false
	return true

func _all_gaps_valid(plan: Dictionary) -> bool:
	for index in range(plan["houses"].size()):
		var polygon: PackedVector2Array = plan["houses"][index]["polygon"]
		for other in range(index):
			if _polygon_distance(polygon, plan["houses"][other]["polygon"]) < 2.0 - EPS:
				return false
		for road: Dictionary in plan["roads"]:
			if _polygon_distance(polygon, road["polygon"]) < 1.0 - EPS:
				return false
	return true

func _all_templates_present(plan: Dictionary) -> bool:
	for index in range(MODEL_LONG_SIDES.size()):
		if int(plan["stats"]["template_counts"].get("model_%d" % index, 0)) < 1:
			return false
	return true

func _polygon_distance(a: PackedVector2Array, b: PackedVector2Array) -> float:
	for point: Vector2 in a:
		if Geometry2D.is_point_in_polygon(point, b):
			return 0.0
	for point: Vector2 in b:
		if Geometry2D.is_point_in_polygon(point, a):
			return 0.0
	var result := INF
	for i in range(a.size()):
		var a0: Vector2 = a[i]
		var a1: Vector2 = a[(i + 1) % a.size()]
		for j in range(b.size()):
			var b0: Vector2 = b[j]
			var b1: Vector2 = b[(j + 1) % b.size()]
			if Geometry2D.segment_intersects_segment(a0, a1, b0, b1) != null:
				return 0.0
			result = minf(result, minf(minf(_point_segment_distance(a0, b0, b1), _point_segment_distance(a1, b0, b1)), minf(_point_segment_distance(b0, a0, a1), _point_segment_distance(b1, a0, a1))))
	return result

func _point_segment_distance(point: Vector2, a: Vector2, b: Vector2) -> float:
	var delta := b - a
	var t := clampf((point - a).dot(delta) / delta.length_squared(), 0.0, 1.0)
	return point.distance_to(a + delta * t)

func _area(polygon: PackedVector2Array) -> float:
	var area := 0.0
	for index in range(polygon.size()):
		var point: Vector2 = polygon[index]
		var next: Vector2 = polygon[(index + 1) % polygon.size()]
		area += point.cross(next)
	return area * 0.5

func _check(condition: bool, message: String) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		push_error("FAIL: " + message)
