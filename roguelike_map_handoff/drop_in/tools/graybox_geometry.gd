extends RefCounted
var layout=preload("res://tools/graybox_layout.gd").new()
var active_bridges: Node3D
func material(c: Color) -> StandardMaterial3D:
 var m=StandardMaterial3D.new()
 m.albedo_color=c
 m.roughness=0.85
 return m
func group(parent: Node,name: String) -> Node3D:
 var g=Node3D.new()
 g.name=name
 parent.add_child(g)
 return g
func box(parent: Node,name: String,pos: Vector3,size: Vector3,mat: Material,solid: bool=false,basis: Basis=Basis.IDENTITY):
 var n=MeshInstance3D.new()
 n.name=name
 var mesh=BoxMesh.new()
 mesh.size=size
 mesh.material=mat
 n.mesh=mesh
 n.transform=Transform3D(basis,pos)
 parent.add_child(n,true)
 if solid:
  var body=StaticBody3D.new()
  body.name=str(n.name)+"Collision"
  body.transform=n.transform
  parent.add_child(body)
  var s=BoxShape3D.new()
  s.size=size
  var cs=CollisionShape3D.new()
  cs.shape=s
  body.add_child(cs)
 return n
func v(p: Vector2,y: float=0) -> Vector3:
 return Vector3(p.x,y,p.y)
func segment(parent: Node,name: String,a: Vector2,b: Vector2,y: float,w: float,h: float,m: Material,solid: bool=true):
 var axis=v((b-a).normalized())
 var basis=Basis(axis,Vector3.UP,axis.cross(Vector3.UP))
 box(parent,name,v((a+b)*0.5,y-h*0.5),Vector3(a.distance_to(b),h,w),m,solid,basis)
func text(parent: Node,label: String,pos: Vector3,color: Color,flat: bool=false):
 var n=Label3D.new()
 n.text=label
 n.position=pos
 n.font_size=42
 n.pixel_size=0.022
 n.modulate=color
 n.no_depth_test=false
 if flat: n.rotation.x=-PI/2
 else: n.billboard=BaseMaterial3D.BILLBOARD_ENABLED
 parent.add_child(n)
func owns(node: Node,root: Node):
 if node!=root: node.owner=root
 for child in node.get_children(): owns(child,root)
func create(seed_value: int) -> Node3D:
 var plan=layout.plan(seed_value)
 var root=Node3D.new()
 root.name="Generated"
 root.set_meta("seed",seed_value)
 root.set_meta("bridge_count",plan.edges.size())
 var ground=material(Color(0.075,0.087,0.11))
 var outline=material(Color(0.22,0.25,0.3))
 var avenue_mat=material(Color(0.54,0.57,0.61))
 var alley_mat=material(Color(0.29,0.32,0.36))
 var bridge_mat=material(Color(0.35,0.7,0.78))
 var branch_mat=material(Color(0.91,0.68,0.32))
 var white=material(Color(0.83,0.89,0.92))
 box(root,"Base",Vector3(0,-0.6,0),Vector3(100,0.8,100),ground)
 var grid=group(root,"Grid")
 for i in range(9):
  box(grid,"LineX",Vector3(-48+i*12,-0.18,0),Vector3(0.055,0.015,96),outline)
  box(grid,"LineZ",Vector3(0,-0.18,-48+i*12),Vector3(96,0.015,0.055),outline)
 for i in range(8):
  text(grid,String.chr(65+i),Vector3(-42+i*12,0,-51),Color.WHITE,true)
  text(grid,str(i+1),Vector3(-51,0,-42+i*12),Color.WHITE,true)
 var sites=group(root,"BuildingSites_20")
 var pads=group(root,"SocketDatums")
 for i in range(20):
  var p: Vector2=layout.nodes[i]
  var site=group(sites,"B%02d"%[i+1])
  box(site,"Footprint",v(p,-0.13),Vector3(12,0.12,12),outline)
  text(site,"B%02d"%[i+1],v(p,0.1),Color(0.8,0.85,0.9),true)
  # Thin 8m interface pads are placeholders, not finished buildings.
  box(pads,"B%02d_8mDatum"%[i+1],v(p,7.88),Vector3(9.6,0.24,9.6),outline,true)
  text(pads,"B%02d"%[i+1],v(p,8.3),Color.WHITE,true)
 var roads=group(root,"FixedRoads")
 for c in plan.roads:
  var p=Vector2((c.x-3.5)*12,(c.y-3.5)*12)
  var width=6.0 if layout.avenue(c) else 2.8
  box(roads,"Intersection",v(p,-0.1),Vector3(width,0.2,width),avenue_mat if width==6 else alley_mat,true)
 for e in plan.streets:
  var a=Vector2((e.a.x-3.5)*12,(e.a.y-3.5)*12)
  var b=Vector2((e.b.x-3.5)*12,(e.b.y-3.5)*12)
  segment(roads,"Avenue" if e.wide else "Alley",a,b,0,6 if e.wide else 2.8,0.2,avenue_mat if e.wide else alley_mat)
  if e.wide:
   for k in range(1,4):
    var p=a.lerp(b,float(k)/4)
    segment(roads,"RoadDash",p-(b-a).normalized()*0.65,p+(b-a).normalized()*0.65,0.015,0.09,0.015,white,false)
 var bridge_group=group(root,"Bridges")
 active_bridges=bridge_group
 var segments=[]
 for index in range(plan.edges.size()):
  var e=plan.edges[index]
  var g=group(bridge_group,"B%02d_to_B%02d"%[e.a+1,e.b+1])
  g.set_meta("from",e.a)
  g.set_meta("to",e.b)
  g.set_meta("backbone",e.backbone)
  var m=bridge_mat if e.backbone else branch_mat
  for s in range(e.points.size()-1):
   var a: Vector2=e.points[s]
   var b: Vector2=e.points[s+1]
   segment(g,"Deck",a,b,8,2.2,0.25,m)
   segments.append({"a":a,"b":b,"edge":index})
  for p in e.points:
   box(g,"Joint",v(p,7.875),Vector3(2.2,0.25,2.2),m,true)
 var junctions=group(root,"BridgeJunctions")
 var placed={}
 for i in range(segments.size()):
  for j in range(i+1,segments.size()):
   if segments[i].edge==segments[j].edge: continue
   var hit=Geometry2D.segment_intersects_segment(segments[i].a,segments[i].b,segments[j].a,segments[j].b)
   if hit!=null:
    var key=str(Vector2(hit).snapped(Vector2.ONE*0.3))
    if not placed.has(key):
     placed[key]=true
     box(junctions,"Crossing",v(hit,7.9),Vector3(2.3,0.2,2.3),white,true)
 var route=group(root,"EnemyRoutePreview")
 # A path along the guaranteed north-south avenue, never across building sites.
 for y in range(7):
  var a=Vector2(-6,(y-3.5)*12)
  var b=Vector2(-6,(y+1-3.5)*12)
  segment(route,"PatrolLine",a,b,0.04,0.12,0.025,branch_mat,false)
 for y in [0,2,4,7]:
  box(route,"PatrolMarker",Vector3(-6,0.15,(y-3.5)*12),Vector3(0.9,0.3,0.9),branch_mat)
 for dead in plan.dead_ends:
  var c=dead.start
  text(roads,"DEAD END",Vector3((c.x-3.5)*12,0.08,(c.y-3.5)*12),Color(1,0.5,0.3),true)
 root.set_meta("junction_count",placed.size())
 return root
