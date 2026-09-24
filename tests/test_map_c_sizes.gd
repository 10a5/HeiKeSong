extends SceneTree
## The floors' map size is a public option of the Map C planner, so a larger
## district can be checked without measuring or building a single GLB. This
## suite covers the option itself: the same growth rules inside a bigger square,
## the floor's own reported bounds, and floor one's original 100 by 100 result.
##
## Godot --headless --path . --fixed-fps 60 --script tests/test_map_c_sizes.gd

const LAYOUT = preload("res://map_c_layout.gd")
const LEVELS = preload("res://level_stats.gd")

var passed := 0
var failed := 0


func _initialize() -> void:
	var plans: Dictionary = {}
	for floor_index in LEVELS.floors():
		var planner = LAYOUT.new()
		var size := LEVELS.map_size(floor_index)
		plans[floor_index] = planner.plan(7331, [], {"map_size": size})
	# Floor one keeps the documented 100 by 100 district with the original rules.
	var first: Dictionary = plans[LEVELS.FLOOR_ONE]
	check(first["bounds"] == Rect2(0.0, 0.0, 100.0, 100.0), "Omitting map_size still plans the original 100 by 100 metre square")
	check((first["roads"] as Array).size() == 7, "The original plan still builds one main road and six branches")
	# Later floors report their own square and grow more into it, under the same
	# setback, gap and road rules.
	for floor_index in [LEVELS.FLOOR_TWO, LEVELS.FLOOR_THREE]:
		var plan: Dictionary = plans[floor_index]
		var size := LEVELS.map_size(floor_index)
		check(plan["bounds"] == Rect2(0.0, 0.0, size, size), "Floor %d reports a %d by %d metre planning square" % [floor_index, int(size), int(size)])
		check((plan["roads"] as Array).size() == 7, "Floor %d keeps the one-main / six-branch road rule" % floor_index)
		var houses: Array = plan["houses"]
		var previous: Array = plans[floor_index - 1]["houses"]
		check(houses.size() > previous.size(), "Floor %d grows more houses than floor %d (%d vs %d)" % [floor_index, floor_index - 1, houses.size(), previous.size()])
		var in_bounds := true
		for house: Dictionary in houses:
			for point: Vector2 in house["polygon"]:
				in_bounds = in_bounds and point.x >= -0.001 and point.y >= -0.001 and point.x <= size + 0.001 and point.y <= size + 0.001
		check(in_bounds, "Every floor %d house stays inside the larger square" % floor_index)
		var stats: Dictionary = plan["stats"]
		check(float(stats["min_house_gap_m"]) >= 1.99 and float(stats["min_road_gap_m"]) >= 0.99, "Floor %d preserves the two-metre house gap and one-metre road setback" % floor_index)
		var longest := 0.0
		for road: Dictionary in plan["roads"]:
			longest = maxf(longest, float(road["length"]))
		check(longest > 100.0, "Floor %d roads run longer than the first floor's (%.1f m)" % [floor_index, longest])
	print("MAP C SIZES RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
		print("PASS: " + description)
	else:
		failed += 1
		push_error("FAIL: " + description)
