# Godot 最小动作卡牌 Demo 指南

> 目标：先做出一个能运行的 **2D 俯视 Demo**：`WASD` 移动，按 `1` 打出“劈砍牌”，按 `2` 打出“翻滚牌”，两张牌消耗能量，能量随时间恢复。
>
> 本指南以 **Godot 4.x** 为准。所有速度、费用和持续时间都只是原型测试起点，不是最终平衡。

---

## 0. 严格限定范围

### 这次必须做

- WASD 八方向移动
- 玩家朝向跟随最后一次移动方向
- `1`：消耗 2 点能量，显示一次劈砍
- `2`：消耗 3 点能量，沿当前输入方向或朝向翻滚
- 0–10 能量条，以每秒 2 点恢复
- 能量不足时动作不执行，并显示提示
- 玩家不能走出窗口

### 这次明确不做

- 不做抽牌、洗牌、弃牌与随机手牌
- 不做敌人、伤害、血量与命中判定
- 不做无敌帧、硬直、连段与动画树
- 不做义体、Boss、幻境、肉鸽地图与奖励
- 不做正式卡牌美术、音效、存档和 LLM

这个版本的“卡牌”只是两个固定卡槽：`1 = 劈砍牌`，`2 = 翻滚牌`。先验证“按牌键触发动作并消耗实时能量”是否顺手。

---

## 1. 新建项目

1. 打开 Godot，创建项目，例如 `NeuralFracturePrototype`。
2. 渲染器选 **Compatibility** 即可。
3. 在 **Project → Project Settings → Display → Window** 中设置：
   - Viewport Width：`960`
   - Viewport Height：`540`
   - Window Width Override：`960`
   - Window Height Override：`540`
4. 在 **Rendering → Environment → Default Clear Color** 中选一个深色背景。

建议目录：

```text
res://
  main.tscn
  player.gd
```

---

## 2. 配置 Input Map

打开 **Project → Project Settings → Input Map**，添加以下 6 个 Action：

| Action | 按键 |
|---|---|
| `move_left` | A |
| `move_right` | D |
| `move_up` | W |
| `move_down` | S |
| `card_slash` | 1 |
| `card_roll` | 2 |

注意：输入名称必须与上表完全一致，包括下划线和大小写。

---

## 3. 创建场景树

新建一个 **2D Scene**，根节点改名为 `Main`，然后创建以下结构：

```text
Main (Node2D)
├── Player (CharacterBody2D)
│   ├── Body (Polygon2D)
│   ├── CollisionShape2D (CollisionShape2D)
│   └── SlashVisual (Polygon2D)
└── HUD (CanvasLayer)
    └── Margin (MarginContainer)
        └── VBox (VBoxContainer)
            ├── HelpLabel (Label)
            ├── EnergyBar (ProgressBar)
            ├── EnergyLabel (Label)
            └── StatusLabel (Label)
```

保存为 `res://main.tscn`。

### 3.1 设置 Player

选中 `Player`：

- Position：`(480, 270)`

选中 `Body`，在 Inspector 的 `Polygon` 中创建一个简单方形。四个点可以是：

```text
(-16, -16)
( 16, -16)
( 16,  16)
(-16,  16)
```

给它一个容易看见的颜色。

选中 `CollisionShape2D`：

- Shape 新建 `RectangleShape2D`
- Size：`(32, 32)`

选中 `SlashVisual`，设置四个 Polygon 点：

```text
(18, -20)
(56, -10)
(56,  10)
(18,  20)
```

然后：

- 颜色设为亮橙色或亮黄色
- `Visible` 取消勾选

这个多边形会作为最小的“劈砍特效”，它不负责伤害。

### 3.2 设置 HUD

选中 `Margin`：

- Layout → Anchors Preset → **Top Left**
- Theme Overrides → Constants：可以给四个 Margin 都填 `16`

选中 `HelpLabel`，Text：

```text
WASD 移动｜1 劈砍牌（2 能量）｜2 翻滚牌（3 能量）
```

选中 `EnergyBar`：

- Min Value：`0`
- Max Value：`10`
- Value：`10`
- Custom Minimum Size：`(360, 24)`
- Show Percentage：关闭

选中 `EnergyLabel`，Text：

