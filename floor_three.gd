extends "res://floor_one.gd"
## Third floor: the deepest authored district. A 180 x 180 metre square with the
## highest street enemy scaling and the thickest Boss health pool, all read from
## `level_stats.gd`. This is the last floor, so beating its Boss reports a
## cleared run instead of advancing.

func _ready() -> void:
	floor_index = LEVELS.FLOOR_THREE
	super._ready()
