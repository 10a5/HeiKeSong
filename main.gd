extends Node3D
## The 3D test chamber, camera rig, and input routing.
## Primitive meshes are intentional greybox assets: no external models required.

const HUD_SCRIPT = preload("res://hud.gd")
const DECK_SCRIPT = preload("res://deck.gd")
const IMPLANT_INVENTORY = preload("res://implant_inventory.gd")
const ENEMY_SCRIPT = preload("res://enemy.gd")
const BOSS_BRAIN_SCRIPT = preload("res://boss_brain.gd")
const UNLOCK_TERMINAL_SCRIPT = preload("res://unlock_terminal.gd")
const SHOP_SYSTEM = preload("res://shop_system.gd")
const SHOP_PANEL = preload("res://shop_panel.gd")
const REWARD_FLOW = preload("res://reward_flow.gd")
const DEFAULT_YAW := 0.42
const DEFAULT_PITCH := 0.74
const DEFAULT_DISTANCE := 18.0
const CAMERA_MIN_PITCH := 0.03
const CAMERA_MAX_PITCH := 1.53
const CAMERA_MIN_DISTANCE := 4.0
const CAMERA_MAX_DISTANCE := 85.0

@onready var player: CharacterBody3D = $Player
var hud: Control
var deck: Node
var shop_system: Node
var shop_panel: Control
var reward_flow: Node
var inventory: Node
var enemy: CharacterBody3D
## The adaptive brain is telemetry + bounded planning only. A future final boss
## can consume its reaction_requested signal without putting an LLM in combat.
var boss_brain: Node
var unlock_terminals: Array = []
var camera: Camera3D
var paused := false
var camera_yaw := DEFAULT_YAW
var camera_pitch := DEFAULT_PITCH
var camera_distance := DEFAULT_DISTANCE
var _camera_target := Vector3.ZERO
var _orbiting := false
var _paused_before_browser := false
var _materials: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_create_materials()
	_create_environment()
	_create_chamber()
	enemy = ENEMY_SCRIPT.new()
	enemy.name = "TrainingEnemy"
	add_child(enemy)
	enemy.setup(player)
	enemy.defeated.connect(_on_enemy_defeated, CONNECT_DEFERRED)
	_create_camera()
	deck = Node.new()
	deck.name = "Deck"
	deck.set_script(DECK_SCRIPT)
	add_child(deck)
	deck.setup(player)
	inventory = IMPLANT_INVENTORY.new()
	inventory.name = "ImplantInventory"
	add_child(inventory)
	inventory.setup(player, deck)
	_create_unlock_terminals()
	var canvas := CanvasLayer.new()
	canvas.name = "HUD"
	add_child(canvas)
	hud = Control.new()
	hud.set_script(HUD_SCRIPT)
	hud.name = "Interface"
	canvas.add_child(hud)
	hud.setup(player, deck)
	hud.set_implant_inventory(inventory)
	hud.card_requested.connect(_on_card_requested)
	hud.reset_requested.connect(restart)
	hud.pause_requested.connect(toggle_pause)
	hud.browser_requested.connect(open_card_browser)
	hud.browser_close_requested.connect(close_card_browser)
	_setup_shop_system(canvas)
	_setup_reward_flow(canvas)
	_setup_adaptive_brain()
	player.movement_yaw = camera_yaw


func _physics_process(_delta: float) -> void:
	if paused or player.is_dead:
		return
	if Input.is_action_just_pressed("cybernetic_boost"):
		player.activate_cybernetic()
	# Numbers refer to hand positions, never directly to an action type.
	for slot in range(deck.hand_size):
		if Input.is_action_just_pressed("hand_%d" % (slot + 1)):
			deck.play_slot(slot)
			break
	if Input.is_action_just_pressed("jump"):
		player.request_jump()
	if Input.is_action_just_pressed("interact"):
		try_interact()


func _process(delta: float) -> void:
	if paused:
		return
	player.movement_yaw = camera_yaw
	_camera_target = _camera_target.lerp(player.global_position + Vector3(0, 0.65, 0), 1.0 - exp(-10.0 * delta))
	_update_camera()


