extends SceneTree
## Throwaway visual harness for the Boss-victory ending.
##
##   godot --path . --fixed-fps 60 --script tools/_ending_check.gd
##
## Drives a real first-floor duel to a real victory and then captures the whole
## sequence: the collapse, the fall into the water, the overhead shot of 雾子
## under the quote, and the digital shop gate. Frames land in `_visual_check/`.

const OUTPUT_DIR := "res://_visual_check"
## Seconds after the ending starts, with the label each frame is saved under.
const CHECKPOINTS: Array = [
	[0.9, "collapse-a"],
	[2.1, "collapse-b"],
	[3.9, "submerge"],
	[5.6, "mirror-a"],
	[7.8, "mirror-b"],
	[10.2, "mirror-c"],
	[11.6, "digital-a"],
	[13.0, "digital-b"],
	[13.5, "gate"],
]

var _floor: Node
var _ending: Node
var _frames_per_second := 60.0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	var packed: PackedScene = load("res://floor_one.tscn")
	_floor = packed.instantiate()
	root.add_child(_floor)
	for _index in range(90):
		await process_frame
	print("floor ready, seed=%s" % str(_floor.get("map_seed")))
	await _reach_victory()
	if not is_instance_valid(_ending):
		print("ENDING DID NOT START")
		quit(1)
		return
	var bounds: AABB = _ending.call("arena_bounds")
	print("arena bounds position=%s size=%s player=%s" % [
		str(bounds.position.snapped(Vector3(0.1, 0.1, 0.1))),
		str(bounds.size.snapped(Vector3(0.1, 0.1, 0.1))),
		str((_floor.get("player") as Node3D).global_position.snapped(Vector3(0.1, 0.1, 0.1))),
	])
	for checkpoint: Array in CHECKPOINTS:
		await _advance_to(float(checkpoint[0]))
		await _capture(str(checkpoint[1]))
	print("ENDING CHECK COMPLETE")
	quit(0)


## Real duel hand-off, real victory: the whole point of this harness is that it
## never calls the ending directly.
func _reach_victory() -> void:
	var erosion: Node = _floor.get("erosion")
	erosion.call("reset", 99)
	erosion.call("set_combat_active", false)
	erosion.call("process_activity", 1.0, true, false)
	for _index in range(600):
		if bool(_floor.get("_boss_active")):
			break
		await process_frame
	var boss: Node = _floor.get("boss_target")
	if not is_instance_valid(boss):
		print("BOSS NEVER SPAWNED")
		return
	print("duel live, boss health=%d" % int(boss.get("max_health")))
	# Skip the protected entrance and land a lethal hit, exactly as a finished
	# duel would.
	boss.set("entrance_time_left", 0.0)
	boss.set("is_entering", false)
	boss.call("take_damage", 99999.0, true)
	for _index in range(120):
		_ending = _floor.get("ending")
		if is_instance_valid(_ending):
			return
		await process_frame


func _advance_to(seconds: float) -> void:
	var target := int(round(seconds * _frames_per_second))
	while _elapsed_frames() < target:
		await process_frame


func _elapsed_frames() -> int:
	if is_instance_valid(_ending):
		return int(round(float(_ending.get("_elapsed")) * _frames_per_second))
	return 0


func _capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png("%s/ending_%s.png" % [OUTPUT_DIR, label])
	var stage := "?"
	var notes := ""
	var camera_node: Camera3D = _floor.get("camera")
	if is_instance_valid(_ending):
		stage = str(_ending.call("stage"))
		notes = "flood=%.2f surface=%s camera_rot=%s mirror=%s" % [
			float(_ending.get("_flood_y")),
			str((_ending.get("_floor_surface") as Vector3).snapped(Vector3(0.1, 0.1, 0.1))),
			str(camera_node.rotation_degrees.snapped(Vector3(1.0, 1.0, 1.0))) if is_instance_valid(camera_node) else "-",
			str((_ending.get("_mirror_holder") as Node3D).global_position.snapped(Vector3(0.1, 0.1, 0.1))) if is_instance_valid(_ending.get("_mirror_holder")) else "-",
		]
	print("%-12s stage=%-9s %s" % [label, stage, notes])
