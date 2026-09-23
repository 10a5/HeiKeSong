# C 地图生成逻辑：沿道路与已有房屋生长

本文对应已经生成的 **C 地图：斜交支路、多朝向街区**，采用最新确认的 **短边6米房型**。规则及实验结果依据本轮生成脚本与几何数据整理。

## 1. 目标与基本规则

在指定大小的矩形地图中，先生成一条直线主干道，再从主干道两侧生成支道。随后反复选择道路边或已有房屋边，在附近放置矩形房屋，直到当前放置规则下无法继续添加。

房屋有两种生长方式：

- **沿道路生长**：房屋的一条边平行于所选道路边，离道路边缘至少 1 米。
- **沿房屋生长**：房屋的一条边平行于所选房屋边，与所有已有房屋的距离至少 2 米。

所有房屋占地均为 **短边6米，长边和模型实际尺寸决定。旋转不改变房型，也不会在补空阶段生成更小的房屋。

房屋必须完整位于地图内，不通过裁切房屋来适应地图边界。道路按地图边界裁切。

## 2. C 地图参数

所有长度单位均为米；二维坐标的 x 轴向右、y 轴向上，角度从 +x 方向逆时针测量。

| 参数 | C 图取值 | 说明 |
|---|---:|---|
| 地图宽度、高度 | 100、100 | 坐标范围为 `[0,100] × [0,100]` |
| 随机种子 | 419 | 本次 Python 参考实现的种子 |
| 主路角度 | 68° | 一条贯穿地图的直线主路 |
| 主路宽度 | 10 | 垂直于道路中心线测量 |
| 主路参考点扰动 | x、y 各 ±6 | 相对地图中心 `(50,50)` |
| 支道数量 | 6 | 主路两侧各 3 条 |
| 支道宽度 | 4 | 垂直于各自中心线测量 |
| 支道方向扰动 | ±25° | 相对主路的垂直方向 |
| 支道基础起点比例 | 0.18、0.50、0.82 | 沿主路中心线从起点到终点 |
| 起点比例扰动 | ±0.045 | 每条支道独立取值 |
| 房屋尺寸 | 6×10 | 全部相同，允许旋转 |
| 道路退距 | 1 | 房屋边界到道路表面的最短距离 |
| 最小楼间距 | 2 | 任意两个房屋多边形的最短距离 |
| 最小依附投影重合长度 | 2 | 防止新房屋只在角点附近松散依附 |
| 随机阶段选择道路边的概率 | 0.42 | 已存在房屋时适用 |
| 随机阶段选择房屋边的概率 | 0.58 | 已存在房屋时适用 |
| 随机阶段交换宽深的概率 | 0.30 | 从 `(6,x)` 改为 `(x,6)` |
| 随机阶段连续失败上限 | 2200 | 达到后进入沿边扫描 |
| 收尾扫描步长 | 0.5 | 分别检查两种宽深方向 |
| 几何计算容差 | `1e-7` | 参考实现的浮点判断容差 |

其中 100×100 米、道路退距 1 米、随机采样比例与停止阈值是本次实验的具体设置；房屋短边 6 米、主路 10 米、支道 4 米、楼间距至少 2 米是当前确认的规则。

### 建议配置结构

```json
{
  "map_id": "C",
  "seed": 419,
  "map_width_m": 100.0,
  "map_height_m": 100.0,
  "main_road_angle_deg": 68.0,
  "main_road_width_m": 10.0,
  "main_reference_point_jitter_m": 6.0,
  "branches_per_side": 3,
  "branch_width_m": 4.0,
  "branch_angle_jitter_deg": 25.0,
  "branch_start_fractions": [0.18, 0.50, 0.82],
  "branch_start_fraction_jitter": 0.045,
  "branch_length_ratios": [0.67, 0.80, 1.0],
  "branch_length_ratio_weights": [0.20, 0.25, 0.55],
  "house_size_m": [6.0, 10.0],
  "house_gap_m": 2.0,
  "road_setback_m": 1.0,
  "min_frontage_overlap_m": 2.0,
  "road_anchor_probability": 0.42,
  "swap_house_sides_probability": 0.30,
  "random_failure_limit": 2200,
  "scan_step_m": 0.5
}
```

