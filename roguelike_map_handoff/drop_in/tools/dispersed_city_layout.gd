extends "res://tools/graybox_layout.gd"
const DISTRIBUTED=[Vector2i(0,0),Vector2i(2,0),Vector2i(6,0),Vector2i(5,1),Vector2i(7,1),Vector2i(0,2),Vector2i(4,2),Vector2i(6,2),Vector2i(1,3),Vector2i(7,3),Vector2i(0,4),Vector2i(2,4),Vector2i(5,4),Vector2i(1,5),Vector2i(6,5),Vector2i(0,6),Vector2i(4,6),Vector2i(7,6),Vector2i(2,7),Vector2i(5,7)]
const SERVICES={Vector2i(2,0):"shop",Vector2i(4,2):"medical",Vector2i(2,4):"shop",Vector2i(4,6):"medical"}
const START=Vector2i(3,7)
const GOAL=Vector2i(3,0)
func _init():
 cells=DISTRIBUTED.duplicate()
 nodes.clear()
 for c in cells: nodes.append(Vector2((c.x-3.5)*12,(c.y-3.5)*12))
 dead_end_rules=[{"start":Vector2i(1,0),"end":Vector2i(1,1)}]
