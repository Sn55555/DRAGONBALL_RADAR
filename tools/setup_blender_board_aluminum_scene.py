"""Build the official-dimension 1.75-B aluminum enclosure presentation scene."""

from pathlib import Path
import math

import bpy
from mathutils import Vector


ROOT = Path("/Users/sn5/dragonBall_Radar")
ASSET_DIR = ROOT / "artifacts" / "blender"
STL = ASSET_DIR / "waveshare_esp32_s3_touch_amoled_175c.stl"
BLEND = ASSET_DIR / "dragon_radar_waveshare_175c_b_aluminum.blend"
PREVIEW = ASSET_DIR / "dragon_radar_waveshare_175c_b_aluminum_preview.png"


def mat(name, color, metallic=0.0, roughness=0.4, emission=None, strength=0.0):
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    bsdf = material.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    if emission:
        bsdf.inputs["Emission Color"].default_value = (*emission, 1.0)
        bsdf.inputs["Emission Strength"].default_value = strength
    return material


def look_at(obj, point):
    obj.rotation_euler = (Vector(point) - obj.location).to_track_quat("-Z", "Y").to_euler()


def add_area(name, location, energy, size, color, target=(0, 0, 0)):
    data = bpy.data.lights.new(name, "AREA")
    data.energy = energy
    data.shape = "DISK"
    data.size = size
    data.color = color
    obj = bpy.data.objects.new(name, data)
    bpy.context.collection.objects.link(obj)
    obj.location = location
    look_at(obj, target)


def add_cylinder(name, radius, depth, location, material, vertices=192, bevel=0.0):
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=vertices,
        radius=radius,
        depth=depth,
        location=location,
        rotation=(math.radians(90), 0, 0),
    )
    obj = bpy.context.active_object
    obj.name = name
    obj.data.materials.append(material)
    if bevel:
        mod = obj.modifiers.new("Machined edge", "BEVEL")
        mod.width = bevel
        mod.segments = 4
    return obj


def add_ring(name, major, minor, y, material):
    bpy.ops.mesh.primitive_torus_add(
        major_radius=major,
        minor_radius=minor,
        major_segments=192,
        minor_segments=20,
        location=(0, y, 0),
        rotation=(math.radians(90), 0, 0),
    )
    obj = bpy.context.active_object
    obj.name = name
    obj.data.materials.append(material)
    return obj


def add_radar_line(angle_deg, length, width, y, material):
    bpy.ops.mesh.primitive_cube_add(location=(0, y, 0))
    obj = bpy.context.active_object
    obj.name = f"Radar sweep {angle_deg:.0f}deg"
    obj.dimensions = (width, 0.00018, length)
    obj.rotation_euler[1] = math.radians(angle_deg)
    obj.data.materials.append(material)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)


