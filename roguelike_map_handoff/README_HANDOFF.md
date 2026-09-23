# 肉鸽地图场景交接 —— ActualBuildingBridgePreview（分散城区 + 随机桥网）

> 交接对象：`res://scenes/ActualBuildingBridgePreview.tscn`
> 交接范围：地图生成全链（灰盒桥网 → 实际建筑 → 分散城区/服务点 → 真实桥模型）
> 引擎环境：Godot 4.7.2-stable（Forward+ / Jolt Physics / Windows D3D12）
> 交接时间：2026-09-23
> 本文件在项目内同步一份：`ROGUELIKE_MAP_HANDOFF.md`（本包内为 `README_HANDOFF.md`）

---

## 1. 30 秒结论

**8×8 网格（12m/格）的赛博街区：20 栋真实建筑模型与地面道路固定不动；楼与楼之间的桥网按 `seed` 随机生成，且用最小生成树保证 20 栋始终全连通。另有 2 个商店 + 2 个医疗点，以及唯一的逻辑起点/终点。**

| 项目 | 值 |
|---|---|
| 建筑 | 20 栋 GLB 实例（8 种资源，其中 2 商店 + 2 医疗点） |
| 网格 | 8×8，格宽 12m；建筑中心 = `((x-3.5)×12, ?, (y-3.5)×12)`，即坐标 ∈ {-42,-30,…,42} |
| 地面道路 | **固定**：主路宽 6m（x=3 列、z=2/4 行），小巷 2.8m；38 个道路格、44 段路面、1 处死巷 |
| 桥网 | **随 seed 变化**：22–26 条连接，Kruskal 生成树保证连通，可含 dogleg 折线 |
| 桥面标高 | 统一 Y=8m（桥面顶面 8.000，厚 0.25，宽 2.2） |
| 桥端接口 | 端点固定在距建筑中心 4.8m 的方形环上（对应 8m 立面环梁） |
| 服务点 | 商店 z=-42 / z=6，医疗点 z=-18 / z=30，全部沿主路 x=-6 |
| 起点 / 终点 | 逻辑坐标 (-6, 0.2, 42) / (-6, 0.2, -42)；**当前只有 meta，没有任何可视标记和边界墙** |
| 随机性契约 | 同 seed → 逐边完全一致的桥网；建筑、道路、服务点跨 seed 固定 |
| 场景内参考 seed | **20260923**（26 条桥） |
| 实测 seed 分布 | 20260923–20260927 → 26 / 26 / 24 / 24 / 22 条桥 |

配图（本包内）：`preview_overview.png`（编辑器 cinematic 视角）、`preview_runtime.png`（F6 运行 + 左上角控制面板）。

---

## 2. 拿到包后 3 分钟跑起来

1. 把 `drop_in/` 下的 `scenes/`、`tools/`、`tests/` 三个目录**整体拷进你的 Godot 项目根目录**（覆盖同名文件；路径结构就是 `res://` 结构）。
2. 确认项目根目录已有依赖的 GLB 模型（见 §5，共 9 个，约 329MB）。缺模型不会报错，但对应建筑/桥会是空的。
3. 编辑器里打开 `res://scenes/ActualBuildingBridgePreview.tscn`，按 **F6**（运行当前场景，不要用 F5）。

运行后左上角是控制面板，按键：

| 键 / 操作 | 作用 |
|---|---|
| `R` / Random 按钮 | 换随机 seed，重建桥网 |
| `N` / `P` | 下一个 / 上一个 seed（±1） |
| 输入框 + `Apply seed` / 回车 | 复现指定 seed |
| `B` / Toggle bridges | 显示/隐藏桥与 8m 接口板 |
| `V` | 显示/隐藏实际建筑（会露出 12m 占位格） |
| `T` / `O` | 俯视 / 概览视角 |
| 右键拖动 / 滚轮 | 旋转 / 缩放 |

> 运行时切换 seed **不会**回写场景文件；编辑器里保存的场景固定为 seed 20260923。

重新生成场景（当前没有命令行入口，需要在编辑器内调用脚本）：

