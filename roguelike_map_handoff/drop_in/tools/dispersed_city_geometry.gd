extends "res://tools/actual_building_geometry.gd"
func _init():
 layout=load("res://tools/dispersed_city_layout.gd").new()
func is_dark(i: int) -> bool:
 return i%2==0
func choose_asset(i: int,suggested: String) -> String:
 var cell=layout.cells[i]
 if layout.SERVICES.has(cell):
  return "res://医疗点.glb" if layout.SERVICES[cell]=="medical" else "res://商店.glb"
 return "res://居民楼4.glb" if suggested=="res://商店.glb" else suggested
func decorate(root: Node3D):
 if root.has_node("ServicePoints"): return
 var services=group(root,"ServicePoints")
 var paved=material(Color(0.4,0.43,0.46))
 var green=material(Color(0.12,0.85,0.5))
 var amber=material(Color(1,0.65,0.2))
 for c in layout.SERVICES:
  var id=layout.cells.find(c)
  var role=layout.SERVICES[c]
  var p: Vector2=layout.nodes[id]
  var direction=signf(-6-p.x)
  var facade=Vector2(p.x+direction*4.8,p.y)
  var group_node=group(services,"%s_B%02d"%[role,id+1])
  group_node.set_meta("service_type",role)
  group_node.set_meta("site_id",id)
  group_node.set_meta("station_z",p.y)
  segment(group_node,"MainRoadAccess",facade,Vector2(-6,p.y),0,2.8,0.2,paved)
  var m=green if role=="medical" else amber
  box(group_node,"ServiceSign",Vector3(facade.x,2.0,p.y),Vector3(0.16,3.6,1.5),m)
  text(group_node,"MED +" if role=="medical" else "SHOP",Vector3(facade.x,4.2,p.y),Color.WHITE)
 # No visual arrows, start/goal labels, or boundary indicator walls.
 root.set_meta("service_count",4)
 root.set_meta("service_spacing_m",24.0)
 root.set_meta("start_count",1)
 root.set_meta("goal_count",1)
 root.set_meta("indicators_removed",true)
 root.set_meta("boundary_walls_removed",true)