## 3. 主干道生成

1. 在地图中心附近随机选择参考点：

   `c = (50 + random(-6, 6), 50 + random(-6, 6))`

2. 根据主路角度构造单位方向：

   `u = (cos(68°), sin(68°))`

3. 沿 `u` 的正反方向延伸出覆盖地图的长线段，再与地图矩形相交，得到主路中心线起点 `A` 和终点 `B`。
4. 将中心线向两侧各扩张 5 米，端部采用平头，再与地图矩形求交，得到主路占地多边形。

参考脚本在 100×100 米地图中使用 `c ± 220u` 构造长线段。如果改为其他地图大小，延伸距离应随地图对角线长度调整，不能继续假设 220 米总能覆盖地图。

道路宽度是对中心线的**垂直宽度**，不是世界坐标中的水平宽度或竖直宽度。

## 4. 支道生成

对主路的两侧分别生成 3 条支道。设侧别 `s ∈ {-1,+1}`，主路角度为 `θ`。

### 4.1 起点位置

先取基础比例 `0.18、0.50、0.82`，分别叠加 `[-0.045,0.045]` 范围内的随机扰动，得到 `t`。

```text
branch_start = A + t × (B - A)
```

两侧分别采样，所以支道起点不必左右对齐。

### 4.2 支道方向

对每条支道独立采样 `δ ∈ [-25°,25°]`：

```text
branch_angle = θ + s × (90° + δ)
branch_direction = (cos(branch_angle), sin(branch_angle))
```

这使 C 图保留主路向两侧分叉的结构，同时形成不同朝向的街区。

### 4.3 支道长度

从起点沿支道方向发射射线，计算到地图边界的可用距离 `L_available`，再随机选择长度比例：

| 长度比例 | 选择概率 | 结果 |
|---:|---:|---|
| 0.67 | 20% | 在地图内部结束 |
| 0.80 | 25% | 在地图内部结束 |
| 1.00 | 55% | 到达地图边界 |

```text
branch_length = L_available × length_ratio
branch_end = branch_start + branch_direction × branch_length
```

将支道中心线向两侧各扩张 2 米，使用平头端部并裁切到地图内。最后对主路与全部支道求并集，作为后续房屋碰撞检测的道路区域。

交叉口允许道路互相重叠；房屋必须避开道路并集。当前规则不额外限制支道互相相交，也不保证形成环路。

## 5. 可生长边的数据结构

道路两侧边缘、已接受房屋的四条外边，都可以作为下一栋房屋的依附边。

```text
Anchor:
    p          边的起点，二维坐标
    u          沿边方向的单位向量
    n          朝外的单位法向量，与 u 垂直
    length     边长
    kind       "road" 或 "house"
    parent     所属道路或房屋的 ID
    gap        road 为 1 米；house 为 2 米
```

道路只把中心线两侧的平行边加入集合，不把道路端部横边加入集合。某些道路边位于交叉口内部，也可以保留在候选集合中；实际房屋会在道路退距检查中被拒绝。

房屋顶点统一成逆时针顺序后，对每条边计算：

```text
u = normalize(edge_end - edge_start)
n = (u.y, -u.x)
```

此时 `n` 指向房屋外部。法线不能指向已有建筑内部，否则会反复生成重叠候选。

## 6. 从一条边构造房屋

设选中的依附边为 `Anchor`，沿该边方向的房屋尺寸为 `w`，向外延伸的尺寸为 `d`。

可选方向为：

```text
(w, d) = (6, 10) 或 (10, 6)
```

沿依附边选择偏移量 `offset`：

```text
offset ∈ [-w + 2, Anchor.length - 2]
```

这个范围允许房屋超出依附边的端点，但两者沿边方向的投影至少重合 2 米。

房屋四个角点按以下方式构造：

```text
P0 = Anchor.p + offset × Anchor.u + Anchor.gap × Anchor.n
P1 = P0 + w × Anchor.u
P2 = P1 + d × Anchor.n
P3 = P0 + d × Anchor.n
```

`P0—P1` 就是朝向依附对象的那条房屋边。房屋中心为四个顶点的平均值。

沿房屋生长时，新房屋继承所选房屋边的方向。因此，街区朝向来自道路及其后续生长关系，而不是给每栋房屋独立选择任意角度。