- 实际建筑场景：调用 `tools/build_actual_building_preview.gd` 的 `build()`。它基于 `scenes/GrayboxBridgeRoadPreview.tscn` 起壳，用 `actual_bridge_geometry.create(20260923)` 生成内容，并**覆盖保存** `scenes/ActualBuildingBridgePreview.tscn`（seed 在代码里写死 20260923）。
- 灰盒场景：调用 `tools/build_graybox_preview.gd` 的 `build(seed)`，覆盖保存 `scenes/GrayboxBridgeRoadPreview.tscn`。

---

## 3. 文件职责与继承链

### 3.1 继承链（读代码请从下往上）

```
桥网规划
graybox_layout.gd                灰盒布局 + 桥网规划算法（种子核心：候选边、噪声权重、Kruskal、加边）
└─ dispersed_city_layout.gd      换成 20 格分散坐标 + 4 个服务格 + 起终点常量

几何构建
graybox_geometry.gd              材质/box/segment/text 工具 + create(seed) 主入口（灰盒全部几何）
└─ actual_building_geometry.gd   实例化 20 栋真实建筑 + 8m 立面环梁与 4 根立柱
   └─ dispersed_city_geometry.gd 分散布局差异 + 服务点装饰 + 起终点 meta（不再建 Navigation/边界墙）
      └─ actual_bridge_geometry.gd 把灰盒桥面替换成 重置桥.glb 实例

预览交互
graybox_preview_controls.gd      预览 UI / 相机 / seed 切换 / 显隐
└─ actual_building_controls.gd   覆盖为：换 seed 时保留建筑实例、V 键切换建筑

生成入口（RefCounted，需被调用）
build_graybox_preview.gd         → scenes/GrayboxBridgeRoadPreview.tscn
build_actual_building_preview.gd → scenes/ActualBuildingBridgePreview.tscn

测试
tests/test_graybox_preview.gd         suite = graybox_preview
tests/test_dispersed_city_services.gd suite = dispersed_city_services
tests/test_actual_buildings.gd        suite = actual_buildings（当前失败，见 §7）
tests/build_seven_building_map.gd     不属于本链；被 test_actual_buildings 当几何工具库用（取三角形/AABB）
```

### 3.2 场景树（保存态，seed 20260923 的实际子节点数）

```
ActualBuildingBridgePreview (Node3D, script=actual_building_controls.gd)
├─ WorldEnvironment / Key(DirectionalLight3D) / OverviewCamera(Camera3D, current)
└─ Generated (Node3D, meta: seed / bridge_count=26 / real_building_count=20 /
   │           service_count=4 / start_count=1 / goal_count=1 /
   │           indicators_removed / boundary_walls_removed)
   ├─ Base                        100×100 地板（**无碰撞**，见 §7）
   ├─ Grid                        网格线 + A–H / 1–8 坐标标签
   ├─ BuildingSites_20       (20) 12×12 占位板（visible=false，标签已删）
   ├─ SocketDatums           (40) 每格 9.6×9.6×0.24 的 8m 接口板 + 同级静态碰撞
   ├─ FixedRoads            (198) 路口 + 主路/小巷段 + 车道虚线 + 死巷标签
   ├─ Bridges                (26) 每条边一组 B%02d_to_B%02d（meta: from/to/backbone/actual_bridge/asset）
   ├─ BridgeJunctions         (2) 不同边桥面交叉处的通行路口方块
   ├─ EnemyRoutePreview      (11) 沿主路的巡逻线示意（**纯视觉，不是 AI**）
   ├─ ActualBuildings        (20) 真实建筑模型实例（meta: site_id/tone/asset/height）
   ├─ FacadeSupports         (20) 每栋 4 根立柱 + 四面 8m 环梁
   └─ ServicePoints           (4) 服务点：接驳段 + 招牌柱 + "SHOP"/"MED +" 标签
```

---

## 4. 生成管线：从 seed 到场景

### 4.1 `layout.plan(seed)` —— 桥网与道路

**候选边**：任意两栋建筑中心距 ≤ 53m；两端做 `socket()`（沿方向取 4.8m，用切比雪夫归一化后落在方形环上）；`clear_path()` 要求路径不与任何**第三栋**建筑的 12m 格安全区（half = 5.95m）相交。

**噪声权重**：`FastNoiseLite`，`TYPE_PERLIN`，frequency `0.18`，`fractal_octaves` `3`；采样点 `(mid.x, mid.y, (i+j)*0.31)`，`mid=(a+b)/24`；映射到 [0,1] 得 `density`。

