@tool
extends "res://addons/godot_ai/testing/test_suite.gd"

func suite_name() -> String:
 return "seven_building_bridge_map"

func collect_meshes(node: Node, parent_transform: Transform3D, out: Array) -> void:
 var t = parent_transform
 if node is Node3D:
  t = parent_transform * node.transform
 if node is MeshInstance3D and node.mesh != null:
  out.append({"mesh":node.mesh, "transform":t})
 for child in node.get_children():
  collect_meshes(child, t, out)

func mesh_bounds(instance: Node) -> AABB:
 var entries = []
 collect_meshes(instance, Transform3D.IDENTITY, entries)
 var first = true
 var bounds = AABB()
 for entry in entries:
  var mesh: Mesh = entry.mesh
  var b = entry.transform * mesh.get_aabb()
  if first:
   bounds = b
   first = false
  else:
   bounds = bounds.merge(b)
 return bounds

func add_owner_recursive(node: Node, owner: Node) -> void:
 if node != owner:
  node.owner = owner
 if node != owner and not node.scene_file_path.is_empty():
  return
 for child in node.get_children():
  add_owner_recursive(child, owner)

func brightness(instance: Node) -> float:
 var entries = []
 collect_meshes(instance, Transform3D.IDENTITY, entries)
 var total = 0.0
 var count = 0
 for entry in entries:
  for s in range(entry.mesh.get_surface_count()):
   var mat = entry.mesh.surface_get_material(s)
   if not mat is BaseMaterial3D:
    continue
   var col = mat.albedo_color
   if mat.albedo_texture != null:
    var image = mat.albedo_texture.get_image()
    if image.is_compressed():
     image.decompress()
    image.resize(24,24)
    for y in range(24):
     for x in range(24):
      var c = image.get_pixel(x,y) * col
      total += c.r*0.2126+c.g*0.7152+c.b*0.0722
      count += 1
   else:
    total += col.r*0.2126+col.g*0.7152+col.b*0.0722
    count += 1
 return total/maxi(1,count)

func triangles_for(instance: Node) -> Array:
 var entries = []
 collect_meshes(instance, Transform3D.IDENTITY, entries)
 var triangles = []
 for e in entries:
  for s in range(e.mesh.get_surface_count()):
   var arrays = e.mesh.surface_get_arrays(s)
   var verts = arrays[Mesh.ARRAY_VERTEX]
   var indices = arrays[Mesh.ARRAY_INDEX]
   if indices == null:
    continue
   for i in range(0,indices.size(),3):
    triangles.append([e.transform*verts[indices[i]],e.transform*verts[indices[i+1]],e.transform*verts[indices[i+2]]])
 return triangles

func ray_bounds(triangles: Array, y: float, z: float) -> Vector2:
 var result = Vector2(INF,-INF)
 for t in triangles:
  var hit = Geometry3D.segment_intersects_triangle(Vector3(-500,y,z),Vector3(500,y,z),t[0],t[1],t[2])
  if hit != null:
   result.x = minf(result.x,hit.x)
   result.y = maxf(result.y,hit.x)
 return result

func make_material(color: Color) -> StandardMaterial3D:
 var material = StandardMaterial3D.new()
 material.albedo_color = color
 material.roughness = 0.85
 return material

