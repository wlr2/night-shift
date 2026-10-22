"""Decode the converted art library (src/art) exactly as the client does.

src/art/Models/<key>.luau holds base64 buffers per part, written by
tools/convert_assets.py and read by src/client/Controllers/ArtController.luau:

  v   int16 x3 per vertex, quantised to the part box: center + q/32767 * size/2
  n   int8  x3 per vertex (normal * 127)
  uv  uint16 x2 per vertex (atlas UV / 65535)
  i   uint16 x3 per triangle (0-based)

Atlas_<n>.luau / surf_<name>.luau are RGB565 images (base64, little endian).
Coordinates are model-local studs with +Z as the model front; the client
places them with the anchor CFrame and the uniform ArtScale.
"""

from __future__ import annotations

import base64
import math
import re
from functools import cache
from pathlib import Path

import numpy as np

PART_RE = re.compile(
    r"nv\s*=\s*(\d+),\s*nt\s*=\s*(\d+),\s*color\s*=\s*\{([^}]*)\},\s*center\s*=\s*\{([^}]*)\},\s*"
    r"size\s*=\s*\{([^}]*)\},\s*v\s*=\s*\"([^\"]*)\",\s*n\s*=\s*\"([^\"]*)\",\s*uv\s*=\s*\"([^\"]*)\",\s*"
    r"i\s*=\s*\"([^\"]*)\""
)
IMAGE_RE = re.compile(r"w\s*=\s*(\d+),\s*h\s*=\s*(\d+),\s*format\s*=\s*\"565\",\s*data\s*=\s*\"([^\"]*)\"")


def _nums(s: str) -> list[float]:
    return [float(x) for x in s.replace(" ", "").split(",") if x]


class Mesh:
    """One model in local (unscaled) coordinates."""

    def __init__(self, key: str, verts, normals, uvs, tris, colors):
        self.key = key
        self.verts = verts  # (N,3) float64
        self.normals = normals  # (N,3)
        self.uvs = uvs  # (N,2)
        self.tris = tris  # (M,3) int
        self.colors = colors  # (M,3) per-triangle part colour multiplier
        self._samples: dict[float, np.ndarray] = {}

    @property
    def min(self):
        return self.verts.min(axis=0)

    @property
    def max(self):
        return self.verts.max(axis=0)

    def samples(self, spacing: float = 0.08) -> np.ndarray:
        """Points spread over every triangle (local coords), at most `spacing` apart."""
        cached = self._samples.get(spacing)
        if cached is not None:
            return cached
        v = self.verts
        a, b, c = v[self.tris[:, 0]], v[self.tris[:, 1]], v[self.tris[:, 2]]
        longest = np.maximum(np.linalg.norm(b - a, axis=1), np.maximum(np.linalg.norm(c - b, axis=1), np.linalg.norm(a - c, axis=1)))
        steps = np.clip(np.ceil(longest / spacing), 1, 160).astype(int)
        out = [v]
        for n in np.unique(steps):
            idx = np.nonzero(steps == n)[0]
            ii, jj = np.meshgrid(np.arange(n + 1), np.arange(n + 1), indexing="ij")
            keep = (ii + jj) <= n
            u = (ii[keep] / n)[None, :, None]
            w = (jj[keep] / n)[None, :, None]
            pa, pb, pc = a[idx][:, None, :], b[idx][:, None, :], c[idx][:, None, :]
            pts = pa + (pb - pa) * u + (pc - pa) * w
            out.append(pts.reshape(-1, 3))
        pts = np.unique(np.round(np.concatenate(out), 3), axis=0)
        self._samples[spacing] = pts
        return pts


@cache
def load_mesh(art_dir: str, key: str) -> Mesh | None:
    path = Path(art_dir) / "Models" / f"{key}.luau"
    if not path.is_file():
        return None
    text = path.read_text()
    verts, normals, uvs, tris, colors = [], [], [], [], []
    base = 0
    for m in PART_RE.finditer(text):
        nv, nt = int(m.group(1)), int(m.group(2))
        color = _nums(m.group(3))
        center = np.array(_nums(m.group(4)))
        half = np.array(_nums(m.group(5))) / 2
        vb = np.frombuffer(base64.b64decode(m.group(6)), dtype="<i2").reshape(-1, 3)[:nv]
        nb = np.frombuffer(base64.b64decode(m.group(7)), dtype="<i1").reshape(-1, 3)[:nv]
        ub = np.frombuffer(base64.b64decode(m.group(8)), dtype="<u2").reshape(-1, 2)[:nv]
        ib = np.frombuffer(base64.b64decode(m.group(9)), dtype="<u2").reshape(-1, 3)[:nt]
        verts.append(center + vb.astype(np.float64) / 32767.0 * half)
        normals.append(nb.astype(np.float64) / 127.0)
        uvs.append(ub.astype(np.float64) / 65535.0)
        tris.append(ib.astype(np.int64) + base)
        colors.append(np.tile(np.array(color[:3] or [1, 1, 1], dtype=np.float64), (nt, 1)))
        base += nv
    if not verts:
        return None
    return Mesh(key, np.concatenate(verts), np.concatenate(normals), np.concatenate(uvs), np.concatenate(tris), np.concatenate(colors))


def decode_565(text: str) -> np.ndarray | None:
    """RGB565 image module -> (h, w, 3) uint8."""
    m = IMAGE_RE.search(text)
    if not m:
        return None
    w, h = int(m.group(1)), int(m.group(2))
    raw = np.frombuffer(base64.b64decode(m.group(3)), dtype="<u2")[: w * h].reshape(h, w)
    r = (raw >> 11) * 255 // 31
    g = ((raw >> 5) & 63) * 255 // 63
    b = (raw & 31) * 255 // 31
    return np.stack([r, g, b], axis=-1).astype(np.uint8)


@cache
def load_atlas(art_dir: str, width: int, strip: int, strips: int) -> np.ndarray:
    img = np.full((strip * strips, width, 3), 255, dtype=np.uint8)
    for i in range(strips):
        path = Path(art_dir) / "Textures" / f"Atlas_{i}.luau"
        if path.is_file():
            data = decode_565(path.read_text())
            if data is not None:
                img[i * strip : i * strip + data.shape[0], : data.shape[1]] = data
    return img


@cache
def load_surface(art_dir: str, name: str) -> np.ndarray | None:
    path = Path(art_dir) / "Textures" / f"{name}.luau"
    if not path.is_file():
        return None
    return decode_565(path.read_text())


def transform(points: np.ndarray, pos, rot, scale: float = 1.0) -> np.ndarray:
    """Local model points -> world (rot is a 3x3 matrix whose columns are the local axes)."""
    return np.asarray(pos)[None, :] + (points * scale) @ np.asarray(rot).T


def finite(x: float) -> bool:
    return x is not None and not math.isnan(x) and not math.isinf(x)
