"""Create a presentation scene for the Waveshare 1.75C development board."""

from pathlib import Path
import math

import bpy
from mathutils import Vector


ROOT = Path("/Users/sn5/dragonBall_Radar")
ASSET_DIR = ROOT / "artifacts" / "blender"
STL = ASSET_DIR / "waveshare_esp32_s3_touch_amoled_175c.stl"
BLEND = ASSET_DIR / "dragon_radar_waveshare_175c.blend"
PREVIEW = ASSET_DIR / "dragon_radar_waveshare_175c_preview.png"


def material(name, color, metallic=0.0, roughness=0.4):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = (*color, 1.0)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    return mat


def look_at(obj, point):
    obj.rotation_euler = (Vector(point) - obj.location).to_track_quat("-Z", "Y").to_euler()


def add_area(name, location, energy, size, color):
    data = bpy.data.lights.new(name, "AREA")
    data.energy = energy
    data.shape = "DISK"
    data.size = size
    data.color = color
    obj = bpy.data.objects.new(name, data)
    bpy.context.collection.objects.link(obj)
    obj.location = location
    look_at(obj, (0, 0, 0))


def main():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)

    bpy.ops.wm.stl_import(filepath=str(STL))
    board = bpy.context.active_object
    board.name = "Waveshare ESP32-S3 Touch AMOLED 1.75C"

    # STEP/STL geometry is authored in millimetres; Blender presentation uses metres.
    board.scale = (0.001, 0.001, 0.001)
    bpy.context.view_layer.objects.active = board
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)

    # Center at the origin and rest the lowest point on the presentation surface.
    corners = [board.matrix_world @ Vector(corner) for corner in board.bound_box]
    center = sum(corners, Vector()) / 8.0
    board.location.x -= center.x
    board.location.y -= center.y
    board.location.z -= min(v.z for v in corners)
    board.rotation_euler[2] = math.radians(-14)

    # A neutral dark material keeps the official mechanical detail readable.
    board.data.materials.append(material("Board Graphite", (0.055, 0.07, 0.075), 0.28, 0.3))
    for poly in board.data.polygons:
        poly.use_smooth = True

    bpy.ops.mesh.primitive_plane_add(size=0.32, location=(0, 0, -0.0015))
    floor = bpy.context.active_object
    floor.name = "Presentation Surface"
    floor.data.materials.append(material("Midnight Surface", (0.012, 0.018, 0.025), 0.05, 0.28))

    # A subtle amber ring references Dragon Radar while leaving the board unobstructed.
    bpy.ops.mesh.primitive_torus_add(
        major_radius=0.052,
        minor_radius=0.0007,
        major_segments=128,
        minor_segments=12,
        location=(0, 0, 0.0004),
    )
    ring = bpy.context.active_object
    ring.name = "Dragon Radar Accent Ring"
    glow = material("Radar Amber", (1.0, 0.18, 0.015), 0.15, 0.22)
    ring.data.materials.append(glow)
    glow.node_tree.nodes["Principled BSDF"].inputs["Emission Color"].default_value = (1.0, 0.025, 0.002, 1.0)
    glow.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"].default_value = 3.0

    camera_data = bpy.data.cameras.new("Camera")
    camera = bpy.data.objects.new("Camera", camera_data)
    bpy.context.collection.objects.link(camera)
    bpy.context.scene.camera = camera
    camera.location = (0.095, -0.115, 0.085)
    camera.data.lens = 58
    look_at(camera, (0, 0, 0.012))

    add_area("Key", (0.08, -0.05, 0.13), 18, 0.085, (1.0, 0.74, 0.55))
    add_area("Fill", (-0.09, -0.02, 0.07), 8, 0.075, (0.34, 0.56, 1.0))
    add_area("Rim", (0.02, 0.1, 0.11), 24, 0.065, (1.0, 0.19, 0.08))

    world = bpy.context.scene.world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.004, 0.007, 0.012, 1.0)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.18

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1200
    scene.render.resolution_y = 1200
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = str(PREVIEW)
    scene.render.film_transparent = False
    scene.render.image_settings.color_mode = "RGBA"
    scene.view_settings.look = "AgX - Medium High Contrast"
    scene.view_settings.exposure = -1.0

    bpy.ops.wm.save_as_mainfile(filepath=str(BLEND))
    bpy.ops.render.render(write_still=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(BLEND))
    print(f"BLEND={BLEND}")
    print(f"PREVIEW={PREVIEW}")


if __name__ == "__main__":
    main()