**代价**：`cost = length × (1.35 − density) + rand(0, 9)`（RNG 与噪声同 seed）。

**折角**：两端 `|dx|>14 且 |dz|>14 且 density>0.43` 且 `rng<0.5` → 插入一个直角拐点（`shape="elbow"`）。

**主干**：按 cost 升序做 Kruskal 并查集 → 20 节点连通树（`backbone=true`，场景中为青色）。

**支路**：继续按序加边，直到总数达到 `rand(22..26)`；每点度数上限 4；接受概率 `clamp(0.25 + density×0.7)`（`backbone=false`，琥珀色）。

**dogleg**：对仍是直连的边以 42% 概率插入 1.2–2.8m 侧向偏移的中间点。

**道路（与 seed 无关）**：8×8 中排除建筑格，从中心 `(3,3)` 四邻域 flood fill 得到 38 个道路格；`avenue(c) = c.x==3 或 c.y∈{2,4}` → 主路 6m，否则小巷 2.8m；`dead_end_rules` 阻断 `(1,0)–(1,1)` 之间连接形成死巷。

返回：`{seed, edges, roads, streets, dead_ends, degree, connected}`。

**参考 seed 20260923 实测**（运行时求值，dispersed 布局）：

| 指标 | 值 |
|---|---|
| 桥连接数 edges | 26 |
| 桥面段数 segments | 29 |
| 多段边（dogleg） | 3（elbow 0） |
| 道路格 / 路面段 / 死巷 | 38 / 44 / 1 |
| 度数分布 | 1度×2、2度×9、3度×4、4度×5（Σ=52=2×26 ✓） |
| connected | true |

### 4.2 `geometry.create(seed)` —— 场景树

- `Base` 100×100×0.8 地板（注意：**未创建碰撞**）。
- `Grid`：9+9 条网格线 + A–H / 1–8 标签。
- `BuildingSites_20`：20 个 12×12 占位板 + 标签（真实建筑链路里会被隐藏/删标签）。
- `SocketDatums`：每格一块 9.6×9.6×0.24 的 8m 接口板，`solid=true`（碰撞体是网格的**同级兄弟节点**，命名 `<网格名>Collision`）。
- `FixedRoads`：路口方块 + 路面段 + 主路车道虚线；死巷写 `DEAD END` 标签。
- `Bridges`：每条边一个组；每段 `Deck`（中心 y=8−0.125=7.875 → **顶面 8.0**，宽 2.2，厚 0.25，带碰撞）+ 每个点一个 `Joint` 方块（2.2×0.25×2.2）。
- `BridgeJunctions`：不同边的桥面 2D 线段相交处补 2.3×0.2×2.3 路口方块（同标高可通行）。
- `EnemyRoutePreview`：沿 x=-6 主路的 7 段示意线 + 4 个标记。

### 4.3 `actual_building_geometry.populate(root)` —— 真实建筑

- 明暗交替：`is_dark(i)` 覆写为 `i%2==0`；`DARK` 池 = [居民楼3, 工厂1, 居民楼4k, 居民楼2]，`BRIGHT` 池 = [居民楼5, 居民楼4, 商店]，各自循环取用。
- 缩放：水平 `factor = 9.0 / max(size.x, size.z)`（保证不越 12m 格）；高度 12m（偶数位）/ 16m（奇数位）。
- 位置：模型中心对齐格心，底面贴地 `y=0`；写入 meta `site_id / tone / asset / height`。
- `FacadeSupports`：每栋 4 根 0.2×7.76×0.2 立柱（±4.45，从地面顶到 7.76m）+ 四面 9.1×0.22×0.22 的 8m 环梁（y=7.65）。**桥端接口就落在这个环上。**
- 收尾：隐藏 `BuildingSites_20`，删除 `SocketDatums` 下的 `Label3D`。

### 4.4 `dispersed_city_geometry` —— 分散布局与服务点

- 布局换成 `dispersed_city_layout`：20 格 `DISTRIBUTED` 分散坐标（减少连续堆楼），`SERVICES` 4 格，`START=(3,7)`、`GOAL=(3,0)`。
- `choose_asset`：服务格强制用 `商店.glb` / `医疗点.glb`；非服务格若原本抽到商店则替换为 `居民楼4.glb`。
- `decorate`：每个服务点从临街立面拉一段 2.8m 宽接驳路到主路 x=-6，加 0.16×3.6×1.5 招牌柱 + `SHOP`（琥珀）/`MED +`（绿）标签。
- 写入 meta：`service_count=4 / service_spacing_m=24 / start_count=1 / goal_count=1 / indicators_removed / boundary_walls_removed`。**不再创建 Navigation 节点、不再建边界墙、不再画起点终点箭头。**

