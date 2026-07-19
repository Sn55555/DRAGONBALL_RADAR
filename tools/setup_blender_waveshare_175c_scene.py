"""Create the real Waveshare ESP32-S3-Touch-AMOLED-1.75C enclosure scene."""

from pathlib import Path
import math

import bpy
from mathutils import Vector


ROOT = Path("/Users/sn5/dragonBall_Radar")
ASSET_DIR = ROOT / "artifacts" / "blender"
BLEND = ASSET_DIR / "dragon_radar_waveshare_175c.blend"
PREVIEW = ASSET_DIR / "dragon_radar_waveshare_175c_preview.png"
SIDE_PREVIEW = ASSET_DIR / "dragon_radar_waveshare_175c_side_detail.png"


def material(name, color, metallic=0.0, roughness=0.4, emission=None, strength=0.0):
    value = bpy.data.materials.new(name)
    value.use_nodes = True
    bsdf = value.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    if emission:
        bsdf.inputs["Emission Color"].default_value = (*emission, 1.0)
        bsdf.inputs["Emission Strength"].default_value = strength
    return value


def anodized_aluminum_material():
    """Fine bead-blasted anodized aluminum with restrained micro-normal variation."""
    value = bpy.data.materials.new("Fine bead-blasted anodized aluminum")
    value.use_nodes = True
    nodes = value.node_tree.nodes
    links = value.node_tree.links
    bsdf = nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (0.34, 0.37, 0.40, 1.0)
    bsdf.inputs["Metallic"].default_value = 0.88
    bsdf.inputs["Roughness"].default_value = 0.31

    micro = nodes.new("ShaderNodeTexNoise")
    micro.name = "Bead blast micro grain"
    micro.inputs["Scale"].default_value = 960.0
    micro.inputs["Detail"].default_value = 2.2
    micro.inputs["Roughness"].default_value = 0.64

    bump = nodes.new("ShaderNodeBump")
    bump.name = "Subtle aluminum grain"
    bump.inputs["Strength"].default_value = 0.028
    bump.inputs["Distance"].default_value = 0.000018
    links.new(micro.outputs["Fac"], bump.inputs["Height"])
    links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])

    macro = nodes.new("ShaderNodeTexNoise")
    macro.name = "Anodized roughness variation"
    macro.inputs["Scale"].default_value = 90.0
    macro.inputs["Detail"].default_value = 3.0
    macro.inputs["Roughness"].default_value = 0.58
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position = 0.28
    ramp.color_ramp.elements[0].color = (0.29, 0.29, 0.29, 1.0)
    ramp.color_ramp.elements[1].position = 0.72
    ramp.color_ramp.elements[1].color = (0.34, 0.34, 0.34, 1.0)
    links.new(macro.outputs["Fac"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], bsdf.inputs["Roughness"])
    return value


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
    return obj


def lathe_body(name, profile, segments, mat):
    """Revolve (radius, y) points around the Y axis."""
    verts = []
    for radius, y in profile:
        for index in range(segments):
            angle = 2.0 * math.pi * index / segments
            verts.append((radius * math.cos(angle), y, radius * math.sin(angle)))
    faces = []
    rings = len(profile)
    for ring in range(rings - 1):
        for index in range(segments):
            nxt = (index + 1) % segments
            a = ring * segments + index
            b = ring * segments + nxt
            c = (ring + 1) * segments + nxt
            d = (ring + 1) * segments + index
            faces.append((a, b, c, d))
    mesh = bpy.data.meshes.new(f"{name} Mesh")
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(mat)
    for polygon in mesh.polygons:
        polygon.use_smooth = True
    return obj


def add_disc(name, radius, depth, y, mat, bevel=0.0):
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=192,
        radius=radius,
        depth=depth,
        location=(0, y, 0),
        rotation=(math.radians(90), 0, 0),
    )
    obj = bpy.context.active_object
    obj.name = name
    obj.data.materials.append(mat)
    if bevel:
        mod = obj.modifiers.new("Edge radius", "BEVEL")
        mod.width = bevel
        mod.segments = 5
    return obj


def add_ring(name, radius, tube, y, mat):
    bpy.ops.mesh.primitive_torus_add(
        major_radius=radius,
        minor_radius=tube,
        major_segments=192,
        minor_segments=16,
        location=(0, y, 0),
        rotation=(math.radians(90), 0, 0),
    )
    obj = bpy.context.active_object
    obj.name = name
    obj.data.materials.append(mat)
    return obj


def add_beveled_box(name, location, dimensions, mat, bevel_width):
    bpy.ops.mesh.primitive_cube_add(location=location)
    obj = bpy.context.active_object
    obj.name = name
    obj.dimensions = dimensions
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(mat)
    mod = obj.modifiers.new("Rounded", "BEVEL")
    mod.width = bevel_width
    mod.segments = 8
    return obj