func _input(event: InputEvent) -> void:
	if is_instance_valid(reward_flow) and reward_flow.is_open():
		if event is InputEventKey:
			if event.pressed and not event.echo:
				if event.keycode == KEY_ESCAPE:
					reward_flow.skip()
				elif event.keycode == KEY_R:
					restart()
				elif event.keycode == KEY_N:
					if has_method("regenerate_floor"):
						call("regenerate_floor")
					else:
						restart()
			get_viewport().set_input_as_handled()
		elif reward_flow.is_transitioning():
			# Keep the choice under the numeric rain until the reveal finishes;
			# after that, let RewardPanel's buttons receive mouse input normally.
			get_viewport().set_input_as_handled()
			return
		return
	if is_instance_valid(shop_system) and shop_system.is_open():
		if shop_system.is_transitioning() and (event is InputEventMouse or event is InputEventGesture or event is InputEventScreenTouch or event is InputEventScreenDrag):
			get_viewport().set_input_as_handled()
			return
		if event is InputEventKey:
			if event.pressed and not event.echo:
				if event.keycode in [KEY_ESCAPE, KEY_I]:
					shop_system.close()
				elif event.keycode == KEY_R:
					restart()
			get_viewport().set_input_as_handled()
		return
	# Handle modal shortcuts before focused GUI buttons can consume Escape/Tab.
	if not is_instance_valid(hud) or not hud.is_browser_open():
		return
	if event is InputEventKey:
		if event.pressed and not event.echo:
			if event.keycode == KEY_ESCAPE or event.keycode == KEY_TAB:
				close_card_browser()
			elif event.keycode == KEY_R:
				restart()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if is_instance_valid(reward_flow) and reward_flow.is_open():
		get_viewport().set_input_as_handled()
		return
	if is_instance_valid(shop_system) and shop_system.is_open():
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			restart()
			get_viewport().set_input_as_handled()
			return
		elif event.keycode == KEY_I:
			shop_system.open_inventory()
			get_viewport().set_input_as_handled()
			return
		elif event.keycode == KEY_T:
			# Preview the transition effect in the running demo. Scene-specific
			# transitions can call play_matrix_transition() directly instead.
			play_matrix_transition()
			get_viewport().set_input_as_handled()
			return
		elif event.keycode == KEY_ESCAPE:
			toggle_pause()
			get_viewport().set_input_as_handled()
			return
		elif event.keycode == KEY_TAB:
			open_card_browser(&"all")
			get_viewport().set_input_as_handled()
			return
	if hud.is_browser_open():
		get_viewport().set_input_as_handled()
		return
	if paused:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_orbiting = event.pressed
			# HUD consumes card presses first; releases always end a scene drag.
			get_viewport().set_input_as_handled()
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_camera(-1.25)
			get_viewport().set_input_as_handled()
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_camera(1.25)
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _orbiting:
		_rotate_camera(event.relative)
		get_viewport().set_input_as_handled()
	elif event is InputEventMagnifyGesture:
		# macOS trackpad pinches are gesture events, not mouse-wheel presses.
		# Opening the fingers magnifies the scene by moving the orbit closer.
		if is_finite(event.factor) and event.factor > 0.0:
			camera_distance = clampf(camera_distance / event.factor, CAMERA_MIN_DISTANCE, CAMERA_MAX_DISTANCE)
		get_viewport().set_input_as_handled()
	elif event is InputEventPanGesture:
		# Two-finger vertical scrolling follows the mouse-wheel zoom behavior.
		_zoom_camera(event.delta.y * 1.25)
		get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_orbiting = false


func _on_card_requested(slot: int) -> void:
	if not paused and not player.is_dead:
		deck.play_slot(slot)


