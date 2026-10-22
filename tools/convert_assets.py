"""
NIGHT SHIFT: DATA PURGE - asset converter.

Converts the selected low-poly GLB / FBX assets from the NightShiftAssets
library into compact Luau ModuleScripts (geometry + textures) that the client
turns into real MeshParts at runtime with AssetService:CreateEditableMesh.

No Roblox upload or asset ID is required: the place file carries the data.

Usage (from the night-shift folder):
    python tools/convert_assets.py --library ".." --out src/art

Requires Pillow (pip install pillow).
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import math
import struct
import sys
import zlib
from pathlib import Path

from PIL import Image

STUDS_PER_METER = 3.5
MAX_TEXTURE = 128

# --------------------------------------------------------------------------
# Selection: every asset key used by the game, grouped by purpose.
# targetHeight (studs) overrides the uniform metre scale (used for characters).
# --------------------------------------------------------------------------

SELECTION: dict[str, dict] = {}


def sel(keys: list[str], **opts) -> None:
    for k in keys:
        SELECTION[k] = dict(opts)


sel([
    # desks: clean dark-wood variants only (the weathered set reads as neglect)
    "office__desks__desk2", "office__desks__desk2_alt", "office__desks__desk2_alt2",
    "office__desks__desk2_alt3", "office__desks__desk2_alt4", "office__desks__desk2_corner",
    # chairs (muted upholstery only)
    "office__chairs__office_chair_grey", "office__chairs__office_chair_black",
    "office__chairs__office_chair_blue", "office__chairs__office_chair_grey_alt",
    "office__chairs__office_chair_black_alt", "office__chairs__office_chair_blue_alt",
    "office__chairs__conference_chair_grey",
    # computers
    "office__computers__computer_monitor", "office__computers__computer_tower",
    "office__computers__computer_tower_alt", "office__computers__computer_keyboard",
    "office__computers__computer_mouse",
    # desk objects + kitchen (a few purposeful pieces per surface)
    "office__extras__circular_desklamp", "office__extras__square_desklamp",
    "office__extras__coffee_machine", "office__extras__water_cooler_bottle_attached",
    "office__extras__mug", "office__extras__mug_alt", "office__extras__mug_alt2",
    "office__extras__mug_alt3", "office__extras__desk_phone_with_cable",
    "office__extras__wall_clock", "office__extras__whiteboard",
    "office__stationary__paper_stack", "office__stationary__paper_stack_large",
    "office__stationary__pen2",
    "office__book_things__book_case_with_back_small", "office__book_things__books",
    "office__book_things__file_binder",
    "office__book_things__file_binder_alt", "office__book_things__file_binder_alt2",
    "office__file_cabinets__file_cabinet_small", "office__file_cabinets__file_cabinet_larger",
    "office__file_cabinets__file_cabinet_largest",
    "office__dividers__divider_black_low", "office__dividers__divider_black_low_half",
    "office__couches__couch_green",
    "office__carpet_floor__floor_3x3",
    # classic 64 props (utility hall, wall fittings, storage door, alley)
    "classic64__blend__panel_electric", "classic64__blend__panel_thermostat",
    "classic64__blend__panel_heater", "classic64__blend__electrical_junctionbox_small",
    "classic64__blend__fire_extenguisher_case",
    "classic64__blend__papers_envolope_redacted", "classic64__blend__papers_log_1_stack",
    "classic64__blend__metal_rack_stackable", "classic64__blend__door_brown_a",
    "classic64__blend__wood_pallet", "classic64__blend__manhole_cover", "classic64__blend__yellow_post",
    # (branded-looking grocery props intentionally left out: original art only)
    # misc packs
    "oldstuff__barrel", "oldstuff__telephone",
])

# Urban exterior / alley / hall services. These source models keep their scene
# position, so `recenter` moves the origin to the footprint centre at floor level
# (the same pivot every other prop uses) without changing their metre scale.
sel([
    "urban__litter__dumpsters__dumpster_lid_closed",
    "urban__litter__metal_trashcan__metaltrashcan_closed",
    "urban__litter__trash__trashbag_1", "urban__litter__trash__trashbag_2_white",
    "urban__litter__trashcan__trash_can",
    "urban__pipes__pipe", "urban__vents__duct_long",
    "urban__fences__plackard_wall__plackard_closed", "urban__fences__plackard_wall__plackard_broken",
    "urban__traffic_lights__street_light_clean",
    "urban__cones_barriers__bollards__concrete_retro_bollard_light",
], recenter=True)

# characters (rest pose, static, normalised height in studs)
sel(["characters__male__character_04"], targetHeight=6.3)  # the former employee outside
sel(["characters__male__character_01", "characters__male__character_05"], targetHeight=5.6)

# Objects whose source units do not match the metre convention get explicit heights.
SELECTION["oldstuff__barrel"]["targetHeight"] = 3.0
SELECTION["oldstuff__telephone"]["targetHeight"] = 0.55
SELECTION["classic64__blend__wood_pallet"]["targetHeight"] = 0.5

# Standalone surface textures (walls, floors, paper) used on generated parts.
# The client tints each one toward its palette target (Atmosphere SURFACES), so
# these are chosen for clean, low-contrast detail: no stains, moss or rust indoors.
SURFACE_TEXTURES = {
    "wall_office": "horror__horror_wall_10",    # fine pinstripe wallpaper above the cream wainscot
    "wall_lower": "horror__horror_wall_04",     # warm plaster (counter and reception fronts)
    "wall_concrete": "horror__horror_stone_11",  # utility hall: clean painted block, no damp gradient
    "wall_kitchen": "horror__horror_wall_01",   # clean cream plaster
    "ceiling_tile": "horror__horror_floor_12",  # grey acoustic tile grid (reads clean once tinted)
    "floor_tile": "horror__horror_floor_12",    # kitchenette vinyl tiles
    "floor_lobby": "horror__horror_floor_11",   # lobby stone tiles
    "floor_concrete": "horror__horror_stone_12",  # sealed grey concrete
    "brick_alley": "horror__horror_brick_11",   # grey brick, no moss
    "metal_door": "horror__horror_metal_11",
    "metal_panel": "horror__horror_metal_05",
    "paper_note": "paper__texture__08773030f66091de",
}

# --------------------------------------------------------------------------
# Math helpers
# --------------------------------------------------------------------------


def mat_identity():
    return [1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0]


def mat_mul(a, b):
    # column-major 4x4 (glTF convention)
    out = [0.0] * 16
    for c in range(4):
        for r in range(4):
            out[c * 4 + r] = sum(a[k * 4 + r] * b[c * 4 + k] for k in range(4))
    return out


def mat_from_trs(t, r, s):
    x, y, z, w = r
    xx, yy, zz = x * x, y * y, z * z
    xy, xz, yz = x * y, x * z, y * z
    wx, wy, wz = w * x, w * y, w * z
    m = [
        (1 - 2 * (yy + zz)) * s[0], (2 * (xy + wz)) * s[0], (2 * (xz - wy)) * s[0], 0,
        (2 * (xy - wz)) * s[1], (1 - 2 * (xx + zz)) * s[1], (2 * (yz + wx)) * s[1], 0,
        (2 * (xz + wy)) * s[2], (2 * (yz - wx)) * s[2], (1 - 2 * (xx + yy)) * s[2], 0,
        t[0], t[1], t[2], 1,
    ]
    return m


def mat_apply(m, v):
    x, y, z = v
    return (
        m[0] * x + m[4] * y + m[8] * z + m[12],
        m[1] * x + m[5] * y + m[9] * z + m[13],
        m[2] * x + m[6] * y + m[10] * z + m[14],
    )


def mat_apply_dir(m, v):
    x, y, z = v
    d = (m[0] * x + m[4] * y + m[8] * z, m[1] * x + m[5] * y + m[9] * z, m[2] * x + m[6] * y + m[10] * z)
    n = math.sqrt(d[0] ** 2 + d[1] ** 2 + d[2] ** 2) or 1.0
    return (d[0] / n, d[1] / n, d[2] / n)


def mat_det3(m):
    return (
        m[0] * (m[5] * m[10] - m[9] * m[6])
        - m[4] * (m[1] * m[10] - m[9] * m[2])
        + m[8] * (m[1] * m[6] - m[5] * m[2])
    )


# --------------------------------------------------------------------------
# GLB reader
# --------------------------------------------------------------------------

COMP = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4)}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}


def read_glb(path: Path):
    data = path.read_bytes()
    _, _, length = struct.unpack("<III", data[:12])
    off = 12
    js = None
    binchunk = b""
    while off < length:
        clen, ctype = struct.unpack("<II", data[off : off + 8])
        chunk = data[off + 8 : off + 8 + clen]
        if ctype == 0x4E4F534A:
            js = json.loads(chunk)
        elif ctype == 0x004E4942:
            binchunk = chunk
        off += 8 + clen
    return js, binchunk


def accessor(js, binc, idx):
    acc = js["accessors"][idx]
    bv = js["bufferViews"][acc["bufferView"]]
    fmt, size = COMP[acc["componentType"]]
    n = NCOMP[acc["type"]]
    stride = bv.get("byteStride", size * n)
    base = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    out = []
    norm = acc.get("normalized", False)
    for i in range(acc["count"]):
        vals = struct.unpack_from("<" + fmt * n, binc, base + i * stride)
        if norm and fmt in "BH":
            vals = tuple(v / (255.0 if fmt == "B" else 65535.0) for v in vals)
        out.append(vals if n > 1 else vals[0])
    return out


def glb_image(js, binc, tex_index) -> Image.Image | None:
    tex = js["textures"][tex_index]
    src = tex.get("source")
    if src is None:
        return None
    img = js["images"][src]
    if "bufferView" not in img:
        return None
    bv = js["bufferViews"][img["bufferView"]]
    raw = binc[bv.get("byteOffset", 0) : bv.get("byteOffset", 0) + bv["byteLength"]]
    return Image.open(io.BytesIO(raw)).convert("RGBA")


def load_glb_model(path: Path):
    """Returns list of primitives: dict(pos, nrm, uv, idx, image, color, double)."""
    js, binc = read_glb(path)
    prims = []

    def visit(node_idx, parent):
        node = js["nodes"][node_idx]
        if "matrix" in node:
            local = list(node["matrix"])
        else:
            local = mat_from_trs(node.get("translation", [0, 0, 0]), node.get("rotation", [0, 0, 0, 1]), node.get("scale", [1, 1, 1]))
        world = mat_mul(parent, local)
        if "mesh" in node and "skin" not in node:
            mesh = js["meshes"][node["mesh"]]
            flip = mat_det3(world) < 0
            for p in mesh["primitives"]:
                if p.get("mode", 4) != 4:
                    continue
                a = p["attributes"]
                pos = [mat_apply(world, v) for v in accessor(js, binc, a["POSITION"])]
                nrm = [mat_apply_dir(world, v) for v in accessor(js, binc, a["NORMAL"])] if "NORMAL" in a else None
                uv = accessor(js, binc, a["TEXCOORD_0"]) if "TEXCOORD_0" in a else None
                idx = accessor(js, binc, p["indices"]) if "indices" in p else list(range(len(pos)))
                if flip:
                    idx = [idx[i + j] for i in range(0, len(idx), 3) for j in (0, 2, 1)]
                image, color, double = None, (1.0, 1.0, 1.0, 1.0), False
                if "material" in p:
                    mat = js["materials"][p["material"]]
                    double = bool(mat.get("doubleSided", False))
                    pbr = mat.get("pbrMetallicRoughness", {})
                    color = tuple(pbr.get("baseColorFactor", [1, 1, 1, 1]))
                    if "baseColorTexture" in pbr:
                        image = glb_image(js, binc, pbr["baseColorTexture"]["index"])
                prims.append(dict(pos=pos, nrm=nrm, uv=uv, idx=idx, image=image, color=color, double=double))
        for c in node.get("children", []):
            visit(c, world)

    scene = js["scenes"][js.get("scene", 0)]
    for n in scene["nodes"]:
        visit(n, mat_identity())
    # skinned meshes: take the mesh in bind pose (vertex data is already in mesh space)
    if not prims:
        for node in js["nodes"]:
            if "mesh" in node:
                for p in js["meshes"][node["mesh"]]["primitives"]:
                    a = p["attributes"]
                    pos = accessor(js, binc, a["POSITION"])
                    prims.append(dict(pos=pos, nrm=accessor(js, binc, a["NORMAL"]) if "NORMAL" in a else None,
                                      uv=accessor(js, binc, a["TEXCOORD_0"]) if "TEXCOORD_0" in a else None,
                                      idx=accessor(js, binc, p["indices"]), image=None, color=(1, 1, 1, 1), double=False))
    return prims


# --------------------------------------------------------------------------
# Binary FBX reader (geometry + UVs only; static bind pose)
# --------------------------------------------------------------------------


def _fbx_read_props(data, off, count):
    props = []
    for _ in range(count):
        t = chr(data[off]); off += 1
        if t == "Y":
            props.append(struct.unpack_from("<h", data, off)[0]); off += 2
        elif t == "C":
            props.append(bool(data[off])); off += 1
        elif t == "I":
            props.append(struct.unpack_from("<i", data, off)[0]); off += 4
        elif t == "F":
            props.append(struct.unpack_from("<f", data, off)[0]); off += 4
        elif t == "D":
            props.append(struct.unpack_from("<d", data, off)[0]); off += 8
        elif t == "L":
            props.append(struct.unpack_from("<q", data, off)[0]); off += 8
        elif t in "fdlib":
            n, enc, clen = struct.unpack_from("<III", data, off); off += 12
            raw = data[off : off + clen]; off += clen
            if enc == 1:
                raw = zlib.decompress(raw)
            code = {"f": "f", "d": "d", "l": "q", "i": "i", "b": "?"}[t]
            props.append(list(struct.unpack("<" + code * n, raw)))
        elif t in "SR":
            n = struct.unpack_from("<I", data, off)[0]; off += 4
            raw = data[off : off + n]; off += n
            props.append(raw.decode("utf-8", "replace") if t == "S" else raw)
        else:
            raise ValueError("bad fbx prop type " + t)
    return props, off


def _fbx_read_node(data, off, v75):
    if v75:
        end, nprops, plen = struct.unpack_from("<QQQ", data, off); off += 24
    else:
        end, nprops, plen = struct.unpack_from("<III", data, off); off += 12
    if end == 0:
        return None, off
    nlen = data[off]; off += 1
    name = data[off : off + nlen].decode("ascii", "replace"); off += nlen
    props, _ = _fbx_read_props(data, off, nprops)
    off = off + plen
    children = []
    while off < end:
        child, off = _fbx_read_node(data, off, v75)
        if child is None:  # null record terminates the child list
            break
        children.append(child)
    return dict(name=name, props=props, children=children), end


def read_fbx(path: Path):
    data = path.read_bytes()
    assert data[:20] == b"Kaydara FBX Binary  ", "only binary FBX supported"
    version = struct.unpack_from("<I", data, 23)[0]
    v75 = version >= 7500
    off = 27
    nodes = []
    while off < len(data):
        node, off = _fbx_read_node(data, off, v75)
        if node is None:
            break
        nodes.append(node)
    return nodes


def fbx_child(node, name):
    for c in node["children"]:
        if c["name"] == name:
            return c
    return None


def load_fbx_model(path: Path, texture_path: Path | None):
    nodes = read_fbx(path)
    objects = next(n for n in nodes if n["name"] == "Objects")
    prims = []
    image = Image.open(texture_path).convert("RGBA") if texture_path and texture_path.exists() else None
    # mesh Model rotation (Mixamo exports carry a -90 X pre-rotation from Z-up mesh space)
    rot = (0.0, 0.0, 0.0)
    for m in objects["children"]:
        if m["name"] == "Model" and len(m["props"]) > 2 and m["props"][2] == "Mesh":
            p70 = fbx_child(m, "Properties70")
            for prop in (p70["children"] if p70 else []):
                if prop["props"][0] == "Lcl Rotation":
                    rot = tuple(float(v) for v in prop["props"][4:7])
            break
    rx, ry, rz = (math.radians(a) for a in rot)

    def rotate(p):
        x, y, z = p
        y, z = y * math.cos(rx) - z * math.sin(rx), y * math.sin(rx) + z * math.cos(rx)
        x, z = x * math.cos(ry) + z * math.sin(ry), -x * math.sin(ry) + z * math.cos(ry)
        x, y = x * math.cos(rz) - y * math.sin(rz), x * math.sin(rz) + y * math.cos(rz)
        return (x, y, z)

    for geo in objects["children"]:
        if geo["name"] != "Geometry":
            continue
        vnode = fbx_child(geo, "Vertices")
        inode = fbx_child(geo, "PolygonVertexIndex")
        if not vnode or not inode:
            continue
        verts = vnode["props"][0]
        pvi = inode["props"][0]
        uvlayer = fbx_child(geo, "LayerElementUV")
        uvs, uvidx, uvmap, uvref = None, None, None, None
        if uvlayer:
            uvs = fbx_child(uvlayer, "UV")["props"][0]
            ui = fbx_child(uvlayer, "UVIndex")
            uvidx = ui["props"][0] if ui else None
            uvmap = fbx_child(uvlayer, "MappingInformationType")["props"][0]
            uvref = fbx_child(uvlayer, "ReferenceInformationType")["props"][0]
        pos, uv, idx = [], [], []
        poly = []
        for corner, raw in enumerate(pvi):
            vi = raw if raw >= 0 else ~raw
            p = rotate((verts[vi * 3], verts[vi * 3 + 1], verts[vi * 3 + 2]))
            if uvs is not None:
                if uvmap == "ByPolygonVertex":
                    k = uvidx[corner] if uvref == "IndexToDirect" else corner
                else:
                    k = vi
                t = (uvs[k * 2], 1.0 - uvs[k * 2 + 1])  # FBX v is bottom-up
            else:
                t = (0.0, 0.0)
            poly.append(len(pos))
            pos.append(p)
            uv.append(t)
            if raw < 0:
                for i in range(1, len(poly) - 1):
                    idx += [poly[0], poly[i], poly[i + 1]]
                poly = []
        prims.append(dict(pos=pos, nrm=None, uv=uv, idx=idx, image=image, color=(1, 1, 1, 1), double=False))
    return prims


# --------------------------------------------------------------------------
# Output encoding
# --------------------------------------------------------------------------


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def compute_normals(pos, idx):
    acc = [[0.0, 0.0, 0.0] for _ in pos]
    for i in range(0, len(idx), 3):
        a, b, c = idx[i], idx[i + 1], idx[i + 2]
        pa, pb, pc = pos[a], pos[b], pos[c]
        u = (pb[0] - pa[0], pb[1] - pa[1], pb[2] - pa[2])
        v = (pc[0] - pa[0], pc[1] - pa[1], pc[2] - pa[2])
        n = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
        for k in (a, b, c):
            acc[k][0] += n[0]; acc[k][1] += n[1]; acc[k][2] += n[2]
    out = []
    for n in acc:
        l = math.sqrt(n[0] ** 2 + n[1] ** 2 + n[2] ** 2) or 1.0
        out.append((n[0] / l, n[1] / l, n[2] / l))
    return out


def encode_565(img: Image.Image) -> bytes:
    raw = img.convert("RGB").tobytes()
    out = bytearray(len(raw) // 3 * 2)
    o = 0
    for i in range(0, len(raw), 3):
        v = ((raw[i] >> 3) << 11) | ((raw[i + 1] >> 2) << 5) | (raw[i + 2] >> 3)
        out[o] = v & 255
        out[o + 1] = v >> 8
        o += 2
    return bytes(out)


def write_texture_module(path: Path, img: Image.Image):
    w, h = img.size
    path.write_text(
        "--!strict\n-- Generated by tools/convert_assets.py. Do not edit.\n"
        f'return {{ w = {w}, h = {h}, format = "565", data = "{b64(encode_565(img))}" }}\n',
        encoding="utf-8",
    )


def prep_image(img: Image.Image) -> Image.Image:
    w, h = img.size
    # PSX-scale textures: 64px for small maps, 128px only for big atlases / characters
    max_size = 128 if max(w, h) >= 400 else 64
    scale = min(1.0, max_size / max(w, h))
    if scale < 1.0:
        img = img.resize((max(1, round(w * scale)), max(1, round(h * scale))), Image.LANCZOS)
    return img.convert("RGBA")


class Atlas:
    """Shelf-packed texture atlas shared by every baked mesh chunk."""

    WIDTH = 1024
    PAD = 2

    def __init__(self):
        self.images: dict[str, Image.Image] = {}
        self.rects: dict[str, tuple[int, int, int, int]] = {}
        self.alpha: set[str] = set()
        self.height = 0

    def add(self, img: Image.Image) -> str:
        img = prep_image(img)
        raw = img.tobytes()
        digest = hashlib.sha1(raw).hexdigest()[:12]
        if digest not in self.images:
            self.images[digest] = img
            if any(raw[i] < 250 for i in range(3, len(raw), 4)):
                self.alpha.add(digest)
        return digest

    def pack(self):
        self.images["white"] = Image.new("RGBA", (8, 8), (255, 255, 255, 255))
        order = sorted(self.images.items(), key=lambda kv: -kv[1].size[1])
        x = y = shelf = 0
        for key, img in order:
            w, h = img.size
            pw, ph = w + self.PAD * 2, h + self.PAD * 2
            if x + pw > self.WIDTH:
                x = 0
                y += shelf
                shelf = 0
            self.rects[key] = (x + self.PAD, y + self.PAD, w, h)
            x += pw
            shelf = max(shelf, ph)
        self.height = ((y + shelf + 63) // 64) * 64

    def render(self) -> Image.Image:
        atlas = Image.new("RGB", (self.WIDTH, self.height), (128, 128, 128))
        for key, (x, y, w, h) in self.rects.items():
            img = self.images[key].convert("RGB")
            big = img.resize((w + self.PAD * 2, h + self.PAD * 2), Image.NEAREST)  # edge-extend padding
            atlas.paste(big, (x - self.PAD, y - self.PAD))
            atlas.paste(img, (x, y))
        return atlas

    def map_uv(self, key: str, u: float, v: float) -> tuple[float, float]:
        x, y, w, h = self.rects[key]
        u = min(max(u, 0.0), 1.0)
        v = min(max(v, 0.0), 1.0)
        px = x + 0.5 + u * (w - 1)  # keep half a texel inside the cell
        py = y + 0.5 + v * (h - 1)
        return px / self.WIDTH, py / self.height

    def average(self, key: str) -> tuple[float, float, float]:
        r, g, b = self.images[key].convert("RGB").resize((1, 1), Image.BOX).getpixel((0, 0))
        return r / 255, g / 255, b / 255


def prepare_model(key: str, prims, opts, atlas: Atlas):
    """Scale to studs and register textures."""
    allp = [p for pr in prims for p in pr["pos"]]
    if not allp:
        raise ValueError("no geometry")
    mn = [min(p[i] for p in allp) for i in range(3)]
    mx = [max(p[i] for p in allp) for i in range(3)]
    height = mx[1] - mn[1]
    scale = opts["targetHeight"] / height if ("targetHeight" in opts and height > 0) else STUDS_PER_METER
    centred = "targetHeight" in opts or opts.get("recenter", False)
    origin = ((mn[0] + mx[0]) / 2, mn[1], (mn[2] + mx[2]) / 2) if centred else (0.0, 0.0, 0.0)
    out = []
    for pr in prims:
        pos = [((p[0] - origin[0]) * scale, (p[1] - origin[1]) * scale, (p[2] - origin[2]) * scale) for p in pr["pos"]]
        idx = list(pr["idx"])
        nrm = pr["nrm"] or compute_normals(pos, idx)
        uv = pr["uv"] or [(0.0, 0.0)] * len(pos)
        if pr["double"]:
            idx = idx + [x for i in range(0, len(pr["idx"]), 3) for x in (pr["idx"][i], pr["idx"][i + 2], pr["idx"][i + 1])]
        tex = atlas.add(pr["image"]) if pr["image"] is not None else None
        out.append(dict(pos=pos, nrm=nrm, uv=uv, idx=idx, tex=tex, color=tuple(pr["color"][:3])))
    return out


def emit_model(key: str, prepared, atlas: Atlas, outdir: Path):
    EPS = 0.02
    parts = []
    white = atlas.map_uv("white", 0.5, 0.5)
    for pr in prepared:
        pos, nrm, uv, idx, tex = pr["pos"], pr["nrm"], pr["uv"], pr["idx"], pr["tex"]
        color = list(pr["color"])
        P, N, U, I = [], [], [], []
        tiled = tex is not None and any(t[0] < -EPS or t[0] > 1 + EPS or t[1] < -EPS or t[1] > 1 + EPS for t in uv)
        if not tiled:
            for k in range(len(pos)):
                P.append(pos[k])
                N.append(nrm[k])
                U.append(atlas.map_uv(tex, uv[k][0], uv[k][1]) if tex else white)
            I = list(idx)
        else:
            # de-index; triangles inside one UV tile are shifted into [0,1],
            # triangles that span a seam fall back to the average texture colour
            fallback = 0
            for i in range(0, len(idx), 3):
                tri = idx[i : i + 3]
                us = [uv[k][0] for k in tri]
                vs = [uv[k][1] for k in tri]
                fu, fv = math.floor(min(us) + 1e-6), math.floor(min(vs) + 1e-6)
                fits = max(us) - fu <= 1 + EPS and max(vs) - fv <= 1 + EPS
                if not fits:
                    fallback += 1
                for k in tri:
                    I.append(len(P))
                    P.append(pos[k])
                    N.append(nrm[k])
                    U.append(atlas.map_uv(tex, uv[k][0] - fu, uv[k][1] - fv) if fits else white)
            if fallback * 3 >= len(idx):
                avg = atlas.average(tex)
                color = [color[c] * avg[c] for c in range(3)]
        if len(P) > 60000:
            raise ValueError("too many vertices")
        pmn = [min(p[i] for p in P) for i in range(3)]
        pmx = [max(p[i] for p in P) for i in range(3)]
        center = [(pmn[i] + pmx[i]) / 2 for i in range(3)]
        half = [max((pmx[i] - pmn[i]) / 2, 1e-4) for i in range(3)]

        def q(v, i):
            return max(-32767, min(32767, round((v - center[i]) / half[i] * 32767)))

        vb = struct.pack("<" + "h" * (len(P) * 3), *[q(p[i], i) for p in P for i in range(3)])
        nb = struct.pack("<" + "b" * (len(N) * 3), *[max(-127, min(127, round(c * 127))) for n in N for c in n])
        ub = struct.pack("<" + "H" * (len(U) * 2), *[max(0, min(65535, round(c * 65535))) for t in U for c in t])
        ib = struct.pack("<" + "H" * len(I), *I)
        parts.append(dict(v=b64(vb), n=b64(nb), uv=b64(ub), i=b64(ib), nv=len(P), nt=len(I) // 3,
                          color=[round(c, 4) for c in color], center=[round(c, 5) for c in center],
                          size=[round(h * 2, 5) for h in half]))
    allp = [p for pr in prepared for p in pr["pos"]]
    bmn = [min(p[i] for p in allp) for i in range(3)]
    bmx = [max(p[i] for p in allp) for i in range(3)]
    lines = ["--!strict", "-- Generated by tools/convert_assets.py from the NightShiftAssets library. Do not edit.",
             f"-- source key: {key}", "return {", "\tparts = {"]
    for p in parts:
        lines.append(
            "\t\t{ nv = %d, nt = %d, color = { %s }, center = { %s }, size = { %s },\n\t\t\tv = \"%s\",\n\t\t\tn = \"%s\",\n\t\t\tuv = \"%s\",\n\t\t\ti = \"%s\" },"
            % (p["nv"], p["nt"], ", ".join(map(str, p["color"])), ", ".join(map(str, p["center"])),
               ", ".join(map(str, p["size"])), p["v"], p["n"], p["uv"], p["i"])
        )
    lines.append("\t},")
    lines.append("\tmin = { %s }," % ", ".join(str(round(v, 4)) for v in bmn))
    lines.append("\tmax = { %s }," % ", ".join(str(round(v, 4)) for v in bmx))
    lines.append("}")
    (outdir / f"{key}.luau").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return dict(min=bmn, max=bmx, tris=sum(p["nt"] for p in parts), parts=len(parts),
                alpha=any(pr["tex"] in atlas.alpha for pr in prepared))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--library", required=True, help="path to NightShiftAssets")
    ap.add_argument("--out", required=True, help="output art folder (src/art)")
    args = ap.parse_args()
    lib = Path(args.library).resolve()
    out = Path(args.out).resolve()
    (out / "Models").mkdir(parents=True, exist_ok=True)
    (out / "Textures").mkdir(parents=True, exist_ok=True)
    for old in list((out / "Models").glob("*.luau")) + list((out / "Textures").glob("*.luau")):
        old.unlink()

    catalog = {a["key"]: a for a in json.loads((lib / "catalog.json").read_text(encoding="utf-8"))["assets"]}
    chars = {a["key"]: a for a in json.loads((lib / "characters" / "catalog.json").read_text(encoding="utf-8"))["assets"]}
    texcat = {a["key"]: a for a in json.loads((lib / "texture-catalog.json").read_text(encoding="utf-8"))["assets"]}

    atlas = Atlas()
    report = {"models": {}, "surfaces": {}, "failed": {}}
    prepared = {}
    for key, opts in SELECTION.items():
        try:
            if key in chars:
                entry = chars[key]
                tpath = None
                for t in entry.get("textures", []):
                    if t.get("path"):
                        tpath = lib / t["path"]
                prims = load_fbx_model(lib / entry["preparedFile"], tpath)
            elif key in catalog:
                prims = load_glb_model(lib / catalog[key]["preparedFile"])
            else:
                raise KeyError("key not in catalog")
            prepared[key] = prepare_model(key, prims, opts, atlas)
        except Exception as e:  # report and continue: a single bad asset must not stop the build
            report["failed"][key] = repr(e)
            print("FAILED", key, e, file=sys.stderr)

    atlas.pack()
    for key, prep in prepared.items():
        report["models"][key] = emit_model(key, prep, atlas, out / "Models")

    img = atlas.render()
    img.save(out.parent.parent / "tools" / "atlas_preview.png")
    strip = 64
    strips = atlas.height // strip
    for i in range(strips):
        write_texture_module(out / "Textures" / f"Atlas_{i}.luau", img.crop((0, i * strip, atlas.WIDTH, (i + 1) * strip)))

    # carpet comes from the office pack floor tile's embedded texture
    js, binc = read_glb(lib / catalog["office__carpet_floor__floor_3x3"]["preparedFile"])
    carpet = glb_image(js, binc, 0)
    if carpet is not None:
        write_texture_module(out / "Textures" / "surf_carpet.luau", carpet.convert("RGB"))
        report["surfaces"]["carpet"] = "surf_carpet"

    for name, tkey in SURFACE_TEXTURES.items():
        entry = texcat[tkey]
        variants = sorted(entry["variants"], key=lambda v: v["width"])
        pick = next((v for v in variants if v["width"] >= 128), variants[-1])
        simg = Image.open(lib / pick["file"]).convert("RGB")
        if max(simg.size) > 128:
            simg = simg.resize((128, 128), Image.LANCZOS)
        write_texture_module(out / "Textures" / f"surf_{name}.luau", simg)
        report["surfaces"][name] = f"surf_{name}"

    index = ["--!strict", "-- Generated by tools/convert_assets.py. Do not edit.", "return {",
             f"\tatlas = {{ w = {atlas.WIDTH}, h = {atlas.height}, strip = {strip}, strips = {strips} }},", "\tsurfaces = {"]
    for name, tkey in report["surfaces"].items():
        index.append(f'\t\t{name} = "{tkey}",')
    index.append("\t},")
    index.append("\tmodels = {")
    for key, m in report["models"].items():
        index.append("\t\t%s = { min = Vector3.new(%s), max = Vector3.new(%s), tris = %d }," % (
            key, ", ".join(str(round(v, 3)) for v in m["min"]), ", ".join(str(round(v, 3)) for v in m["max"]), m["tris"]))
    index.append("\t},")
    index.append("}")
    (out / "Index.luau").write_text("\n".join(index) + "\n", encoding="utf-8")
    (out.parent.parent / "tools" / "asset_report.json").write_text(json.dumps(report, indent=1), encoding="utf-8")
    total = sum(m["tris"] for m in report["models"].values())
    alpha = [k for k, m in report["models"].items() if m["alpha"]]
    print(f"models: {len(report['models'])}  failed: {len(report['failed'])}  atlas: {atlas.WIDTH}x{atlas.height} "
          f"({len(atlas.images)} images)  triangles: {total}")
    print("models with alpha textures (rendered opaque):", alpha)


if __name__ == "__main__":
    main()
