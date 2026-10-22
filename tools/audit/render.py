#!/usr/bin/env python3
"""Approximate offline eye-height previews of the built map.

NOT Studio lighting. A small numpy z-buffer rasteriser draws the structure
boxes from the harness dump (with their tiled surface textures) and every art
prop decoded from src/art exactly as ArtController does (vertices, atlas UVs,
part colours). Shading is Lambert from the map's point and surface lights plus
a flat ambient from default.project.json. No shadows, no fog, no bloom, no
client-side Atmosphere controller, no PBR: use it to judge layout, clutter,
facing and clipping, not mood.

Usage: python3 tools/audit/render.py --dump tools/audit/out/current.dump.json \
           --src src --label current --out-dir docs/presentation
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
import artmesh
from analyze import load_font

W, H = 1280, 720
FOV_Y = 70.0  # Roblox default Camera.FieldOfView (vertical)
NEAR = 0.1
EYE = 4.6  # first-person camera height (studs)
SKY = np.array([12, 14, 17], dtype=np.float64) / 255

FACES = {"Right": (0, 1), "Left": (0, -1), "Top": (1, 1), "Bottom": (1, -1), "Back": (2, 1), "Front": (2, -1)}


def srgb_to_lin(c):
    return np.power(np.clip(c, 0, 1), 2.2)


def lin_to_srgb(c):
    return np.power(np.clip(c, 0, 1), 1 / 2.2)


class Scene:
    def __init__(self):
        self.V = []  # (n,3,3) world positions
        self.UV = []  # (n,3,2)
        self.TEX = []  # (n,) texture id: -1 flat colour, 0 atlas, k surface
        self.COL = []  # (n,3) linear colour multiplier
        self.EMIT = []  # (n,) emissive
        self.textures: list[np.ndarray] = []
        self.tex_ids: dict[str, int] = {}

    def texture(self, key: str, img: np.ndarray | None) -> int:
        if img is None:
            return -1
        if key not in self.tex_ids:
            self.tex_ids[key] = len(self.textures)
            self.textures.append(srgb_to_lin(img.astype(np.float64) / 255))
        return self.tex_ids[key]

    def add(self, V, UV, tex, col, emit):
        n = len(V)
        self.V.append(np.asarray(V, dtype=np.float64).reshape(n, 3, 3))
        self.UV.append(np.asarray(UV, dtype=np.float64).reshape(n, 3, 2))
        self.TEX.append(np.full(n, tex, dtype=np.int64) if np.isscalar(tex) else np.asarray(tex))
        c = np.asarray(col, dtype=np.float64)
        self.COL.append(np.tile(c, (n, 1)) if c.ndim == 1 else c)
        self.EMIT.append(np.full(n, bool(emit)))

    def finish(self):
        self.V = np.concatenate(self.V)
        self.UV = np.concatenate(self.UV)
        self.TEX = np.concatenate(self.TEX)
        self.COL = np.concatenate(self.COL)
        self.EMIT = np.concatenate(self.EMIT)
        e1 = self.V[:, 1] - self.V[:, 0]
        e2 = self.V[:, 2] - self.V[:, 0]
        n = np.cross(e1, e2)
        ln = np.linalg.norm(n, axis=1, keepdims=True)
        self.N = n / np.maximum(ln, 1e-12)


def build_scene(dump: dict, art_dir: str) -> Scene:
    sc = Scene()
    atlas_info = None
    index_path = Path(art_dir) / "Index.luau"
    if index_path.is_file():
        import re

        m = re.search(r"atlas\s*=\s*\{\s*w\s*=\s*(\d+),\s*h\s*=\s*(\d+),\s*strip\s*=\s*(\d+),\s*strips\s*=\s*(\d+)", index_path.read_text())
        if m:
            atlas_info = tuple(int(x) for x in m.groups())
    atlas_id = -1
    if atlas_info:
        w, _, strip, strips = atlas_info
        atlas_id = sc.texture("__atlas", artmesh.load_atlas(art_dir, w, strip, strips))
    surfaces = dump.get("surfaces") or {}

    for p in dump["parts"]:
        attrs = p.get("attrs") if isinstance(p.get("attrs"), dict) else {}
        if isinstance(attrs.get("ArtKey"), str):
            continue
        if p["transparency"] >= 0.95 or p["material"] == "Glass" or p["group"] == "Collision":
            continue
        R = np.array(p["rot"], dtype=np.float64).reshape(3, 3)
        c = np.array(p["pos"], dtype=np.float64)
        h = np.array(p["size"], dtype=np.float64) / 2
        col = srgb_to_lin(np.array(p["color"], dtype=np.float64) / 255)
        emit = p["material"] == "Neon"
        tex_by_face = {}
        for t in p.get("textures") or []:
            mod = surfaces.get(t["surface"])
            img = artmesh.load_surface(art_dir, mod) if mod else None
            tid = sc.texture(t["surface"], img)
            if tid >= 0:
                tex_by_face[t["face"]] = (tid, float(t.get("tileU") or 8), float(t.get("tileV") or 8))
        for face, (a, s) in FACES.items():
            u, v = [i for i in range(3) if i != a]
            fc = c + R[:, a] * s * h[a]
            du, dv = R[:, u] * h[u], R[:, v] * h[v]
            q = [fc - du - dv, fc + du - dv, fc + du + dv, fc - du + dv]
            tris = [(q[0], q[1], q[2]), (q[0], q[2], q[3])]
            if face in tex_by_face:
                tid, tu, tv = tex_by_face[face]
                uvs = [[(np.dot(pt, R[:, u]) / tu, -np.dot(pt, R[:, v]) / tv) for pt in tri] for tri in tris]
                sc.add(tris, uvs, tid, np.ones(3), False)
            else:
                sc.add(tris, np.zeros((2, 3, 2)), -1, col, emit)

    for p in dump["parts"]:
        attrs = p.get("attrs") if isinstance(p.get("attrs"), dict) else {}
        key = attrs.get("ArtKey")
        if not isinstance(key, str) or attrs.get("ArtHidden") is True:
            continue
        mesh = artmesh.load_mesh(art_dir, key)
        if mesh is None:
            continue
        scale = attrs.get("ArtScale", 1)
        scale = float(scale) if isinstance(scale, (int, float)) else 1.0
        R = np.array(p["rot"], dtype=np.float64).reshape(3, 3)
        verts = artmesh.transform(mesh.verts, p["pos"], R, scale)
        V = verts[mesh.tris]
        UV = mesh.uvs[mesh.tris]
        col = mesh.colors.copy()
        tint = attrs.get("ArtTint")
        if isinstance(tint, list) and len(tint) == 3:
            col = col * (np.array(tint, dtype=np.float64) / 255)
        sc.add(V, UV, atlas_id, srgb_to_lin(col), False)
    sc.finish()
    return sc


def look_at(eye, target):
    f = np.asarray(target, float) - np.asarray(eye, float)
    f /= np.linalg.norm(f)
    r = np.cross(f, [0, 1, 0])
    r /= np.linalg.norm(r)
    u = np.cross(r, f)
    return np.asarray(eye, float), r, u, f


def clip_near(tri_cam, uv):
    """Clip a camera-space triangle against z >= NEAR; returns a list of (verts, uvs) triangles."""
    poly = list(zip(tri_cam, uv))
    out = []
    for i in range(len(poly)):
        (p1, t1), (p2, t2) = poly[i], poly[(i + 1) % len(poly)]
        in1, in2 = p1[2] >= NEAR, p2[2] >= NEAR
        if in1:
            out.append((p1, t1))
        if in1 != in2:
            k = (NEAR - p1[2]) / (p2[2] - p1[2])
            out.append((p1 + (p2 - p1) * k, t1 + (t2 - t1) * k))
    tris = []
    for i in range(1, len(out) - 1):
        tris.append((np.array([out[0][0], out[i][0], out[i + 1][0]]), np.array([out[0][1], out[i][1], out[i + 1][1]])))
    return tris


def render(sc: Scene, eye, target, lights, ambient):
    C, r, u, f = look_at(eye, target)
    fy = (H / 2) / math.tan(math.radians(FOV_Y) / 2)
    fx = fy
    rel = sc.V - C[None, None, :]
    cam = np.stack([rel @ r, rel @ u, rel @ f], axis=-1)  # x right, y up, z forward
    zmin = cam[:, :, 2].min(axis=1)
    zmax = cam[:, :, 2].max(axis=1)
    keep_all = zmin >= NEAR
    crossing = (zmax >= NEAR) & ~keep_all

    tri_cam = [cam[keep_all]]
    tri_uv = [sc.UV[keep_all]]
    tri_src = [np.nonzero(keep_all)[0]]
    extra_cam, extra_uv, extra_src = [], [], []
    for i in np.nonzero(crossing)[0]:
        for vc, vt in clip_near(cam[i], sc.UV[i]):
            extra_cam.append(vc)
            extra_uv.append(vt)
            extra_src.append(i)
    if extra_cam:
        tri_cam.append(np.array(extra_cam))
        tri_uv.append(np.array(extra_uv))
        tri_src.append(np.array(extra_src))
    tcam = np.concatenate(tri_cam)
    tuv = np.concatenate(tri_uv)
    tsrc = np.concatenate(tri_src)

    z = tcam[:, :, 2]
    sx = W / 2 + fx * tcam[:, :, 0] / z
    sy = H / 2 - fy * tcam[:, :, 1] / z
    bx0 = np.floor(sx.min(axis=1)).astype(int)
    bx1 = np.ceil(sx.max(axis=1)).astype(int)
    by0 = np.floor(sy.min(axis=1)).astype(int)
    by1 = np.ceil(sy.max(axis=1)).astype(int)
    vis = (bx1 >= 0) & (bx0 < W) & (by1 >= 0) & (by0 < H)
    area = (sx[:, 1] - sx[:, 0]) * (sy[:, 2] - sy[:, 0]) - (sx[:, 2] - sx[:, 0]) * (sy[:, 1] - sy[:, 0])
    vis &= np.abs(area) > 1e-9

    zbuf = np.full((H, W), np.inf)
    tid = np.full((H, W), -1, dtype=np.int64)
    bary = np.zeros((H, W, 3))
    for k in np.nonzero(vis)[0]:
        x0, x1 = max(bx0[k], 0), min(bx1[k], W - 1)
        y0, y1 = max(by0[k], 0), min(by1[k], H - 1)
        if x1 < x0 or y1 < y0:
            continue
        px = np.arange(x0, x1 + 1) + 0.5
        py = np.arange(y0, y1 + 1) + 0.5
        X, Y = np.meshgrid(px, py)
        ax, ay, bxx, byy, cx, cy = sx[k, 0], sy[k, 0], sx[k, 1], sy[k, 1], sx[k, 2], sy[k, 2]
        a = area[k]
        l0 = ((bxx - X) * (cy - Y) - (cx - X) * (byy - Y)) / a
        l1 = ((cx - X) * (ay - Y) - (ax - X) * (cy - Y)) / a
        l2 = 1 - l0 - l1
        inside = (l0 >= -1e-6) & (l1 >= -1e-6) & (l2 >= -1e-6)
        if not inside.any():
            continue
        iz = l0 / z[k, 0] + l1 / z[k, 1] + l2 / z[k, 2]
        depth = 1 / np.where(iz > 0, iz, 1e-9)
        sub = zbuf[y0 : y1 + 1, x0 : x1 + 1]
        win = inside & (depth < sub)
        if not win.any():
            continue
        sub[win] = depth[win]
        tid[y0 : y1 + 1, x0 : x1 + 1][win] = k
        b = np.stack([l0 / z[k, 0], l1 / z[k, 1], l2 / z[k, 2]], axis=-1) / iz[..., None]
        bary[y0 : y1 + 1, x0 : x1 + 1][win] = b[win]

    img = np.tile(srgb_to_lin(SKY), (H, W, 1))
    hit = tid >= 0
    k = tid[hit]
    b = bary[hit]
    src = tsrc[k]
    # world position from camera-space barycentrics
    pc = (tcam[k] * b[:, :, None]).sum(axis=1)
    P = C[None, :] + pc[:, 0:1] * r[None, :] + pc[:, 1:2] * u[None, :] + pc[:, 2:3] * f[None, :]
    N = sc.N[src].copy()
    toward = C[None, :] - P
    flip = (N * toward).sum(axis=1) < 0
    N[flip] *= -1
    uv = (tuv[k] * b[:, :, None]).sum(axis=1)
    albedo = sc.COL[src].copy()
    tex = sc.TEX[src]
    for t_id in np.unique(tex):
        if t_id < 0:
            continue
        m = tex == t_id
        img_t = sc.textures[t_id]
        th, tw = img_t.shape[:2]
        if t_id == sc.tex_ids.get("__atlas"):
            uu = np.clip((uv[m, 0] * tw).astype(int), 0, tw - 1)
            vv = np.clip((uv[m, 1] * th).astype(int), 0, th - 1)
        else:
            uu = np.floor(uv[m, 0] % 1.0 * tw).astype(int) % tw
            vv = np.floor(uv[m, 1] % 1.0 * th).astype(int) % th
        albedo[m] = albedo[m] * img_t[vv, uu]

    light = np.tile(ambient, (len(P), 1))
    for L in lights:
        if L["brightness"] <= 0:
            continue
        lp = np.array(L["pos"], dtype=np.float64)
        if L["class"] == "SurfaceLight":
            lp = lp + np.array([0, -0.3, 0])
        d = lp[None, :] - P
        dist = np.linalg.norm(d, axis=1)
        rng = float(L["range"])
        near = dist < rng
        if not near.any():
            continue
        ldir = d[near] / np.maximum(dist[near, None], 1e-6)
        ndl = np.clip((N[near] * ldir).sum(axis=1), 0, 1)
        att = np.clip(1 - dist[near] / rng, 0, 1) ** 2
        if L["class"] in ("SurfaceLight", "SpotLight"):
            down = np.array([0, -1, 0]) if L.get("face", "Bottom") == "Bottom" else np.array([0, 1, 0])
            cosang = (-ldir * down).sum(axis=1)
            half = math.radians(float(L.get("angle") or 90) / 2)
            att *= np.clip((cosang - math.cos(half)) / max(1 - math.cos(half), 1e-3) * 2.5, 0, 1)
        colr = srgb_to_lin(np.array(L["color"], dtype=np.float64) / 255)
        light[near] += colr[None, :] * (float(L["brightness"]) * 1.8 * att * ndl)[:, None]
    shaded = albedo * light
    emit = sc.EMIT[src]
    shaded[emit] = albedo[emit] * 1.1
    img[hit] = shaded
    out = lin_to_srgb(img * 1.15)
    return (out * 255).astype(np.uint8)


def views_for(dump: dict) -> list[tuple[str, list, list]]:
    lay = dump.get("layout") or {}
    views = []
    lg = lay.get("LOBBY_GAP")
    M = lay.get("MAIN")
    if lg and M:
        x = (lg["minX"] + lg["maxX"]) / 2
        views.append(("office entrance (lobby doorway, looking into the office)", [x, EYE, M["maxZ"] - 1.0], [x - 14, 3.2, M["minZ"] + 6]))
    desks = lay.get("DESKS") or []
    if desks:
        xs = [d["pos"][0] for d in desks]
        zs = [d["pos"][2] for d in desks]
        # the aisle behind the southern row of chairs, looking west along the desks
        views.append(("aisle behind the desk chairs (looking west)", [max(xs) + 4.0, EYE, max(zs) + 5.0], [min(xs) - 4.0, 3.0, max(zs) - 0.6]))
    ws = lay.get("WORKSTATION") or {}
    if ws.get("chair") and ws.get("facing") and ws.get("monitor"):
        ch = np.array(ws["chair"], float)
        fa = np.array(ws["facing"], float)
        eye = ch - fa * 2.2
        views.append(("behind the workstation chair", [eye[0], EYE, eye[2]], [ws["monitor"][0], 4.0, ws["monitor"][2]]))
    return views


def ambient_from(project: Path | None) -> np.ndarray:
    amb = np.array([0.18, 0.21, 0.235])
    if project and project.is_file():
        try:
            tree = json.loads(project.read_text())["tree"]
            a = tree.get("Lighting", {}).get("$properties", {}).get("Ambient")
            if isinstance(a, list) and len(a) == 3:
                amb = np.array(a, dtype=np.float64)
        except (ValueError, KeyError):
            pass
    # Future lighting lifts indoor ambient a little; keep it close to the authored value
    return srgb_to_lin(amb) * 1.6 + 0.01


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dump", required=True)
    ap.add_argument("--src", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--project", help="default.project.json for Lighting.Ambient (default: next to the src dir)")
    args = ap.parse_args()
    dump = json.loads(Path(args.dump).read_text())
    src = Path(args.src)
    if (src / "src" / "art").is_dir():
        src = src / "src"
    project = Path(args.project) if args.project else src.parent / "default.project.json"
    ambient = ambient_from(project)
    scene = build_scene(dump, str(src / "art"))
    font = load_font(18, True)
    small = load_font(15)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    for n, (name, eye, target) in enumerate(views_for(dump), 1):
        rgb = render(scene, eye, target, dump.get("lights") or [], ambient)
        im = Image.fromarray(rgb, "RGB")
        d = ImageDraw.Draw(im, "RGBA")
        d.rectangle([0, H - 54, W, H], fill=(0, 0, 0, 170))
        d.text((14, H - 48), "APPROXIMATE OFFLINE RENDER, NOT STUDIO LIGHTING", font=font, fill=(255, 210, 120, 255))
        d.text((14, H - 24), f"{args.label} view {n}: {name} | eye {eye[0]:.1f}, {eye[1]:.1f}, {eye[2]:.1f} | Lambert + point lights, no shadows/fog/post", font=small, fill=(225, 225, 220, 255))
        path = out_dir / f"view-{args.label}-{n}.png"
        im.save(path, optimize=True)
        print(f"[render] {path}")


if __name__ == "__main__":
    main()
