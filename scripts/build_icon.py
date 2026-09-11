"""Rasterize the editable SVG into PNG and a complete modern macOS ICNS.
Development-only dependency: CairoSVG. Runtime and release builds use the
committed assets and do not download or regenerate artwork.
"""
from pathlib import Path
import struct
import cairosvg

root = Path(__file__).resolve().parents[1] / 'Resources'
source = (root / 'AppIcon.svg').read_bytes()
sizes = {b'icp4': 16, b'icp5': 32, b'icp6': 64, b'ic07': 128,
         b'ic08': 256, b'ic09': 512, b'ic10': 1024,
         b'ic11': 32, b'ic12': 64, b'ic13': 256, b'ic14': 512}
images = {size: cairosvg.svg2png(bytestring=source, output_width=size,
                              output_height=size) for size in set(sizes.values())}
chunks = b''.join(kind + struct.pack('>I', len(images[size]) + 8) + images[size]
                  for kind, size in sizes.items())
(root / 'AppIcon.icns').write_bytes(b'icns' + struct.pack('>I', len(chunks) + 8) + chunks)
(root / 'AppIcon.png').write_bytes(images[1024])
