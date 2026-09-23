extends RefCounted
func build() -> Dictionary:
 var source=load("res://scenes/GrayboxBridgeRoadPreview.tscn").instantiate()
 source.name="ActualBuildingBridgePreview"
 source.set_script(load("res://tools/actual_building_controls.gd"))
 var old=source.get_node("Generated")
 source.remove_child(old)
 old.free()
 var generator=load("res://tools/actual_bridge_geometry.gd").new()
 var generated=generator.create(20260923)
 source.add_child(generated)
 generator.decorate(generated)
 var camera=source.get_node("OverviewCamera")
 camera.position=Vector3(0,110,80)
 camera.basis=Basis.looking_at(Vector3(0,6,0)-camera.position)
 generator.owns(source,source)
 var packed=PackedScene.new()
 var error=packed.pack(source)
 if error==OK:
  error=ResourceSaver.save(packed,"res://scenes/ActualBuildingBridgePreview.tscn")
 var result={"saved":error==OK,"buildings":generated.get_node("ActualBuildings").get_child_count(),"links":generated.get_node("Bridges").get_child_count()}
 source.free()
 return result