```text
能量 10.0 / 10.0
```

选中 `StatusLabel`，Text：

```text
状态：准备
```

> 节点名称必须与场景树一致，因为脚本会按这些路径寻找 HUD。

---

## 4. 创建 `player.gd`

选中 `Player`，点击 **Attach Script**，保存为 `res://player.gd`，然后用以下内容完整替换：

```gdscript
extends CharacterBody2D

# 所有数值都只是原型测试起点。
@export var move_speed: float = 220.0
@export var roll_speed: float = 560.0
@export var roll_duration: float = 0.22

@export var max_energy: float = 10.0
@export var energy_regen_per_second: float = 2.0
@export var slash_cost: float = 2.0
@export var roll_cost: float = 3.0
@export var slash_visual_duration: float = 0.14

@onready var body: Polygon2D = $Body
@onready var slash_visual: Polygon2D = $SlashVisual
@onready var energy_bar: ProgressBar = $"../HUD/Margin/VBox/EnergyBar"
@onready var energy_label: Label = $"../HUD/Margin/VBox/EnergyLabel"
@onready var status_label: Label = $"../HUD/Margin/VBox/StatusLabel"

var energy: float = 10.0
var facing: Vector2 = Vector2.RIGHT

var is_rolling: bool = false
var roll_direction: Vector2 = Vector2.RIGHT
var roll_time_left: float = 0.0
var slash_time_left: float = 0.0


func _ready() -> void:
    energy = max_energy
    slash_visual.visible = false
    energy_bar.min_value = 0.0
    energy_bar.max_value = max_energy
    _update_hud("准备")


func _process(delta: float) -> void:
    # 能量一直随时间恢复。
    energy = minf(max_energy, energy + energy_regen_per_second * delta)

    # 到时间后隐藏劈砍特效。
    if slash_time_left > 0.0:
        slash_time_left -= delta
        if slash_time_left <= 0.0:
            slash_visual.visible = false

    _update_energy_display()


func _physics_process(delta: float) -> void:
    var input_direction := Input.get_vector(
        "move_left",
        "move_right",
        "move_up",
        "move_down"
    )

    if input_direction != Vector2.ZERO and not is_rolling:
        facing = input_direction.normalized()
        body.rotation = facing.angle()

    # 翻滚期间暂时不接收普通移动和其他牌。
    if is_rolling:
        roll_time_left -= delta
        velocity = roll_direction * roll_speed
        move_and_slide()
        _clamp_to_viewport()

        if roll_time_left <= 0.0:
            is_rolling = false
            body.modulate = Color.WHITE
            _update_hud("翻滚结束")
        return

    # 翻滚牌优先于劈砍牌。
    if Input.is_action_just_pressed("card_roll"):
        if _try_spend_energy(roll_cost):
            roll_direction = input_direction.normalized() if input_direction != Vector2.ZERO else facing
            facing = roll_direction
            body.rotation = facing.angle()
            is_rolling = true
            roll_time_left = roll_duration
            body.modulate = Color(0.45, 0.85, 1.0)
            velocity = roll_direction * roll_speed
            move_and_slide()
            _clamp_to_viewport()
            _update_hud("打出：翻滚牌")
        else:
            _update_hud("能量不足：翻滚需要 %.0f" % roll_cost)
        return

    if Input.is_action_just_pressed("card_slash"):
        if _try_spend_energy(slash_cost):
            slash_visual.rotation = facing.angle()
            slash_visual.visible = true
            slash_time_left = slash_visual_duration
            _update_hud("打出：劈砍牌")
        else:
            _update_hud("能量不足：劈砍需要 %.0f" % slash_cost)

    velocity = input_direction * move_speed
    move_and_slide()
    _clamp_to_viewport()


func _try_spend_energy(cost: float) -> bool:
    if energy < cost:
        return false

    energy -= cost
    _update_energy_display()
    return true


func _clamp_to_viewport() -> void:
    var viewport_size := get_viewport_rect().size
    global_position.x = clampf(global_position.x, 16.0, viewport_size.x - 16.0)
    global_position.y = clampf(global_position.y, 16.0, viewport_size.y - 16.0)


func _update_energy_display() -> void:
    energy_bar.value = energy
    energy_label.text = "能量 %.1f / %.1f" % [energy, max_energy]


func _update_hud(message: String) -> void:
    _update_energy_display()
    status_label.text = "状态：" + message
```

