@tool
extends "res://addons/godot_ai/testing/test_suite.gd"
func suite_name() -> String: return "actual_buildings"
func test_models_footprints_and_bridge_supports():
 var generator=load("res://tools/actual_bridge_geometry.gd").new()
 var root=track(load("res://scenes/ActualBuildingBridgePreview.tscn").instantiate())
 var base=track(load("res://scenes/GrayboxBridgeRoadPreview.tscn").instantiate())
 var g=root.get_node("Generated")
 var buildings=g.get_node("ActualBuildings").get_children()
 assert_eq(buildings.size(),20,"20 actual model roots")
 assert_eq(g.get_node("FixedRoads").get_child_count(),base.get_node("Generated/FixedRoads").get_child_count(),"Road topology retained")
 assert_eq(g.get_node("Bridges").get_child_count(),22,"Reference bridge graph retained")
 var assets={}
 var report=[]
 var triangles=load("res://tests/build_seven_building_map.gd").new()
 for model in buildings:
  var id=int(model.get_meta("site_id"))
  var center: Vector2=generator.layout.nodes[id]
  var bounds=generator.mesh_bounds(model)
  assert_true(bounds.position.x>=center.x-4.51 and bounds.end.x<=center.x+4.51,"Model fits site X")
  assert_true(bounds.position.z>=center.y-4.51 and bounds.end.z<=center.y+4.51,"Model fits site Z")
  assert_true(absf(bounds.position.y)<0.01,"Building sits on ground")
  assert_true(absf(bounds.size.y/4-roundf(bounds.size.y/4))<0.001,"Total height follows 4m datum")
  assert_true(not model.scene_file_path.is_empty(),"Imported model remains reusable instance")
  assets[model.scene_file_path]=true
  var count=0
  for tri in triangles.triangles_for(model):
   var low=minf(tri[0].y,minf(tri[1].y,tri[2].y))
   var high=maxf(tri[0].y,maxf(tri[1].y,tri[2].y))
   if low<=8 and high>=7.76: count+=1
  assert_true(count>0,"8m facade collar intersects actual mesh")
  var supports=g.get_node("FacadeSupports/B%02d_Support"%[id+1])
  var columns=0
  for n in supports.get_children():
   if n is MeshInstance3D and str(n.name).begins_with("Column"):
    assert_true(absf(n.position.y-n.mesh.size.y/2)<0.001,"Column grounded")
    assert_true(absf(n.position.y+n.mesh.size.y/2-7.76)<0.001,"Column meets collar underside")
    columns+=1
  assert_eq(columns,4,"Four real ground supports")
  report.append({"id":id,"asset":model.scene_file_path,"tone":model.get_meta("tone"),"height":bounds.size.y,"collar_intersection_triangles":count})
 assert_eq(assets.size(),7,"All seven assets used")
 for bridge in generator.layout.plan(20260923).edges:
  for side in [[bridge.a,bridge.points[0]],[bridge.b,bridge.points[-1]]]:
   var delta: Vector2=(side[1]-generator.layout.nodes[side[0]]).abs()
   assert_true(delta.x<=4.801 and delta.y<=4.801,"Bridge endpoint on supported collar")
 var f=FileAccess.open("res://tools/actual_building_validation.json",FileAccess.WRITE)
 f.store_string(JSON.stringify({"buildings":report,"assets":assets.size(),"bridge_links":22},"  "))
 f.close()