**建筑资源分配（与 seed 无关，20 栋固定）**

| 序号 | 格 | 资源 | 备注 |
|---|---|---|---|
| B01 | (0,0) | 居民楼3 | 暗 |
| B02 | (2,0) | 商店 | 服务点（z=-42） |
| B03 | (6,0) | 工厂1 | 暗 |
| B04 | (5,1) | 居民楼4 | 亮 |
| B05 | (7,1) | 居民楼4k | 暗 |
| B06 | (0,2) | 居民楼4 | 亮（原抽到商店，已替换） |
| B07 | (4,2) | 医疗点 | 服务点（z=-18） |
| B08 | (6,2) | 居民楼5 | 亮 |
| B09 | (1,3) | 居民楼3 | 暗 |
| B10 | (7,3) | 居民楼4 | 亮 |
| B11 | (0,4) | 工厂1 | 暗 |
| B12 | (2,4) | 商店 | 服务点（z=6） |
| B13 | (5,4) | 居民楼4k | 暗 |
| B14 | (1,5) | 居民楼5 | 亮 |
| B15 | (6,5) | 居民楼2 | 暗 |
| B16 | (0,6) | 居民楼4 | 亮 |
| B17 | (4,6) | 医疗点 | 服务点（z=30） |
| B18 | (7,6) | 居民楼4 | 亮（原抽到商店，已替换） |
| B19 | (2,7) | 工厂1 | 暗 |
| B20 | (5,7) | 居民楼5 | 亮 |

### 4.5 `actual_bridge_geometry` —— 真实桥模型

- `replace_bridges`：把每条边的灰盒 `Deck`/`Joint`/碰撞删掉，按原 `Deck` 的位置/方向/长度用 `重置桥 .glb` 重建。
- 对齐数学：常量 `BRIDGE_BASIS`（模型自带斜轴旋转）、`BRIDGE_CENTER`（模型几何中心）；`scale_vec = (段长/107.5178375, 0.13, 0.13)`；`transform = placement × BRIDGE_BASIS.scaled(scale_vec)`，再把模型中心平移到段中点上方 1.15m。
- 每段写 meta `actual_bridge=true` / `asset`。
- ⚠️ 这一步当前有已知缺陷（碰撞丢失、多段边缺半截），见 §7 P0-2。

---

## 5. 本包内容 / 未包含的依赖

### 5.1 包内文件（`drop_in/` 直接对应 `res://`）

| 包内路径 | 目标路径 | 说明 |
|---|---|---|
| `drop_in/scenes/ActualBuildingBridgePreview.tscn` | `res://scenes/` | 主交接场景（seed 20260923，26 桥） |
| `drop_in/scenes/GrayboxBridgeRoadPreview.tscn` | `res://scenes/` | 灰盒底座场景；**重建实际场景时是必需依赖** |
| `drop_in/tools/graybox_layout.gd` (+uid) | `res://tools/` | 桥网规划算法核心 |
| `drop_in/tools/graybox_geometry.gd` (+uid) | `res://tools/` | 灰盒几何与 create 入口 |
| `drop_in/tools/graybox_preview_controls.gd` (+uid) | `res://tools/` | 预览交互/相机 |
| `drop_in/tools/dispersed_city_layout.gd` (+uid) | `res://tools/` | 分散坐标 + 服务格 + 起终点 |
| `drop_in/tools/actual_building_geometry.gd` (+uid) | `res://tools/` | 真实建筑实例化 + 立面环梁 |
| `drop_in/tools/dispersed_city_geometry.gd` (+uid) | `res://tools/` | 服务点装饰 + 起终点 meta |
| `drop_in/tools/actual_bridge_geometry.gd` (+uid) | `res://tools/` | 真实桥模型替换 |
| `drop_in/tools/actual_building_controls.gd` (+uid) | `res://tools/` | 实际场景交互覆盖 |
| `drop_in/tools/build_graybox_preview.gd` (+uid) | `res://tools/` | 生成灰盒场景 |
| `drop_in/tools/build_actual_building_preview.gd` (+uid) | `res://tools/` | 生成实际场景 |
| `drop_in/tests/test_*.gd` (+uid) | `res://tests/` | 3 个测试套件 |
| `drop_in/tests/build_seven_building_map.gd` (+uid) | `res://tests/` | 几何工具库（被 actual_buildings 引用） |
| `reference/*` | 仅参考 | 既有 README 与验证 JSON 快照（**不要**当输入） |
| `preview_overview.png` / `preview_runtime.png` | 仅参考 | 编辑器视角 / 运行画面 |
| `MANIFEST.json` | — | 文件清单 + sha256 |

