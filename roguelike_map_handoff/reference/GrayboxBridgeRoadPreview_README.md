# 道路与随机桥梁灰盒预览

打开 `res://scenes/GrayboxBridgeRoadPreview.tscn`，按 F6 运行。原主场景及已有地图未修改。

## 布局
- 8×8网格，每格12m；20个1×1格建筑占位，无正式建筑模型。
- 占位格内9.6×9.6m薄板代表8m桥接接口，外围留退界；不是完成设计的悬空建筑。
- 大道宽6m，小巷宽2.8m；40个地面道路节点连通，C1、F1为死巷。街道与占位固定。
- 蓝色为桥骨架，琥珀色为额外支路；地面琥珀线/方块为敌人巡逻路线示意，不是敌人AI。
- Perlin噪声影响候选边权和额外连接概率；Kruskal树保证20个节点桥网连通，再添加支路、短折线。
- 桥及碰撞共同旋转，避开第三栋建筑9.6m几何预留范围并计入桥宽；同标高交叉为通行路口。
- 统一8m桥面，暂不加入竖向路线、攀爬及地面到桥面的出入口。

## 操作
- 每次运行自动选随机seed。
- R / Random：随机；N / Next和P / Previous：相邻seed。
- 数字输入框 + Apply seed / Enter：复现指定seed。
- B / Roads only：隐藏桥及8m接口薄板，检查地面路线。
- T：俯视；O：概览；右键拖动：旋转；滚轮：缩放。
- 运行时切换不覆盖保存场景。编辑器参考seed为20260923。

## 验证
测试suite `graybox_preview`：2项测试、1382个断言通过。
10个seed（20260923～20260932）：10种桥图、22～26条连接、每图2～6条折线；地面道路不变、20节点全连通、两处死巷保留。
同seed重复生成一致；桥路径避障、端点接口和旋转碰撞通过结构检查。
新运行实测输入20260923得到22连接/24段桥面，N切换20260924得到26连接。桥层隐藏和道路保持不变已验证。
未进行玩家/敌人AI通行测试，未穷举所有seed。

## 文件
- tools/graybox_layout.gd：布局与桥规划。
- tools/graybox_geometry.gd：灰盒几何、碰撞。
- tools/graybox_preview_controls.gd：交互、相机。
- tools/build_graybox_preview.gd：调用build(seed)保存参考场景。
- tests/test_graybox_preview.gd：测试。
- tools/graybox_validation.json：多seed统计。