func try_interact() -> bool:
	if paused or player.is_dead or player.is_action_locked():
		return false
	var nearest: Node3D = null
	var nearest_distance := INF
	for terminal in unlock_terminals:
		if not terminal.can_interact():
			continue
		var distance: float = player.global_position.distance_squared_to(terminal.global_position)
		if distance < nearest_distance:
			nearest = terminal
			nearest_distance = distance
	return bool(nearest.call("interact")) if nearest != null else false


func _on_enemy_defeated() -> void:
	if enemy.is_dead:
		if is_instance_valid(reward_flow):
			reward_flow.enqueue_reward("enemy", reward_flow.make_random_reward(int(Time.get_ticks_msec())))
		else:
			player.status_changed.emit("训练敌人已击败 · 按 R 再来一局", false)


func _setup_adaptive_brain() -> void:
	if is_instance_valid(boss_brain):
		return
	boss_brain = BOSS_BRAIN_SCRIPT.new()
	boss_brain.name = "AdaptiveBossBrain"
	add_child(boss_brain)
	boss_brain.attach_player(player)
	boss_brain.reaction_requested.connect(_on_adaptive_reaction)
	if is_instance_valid(enemy) and boss_brain.has_method("attach_opponent"):
		boss_brain.attach_opponent(enemy)


func _on_adaptive_reaction(reaction: StringName, payload: Dictionary) -> void:
	# Keep the current training foe deterministic. The hook is ready for the
	# future Mirror controller, which can implement apply_adaptive_reaction().
	var reaction_target: Node = enemy
	if has_method("get") and get("_boss_active") == true:
		var live_boss: Variant = get("boss_target")
		if is_instance_valid(live_boss):
			reaction_target = live_boss
	if is_instance_valid(reaction_target) and reaction_target.has_method("apply_adaptive_reaction"):
		reaction_target.apply_adaptive_reaction(reaction, payload)


func restart() -> void:
	if is_instance_valid(reward_flow):
		reward_flow.reset()
	if is_instance_valid(shop_system):
		shop_system.reset_run()
	hud.hide_browser()
	_paused_before_browser = false
	paused = false
	get_tree().paused = false
	_orbiting = false
	camera_yaw = DEFAULT_YAW
	camera_pitch = DEFAULT_PITCH
	camera_distance = DEFAULT_DISTANCE
	player.reset_player()
	enemy.reset_enemy()
	if is_instance_valid(boss_brain):
		boss_brain.reset_observation()
		if boss_brain.has_method("attach_opponent"):
			boss_brain.attach_opponent(enemy)
	inventory.reset_inventory()
	deck.clear_purchased_cards()
	deck.reset_deck()
	for terminal in unlock_terminals:
		terminal.refresh_state()
	player.movement_yaw = camera_yaw
	_camera_target = player.global_position + Vector3(0, 0.65, 0)
	_update_camera()
	hud.setup(player, deck)
	hud.set_paused(false)


func toggle_pause() -> void:
	if is_instance_valid(reward_flow) and reward_flow.is_open():
		reward_flow.skip()
		return
	if is_instance_valid(shop_system) and shop_system.is_open():
		shop_system.close()
		return
	if hud.is_browser_open():
		close_card_browser()
		return
	paused = not paused
	get_tree().paused = paused
	_orbiting = false
	hud.set_paused(paused)


func open_card_browser(view: StringName = &"all") -> void:
	if is_instance_valid(reward_flow) and reward_flow.is_open():
		return
	if is_instance_valid(shop_system) and shop_system.is_open():
		return
	if view not in [&"all", &"draw", &"discard", &"catalog"]:
		return
	if not hud.is_browser_open():
		_paused_before_browser = paused
	paused = true
	get_tree().paused = true
	_orbiting = false
	hud.set_paused(true)
	hud.show_browser(view)


func close_card_browser() -> void:
	if not hud.is_browser_open():
		return
	hud.hide_browser()
	paused = _paused_before_browser
	get_tree().paused = paused
	_orbiting = false
	hud.set_paused(paused)