### 5.2 未打包的依赖（必须在你的项目里已存在）

| 依赖 | 规模 | 用途 / 备注 |
|---|---|---|
| `居民楼2.glb` | 25.3 MB | B15 |
| `居民楼3.glb` | 26.1 MB | B01、B09 |
| `居民楼4.glb` | 71.6 MB | B04、B06、B10、B16、B18 |
| `居民楼4k.glb` | 23.5 MB | B05、B13 |
| `居民楼5.glb` | 47.7 MB | B08、B14、B20 |
| `工厂1.glb` | 23.3 MB | B03、B11、B19 |
| `商店.glb` | 17.0 MB | B02、B12（服务点） |
| `医疗点.glb` | 69.8 MB | B07、B17（服务点） |
| `重置桥 .glb` | 24.4 MB | 全部随机桥（**注意文件名里有一个空格**） |
| 上述模型的贴图（`*_basecolor` / `*_normal` / `*_rm`） | 27 个文件 / 171 MB | GLB 同目录，默认导入设置即可 |
| `addons/godot_ai` | — | **只有跑测试需要**（测试基类 `res://addons/godot_ai/testing/test_suite.gd`） |
| `project.godot` 设置 | — | 物理引擎 Jolt、D3D12 驱动、主场景 `Main.tscn`（预览场景不需要改主场景） |

- 场景本身与 `Main.tscn`（Arena 战斗场景）**互不引用**，两边可独立开发；`GAME_DESIGN.md` 的战斗设计尚未与本地图接线。
- 预览交互只用 UI 按键，不依赖 project.godot 里的输入动作；只有接入玩家时才需要。

---

## 6. 验证结果（本次交接前实测）

测试入口：编辑器内 `godot_ai` 的 test runner（`test_run suite=<name>`）。项目已开着 `ActualBuildingBridgePreview.tscn`。

| 套件 | 结果 | 断言数 | 耗时 |
|---|---|---|---|
| `dispersed_city_services` | ✅ PASS（1 test） | 210 | 62 ms |
| `graybox_preview` | ✅ PASS（2 tests） | 1382（27 + 1355） | 62 ms |
| `actual_buildings` | ❌ FAIL（1 test） | 356（首个断言即失败） | 13.4 s |

- `dispersed_city_services` 覆盖：20 栋建筑、建筑间距 ≥11m、4 个服务点及其主路坐标、唯一起点/终点、可视标记与边界墙已移除、5 个 seed 的桥数范围。
- `graybox_preview` 覆盖：10 个 seed 各 19–26 桥、20 节点全连通、避障、端点落 4.8m 环、同 seed 可复现、道路跨 seed 固定、死巷保留、桥面碰撞随旋转对齐。
- `actual_buildings` 的失败是**断言期望值过期**（不是代码坏了），详见 §7 P1-3。

另外用运行时求值核实过：保存场景 = seed 20260923，26 桥；运行时按 `R` 换 seed 后桥数在 22–26 区间变化，建筑与道路位置不变。

> 提示：跑测试会重写 `tools/graybox_validation.json` 与 `tools/dispersed_city_validation.json`（内容等价，仅是重新生成的产物）。

---

## 7. 已知问题与建议修法（按优先级）

### 🔴 P0-1 运行时换 seed 会把建筑实例化两遍（已复现）

**证据**：F6 运行后，运行时树里 `Generated` 同时存在
`ActualBuildings`(20 个模型) 与 `@Node3D@334`(20 个模型)，`FacadeSupports`(20) 与 `@Node3D@335`(20)。
保存的场景文件本身是干净的（只有一套），所以**只在运行时会翻倍**，看编辑器树看不出来。

