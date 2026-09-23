# 自适应最终 Boss 原型

`boss_brain.gd` 把分析与实时战斗分成三层。它不读取玩家手牌、抽牌堆或未来随机数，只观察已经发生的动作和当前公开状态。

## 三层职责

1. **世界模型（每张牌和每个物理 tick）**
   - 接收 `Player.action_played(kind, cost)`、`action_attempted`、`damaged`、`cybernetic_changed`。
   - 保留最近 40 张已接受的动作；动作按 8 秒半衰期加权。
   - 计算攻击/位移/复合比例、能量投入、失败尝试、动作转移和连招，例如 `roll->slash`。
   - `snapshot()` 返回可保存或序列化的摘要。

2. **策略摘要（低频、可选）**
   - `get_llm_context()` 只提供紧凑摘要、当前策略和 FSM 状态。
   - 外部 LLM 可以每 10～30 秒返回有限 JSON，例如：

     ```json
     {"aggression": 0.8, "exploration_rate": 0.2, "roll_response": "evade"}
     ```

   - `apply_llm_directive()` 校验白名单、限制数值范围；实时帧不会等待 LLM。

3. **本地反应 FSM（每个物理 tick）**
   - `plan_reaction()` 是无副作用的纯规划接口。
   - 学到 `roll->攻击` 且玩家当前能量足够时返回 `evade`，并附带 `punish_after: roll_recovery`；翻滚但能量不足时保持观察。
   - 通过 `reaction_requested(reaction, payload)` 将意图交给 Boss 控制器。Boss 自己决定移动、攻击和碰撞，不把脑的意图当作伤害判定。

## 接入现有场景

当前 `main.gd` 和默认的 `floor_one.gd` 已经自动创建并绑定脑：第一层重新生成街区时会清空本局画像，并把当前街道敌人作为距离上下文重新绑定。训练敌人只保存 `adaptive_reaction` 和 payload，不改变固定战斗逻辑，方便先验证画像而不改变基线手感。

```gdscript
const BOSS_BRAIN = preload("res://boss_brain.gd")
var boss_brain: AdaptiveBossBrain

func attach_brain(player: Node, final_boss: Node) -> void:
    boss_brain = BOSS_BRAIN.new()
    add_child(boss_brain)
    boss_brain.attach_player(player)
    boss_brain.reaction_requested.connect(final_boss.apply_reaction)
```

运行中可以从场景节点读取 `boss_brain.snapshot()`，也可以读取 `boss_brain.get_llm_context()` 作为外部 LLM 的输入。`snapshot.actions_seen` 是当前 40 张动作窗口，`total_actions_seen` 是本次观察会话累计样本数。

Boss 在攻击结算后可反馈结果：

```gdscript
boss_brain.record_action_outcome("slash", "hit")
boss_brain.record_event("dodge_success", {"attack": "enemy_slash"})
```

## 验证

`tests/test_boss_brain.gd` 不加载主场景，使用玩家代理验证动作学习、`roll->slash` 识别、能量门槛、FSM 白名单和 LLM 策略边界。这样即使没有 LLM 或 profiler，最终 Boss 仍然能用固定的本地 FSM 工作。
