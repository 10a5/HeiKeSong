@tool
extends "res://addons/godot_ai/testing/test_suite.gd"
func suite_name() -> String: return "graybox_preview"
func test_ten_seeds():
 var layout=load("res://tools/graybox_layout.gd").new()
 var reports=[]
 var signatures={}
 var road_signature=""
 for seed_value in range(20260923,20260933):
  var plan=layout.plan(seed_value)
  assert_eq(layout.nodes.size(),20,"20 reserved buildings")
  assert_true(plan.edges.size()>=19 and plan.edges.size()<=26,"19-26 bridge connections")
  var adjacency={}
  for i in range(20): adjacency[i]=[]
  var shape_count=0
  var segments=0
  var diagonal=0
  for e in plan.edges:
   adjacency[e.a].append(e.b)
   adjacency[e.b].append(e.a)
   assert_true(layout.clear_path(e.points,e.a,e.b),"Bridge corridor avoids third building")
   for pair in [[e.points[0],layout.nodes[e.a]],[e.points[-1],layout.nodes[e.b]]]:
    var delta=(pair[0]-pair[1]).abs()
    assert_true(absf(maxf(delta.x,delta.y)-4.8)<0.001,"Socket on facade datum")
   if e.points.size()>2: shape_count+=1
   segments+=e.points.size()-1
   var delta=layout.nodes[e.a]-layout.nodes[e.b]
   if absf(delta.x)>0.1 and absf(delta.y)>0.1: diagonal+=1
  var visited={0:true}
  var queue=[0]
  while not queue.is_empty():
   var node=queue.pop_front()
   for next in adjacency[node]:
    if not visited.has(next):
     visited[next]=true
     queue.append(next)
  assert_eq(visited.size(),20,"All sites bridge-connected")
  var road_graph={}
  for c in plan.roads: road_graph[c]=[]
  for e in plan.streets:
   assert_true(not e.a in layout.CELLS and not e.b in layout.CELLS,"Road avoids buildings")
   road_graph[e.a].append(e.b)
   road_graph[e.b].append(e.a)
  var reached={Vector2i(3,3):true}
  var open=[Vector2i(3,3)]
  while not open.is_empty():
   var c=open.pop_front()
   for next in road_graph[c]:
    if not reached.has(next):
     reached[next]=true
     open.append(next)
  assert_eq(reached.size(),plan.roads.size(),"Single connected ground street network")
  for dead in plan.dead_ends: assert_eq(road_graph[dead.start].size(),1,"Preserve cul-de-sac")
  var sig=var_to_str(plan.edges)
  signatures[sig]=true
  assert_eq(sig,var_to_str(layout.plan(seed_value).edges),"Repeatable seed")
  if road_signature.is_empty(): road_signature=var_to_str(plan.streets)
  assert_eq(var_to_str(plan.streets),road_signature,"Roads fixed across seeds")
  reports.append({"seed":seed_value,"links":plan.edges.size(),"segments":segments,"elbows":shape_count,"diagonals":diagonal,"road_nodes":plan.roads.size()})
 assert_true(signatures.size()>=8,"Different seeds produce different bridge networks")
 var f=FileAccess.open("res://tools/graybox_validation.json",FileAccess.WRITE)
 f.store_string(JSON.stringify({"seeds":reports,"unique_graphs":signatures.size()},"  "))
 f.close()
func test_saved_scene():
 var packed=load("res://scenes/GrayboxBridgeRoadPreview.tscn")
 assert_true(packed!=null,"Scene exists")
 var root=track(packed.instantiate())
 assert_eq(root.get_node("Generated/BuildingSites_20").get_child_count(),20,"20 markers not building models")
 assert_true(root.get_node("Generated/Bridges").get_child_count()>=19,"Saved bridge graph")
 for bridge in root.get_node("Generated/Bridges").get_children():
  for child in bridge.get_children():
   if child is MeshInstance3D and str(child.name).begins_with("Deck"):
    var body=bridge.get_node(str(child.name)+"Collision")
    assert_eq(body.transform,child.transform,"Rotated bridge collision aligned")
