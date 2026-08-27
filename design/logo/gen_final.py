#!/usr/bin/env python3
"""Cove logo final assets (D1 'stacked waves' direction).

Emits into ~/cove-logo/final/:
  icon-master.svg    full-bleed 1024 square (the OS applies the squircle mask)
  glyph.svg          waves only, transparent background, trimmed canvas
  lockup.svg         glyph + Cove wordmark, horizontal, transparent
PNG rendering happens separately via qlmanage.
"""

K = 0.3642  # half-period sine ≈ cubic with this handle ratio

def sine_path(x0, x1, y, amp, periods):
    n = int(periods * 2)
    seg = (x1 - x0) / n
    d = [f"M {x0:.1f} {y:.1f}"]
    for i in range(n):
        direction = 1 if i % 2 == 0 else -1
        y_peak = y + direction * amp
        xa, xb = x0 + i * seg, x0 + (i + 1) * seg
        d.append(f"C {xa + seg * K:.1f} {y_peak:.1f} {xb - seg * K:.1f} {y_peak:.1f} {xb:.1f} {y:.1f}")
    return " ".join(d)

# (y, half_width, amplitude, stroke_width, color, opacity) on the 1024 canvas.
# Content bounds incl. stroke: x 184..840, y 352..748.
ROWS = [
    (668, 300, 52, 56, "#2F7FC4", 0.55),
    (532, 232, 44, 48, "#4FB4DE", 0.8),
    (408, 164, 36, 40, "#8FE3F5", 1.0),
]

def waves_paths():
    out = []
    for y, hw, amp, sw, color, op in ROWS:
        out.append(
            f'<path d="{sine_path(512 - hw, 512 + hw, y, amp, 2.0)}" fill="none" '
            f'stroke="{color}" stroke-width="{sw}" stroke-linecap="round" opacity="{op}"/>')
    return "".join(out)

HEAD = '<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">'

# 1) App icon master: full-bleed square, gradient edge to edge.
icon = (HEAD.format(w=1024, h=1024)
        + '<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
          '<stop offset="0" stop-color="#0D2B4E"/>'
          '<stop offset="1" stop-color="#081A30"/></linearGradient></defs>'
          '<rect width="1024" height="1024" fill="url(#bg)"/>'
        + "<g>" + waves_paths() + "</g>"
        + '</svg>')

# 2) Glyph only, transparent, trimmed: content center (512, 550) onto a
#    760x500 canvas (pad ~60 around the 656x396 content box).
glyph = (HEAD.format(w=760, h=500)
         + f'<g transform="translate(-132,-300)">{waves_paths()}</g>'
         + '</svg>')

# 3) Horizontal lockup: 512px glyph block (scale 0.5 of master canvas, waves
#    center lands at y=275, near the 256 canvas center) + wordmark.
lockup = (HEAD.format(w=1420, h=512)
          + f'<g transform="scale(0.5)">{waves_paths()}</g>'
          + '<text x="560" y="345" font-family="-apple-system, Helvetica Neue, Arial, sans-serif" '
            'font-size="290" font-weight="600" letter-spacing="4" fill="#EAF3FA">Cove</text>'
          + '</svg>')

import os
os.makedirs("/Users/boyang/cove-logo/final", exist_ok=True)
for name, svg in [("icon-master", icon), ("glyph", glyph), ("lockup", lockup)]:
    with open(f"/Users/boyang/cove-logo/final/{name}.svg", "w") as f:
        f.write(svg)
print("masters written")
