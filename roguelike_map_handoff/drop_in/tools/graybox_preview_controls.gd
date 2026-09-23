extends Node3D
var generator=preload("res://tools/graybox_geometry.gd").new()
var seed_value=20260923
var bridge_visible=true
var status: Label
var seed_input: LineEdit
var angle=0.0
var elevation=0.95
var distance=124.0
var orbiting=false
func _ready():
 seed_value=int(get_meta("seed",20260923))
 var layer=CanvasLayer.new()
 add_child(layer)
 var panel=PanelContainer.new()
 panel.position=Vector2(18,18)
 layer.add_child(panel)
 var column=VBoxContainer.new()
 panel.add_child(column)
 status=Label.new()
 status.add_theme_font_size_override("font_size",18)
 column.add_child(status)
 var hint=Label.new()
 hint.text="R: random seed  |  N/P: next/previous  |  B: bridges on/off\nT: top view  |  O: overview  |  RMB drag: orbit  |  Wheel: zoom\nGray: avenues  Dark gray: alleys  Cyan: backbone  Amber: extra links\nB01-B20: building reservations only. All bridges use the 8m test datum."
 column.add_child(hint)
 var row=HBoxContainer.new()
 column.add_child(row)
 for spec in [["Random",0],["Previous",-1],["Next",1],["Roads only",2]]:
  var button=Button.new()
  button.text=spec[0]
  var action=int(spec[1])
  button.pressed.connect(func(): command(action))
  row.add_child(button)
 var seed_row=HBoxContainer.new()
 column.add_child(seed_row)
 seed_input=LineEdit.new()
 seed_input.placeholder_text="Enter seed to replay"
 seed_input.custom_minimum_size=Vector2(220,0)
 seed_row.add_child(seed_input)
 var apply=Button.new()
 apply.text="Apply seed"
 apply.pressed.connect(apply_seed)
 seed_row.add_child(apply)
 seed_input.text_submitted.connect(func(_text): apply_seed())
 command(0)
func apply_seed():
 if seed_input.text.is_valid_int():
  seed_value=clampi(int(seed_input.text),1,2000000000)-1
  command(1)
  seed_input.release_focus()
func command(action: int):
 if action==2:
  bridge_visible=not bridge_visible
  set_bridges()
 else:
  seed_value=randi_range(1,2000000000) if action==0 else maxi(1,seed_value+action)
  var old=get_node("Generated")
  remove_child(old)
  old.queue_free()
  add_child(generator.create(seed_value))
  set_bridges()
  update_status()
func set_bridges():
 for path in ["Bridges","BridgeJunctions","SocketDatums"]:
  get_node("Generated/"+path).visible=bridge_visible
func update_status():
 var g=get_node("Generated")
 seed_input.text=str(seed_value)
 status.text="8 x 8 ROAD / BRIDGE GRAYBOX     Seed: %d     Sites: 20     Links: %d"%[seed_value,g.get_meta("bridge_count")]
func orbit():
 var cam=get_node("OverviewCamera")
 cam.position=Vector3(sin(angle)*cos(elevation),sin(elevation),cos(angle)*cos(elevation))*distance
 cam.look_at(Vector3(0,3,0))
func _unhandled_input(event):
 if event is InputEventKey and event.pressed and not event.echo:
  match event.keycode:
   KEY_R: command(0)
   KEY_N: command(1)
   KEY_P: command(-1)
   KEY_B: command(2)
   KEY_T:
    elevation=1.565
    orbit()
   KEY_O:
    elevation=0.95
    angle=0.0
    orbit()
 if event is InputEventMouseButton:
  if event.button_index==MOUSE_BUTTON_RIGHT: orbiting=event.pressed
  if event.pressed and event.button_index==MOUSE_BUTTON_WHEEL_UP:
   distance=maxf(30,distance-8)
   orbit()
  if event.pressed and event.button_index==MOUSE_BUTTON_WHEEL_DOWN:
   distance=minf(230,distance+8)
   orbit()
 if event is InputEventMouseMotion and orbiting:
  angle-=event.relative.x*0.008
  elevation=clampf(elevation+event.relative.y*0.006,0.2,1.565)
  orbit()
