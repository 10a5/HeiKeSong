@tool
extends EditorScenePostImport
## The GLB stores the facade color in vertices rather than texture images.


func _post_import(scene: Node) -> Object:
	_restore_vertex_colors(scene)
	return scene


func _restore_vertex_colors(node: Node) -> void:
	if node is MeshInstance3D and node.mesh != null:
		for surface in range(node.mesh.get_surface_count()):
			if node.mesh.surface_get_format(surface) & Mesh.ARRAY_FORMAT_COLOR:
				var material: Material = node.mesh.surface_get_material(surface)
				if material is BaseMaterial3D:
					material.vertex_color_use_as_albedo = true
	for child in node.get_children():
		_restore_vertex_colors(child)
