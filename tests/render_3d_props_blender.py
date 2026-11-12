"""Blender side of the 3D prop render: one static view of one mesh.

Runs ONLY inside Blender (no Pillow there); the driver
`tests/render_3d_props.py` does cropping, scaling and outline.

    blender --background --factory-startup --python tests/render_3d_props_blender.py \
        -- --job job.json

The job is a small JSON: mesh path, output path, azimuth/elevation in degrees,
render size in pixels and a margin factor. The render is deliberately square
and oversized: the driver re-crops it, so the framing computed here only has to
contain the whole model.
"""
import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def parse_job() -> dict:
    argv = sys.argv
    if "--" not in argv:
        raise SystemExit("expected: -- --job <path>")
    rest = argv[argv.index("--") + 1:]
    if len(rest) < 2 or rest[0] != "--job":
        raise SystemExit("expected: -- --job <path>")
    return json.loads(Path(rest[1]).read_text(encoding="utf-8"))


def clear_scene() -> None:
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)


def import_mesh(path: Path) -> None:
    suffix = path.suffix.lower()
    if suffix in (".glb", ".gltf"):
        bpy.ops.import_scene.gltf(filepath=str(path))
    elif suffix == ".obj":
        bpy.ops.wm.obj_import(filepath=str(path))
    elif suffix == ".fbx":
        bpy.ops.import_scene.fbx(filepath=str(path))
    else:
        raise SystemExit("unsupported mesh format: %s" % path)
    if not [o for o in bpy.data.objects if o.type == "MESH"]:
        raise SystemExit("no mesh imported from %s" % path)


def world_bounds():
    """Evaluated bounds: `bound_box` of the object ignores the modifier stack."""
    deps = bpy.context.evaluated_depsgraph_get()
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for obj in bpy.data.objects:
        if obj.type != "MESH":
            continue
        ev = obj.evaluated_get(deps)
        mesh = ev.to_mesh()
        for v in mesh.vertices:
            co = ev.matrix_world @ v.co
            lo.x = min(lo.x, co.x)
            lo.y = min(lo.y, co.y)
            lo.z = min(lo.z, co.z)
            hi.x = max(hi.x, co.x)
            hi.y = max(hi.y, co.y)
            hi.z = max(hi.z, co.z)
        ev.to_mesh_clear()
    if lo.x > hi.x:
        raise SystemExit("empty mesh")
    return lo, hi


def pick_engine(scene) -> None:
    for engine in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "BLENDER_WORKBENCH"):
        try:
            scene.render.engine = engine
            return
        except TypeError:
            continue
    raise SystemExit("no usable render engine found")


def setup_scene(job: dict) -> None:
    scene = bpy.context.scene
    px = int(job["render_px"])
    # Standard view transform, the same reason as the character pipeline: the
    # game draws sprites without a tone mapper, AgX would repaint the palette.
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    # The painted prop sprites are lit brighter than a default Blender stage:
    # measured mean 87,111,29 against 49,59,25 on the first bake. Exposure is a
    # per-model knob because snow, stone and foliage do not share one gain.
    scene.view_settings.exposure = float(job.get("exposure", 0.0))
    scene.view_settings.gamma = 1.0
    scene.render.resolution_x = px
    scene.render.resolution_y = px
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "8"
    pick_engine(scene)

    # Key from the upper left, weak fill from the right: props sit next to
    # sprites painted with the same light direction.
    key_data = bpy.data.lights.new("Key", type="SUN")
    key_data.energy = float(job.get("key_energy", 3.0))
    key_data.angle = math.radians(12.0)
    key = bpy.data.objects.new("Key", key_data)
    key.rotation_euler = Vector((0.82, -0.22, -1.0)).normalized() \
        .to_track_quat("-Z", "Y").to_euler()
    scene.collection.objects.link(key)
    fill_data = bpy.data.lights.new("Fill", type="SUN")
    fill_data.energy = 1.2
    fill = bpy.data.objects.new("Fill", fill_data)
    fill.rotation_euler = Vector((-0.7, 0.6, -0.6)).normalized() \
        .to_track_quat("-Z", "Y").to_euler()
    scene.collection.objects.link(fill)

    if scene.world is None:
        scene.world = bpy.data.worlds.new("PropWorld")
    scene.world.use_nodes = True
    bg = scene.world.node_tree.nodes.get("Background")
    if bg is not None:
        bg.inputs[0].default_value = (0.32, 0.34, 0.36, 1.0)
        bg.inputs[1].default_value = 0.55


def add_camera(job: dict, lo: Vector, hi: Vector) -> None:
    scene = bpy.context.scene
    margin = float(job.get("margin", 1.08))
    size = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z, 0.05) * margin
    target = (lo + hi) / 2.0
    cam_data = bpy.data.cameras.new("PropCam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = size
    cam = bpy.data.objects.new("PropCam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    az = math.radians(float(job.get("azimuth", -35.0)))
    el = math.radians(float(job.get("elevation", 22.0)))
    dist = max(6.0, size * 4.0)
    cam.location = target + Vector((
        math.sin(az) * math.cos(el),
        -math.cos(az) * math.cos(el),
        math.sin(el),
    )) * dist
    cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
    bpy.context.view_layer.update()


def main() -> None:
    job = parse_job()
    clear_scene()
    import_mesh(Path(job["mesh"]))
    lo, hi = world_bounds()
    setup_scene(job)
    add_camera(job, lo, hi)
    out = Path(job["out"])
    out.parent.mkdir(parents=True, exist_ok=True)
    bpy.context.scene.render.filepath = str(out)
    bpy.ops.render.render(write_still=True)
    manifest = {
        "out": str(out),
        "render_px": int(job["render_px"]),
        "bounds": {"lo": list(lo), "hi": list(hi)},
    }
    Path(job["manifest"]).write_text(json.dumps(manifest, indent=1),
                                     encoding="utf-8")
    print("RENDERED:", out)


main()
