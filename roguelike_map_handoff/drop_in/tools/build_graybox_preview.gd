extends RefCounted
func build(seed_value: int=20260923) -> Dictionary:
 var generator=load("res://tools/graybox_geometry.gd").new()
 var root=Node3D.new()
 root.name="GrayboxBridgeRoadPreview"
 root.set_script(load("res://tools/graybox_preview_controls.gd"))
 root.set_meta("seed",seed_value)
 var generated=generator.create(seed_value)
 root.add_child(generated)
 var world=WorldEnvironment.new()
 world.name="WorldEnvironment"
 var env=Environment.new()
 env.background_mode=Environment.BG_COLOR
 env.background_color=Color(0.035,0.045,0.065)
 env.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
 env.ambient_light_color=Color(0.75,0.8,0.9)
 env.ambient_light_energy=0.8
 world.environment=env
 root.add_child(world)
 var light=DirectionalLight3D.new()
 light.name="Key"
 light.rotation_degrees=Vector3(-60,-25,0)
 light.light_energy=1.3
 light.shadow_enabled=true
 root.add_child(light)
 var cam=Camera3D.new()
 cam.name="OverviewCamera"
 cam.position=Vector3(0,101,72)
 cam.basis=Basis.looking_at(Vector3(0,3,0)-cam.position)
 cam.current=true
 cam.fov=58
 cam.far=400
 root.add_child(cam)
 generator.owns(root,root)
 var packed=PackedScene.new()
 var error=packed.pack(root)
 if error==OK:
  error=ResourceSaver.save(packed,"res://scenes/GrayboxBridgeRoadPreview.tscn")
 var result={"saved":error==OK,"seed":seed_value,"bridges":generated.get_meta("bridge_count"),"junctions":generated.get_meta("junction_count")}
 root.free()
 return result