def capsule_prism(name, length, height, thickness, mat, arc_segments=16, edge_bevel=0.00008):
    """Create a true pill outline in local Y/Z and extrude it along local X."""
    radius = height / 2.0
    straight_half = (length - height) / 2.0
    outline = []
    for index in range(arc_segments + 1):
        angle = -math.pi / 2.0 + math.pi * index / arc_segments
        outline.append((straight_half + radius * math.cos(angle), radius * math.sin(angle)))
    for index in range(arc_segments + 1):
        angle = math.pi / 2.0 + math.pi * index / arc_segments
        outline.append((-straight_half + radius * math.cos(angle), radius * math.sin(angle)))

    verts = []
    for x in (-thickness / 2.0, thickness / 2.0):
        verts.extend((x, y, z) for y, z in outline)
    count = len(outline)
    faces = [tuple(reversed(range(count))), tuple(range(count, count * 2))]
    for index in range(count):
        nxt = (index + 1) % count
        faces.append((index, nxt, count + nxt, count + index))
    mesh = bpy.data.meshes.new(f"{name} Mesh")
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(mat)
    bevel = obj.modifiers.new("CNC edge fillet", "BEVEL")
    bevel.width = edge_bevel
    bevel.segments = 4
    return obj


def add_side_capsule(name, z, body_mat, gasket_mat):
    """Create a flat pill button seated in a thin black gasket on the curved right wall."""
    outer_radius = 0.0275
    theta = math.asin(z / outer_radius)
    normal = Vector((math.cos(theta), 0.0, math.sin(theta)))
    rotation = (0.0, -theta, 0.0)

    gasket = capsule_prism(
        f"{name} black gasket", 0.00535, 0.00270, 0.00038, gasket_mat, edge_bevel=0.00007
    )
    gasket.location = normal * 0.02717 + Vector((0, -0.00075, 0))
    gasket.rotation_euler = rotation

    button = capsule_prism(
        name, 0.00475, 0.00212, 0.00072, body_mat, edge_bevel=0.00010
    )
    button.location = normal * 0.02750 + Vector((0, -0.00075, 0))
    button.rotation_euler = rotation
    return button


def add_side_hole(name, z, mat):
    """Add a flush black acoustic aperture on the curved right side wall."""
    outer_radius = 0.0275
    theta = math.asin(z / outer_radius)
    normal = Vector((math.cos(theta), 0.0, math.sin(theta)))
    bpy.ops.mesh.primitive_cylinder_add(vertices=48, radius=0.00052, depth=0.00024)
    hole = bpy.context.active_object
    hole.name = name
    hole.location = normal * 0.02748 + Vector((0, -0.00035, 0))
    hole.rotation_mode = "QUATERNION"
    hole.rotation_quaternion = normal.to_track_quat("Z", "Y")
    hole.data.materials.append(mat)
    return hole