---

## 5. 设置主场景并运行

1. 按 `F6` 运行当前场景；或者按 `F5` 后选择 `main.tscn` 作为主场景。
2. 使用 WASD 移动。
3. 面朝一个方向时按 `1`，前方应短暂显示橙色劈砍块，能量减少 2。
4. 按住方向键再按 `2`，玩家应快速向该方向翻滚，能量减少 3。
5. 不按方向键时按 `2`，玩家应沿最后朝向翻滚。
6. 连续出牌把能量耗空，能量不足时动作不执行。
7. 等待几秒，能量应以每秒 2 点恢复。

---

## 6. 10 分钟自测清单

- [ ] W、A、S、D 都能移动，斜向移动没有明显加速
- [ ] 玩家最后移动方向能决定劈砍方向
- [ ] 按 `1` 只扣 2 点能量
- [ ] 劈砍特效约 0.14 秒后自动消失
- [ ] 按 `2` 只扣 3 点能量
- [ ] 翻滚期间普通移动不会改变翻滚方向
- [ ] 不按移动键时也能沿最后朝向翻滚
- [ ] 能量不足时不会继续扣成负数
- [ ] 能量能恢复，但不会超过 10
- [ ] 玩家无法移动出 960×540 的窗口
- [ ] 可以连续运行 3 分钟，没有脚本报错
- [ ] 可以停止并重新运行，状态会恢复为 10 能量

---

## 7. 最小通过标准

只有下面全部满足，才算这个 Demo 完成：

1. **可启动**：运行 `main.tscn` 后没有红色脚本错误。
2. **可移动**：WASD 能稳定控制玩家，斜向速度与横向速度一致。
3. **可出牌**：`1` 和 `2` 能触发两个明显不同的动作。
4. **有资源约束**：两张牌消耗不同能量，能量不足时无法使用。
5. **可恢复**：能量自动恢复到 10，但不超过 10。
6. **可重玩**：停止后重新运行，Demo 状态正常重置。

这一步不验证“战斗是否好玩”，只验证以下最小闭环是否成立：

```text
移动 → 选择动作牌 → 消耗能量 → 看到动作反馈 → 等待能量恢复 → 再出牌
```

---

## 8. 常见错误排查

### 报错：`Input action ... doesn't exist`

原因：Input Map 的名称没有完全对应。检查是否准确创建了：

```text
move_left
move_right
move_up
move_down
card_slash
card_roll
```

### 报错：找不到 `EnergyBar`、`EnergyLabel` 或 `StatusLabel`

原因：HUD 节点名称或层级与指南不同。检查完整路径：

```text
Main/HUD/Margin/VBox/EnergyBar
Main/HUD/Margin/VBox/EnergyLabel
Main/HUD/Margin/VBox/StatusLabel
```

### 玩家看不见

检查：

- `Player` 是否位于 `(480, 270)`
- `Body` 是否真的设置了 Polygon 点
- `Body` 颜色是否与背景区分明显
- `Body.visible` 是否开启

### 劈砍没有显示

检查：

- `SlashVisual` 是否设置了 Polygon 点
- 它是否为 `Player` 的直接子节点
- 它的颜色是否可见
- 脚本是否挂在 `Player`，而不是 `Main`

### 翻滚方向不对

`Input.get_vector()` 会自动归一化斜向输入；不要再把 X、Y 速度分别叠加，否则斜向可能变快。

### Godot 3 代码不能直接套用

本指南是 Godot 4 API：

- 使用 `CharacterBody2D`，不是 `KinematicBody2D`
- 直接设置内置属性 `velocity`
- 使用无参数的 `move_and_slide()`
- 使用 `await`，不是旧版 `yield`

---

## 9. 完成后只做一个下一步

当本指南的 6 条通过标准全部满足后，下一步只建议增加：

> 一个静止木桩 + 劈砍命中区域 + 木桩扣血反馈。

先不要增加随机抽牌。只有当“移动、劈砍、翻滚、能量”本身已经稳定，再把两个固定卡槽替换成真正的手牌系统。