**原因**：`tools/actual_building_controls.gd` 的 `command()` 里
```gdscript
var fresh = base_geometry.create(seed_value)   # 内部经 actual_building_geometry.create() → populate() 已经建好这两组
for name in ["ActualBuildings","FacadeSupports"]:
    if old.has_node(name):
        fresh.add_child(...)                   # 再搬一份进来 → 同名冲突，Godot 给后来者改名
```
而 `set_buildings()` 用 `get_node("Generated/ActualBuildings")` 只切到其中一组，所以按 `V` 隐藏建筑时另一组仍在。

**影响**：每个 seed 切换后建筑模型实例/三角形/绘制调用翻倍（这批 GLB 本身很重，代价明显）；`V` 键行为不完整。

**建议修法（未改动代码，二选一）**：

- 简单版（保证正确）：搬入前先删掉 `fresh` 里已有的同名组
  ```gdscript
  for name in ["ActualBuildings","FacadeSupports"]:
      if fresh.has_node(name):
          fresh.get_node(name).free()
      if old.has_node(name):
          var n = old.get_node(name); old.remove_child(n); fresh.add_child(n)
  ```
- 推荐版（同时保住"不重复加载模型"的初衷）：给 `actual_building_geometry.create()` 加一个 `populate_models := true` 参数，`command()` 用 `base_geometry.create(seed_value, false)`，只走"搬运旧实例"这条路。

### 🔴 P0-2 真实桥模型没有碰撞；dogleg 边只生成半截桥面（已复现）

**证据**：
- 保存场景 `Generated/Bridges` 下：26 组、26 个 `UserResetBridge_NN` 模型，静态碰撞只剩 3 个孤儿 `Deck2Collision`。
- 运行态（随机 seed，24 组）：模型 24 个、孤儿 `Deck2Collision` 5 个、**真实桥模型内部 `StaticBody3D` 数量 = 0**。
- 布局求值：seed 20260923 有 3 条多段边（dogleg）。

**原因（两处，都在 `tools/actual_bridge_geometry.gd`）**：
1. `replace_bridges()` 删除了灰盒 `Deck` 及其 `DeckCollision`，但**没有给替换后的真实模型新建碰撞** → 所有桥面踩不上去。
2. 收集桥面时用 `g.find_children("Deck", "MeshInstance3D", ...)`，该匹配**不做前缀匹配**，所以第二段 `Deck2` 不被收集；随后第二段网格被通删，却不会重建 → dogleg 边的后半段**既没有模型也没有正确碰撞**（只留下一个位置不匹配的孤儿碰撞体）。

**影响**：接入玩家/敌人后，单段桥会踩空掉落；dogleg 桥有肉眼可见的断口。

**建议修法**：不要依赖节点名，直接用 `plan.edges[i].points` 逐段生成模型（每段一个 `重置桥` 实例，或对多段边生成一个自适应的分段网格），并为每段显式创建 `StaticBody3D + BoxShape3D`（尺寸 = 段长 × 0.25 × 2.2，随段旋转）。清理时按组的 meta 标记删除，而不是靠名字匹配。

### 🟠 P1-3 `actual_buildings` 测试期望值过期（当前唯一失败项）

`tests/test_actual_buildings.gd` 里三处需要改为新布局的真实值：

| 行 | 现断言 | 实际值 | 建议 |
|---|---|---|---|
| 11 | `FixedRoads` 子节点数 == 灰盒场景的值 | 实际 198；灰盒 248 | 道路已随 DISTRIBUTED 布局改变，与灰盒对比已无意义；建议改成按 `layout.plan(seed)` 推导期望值 |
| 12 | `Bridges` == 22 | **26**（seed 20260923） | 改为 `layout.plan(20260923).edges.size()` |
| 41 | `assets.size() == 7` | **8**（新增 `医疗点.glb`） | 改为 8，或从 `layout.SERVICES` 推导 |

其余断言（模型不越格、贴地、高度是 4m 倍数、8m 环梁与真实网格相交、4 根立柱接地、桥端落在 4.8m 接口环上）在本次运行中均通过。

### 🟠 P1-4 地面 `Base` 没有碰撞

`graybox_geometry.create()` 里 `Base` 是通过 `box(..., solid=false)`（默认）创建的，因此 100×100 地板没有碰撞体。接入玩家前需要 `solid=true` 或另加一块碰撞地板。