## Play the reusable full-screen Matrix-style transition through the HUD.
func play_matrix_transition(
	fade_in_duration: float = 0.24,
	hold_duration: float = 0.85,
	fade_out_duration: float = 0.34
) -> void:
	if is_instance_valid(hud) and hud.has_method("play_matrix_transition"):
		hud.play_matrix_transition(fade_in_duration, hold_duration, fade_out_duration)


func stop_matrix_transition() -> void:
	if is_instance_valid(hud) and hud.has_method("stop_matrix_transition"):
		hud.stop_matrix_transition()


func _setup_shop_system(canvas: CanvasLayer) -> void:
	shop_panel = SHOP_PANEL.new()
	shop_panel.name = "ShopPanel"
	canvas.add_child(shop_panel)
	shop_system = SHOP_SYSTEM.new()
	shop_system.name = "ShopSystem"
	add_child(shop_system)
	shop_system.setup(self, shop_panel, inventory, deck)
	hud.implants_requested.connect(shop_system.open_inventory)


func _setup_reward_flow(canvas: CanvasLayer) -> void:
	if is_instance_valid(reward_flow):
		reward_flow.queue_free()
	reward_flow = REWARD_FLOW.new()
	reward_flow.name = "RewardFlow"
	add_child(reward_flow)
	reward_flow.setup(self, canvas, hud, deck, inventory)


func open_reward(source: String, reward: Dictionary) -> bool:
	return is_instance_valid(reward_flow) and bool(reward_flow.open_reward(source, reward))


func _create_camera() -> void:
	camera = Camera3D.new()
	camera.name = "OrbitCamera"
	camera.fov = 48.0
	camera.near = 0.1
	camera.far = 140.0
	camera.current = true
	add_child(camera)
	_camera_target = player.global_position + Vector3(0, 0.65, 0)
	_update_camera()


func _create_unlock_terminals() -> void:
	var station_data: Array[Dictionary] = [
		{"name": "AttackMemory", "title": "攻击记忆", "kinds": ["punch", "sweep", "shot", "charged_slash"], "preview": "快拳 · 扫腿 · 点射 · 蓄力重劈", "position": Vector3(-3.6, 0.0, 3.4), "color": Color("ffb66d")},
		{"name": "MovementMemory", "title": "位移记忆", "kinds": ["blink", "jet_jump"], "preview": "短距闪现 · 喷射跃升", "position": Vector3(-8.0, 0.0, 5.8), "color": Color("74d9ef")},
		{"name": "HybridMemory", "title": "复合记忆", "kinds": ["airborne_slash", "dive_slash"], "preview": "腾空斩 · 俯冲重斩", "position": Vector3(3.6, 0.0, 3.4), "color": Color("cba4ff")},
	]
	for data in station_data:
		var terminal := UNLOCK_TERMINAL_SCRIPT.new()
		terminal.name = data["name"]
		terminal.position = data["position"]
		add_child(terminal)
		terminal.setup(player, deck, data["title"], data["kinds"], data["preview"], data["color"])
		unlock_terminals.append(terminal)


func _update_camera() -> void:
	var horizontal := cos(camera_pitch) * camera_distance
	var offset := Vector3(sin(camera_yaw) * horizontal, sin(camera_pitch) * camera_distance, cos(camera_yaw) * horizontal)
	camera.global_position = _camera_target + offset
	camera.look_at(_camera_target, Vector3.UP)


func _zoom_camera(delta: float) -> void:
	camera_distance = clampf(camera_distance + delta, CAMERA_MIN_DISTANCE, CAMERA_MAX_DISTANCE)


func _rotate_camera(relative: Vector2) -> void:
	# Stop short of vertical to keep look_at and camera-relative movement stable.
	camera_yaw = wrapf(camera_yaw - relative.x * 0.006, -PI, PI)
	camera_pitch = clampf(camera_pitch + relative.y * 0.005, CAMERA_MIN_PITCH, CAMERA_MAX_PITCH)
	player.movement_yaw = camera_yaw


