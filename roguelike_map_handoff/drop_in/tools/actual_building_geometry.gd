extends "res://tools/graybox_geometry.gd"
const DARK = ["res://居民楼3.glb","res://工厂1.glb","res://居民楼4k.glb","res://居民楼2.glb"]
const BRIGHT = ["res://居民楼5.glb","res://居民楼4.glb","res://商店.glb"]
var cache={}
func mesh_bounds(node: Node,t: Transform3D=Transform3D.IDENTITY) -> AABB:
 var entries=[]
 collect(node,t,entries)
 var bounds: AABB=entries[0]
 for b in entries: bounds=bounds.merge(b)
 return bounds
func collect(node: Node,t: Transform3D,out: Array):
 var world=t
 if node is Node3D: world=t*node.transform
 if node is MeshInstance3D and node.mesh!=null: out.append(world*node.mesh.get_aabb())
 for child in node.get_children(): collect(child,world,out)
func asset(path: String) -> Dictionary:
 if not cache.has(path):
  var packed=load(path)
  var sample=packed.instantiate()
  cache[path]={"packed":packed,"bounds":mesh_bounds(sample)}
  sample.free()
 return cache[path]
func is_dark(i: int) -> bool:
 var cell=layout.cells[i]
 return (cell.x+cell.y)%2==0
func choose_asset(i: int,suggested: String) -> String:
 return suggested
func populate(root: Node3D):
 if root.has_node("ActualBuildings"): return
 var buildings=group(root,"ActualBuildings")
 var supports=group(root,"FacadeSupports")
 var steel=material(Color(0.12,0.15,0.18))
 var dc=0
 var bc=0
 for i in range(20):
  var dark=is_dark(i)
  var path: String
  if dark:
   path=DARK[dc%DARK.size()]
   dc+=1
  else:
   path=BRIGHT[bc%BRIGHT.size()]
   bc+=1
  path=choose_asset(i,path)
  var info=asset(path)
  var model=info.packed.instantiate()
  model.name="B%02d_%s"%[i+1,path.get_file().get_basename()]
  buildings.add_child(model)
  var bounds: AABB=info.bounds
  var factor=9.0/maxf(bounds.size.x,bounds.size.z)
  var target_height=12.0+4.0*(i%2)
  model.scale=Vector3(factor,target_height/bounds.size.y,factor)
  var center=v(layout.nodes[i])
  model.position=center-Vector3(bounds.get_center().x*factor,bounds.position.y*model.scale.y,bounds.get_center().z*factor)
  model.set_meta("site_id",i)
  model.set_meta("tone","dark" if dark else "bright")
  model.set_meta("asset",path)
  model.set_meta("height",target_height)
  # Existing socket slabs become supported facade collars at the common 8m floor.
  var frame=group(supports,"B%02d_Support"%[i+1])
  for sx in [-1,1]:
   for sz in [-1,1]:
    box(frame,"Column",center+Vector3(sx*4.45,3.88,sz*4.45),Vector3(0.2,7.76,0.2),steel,true)
  for sz in [-1,1]:
   box(frame,"FacadeBeam",center+Vector3(0,7.65,sz*4.45),Vector3(9.1,0.22,0.22),steel)
  for sx in [-1,1]:
   box(frame,"SideBeam",center+Vector3(sx*4.45,7.65,0),Vector3(0.22,0.22,9.1),steel)
 root.get_node("BuildingSites_20").visible=false
 # Remove labels now buried inside actual buildings.
 for child in root.get_node("SocketDatums").get_children():
  if child is Label3D: child.free()
 root.set_meta("real_building_count",20)
 root.set_meta("building_note","20 model instances; supported 8m facade collars; graybox bridge geometry retained")
func create(seed_value: int) -> Node3D:
 var root=super.create(seed_value)
 populate(root)
 return root
func owns(node: Node,root: Node):
 if node!=root: node.owner=root
 if node!=root and not node.scene_file_path.is_empty(): return
 for child in node.get_children(): owns(child,root)
