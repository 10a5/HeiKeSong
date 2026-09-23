extends "res://tools/dispersed_city_geometry.gd"
const BRIDGE_BASIS=Basis(Vector3(0.5245950222,0.1574558616,-0.8366646765),Vector3(-0.2874774635,0.9577874541,0),Vector3(0.8013468385,0.2405222207,0.5477155447))
const BRIDGE_CENTER=Vector3(-8.4502602,24.3716488,0.8670797)
func add_model_for_segment(parent: Node,segment_data: Dictionary,index: int):
 var length=segment_data.length
 var direction=segment_data.direction
 var start=segment_data.position-direction*(length*0.5)+Vector3(0,0.125,0)
 var end=segment_data.position+direction*(length*0.5)+Vector3(0,0.125,0)
 var horizontal=Vector3(end.x-start.x,0,end.z-start.z)
 if horizontal.length()<0.1: return
 var axis=horizontal.normalized()
 var side=axis.cross(Vector3.UP).normalized()
 var placement=Basis(axis,Vector3.UP,side)
 var scale_vec=Vector3(horizontal.length()/107.5178375,0.13,0.13)
 var model=load("res://重置桥 .glb").instantiate()
 model.name="UserResetBridge_%02d"%index
 parent.add_child(model)
 var center=(start+end)*0.5+Vector3(0,1.15,0)
 model.transform=Transform3D(placement*BRIDGE_BASIS.scaled(scale_vec),center-placement*(BRIDGE_CENTER*scale_vec))
 parent.set_meta("actual_bridge",true)
 parent.set_meta("asset","res://重置桥 .glb")
func replace_bridges(root: Node3D):
 var bridge_root=root.get_node("Bridges")
 for g in bridge_root.get_children():
  var decks=[]
  for n in g.find_children("Deck", "MeshInstance3D", true, false):
   decks.append({"position":n.position,"direction":n.basis.x.normalized(),"length":n.mesh.size.x})
  for n in g.get_children():
   if n is MeshInstance3D or str(n.name).contains("DeckCollision") or str(n.name).begins_with("Joint"):
    n.free()
  for i in range(decks.size()): add_model_for_segment(g,decks[i],i)
func create(seed_value: int) -> Node3D:
 var result=super.create(seed_value)
 replace_bridges(result)
 decorate(result)
 return result
