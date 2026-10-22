#!/usr/bin/env python3
"""Headless layout audit for NIGHT SHIFT (see tools/audit/README.md).

Reads the JSON dump written by tools/audit/harness.luau (the real MapBuilder
run in Lune) plus the converted meshes in <src>/art, and reports:

  a. prop-vs-prop intersections (OBB separating-axis test + mesh check)
  b. props penetrating structure, trim, glass and other furniture collision
  c. first-person camera clipping risk: visual mesh beyond collision at 3..6.5 studs
  d. walkability: collision band raster, character dilation, flood fill from the
     spawn, prompt reachability, widest-route bottlenecks, floor behind chairs
  e. clutter: art props per area / desk, weathered or trash-like keys
  f. plan image  docs/presentation/plan-<label>.png
  g. markdown    docs/presentation/layout-audit-<label>.md and JSON tools/audit/out/<label>.json

Everything is an approximation of the Roblox runtime: boxes and sampled mesh
points, no physics, prompts measured from a root height of 3 studs.
"""

from __future__ import annotations

import argparse
import heapq
import json
import math
import re
import sys
import time
from collections import Counter, defaultdict, deque
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
import artmesh

# ---------------------------------------------------------------------------
# Tunables (studs)
# ---------------------------------------------------------------------------

CELL = 0.25  # walk grid resolution
CHAR_RADIUS = 1.0  # character half width (R15 torso is 2 wide)
FACE_RADIUS = 0.5  # how close a body gets to a wall face-first (torso half depth)
BAND = (0.4, 5.5)  # collision that blocks a walking character
ROOT_Y = 3.0  # HumanoidRootPart height, used for prompt distances
CONTACT_TOL = 0.05  # overlap below this is resting / touching contact
NEST_TOL = 0.15  # an item resting on a surface may sink this much
COVER_BAND = (3.0, 6.5)  # heights checked for camera clipping
EYE_ZONE = (4.0, 5.8)  # head/camera height (~4.5-5) plus near-plane slack
OVERHANG_LIMIT = 0.3
EXPOSE_DIST = 1.0  # mesh points this close (horizontally) to reachable floor can meet the camera
ROUTE_MIN = 3.5  # art direction: clear walking routes
CHAIR_BACK_MIN = 2.5  # art direction: free floor behind each chair
SPACING = 0.1  # mesh sample spacing
VOXEL = 0.1  # shared-surface voxel size for the mesh overlap check
MESH_CONTACT_MIN = 4  # shared voxels needed to call an overlap "mesh-confirmed"
FLUSH_MOUNT = 0.35  # wall-mounted props may sink this far into their wall
PROMPT_DEFAULT = 10.0

WEATHERED_RE = re.compile(r"weather|rust|trash|litter|garbage|boarded|hazard|broken|dirty|grime|stain|overflow|pile|damaged|chemical|graffiti|dumpster")
DIRTY_SURFACE_RE = re.compile(r"stain|rust|dirt|grime|corrug|asphalt")
ROUGH_SURFACE_RE = re.compile(r"concrete|brick")  # speckle is the material, not dirt

REGION_KEYS = [("Office", "MAIN"), ("Kitchen", "KITCHEN"), ("Lobby", "LOBBY"), ("Hall", "HALL"), ("Alley", "ALLEY"), ("Street", "STREET")]
INDOOR = {"Office", "Kitchen", "Lobby", "Hall"}

CATEGORY_RULES = [
    ("character", r"characters__"),
    ("desk", r"__desks__"),
    ("chair", r"__chairs__"),
    ("computer", r"__computers__"),
    ("divider", r"__dividers__"),
    ("seating", r"__couches__"),
    ("storage", r"file_cabinet|book_case|metal_rack|commerical_shelf|__box_"),
    ("appliance", r"fridge|coffee_machine|water_cooler"),
    ("deskitem", r"mug|paper|stationary|binder|books|desklamp|phone|telephone|pen\d?$|envolope|catalog|glass$|book_"),
    ("wall", r"wall_clock|whiteboard|panel_|sign_|fire_ext|junctionbox|vent|duct|pipe|valve|door_|window_"),
    ("outdoor", r"urban__|wood_pallet|manhole|yellow_post|barrel|street_light"),
]

# Rough real-world size sanity (studs; a Roblox character is ~5.5 tall, the
# converter uses 3.5 studs per metre). (pattern, "h" height | "w" widest
# horizontal extent, min, max). Heuristic: only catches gross scale mistakes.
SCALE_HINTS = [
    (r"coffee_machine", "h", 1.0, 2.4),
    (r"manhole", "w", 2.0, 3.4),
    (r"wood_pallet", "w", 3.4, 4.8),
    (r"__mug", "h", 0.25, 0.55),
    (r"computer_monitor", "h", 1.2, 2.5),
    (r"__chairs__", "h", 2.9, 4.3),
    (r"__desks__", "h", 2.4, 3.4),
    (r"door_brown|door_pushbar", "h", 6.3, 8.6),
    (r"fridge", "h", 4.5, 6.8),
    (r"water_cooler", "h", 3.6, 5.4),
    (r"whiteboard", "h", 4.5, 8.0),
    (r"book_case", "h", 4.5, 8.0),
    (r"file_cabinet", "h", 2.0, 5.6),
    (r"desklamp", "h", 0.8, 2.4),
    (r"telephone|desk_phone", "h", 0.3, 1.0),
    (r"barrel", "h", 2.4, 3.6),
    (r"trash_can|metaltrashcan", "h", 1.8, 3.8),
    (r"trashbag", "h", 1.0, 2.6),
    (r"dumpster_lid", "h", 3.8, 7.5),
    (r"street_light", "h", 13.0, 27.0),
    (r"couches__", "h", 2.5, 4.4),
    (r"characters__", "h", 4.8, 6.4),
]

CATEGORY_COLORS = {
    "desk": (176, 128, 84),
    "chair": (96, 150, 210),
    "computer": (150, 205, 150),
    "deskitem": (238, 214, 120),
    "storage": (190, 160, 220),
    "seating": (220, 140, 170),
    "appliance": (120, 210, 210),
    "divider": (150, 150, 160),
    "wall": (230, 170, 110),
    "outdoor": (150, 160, 110),
    "character": (255, 255, 255),
    "other": (200, 200, 200),
}


def categorize(key: str) -> str:
    for name, pattern in CATEGORY_RULES:
        if re.search(pattern, key):
            return name
    return "other"


def short(key: str) -> str:
    parts = key.split("__")
    return parts[-1] if parts else key


def fmt(v, nd=2) -> str:
    return f"{v:.{nd}f}"


def xyz(p) -> str:
    return f"({p[0]:.1f}, {p[1]:.1f}, {p[2]:.1f})"


def xz(p) -> str:
    return f"({p[0]:.1f}, {p[2]:.1f})"


# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------


class Box:
    """Oriented box. R columns are the local axes in world space."""

    __slots__ = ("R", "c", "h", "hi", "lo")

    def __init__(self, center, rot, half):
        self.c = np.asarray(center, dtype=float)
        self.R = np.asarray(rot, dtype=float).reshape(3, 3)
        self.h = np.abs(np.asarray(half, dtype=float))
        ext = np.abs(self.R) @ self.h
        self.lo = self.c - ext
        self.hi = self.c + ext

    def corners(self) -> np.ndarray:
        s = np.array([[sx, sy, sz] for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)], dtype=float)
        return self.c[None, :] + (s * self.h[None, :]) @ self.R.T

    def local(self, pts: np.ndarray) -> np.ndarray:
        return (pts - self.c[None, :]) @ self.R

    def inside_depth(self, pts: np.ndarray) -> np.ndarray:
        """>0 inside (distance to the nearest face), <=0 outside."""
        loc = np.abs(self.local(pts))
        return np.min(self.h[None, :] - loc, axis=1)

    def dist(self, pts: np.ndarray) -> np.ndarray:
        loc = np.abs(self.local(pts))
        d = np.maximum(loc - self.h[None, :], 0.0)
        return np.sqrt((d * d).sum(axis=1))

    def footprint(self, inflate_thin: float = 0.0) -> list[tuple[float, float]]:
        h = self.h.copy()
        if inflate_thin:
            # keep thin parts visible on the grid (glass, slim panels)
            for i in range(3):
                axis = self.R[:, i]
                if abs(axis[1]) < 0.9:
                    h[i] = max(h[i], inflate_thin)
        s = np.array([[sx, sy, sz] for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)], dtype=float)
        pts = self.c[None, :] + (s * h[None, :]) @ self.R.T
        return convex_hull([(p[0], p[2]) for p in pts])

    def aabb_overlap(self, other: Box, pad: float = 0.0) -> bool:
        return bool(np.all(self.lo - pad <= other.hi) and np.all(other.lo - pad <= self.hi))

    def vertical(self) -> bool:
        return abs(self.R[1, 1]) > 0.999


def sat_depth(a: Box, b: Box) -> tuple[float, np.ndarray | None]:
    """Penetration depth (min overlap over the 15 SAT axes) and its axis; 0 when separated."""
    axes = [a.R[:, i] for i in range(3)] + [b.R[:, i] for i in range(3)]
    for i in range(3):
        for j in range(3):
            axes.append(np.cross(a.R[:, i], b.R[:, j]))
    t = b.c - a.c
    best, best_axis = math.inf, None
    for L in axes:
        n = np.linalg.norm(L)
        if n < 1e-6:
            continue
        L = L / n
        ra = float(np.sum(a.h * np.abs(a.R.T @ L)))
        rb = float(np.sum(b.h * np.abs(b.R.T @ L)))
        ov = ra + rb - abs(float(t @ L))
        if ov <= 0:
            return 0.0, None
        if ov < best:
            best, best_axis = ov, L
    return best, best_axis


def convex_hull(points):
    pts = sorted(set((round(x, 5), round(z, 5)) for x, z in points))
    if len(pts) <= 2:
        return pts

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    lower, upper = [], []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


def clip_polygon(subject, clip):
    """Sutherland-Hodgman intersection of two convex CCW polygons."""

    def inside(p, a, b):
        return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]) >= -1e-9

    def intersect(p1, p2, a, b):
        x1, y1, x2, y2 = p1[0], p1[1], p2[0], p2[1]
        x3, y3, x4, y4 = a[0], a[1], b[0], b[1]
        den = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
        if abs(den) < 1e-12:
            return p2
        t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / den
        return (x1 + t * (x2 - x1), y1 + t * (y2 - y1))

    out = list(subject)
    for i in range(len(clip)):
        a, b = clip[i], clip[(i + 1) % len(clip)]
        inp, out = out, []
        if not inp:
            break
        s = inp[-1]
        for e in inp:
            if inside(e, a, b):
                if not inside(s, a, b):
                    out.append(intersect(s, e, a, b))
                out.append(e)
            elif inside(s, a, b):
                out.append(intersect(s, e, a, b))
            s = e
    return out


# ---------------------------------------------------------------------------
# Dump model
# ---------------------------------------------------------------------------


class PartRec:
    def __init__(self, d: dict):
        self.d = d
        self.uid = d["uid"]
        self.name = d["name"]
        self.cls = d["class"]
        self.group = d["group"]
        self.collide = bool(d["collide"])
        self.transparency = float(d["transparency"])
        self.material = d.get("material", "")
        self.color = tuple(d.get("color", (200, 200, 200)))
        attrs = d.get("attrs") or {}
        self.attrs = attrs if isinstance(attrs, dict) else {}
        self.size = np.array(d["size"], dtype=float)
        self.pos = np.array(d["pos"], dtype=float)
        self.rot = np.array(d["rot"], dtype=float).reshape(3, 3)
        self.box = Box(self.pos, self.rot, self.size / 2)
        self.labels = d.get("labels") or []
        self.surfaces = d.get("surfaces") or []
        self.collision_group = d.get("collisionGroup", "Default")

    @property
    def visible(self) -> bool:
        return self.transparency < 0.95


class Prop:
    def __init__(self, part: PartRec, models: dict, art_dir: str):
        self.part = part
        self.uid = part.uid
        self.key = part.attrs["ArtKey"]
        scale = part.attrs.get("ArtScale", 1)
        self.scale = float(scale) if isinstance(scale, (int, float)) else 1.0
        self.pos = part.pos
        self.R = part.rot
        self.hidden = part.attrs.get("ArtHidden") is True
        self.dynamic = part.attrs.get("ArtDynamic") is True
        self.category = categorize(self.key)
        info = models.get(self.key)
        self.known = info is not None
        if info:
            lo = np.array(info["min"], dtype=float) * self.scale
            hi = np.array(info["max"], dtype=float) * self.scale
        else:
            lo, hi = np.full(3, -0.5), np.full(3, 0.5)
        self.local_lo, self.local_hi = lo, hi
        self.box = Box(self.pos + self.R @ ((lo + hi) / 2), self.R, (hi - lo) / 2)
        self.mesh = artmesh.load_mesh(art_dir, self.key) if info else None
        self._pts = None
        self.region = "Outside"
        self.idx = 0

    @property
    def label(self) -> str:
        return f"{short(self.key)}#{self.idx}"

    def points(self) -> np.ndarray:
        """World-space surface samples (falls back to the box corners)."""
        if self._pts is None:
            if self.mesh is not None:
                self._pts = artmesh.transform(self.mesh.samples(SPACING), self.pos, self.R, self.scale)
            else:
                self._pts = self.box.corners()
        return self._pts

    def mesh_min_y(self) -> float:
        if self.mesh is None:
            return float(self.box.lo[1])
        v = artmesh.transform(self.mesh.verts, self.pos, self.R, self.scale)
        return float(v[:, 1].min())

    @property
    def height(self) -> float:
        return float(self.box.hi[1] - self.box.lo[1])