## 7. 接受房屋前的几何检查

一个候选必须同时满足以下条件：

1. 四个角点完整位于地图矩形内。
2. 候选房屋与道路并集的最短距离至少为 1 米。
3. 候选房屋与每一栋已有房屋的最短距离至少为 2 米。
4. 矩形短边为6米，长边符合设施实际尺寸

距离检查必须针对**旋转后的真实多边形**。仅检测外接矩形相交，或只检查房屋中心之间的距离，都不足以保证 2 米楼间距。

可以先用扩张了 2 米的轴对齐外接矩形查询附近房屋，再对查询结果计算精确多边形距离。参考实现使用空间索引加速这一过程。

接受候选后：

- 保存它的顶点、中心、尺寸、方向、依附对象及放置顺序。
- 把新房屋加入碰撞检测集合。
- 把新房屋四条朝外的边加入可生长边集合。

## 8. 第一阶段：随机生长

每次尝试执行：

1. 还没有任何房屋时，只能选择道路边。
2. 已有房屋时，以 42% 概率选择道路边，58% 概率选择房屋边。
3. 选择道路边时按边长加权，长边获得更多采样机会；选择房屋边时对已有房屋边等概率采样。
4. 默认取 `(w,d)=(6,10)`，以 30% 概率交换为 `(10,6)`。
5. 在允许区间内均匀随机采样 `offset`。
6. 构造房屋并检查合法性。
7. 成功则接受房屋，并把连续失败计数归零；失败则计数加一。
8. 连续失败达到 2200 次时，结束随机阶段，进入沿边扫描。

2200 次是**连续失败次数**，不是总尝试次数，也不是房屋数量上限。

## 9. 第二阶段：沿边扫描补空

随机失败不能直接证明已经没有可用位置，所以还要做一次规则化扫描。

1. 把全部道路边和当前房屋边加入队列，并打乱初始顺序。
2. 取出一条边，分别检查 `(6,10)`、`(10,6)` 两种方向；方向顺序随机打乱。
3. 对每种方向，从 `-w+2` 开始，以 0.5 米步长采样，直到不超过 `edge.length-2`；采样点顺序也打乱。
4. 使用与随机阶段完全相同的合法性检查。
5. 每放入一栋房屋，就把它的四条边加入待扫描队列。
6. 队列处理完毕后，再独立扫描最终的全部边，确认没有合法候选。

随着房屋增多，障碍物只会增加，之前失败的固定候选不会重新变为合法。因此，每条已存在的边完成一轮扫描即可，新房屋产生的新边继续入队。

**停止条件的准确含义：**采用 6×10 米房型、当前依附方向及位置规则、0.5 米沿边采样步长，已经找不到新的合法位置。它不等于连续空间中的全局最密装箱；移动已有房屋、改变朝向规则或缩小扫描步长，仍可能得到不同结果。

地图本身使用连续坐标。0.5 米只用于收尾扫描，不代表所有房屋必须落在一个全局 0.5 米网格上。

## 10. 完整流程伪代码

```text
function generate_map_C(config):
    rng = create_rng(seed=419)
    site = rectangle(0, 0, 100, 100)

    main_road = generate_main_road(site, angle=68°, width=10, rng)
    branches = generate_branches(
        main_road, each_side=3, width=4, angle_jitter=25°, rng
    )
    road_union = union(main_road, branches)
    road_edges = build_road_side_anchors(main_road, branches)

    houses = []
    house_edges = []
    failure_streak = 0

    while failure_streak < 2200:
        edge = choose_anchor(road_edges, house_edges, road_probability=0.42, rng)
        width, depth = (6, 10)
        if rng.random() < 0.30:
            width, depth = (10, 6)

        offset = rng.uniform(-width + 2, edge.length - 2)
        candidate = make_rectangle(edge, offset, width, depth)

        if is_valid(candidate, site, road_union, houses):
            accept(candidate, parent=edge.parent, phase="random")
            houses.append(candidate)
            house_edges.extend(outward_edges(candidate))
            update_spatial_index(candidate)
            failure_streak = 0
        else:
            failure_streak += 1

    queue = rng.shuffle(copy(road_edges) + copy(house_edges))

    while queue is not empty:
        edge = queue.pop_front()
        for width, depth in rng.shuffle([(6,10), (10,6)]):
            offsets = sample_interval(-width+2, edge.length-2, step=0.5)
            for offset in rng.shuffle(offsets):
                candidate = make_rectangle(edge, offset, width, depth)
                if is_valid(candidate, site, road_union, houses):
                    accept(candidate, parent=edge.parent, phase="scan")
                    houses.append(candidate)
                    new_edges = outward_edges(candidate)
                    house_edges.extend(new_edges)
                    queue.extend(new_edges)
                    update_spatial_index(candidate)

    verify_sizes_bounds_distances_and_remaining_candidates()
    return roads, houses, generation_order, statistics
```