def main():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)

    aluminum = mat("Bead-blasted Aluminum", (0.34, 0.37, 0.40), 0.92, 0.22)
    edge = mat("Polished Chamfer", (0.55, 0.59, 0.62), 0.96, 0.12)
    glass = mat("AMOLED Glass", (0.002, 0.006, 0.005), 0.06, 0.1)
    port_mat = mat("Port Interior", (0.006, 0.008, 0.01), 0.18, 0.42)
    green = mat("Radar Green", (0.005, 0.28, 0.07), 0.05, 0.2, (0.005, 1.0, 0.12), 4.0)
    amber = mat("Status Amber", (0.8, 0.08, 0.008), 0.1, 0.22, (1.0, 0.02, 0.002), 3.0)

    # Official mechanical drawing: diameter 51.00 mm, total thickness about 12.10 mm.
    body = add_cylinder("Aluminum enclosure - 51mm", 0.0255, 0.0121, (0, 0, 0), aluminum, bevel=0.00075)

    # Front machined lip and 43.76 mm touch/glass region.
    add_ring("Front polished lip", 0.02325, 0.0007, -0.00625, edge)
    add_cylinder("AMOLED touch glass - 43.76mm", 0.02188, 0.00062, (0, -0.00643, 0), glass, bevel=0.00025)
    add_ring("Glass inner seal", 0.02125, 0.00022, -0.00678, port_mat)

    # Bottom USB-C slot: rounded cutter through the aluminum shell.
    bpy.ops.mesh.primitive_cube_add(location=(0, 0, -0.0251))
    cutter = bpy.context.active_object
    cutter.name = "USB-C opening cutter"
    cutter.dimensions = (0.0105, 0.0062, 0.0044)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    bevel = cutter.modifiers.new("USB rounded corners", "BEVEL")
    bevel.width = 0.0016
    bevel.segments = 8
    bpy.context.view_layer.objects.active = cutter
    bpy.ops.object.modifier_apply(modifier=bevel.name)
    boolean = body.modifiers.new("USB-C opening", "BOOLEAN")
    boolean.operation = "DIFFERENCE"
    boolean.solver = "EXACT"
    boolean.object = cutter
    bpy.context.view_layer.objects.active = body
    bpy.ops.object.modifier_apply(modifier=boolean.name)
    bpy.data.objects.remove(cutter, do_unlink=True)

    bpy.ops.mesh.primitive_cube_add(location=(0, 0, -0.0247))
    port = bpy.context.active_object
    port.name = "USB-C dark cavity"
    port.dimensions = (0.0084, 0.0048, 0.0013)
    port.data.materials.append(port_mat)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    port_bevel = port.modifiers.new("Port radius", "BEVEL")
    port_bevel.width = 0.00125
    port_bevel.segments = 6

    # Two recessed side keys near the lower quadrants in the official drawing.
    for name, x in (("PWR side key", -0.0237), ("BOOT side key", 0.0237)):
        bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=24, location=(x, 0.001, -0.0095))
        button = bpy.context.active_object
        button.name = name
        button.scale = (0.0010, 0.0022, 0.0015)
        button.data.materials.append(edge)

    # Simple Dragon Radar face, presented under the glass.
    for radius in (0.0064, 0.0122, 0.0180):
        add_ring(f"Radar range {radius * 1000:.1f}mm", radius, 0.00011, -0.00682, green)
    add_radar_line(-38, 0.034, 0.00018, -0.00684, green)
    for idx, (x, z) in enumerate(((-0.009, 0.007), (0.007, 0.011), (0.012, -0.006), (-0.004, -0.013), (0.002, 0.003))):
        bpy.ops.mesh.primitive_uv_sphere_add(segments=32, ring_count=16, radius=0.00065, location=(x, -0.00702, z))
        dot = bpy.context.active_object
        dot.name = f"Radar target {idx + 1}"
        dot.data.materials.append(amber if idx == 1 else green)

    # Keep the detailed official bare-board mesh inside as a hidden engineering reference.
    bpy.ops.wm.stl_import(filepath=str(STL))
    board = bpy.context.active_object
    board.name = "Internal official bare-board reference"
    board.scale = (0.001, 0.001, 0.001)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    board.hide_render = True
    board.hide_set(True)

    # Presentation floor.
    bpy.ops.mesh.primitive_plane_add(size=0.30, location=(0, 0.018, -0.0272), rotation=(math.radians(90), 0, 0))
    floor = bpy.context.active_object
    floor.name = "Presentation surface"
    floor.data.materials.append(mat("Midnight Surface", (0.008, 0.012, 0.018), 0.12, 0.28))

    camera_data = bpy.data.cameras.new("Camera")
    camera = bpy.data.objects.new("Camera", camera_data)
    bpy.context.collection.objects.link(camera)
    bpy.context.scene.camera = camera
    camera.location = (0.078, -0.105, 0.058)
    camera.data.lens = 62
    look_at(camera, (0, -0.001, 0))

    add_area("Warm key", (-0.06, -0.08, 0.105), 20, 0.075, (1.0, 0.62, 0.38))
    add_area("Cool fill", (0.08, -0.055, 0.07), 13, 0.065, (0.34, 0.55, 1.0))
    add_area("Edge light", (0.015, 0.075, 0.09), 30, 0.055, (1.0, 0.12, 0.035))

    world = bpy.context.scene.world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.003, 0.005, 0.009, 1.0)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.16

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1200
    scene.render.resolution_y = 1200
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = str(PREVIEW)
    scene.view_settings.look = "AgX - Medium High Contrast"
    scene.view_settings.exposure = -0.8

    bpy.ops.wm.save_as_mainfile(filepath=str(BLEND))
    bpy.ops.render.render(write_still=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(BLEND))
    print(f"BLEND={BLEND}")
    print(f"PREVIEW={PREVIEW}")


if __name__ == "__main__":
    main()