def region_of(layout: dict, x: float, z: float) -> str:
    for name, key in REGION_KEYS:
        r = layout.get(key)
        if isinstance(r, dict) and r.get("minX") is not None:
            if r["minX"] <= x <= r["maxX"] and r["minZ"] <= z <= r["maxZ"]:
                return name
    return "Outside"


def vec(v, default=None):
    if isinstance(v, dict) and v.get("$cframe"):
        return np.array(v["pos"], dtype=float)
    if isinstance(v, dict) and "pos" in v:
        return np.array(v["pos"], dtype=float)
    if isinstance(v, (list, tuple)) and len(v) == 3 and all(isinstance(x, (int, float)) for x in v):
        return np.array(v, dtype=float)
    return default


# ---------------------------------------------------------------------------
# Prompts declared in server code (labels + distances)
# ---------------------------------------------------------------------------


def balanced(text: str, start: int) -> str:
    depth = 0
    for i in range(start, len(text)):
        ch = text[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return text[start + 1 : i]
    return text[start + 1 :]


def parse_prompts(src: Path, reach: dict) -> list[dict]:
    out = []
    server = src / "server"
    if not server.is_dir():
        return out
    for path in sorted(server.rglob("*.luau")):
        text = path.read_text()
        for m in re.finditer(r"Prompts\.make\s*\(", text):
            body = balanced(text, m.end() - 1)
            first = body.split(",", 1)[0].strip()
            action = re.search(r"action\s*=\s*\"([^\"]*)\"", body)
            distance = re.search(r"distance\s*=\s*([\w.]+)", body)
            key = re.search(r"\bkey\s*=\s*Enum\.KeyCode\.(\w+)", body)
            hold = re.search(r"hold\s*=\s*([\w.]+)", body)
            dist = PROMPT_DEFAULT if "prompt" not in reach else float(reach["prompt"])
            if distance:
                raw = distance.group(1)
                if re.fullmatch(r"[\d.]+", raw):
                    dist = float(raw)
                else:
                    rk = raw.split(".")[-1]
                    if rk in reach and isinstance(reach[rk], (int, float)):
                        dist = float(reach[rk])
            line = text.count("\n", 0, m.start()) + 1
            out.append(
                {
                    "file": str(path.relative_to(src.parent)) if src.parent in path.parents else str(path),
                    "line": line,
                    "arg": first,
                    "action": action.group(1) if action else "?",
                    "distance": dist,
                    "key": key.group(1) if key else "E",
                    "hold": hold.group(1) if hold else "0",
                }
            )
    return out


PROMPT_TARGETS = [
    # (target kind, matcher on the first argument / file / action)
    ("tower", lambda p: p["arg"] == "pc"),
    ("rackslot", lambda p: p["action"].lower().startswith("take drive")),
    ("rack", lambda p: "recoveryRack" in p["arg"]),
    ("dock", lambda p: p["arg"].endswith(".dock")),
    ("seat", lambda p: "seatPromptPart" in p["arg"]),
    ("breaker", lambda p: p["arg"] == "sw" or "breaker" in p["arg"].lower()),
    ("reardoor", lambda p: "doorPromptPart" in p["arg"]),
    ("trash", lambda p: "kitchenTrash" in p["arg"]),
    ("dumpster", lambda p: "dumpster" in p["arg"]),
    ("thermostat", lambda p: "thermostat" in p["arg"]),
    ("printer", lambda p: "printer" in p["arg"]),
    ("outbox", lambda p: "outbox" in p["arg"]),
    ("timeclock", lambda p: "timeClock" in p["arg"]),
]


# ---------------------------------------------------------------------------
# Walk grid
# ---------------------------------------------------------------------------


class Grid:
    def __init__(self, x0, x1, z0, z1, cell=CELL):
        self.cell = cell
        self.x0, self.z0 = x0, z0
        self.nx = int(math.ceil((x1 - x0) / cell))
        self.nz = int(math.ceil((z1 - z0) / cell))
        self.xs = x0 + (np.arange(self.nx) + 0.5) * cell
        self.zs = z0 + (np.arange(self.nz) + 0.5) * cell

    def index(self, x, z):
        ix = int(math.floor((x - self.x0) / self.cell))
        iz = int(math.floor((z - self.z0) / self.cell))
        return min(max(iz, 0), self.nz - 1), min(max(ix, 0), self.nx - 1)

    def fill(self, mask: np.ndarray, poly, value=True):
        if len(poly) < 3:
            return
        xs = [p[0] for p in poly]
        zs = [p[1] for p in poly]
        ix0 = max(int(math.floor((min(xs) - self.x0) / self.cell)), 0)
        ix1 = min(int(math.ceil((max(xs) - self.x0) / self.cell)), self.nx - 1)
        iz0 = max(int(math.floor((min(zs) - self.z0) / self.cell)), 0)
        iz1 = min(int(math.ceil((max(zs) - self.z0) / self.cell)), self.nz - 1)
        if ix1 < ix0 or iz1 < iz0:
            return
        X, Z = np.meshgrid(self.xs[ix0 : ix1 + 1], self.zs[iz0 : iz1 + 1])
        ok = np.ones(X.shape, dtype=bool)
        n = len(poly)
        for i in range(n):
            ax, az = poly[i]
            bx, bz = poly[(i + 1) % n]
            ok &= (bx - ax) * (Z - az) - (bz - az) * (X - ax) >= -1e-9
        sub = mask[iz0 : iz1 + 1, ix0 : ix1 + 1]
        sub[ok] = value


def edt(obstacle: np.ndarray) -> np.ndarray:
    """Exact Euclidean distance (cells) from each cell centre to the nearest True cell."""
    nz, nx = obstacle.shape
    inf = float(nz + nx) * 4
    g = np.where(obstacle, 0.0, inf)
    for i in range(1, nz):
        g[i] = np.minimum(g[i], g[i - 1] + 1)
    for i in range(nz - 2, -1, -1):
        g[i] = np.minimum(g[i], g[i + 1] + 1)
    out = np.empty_like(g)
    xi = np.arange(nx, dtype=float)
    d2 = (xi[:, None] - xi[None, :]) ** 2
    for i in range(nz):
        out[i] = np.min(g[i][None, :] ** 2 + d2, axis=1)
    return np.sqrt(out)


def flood(free: np.ndarray, start) -> np.ndarray:
    nz, nx = free.shape
    seen = np.zeros_like(free)
    if not free[start]:
        return seen
    q = deque([start])
    seen[start] = True
    while q:
        z, x = q.popleft()
        for dz, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            a, b = z + dz, x + dx
            if 0 <= a < nz and 0 <= b < nx and free[a, b] and not seen[a, b]:
                seen[a, b] = True
                q.append((a, b))
    return seen


def nearest_true(mask: np.ndarray, cell) -> tuple[int, int] | None:
    if mask[cell]:
        return cell
    idx = np.argwhere(mask)
    if len(idx) == 0:
        return None
    d = (idx[:, 0] - cell[0]) ** 2 + (idx[:, 1] - cell[1]) ** 2
    k = int(np.argmin(d))
    return int(idx[k, 0]), int(idx[k, 1])


def widest_paths(clear: np.ndarray, start) -> tuple[np.ndarray, np.ndarray]:
    """Max-min clearance from `start` to every cell (8-connected, no corner cutting)."""
    nz, nx = clear.shape
    best = np.full(clear.shape, -1.0)
    parent = np.full(clear.shape, -1, dtype=np.int64)
    done = np.zeros(clear.shape, dtype=bool)
    best[start] = clear[start]
    heap = [(-clear[start], start[0], start[1])]
    nbrs = ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1))
    while heap:
        nb, z, x = heapq.heappop(heap)
        if done[z, x]:
            continue
        done[z, x] = True
        cur = -nb
        for dz, dx in nbrs:
            a, b = z + dz, x + dx
            if not (0 <= a < nz and 0 <= b < nx) or done[a, b] or clear[a, b] <= 0:
                continue
            if dz and dx and (clear[z + dz, x] <= 0 or clear[z, x + dx] <= 0):
                continue
            v = min(cur, clear[a, b])
            if v > best[a, b]:
                best[a, b] = v
                parent[a, b] = z * nx + x
                heapq.heappush(heap, (-v, a, b))
    return best, parent


def bfs_paths(free: np.ndarray, start) -> np.ndarray:
    nz, nx = free.shape
    parent = np.full(free.shape, -1, dtype=np.int64)
    seen = np.zeros_like(free)
    if not free[start]:
        return parent
    q = deque([start])
    seen[start] = True
    nbrs = ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1))
    while q:
        z, x = q.popleft()
        for dz, dx in nbrs:
            a, b = z + dz, x + dx
            if 0 <= a < nz and 0 <= b < nx and free[a, b] and not seen[a, b]:
                if dz and dx and not (free[z + dz, x] and free[z, x + dx]):
                    continue
                seen[a, b] = True
                parent[a, b] = z * nx + x
                q.append((a, b))
    return parent


