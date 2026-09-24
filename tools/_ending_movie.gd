extends SceneTree
## Records the first-floor Boss-victory ending as a movie.
##
##   godot --path . --write-movie _visual_check/ending_first_floor.avi \
##         --fixed-fps 60 --script tools/_ending_movie.gd
##
## Movie Maker mode writes every rendered frame, so this harness only has to
## drive the shipped sequence: a real duel, a real victory, and then the whole
## ending played at its authored pace (no `_process` acceleration). The recording
## stops on the digital gate's white-out, before the scene switch starts loading
## the second floor.
##
## The first ~2.5 seconds are the district generation and the Matrix hand-off into
## the duel; trim them if the clip should open on the collapse.

const FLOOR_SCENE := "res://floor_one.tscn"
const TEST_SEED := 7331
const MAX_WAIT_FRAMES := 900

var _floor: Node
var _ending: Node
var _started := false
var _frames := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var packed: PackedScene = load(FLOOR_SCENE)
	_floor = packed.instantiate()
	root.add_child(_floor)
	# `_ready()` plans and builds the whole district synchronously, so the clip
	# opens on the finished first floor. These frames only let static collision
	# settle before the arena ray casts run.
	for _index in range(30):
		await _step()
	await _reach_victory()
	if not await _wait_for_ending():
		print("ENDING DID NOT START")
		quit(1)
		return
	# Let the ending run to its own end: `completed` fires once the digital gate
	# has covered the screen.
	var finished := [false]
	_ending.connect("completed", func() -> void: finished[0] = true)
	var guard := 0
	while not bool(finished[0]) and guard < 1800:
		guard += 1
		await _step()
	# A few frames of the flare held on screen close the clip.
	for _index in range(8):
		await _step()
	print("MOVIE COMPLETE frames=%d ending_frames=%d" % [_frames, guard])
	quit(0)


## Real erosion threshold, real Matrix hand-off, real lethal hit: the clip shows
## the shipped victory path. The mirror's protected entrance is skipped so the
## duel beat stays short.
func _reach_victory() -> void:
	var erosion: Node = _floor.get("erosion")
	erosion.call("reset", 99)
	erosion.call("set_combat_active", false)
	erosion.call("process_activity", 1.0, true, false)
	for _index in range(MAX_WAIT_FRAMES):
		if bool(_floor.get("_boss_active")):
			break
		await _step()
	var boss: Node = _floor.get("boss_target")
	if not is_instance_valid(boss):
		print("BOSS NEVER SPAWNED")
		return
	boss.set("entrance_time_left", 0.0)
	boss.set("is_entering", false)
	# A beat with the mirror still standing, then the kill.
	for _index in range(36):
		await _step()
	boss.call("take_damage", 99999.0, true)


func _wait_for_ending() -> bool:
	for _index in range(120):
		_ending = _floor.get("ending")
		if is_instance_valid(_ending):
			_started = true
			for _delay in range(4):
				await _step()
			return true
		await _step()
	return false


func _step() -> void:
	_frames += 1
	await process_frame