def main():
    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)

    aluminum = anodized_aluminum_material()
    aluminum_edge = material("Machined aluminum highlight", (0.46, 0.50, 0.54), 0.94, 0.20)
    bezel = material("Black display bezel", (0.004, 0.006, 0.008), 0.08, 0.15)
    glass = material("AMOLED glass", (0.002, 0.012, 0.009), 0.04, 0.08)
    dark = material("Port and seam", (0.004, 0.006, 0.008), 0.12, 0.36)
    green = material("Dragon Radar green", (0.002, 0.20, 0.035), 0.02, 0.2, (0.002, 1.0, 0.08), 4.5)
    amber = material("Dragon Radar target", (0.62, 0.025, 0.002), 0.04, 0.18, (1.0, 0.02, 0.001), 5.0)

    # Official product dimensions: maximum diameter 55.00 mm, thickness 15.05 mm.
    # The profile reproduces the characteristic convex CNC badge/watch enclosure.
    profile = [
        (0.00001, -0.00635),
        (0.0219, -0.00635),
        (0.0245, -0.00625),
        (0.0258, -0.00555),
        (0.0268, -0.0040),
        (0.0275, -0.0012),
        (0.02735, 0.0021),
        (0.02645, 0.00465),
        (0.0250, 0.00645),
        (0.0226, 0.007525),
        (0.00001, 0.007525),
    ]
    body = lathe_body("1.75C one-piece CNC aluminum enclosure", profile, 256, aluminum)
    body["official_outer_diameter_mm"] = 55.00
    body["official_thickness_mm"] = 15.05

    # 48.96 mm black face and 43.76 mm active touch/display area.
    add_disc("Black bezel - 48.96mm", 0.02448, 0.00062, -0.00645, bezel, 0.00030)
    add_disc("AMOLED touch glass - 43.76mm", 0.02188, 0.00038, -0.00682, glass, 0.00020)
    add_ring("Precision bezel edge", 0.02455, 0.00028, -0.00666, aluminum_edge)
    add_ring("Rear cover seam", 0.02415, 0.00016, 0.00720, dark)

    # Actual C version: two flat pill buttons with dark perimeter gaskets.
    add_side_capsule("PWR side button", 0.0114, aluminum_edge, dark)
    add_side_capsule("BOOT side button", -0.0110, aluminum_edge, dark)

    # Five small speaker apertures between the two buttons on the right wall.
    for idx, z in enumerate((0.0060, 0.0036, 0.0012, -0.0012, -0.0036)):
        add_side_hole(f"Speaker aperture {idx + 1}", z, dark)

    # Bottom USB-C opening and lanyard/flat-base detail.
    add_beveled_box("USB-C opening", (0, 0.0012, -0.02715), (0.0090, 0.0048, 0.00105), dark, 0.00048)
    add_beveled_box("Bottom lanyard recess", (0, 0.0055, -0.02665), (0.0130, 0.0034, 0.00135), dark, 0.00062)
    add_ring("Lanyard loop", 0.00215, 0.00042, 0.0048, aluminum_edge).location.z = -0.02715
    bpy.context.active_object.scale.x = 1.65

    # Dragon Radar UI under the glass.
    ui_y = -0.00708
    for radius in (0.0061, 0.0120, 0.0180):
        add_ring(f"Radar range {radius * 1000:.0f}", radius, 0.00010, ui_y, green)
    bpy.ops.mesh.primitive_cube_add(location=(0, ui_y - 0.00005, 0))
    sweep = bpy.context.active_object
    sweep.name = "Radar sweep"
    sweep.dimensions = (0.00018, 0.00012, 0.036)
    sweep.rotation_euler[1] = math.radians(-36)
    sweep.data.materials.append(green)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    for idx, (x, z) in enumerate(((-0.010, 0.007), (0.008, 0.012), (0.012, -0.006), (-0.006, -0.013), (0.002, 0.002))):
        bpy.ops.mesh.primitive_uv_sphere_add(segments=32, ring_count=16, radius=0.00062, location=(x, ui_y - 0.00020, z))
        target = bpy.context.active_object
        target.name = f"Target {idx + 1}"
        target.data.materials.append(amber if idx == 1 else green)

    # Presentation floor and lighting.
    bpy.ops.mesh.primitive_plane_add(size=0.32, location=(0, 0, -0.02825))
    floor = bpy.context.active_object
    floor.name = "Presentation surface"
    floor.data.materials.append(material("Midnight floor", (0.006, 0.010, 0.016), 0.18, 0.30))

    camera_data = bpy.data.cameras.new("Camera")
    camera = bpy.data.objects.new("Camera", camera_data)
    bpy.context.collection.objects.link(camera)
    bpy.context.scene.camera = camera
    camera.location = (0.079, -0.112, 0.057)
    camera.data.lens = 62
    look_at(camera, (0, -0.001, -0.0005))

    add_area("Large neutral key", (-0.065, -0.080, 0.105), 11, 0.105, (1.0, 0.88, 0.76))
    add_area("Cool fill", (0.090, -0.045, 0.072), 7, 0.090, (0.42, 0.62, 1.0))
    add_area("Warm rear edge", (0.005, 0.080, 0.095), 15, 0.080, (1.0, 0.22, 0.06))

    world = bpy.context.scene.world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.002, 0.004, 0.008, 1.0)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.15

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1200
    scene.render.resolution_y = 1200
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = str(PREVIEW)
    scene.view_settings.look = "AgX - Medium High Contrast"
    scene.view_settings.exposure = -1.20

    hero_location = camera.location.copy()
    hero_rotation = camera.rotation_euler.copy()
    hero_lens = camera.data.lens

    bpy.ops.wm.save_as_mainfile(filepath=str(BLEND))
    bpy.ops.render.render(write_still=True)

    # Official-photo-style three-quarter detail focused on the right-side controls.
    detail_light = add_area("Button detail softbox", (0.092, -0.055, 0.045), 9, 0.060, (0.82, 0.90, 1.0))
    look_at(detail_light, (0.024, -0.001, 0.0))
    camera.location = (0.070, -0.095, 0.035)
    camera.data.lens = 90
    look_at(camera, (0.020, -0.001, 0.0005))
    scene.render.filepath = str(SIDE_PREVIEW)
    bpy.ops.render.render(write_still=True)
    bpy.data.objects.remove(detail_light, do_unlink=True)

    camera.location = hero_location
    camera.rotation_euler = hero_rotation
    camera.data.lens = hero_lens
    scene.render.filepath = str(PREVIEW)
    bpy.ops.wm.save_as_mainfile(filepath=str(BLEND))
    print(f"BLEND={BLEND}")
    print(f"PREVIEW={PREVIEW}")
    print(f"SIDE_PREVIEW={SIDE_PREVIEW}")


if __name__ == "__main__":
    main()