func _create_materials() -> void:
	_materials["base"] = _material(Color("253641"))
	_materials["tile_a"] = _material(Color("5b6c76"))
	_materials["tile_b"] = _material(Color("60717b"))
	_materials["rail"] = _material(Color("94a5ad"))
	_materials["concrete"] = _material(Color("c4cdd0"))
	_materials["dark"] = _material(Color("34464f"))
	_materials["teal"] = _material(Color("78ded0"), true)
	_materials["orange"] = _material(Color("edb270"))
	_materials["ground"] = _material(Color("152530"))
	_materials["marking"] = _material(Color("82979e"))


func _material(color: Color, luminous := false) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.85
	if luminous:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = 0.55
	return mat


func _create_environment() -> void:
	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("20323f")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("c8dcef")
	env.ambient_light_energy = 0.55
	world.environment = env
	add_child(world)
	var sun := DirectionalLight3D.new()
	sun.name = "KeyLight"
	sun.rotation_degrees = Vector3(-53, -34, 0)
	sun.light_color = Color("fff2df")
	sun.light_energy = 0.85
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 50.0
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.name = "FillLight"
	fill.rotation_degrees = Vector3(-34, 140, 0)
	fill.light_color = Color("9fc8ec")
	fill.light_energy = 0.20
	add_child(fill)


func _create_chamber() -> void:
	var chamber := Node3D.new()
	chamber.name = "GreyboxChamber"
	add_child(chamber)
	_box(chamber, "SurroundingGround", Vector3(160, 0.1, 160), Vector3(0, -1.02, 0), "ground")
	_box(chamber, "Foundation", Vector3(21.4, 0.75, 17.4), Vector3(0, -0.48, 0), "base")
	# One continuous collider avoids tile seams affecting movement.
	_box(chamber, "Floor", Vector3(20, 0.4, 16), Vector3(0, -0.2, 0), "dark", true)
	for x in range(10):
		for z in range(8):
			var tile_position := Vector3(-9.0 + x * 2.0, 0.0, -7.0 + z * 2.0)
			_box(chamber, "Tile_%d_%d" % [x, z], Vector3(1.965, 0.014, 1.965), tile_position, "tile_a" if (x + z) % 2 == 0 else "tile_b")

	# Solid low walls let the camera see the actor from every angle.
	_box(chamber, "WestWall", Vector3(0.4, 0.48, 16.8), Vector3(-10.2, 0.24, 0), "rail", true)
	_box(chamber, "EastWall", Vector3(0.4, 0.48, 16.8), Vector3(10.2, 0.24, 0), "rail", true)
	_box(chamber, "NorthWall", Vector3(20, 0.48, 0.4), Vector3(0, 0.24, -8.2), "rail", true)
	_box(chamber, "SouthWall", Vector3(20, 0.48, 0.4), Vector3(0, 0.24, 8.2), "rail", true)
	for x in [-10.2, 10.2]:
		_box(chamber, "SideLight", Vector3(0.07, 0.015, 15.8), Vector3(x, 0.487, 0), "teal")
	for z in [-8.2, 8.2]:
		_box(chamber, "EndLight", Vector3(19.4, 0.015, 0.07), Vector3(0, 0.487, z), "teal")
	for x in [-9.75, 9.75]:
		for z in [-7.75, 7.75]:
			_box(chamber, "CornerFoot", Vector3(0.68, 0.3, 0.68), Vector3(x, 0.15, z), "dark", true)
			_box(chamber, "CornerPost", Vector3(0.32, 1.7, 0.32), Vector3(x, 0.98, z), "concrete")
			_box(chamber, "CornerLamp", Vector3(0.36, 0.12, 0.36), Vector3(x, 1.86, z), "teal")

	# A pair of box stacks and low cylindrical bollards provide collision tests.
	_crate(chamber, Vector3(-5.6, 0, -2.7), Vector3(2.0, 1.3, 1.8))
	_crate(chamber, Vector3(-6.2, 0, 3.3), Vector3(1.5, 0.9, 1.5))
	_crate(chamber, Vector3(5.5, 0, -3.0), Vector3(1.8, 1.8, 1.8))
	_crate(chamber, Vector3(6.8, 0, 3.7), Vector3(2.8, 0.8, 1.3))
	for x in [-4.7, 4.7]:
		_cylinder(chamber, "Bollard", Vector3(x, 0.55, 5.9), 0.48, 1.1, "concrete", true)
		_cylinder(chamber, "BollardCap", Vector3(x, 1.115, 5.9), 0.49, 0.1, "orange")

	# Ground-level rings and lane markers are visual geometry, without hitboxes.
	_ring(chamber, Vector3(0, 0.026, 2), 1.3, "teal")
	_ring(chamber, Vector3(0, 0.026, 2), 1.48, "marking")
	for z in range(-6, 8, 2):
		_box(chamber, "LaneLeft", Vector3(0.04, 0.012, 0.5), Vector3(-3.0, 0.018, z), "marking")
		_box(chamber, "LaneRight", Vector3(0.04, 0.012, 0.5), Vector3(3.0, 0.018, z), "marking")
	for x in range(-8, 9, 2):
		_box(chamber, "BoundaryMark", Vector3(0.6, 0.012, 0.13), Vector3(x, 0.02, -7.4), "orange")

	# An unmistakable 3D test-range sign made from a block and a Label3D.
	_box(chamber, "SignPlinth", Vector3(4.1, 0.2, 0.55), Vector3(0, 0.1, -7.0), "dark")
	_box(chamber, "RangeSign", Vector3(3.8, 0.95, 0.18), Vector3(0, 0.7, -7.05), "base")
	var sign := Label3D.new()
	sign.name = "RangeNumber"
	sign.text = "01  /  ACTION LAB"
	sign.font_size = 44
	sign.pixel_size = 0.006
	sign.position = Vector3(0, 0.71, -6.951)
	sign.modulate = Color("bdeee6")
	sign.outline_size = 0
	chamber.add_child(sign)


