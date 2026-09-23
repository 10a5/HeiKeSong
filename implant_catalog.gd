extends RefCounted
## Accessory definitions shared by the shop, equipment view and inventory.

const KINDS: Array[String] = [
	"hand_slot", "damage", "armor", "move_speed", "energy_capacity", "energy_regen"
]
const ITEMS: Dictionary = {
	"hand_slot": {"name": "认知扩展器", "effect": "可同时持有的卡牌槽位 +1", "price": 36, "sell_price": 18, "color": Color("b9a3ff")},
	"damage": {"name": "肌束增幅器", "effect": "所有攻击伤害 +20%", "price": 30, "sell_price": 15, "color": Color("ffae74")},
	"armor": {"name": "皮下缓冲层", "effect": "受到的伤害减少 20%\n减伤先于护盾结算", "price": 30, "sell_price": 15, "color": Color("75d5ee")},
	"move_speed": {"name": "神经疾行器", "effect": "普通移动速度 +20%\n可叠加 Q 爆发加速", "price": 24, "sell_price": 12, "color": Color("89ecc0")},
	"energy_capacity": {"name": "储能核心", "effect": "能量上限 +20%", "price": 24, "sell_price": 12, "color": Color("ebd278")},
	"energy_regen": {"name": "循环充能器", "effect": "能量恢复速率 +20%", "price": 28, "sell_price": 14, "color": Color("a0e78a")},
}


static func kinds() -> Array[String]:
	return KINDS.duplicate()


static func has_kind(kind: String) -> bool:
	return ITEMS.has(kind)


static func get_item(kind: String) -> Dictionary:
	if not has_kind(kind):
		return {}
	var item: Dictionary = ITEMS[kind].duplicate(true)
	item["kind"] = kind
	return item
