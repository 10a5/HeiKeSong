extends RefCounted
const CELL = 12.0
const CELLS = [Vector2i(0,0),Vector2i(1,0),Vector2i(4,0),Vector2i(6,0),Vector2i(7,0),Vector2i(4,1),Vector2i(0,2),Vector2i(7,2),Vector2i(0,3),Vector2i(6,3),Vector2i(7,4),Vector2i(0,5),Vector2i(4,5),Vector2i(6,5),Vector2i(0,6),Vector2i(4,6),Vector2i(6,6),Vector2i(1,7),Vector2i(6,7),Vector2i(7,7)]
var cells = CELLS.duplicate()
var dead_end_rules=[{"start":Vector2i(2,0),"end":Vector2i(2,1)},{"start":Vector2i(5,0),"end":Vector2i(5,1)}]
var nodes = []
func _init():
 for c in cells:
  nodes.append(Vector2((c.x-3.5)*CELL,(c.y-3.5)*CELL))
func avenue(c: Vector2i) -> bool:
 return c.x==3 or c.y==2 or c.y==4
func noise_for(seed_value: int) -> FastNoiseLite:
 var n=FastNoiseLite.new()
 n.seed=seed_value
 n.noise_type=FastNoiseLite.TYPE_PERLIN
 n.frequency=0.18
 n.fractal_octaves=3
 return n
func socket(center: Vector2, toward: Vector2) -> Vector2:
 var d=toward-center
 return center+d*(4.8/maxf(absf(d.x),absf(d.y)))
func hits_box(a: Vector2,b: Vector2,c: Vector2,half: float) -> bool:
 var lo=0.0
 var hi=1.0
 var d=b-a
 for axis in range(2):
  if absf(d[axis])<0.00001:
   if a[axis]<c[axis]-half or a[axis]>c[axis]+half:
    return false
  else:
   var t0=(c[axis]-half-a[axis])/d[axis]
   var t1=(c[axis]+half-a[axis])/d[axis]
   lo=maxf(lo,minf(t0,t1))
   hi=minf(hi,maxf(t0,t1))
   if lo>hi: return false
 return true
func clear_path(points: Array,ia: int,ib: int) -> bool:
 for k in range(nodes.size()):
  if k==ia or k==ib: continue
  for s in range(points.size()-1):
   if hits_box(points[s],points[s+1],nodes[k],5.95): return false
 return true
func find_root(parents: Array,id: int) -> int:
 while parents[id]!=id:
  id=parents[id]
 return id
func plan(seed_value: int) -> Dictionary:
 var noise=noise_for(seed_value)
 var rng=RandomNumberGenerator.new()
 rng.seed=seed_value
 var candidates=[]
 for i in range(nodes.size()):
  for j in range(i+1,nodes.size()):
   var a: Vector2=nodes[i]
   var b: Vector2=nodes[j]
   var length=a.distance_to(b)
   if length>53: continue
   var points=[socket(a,b),socket(b,a)]
   if not clear_path(points,i,j): continue
   var mid=(a+b)/24.0
   var density=clampf((noise.get_noise_3d(mid.x,mid.y,float(i+j)*0.31)+1)*0.5,0,1)
   var bend=Vector2(b.x,a.y) if rng.randf()<0.5 else Vector2(a.x,b.y)
   var shape="straight"
   if absf(a.x-b.x)>14 and absf(a.y-b.y)>14 and density>0.43 and rng.randf()<0.5:
    var bent=[socket(a,bend),bend,socket(b,bend)]
    if clear_path(bent,i,j):
     points=bent
     shape="elbow"
   var cost=length*(1.35-density)+rng.randf_range(0,9)
   candidates.append({"a":i,"b":j,"points":points,"density":density,"cost":cost,"shape":shape})
 candidates.sort_custom(func(a,b):return a.cost<b.cost)
 var parents=[]
 var degree=[]
 for i in range(20):
  parents.append(i)
  degree.append(0)
 var edges=[]
 var selected={}
 for e in candidates:
  var ra=find_root(parents,e.a)
  var rb=find_root(parents,e.b)
  if ra!=rb:
   parents[ra]=rb
   e["backbone"]=true
   edges.append(e)
   selected[str(e.a)+":"+str(e.b)]=true
   degree[e.a]+=1
   degree[e.b]+=1
 var target=rng.randi_range(22,26)
 for e in candidates:
  if edges.size()>=target: break
  if selected.has(str(e.a)+":"+str(e.b)): continue
  if degree[e.a]>=4 or degree[e.b]>=4: continue
  if rng.randf()>clampf(0.25+e.density*0.7,0,1): continue
  e["backbone"]=false
  edges.append(e)
  degree[e.a]+=1
  degree[e.b]+=1
 # Add short two-span doglegs after selecting the connectivity backbone.
 for e in edges:
  if e.shape!="straight" or rng.randf()>0.42: continue
  var a: Vector2=e.points[0]
  var b: Vector2=e.points[-1]
  if a.distance_to(b)<8: continue
  var direction=(b-a).normalized()
  var offset=Vector2(-direction.y,direction.x)*rng.randf_range(1.2,2.8)
  if rng.randf()<0.5: offset=-offset
  var midpoint=(a+b)*0.5+offset
  var bent=[a,midpoint,b]
  if clear_path(bent,e.a,e.b):
   e.points=bent
   e.shape="dogleg"
 var roads=[]
 for y in range(8):
  for x in range(8):
   var c=Vector2i(x,y)
   if c in cells: continue
   roads.append(c)
 var reachable=[Vector2i(3,3)]
 var queue=[Vector2i(3,3)]
 while not queue.is_empty():
  var c=queue.pop_front()
  for step in [Vector2i.UP,Vector2i.DOWN,Vector2i.LEFT,Vector2i.RIGHT]:
   var next=c+step
   if next in roads and not next in reachable:
    reachable.append(next)
    queue.append(next)
 roads=reachable
 # Roads use centerline segments; width 6m for avenues, 2.8m for alleys.
 var streets=[]
 for c in roads:
  for offset in [Vector2i.RIGHT,Vector2i.DOWN]:
   var next=c+offset
   if next in roads:
    var blocked=false
    for rule in dead_end_rules:
     if (c==rule.start or next==rule.start) and not (c==rule.end or next==rule.end): blocked=true
    if blocked: continue
    streets.append({"a":c,"b":next,"wide":avenue(c) and avenue(next)})
 # Explicit cul-de-sac spurs are excluded from through routes.
 var dead_ends=dead_end_rules.duplicate(true)
 return {"seed":seed_value,"edges":edges,"roads":roads,"streets":streets,"dead_ends":dead_ends,"connected":edges.size()>=19,"degree":degree}