func _box(parent: Node3D, node_name: String, dimensions: Vector3, location: Vector3, material_name: String, solid := false) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = dimensions
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = _materials[material_name]
	instance.position = location
	parent.add_child(instance)
	if solid:
		var body := StaticBody3D.new()
		body.name = node_name + "Collision"
		body.position = location
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = dimensions
		shape.shape = box
		body.add_child(shape)
		parent.add_child(body)
	return instance


func _crate(parent: Node3D, base: Vector3, dimensions: Vector3) -> void:
	_box(parent, "BlockObstacle", dimensions, base + Vector3(0, dimensions.y / 2.0, 0), "concrete", true)
	_box(parent, "BlockCap", Vector3(dimensions.x + 0.04, 0.09, dimensions.z + 0.04), base + Vector3(0, dimensions.y + 0.04, 0), "dark")
	for x in [-0.32, 0.32]:
		_box(parent, "SafetyStripe", Vector3(0.16, 0.1, dimensions.z + 0.05), base + Vector3(x, dimensions.y + 0.1, 0), "orange")


func _cylinder(parent: Node3D, node_name: String, location: Vector3, radius: float, height: float, material_name: String, solid := false) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 16
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.position = location
	instance.material_override = _materials[material_name]
	parent.add_child(instance)
	if solid:
		var body := StaticBody3D.new()
		body.position = location
		var collision := CollisionShape3D.new()
		var shape := CylinderShape3D.new()
		shape.radius = radius
		shape.height = height
		collision.shape = shape
		body.add_child(collision)
		parent.add_child(body)


func _ring(parent: Node3D, location: Vector3, radius: float, material_name: String) -> void:
	var mesh := TorusMesh.new()
	mesh.inner_radius = radius - 0.018
	mesh.outer_radius = radius + 0.018
	mesh.rings = 64
	mesh.ring_segments = 6
	var instance := MeshInstance3D.new()
	instance.name = "SpawnRing"
	instance.mesh = mesh
	instance.position = location
	instance.material_override = _materials[material_name]
	parent.add_child(instance)