### 🟡 P1-5 文档与 UI 文案已过期

- `tools/ActualBuildingBridgePreview_README.md` 仍写着"一个 `Navigation/Start`、一个 `Navigation/Goal`"——这两个可视标记在 16:08 的改动里已删除，现在**只有 meta**（`start_count=1` / `goal_count=1`，`indicators_removed=true`），坐标来自 `dispersed_city_layout.START/GOAL`。
- 运行面板文案仍写 "Bridges are still graybox meshes"，但实际上桥已经换成 `重置桥 .glb` 真实模型。
- `tools/actual_building_validation.json` 是 DISTRIBUTED 布局改造**之前**生成的（里面还写着商店在 id 5/9/12、没有医疗点），属于过期产物，修好 P1-3 后重新跑测试会自动覆盖。

### ⚪ P2-6 尚未完成的功能

- 服务点（商店 / 医疗点）**没有任何交互逻辑**，只是模型 + 招牌 + meta。
- 起点 / 终点**不是玩家逻辑**，只是坐标常量与 meta；没有关卡流程、没有出入口触发。
- 建筑**没有内部空间、入口和碰撞体**（模型是整体外壳，只有 8m 环梁与 4 根立柱有碰撞）。
- 敌人导航、地面到桥面的竖向通路（楼梯/攀爬）、桥面正式美术均未做。
- `EnemyRoutePreview` 只是地面示意线，不是 AI 巡逻。

---

## 8. 建议的下一步（按性价比排序）

1. 修 `actual_buildings` 三处断言（约 5 分钟）→ 三个套件全绿，交接基线干净。
2. 修 P0-1 的重复实例（约 10 分钟）→ 换 seed 的性能与 `V` 键行为恢复正常。
3. 修 P0-2 + P1-4 的碰撞（约 30 分钟）→ 玩家能在街区与桥面上正常行走，这是接入肉鸽玩法的前提。
4. 把 seed 接进局内流程：一"局" = 一个 seed；起点/终点作为关卡出入口；服务点作为局内节点（商店/医疗）。
5. 之后再做建筑内部、敌人导航与桥面美术。

---

## 9. 附录

### 9.1 关键常量

| 常量 | 值 | 位置 |
|---|---|---|
| `CELL` | 12.0 | `graybox_layout.gd` |
| 网格原点偏移 | `-3.5`（即 `(x-3.5)*12`） | `graybox_layout.gd` / `graybox_geometry.gd` |
| 候选边最大跨度 | 53m | `graybox_layout.gd` |
| 避障安全半宽 | 5.95m | `graybox_layout.gd` `clear_path()` |
| socket 半径 | 4.8m | `graybox_layout.gd` `socket()` |
| 桥面标高 / 宽 / 厚 | 8.0 / 2.2 / 0.25 | `graybox_geometry.gd` |
| 桥面数量目标 | `rand(22..26)` | `graybox_layout.gd` |
| 立面环梁高度 | 7.65m（立柱顶 7.76m） | `actual_building_geometry.gd` |
| 建筑水平缩放上限 | 9.0m / 最长水平边 | `actual_building_geometry.gd` |
| 建筑总高 | 12m / 16m 交替 | `actual_building_geometry.gd` |
| `重置桥` 原始跨度 | 107.5178375 | `actual_bridge_geometry.gd` |

### 9.2 复现某个 seed 并检查桥网（可在运行的游戏里直接求值）

```gdscript
var l = load("res://tools/dispersed_city_layout.gd").new()
var p = l.plan(20260923)
var segs = 0; var multi = 0
for e in p.edges:
    segs += e.points.size() - 1
    if e.points.size() > 2: multi += 1
return {"edges": p.edges.size(), "segments": segs, "multi": multi,
        "roads": p.roads.size(), "streets": p.streets.size(), "connected": p.connected}
```

### 9.3 交接时的环境

- Godot 4.7.2-stable (official)，Windows，Forward+，Jolt Physics，D3D12。
- 编辑器会话 `ghost-in-the-shell@6ec71a67bc4dee37`，当前场景 `res://scenes/ActualBuildingBridgePreview.tscn`。
- 尚未纳入版本控制（项目根目录没有 `.git`），交接以本包为准。
