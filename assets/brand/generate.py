"""Rebuild the packaged Pegelbot artwork with Python 3 and rsvg-convert (librsvg)."""

from pathlib import Path
import shutil
import struct
import subprocess


BRAND = Path(__file__).resolve().parent
PLATFORMS = BRAND.parents[1] / "platforms"
CATALOG = PLATFORMS / "macos/VibeMeasureMac/Sources/VibeMeasureMac/Assets.xcassets"
WINDOWS = PLATFORMS / "windows/VibeMeasure.Windows/Assets"
GNOME = PLATFORMS / "linux/gnome/vibemeasure@chardonnay.example"
PLASMA = PLATFORMS / "linux/kde/org.vibemeasure.plasmoid/contents/images"


def render(size):
    return subprocess.check_output([
        "rsvg-convert", "-w", str(size), "-h", str(size), str(BRAND / "pegelbot.svg")
    ])


def write_ico(path, frames):
    # The ICO directory precedes the PNG frames; dimension 256 is encoded as zero.
    offset = 6 + 16 * len(frames)
    directory = bytearray(struct.pack("<HHH", 0, 1, len(frames)))
    for size, png in frames.items():
        dimension = size % 256
        directory.extend(struct.pack("<BBBBHHII", dimension, dimension, 0, 0, 1, 32, len(png), offset))
        offset += len(png)
    path.write_bytes(directory + b"".join(frames.values()))


def main():
    WINDOWS.mkdir(parents=True, exist_ok=True)
    PLASMA.mkdir(parents=True, exist_ok=True)
    mac_sizes = (16, 32, 64, 128, 256, 512, 1024)
    windows_sizes = (16, 20, 24, 32, 40, 48, 64, 128, 256)
    rasters = {size: render(size) for size in sorted(set(mac_sizes + windows_sizes))}
    for size in mac_sizes:
        (CATALOG / "AppIcon.appiconset" / f"pegelbot-{size}.png").write_bytes(rasters[size])
    write_ico(WINDOWS / "pegelbot.ico", {size: rasters[size] for size in windows_sizes})
    (WINDOWS / "pegelbot.png").write_bytes(rasters[128])
    for destination in (GNOME, PLASMA, CATALOG / "StatusIcon.imageset"):
        shutil.copyfile(BRAND / "pegelbot-symbolic.svg", destination / "pegelbot-symbolic.svg")
    shutil.copyfile(BRAND / "pegelbot.svg", PLASMA / "pegelbot.svg")


if __name__ == "__main__":
    main()
