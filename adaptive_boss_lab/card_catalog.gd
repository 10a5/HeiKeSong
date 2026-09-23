extends RefCounted
## Shared definitions for physical cards, discovery, and presentation.

const KINDS: Array[String] = [
	"punch", "slash", "sweep", "shot", "charged_slash", "roll", "blink", "jet_jump",
	"dash_slash", "airborne_slash", "dive_slash"
]
const STARTING_UNLOCKS: Array[String] = ["slash", "roll", "dash_slash"]
const CARDS: Dictionary = {
	"punch": {"name": "快拳", "category": "attack", "cost": 1.0, "effect": "近距离快速出拳\n可接其他攻击"},
	"slash": {"name": "出拳", "category": "attack", "cost": 2.0, "effect": "向前方强力出拳\n可与翻滚衔接"},
	"sweep": {"name": "扫腿", "category": "attack", "cost": 2.0, "effect": "低身横扫前方\n可打断近身敌人"},
	"shot": {"name": "点射", "category": "attack", "cost": 2.0, "effect": "朝面向直线射击\n可在移动后追击"},
	"charged_slash": {"name": "蓄力重劈", "category": "attack", "cost": 3.0, "effect": "短暂蓄力后重击\n近距离高伤害"},
	"roll": {"name": "翻滚", "category": "movement", "cost": 3.0, "effect": "翻滚期间躲避伤害\n可同时接一张攻击"},
	"blink": {"name": "短距闪现", "category": "movement", "cost": 3.0, "effect": "向输入方向闪现\n无法穿过墙体"},
	"jet_jump": {"name": "喷射跃升", "category": "movement", "cost": 2.0, "effect": "向上喷射跃升\n可接空中动作"},
	"dash_slash": {"name": "突进出拳", "category": "hybrid", "cost": 5.0, "effect": "快速向前突进\n接近敌人后出拳"},
	"airborne_slash": {"name": "腾空斩", "category": "hybrid", "cost": 4.0, "effect": "起跳向前挥斩\n可接俯冲重斩"},
	"dive_slash": {"name": "俯冲重斩", "category": "hybrid", "cost": 5.0, "effect": "腾空后向前俯冲\n落地造成范围伤害"},
}


static func kinds() -> Array[String]:
	return KINDS.duplicate()


static func has_kind(kind: String) -> bool:
	return CARDS.has(kind)


static func get_card(kind: String) -> Dictionary:
	if not has_kind(kind):
		return {}
	var card: Dictionary = CARDS[kind].duplicate(true)
	card["kind"] = kind
	card["color"] = accent(kind)
	return card


static func card_name(kind: String) -> String:
	return str(CARDS.get(kind, {}).get("name", "未知动作"))


static func category(kind: String) -> String:
	return str(CARDS.get(kind, {}).get("category", ""))


static func category_name(kind: String) -> String:
	match category(kind):
		"movement": return "位移"
		"hybrid": return "复合"
		"attack": return "攻击"
		_: return "未知"


static func cost(kind: String) -> float:
	return float(CARDS.get(kind, {}).get("cost", 0.0))


static func accent(kind: String) -> Color:
	match category(kind):
		"movement": return Color("81ceff")
		"hybrid": return Color("c8a5ff")
		"attack": return Color("ffad68")
		_: return Color("8ca5b6")


static func effect(kind: String) -> String:
	return str(CARDS.get(kind, {}).get("effect", ""))
