extends "res://floor_one.gd"
## Second floor: the same water-front district rules grown into a 160 x 160
## metre square, with tougher street enemies and a thicker mirror Boss.
##
## Nothing in this script changes the combat baseline. Map size, street enemy
## health/damage, encounter count, credit scale and the Boss health pool all
## come from `level_stats.gd`, so the second floor is this scene plus one row in
## that table. Every other first-floor rule (roads, houses, services, water,
## erosion, duel) is inherited unchanged.

func _ready() -> void:
	floor_index = LEVELS.FLOOR_TWO
	super._ready()
