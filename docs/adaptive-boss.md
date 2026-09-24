# 自适应最终 Boss

`boss_brain.gd` 把分析与实时战斗分成三层。它不读取玩家手牌、抽牌堆或未来随机数，只观察已经发生的动作和当前公开状态。

## 三层职责

1. **世界模型（每张牌和每个物理 tick）**
   - 接收 `Player.action_played(kind, cost)`、`action_attempted`、`damaged`、`cybernetic_changed`。
   - 保留最近 40 张已接受的动作；动作按 8 秒半衰期加权。
   - 计算攻击/位移/复合比例、能量投入、失败尝试、动作转移和连招，例如 `roll->slash`。
   - `snapshot()` 返回可保存或序列化的摘要。

2. **策略摘要（低频、可选）**
   - `get_llm_context()` 只提供紧凑摘要、当前策略和 FSM 状态。
   - `adaptive_boss_runtime.gd` 默认每 12 秒异步发送一次摘要；样本不足四次时不会发送。
   - 检测到根目录 `key.txt` 时，运行时使用 EvoMap 的 OpenAI-compatible 接口和 `evomap-gemini-3.1-pro-preview`；也可以在 `user://llm_config.json` 中配置其它兼容服务。
   - 模型只返回有限 JSON，例如：

     ```json
     {"aggression": 0.8, "exploration_rate": 0.2, "roll_response": "evade"}
     ```

   - `llm_bridge.gd` 校验 JSON、白名单和数值范围；网络等待期间实时帧不会等待 LLM，失败时继续使用本地规则。

3. **本地反应 FSM（每个物理 tick）**
   - `plan_reaction()` 是无副作用的纯规划接口。
   - 学到 `roll->攻击` 且玩家当前能量足够时，按当前策略返回 `evade` 或 `disengage`，并附带可解释原因；翻滚但能量不足时保持观察。
   - 通过 `reaction_requested(reaction, payload)` 将意图交给 Boss 控制器。Boss 自己决定移动、攻击和碰撞，不把脑的意图当作伤害判定。

## 接入现有场景

当前 `main.gd` 和默认的 `floor_one.gd` 已经自动创建并绑定脑。进入 Boss 战时，`adaptive_boss_runtime.gd` 会连接玩家、Boss、行为观察器和异步桥接器；重新生成第一层或重置决战会取消旧请求并清空本局画像。训练敌人只保存 `adaptive_reaction` 和 payload，不改变固定战斗逻辑；最终 Boss 才会把有限反应意图交给本地战斗状态机。

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

Boss 或玩家在本地攻击结算后可反馈结果：

```gdscript
boss_brain.record_action_outcome("slash", "hit")
boss_brain.record_event("dodge_success", {"attack": "enemy_slash"})
```

## EvoMap 配置与密钥

开发目录中的 `key.txt` 应只保存完整的 `sk-evomap-...` token，一行即可。它已被 `.gitignore` 忽略，桥接器只在发起请求时读取并直接作为 `Authorization: Bearer` 值使用，不会把密钥放进世界模型、导出报告或 `user://llm_config.json`。如果不希望把密钥放在项目目录，可以把 token 放到 `user://evomap.key`，或通过 `api_key_env` 指定环境变量名。

EvoMap 的默认请求地址是 `https://api.evomap.ai/v1/chat/completions`，默认省略可选的 `response_format` 字段以匹配公开 curl 协议。自定义 OpenAI-compatible 配置可用 `response_format: true/false` 控制该字段。模型响应必须是只包含 `summary` 和 `directive` 的 JSON；任何解析失败、超时或越界策略都会被丢弃，Boss 保持上一次有效策略或本地规则。

## 验证

`tests/test_boss_brain.gd` 不加载主场景，使用玩家代理验证动作学习、`roll->slash` 识别、能量门槛、FSM 白名单和策略边界；`tests/test_llm_bridge.gd` 使用回环 HTTP 服务验证请求、取消、超时和响应校验，不调用真实 EvoMap。这样即使没有网络或密钥，最终 Boss 仍然能用固定的本地 FSM 工作。