func build_map() -> int:
 var root = Node3D.new()
 root.name = "SevenBuildingBridgeMap"
 var buildings = Node3D.new()
 buildings.name = "Buildings"
 root.add_child(buildings)

 var assets = [
  {"name":"Building_01_Residential2", "path":"res://居民楼2.glb", "tone":"dark"},
  {"name":"Building_02_Shop", "path":"res://商店.glb", "tone":"bright"},
  {"name":"Building_03_Residential3", "path":"res://居民楼3.glb", "tone":"dark"},
  {"name":"Building_04_Factory1", "path":"res://工厂1.glb", "tone":"bright"},
  {"name":"Building_05_Residential4", "path":"res://居民楼4.glb", "tone":"dark"},
  {"name":"Building_06_Residential5", "path":"res://居民楼5.glb", "tone":"bright"},
  {"name":"Building_07_Residential4k", "path":"res://居民楼4k.glb", "tone":"dark"}
 ]
 for spec in assets:
  var sample = load(spec.path).instantiate()
  spec["luminance"] = brightness(sample)
  sample.free()
 assets.sort_custom(func(a,b): return a.luminance < b.luminance)
 var ordered = []
 for index in [0,6,1,5,2,4,3]:
  ordered.append(assets[index])
 assets = ordered
 var report = {"buildings":[],"bridges":[],"gap":8.0}
 var instances = []
 var gap = 8.0
 var cursor = -100.0
 for spec in assets:
  var instance = load(spec.path).instantiate()
  instance.name = "Building_%02d_%s" % [instances.size()+1,spec.path.get_file().get_basename()]
  instance.set_meta("texture_luminance",spec.luminance)
  buildings.add_child(instance)
  var raw_bounds = mesh_bounds(instance)
  var factor = 24.0 / maxf(raw_bounds.size.y, 0.001)
  instance.scale = Vector3.ONE * factor
  var width = raw_bounds.size.x * factor
  var depth = raw_bounds.size.z * factor
  instance.position = Vector3(cursor - raw_bounds.position.x * factor, -raw_bounds.position.y * factor, -raw_bounds.get_center().z * factor)
  report.buildings.append({"asset":spec.path,"luminance":spec.luminance,"min_x":cursor,"max_x":cursor+width,"height":24.0})
  instances.append({"node":instance, "width":width, "depth":depth, "bounds":raw_bounds, "factor":factor, "tone":spec.tone, "path":spec.path, "min_x":cursor, "max_x":cursor+width})
  cursor += width + gap

 var bridges = Node3D.new()
 bridges.name = "Bridges"
 root.add_child(bridges)
 var bridge_basis = Basis(Vector3(0.5245950222, 0.1574558616, -0.8366646765), Vector3(-0.2874774635, 0.9577874541, 0.0), Vector3(0.8013468385, 0.2405222207, 0.5477155447))
 var bridge_min = Vector3(-62.2091789, 12.6448936, -13.3857794)
 var bridge_size = Vector3(107.5178375, 23.4535103, 28.5057182)
 for i in range(instances.size()-1):
  var left = instances[i]
  var right = instances[i+1]
  var bridge = load("res://重置桥 .glb").instantiate()
  bridge.name = "Bridge_%02d_%02d" % [i+1, i+2]
  bridges.add_child(bridge)
  var lt = triangles_for(left.node)
  var rt = triangles_for(right.node)
  var best = INF
  var chosen = {}
  for y in [6.0,8.0,10.0,12.0,14.0]:
   for z in [-3.0,0.0,3.0]:
    var lh = ray_bounds(lt,y,z)
    var rh = ray_bounds(rt,y,z)
    if lh.y-lh.x < 4.0 or rh.y-rh.x < 4.0:
     continue
    var score = rh.x-lh.y+absf(y-8.0)*0.7+absf(z)*0.3
    if score < best:
     best = score
     chosen = {"left":lh.y,"right":rh.x,"y":y,"z":z}
  if chosen.is_empty():
   root.free()
   return ERR_INVALID_DATA
  var penetration = 2.0
  var desired_length = chosen.right-chosen.left+penetration*2.0
  var scale_factor = desired_length / bridge_size.x
  var center = bridge_min + bridge_size/2.0
  var target = Vector3((chosen.left+chosen.right)/2.0,chosen.y,chosen.z)
  bridge.transform = Transform3D(bridge_basis.scaled(Vector3.ONE * scale_factor), target-center*scale_factor)
  bridge.set_meta("left_building",str(left.node.name))
  bridge.set_meta("right_building",str(right.node.name))
  bridge.set_meta("facade_left",chosen.left)
  bridge.set_meta("facade_right",chosen.right)
  report.bridges.append({"name":str(bridge.name),"facade_left":chosen.left,"facade_right":chosen.right,"height":chosen.y,"z":chosen.z,"length":desired_length,"scale":scale_factor})

 var ground = CSGBox3D.new()
 ground.name = "Ground"
 ground.position = Vector3((instances[0].min_x + instances[-1].max_x)/2.0, -0.4, 0)
 ground.size = Vector3(instances[-1].max_x-instances[0].min_x+16.0, 0.8, 52.0)
 ground.material = make_material(Color(0.07,0.10,0.14))
 ground.use_collision = true
 root.add_child(ground)
 var world = WorldEnvironment.new()
 world.name = "WorldEnvironment"
 var env = Environment.new()
 env.background_mode = Environment.BG_COLOR
 env.background_color = Color(0.035,0.055,0.09)
 env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
 env.ambient_light_color = Color(0.7,0.8,1.0)
 env.ambient_light_energy = 0.9
 env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
 world.environment = env
 root.add_child(world)
 var key = DirectionalLight3D.new()
 key.name = "WarmKey"
 key.rotation_degrees = Vector3(-48,-35,0)
 key.light_color = Color(1.0,0.83,0.64)
 key.light_energy = 1.8
 key.shadow_enabled = true
 root.add_child(key)
 var fill = DirectionalLight3D.new()
 fill.name = "CoolFill"
 fill.rotation_degrees = Vector3(-30,140,0)
 fill.light_color = Color(0.42,0.68,1.0)
 fill.light_energy = 0.9
 root.add_child(fill)
 var camera = Camera3D.new()
 camera.name = "OverviewCamera"
 var center_x = (instances[0].min_x + instances[-1].max_x) / 2.0
 camera.position = Vector3(center_x, 60, ground.size.x*0.85)
 camera.basis = Basis.looking_at(Vector3(center_x, 10, 0)-camera.position)
 camera.current = true
 camera.fov = 54.0
 camera.far = 600.0
 root.add_child(camera)
 add_owner_recursive(root, root)
 var packed = PackedScene.new()
 var result = packed.pack(root)
 if result != OK:
  root.free()
  return result
 result = ResourceSaver.save(packed, "res://scenes/SevenBuildingBridgeMap.tscn")
 var file = FileAccess.open("res://tests/seven_building_map_report.json",FileAccess.WRITE)
 file.store_string(JSON.stringify(report,"  "))
 file.close()
 root.free()
 return result

func test_generate_map():
 assert_eq(build_map(), OK, "Generate and save seven-building bridge map")
 var packed = ResourceLoader.load("res://scenes/SevenBuildingBridgeMap.tscn", "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
 assert_true(packed != null, "Generated scene loads")
 var root = track(packed.instantiate())
 assert_eq(root.get_node("Buildings").get_child_count(), 7, "Seven buildings")
 assert_eq(root.get_node("Bridges").get_child_count(), 6, "Six adjacent bridges")
 assert_true(not root.has_node("Landings"), "No floating landing platform")
 for bridge in root.get_node("Bridges").get_children():
  assert_eq(bridge.scene_file_path, "res://重置桥 .glb", "Every bridge uses reset bridge")