## 11. C 图实测结果与复现

| 指标 | 结果 |
|---|---:|
| 建筑数量 | 48 栋 |
| 每栋建筑面积 | 60 平方米 |
| 建筑总占地 | 2880 平方米 |
| 建筑占地图面积比例 | 28.8% |
| 道路并集面积 | 2048.69 平方米 |
| 生成时依附道路的建筑 | 24 栋 |
| 生成时依附房屋的建筑 | 24 栋 |
| 随机阶段总尝试次数 | 5573 |
| 扫描阶段新增建筑 | 0 栋 |
| 最小楼间距 | 2 米 |
| 最小道路退距 | 1 米 |
| 越界、建筑重叠 | 均为 0 |
| 最终扫描剩余合法候选 | 0 |

“依附道路／依附房屋”记录生成时选择的对象，不是建筑用途分类，也不保证与最终是否临街完全一致。

### 已生成 C 图的道路中心线

以下坐标按已导出的几何数据列出，保留六位小数。若希望沿用同一套道路，可直接使用这些线段及对应道路宽度。

| 道路 | 起点 `(x,y)` | 终点 `(x,y)` | 宽度 |
|---|---|---|---:|
| 主路 | `(34.138529, 0.000000)` | `(74.541152, 100.000000)` | 10 |
| 支道 1 | `(41.290459, 17.701647)` | `(100.000000, 0.450966)` | 4 |
| 支道 2 | `(53.093841, 46.916044)` | `(90.618768, 37.284470)` | 4 |
| 支道 3 | `(67.268486, 81.999521)` | `(100.000000, 65.042789)` | 4 |
| 支道 4 | `(40.227443, 15.070591)` | `(13.275056, 26.641926)` | 4 |
| 支道 5 | `(54.154637, 49.541607)` | `(10.830927, 55.049280)` | 4 |
| 支道 6 | `(66.710914, 80.619481)` | `(0.000000, 88.471669)` | 4 |

参考代码使用 `numpy.random.default_rng(419)`。要逐点复现原图，需要保持随机数实现、抽样调用顺序、集合顺序和几何计算方式一致。Godot 中仅设置相同的种子，不保证得到相同坐标。

若要求精确还原现有 C 图，应直接读取此前生成包中的 `uniform_6x10_geometry.json`，取 `maps` 数组里 `id == "C"` 的对象；若只要求生成同类地图，按本文规则实现即可。

## 12. 输出数据与 3D 还原

建议保留以下数据：

```text
Road:
    id, width, centerline_start, centerline_end, polygon_vertices

House:
    id, polygon_vertices, center, width, depth, angle
    parent_kind, parent_id, generation, placement_phase
    entrance_candidate

Map:
    seed, bounds, roads, houses_in_placement_order, validation_statistics
```

入口候选点可以取房屋依附边的中点 `(P0+P1)/2`。它只是几何候选，尚未保证门口有通向道路的可行走路径。

将二维点还原到 Godot 的 XZ 平面时，可以采用：

```text
(x, y) → Vector3(x, height, -y)
```

道路多边形用于构建地面网格；房屋矩形用于生成或放置建筑底面，再赋予建筑高度。生成三角形或挤出网格前，应统一顶点绕序。房屋高度、建筑用途、入口导航、桥梁和不同水平层，可以在这份平面布局之上继续添加。

2 米楼间距表示几何上的空隙；加入台阶、装饰、碰撞体或角色半径后，仍需单独验证实际通行宽度与连通性。
