@tool
extends "res://addons/godot_ai/testing/test_suite.gd"
func suite_name() -> String: return "dispersed_city_services"
func test_distribution_services_and_unique_endpoints():
 var root=track(load("res://scenes/ActualBuildingBridgePreview.tscn").instantiate())
 var g=root.get_node("Generated")
 var layout=load("res://tools/dispersed_city_layout.gd").new()
 var sites=layout.cells
 assert_eq(g.get_node("ActualBuildings").get_child_count(),20,"20 buildings")
 var services=g.get_node("ServicePoints").get_children()
 assert_eq(services.size(),4,"Two shops and two medical points")
 var shop_z=[]
 var med_z=[]
 for s in services:
  if s.get_meta("service_type")=="shop": shop_z.append(s.get_meta("station_z"))
  else: med_z.append(s.get_meta("station_z"))
 assert_eq(shop_z.size(),2,"Two shops")
 assert_eq(med_z.size(),2,"Two medical points")
 assert_eq(shop_z[0],-42.0,"First shop on main road north segment")
 assert_eq(shop_z[1],6.0,"Second shop on main road south segment")
 assert_eq(med_z[0],-18.0,"First medical point on main road")
 assert_eq(med_z[1],30.0,"Second medical point on main road")
 assert_eq(g.get_meta("start_count"),1,"One logical start")
 assert_eq(g.get_meta("goal_count"),1,"One logical goal")
 assert_true(not g.has_node("Navigation"),"Visual start/goal indicators removed")
 assert_true(not g.has_node("Boundary"),"Indicator boundary walls removed")
 assert_true(g.get_meta("indicators_removed"),"Indicator removal metadata")
 assert_true(g.get_meta("boundary_walls_removed"),"Boundary wall removal metadata")
 var building_nodes=g.get_node("ActualBuildings").get_children()
 for i in range(building_nodes.size()):
  for j in range(i+1,building_nodes.size()):
   var a=building_nodes[i].position
   var b=building_nodes[j].position
   assert_true(a.distance_to(b)>=11.0,"Buildings distributed without overlap")
 var path_counts={}
 for seed in range(20260923,20260928):
  var plan=layout.plan(seed)
  assert_true(plan.edges.size()>=19 and plan.edges.size()<=26,"Bridge network remains connected range")
  path_counts[seed]=plan.edges.size()
 assert_true(path_counts.size()==5,"Five seeds checked")
 var f=FileAccess.open("res://tools/dispersed_city_validation.json",FileAccess.WRITE)
 f.store_string(JSON.stringify({"services":4,"start":1,"goal":1,"checked_seeds":path_counts},"  "))
 f.close()
