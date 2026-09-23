extends SceneTree
## Godot --headless --path . --fixed-fps 60 --script tests/test_enemy_cloak.gd
## Regression checks for the optical cloak used by the boxer and sniper.
## The test drives the visibility progress directly so the three visual phases
## can be checked without waiting for the combat state machine.

const VARIANT_SCRIPT = preload("res://enemy_variant.gd")

var world: Node3D
var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _test_variant(&"boxer")
	await _test_variant(&"sniper")
	await _test_instance_isolation()
	await _test_authored_material_restoration()
	if is_instance_valid(world):
		world.queue_free()
		await process_frame
	print("ENEMY CLOAK RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_variant(kind: StringName) -> void:
	var foe := await _new_enemy(kind)
	var visual: Node3D = foe.get("_variant_visual") as Node3D
	var cloak: ShaderMaterial = foe.get("_cloak_material") as ShaderMaterial
	var records: Array = foe.get("_cloak_records") as Array
	_check(is_instance_valid(visual), "%s has an imported visual root" % kind)
	_check(is_instance_valid(cloak), "%s creates a dedicated cloak shader material" % kind)
	_check(not records.is_empty(), "%s records every imported geometry surface" % kind)
	if records.is_empty() or cloak == null:
		return

	# Phase 0: no scan, no body, no shadow or helper can disclose the enemy.
	_force_visibility(foe, 0.0)
	_check(not visual.visible, "%s is completely hidden at visibility 0" % kind)
	_check(not _helper_visible(foe, "_health_label"), "%s hides its health label while cloaked" % kind)
	_check(_all_shadows_off(records), "%s casts no body shadow while cloaked" % kind)
	_check(_near_shader_fade(cloak, 0.0), "%s cloak shader is fully transparent at visibility 0" % kind)

	# Phase 1: the building-like hologram is the only rendered body and its
	# travelling shader has started to form.
	_force_visibility(foe, 0.20)
	_check(visual.visible, "%s visual root is enabled during reveal" % kind)
	_check(_all_use_material(records, cloak), "%s uses the hologram material during the first reveal phase" % kind)
	_check(_shader_fade(cloak) > 0.0, "%s scan shader fades in from zero" % kind)
	_check(_shader_fade(cloak) <= 1.0, "%s scan shader fade stays bounded" % kind)
	_check(not _helper_visible(foe, "_health_label"), "%s keeps the health label hidden during the hologram phase" % kind)

	# Phase 2: the hologram and textured character cross-fade. The original
	# surface materials remain independent copies and are partially transparent.
	_force_visibility(foe, 0.70)
	_check(_all_have_overlay(records), "%s keeps a hologram overlay during textured cross-fade" % kind)
	_check(_all_crossfade_overlays_replaced(records), "%s does not leak the original material overlay during cross-fade" % kind)
	_check(_shader_fade(cloak) < 1.0, "%s hologram overlay fades while the body appears" % kind)
	_check(_all_surface_materials_partial(records), "%s fades every textured surface during cross-fade" % kind)
	_check(_surface_texture_refs_preserved(records), "%s keeps each original surface texture while fading" % kind)
	_check(_all_shadows_off(records), "%s keeps body shadows disabled until fully restored" % kind)
	_check(not _helper_visible(foe, "_health_label"), "%s keeps helpers hidden until the body is fully restored" % kind)

	# Phase 3: the imported material objects and surface overrides are exactly
	# restored, proving that shared GLB resources were not permanently edited.
	_force_visibility(foe, 1.0)
	_check(visual.visible, "%s visual root is visible at full visibility" % kind)
	_check(_all_original_materials(records), "%s restores original overrides and overlays" % kind)
	_check(_all_original_surfaces(records), "%s restores original surface overrides" % kind)
	_check(_all_shadows_original(records), "%s restores original shadow settings" % kind)
	_check(_helper_visible(foe, "_health_label"), "%s shows its health label after reveal" % kind)

	# Reverse direction is also exercised because snipers hide again after firing.
	_force_visibility(foe, 0.35)
	_check(_shader_fade(cloak) > 0.0, "%s re-enters the hologram phase when visibility reverses" % kind)
	_force_visibility(foe, 0.0)
	_check(not visual.visible and not _helper_visible(foe, "_health_label"), "%s can fully re-cloak after being visible" % kind)

	# reset_enemy is expected to apply its initial cloak immediately, without
	# requiring a physics frame.
	_force_visibility(foe, 1.0)
	foe.reset_enemy()
	_check(foe.is_optically_hidden(), "%s reset restores its initial hidden state" % kind)
	_check(not visual.visible, "%s reset immediately hides its visual root" % kind)


func _test_instance_isolation() -> void:
	if is_instance_valid(world):
		world.queue_free()
		await process_frame
	world = Node3D.new()
	world.name = "EnemyCloakIsolationWorld"
	root.add_child(world)
	var first := VARIANT_SCRIPT.new()
	first.name = "BoxerCloakOne"
	first.variant = &"boxer"
	world.add_child(first)
	var second := VARIANT_SCRIPT.new()
	second.name = "BoxerCloakTwo"
	second.variant = &"boxer"
	world.add_child(second)
	await process_frame
	first.set_physics_process(false)
	second.set_physics_process(false)
	var first_shader: ShaderMaterial = first.get("_cloak_material") as ShaderMaterial
	var second_shader: ShaderMaterial = second.get("_cloak_material") as ShaderMaterial
	var first_records: Array = first.get("_cloak_records") as Array
	var second_records: Array = second.get("_cloak_records") as Array
	_check(first_shader != second_shader, "Each enemy owns an isolated cloak material")
	_force_visibility(first, 0.2)
	_force_visibility(second, 1.0)
	_check(_shader_fade(first_shader) > 0.0 and _near_shader_fade(second_shader, 0.0), "Changing one enemy cloak does not change the other")
	_check(_all_original_materials(second_records), "The second enemy remains fully textured after the first fades")
	_check(not first_records.is_empty() and not second_records.is_empty(), "Both enemies retain independent cloak records")
	# The original GLB material references are allowed to be shared; only the
	# fade copies and overlays must be unique per enemy.
	var independent_materials := not first_records.is_empty() and first_records.size() == second_records.size()
	for record_index in range(mini(first_records.size(), second_records.size())):
		var first_fades: Array = first_records[record_index].get("fade_materials", []) as Array
		var second_fades: Array = second_records[record_index].get("fade_materials", []) as Array
		independent_materials = independent_materials and not first_fades.is_empty() and first_fades.size() == second_fades.size()
		for surface_index in range(mini(first_fades.size(), second_fades.size())):
			independent_materials = independent_materials and first_fades[surface_index] != second_fades[surface_index]
	_check(independent_materials, "All per-surface fade materials are isolated between enemies")


func _test_authored_material_restoration() -> void:
	var foe := await _new_enemy(&"boxer")
	_force_visibility(foe, 1.0)
	var visual: Node3D = foe.get("_variant_visual") as Node3D
	var fixture := MeshInstance3D.new()
	fixture.name = "AuthoredCloakMaterialFixture"
	fixture.mesh = BoxMesh.new()
	var texture := GradientTexture1D.new()
	texture.gradient = Gradient.new()
	var mesh_material := StandardMaterial3D.new()
	mesh_material.albedo_texture = texture
	(fixture.mesh as BoxMesh).material = mesh_material
	var surface_override := StandardMaterial3D.new()
	surface_override.albedo_color = Color(0.9, 0.3, 0.2, 0.8)
	surface_override.albedo_texture = texture
	fixture.set_surface_override_material(0, surface_override)
	var authored_override := StandardMaterial3D.new()
	authored_override.albedo_color = Color(0.3, 0.9, 0.2, 0.65)
	authored_override.albedo_texture = texture
	fixture.material_override = authored_override
	var authored_overlay := StandardMaterial3D.new()
	authored_overlay.albedo_color = Color(0.4, 0.1, 1.0, 0.35)
	fixture.material_overlay = authored_overlay
	fixture.transparency = 0.15
	fixture.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	visual.add_child(fixture)
	foe.call("_setup_cloak_material")
	var cloak: ShaderMaterial = foe.get("_cloak_material") as ShaderMaterial
	var records: Array = foe.get("_cloak_records") as Array
	var fixture_record: Dictionary = {}
	for record: Dictionary in records:
		if record.get("node") == fixture:
			fixture_record = record
	_check(not fixture_record.is_empty(), "Authored material fixture is included in cloak records")
	if fixture_record.is_empty():
		return
	_force_visibility(foe, 0.2)
	_check(fixture.material_override == cloak and fixture.material_overlay != authored_overlay, "Pure ghost replaces authored override and suppresses its old overlay")
	_force_visibility(foe, 0.7)
	var faded := fixture.get_active_material(0) as BaseMaterial3D
	_check(fixture.material_override == null and fixture.material_overlay == cloak, "Cross-fade clears authored override so faded surface materials are active")
	_check(is_instance_valid(faded) and faded != authored_override and faded.albedo_color.a > 0.0 and faded.albedo_color.a < authored_override.albedo_color.a, "Authored override is copied and fades without mutating its original alpha")
	_check(is_instance_valid(faded) and faded.albedo_texture == authored_override.albedo_texture, "Authored override texture survives on the active fading surface")
	_check(is_equal_approx(authored_override.albedo_color.a, 0.65) and is_equal_approx(surface_override.albedo_color.a, 0.8), "Original override and surface material alpha stay unchanged")
	_force_visibility(foe, 1.0)
	_check(fixture.material_override == authored_override and fixture.material_overlay == authored_overlay, "Full reveal restores exact authored override and overlay objects")
	_check(fixture.get_surface_override_material(0) == surface_override, "Full reveal restores exact authored surface override")
	_check(is_equal_approx(fixture.transparency, 0.15) and fixture.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED, "Full reveal restores authored transparency and shadow settings")


func _new_enemy(kind: StringName) -> Node:
	if is_instance_valid(world):
		world.queue_free()
		await process_frame
	world = Node3D.new()
	world.name = "EnemyCloakWorld"
	root.add_child(world)
	var foe := VARIANT_SCRIPT.new()
	foe.name = "CloakTest_%s" % String(kind)
	foe.variant = kind
	world.add_child(foe)
	await process_frame
	foe.set_physics_process(false)
	return foe


func _force_visibility(foe: Node, amount: float) -> void:
	foe.set("_visibility_alpha", amount)
	foe.set("_visibility_target", amount)
	foe.call("_apply_visibility")


func _helper_visible(foe: Node, property_name: String) -> bool:
	var helper := foe.get(property_name) as Node3D
	return is_instance_valid(helper) and helper.visible


func _all_use_material(records: Array, material: Material) -> bool:
	for record: Dictionary in records:
		var node := record.get("node") as GeometryInstance3D
		if not is_instance_valid(node) or node.material_override != material:
			return false
	return true


func _all_have_overlay(records: Array) -> bool:
	for record: Dictionary in records:
		var node := record.get("node") as GeometryInstance3D
		if not is_instance_valid(node):
			return false
		if node.material_overlay == null:
			return false
	return not records.is_empty()


func _all_crossfade_overlays_replaced(records: Array) -> bool:
	for record: Dictionary in records:
		var node := record.get("node") as GeometryInstance3D
		if not is_instance_valid(node):
			return false
		var original_overlay: Material = record.get("overlay") as Material
		if original_overlay != null and node.material_overlay == original_overlay:
			return false
	return true


func _all_surface_materials_partial(records: Array) -> bool:
	var checked := 0
	for record: Dictionary in records:
		var node := record.get("node") as GeometryInstance3D
		if not is_instance_valid(node):
			return false
		var fade_materials: Array = record.get("fade_materials", []) as Array
		for fade_material in fade_materials:
			var base := fade_material as BaseMaterial3D
			if not is_instance_valid(base):
				continue
			checked += 1
			var alpha := base.albedo_color.a
			if alpha <= 0.01 or alpha >= 0.99:
				return false
		if fade_materials.is_empty() and node.transparency > 0.01 and node.transparency < 0.99:
			checked += 1
			continue
	return checked > 0


func _has_partial_body_alpha(records: Array) -> bool:
	for record: Dictionary in records:
		var node := record.get("node") as GeometryInstance3D
		if is_instance_valid(node) and node.transparency > 0.01 and node.transparency < 0.99:
			return true
		# Implementations may keep GeometryInstance3D opaque and instead fade
		# independent StandardMaterial3D copies per imported surface. Accept that
		# representation too; it is the reason records expose fade_materials.
		for fade_material in (record.get("fade_materials", []) as Array):
			var base := fade_material as BaseMaterial3D
			if is_instance_valid(base) and base.albedo_color.a > 0.01 and base.albedo_color.a < 0.99:
				return true
	return false


func _surface_texture_refs_preserved(records: Array) -> bool:
	var checked := 0
	for record: Dictionary in records:
		var node := record.get("node") as GeometryInstance3D
		var surfaces: Array = record.get("surfaces", []) as Array
		var fade_materials: Array = record.get("fade_materials", []) as Array
		var mesh := node as MeshInstance3D
		for entry in surfaces:
			var original: Material
			var index := -1
			if entry is Dictionary:
				original = entry.get("material") as Material
				index = int(entry.get("index", -1))
			else:
				original = entry as Material
				index = surfaces.find(entry)
			# An imported GLB normally has no authored surface override. In that
			# case get_active_material() captured the source material, while the
			# `surfaces` record intentionally stores a null override for exact
			# restoration. Read the mesh surface material for texture validation.
			if original == null and is_instance_valid(mesh) and index >= 0 and index < mesh.mesh.get_surface_count():
				original = mesh.mesh.surface_get_material(index)
			if index < 0 or index >= fade_materials.size():
				continue
			var faded := fade_materials[index] as BaseMaterial3D
			var source := original as BaseMaterial3D
			if not is_instance_valid(faded) or not is_instance_valid(source):
				continue
			var source_standard := source as StandardMaterial3D
			var faded_standard := faded as StandardMaterial3D
			if source_standard != null and faded_standard != null and source_standard.albedo_texture != null:
				checked += 1
				if faded_standard.albedo_texture != source_standard.albedo_texture:
					return false
	return checked > 0 or records.is_empty()


func _all_original_materials(records: Array) -> bool:
	for record: Dictionary in records:
		var node := record.get("node") as GeometryInstance3D
		if not is_instance_valid(node):
			return false
		if node.material_override != record.get("material"):
			return false
		if node.material_overlay != record.get("overlay"):
			return false
		if not is_equal_approx(node.transparency, float(record.get("transparency", 0.0))):
			return false
	return true


func _all_original_surfaces(records: Array) -> bool:
	for record: Dictionary in records:
		var node := record.get("node") as GeometryInstance3D
		var surfaces: Array = record.get("surfaces", []) as Array
		if not is_instance_valid(node):
			return false
		for entry in surfaces:
			var index := -1
			var material: Material
			if entry is Dictionary:
				index = int(entry.get("index", -1))
				material = entry.get("material") as Material
			else:
				index = surfaces.find(entry)
				material = entry as Material
			if index >= 0 and node.get_surface_override_material(index) != material:
				return false
	return true


func _all_shadows_off(records: Array) -> bool:
	for record: Dictionary in records:
		var node := record.get("node") as GeometryInstance3D
		if is_instance_valid(node) and node.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			return false
	return true


func _all_shadows_original(records: Array) -> bool:
	for record: Dictionary in records:
		var node := record.get("node") as GeometryInstance3D
		if is_instance_valid(node) and node.cast_shadow != record.get("cast_shadow"):
			return false
	return true


func _shader_fade(material: ShaderMaterial) -> float:
	return float(material.get_shader_parameter("fade"))


func _near_shader_fade(material: ShaderMaterial, expected: float) -> bool:
	return absf(_shader_fade(material) - expected) < 0.03


func _check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		push_error("FAIL: " + description)