def trace(parent: np.ndarray, end, nx: int) -> list[tuple[int, int]]:
    path = [end]
    cur = end
    guard = parent.size
    while guard > 0:
        p = parent[cur]
        if p < 0:
            break
        cur = (int(p // nx), int(p % nx))
        path.append(cur)
        guard -= 1
    return path[::-1]


# ---------------------------------------------------------------------------
# Audit
# ---------------------------------------------------------------------------


class Audit:
    def __init__(self, dump: dict, src: Path, label: str):
        self.dump = dump
        self.src = src
        self.label = label
        self.art_dir = str(src / "art")
        self.layout = dump.get("layout") or {}
        self.refs = dump.get("refs") or {}
        self.reach = dump.get("reach") or {}
        self.models = dump.get("models") or {}
        self.parts = [PartRec(p) for p in dump["parts"]]
        self.by_uid = {p.uid: p for p in self.parts}
        self.props: list[Prop] = []
        for p in self.parts:
            if isinstance(p.attrs.get("ArtKey"), str):
                self.props.append(Prop(p, self.models, self.art_dir))
        counter = Counter()
        for pr in sorted(self.props, key=lambda q: (q.key, q.pos[0], q.pos[2])):
            counter[pr.key] += 1
            pr.idx = counter[pr.key]
            pr.region = region_of(self.layout, pr.pos[0], pr.pos[2])
        self.visible_props = [p for p in self.props if not p.hidden]
        self.unknown_keys = sorted({p.key for p in self.props if not p.known})
        self.result: dict = {"label": label, "src": str(src)}
        self.issues: list[dict] = []

        def is_floor(p: PartRec) -> bool:
            return p.collide and p.box.hi[1] <= 0.35 and p.box.hi[1] >= -0.35 and p.size[1] <= 3

        self.floors = [p for p in self.parts if is_floor(p) and p.group != "Collision"]
        self.doors = [p for p in self.parts if p.group == "Interactive" and re.fullmatch(r"RearDoor|FrontDoor\d*", p.name)]
        door_ids = {d.uid for d in self.doors}
        self.colliders = [p for p in self.parts if p.collide and p.cls != "Seat" and p.uid not in door_ids and p not in self.floors]
        self.collision_proxies = [p for p in self.parts if p.group == "Collision"]
        self.structure = [p for p in self.parts if p.group == "Structure" and p not in self.floors and p.visible]
        self.visible_interactive = [p for p in self.parts if p.group == "Interactive" and p.visible and p.uid not in door_ids]

    # -- helpers ------------------------------------------------------------

    def ref_part(self, value) -> PartRec | None:
        if isinstance(value, dict) and "$inst" in value:
            return self.by_uid.get(value["$inst"])
        return None

    def spawn(self) -> np.ndarray:
        for p in self.parts:
            if p.cls == "SpawnLocation":
                return p.pos
        s = vec(self.layout.get("SPAWN"))
        return s if s is not None else np.array([0.0, 0.0, 0.0])

    def owner_of_proxy(self, proxy: PartRec) -> Prop | None:
        if not proxy.name.endswith("_Collision"):
            return None
        key = proxy.name[: -len("_Collision")]
        best, bd = None, 1e9
        for pr in self.props:
            if pr.key == key:
                d = float(np.linalg.norm(pr.box.c - proxy.pos))
                if d < bd:
                    best, bd = pr, d
        return best if bd < 1.5 else None

    # -- (d) walk grid -----------------------------------------------------

    def build_grid(self):
        lay = self.layout
        xs, zs = [], []
        for _, key in REGION_KEYS:
            r = lay.get(key)
            if isinstance(r, dict) and "minX" in r:
                xs += [r["minX"], r["maxX"]]
                zs += [r["minZ"], r["maxZ"]]
        if not xs:
            xs, zs = [-35, 70], [-16, 36]
        x0, x1 = math.floor(min(xs)) - 2, math.ceil(max(xs)) + 2
        z0, z1 = math.floor(min(zs)) - 2, math.ceil(max(zs)) + 2
        g = Grid(x0, x1, z0, z1)
        self.grid = g
        ground = np.zeros((g.nz, g.nx), dtype=bool)
        for f in self.floors:
            g.fill(ground, f.box.footprint())
        obstacle = np.zeros_like(ground)
        for p in self.colliders:
            if p.box.hi[1] < BAND[0] or p.box.lo[1] > BAND[1]:
                continue
            g.fill(obstacle, p.box.footprint(inflate_thin=CELL * 0.51))
        self.ground = ground
        self.obstacle = obstacle
        blocked = obstacle | ~ground
        clear = edt(blocked) * CELL - CELL / 2
        clear[blocked] = 0.0
        self.clear = clear
        sp = self.spawn()
        start = g.index(sp[0], sp[2])
        free1 = clear >= CHAR_RADIUS
        free05 = clear >= FACE_RADIUS
        s1 = nearest_true(free1, start)
        s05 = nearest_true(free05, start)
        self.start = s1 or start
        self.reach1 = flood(free1, s1) if s1 else np.zeros_like(free1)
        self.reach05 = flood(free05, s05) if s05 else np.zeros_like(free05)
        self.free1 = free1
        in_regions = np.zeros_like(free1)
        for _, key in REGION_KEYS:
            r = lay.get(key)
            if isinstance(r, dict) and "minX" in r:
                in_regions |= (g.xs[None, :] >= r["minX"]) & (g.xs[None, :] <= r["maxX"]) & (g.zs[:, None] >= r["minZ"]) & (g.zs[:, None] <= r["maxZ"])
        self.pockets = free1 & ~self.reach1 & in_regions
        self.widest, self.wparent = widest_paths(clear, self.start)
        self.bfs_parent = bfs_paths(self.reach1, self.start)
        # distance (studs) from any cell to the nearest cell a face-first body can reach
        self.expose = edt(self.reach05) * CELL
        X, Z = np.meshgrid(g.xs, g.zs)
        self.X, self.Z = X, Z
        self.result["walk"] = {
            "grid": {"x0": x0, "x1": x1, "z0": z0, "z1": z1, "cell": CELL},
            "spawn": [float(sp[0]), float(sp[1]), float(sp[2])],
            "reachableArea": float(self.reach1.sum() * CELL * CELL),
            "pocketArea": float(self.pockets.sum() * CELL * CELL),
            "doorsTreatedOpen": [d.name for d in self.doors],
        }

    def expose_at(self, pts: np.ndarray) -> np.ndarray:
        g = self.grid
        ix = np.clip(np.floor((pts[:, 0] - g.x0) / g.cell).astype(int), 0, g.nx - 1)
        iz = np.clip(np.floor((pts[:, 2] - g.z0) / g.cell).astype(int), 0, g.nz - 1)
        return self.expose[iz, ix]

    # -- targets ------------------------------------------------------------

    def targets(self) -> list[dict]:
        prompts = parse_prompts(self.src, self.reach)
        self.result["prompts"] = prompts

        def prompt_for(kind):
            for name, match in PROMPT_TARGETS:
                if name == kind:
                    for p in prompts:
                        if match(p):
                            return p
            return None

        out = []

        def add(tid, label, pos, kind, region_box=None):
            if pos is None and region_box is None:
                return
            p = prompt_for(kind)
            dist = p["distance"] if p else float(self.reach.get("prompt", PROMPT_DEFAULT))
            if kind == "notice":
                dist = 8.0
            out.append(
                {
                    "id": tid,
                    "label": label,
                    "pos": None if pos is None else [float(v) for v in pos],
                    "kind": kind,
                    "distance": dist,
                    "action": p["action"] if p else ("(read)" if kind == "notice" else "(walk in)" if region_box else "?"),
                    "promptFile": f"{p['file']}:{p['line']}" if p else None,
                    "region": region_box,
                }
            )

        refs = self.refs
        for i, pc in enumerate(refs.get("sourcePCs") or []):
            add(f"tower{i + 1}", f"Desk {i + 1} tower", vec(pc), "tower")
        add("dock", "Drive dock", vec(refs.get("dock")), "dock")
        add("seat", "Workstation seat", vec(refs.get("seatPromptPart")), "seat")
        add("rack", "Drive rack", vec(refs.get("recoveryRack")), "rack")
        slots = refs.get("stagingSlots") or []
        if slots:
            add("rackslots", "Rack slot (far)", vec(slots[0]), "rackslot")
        for bid, sw in sorted((refs.get("breakerSwitches") or {}).items()):
            add(f"breaker_{bid}", f"Breaker {bid}", vec(sw), "breaker")
        add("reardoor", "Rear door", vec(refs.get("doorPromptPart")), "reardoor")
        add("trash", "Kitchen trash", vec(refs.get("kitchenTrash")) if refs.get("kitchenTrash") else vec(self.layout.get("KITCHEN_TRASH")), "trash")
        add("dumpster", "Dumpster", vec(refs.get("dumpster")), "dumpster")
        add("thermostat", "Thermostat", vec(refs.get("thermostat")), "thermostat")
        add("printer", "Printer", vec(refs.get("printer")), "printer")
        add("outbox", "Out tray", vec(refs.get("outbox")), "outbox")
        add("timeclock", "Time clock", vec(refs.get("timeClock")), "timeclock")
        boards = refs.get("noticeBoards") or []
        if boards:
            add("notice", "Notice board", vec(boards[0]), "notice")
        ez = self.ref_part(refs.get("escapeZone"))
        if ez is not None:
            add("frontdoor", "Front door / escape", ez.pos, "escape", region_box=[float(ez.box.lo[0]), float(ez.box.hi[0]), float(ez.box.lo[2]), float(ez.box.hi[2])])
        return out

    def analyse_targets(self):
        g = self.grid
        nx = g.nx
        results = []
        for t in self.targets():
            if t["region"]:
                x0, x1, z0, z1 = t["region"]
                approach = (self.X >= x0) & (self.X <= x1) & (self.Z >= z0) & (self.Z <= z1)
                d3 = np.zeros_like(self.X)
            else:
                p = t["pos"]
                d3 = np.sqrt((self.X - p[0]) ** 2 + (ROOT_Y - p[1]) ** 2 + (self.Z - p[2]) ** 2)
                approach = d3 <= max(t["distance"] - 1.0, 0.5)
            ok = approach & self.reach1
            reachable = bool(ok.any())
            within = d3[self.reach1] if self.reach1.any() else np.array([math.inf])
            closest = float(within.min()) if within.size else math.inf
            cand = approach & (self.widest > 0)
            width, neck, path, wpath = 0.0, None, [], []
            if cand.any():
                vals = np.where(cand, self.widest, -1)
                k = np.unravel_index(int(np.argmax(vals)), vals.shape)
                width = float(2 * self.widest[k])
                wpath = trace(self.wparent, (int(k[0]), int(k[1])), nx)
                cl = [self.clear[c] for c in wpath]
                j = int(np.argmin(cl))
                neck = [float(g.xs[wpath[j][1]]), 0.0, float(g.zs[wpath[j][0]])]
            if reachable:
                dist_grid = np.where(ok, d3, math.inf)
                k = np.unravel_index(int(np.argmin(dist_grid)), dist_grid.shape)
                path = trace(self.bfs_parent, (int(k[0]), int(k[1])), nx)
            t.update(
                {
                    "reachable": reachable,
                    "closest": closest,
                    "routeWidth": width,
                    "bottleneck": neck,
                    "path": [[float(g.xs[c[1]]), float(g.zs[c[0]])] for c in path[:: max(1, len(path) // 80)]] if path else [],
                }
            )
            results.append(t)
        self.targets_result = results
        self.result["targets"] = results
        crowd = []
        pts = [t for t in results if t["pos"] is not None and t["kind"] not in ("notice", "escape")]
        for i in range(len(pts)):
            for j in range(i + 1, len(pts)):
                dd = float(np.linalg.norm(np.array(pts[i]["pos"]) - np.array(pts[j]["pos"])))
                if dd < 2.5:
                    crowd.append({"a": pts[i]["label"], "b": pts[j]["label"], "distance": round(dd, 2), "sameKey": pts[i]["kind"] == pts[j]["kind"]})
        self.result["promptCrowding"] = crowd
        for t in results:
            where = xz(t["pos"]) if t["pos"] else ""
            if not t["reachable"]:
                self.issue(
                    "critical",
                    "unreachable",
                    f"{t['label']} {where} is not reachable: closest standable point is {fmt(t['closest'], 1)} studs away, prompt reach {fmt(t['distance'], 0)} (-1 margin).",
                    t.get("pos"),
                    t["closest"],
                )
            elif t["routeWidth"] < ROUTE_MIN:
                door = self.doorway_at(t["bottleneck"])
                t["bottleneckDoorway"] = door
                if door:
                    sev = "low"
                    text = f"Route spawn -> {t['label']}: narrowest point is the {door} ({fmt(t['routeWidth'], 1)} studs clear at {xz(t['bottleneck'])}); door openings are fixed by Layout."
                else:
                    sev = "high" if t["routeWidth"] < 2 * CHAR_RADIUS + 0.5 else "medium"
                    text = f"Route spawn -> {t['label']}: widest available route narrows to {fmt(t['routeWidth'], 1)} studs at {xz(t['bottleneck'])} (target {ROUTE_MIN})."
                self.issue(sev, "narrow-route", text, t["bottleneck"], ROUTE_MIN - t["routeWidth"])

    def doorway_at(self, p) -> str | None:
        """Name of the Layout wall opening within 1.5 studs of p, if any."""
        if p is None:
            return None
        lay = self.layout
        M = lay.get("MAIN") or {}
        specs = []
        if lay.get("KITCHEN_GAP") and M:
            specs.append(("kitchen doorway", M["minX"] - 0.5, None, lay["KITCHEN_GAP"]["minZ"], lay["KITCHEN_GAP"]["maxZ"]))
        if lay.get("HALL_GAP") and M:
            specs.append(("hall opening", M["maxX"] + 0.5, None, lay["HALL_GAP"]["minZ"], lay["HALL_GAP"]["maxZ"]))
        if lay.get("LOBBY_GAP") and M:
            specs.append(("lobby doorway", None, M["maxZ"] + 0.5, lay["LOBBY_GAP"]["minX"], lay["LOBBY_GAP"]["maxX"]))
        rd = lay.get("REAR_DOOR")
        if isinstance(rd, dict):
            specs.append(("rear door", rd["x"] + 0.5, None, rd["minZ"], rd["maxZ"]))
        fd = lay.get("FRONT_DOOR")
        if isinstance(fd, dict):
            specs.append(("front door", None, fd["z"] + 0.5, fd["minX"], fd["maxX"]))
        for name, x, z, a, b in specs:
            if x is not None and abs(p[0] - x) <= 1.5 and a - 0.5 <= p[2] <= b + 0.5:
                return name
            if z is not None and abs(p[2] - z) <= 1.5 and a - 0.5 <= p[0] <= b + 0.5:
                return name
        return None

    # -- (a) prop vs prop ---------------------------------------------------

    def supports(self, item: Prop, base: Prop) -> bool:
        """item rests on base's top, or is stored inside storage furniture."""
        top = base.box.hi[1]
        bottom = item.box.lo[1]
        fp_item = item.box.footprint()
        fp_base = Box(base.box.c, base.box.R, base.box.h + np.array([0.15, 0, 0.15])).footprint()
        inter = clip_polygon(fp_item, fp_base)
        if len(inter) < 3:
            return False
        area_item = poly_area(fp_item)
        area_in = poly_area(inter)
        inside = area_item > 0 and area_in / area_item > 0.6
        if not inside:
            return False
        if abs(item.pos[1] - top) <= NEST_TOL or abs(bottom - top) <= NEST_TOL:
            return True
        if base.category in ("storage", "desk") and item.category in ("deskitem", "computer") and bottom >= base.box.lo[1] - 0.05:
            return True
        return False

    def shared_voxels(self, a: Prop, b: Prop) -> int:
        pa, pb = a.points(), b.points()
        lo = np.maximum(a.box.lo, b.box.lo) - VOXEL
        hi = np.minimum(a.box.hi, b.box.hi) + VOXEL
        sa = pa[np.all((pa >= lo) & (pa <= hi), axis=1)]
        sb = pb[np.all((pb >= lo) & (pb <= hi), axis=1)]
        if len(sa) == 0 or len(sb) == 0:
            return 0
        ka = np.unique(voxel_keys(sa))
        kb = np.unique(voxel_keys(sb))
        return len(np.intersect1d(ka, kb, assume_unique=True))

    def prop_overlaps(self):
        props = [p for p in self.visible_props if p.category != "character"]
        overlaps, nested, resting = [], [], []
        for i in range(len(props)):
            a = props[i]
            for j in range(i + 1, len(props)):
                b = props[j]
                if not a.box.aabb_overlap(b.box):
                    continue
                depth, axis = sat_depth(a.box, b.box)
                if depth <= CONTACT_TOL:
                    continue
                small, big = (a, b) if np.prod(a.box.h) <= np.prod(b.box.h) else (b, a)
                if self.supports(small, big):
                    nested.append({"item": small.label, "on": big.label, "depth": depth})
                    continue
                vertical = axis is not None and abs(axis[1]) > 0.95
                if vertical and depth <= NEST_TOL + 0.05:
                    resting.append({"a": a.label, "b": b.label, "depth": round(depth, 3)})
                    continue
                shared = self.shared_voxels(a, b)
                lo = np.maximum(a.box.lo, b.box.lo)
                hi = np.minimum(a.box.hi, b.box.hi)
                center = (lo + hi) / 2
                overlaps.append(
                    {
                        "a": a.label,
                        "b": b.label,
                        "aKey": a.key,
                        "bKey": b.key,
                        "depth": round(depth, 3),
                        "axis": "vertical" if vertical else "horizontal",
                        "meshVoxels": shared,
                        "mesh": shared >= MESH_CONTACT_MIN,
                        "at": [round(float(v), 2) for v in center],
                        "region": region_of(self.layout, center[0], center[2]),
                        "polyA": a.box.footprint(),
                        "polyB": b.box.footprint(),
                    }
                )
        overlaps.sort(key=lambda o: -o["depth"])
        self.overlaps = overlaps
        self.result["propOverlaps"] = [{k: v for k, v in o.items() if not k.startswith("poly")} for o in overlaps]
        self.result["nestedOnSurfaces"] = len(nested)
        self.result["shallowVertical"] = resting
        for o in overlaps:
            o["offsetMesh"] = o["aKey"] in self.offset_keys or o["bKey"] in self.offset_keys
            if o["mesh"] and not o["offsetMesh"]:
                self.issue(
                    "high" if o["depth"] > 0.3 else ("medium" if o["depth"] >= 0.15 else "low"),
                    "prop-overlap",
                    f"{o['a']} intersects {o['b']} by {fmt(o['depth'])} studs at {xyz(o['at'])} (mesh surfaces meet: {o['meshVoxels']} voxels).",
                    o["at"],
                    o["depth"],
                )

    # -- (b) props vs structure --------------------------------------------

    def structure_hits(self):
        hits = []
        others = []
        for p in self.structure:
            kind = "glass" if p.material == "Glass" else ("ceiling" if re.match(r"Ceiling|RoofCap", p.name) else ("trim" if not p.collide else "wall"))
            if p.name in ("Curtain", "CurtainRod", "DoorFrame", "WindowFrame", "WindowMullion"):
                kind = "trim"
            others.append((p, kind))
        for p in self.visible_interactive:
            others.append((p, "fixture"))
        for p in self.collision_proxies:
            others.append((p, "collision"))
        for pr in self.visible_props:
            if pr.category == "character":
                continue
            pts = None
            for part, kind in others:
                if not pr.box.aabb_overlap(part.box):
                    continue
                if kind == "collision":
                    owner = self.owner_of_proxy(part)
                    if owner is pr:
                        continue
                    if owner is None and np.linalg.norm(part.box.c - pr.box.c) < 0.6 and pr.category in ("desk",):
                        continue
                    # the corner workstation slabs belong to the corner desk
                    if part.name.startswith("WSDesk") and pr.key.endswith("desk2_corner"):
                        continue
                depth, _ = sat_depth(pr.box, part.box)
                if depth <= CONTACT_TOL:
                    continue
                if pts is None:
                    pts = pr.points()
                inner = part.box.inside_depth(pts)
                n_in = int((inner > 0.02).sum())
                mesh_depth = float(inner.max()) if len(inner) else 0.0
                if n_in == 0:
                    continue
                owner = self.owner_of_proxy(part) if kind == "collision" else None
                hits.append(
                    {
                        "prop": pr.label,
                        "key": pr.key,
                        "part": part.name if owner is None else f"{part.name} ({owner.label})",
                        "kind": kind,
                        "boxDepth": round(depth, 3),
                        "meshDepth": round(max(mesh_depth, 0.0), 3),
                        "meshPoints": n_in,
                        "at": [round(float(v), 2) for v in pr.box.c],
                        "region": pr.region,
                        "poly": pr.box.footprint(),
                    }
                )
        order = {"wall": 0, "glass": 1, "ceiling": 2, "fixture": 3, "collision": 4, "trim": 5}
        hits.sort(key=lambda h: (order.get(h["kind"], 9), -h["meshDepth"]))
        self.struct_hits = hits
        self.result["structureHits"] = [{k: v for k, v in h.items() if k != "poly"} for h in hits]
        for h in hits:
            if h["key"] in self.offset_keys:
                h["offsetMesh"] = True
                continue
            mounted = h["kind"] == "wall" and categorize(h["key"]) == "wall" and h["meshDepth"] <= FLUSH_MOUNT
            h["flushMount"] = mounted
            if h["kind"] in ("wall", "glass", "ceiling") and h["meshDepth"] > 0.1 and not mounted:
                self.issue("high" if h["meshDepth"] > 0.3 else "medium", "into-structure", f"{h['prop']} penetrates {h['kind']} '{h['part']}' by {fmt(h['meshDepth'])} studs (mesh) near {xyz(h['at'])}.", h["at"], h["meshDepth"])
            elif h["kind"] == "fixture" and h["meshDepth"] > 0.1:
                self.issue("medium", "into-fixture", f"{h['prop']} penetrates '{h['part']}' by {fmt(h['meshDepth'])} studs near {xyz(h['at'])}.", h["at"], h["meshDepth"])

        # sinking below the supporting surface (floor or furniture top)
        sunk = []
        tops = [(p.box, p.name) for p in self.floors] + [(p.box, p.label) for p in self.visible_props if p.category in ("desk", "storage")]
        for pr in self.visible_props:
            if pr.category in ("character",) or pr.mesh is None or pr.key in self.offset_keys:
                continue
            support = None
            for box, name in tops:
                if abs(box.hi[1] - pr.pos[1]) <= 0.12 and box.lo[0] - 0.05 <= pr.pos[0] <= box.hi[0] + 0.05 and box.lo[2] - 0.05 <= pr.pos[2] <= box.hi[2] + 0.05 and box is not pr.box:
                    support = (box, name)
                    break
            if not support:
                continue
            below = float(support[0].hi[1] - pr.mesh_min_y())
            if below > 0.08:
                sunk.append({"prop": pr.label, "key": pr.key, "support": support[1], "below": round(below, 3), "at": [round(float(v), 2) for v in pr.pos]})
        sunk.sort(key=lambda s: -s["below"])
        self.sunk = sunk
        self.result["sunkBelowSupport"] = sunk
        for s in sunk:
            self.issue("medium" if s["below"] > 0.2 else "low", "sunk", f"{s['prop']} mesh extends {fmt(s['below'])} studs below its support ({s['support']}) at {xyz(s['at'])}: raise it or it reads as sunk into the {('floor' if s['support'].startswith('Floor') else 'surface')}.", s["at"], s["below"])

    # -- (c) camera clipping coverage --------------------------------------

    def coverage(self):
        """Horizontal overhang of eye-band mesh points beyond the collision a body bumps into."""
        rows = []
        band = [p for p in self.colliders if p.box.hi[1] >= BAND[0] and p.box.lo[1] <= BAND[1]]
        for pr in self.visible_props:
            if pr.category == "character":
                continue
            if pr.box.hi[1] < COVER_BAND[0] or pr.box.lo[1] > COVER_BAND[1]:
                continue
            wall_mounted = pr.box.lo[1] > 1.5
            if pr.height <= 1.2 and not wall_mounted:
                continue
            pts = pr.points()
            pts = pts[(pts[:, 1] >= COVER_BAND[0]) & (pts[:, 1] <= COVER_BAND[1])]
            if len(pts) == 0:
                continue
            exposed = pts[self.expose_at(pts) <= EXPOSE_DIST]
            if len(exposed) == 0:
                continue
            near = [p for p in band if pr.box.aabb_overlap(p.box, pad=OVERHANG_LIMIT + 1.5)]
            if near:
                dists = []
                for p in near:
                    q = exposed.copy()
                    q[:, 1] = p.box.c[1]  # horizontal distance to the collider's column
                    dists.append(p.box.dist(q))
                d = np.min(np.stack(dists), axis=0)
            else:
                d = np.full(len(exposed), 99.0)
            d = np.minimum(d, 99.0)
            eye = (exposed[:, 1] >= EYE_ZONE[0]) & (exposed[:, 1] <= EYE_ZONE[1])
            worst_eye = float(d[eye].max()) if eye.any() else 0.0
            worst_low = float(d[~eye].max()) if (~eye).any() else 0.0
            k = int(np.argmax(np.where(eye, d, -1))) if eye.any() else int(np.argmax(d))
            proxies = [p.name for p in near if p.group == "Collision" and pr.box.aabb_overlap(p.box, pad=0.2)]
            rows.append(
                {
                    "prop": pr.label,
                    "key": pr.key,
                    "category": pr.category,
                    "at": [round(float(pr.box.c[0]), 2), round(float(pr.pos[1]), 2), round(float(pr.box.c[2]), 2)],
                    "region": pr.region,
                    "height": round(pr.height, 2),
                    "eyeOverhang": round(worst_eye, 3),
                    "lowOverhang": round(worst_low, 3),
                    "worstPoint": [round(float(v), 2) for v in exposed[k]],
                    "collision": sorted(set(proxies))[:4],
                    "hasOwnProxy": any(n == pr.key + "_Collision" for n in proxies),
                    "flag": worst_eye > OVERHANG_LIMIT,
                    "flagOutsideEye": worst_eye <= OVERHANG_LIMIT < worst_low,
                    "poly": pr.box.footprint(),
                }
            )
        rows.sort(key=lambda r: (-r["eyeOverhang"], -r["lowOverhang"]))
        self.coverage_rows = rows
        self.result["coverage"] = [{k: v for k, v in r.items() if k != "poly"} for r in rows]
        for r in rows:
            if r["flag"]:
                what = "has no collision under it" if r["eyeOverhang"] >= 99 else f"reaches {fmt(r['eyeOverhang'])} studs beyond the collision footprint"
                self.issue(
                    "high" if r["eyeOverhang"] > 0.6 else "medium",
                    "camera-clip",
                    f"{r['prop']} at {xyz(r['at'])}: mesh at eye height {what} (worst point {xyz(r['worstPoint'])}); a first-person camera walking up to it can enter the mesh.",
                    r["worstPoint"],
                    min(r["eyeOverhang"], 5),
                )
            elif r["flagOutsideEye"]:
                what = "has no collision" if r["lowOverhang"] >= 99 else f"reaches {fmt(r['lowOverhang'])} studs beyond collision"
                self.issue("low", "overhang", f"{r['prop']} at {xyz(r['at'])}: mesh outside the eye zone (3-4 or 5.8-6.5 studs) {what}.", r["at"], min(r["lowOverhang"], 5) / 10)

    # -- scale sanity -------------------------------------------------------------

    def scale_checks(self):
        rows = []
        seen = set()
        for pr in self.visible_props:
            for pattern, dim, lo, hi in SCALE_HINTS:
                if not re.search(pattern, pr.key):
                    continue
                size = (pr.local_hi - pr.local_lo)
                value = float(size[1]) if dim == "h" else float(max(size[0], size[2]))
                if value < lo or value > hi:
                    tag = (pr.key, round(pr.scale, 3))
                    if tag in seen:
                        break
                    seen.add(tag)
                    want = (lo + hi) / 2
                    rows.append({"prop": pr.label, "key": pr.key, "scale": pr.scale, "dim": "height" if dim == "h" else "width", "value": round(value, 2), "expected": [lo, hi], "suggestScale": round(pr.scale * want / value, 2), "at": [round(float(v), 2) for v in pr.pos]})
                break
        self.result["scaleSanity"] = rows
        for r in rows:
            self.issue("medium" if (r["value"] > r["expected"][1] * 1.4 or r["value"] < r["expected"][0] / 1.4) else "low", "scale", f"{short(r['key'])} at {xz(r['at'])} is {fmt(r['value'], 1)} studs {r['dim']} (plausible {r['expected'][0]}-{r['expected'][1]}); ArtScale {fmt(r['scale'], 2)} -> about {fmt(r['suggestScale'], 2)}.", r["at"], abs(r["value"] - (r["expected"][0] + r["expected"][1]) / 2) / 5)

    # -- art origin sanity -------------------------------------------------------

    def origins(self):
        rows = []
        for pr in self.props:
            off = float(np.linalg.norm((pr.box.c - pr.pos)[[0, 2]]))
            reach = float(np.linalg.norm(pr.box.h[[0, 2]]))
            if off > max(3.0, reach * 1.5):
                rows.append({"prop": pr.label, "key": pr.key, "anchor": [round(float(v), 2) for v in pr.pos], "meshCenter": [round(float(v), 2) for v in pr.box.c], "offset": round(off, 1)})
        rows.sort(key=lambda r: -r["offset"])
        self.offset_keys = {r["key"] for r in rows}
        self.result["originOffsets"] = rows
        by_key = defaultdict(list)
        for r in rows:
            by_key[r["key"]].append(r)
        for key, group in sorted(by_key.items(), key=lambda kv: -kv[1][0]["offset"]):
            where = ", ".join(xz(r["anchor"]) for r in group)
            first = group[0]
            lands = region_of(self.layout, first["meshCenter"][0], first["meshCenter"][2])
            lands = f" (inside the {lands} area)" if lands != "Outside" else " (outside the playable map)"
            proxy = any(c.name == key + "_Collision" for c in self.collision_proxies)
            moved = " Its collision proxy is built from the same bounds, so the collision moved too." if proxy else ""
            self.issue(
                "high",
                "mesh-offset",
                f"{short(key)} x{len(group)}: the converted mesh sits {fmt(first['offset'], 0)} studs from its anchor, so it renders near {xz(first['meshCenter'])}{lands} instead of {where}.{moved} Re-centre the model in tools/convert_assets.py or compensate in MapBuilder.",
                first["anchor"],
                1.0,
            )

    # -- chairs --------------------------------------------------------------

    def chairs(self):
        lay = self.layout
        solids = [p.box for p in self.colliders if p.box.hi[1] >= BAND[0] and p.box.lo[1] <= BAND[1]]
        solid_props = [pr for pr in self.visible_props if pr.box.lo[1] < 0.5 and pr.height > 0.6 and pr.category not in ("character",)]
        chairs = [pr for pr in self.visible_props if pr.category == "chair"]
        rows = []
        specs = []  # (name, where the chair should be, direction pointing away from the desk)
        for d in lay.get("DESKS") or []:
            pos, front = vec(d.get("pos")), vec(d.get("front"))
            if pos is None or front is None:
                continue
            f = front / (np.linalg.norm(front) or 1)
            specs.append((f"Desk {d.get('index')}", pos + f * 2.7, f))
        ws = lay.get("WORKSTATION") or {}
        if vec(ws.get("chair")) is not None and vec(ws.get("facing")) is not None:
            f = vec(ws.get("facing"))
            specs.append(("Workstation", vec(ws.get("chair")), -f / (np.linalg.norm(f) or 1)))
        used = set()
        for name, guess, f in specs:
            best, bd = None, 3.5
            for c in chairs:
                if c.uid in used:
                    continue
                dd = float(np.linalg.norm((c.pos - guess)[[0, 2]]))
                if dd < bd:
                    best, bd = c, dd
            if best is None:
                continue
            used.add(best.uid)
            c = best
            back = np.array([f[0], 0.0, f[2]])
            side = np.array([-back[2], 0.0, back[0]])
            # extent of the chair along back/side directions (from its box corners)
            cs = c.box.corners()
            along = (cs - c.pos) @ back
            across = (cs - c.pos) @ side
            start = c.pos + back * float(along.max())
            lanes = np.linspace(float(across.min()) + 0.1, float(across.max()) - 0.1, 5)
            steps = np.arange(0.0, 8.0, 0.05)
            pts = (start[None, None, :] + side[None, None, :] * lanes[None, :, None] + back[None, None, :] * steps[:, None, None]).reshape(-1, 3)
            pts[:, 1] = 1.0
            hit = np.zeros(len(pts), dtype=bool)
            own = {c.uid}
            for b in solids:
                if np.linalg.norm((b.c - c.box.c)[[0, 2]]) < 0.4 and b.h.max() < 2.0:
                    continue  # the chair's own slim proxy
                hit |= b.inside_depth(pts) > 0
            for pr in solid_props:
                if pr.uid in own:
                    continue
                q0 = c.pos.copy()
                q0[1] = pr.box.c[1]
                if pr.box.inside_depth(q0[None, :])[0] > 0:
                    continue  # the chair stands inside this prop's box (L-shaped corner desk): use its collision instead
                q = pts.copy()
                q[:, 1] = pr.box.c[1]
                hit |= pr.box.inside_depth(q) > 0
            g = self.grid
            ix = np.clip(np.floor((pts[:, 0] - g.x0) / g.cell).astype(int), 0, g.nx - 1)
            iz = np.clip(np.floor((pts[:, 2] - g.z0) / g.cell).astype(int), 0, g.nz - 1)
            hit |= ~self.ground[iz, ix]
            hit = hit.reshape(len(steps), len(lanes))
            free = 8.0
            for k in range(len(steps)):
                if hit[k].any():
                    free = float(steps[k])
                    break
            facing = self.chair_facing(c)
            err = None
            if facing is not None:
                # a seated user faces the desk: the seat's front should point opposite `back`
                cosang = float(np.clip(-(facing @ back), -1, 1))
                err = round(math.degrees(math.acos(cosang)), 0)
            rows.append({"desk": name, "chair": c.label, "key": c.key, "at": [round(float(v), 2) for v in c.pos], "freeBehind": round(free, 2), "dir": [round(float(back[0]), 2), round(float(back[2]), 2)], "ok": free >= CHAIR_BACK_MIN, "facingError": err})
        self.chair_rows = rows
        self.result["chairs"] = rows
        for r in rows:
            if r["facingError"] is not None and r["facingError"] > 45:
                way = "backwards (backrest against the desk)" if r["facingError"] > 135 else "sideways"
                self.issue("high", "chair-facing", f"{r['desk']} chair {r['chair']} at {xz(r['at'])} faces {way}: seat front is {fmt(r['facingError'], 0)} deg off the desk direction (model's native front is not +Z; add a yaw for {short(r['key'])}).", r["at"], r["facingError"] / 90)
            if not r["ok"]:
                self.issue("medium", "chair-space", f"{r['desk']} chair {r['chair']} at {xz(r['at'])}: only {fmt(r['freeBehind'], 1)} studs of free floor behind it (target {CHAIR_BACK_MIN}).", r["at"], CHAIR_BACK_MIN - r["freeBehind"])

    def chair_facing(self, c: Prop):
        """World direction the seat faces, inferred from where the backrest is (top quarter of the mesh)."""
        if c.mesh is None:
            return None
        v = c.mesh.verts
        lo, hi = v.min(axis=0), v.max(axis=0)
        top = v[v[:, 1] > lo[1] + 0.75 * (hi[1] - lo[1])]
        if len(top) < 3:
            return None
        center = (lo + hi) / 2
        offset = top.mean(axis=0) - center
        offset[1] = 0
        if np.linalg.norm(offset) < 0.25:
            return None  # backrest not off-centre enough to tell (stools, symmetric chairs)
        world = c.R @ (-offset)
        world[1] = 0
        return world / np.linalg.norm(world)

    # -- door swing ------------------------------------------------------------

    def door_swing(self):
        refs = self.refs
        hinge = refs.get("rearDoorHinge")
        door = self.ref_part(refs.get("rearDoor"))
        out = {}
        if isinstance(hinge, dict) and door is not None:
            hp = np.array(hinge["pos"], dtype=float)
            width = float(door.size[2] + 0.1)
            angles = np.radians(np.linspace(0, 100, 41))
            radii = np.linspace(0.75, width, 10)  # inner hinge region sits in the jamb by construction
            A, Rr = np.meshgrid(angles, radii)
            pts = np.stack([hp[0] + Rr.ravel() * np.sin(A.ravel()), np.full(A.size, 1.0), hp[2] + Rr.ravel() * np.cos(A.ravel())], axis=1)
            blockers = set()
            for p in self.colliders:
                if p.uid == door.uid or p.box.hi[1] < 0.3:
                    continue
                if (p.box.inside_depth(pts) > 0.02).any():
                    blockers.add(p.name)
            for pr in self.visible_props:
                q = pts.copy()
                q[:, 1] = pr.box.c[1]
                if pr.box.lo[1] < 2 and (pr.box.inside_depth(q) > 0.02).any():
                    blockers.add(pr.label)
            out = {"hinge": hp.tolist(), "width": width, "openAngle": 100, "blockers": sorted(blockers)}
            for b in sorted(blockers):
                self.issue("medium", "door-swing", f"Rear door swing (hinge {xz(hp)}, 100 deg outward) is obstructed by {b}.", hp.tolist(), 1.0)
        self.result["rearDoorSwing"] = out

    # -- (e) clutter ---------------------------------------------------------

    def clutter(self):
        lay = self.layout
        by_region = defaultdict(Counter)
        for pr in self.visible_props:
            by_region[pr.region][pr.category] += 1
        self.result["propsByRegion"] = {r: {"total": sum(c.values()), **dict(c)} for r, c in sorted(by_region.items())}
        desks = []
        top = float(lay.get("DESK_TOP") or 3.1)
        specs = [(f"Desk {d.get('index')}", vec(d.get("pos")), d.get("art")) for d in lay.get("DESKS") or []]
        ws = lay.get("WORKSTATION") or {}
        if vec(ws.get("desk")) is not None:
            specs.append(("Workstation", vec(ws.get("desk")), None))
        for name, pos, art in specs:
            if pos is None:
                continue
            desk = None
            bd = 1.0
            for pr in self.visible_props:
                if pr.category == "desk" and np.linalg.norm((pr.pos - pos)[[0, 2]]) < bd:
                    desk, bd = pr, float(np.linalg.norm((pr.pos - pos)[[0, 2]]))
            if desk is None:
                continue
            fp = Box(desk.box.c, desk.box.R, desk.box.h + np.array([0.3, 0, 0.3]))
            items = []
            for pr in self.visible_props:
                if pr is desk or pr.category in ("chair", "desk"):
                    continue
                if abs(pr.pos[1] - top) > 0.6:
                    continue
                q = pr.pos.copy()
                q[1] = fp.c[1]
                if fp.inside_depth(q[None, :])[0] > 0:
                    items.append(pr)
            kit = [i for i in items if i.category == "computer"]
            personal = [i for i in items if i.category != "computer"]
            desks.append({"desk": name, "art": desk.key, "items": len(items), "computerKit": len(kit), "personal": len(personal), "personalItems": [short(i.key) for i in personal]})
        self.result["desks"] = desks
        weathered = []
        for pr in self.visible_props:
            if WEATHERED_RE.search(pr.key):
                weathered.append({"prop": pr.label, "key": pr.key, "region": pr.region, "indoor": pr.region in INDOOR, "at": [round(float(v), 2) for v in pr.pos]})
        weathered.sort(key=lambda w: (not w["indoor"], w["region"], w["key"]))
        self.result["weathered"] = weathered
        for w in weathered:
            if w["indoor"]:
                self.issue("medium", "weathered-indoor", f"{w['prop']} ({w['region']}) at {xz(w['at'])} is a weathered/trash/hazard asset indoors.", w["at"], 0.5)
        surfaces = Counter()
        dirty = Counter()
        for p in self.parts:
            for s in p.surfaces:
                surfaces[s] += 1
                region = region_of(lay, p.pos[0], p.pos[2])
                if DIRTY_SURFACE_RE.search(s) and region in INDOOR:
                    dirty[s] += 1
        self.result["surfaces"] = dict(surfaces)
        self.result["dirtySurfacesIndoor"] = dict(dirty)
        if self.unknown_keys:
            for k in self.unknown_keys:
                self.issue("high", "unknown-key", f"Art key '{k}' is not in ArtData.Index: the client renders nothing there.", None, 1.0)

    # -- surface textures ------------------------------------------------------

    def surface_stats(self):
        """Grime check on the tiled textures actually used indoors (stains are baked into some)."""
        use = defaultdict(Counter)
        for p in self.parts:
            if p.group != "Structure" or not p.surfaces:
                continue
            if region_of(self.layout, p.pos[0], p.pos[2]) not in INDOOR and not p.name.startswith(("Wall", "Kitchen", "Lobby", "Hall", "Ceiling", "Floor")):
                continue
            kind = "floor" if p.name.startswith("Floor") else ("ceiling" if p.name.startswith("Ceiling") else "wall")
            for sname in p.surfaces:
                use[sname][kind] += 1
        surfaces = self.dump.get("surfaces") or {}
        rows, digests = [], {}
        for sname, kinds in sorted(use.items()):
            mod = surfaces.get(sname) if isinstance(surfaces, dict) else None
            img = artmesh.load_surface(self.art_dir, mod) if mod else None
            if img is None:
                continue
            f = img.astype(np.float64) / 255
            lum = f @ np.array([0.2126, 0.7152, 0.0722])
            med = float(np.median(lum))
            blotch = float((lum < 0.7 * med).mean() * 100)
            digest = hash(img.tobytes())
            same = digests.get(digest)
            digests.setdefault(digest, sname)
            rows.append({"surface": sname, "module": mod, "usedOn": dict(kinds), "mean": [round(float(v) * 255) for v in f.reshape(-1, 3).mean(axis=0)], "medianLum": round(med * 255), "blotchPct": round(blotch, 2), "lumStd": round(float(lum.std() * 255), 1), "sameImageAs": same})
        self.result["surfaceTextures"] = rows
        for r in rows:
            if r["usedOn"].get("wall") and r["blotchPct"] > 0.5 and not ROUGH_SURFACE_RE.search(r["surface"]):
                self.issue("medium", "dirty-texture", f"Wall texture '{r['surface']}' ({r['module']}) has {fmt(r['blotchPct'], 1)}% dark blotches (stains baked into the image); used on {r['usedOn']['wall']} wall parts.", None, r["blotchPct"])
            if r["usedOn"].get("ceiling") and r["blotchPct"] > 10:
                self.issue("low", "dirty-texture", f"Ceiling texture '{r['surface']}' ({r['module']}) has {fmt(r['blotchPct'], 1)}% dark blotches.", None, r["blotchPct"] / 10)

    # -- lights --------------------------------------------------------------

    def lights(self):
        rows = []
        for l in self.dump.get("lights") or []:
            r, g, b = l["color"]
            groups = sorted(set(l.get("groups") or []))
            if "emergency" in groups or (r > 200 and g < 120 and b < 120):
                kind = "emergency"
            elif g > r + 60 and g > b + 60:
                kind = "status"
            elif r - b > 40 and r >= g:
                kind = "amber"
            elif b - r > 10:
                kind = "cold"
            else:
                kind = "neutral"
            pos = l["pos"]
            rows.append({"class": l["class"], "kind": kind, "groups": groups, "pos": pos, "range": l["range"], "brightness": l["brightness"], "color": [r, g, b], "region": region_of(self.layout, pos[0], pos[2]), "holder": l.get("holderName")})
        self.light_rows = rows
        summary = defaultdict(Counter)
        for r in rows:
            summary[r["region"]][r["kind"]] += 1
        self.result["lights"] = {"count": len(rows), "byRegion": {k: dict(v) for k, v in sorted(summary.items())}, "list": rows}

    # -- issues ---------------------------------------------------------------

    def issue(self, severity, kind, text, at, weight):
        self.issues.append({"severity": severity, "kind": kind, "text": text, "at": at, "weight": float(weight or 0)})

    def run(self):
        t0 = time.time()
        self.build_grid()
        self.analyse_targets()
        self.origins()
        self.scale_checks()
        self.prop_overlaps()
        self.structure_hits()
        self.coverage()
        self.chairs()
        self.door_swing()
        self.clutter()
        self.surface_stats()
        self.lights()
        sev = {"critical": 0, "high": 1, "medium": 2, "low": 3}
        self.issues.sort(key=lambda i: (sev[i["severity"]], -i["weight"]))
        for n, i in enumerate(self.issues, 1):
            i["id"] = n
        self.result["issues"] = self.issues
        self.result["metrics"] = self.metrics()
        self.result["harnessWarnings"] = self.dump.get("warnings") or []
        self.result["seconds"] = round(time.time() - t0, 2)

    def metrics(self) -> dict:
        t = self.targets_result
        routes = [x for x in t if x["routeWidth"] > 0]
        narrow = min(routes, key=lambda x: x["routeWidth"]) if routes else None
        indoor = [p for p in self.visible_props if p.region in INDOOR]
        desks = self.result.get("desks") or []
        real_desks = [d for d in desks if d["desk"] != "Workstation"]
        return {
            "desks": len(self.layout.get("DESKS") or []),
            "artPropsVisible": len(self.visible_props),
            "artPropsIndoor": len(indoor),
            "artPropsOffice": sum(1 for p in self.visible_props if p.region == "Office"),
            "avgItemsPerDesk": round(sum(d["items"] for d in real_desks) / len(real_desks), 2) if real_desks else 0,
            "avgPersonalItemsPerDesk": round(sum(d["personal"] for d in real_desks) / len(real_desks), 2) if real_desks else 0,
            "weatheredIndoor": sum(1 for w in self.result["weathered"] if w["indoor"]),
            "weatheredOutdoor": sum(1 for w in self.result["weathered"] if not w["indoor"]),
            "dirtySurfaceFacesIndoor": sum(self.result["dirtySurfacesIndoor"].values()),
            "wallTextureBlotchPct": max([r["blotchPct"] for r in self.result.get("surfaceTextures", []) if r["usedOn"].get("wall") and not ROUGH_SURFACE_RE.search(r["surface"])] or [0]),
            "ceilingTextureBlotchPct": max([r["blotchPct"] for r in self.result.get("surfaceTextures", []) if r["usedOn"].get("ceiling")] or [0]),
            "propOverlapsBox": len(self.overlaps),
            "propOverlapsMesh": sum(1 for o in self.overlaps if o["mesh"] and not o.get("offsetMesh")),
            "maxPropOverlapMesh": max([o["depth"] for o in self.overlaps if o["mesh"] and not o.get("offsetMesh")] or [0]),
            "intoWallsGlassCeiling": sum(1 for h in self.struct_hits if h["kind"] in ("wall", "glass", "ceiling") and h["meshDepth"] > 0.1 and not h.get("flushMount") and not h.get("offsetMesh")),
            "intoTrim": sum(1 for h in self.struct_hits if h["kind"] == "trim"),
            "intoOtherCollision": sum(1 for h in self.struct_hits if h["kind"] == "collision" and h["meshDepth"] > 0.1),
            "sunkBelowSupport": sum(1 for s in self.sunk if s["below"] > 0.08),
            "cameraClipProps": sum(1 for r in self.coverage_rows if r["flag"]),
            "meshOffsetProps": len(self.result.get("originOffsets") or []),
            "scaleOutliers": len(self.result.get("scaleSanity") or []),
            "maxEyeOverhang": max([min(r["eyeOverhang"], 99) for r in self.coverage_rows] or [0]),
            "targets": len(t),
            "targetsReachable": sum(1 for x in t if x["reachable"]),
            "routesUnder3_5": sum(1 for x in t if x["routeWidth"] < ROUTE_MIN),
            "narrowestRoute": round(narrow["routeWidth"], 2) if narrow else 0,
            "narrowestRouteTo": narrow["label"] if narrow else None,
            "chairsUnder2_5": sum(1 for r in self.chair_rows if not r["ok"]),
            "chairsMisfacing": sum(1 for r in self.chair_rows if r.get("facingError") is not None and r["facingError"] > 45),
            "minFreeBehindChair": min([r["freeBehind"] for r in self.chair_rows] or [0]),
            "reachableArea": round(self.result["walk"]["reachableArea"], 1),
            "pocketArea": round(self.result["walk"]["pocketArea"], 1),
            "lights": len(self.light_rows),
            "amberLights": sum(1 for r in self.light_rows if r["kind"] == "amber"),
            "coldLights": sum(1 for r in self.light_rows if r["kind"] == "cold"),
            "collisionProxies": len(self.collision_proxies),
            "issues": len(self.issues),
        }


def voxel_keys(pts: np.ndarray) -> np.ndarray:
    k = np.floor(pts / VOXEL).astype(np.int64) + 100000
    return (k[:, 0] * 400000 + k[:, 1]) * 400000 + k[:, 2]


def poly_area(poly) -> float:
    if len(poly) < 3:
        return 0.0
    s = 0.0
    for i in range(len(poly)):
        x1, z1 = poly[i]
        x2, z2 = poly[(i + 1) % len(poly)]
        s += x1 * z2 - x2 * z1
    return abs(s) / 2


# ---------------------------------------------------------------------------
# (f) Plan image
# ---------------------------------------------------------------------------


def load_font(size: int, bold: bool = False):
    names = ["DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"]
    for base in ("/usr/share/fonts/truetype/dejavu", "/usr/share/fonts/dejavu", "/Library/Fonts", "C:/Windows/Fonts"):
        for n in names:
            p = Path(base) / n
            if p.is_file():
                return ImageFont.truetype(str(p), size)
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


KIND_COLORS = {"amber": (230, 170, 80), "cold": (150, 190, 225), "neutral": (235, 235, 215), "emergency": (220, 60, 50), "status": (90, 230, 120)}


def render_plan(a: Audit, path: Path, scale: float = 18.0):
    lay = a.layout
    xs, zs = [], []
    for name, key in REGION_KEYS:
        r = lay.get(key)
        if isinstance(r, dict) and "minX" in r:
            xs += [r["minX"], r["maxX"]]
            zs += [r["minZ"], r["maxZ"]]
    x0, x1 = min(xs) - 3, max(xs) + 2
    z0, z1 = min(zs) - 3, max(zs) + 2
    margin_l, margin_t, legend_w, margin_b = 56, 92, 360, 40
    W = int((x1 - x0) * scale) + margin_l + legend_w
    H = int((z1 - z0) * scale) + margin_t + margin_b
    img = Image.new("RGBA", (W, H), (22, 25, 28, 255))
    f_small, f_big, f_title = load_font(13), load_font(22, True), load_font(26, True)
    f_bold = load_font(14, True)

    def P(x, z):
        return (margin_l + (x - x0) * scale, margin_t + (z - z0) * scale)

    def poly_px(poly):
        return [P(x, z) for x, z in poly]

    def layer():
        return Image.new("RGBA", (W, H), (0, 0, 0, 0))

    def paste(lyr):
        nonlocal img
        img = Image.alpha_composite(img, lyr)

    # floors
    lyr = layer()
    d = ImageDraw.Draw(lyr)
    for f in sorted(a.floors, key=lambda p: p.box.hi[1]):
        c = tuple(int(v * 0.8) for v in f.color)
        d.polygon(poly_px(f.box.footprint()), fill=c + (255,))
    paste(lyr)

    # walk grid overlays
    g = a.grid
    rgba = np.zeros((g.nz, g.nx, 4), dtype=np.uint8)
    rgba[a.reach1] = (170, 230, 190, 34)
    rgba[a.pockets] = (255, 140, 40, 150)
    unreach_ground = a.ground & ~a.obstacle & ~a.reach1 & ~a.pockets & (a.clear > 0)
    rgba[unreach_ground] = (0, 0, 0, 0)
    over = Image.fromarray(rgba, "RGBA").resize((int(g.nx * g.cell * scale), int(g.nz * g.cell * scale)), Image.NEAREST)
    lyr = layer()
    lyr.paste(over, (int(P(g.x0, g.z0)[0]), int(P(g.x0, g.z0)[1])))
    paste(lyr)

    # region labels
    lyr = layer()
    d = ImageDraw.Draw(lyr)
    for name, key in REGION_KEYS:
        r = lay.get(key)
        if isinstance(r, dict) and "minX" in r:
            cx, cz = P((r["minX"] + r["maxX"]) / 2, r["minZ"] + 1.2)
            d.text((cx, cz), name.upper(), font=f_big, fill=(255, 255, 255, 60), anchor="mt")
    paste(lyr)

    # structure + collision
    lyr = layer()
    d = ImageDraw.Draw(lyr)
    for p in a.structure:
        if p.box.lo[1] > BAND[1] + 3 or p.box.hi[1] < 0.2:
            continue
        poly = poly_px(p.box.footprint())
        if len(poly) < 3:
            continue
        if p.material == "Glass":
            d.polygon(poly, fill=(140, 190, 220, 170), outline=(190, 225, 245, 255))
        elif p.collide:
            d.polygon(poly, fill=(52, 60, 66, 255), outline=(120, 130, 136, 255))
        elif p.name not in ("Trim",):
            d.polygon(poly, outline=(183, 176, 156, 150))
    for p in a.parts:
        if p.collide and p.group == "Structure" and not p.visible and p.box.hi[1] > BAND[0]:
            d.polygon(poly_px(p.box.footprint()), fill=(90, 40, 40, 90), outline=(200, 90, 90, 200))
    paste(lyr)

    # props: projected mesh silhouettes, low to high
    lyr = layer()
    d = ImageDraw.Draw(lyr)
    for pr in sorted(a.visible_props, key=lambda q: q.box.hi[1]):
        if pr.category == "character":
            continue
        col = CATEGORY_COLORS.get(pr.category, CATEGORY_COLORS["other"])
        if pr.mesh is not None:
            v = artmesh.transform(pr.mesh.verts, pr.pos, pr.R, pr.scale)
            px = np.stack([margin_l + (v[:, 0] - x0) * scale, margin_t + (v[:, 2] - z0) * scale], axis=1)
            for tri in pr.mesh.tris:
                pts = [tuple(px[i]) for i in tri]
                d.polygon(pts, fill=col + (120,))
        d.polygon(poly_px(pr.box.footprint()), outline=col + (255,))
    for pr in a.visible_props:
        if pr.category != "chair":
            continue
        f = a.chair_facing(pr)
        if f is None:
            continue
        c0 = P(pr.box.c[0], pr.box.c[2])
        tip = P(pr.box.c[0] + f[0] * 1.6, pr.box.c[2] + f[2] * 1.6)
        d.line([c0, tip], fill=(255, 255, 255, 255), width=3)
        side = np.array([-f[2], f[0]])
        base = (pr.box.c[0] + f[0] * 1.0, pr.box.c[2] + f[2] * 1.0)
        d.polygon([tip, P(base[0] + side[0] * 0.4, base[1] + side[1] * 0.4), P(base[0] - side[0] * 0.4, base[1] - side[1] * 0.4)], fill=(255, 255, 255, 255))
    paste(lyr)

    # collision proxies: hatched, so the gap between mesh and collision reads at a glance
    lyr = layer()
    for p in a.collision_proxies:
        poly = poly_px(p.box.footprint())
        if len(poly) < 3:
            continue
        bx0, by0 = int(min(q[0] for q in poly)) - 1, int(min(q[1] for q in poly)) - 1
        bx1, by1 = int(max(q[0] for q in poly)) + 2, int(max(q[1] for q in poly)) + 2
        w, h = bx1 - bx0, by1 - by0
        local = [(q[0] - bx0, q[1] - by0) for q in poly]
        mask = Image.new("L", (w, h), 0)
        ImageDraw.Draw(mask).polygon(local, fill=255)
        hatch = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        hd = ImageDraw.Draw(hatch)
        for k in range(-h, w + 1, 7):
            hd.line([(k, h), (k + h, 0)], fill=(235, 90, 235, 120), width=1)
        lyr.paste(hatch, (bx0, by0), mask)
        ImageDraw.Draw(lyr).polygon(poly, outline=(235, 90, 235, 230))
    paste(lyr)

    # visible interactive parts
    lyr = layer()
    d = ImageDraw.Draw(lyr)
    for p in a.visible_interactive:
        if p.size.max() < 0.3:
            continue
        d.polygon(poly_px(p.box.footprint()), fill=(240, 236, 214, 200), outline=(255, 255, 255, 255))
    for p in a.doors:
        d.polygon(poly_px(p.box.footprint()), fill=(120, 180, 210, 160), outline=(200, 230, 255, 255))
    sw = a.result.get("rearDoorSwing") or {}
    if sw:
        hx, hz = sw["hinge"][0], sw["hinge"][2]
        r = sw["width"]
        cx, cz = P(hx, hz)
        bbox = [cx - r * scale, cz - r * scale, cx + r * scale, cz + r * scale]
        # angle 0 = +Z (down on the image), sweeping toward +X (right) => image angles 90 -> -10
        d.arc(bbox, start=-10, end=90, fill=(200, 230, 255, 255), width=2)
        d.line([P(hx, hz), P(hx + r * math.sin(math.radians(100)), hz + r * math.cos(math.radians(100)))], fill=(200, 230, 255, 200), width=1)
    paste(lyr)

    # lights
    lyr = layer()
    d = ImageDraw.Draw(lyr)
    for l in a.light_rows:
        col = KIND_COLORS[l["kind"]]
        cx, cz = P(l["pos"][0], l["pos"][2])
        rad = max(4.0, l["range"] * scale * 0.12)
        alpha = 40 if l["kind"] == "emergency" else 70
        d.ellipse([cx - rad, cz - rad, cx + rad, cz + rad], fill=col + (alpha,), outline=col + (200,))
        d.ellipse([cx - 3, cz - 3, cx + 3, cz + 3], fill=col + (255,))
    paste(lyr)

    # overlaps / structure hits / coverage gaps
    lyr = layer()
    d = ImageDraw.Draw(lyr)
    for o in a.overlaps:
        if not o["mesh"] or o.get("offsetMesh"):
            continue
        inter = clip_polygon(o["polyA"], o["polyB"])
        if len(inter) >= 3:
            d.polygon(poly_px(inter), fill=(255, 40, 40, 150), outline=(255, 80, 80, 255))
    for h in a.struct_hits:
        if h["kind"] in ("wall", "glass", "ceiling", "fixture") and h["meshDepth"] > 0.1:
            d.polygon(poly_px(h["poly"]), outline=(255, 60, 60, 255))
    for r in a.coverage_rows:
        if r["flag"]:
            d.polygon(poly_px(r["poly"]), outline=(255, 120, 255, 255))
            d.line(poly_px(r["poly"]) + [poly_px(r["poly"])[0]], fill=(255, 120, 255, 255), width=3)
    paste(lyr)

    # routes
    lyr = layer()
    d = ImageDraw.Draw(lyr)
    for t in a.targets_result:
        if len(t["path"]) > 1:
            d.line([P(x, z) for x, z in t["path"]], fill=(120, 200, 255, 120), width=2)
    for t in a.targets_result:
        if t["bottleneck"] and t["routeWidth"] < ROUTE_MIN:
            cx, cz = P(t["bottleneck"][0], t["bottleneck"][2])
            col = (255, 200, 60, 255) if t["routeWidth"] >= 2.5 else (255, 90, 40, 255)
            rad = t["routeWidth"] / 2 * scale
            d.ellipse([cx - rad, cz - rad, cx + rad, cz + rad], outline=col, width=2)
    paste(lyr)

    # labels with collision avoidance
    lyr = layer()
    d = ImageDraw.Draw(lyr)
    placed = []

    def place_label(x, y, text, color=(240, 240, 240), font=f_small, bg=(16, 18, 20, 210)):
        tw, th = d.textbbox((0, 0), text, font=font)[2:]
        for dx, dy in ((10, -th / 2), (-10 - tw, -th / 2), (-tw / 2, -th - 10), (-tw / 2, 10), (14, -th - 6), (14, 6), (-14 - tw, -th - 6), (-14 - tw, 6), (-tw / 2, -th - 24), (-tw / 2, 24)):
            box = (x + dx - 3, y + dy - 2, x + dx + tw + 3, y + dy + th + 3)
            if all(box[2] < b[0] or box[0] > b[2] or box[3] < b[1] or box[1] > b[3] for b in placed):
                break
        placed.append(box)
        d.rectangle(box, fill=bg)
        d.text((box[0] + 3, box[1] + 1), text, font=font, fill=color + (255,))

    sp = a.result["walk"]["spawn"]
    cx, cz = P(sp[0], sp[2])
    d.polygon([(cx, cz - 9), (cx + 8, cz + 6), (cx - 8, cz + 6)], fill=(120, 220, 255, 255))
    placed.append((cx - 9, cz - 10, cx + 9, cz + 7))
    marks = []
    for t in a.targets_result:
        p = t["pos"]
        if p is None:
            continue
        cx, cz = P(p[0], p[2])
        ok = t["reachable"]
        col = (90, 230, 120) if ok else (255, 70, 60)
        d.ellipse([cx - 6, cz - 6, cx + 6, cz + 6], fill=col + (255,), outline=(10, 10, 10, 255), width=2)
        if not ok:
            d.line([cx - 9, cz - 9, cx + 9, cz + 9], fill=(255, 70, 60, 255), width=3)
            d.line([cx - 9, cz + 9, cx + 9, cz - 9], fill=(255, 70, 60, 255), width=3)
        placed.append((cx - 7, cz - 7, cx + 7, cz + 7))
        marks.append((cx, cz, t, col))
    for cx, cz, t, col in marks:
        txt = t["label"].replace("Desk ", "D").replace(" tower", " PC")
        if t["routeWidth"] and t["routeWidth"] < ROUTE_MIN:
            txt += f"  {t['routeWidth']:.1f}w"
        place_label(cx, cz, txt, color=col)
    sp_txt = "SPAWN"
    place_label(P(sp[0], sp[2])[0], P(sp[0], sp[2])[1], sp_txt, color=(120, 220, 255))
    shown = 0
    for i in a.issues:
        if i["at"] is None or i["kind"] in ("unreachable",) or shown >= 24:
            continue
        cx, cz = P(i["at"][0], i["at"][2])
        col = {"critical": (255, 60, 60), "high": (255, 90, 90), "medium": (255, 190, 90), "low": (200, 200, 200)}[i["severity"]]
        d.ellipse([cx - 9, cz - 9, cx + 9, cz + 9], fill=col + (235,), outline=(20, 20, 20, 255), width=1)
        d.text((cx, cz), str(i["id"]), font=f_bold, fill=(10, 10, 10, 255), anchor="mm")
        placed.append((cx - 10, cz - 10, cx + 10, cz + 10))
        shown += 1
    paste(lyr)

    # keep the plan inside its frame (offset meshes and labels can spill out)
    frame = (margin_l, margin_t, margin_l + (x1 - x0) * scale, margin_t + (z1 - z0) * scale)
    outside = Image.new("L", (W, H), 255)
    ImageDraw.Draw(outside).rectangle(frame, fill=0)
    img.paste(Image.new("RGBA", (W, H), (22, 25, 28, 255)), (0, 0), outside)

    # frame, ticks, title, legend
    d = ImageDraw.Draw(img)
    for x in range(int(math.ceil(x0 / 5) * 5), int(x1) + 1, 5):
        px, _ = P(x, z0)
        d.line([(px, margin_t - 6), (px, margin_t)], fill=(150, 150, 150, 255))
        d.line([(px, margin_t), (px, margin_t + (z1 - z0) * scale)], fill=(255, 255, 255, 18))
        d.text((px, margin_t - 8), str(x), font=f_small, fill=(160, 160, 160, 255), anchor="mb")
    for z in range(int(math.ceil(z0 / 5) * 5), int(z1) + 1, 5):
        _, pz = P(x0, z)
        d.line([(margin_l - 6, pz), (margin_l, pz)], fill=(150, 150, 150, 255))
        d.line([(margin_l, pz), (margin_l + (x1 - x0) * scale, pz)], fill=(255, 255, 255, 18))
        d.text((margin_l - 9, pz), str(z), font=f_small, fill=(160, 160, 160, 255), anchor="rm")
    d.rectangle([margin_l, margin_t, margin_l + (x1 - x0) * scale, margin_t + (z1 - z0) * scale], outline=(110, 110, 110, 255))
    m = a.result["metrics"]
    d.text((margin_l, 14), f"NIGHT SHIFT layout audit: {a.label}", font=f_title, fill=(235, 235, 225, 255))
    d.text(
        (margin_l, 50),
        f"{m['desks']} desks | {m['artPropsVisible']} art props ({m['artPropsOffice']} in office) | mesh overlaps {m['propOverlapsMesh']} | "
        f"into walls/glass {m['intoWallsGlassCeiling']} | camera-clip props {m['cameraClipProps']} | targets reachable {m['targetsReachable']}/{m['targets']} | "
        f"routes < {ROUTE_MIN}: {m['routesUnder3_5']} (narrowest {m['narrowestRoute']} to {m['narrowestRouteTo']}) | chairs < {CHAIR_BACK_MIN}: {m['chairsUnder2_5']}",
        font=f_small,
        fill=(190, 190, 180, 255),
    )
    d.text((margin_l + (x1 - x0) * scale, margin_t + (z1 - z0) * scale + 8), "top-down, north (-Z) up, +X east; grid every 5 studs", font=f_small, fill=(140, 140, 140, 255), anchor="ra")

    lx = margin_l + (x1 - x0) * scale + 24
    ly = margin_t
    d.text((lx, ly), "Legend", font=f_big, fill=(235, 235, 225, 255))
    ly += 34

    def sw_rect(fill, outline, text):
        nonlocal ly
        d.rectangle([lx, ly, lx + 26, ly + 16], fill=fill, outline=outline)
        d.text((lx + 36, ly + 8), text, font=f_small, fill=(220, 220, 215, 255), anchor="lm")
        ly += 23

    def sw_dot(color, text, ring=None):
        nonlocal ly
        d.ellipse([lx + 6, ly + 1, lx + 20, ly + 15], fill=color, outline=ring or (10, 10, 10))
        d.text((lx + 36, ly + 8), text, font=f_small, fill=(220, 220, 215, 255), anchor="lm")
        ly += 23

    d.text((lx, ly), "Props (mesh silhouette)", font=f_bold, fill=(200, 200, 190, 255))
    ly += 22
    for cat in ("desk", "chair", "computer", "deskitem", "storage", "seating", "appliance", "divider", "wall", "outdoor"):
        col = CATEGORY_COLORS[cat]
        sw_rect(col + (150,), col, cat)
    ly += 6
    d.text((lx, ly), "Structure and collision", font=f_bold, fill=(200, 200, 190, 255))
    ly += 22
    sw_rect((52, 60, 66), (120, 130, 136), "wall / solid structure")
    sw_rect((140, 190, 220), (190, 225, 245), "glass")
    sw_rect((90, 40, 40), (200, 90, 90), "invisible limit")
    sw_rect((60, 30, 60), (235, 90, 235), "prop collision proxy (hatched)")
    sw_rect((240, 236, 214), (255, 255, 255), "interactive part")
    sw_rect((120, 180, 210), (200, 230, 255), "door (treated open) + swing")
    ly += 6
    d.text((lx, ly), "Walkability (radius 1.0)", font=f_bold, fill=(200, 200, 190, 255))
    ly += 22
    sw_rect((80, 110, 95), (170, 230, 190), "reachable from spawn")
    sw_rect((255, 140, 40), (255, 140, 40), "standable but unreachable")
    sw_rect((22, 25, 28), (120, 200, 255), "route to target (blue line)")
    sw_dot((255, 200, 60), f"bottleneck < {ROUTE_MIN} (circle = width)")
    ly += 6
    d.text((lx, ly), "Targets and issues", font=f_bold, fill=(200, 200, 190, 255))
    ly += 22
    sw_dot((90, 230, 120), "interactable reachable")
    sw_dot((255, 70, 60), "interactable NOT reachable")
    sw_rect((255, 40, 40), (255, 80, 80), "mesh-confirmed prop overlap")
    sw_rect((22, 25, 28), (255, 120, 255), "camera can clip (eye height)")
    sw_rect((22, 25, 28), (255, 255, 255), "chair: arrow = seat front")
    sw_dot((255, 190, 90), "numbered issue (see report)")
    ly += 6
    d.text((lx, ly), "Lights (dot size ~ range)", font=f_bold, fill=(200, 200, 190, 255))
    ly += 22
    for kind in ("amber", "neutral", "cold", "emergency", "status"):
        sw_dot(KIND_COLORS[kind], kind)
    ly += 10
    d.text((lx, ly), "Bounding boxes + sampled meshes,\nno physics. Not a Studio capture.", font=f_small, fill=(150, 150, 140, 255))
    img.convert("RGB").save(path, optimize=True)


# ---------------------------------------------------------------------------
# (g) Report
# ---------------------------------------------------------------------------


def md_table(headers, rows) -> str:
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join("---" for _ in headers) + "|"]
    for r in rows:
        out.append("| " + " | ".join(str(c).replace("|", "/") for c in r) + " |")
    return "\n".join(out)


METRIC_LABELS = [
    ("desks", "Desks (Layout.DESKS)"),
    ("artPropsVisible", "Art props placed (visible)"),
    ("artPropsIndoor", "Art props indoors"),
    ("artPropsOffice", "Art props in the main office"),
    ("avgItemsPerDesk", "Avg objects on a desk (incl. PC kit)"),
    ("avgPersonalItemsPerDesk", "Avg personal objects per desk"),
    ("weatheredIndoor", "Weathered / trash / hazard props indoors"),
    ("weatheredOutdoor", "Weathered / trash props outdoors"),
    ("dirtySurfaceFacesIndoor", "Dirty-named surface textures indoors (faces)"),
    ("wallTextureBlotchPct", "Worst painted-wall texture: % dark blotch pixels"),
    ("ceilingTextureBlotchPct", "Worst ceiling texture: % dark blotch pixels"),
    ("propOverlapsBox", "Prop-prop box overlaps (> 0.05, not resting)"),
    ("propOverlapsMesh", "...of which mesh surfaces meet"),
    ("maxPropOverlapMesh", "Deepest mesh-confirmed prop overlap"),
    ("intoWallsGlassCeiling", "Props into walls / glass / ceiling (> 0.1)"),
    ("intoTrim", "Props touching wall trim"),
    ("intoOtherCollision", "Props inside other furniture collision"),
    ("sunkBelowSupport", "Props sunk below floor / desk top"),
    ("cameraClipProps", f"Camera-clip props (eye-zone overhang > {OVERHANG_LIMIT})"),
    ("maxEyeOverhang", "Largest eye-zone overhang (99 = no collision)"),
    ("meshOffsetProps", "Props whose mesh renders far from its anchor"),
    ("scaleOutliers", "Art keys with implausible size (heuristic)"),
    ("targetsReachable", "Interactables reachable"),
    ("targets", "Interactables checked"),
    ("routesUnder3_5", f"Routes narrower than {ROUTE_MIN}"),
    ("narrowestRoute", "Narrowest route width"),
    ("narrowestRouteTo", "...to"),
    ("chairsUnder2_5", f"Chairs with < {CHAIR_BACK_MIN} free behind"),
    ("minFreeBehindChair", "Least free floor behind a chair"),
    ("chairsMisfacing", "Chairs not facing their desk (> 45 deg)"),
    ("reachableArea", "Walkable area reachable from spawn (sq studs)"),
    ("pocketArea", "Standable but unreachable area (sq studs)"),
    ("lights", "Lights"),
    ("amberLights", "Amber lights"),
    ("coldLights", "Cold lights"),
    ("collisionProxies", "Collision proxies"),
    ("issues", "Issues listed"),
]


def write_report(a: Audit, path: Path, png_name: str, baseline: dict | None):
    r = a.result
    m = r["metrics"]
    lines = [f"# Layout audit: {a.label}", ""]
    lines.append(f"Source: `{r.get('srcDisplay', r['src'])}`. Generated headlessly by `tools/audit/run.sh` from the real `MapBuilder.luau` (Lune) and the converted meshes. ")
    lines.append("This is an offline approximation (boxes + sampled meshes, no physics, prompts measured from a 3-stud root height); confirm in a Studio playtest.")
    lines.append("")
    lines.append(f"![plan]({png_name})")
    lines.append("")
    lines.append("## Metrics")
    lines.append("")
    if baseline:
        bm = baseline.get("metrics", {})
        rows = [[label, bm.get(k, "-"), m.get(k, "-")] for k, label in METRIC_LABELS]
        lines.append(md_table(["Metric", baseline.get("label", "baseline"), a.label], rows))
    else:
        lines.append(md_table(["Metric", a.label], [[label, m.get(k, "-")] for k, label in METRIC_LABELS]))
    lines.append("")
    lines.append("## Top issues")
    lines.append("")
    top = r["issues"][:30]
    if top:
        lines.append(md_table(["#", "Severity", "Kind", "Issue"], [[i["id"], i["severity"], i["kind"], i["text"]] for i in top]))
        if len(r["issues"]) > 30:
            lines.append("")
            lines.append(f"{len(r['issues']) - 30} more in `tools/audit/out/{a.label}.json`.")
    else:
        lines.append("No issues found.")
    lines.append("")
    lines.append("## Interactables and routes")
    lines.append("")
    lines.append(f"Reachable = some cell a character (radius {CHAR_RADIUS}) can reach from the spawn is within the prompt distance minus 1 stud (3D, root at y = {ROOT_Y}). Route width = widest route from the spawn (2 x clearance at its bottleneck). Doors treated open: {', '.join(r['walk']['doorsTreatedOpen']) or 'none'}.")
    lines.append("")
    rows = []
    for t in r["targets"]:
        rows.append([t["label"], xyz(t["pos"]) if t["pos"] else "zone", t["action"], fmt(t["distance"], 0), "yes" if t["reachable"] else "**NO**", fmt(t["closest"], 1), fmt(t["routeWidth"], 1) + ("" if t["routeWidth"] >= ROUTE_MIN else " (narrow)"), xz(t["bottleneck"]) if t["bottleneck"] else "-"])
    lines.append(md_table(["Target", "Position", "Prompt", "Reach", "Reachable", "Closest", "Route width", "Bottleneck"], rows))
    lines.append("")
    crowd = r.get("promptCrowding") or []
    if crowd:
        lines.append("Prompt parents closer than 2.5 studs (the custom prompt must pick one): " + "; ".join(f"{c['a']} / {c['b']} {c['distance']:.1f}" for c in crowd) + ".")
        lines.append("")
    lines.append("## Prop overlaps")
    lines.append("")
    lines.append(f"OBB separating-axis depth > {CONTACT_TOL}; items resting on a desk/cabinet top or stored in storage are excluded ({r['nestedOnSurfaces']} nested pairs, {len(r['shallowVertical'])} shallow vertical contacts up to {NEST_TOL + 0.05}). Mesh = sampled surfaces of both meshes share {MESH_CONTACT_MIN}+ voxels of {VOXEL} stud.")
    lines.append("")
    if a.overlaps:
        lines.append(md_table(["A", "B", "Depth", "Axis", "Mesh", "At"], [[o["a"], o["b"], fmt(o["depth"]), o["axis"], (f"yes ({o['meshVoxels']})" if o["mesh"] else f"no ({o['meshVoxels']})") + (" offset mesh" if o.get("offsetMesh") else ""), xyz(o["at"])] for o in a.overlaps[:40]]))
    else:
        lines.append("None.")
    lines.append("")
    lines.append("## Props into structure, fixtures and other collision")
    lines.append("")
    hits = [h for h in a.struct_hits if h["meshDepth"] > 0.02]
    if hits:
        lines.append(md_table(["Prop", "Into", "Kind", "Mesh depth", "Box depth", "Points", "At"], [[h["prop"], h["part"], h["kind"], fmt(h["meshDepth"]), fmt(h["boxDepth"]), h["meshPoints"], xyz(h["at"])] for h in hits[:50]]))
    else:
        lines.append("None.")
    lines.append("")
    if a.sunk:
        lines.append("Sunk below support (mesh lowest point under the surface the prop stands on):")
        lines.append("")
        lines.append(md_table(["Prop", "Support", "Below", "At"], [[s["prop"], s["support"], fmt(s["below"]), xyz(s["at"])] for s in a.sunk]))
        lines.append("")
    lines.append("## Camera clipping coverage")
    lines.append("")
    lines.append(f"Props taller than 1.2 studs (or wall-mounted) with mesh points at {COVER_BAND[0]}..{COVER_BAND[1]} studs within {EXPOSE_DIST} stud of floor a body can reach face-first. Overhang = horizontal distance from those points to the footprint of the nearest CanCollide part a walking body bumps into (0.4..5.5 studs). Eye zone {EYE_ZONE[0]}..{EYE_ZONE[1]} (camera ~4.5-5 plus near-plane slack): flag (**CLIP**) above {OVERHANG_LIMIT}; overhangs outside the eye zone are listed as low. 99 = no collision nearby.")
    lines.append("")
    if a.coverage_rows:
        lines.append(md_table(["Prop", "At", "Height", "Eye overhang", "Low overhang", "Own proxy", "Flag"], [[c["prop"], xyz(c["at"]), fmt(c["height"], 1), fmt(c["eyeOverhang"]), fmt(c["lowOverhang"]), "yes" if c["hasOwnProxy"] else "no", "**CLIP**" if c["flag"] else ""] for c in a.coverage_rows[:40]]))
    else:
        lines.append("No exposed tall props.")
    lines.append("")
    lines.append("## Chairs")
    lines.append("")
    lines.append("Facing = angle between the seat front (inferred from the backrest in the mesh) and the direction to the desk; 0 is correct, 180 is backwards.")
    lines.append("")
    lines.append(md_table(["Desk", "Chair", "At", f"Free behind (target {CHAIR_BACK_MIN})", "Facing error"], [[c["desk"], c["chair"], xz(c["at"]), (f"{c['freeBehind']:.1f}" if c["freeBehind"] < 8 else "8+") + ("" if c["ok"] else " **short**"), "-" if c.get("facingError") is None else (f"{c['facingError']:.0f} deg" + (" **wrong**" if c["facingError"] > 45 else ""))] for c in a.chair_rows]))
    lines.append("")
    sw = r.get("rearDoorSwing") or {}
    if sw:
        lines.append(f"Rear door swing: hinge {xz(sw['hinge'])}, width {fmt(sw['width'], 1)}, opens {sw['openAngle']} deg outward; obstructions: {', '.join(sw['blockers']) or 'none'}.")
        lines.append("")
    if r.get("scaleSanity"):
        lines.append("## Scale sanity (heuristic)")
        lines.append("")
        lines.append(md_table(["Prop", "Size", "Plausible", "ArtScale", "Suggested", "At"], [[x["prop"], f"{x['value']:.1f} {x['dim']}", f"{x['expected'][0]}-{x['expected'][1]}", fmt(x["scale"], 2), fmt(x["suggestScale"], 2), xz(x["at"])] for x in r["scaleSanity"]]))
        lines.append("")
    if r.get("originOffsets"):
        lines.append("## Meshes far from their anchors")
        lines.append("")
        lines.append("The converted model's own origin is far from its geometry, so the client draws it somewhere else (ArtController uses the vertices as-is).")
        lines.append("")
        lines.append(md_table(["Prop", "Anchor", "Mesh renders near", "Offset"], [[x["prop"], xyz(x["anchor"]), xyz(x["meshCenter"]) + " (" + region_of(a.layout, x["meshCenter"][0], x["meshCenter"][2]) + ")", fmt(x["offset"], 1)] for x in r["originOffsets"]]))
        lines.append("")
    lines.append("## Clutter")
    lines.append("")
    regions = r["propsByRegion"]
    cats = sorted({c for v in regions.values() for c in v if c != "total"})
    lines.append(md_table(["Area", "Total"] + cats, [[k, v["total"]] + [v.get(c, 0) for c in cats] for k, v in regions.items()]))
    lines.append("")
    lines.append(md_table(["Desk", "Model", "Objects on top", "PC kit", "Personal", "Personal items"], [[d["desk"], short(d["art"]), d["items"], d["computerKit"], d["personal"], ", ".join(d["personalItems"]) or "-"] for d in r["desks"]]))
    lines.append("")
    if r["weathered"]:
        lines.append("Weathered / trash / hazard keys placed:")
        lines.append("")
        lines.append(md_table(["Prop", "Area", "Indoor", "At"], [[w["prop"], w["region"], "yes" if w["indoor"] else "no", xz(w["at"])] for w in r["weathered"]]))
        lines.append("")
    if r["dirtySurfacesIndoor"]:
        lines.append(f"Dirty surface textures indoors: {r['dirtySurfacesIndoor']}")
        lines.append("")
    if r.get("surfaceTextures"):
        lines.append("Surface textures used indoors (blotch = pixels darker than 70% of the median luminance; walls should read as clean, light paint, about 205-226 albedo):")
        lines.append("")
        lines.append(md_table(["Surface", "Used on", "Mean RGB", "Median lum", "Blotch %", "Lum std", "Same image as"], [[x["surface"], ", ".join(f"{k} x{v}" for k, v in x["usedOn"].items()), str(tuple(x["mean"])), x["medianLum"], fmt(x["blotchPct"]), x["lumStd"], x["sameImageAs"] or "-"] for x in r["surfaceTextures"]]))
        lines.append("")
    lines.append("## Lights")
    lines.append("")
    lr = r["lights"]["byRegion"]
    kinds = ["amber", "neutral", "cold", "emergency", "status"]
    lines.append(md_table(["Area"] + kinds, [[k] + [v.get(x, 0) for x in kinds] for k, v in lr.items()]))
    lines.append("")
    lines.append("## Prompts declared in server code")
    lines.append("")
    lines.append(md_table(["File", "Parent", "Action", "Key", "Hold", "Distance"], [[p["file"] + ":" + str(p["line"]), p["arg"], p["action"], p["key"], p["hold"], fmt(p["distance"], 0)] for p in r["prompts"]]))
    lines.append("")
    if r["harnessWarnings"]:
        lines.append("## Harness warnings")
        lines.append("")
        for w in r["harnessWarnings"]:
            lines.append(f"- {w}")
        lines.append("")
    lines.append(f"_Analysis took {r['seconds']} s._")
    path.write_text("\n".join(lines) + "\n")


def jsonable(o):
    if isinstance(o, dict):
        return {k: jsonable(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [jsonable(v) for v in o]
    if isinstance(o, (np.floating,)):
        return float(o)
    if isinstance(o, (np.integer,)):
        return int(o)
    if isinstance(o, np.ndarray):
        return o.tolist()
    if isinstance(o, float) and (math.isinf(o) or math.isnan(o)):
        return None
    return o


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dump", required=True)
    ap.add_argument("--src", required=True, help="source dir that holds art/ and server/")
    ap.add_argument("--label", required=True)
    ap.add_argument("--out-json", required=True)
    ap.add_argument("--png", required=True)
    ap.add_argument("--md", required=True)
    ap.add_argument("--baseline", help="JSON from an earlier audit to compare against")
    ap.add_argument("--src-display", help="source label shown in the report")
    args = ap.parse_args()

    dump = json.loads(Path(args.dump).read_text())
    src = Path(args.src)
    if (src / "src" / "server").is_dir():
        src = src / "src"
    audit = Audit(dump, src, args.label)
    audit.result["srcDisplay"] = args.src_display or str(src)
    audit.run()
    render_plan(audit, Path(args.png))
    baseline = None
    if args.baseline and Path(args.baseline).is_file() and Path(args.baseline).resolve() != Path(args.out_json).resolve():
        baseline = json.loads(Path(args.baseline).read_text())
    write_report(audit, Path(args.md), Path(args.png).name, baseline)
    Path(args.out_json).write_text(json.dumps(jsonable(audit.result), indent=1))
    m = audit.result["metrics"]
    print(
        f"[audit] {args.label}: {m['desks']} desks, {m['artPropsVisible']} props, mesh overlaps {m['propOverlapsMesh']}, into walls {m['intoWallsGlassCeiling']}, "
        f"camera-clip {m['cameraClipProps']}, reachable {m['targetsReachable']}/{m['targets']}, routes<{ROUTE_MIN} {m['routesUnder3_5']}, chairs<{CHAIR_BACK_MIN} {m['chairsUnder2_5']}, issues {m['issues']}"
    )
    for i in audit.result["issues"][:12]:
        print(f"  #{i['id']} [{i['severity']}] {i['text']}")


if __name__ == "__main__":
    main()
