extends "res://tools/graybox_preview_controls.gd"
var base_geometry=preload("res://tools/actual_bridge_geometry.gd").new()
var buildings_visible=true
func _ready():
 generator=load("res://tools/actual_building_geometry.gd").new()
 super._ready()
 for button in find_children("*","Button",true,false):
  if button.text=="Roads only": button.text="Toggle bridges"
 for n in find_children("*","Label",true,false):
  if n.text.contains("building reservations"):
   n.text="R: random bridges | N/P: next/previous | B: hide bridges | V: hide buildings\nT: top view | O: overview | RMB drag: orbit | Wheel: zoom\n20 actual buildings. Roads and buildings stay fixed across bridge seeds.\n8m facade collars are supported. Bridges are still graybox meshes."
func command(action: int):
 if action==2:
  bridge_visible=not bridge_visible
  set_bridges()
  return
 seed_value=randi_range(1,2000000000) if action==0 else maxi(1,seed_value+action)
 var old=get_node("Generated")
 var fresh=base_geometry.create(seed_value)
 # Preserve all actual models instead of reloading them on every seed switch.
 for name in ["ActualBuildings","FacadeSupports"]:
  if old.has_node(name):
   var n=old.get_node(name)
   old.remove_child(n)
   fresh.add_child(n)
 fresh.get_node("BuildingSites_20").visible=false
 for n in fresh.get_node("SocketDatums").get_children():
  if n is Label3D: n.free()
 if not fresh.has_node("ActualBuildings"): generator.populate(fresh)
 remove_child(old)
 old.queue_free()
 add_child(fresh)
 set_bridges()
 set_buildings()
 update_status()
func set_bridges():
 for path in ["Bridges","BridgeJunctions"]:
  get_node("Generated/"+path).visible=bridge_visible
func set_buildings():
 for path in ["ActualBuildings","FacadeSupports","SocketDatums"]:
  get_node("Generated/"+path).visible=buildings_visible
 get_node("Generated/BuildingSites_20").visible=not buildings_visible
func update_status():
 seed_input.text=str(seed_value)
 status.text="8 x 8 BUILDING PREVIEW | Seed %d | Buildings 20 | Bridges %d"%[seed_value,get_node("Generated/Bridges").get_child_count()]
func _unhandled_input(event):
 if event is InputEventKey and event.pressed and not event.echo and event.keycode==KEY_V:
  buildings_visible=not buildings_visible
  set_buildings()
 else:
  super._unhandled_input(event)
