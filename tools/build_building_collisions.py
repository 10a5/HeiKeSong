"""Bake compact surface collisions without loading textures or changing GLBs.

Run with Blender's Python (numpy and bpy are bundled):
  Blender --background --factory-startup --python tools/build_building_collisions.py -- --output /tmp/hks-collisions
Then compress the resulting shapes with tools/save_building_collisions.gd.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

import bpy
import numpy as np
from mathutils import Matrix, Quaternion, Vector
from mathutils.bvhtree import BVHTree

MODELS = {
    "residential_0": "居民楼.glb", "residential_1": "居民楼(1).glb",
    "residential_2": "居民楼3.glb", "residential_3": "居民楼4.glb",
    "residential_4": "居民楼5.glb", "factory_0": "工厂1.glb",
    "factory_1": "工业机房楼.glb", "shop": "商店.glb",
    "medical": "医疗点.glb",
}


def read_glb(path):
    raw = path.read_bytes()
    length, = struct.unpack_from("<I", raw, 12)
    doc = json.loads(raw[20:20 + length])
    binary = raw[28 + length:]

    def accessor(index):
        item = doc["accessors"][index]
        view = doc["bufferViews"][item["bufferView"]]
        dtype = {5126: "<f4", 5125: "<u4", 5123: "<u2", 5121: "u1"}[item["componentType"]]
        width = {"SCALAR": 1, "VEC3": 3}[item["type"]]
        offset = view.get("byteOffset", 0) + item.get("byteOffset", 0)
        stride = view.get("byteStride", np.dtype(dtype).itemsize * width)
        return np.ndarray((item["count"], width), dtype=dtype, buffer=binary, offset=offset,
                          strides=(stride, np.dtype(dtype).itemsize)).copy()

    vertices, triangles = [], []
    vertex_count = 0

    def visit(index, parent):
        nonlocal vertex_count
        node = doc["nodes"][index]
        if "matrix" in node:
            transform = np.array(node["matrix"]).reshape((4, 4)).T
        else:
            rotation = node.get("rotation", [0, 0, 0, 1])
            matrix = Matrix.LocRotScale(Vector(node.get("translation", [0, 0, 0])),
                                       Quaternion((rotation[3], *rotation[:3])),
                                       Vector(node.get("scale", [1, 1, 1])))
            transform = np.array(matrix)
        transform = parent @ transform
        if "mesh" in node:
            for primitive in doc["meshes"][node["mesh"]]["primitives"]:
                if primitive.get("mode", 4) != 4:
                    continue
                points = accessor(primitive["attributes"]["POSITION"])
                points = points @ transform[:3, :3].T + transform[:3, 3]
                indices = accessor(primitive["indices"]).reshape(-1, 3) if "indices" in primitive else np.arange(len(points)).reshape(-1, 3)
                if np.linalg.det(transform[:3, :3]) < 0:
                    indices = indices[:, [0, 2, 1]]
                vertices.append(points)
                triangles.append(indices.astype(np.int64) + vertex_count)
                vertex_count += len(points)
        for child in node.get("children", []):
            visit(child, transform)

    for node in doc["scenes"][doc.get("scene", 0)]["nodes"]:
        visit(node, np.eye(4))
    return raw, np.concatenate(vertices), np.concatenate(triangles)


def bake(path, destination, target_faces):
    raw, points, faces = read_glb(path)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    mesh = bpy.data.meshes.new("collision")
    mesh.from_pydata(points.tolist(), [], faces.tolist())
    mesh.update()
    obj = bpy.data.objects.new("collision", mesh)
    bpy.context.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    # GLBs split vertices at UV/normal seams. Weld those before QEM collapse;
    # otherwise a coplanar textured wall can retain thousands of triangles.
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.remove_doubles(threshold=float(np.max(np.ptp(points, axis=0))) * 0.000005)
    bpy.ops.object.mode_set(mode="OBJECT")
    modifier = obj.modifiers.new("Collision simplification", "DECIMATE")
    modifier.ratio = min(1.0, target_faces / max(len(mesh.polygons), 1))
    modifier.use_collapse_triangulate = True
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    mesh.calc_loop_triangles()
    reduced = np.array([vertex.co[:] for vertex in mesh.vertices])
    reduced_faces = np.array([face.vertices[:] for face in mesh.loop_triangles])
    # Godot uses clockwise triangles, glTF/Blender use counter-clockwise.
    shape_points = reduced[reduced_faces[:, [0, 2, 1]]].reshape(-1, 3)
    numbers = ", ".join(format(float(number), ".8g") for number in shape_points.flat)
    destination.write_text('[gd_resource type="ConcavePolygonShape3D" format=3]\n\n[resource]\n'
                           'backface_collision = true\n'
                           f'data = PackedVector3Array({numbers})\n')
    # Record sampled source-to-collision distance for review in world metres.
    tree = BVHTree.FromPolygons(reduced.tolist(), reduced_faces.tolist(), all_triangles=True)
    samples = points[np.linspace(0, len(points) - 1, min(5000, len(points)), dtype=int)]
    errors = [tree.find_nearest(Vector(point))[3] for point in samples]
    size = np.ptp(points, axis=0)
    fit_scale = min(13.45 / size[0], 9.45 / size[2], 15.22 / size[1])
    report = {"source": str(path.name), "sha256": hashlib.sha256(raw).hexdigest(),
              "source_triangles": len(faces), "collision_triangles": len(reduced_faces),
              "source_min": points.min(axis=0).tolist(), "source_max": points.max(axis=0).tolist(),
              "sampled_error_p95_m": round(float(np.percentile(errors, 95) * fit_scale), 4),
              "sampled_error_max_m": round(float(max(errors) * fit_scale), 4)}
    print(json.dumps(report, ensure_ascii=False), flush=True)
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--faces", type=int, default=14000)
    parser.add_argument("--model", action="append", choices=sorted(MODELS),
                        help="Bake only the named model; may be supplied more than once")
    args = parser.parse_args(sys.argv[sys.argv.index("--") + 1:])
    args.output.mkdir(parents=True, exist_ok=True)
    project = Path(__file__).resolve().parent.parent
    # The original vertex-coloured tower contains many separate window ledges;
    # retaining more triangles prevents collapse from erasing whole components.
    selected = args.model or list(MODELS)
    reports = {key: bake(project / "model" / MODELS[key], args.output / f"{key}.tres",
                         max(args.faces, 60000) if key == "residential_0" else args.faces)
               for key in selected}
    (args.output / "manifest.json").write_text(json.dumps(reports, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
