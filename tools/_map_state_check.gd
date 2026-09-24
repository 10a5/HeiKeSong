extends SceneTree
## Throwaway verification: the sentry's city-map dot across its three states —
## concealed (no dot), exposed by a hit (red), defeated (cyan cleared dot).

const MAP_RECT := Rect2(204.0, 88.0, 354.0, 354.0)
const DANGER := Color("ff797e")
const TEAL := Color("74f3d1")
const OUTPUT_DIR := "res://_visual_check"

var _floor: Node
var _overlay: Control
var _city_map: Node
var _sniper: Node
var _encounter: Node
var _pixel := Vector2.ZERO


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	var packed: PackedScene = load("res://floor_one.tscn")
	_floor = packed.instantiate()
	root.add_child(_floor)
	for _index in range(90):
		await process_frame
	_overlay = _floor.get("city_overlay")
	_city_map = _floor.get("city_map")
	if not _find_sentry():
		print("NO SENTRY IN THIS SEED")
		quit(0)
		return
	var bounds: Rect2 = (_city_map.get("shallow_rect") as Rect2).grow(3.0)
	var at: Vector3 = _encounter.global_position
	_pixel = (root.get_final_transform() * (_overlay.call("_world_point", Vector2(at.x, at.z), MAP_RECT, bounds) as Vector2)) as Vector2
	print("sentry map pixel %s" % str(_pixel))

	await _stage("concealed")
	# One hit is the reveal trigger. Damage is rejected while the map pauses the
	# tree, so the hit happens with the map closed.
	_sniper.call("take_damage", 10.0)
	for _index in range(8):
		await process_frame
	await _stage("exposed-by-hit")
	_sniper.call("take_damage", 1000.0)
	for _index in range(8):
		await process_frame
	await _stage("defeated")
	quit(0)


## Open the map, capture and probe, then close it so the next hit is accepted.
## Clearing an encounter opens the reward modal, which also plays the Matrix
## transition, so that has to be dismissed first or it covers the map.
func _stage(stage: String) -> void:
	var reward = _floor.get("reward_flow")
	var hud = _floor.get("hud")
	if is_instance_valid(reward) and bool(reward.call("is_open")):
		reward.call("skip")
	for _index in range(240):
		var busy := is_instance_valid(reward) and bool(reward.call("is_open"))
		busy = busy or bool(hud.call("is_matrix_transition_playing"))
		if not busy:
			break
		await process_frame
	_floor.call("toggle_city_map")
	for _index in range(5):
		await process_frame
	await _report(stage)
	_floor.call("close_city_map")
	for _index in range(2):
		await process_frame


func _find_sentry() -> bool:
	for encounter in (_floor.get("encounters") as Array):
		var foe: Node = encounter.get("foe")
		if String(foe.get_variant_kind()) == "sniper":
			_sniper = foe
			_encounter = encounter
			return true
	return false


func _report(stage: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png("%s/map_%s.png" % [OUTPUT_DIR, stage])
	var color: Color = _overlay.call("encounter_map_color", _encounter)
	var probe := _probe(image, _pixel)
	print("%-16s shows_on_map=%-5s dot_color=%s alpha=%.2f  pixel: danger=%s teal=%s closest=%s" % [
		stage, str(_encounter.call("shows_on_city_map")), color.to_html(false), color.a,
		str(probe["is_danger"]), str(probe["is_teal"]), probe["closest"]])


func _probe(image: Image, pixel: Vector2) -> Dictionary:
	var best := 99.0
	var best_color := Color.BLACK
	var is_danger := false
	var is_teal := false
	for dy in range(-7, 8):
		for dx in range(-7, 8):
			var x := int(round(pixel.x)) + dx
			var y := int(round(pixel.y)) + dy
			if x < 0 or y < 0 or x >= image.get_width() or y >= image.get_height():
				continue
			var color := image.get_pixel(x, y)
			var distance := absf(color.r - DANGER.r) + absf(color.g - DANGER.g) + absf(color.b - DANGER.b)
			if distance < best:
				best = distance
				best_color = color
			if absf(color.r - DANGER.r) < 0.10 and absf(color.g - DANGER.g) < 0.10 and absf(color.b - DANGER.b) < 0.10:
				is_danger = true
			if absf(color.r - TEAL.r) < 0.10 and absf(color.g - TEAL.g) < 0.10 and absf(color.b - TEAL.b) < 0.10:
				is_teal = true
	return {"is_danger": is_danger, "is_teal": is_teal, "closest": best_color.to_html(false)}
