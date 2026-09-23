# 建筑表面碰撞

这里的 `.res` 是从 `model/` 中九款建筑提取并简化的 `ConcavePolygonShape3D`，其中医疗中心使用 `医疗点.glb`。它们保留模型原坐标，运行时与对应可视模型使用同一套旋转、统一缩放和居中变换。同款实例共享资源；生成地图时无需重新简化或提取原始网格。

更新建筑 GLB 后，在项目根目录重新生成：

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --threads 2 --python-exit-code 1 --python tools/build_building_collisions.py -- --output /tmp/hks-building-collisions
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/save_building_collisions.gd -- /tmp/hks-building-collisions
```

只更新单个模型时可用 `--model`，例如医疗中心：

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --threads 2 --python-exit-code 1 --python tools/build_building_collisions.py -- --output /tmp/hks-medical-collision --model medical
```

`医疗点.glb` 的源包围盒为 `0.9807 × 0.9593 × 0.7577 m`（X/Y/Z），原始网格 1,838,474 个三角面。按现有地块的 14 × 10 m 水平边界和约 15.22 m 高度约束，建议运行时统一缩放约 `12.49`；其简化碰撞保留 14,000 个三角面，5,000 点采样的误差 P95 为 `0.0274 m`，最大误差为 `0.0705 m`（均为按地图拟合比例换算后的世界米）。

脚本只读取源 GLB 的几何，不加载纹理，也不改动原文件。Blender 先焊接 UV 接缝的重合顶点，再进行 QEM 简化。Godot 将结果压缩保存为碰撞资源，运行游戏不需要 Blender。

`manifest.json` 记录源文件 SHA-256、原始/简化三角面数以及 5,000 个采样点到简化表面的距离。普通模型约 14,000 面；原版居民楼含许多独立窗台，保留 60,000 面以免过度简化。细小装饰的碰撞是近似值，不代表逐像素精度。
