extends RefCounted
class_name LevelStats
## Per-floor multipliers for the three hand-authored floors.
##
## Only four things change between floors: the square the district grows into,
## how durable and how hard-hitting the street enemies are, and how deep the
## mirror Boss's health pool is. Movement speeds, attack timing, telegraphs,
## card costs, drop tables, service prices and the erosion rule are deliberately
## left at their first-floor values so a later floor stays readable and the
## existing combat baseline keeps its meaning.
##
## Every multiplier is applied at the point the value is already owned by:
## `street_enemy_health` / `street_enemy_damage` on `enemy_variant.gd` and
## `max_health` on `mirror_boss.gd`. Nothing here reads or writes scene state,
## so the table is safe to query from tests.

const FLOOR_ONE := 1
const FLOOR_TWO := 2
const FLOOR_THREE := 3

const FLOORS := {
	FLOOR_ONE: {
		"floor": FLOOR_ONE,
		"title": "神经断层",
		"district": "第一层 · 水岸街区",
		"map_size": 100.0,
		"street_enemy_health": 1.0,
		"street_enemy_damage": 1.0,
		"boss_health_multiplier": 1.0,
		"boss_damage_multiplier": 1.0,
		"encounter_count": 8,
		"encounter_credits": 15,
		"starting_credits": 40,
	},
	FLOOR_TWO: {
		"floor": FLOOR_TWO,
		"title": "神经断层",
		"district": "第二层 · 深巷回廊",
		"map_size": 160.0,
		"street_enemy_health": 1.4,
		"street_enemy_damage": 1.25,
		"boss_health_multiplier": 2.0,
		"boss_damage_multiplier": 1.2,
		"encounter_count": 10,
		"encounter_credits": 18,
		"starting_credits": 55,
	},
	FLOOR_THREE: {
		"floor": FLOOR_THREE,
		"title": "神经断层",
		"district": "第三层 · 断层核心",
		"map_size": 180.0,
		"street_enemy_health": 1.85,
		"street_enemy_damage": 1.5,
		"boss_health_multiplier": 3.2,
		"boss_damage_multiplier": 1.45,
		"encounter_count": 12,
		"encounter_credits": 22,
		"starting_credits": 70,
	},
}

const SCENES := {
	FLOOR_ONE: "res://floor_one.tscn",
	FLOOR_TWO: "res://floor_two.tscn",
	FLOOR_THREE: "res://floor_three.tscn",
}


static func floors() -> Array:
	var result: Array = FLOORS.keys()
	result.sort()
	return result


static func has_floor(floor_index: int) -> bool:
	return FLOORS.has(floor_index)


## Copy of one floor's record. Returns an empty dictionary for an unknown floor
## instead of falling back to floor one, so a typo cannot silently play a
## differently tuned district.
static func config(floor_index: int) -> Dictionary:
	if not FLOORS.has(floor_index):
		return {}
	return (FLOORS[floor_index] as Dictionary).duplicate(true)


static func scene_path(floor_index: int) -> String:
	return str(SCENES.get(floor_index, ""))


## First and last authored floor, used for clamping an unbounded request.
static func first_floor() -> int:
	return FLOOR_ONE


static func last_floor() -> int:
	return FLOOR_THREE


## Clamp any integer into the authored range so wraparound navigation can ask
## for floor 4 or floor 0 without producing a missing-scene error.
static func clamp_floor(floor_index: int) -> int:
	return clampi(floor_index, first_floor(), last_floor())


static func next_floor(floor_index: int) -> int:
	return clamp_floor(floor_index + 1)


static func map_size(floor_index: int) -> float:
	return float(config(floor_index).get("map_size", 100.0))


static func enemy_health_multiplier(floor_index: int) -> float:
	return float(config(floor_index).get("street_enemy_health", 1.0))


static func enemy_damage_multiplier(floor_index: int) -> float:
	return float(config(floor_index).get("street_enemy_damage", 1.0))


static func boss_health_multiplier(floor_index: int) -> float:
	return float(config(floor_index).get("boss_health_multiplier", 1.0))


static func boss_damage_multiplier(floor_index: int) -> float:
	return float(config(floor_index).get("boss_damage_multiplier", 1.0))


static func district_title(floor_index: int) -> String:
	return str(config(floor_index).get("district", "第一层 · 水岸街区"))


## Comparing two floors keeps "later floors are bigger, tougher and thicker"
## as a single assertion in tests and in the shop/HUD copy.
static func is_harder_than(floor_index: int, other_floor: int) -> bool:
	var current := config(floor_index)
	var other := config(other_floor)
	if current.is_empty() or other.is_empty():
		return false
	return (
		float(current["map_size"]) > float(other["map_size"])
		and float(current["street_enemy_health"]) > float(other["street_enemy_health"])
		and float(current["street_enemy_damage"]) > float(other["street_enemy_damage"])
		and float(current["boss_health_multiplier"]) > float(other["boss_health_multiplier"])
	)
