"""
Builds upload-ready audio for NIGHT SHIFT: DATA PURGE into night-shift/audio-upload/.

Roblox only plays audio that has been uploaded as an asset, so this script
prepares files you can bulk-import (Studio: Asset Manager > Bulk Import, or
Creator Dashboard). Paste the resulting rbxassetid:// values into
src/shared/Config.luau -> Config.SOUNDS.

  * ambient loops: 90 s mono 16-bit excerpts of three PSX Ambient Pack tracks
  * original procedural effects (rain, fan hum, chime, breaker, knock,
    footsteps, phone, error, click, door slam) generated here from scratch

Usage (from the night-shift folder):  python tools/make_audio.py --library ..
Only the Python standard library is used.
"""

import argparse
import math
import random
import struct
import wave
from pathlib import Path

RATE = 22050
OUT = Path(__file__).resolve().parent.parent / "audio-upload"

AMBIENT = {
    # Config.SOUNDS key : (track name, start second)
    "ambientRoom": ("Still", 30),
    "ambientTense": ("Distant", 60),
    "ambientFinale": ("Hollow", 45),
}
AMBIENT_SECONDS = 90


def write(name: str, samples: list[float], rate: int = RATE):
    OUT.mkdir(exist_ok=True)
    peak = max(1e-6, max(abs(s) for s in samples))
    gain = 0.89 / peak
    data = b"".join(struct.pack("<h", int(max(-1, min(1, s * gain)) * 32767)) for s in samples)
    with wave.open(str(OUT / f"{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(data)
    print(f"  {name}.wav  {len(samples) / rate:.1f}s")


def env(i: int, n: int, attack: float = 0.005, release: float = 0.2) -> float:
    t = i / RATE
    total = n / RATE
    a = min(1.0, t / attack) if attack > 0 else 1.0
    r = min(1.0, (total - t) / release) if release > 0 else 1.0
    return max(0.0, min(a, r))


def lowpass(x: list[float], alpha: float) -> list[float]:
    out, y = [], 0.0
    for s in x:
        y += alpha * (s - y)
        out.append(y)
    return out


def rain(seconds: float = 30.0) -> list[float]:
    rnd = random.Random(7)
    n = int(seconds * RATE)
    noise = [rnd.uniform(-1, 1) for _ in range(n)]
    hiss = lowpass(noise, 0.35)
    body = lowpass(noise, 0.05)
    out = [0.35 * h + 0.6 * b for h, b in zip(hiss, body)]
    # droplets on glass / gutter
    for _ in range(int(seconds * 22)):
        pos = rnd.randrange(0, n - 800)
        amp = rnd.uniform(0.15, 0.5)
        freq = rnd.uniform(1800, 4200)
        for k in range(600):
            out[pos + k] += amp * math.exp(-k / 90) * math.sin(2 * math.pi * freq * k / RATE)
    # seamless loop: crossfade the ends
    fade = RATE
    for k in range(fade):
        a = k / fade
        out[k] = out[k] * a + out[n - fade + k] * (1 - a)
    return out[: n - fade]


def fan_hum(seconds: float = 20.0) -> list[float]:
    rnd = random.Random(3)
    n = int(seconds * RATE)
    noise = lowpass([rnd.uniform(-1, 1) for _ in range(n)], 0.02)
    out = []
    for i in range(n):
        t = i / RATE
        h = 0.5 * math.sin(2 * math.pi * 60 * t) + 0.25 * math.sin(2 * math.pi * 120 * t) + 0.1 * math.sin(2 * math.pi * 180 * t)
        wobble = 1 + 0.05 * math.sin(2 * math.pi * 0.3 * t)
        out.append(0.4 * h * wobble + 1.2 * noise[i])
    return out


def tone(freqs: list[float], seconds: float, decay: float, attack: float = 0.004) -> list[float]:
    n = int(seconds * RATE)
    out = []
    for i in range(n):
        t = i / RATE
        s = sum(math.sin(2 * math.pi * f * t) / (k + 1) for k, f in enumerate(freqs))
        out.append(s * math.exp(-t / decay) * min(1, t / attack))
    return out


def chime() -> list[float]:
    a = tone([880, 1760, 2640], 0.6, 0.25)
    b = tone([659, 1318, 1977], 0.9, 0.35)
    gap = [0.0] * int(0.18 * RATE)
    return a[: len(gap)] + [x + y for x, y in zip(a[len(gap):] + [0.0] * len(b), b)]


def thump(freq: float, seconds: float, noise_amt: float, seed: int) -> list[float]:
    rnd = random.Random(seed)
    n = int(seconds * RATE)
    noise = lowpass([rnd.uniform(-1, 1) for _ in range(n)], 0.15)
    out = []
    for i in range(n):
        t = i / RATE
        f = freq * (1 + 1.5 * math.exp(-t / 0.02))
        out.append((math.sin(2 * math.pi * f * t) + noise_amt * noise[i]) * math.exp(-t / 0.07))
    return out


def breaker() -> list[float]:
    clack = thump(140, 0.35, 1.4, 11)
    tail = [0.25 * s for s in thump(60, 0.6, 0.6, 12)]
    return [a + (tail[i] if i < len(tail) else 0) for i, a in enumerate(clack + [0.0] * (len(tail) - len(clack)))]


def knock() -> list[float]:
    return thump(110, 0.3, 0.9, 21)


def footsteps(steps: int = 6) -> list[float]:
    out: list[float] = []
    rnd = random.Random(5)
    for k in range(steps):
        out += [0.9 * s for s in thump(rnd.uniform(70, 95), 0.18, 1.6, 30 + k)]
        out += [0.0] * int(rnd.uniform(0.38, 0.46) * RATE)
    return out


def phone() -> list[float]:
    n = int(1.2 * RATE)
    out = []
    for i in range(n):
        t = i / RATE
        trill = 1 if math.sin(2 * math.pi * 20 * t) > 0 else 0.25
        out.append(trill * (math.sin(2 * math.pi * 440 * t) + 0.6 * math.sin(2 * math.pi * 480 * t)) * env(i, n, 0.01, 0.05))
    return out


def error_beep() -> list[float]:
    return [s * 0.8 for s in tone([220, 440], 0.35, 0.3)]


def click() -> list[float]:
    return thump(1800, 0.05, 0.5, 41)


def door_slam() -> list[float]:
    body = thump(55, 0.9, 1.2, 51)
    rattle = [0.2 * s for s in thump(400, 0.4, 2.0, 52)]
    return [a + (rattle[i] if i < len(rattle) else 0) for i, a in enumerate(body)]


def ambient_excerpt(lib: Path, track: str, start: float) -> tuple[list[float], int]:
    src = lib / "additional-packs" / "psx_ambient_pack" / "source" / "PSX Ambient Pack" / "Tracks" / f"{track}.wav"
    with wave.open(str(src), "rb") as w:
        ch, width, rate = w.getnchannels(), w.getsampwidth(), w.getframerate()
        w.setpos(int(start * rate))
        frames = w.readframes(int(AMBIENT_SECONDS * rate))
    step = width * ch
    out = []
    # mono downmix + 2:1 decimation to 22.05 kHz (keeps the file well under upload limits)
    for i in range(0, len(frames) - step * 2 + 1, step * 2):
        acc = 0.0
        for c in range(ch):
            b = frames[i + c * width : i + (c + 1) * width]
            if width == 3:
                v = int.from_bytes(b, "little", signed=True) / 8388608
            else:
                v = int.from_bytes(b, "little", signed=True) / 32768
            acc += v
        out.append(acc / ch)
    n = len(out)
    fade = rate // 2
    for k in range(fade):  # loop-friendly ends
        out[k] *= k / fade
        out[n - 1 - k] *= k / fade
    return out, rate // 2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--library", default="..", help="path to NightShiftAssets")
    args = ap.parse_args()
    lib = Path(args.library).resolve()
    print("writing to", OUT)
    for key, (track, start) in AMBIENT.items():
        samples, rate = ambient_excerpt(lib, track, start)
        write(key, samples, rate)
    write("rain", rain())
    write("fanHum", fan_hum())
    write("chime", chime())
    write("breaker", breaker())
    write("knock", knock())
    write("footsteps", footsteps())
    write("phone", phone())
    write("error", error_beep())
    write("click", click())
    write("doorSlam", door_slam())
    print("Upload these, then paste the IDs into Config.SOUNDS (keys match the file names).")


if __name__ == "__main__":
    main()
