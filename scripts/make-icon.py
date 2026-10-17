"""Renders Resources/AppIcon.png: a graphite tile with a performance gauge."""
import math
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024
SCALE = 2  # supersample for smooth edges
out = sys.argv[1]
W = S * SCALE


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


body = 824 * SCALE
off = (W - body) // 2
radius = int(body * 0.2237)

# Graphite body with a soft vertical gradient.
bg = Image.new("RGBA", (body, body))
top, bottom = (66, 69, 77), (22, 23, 27)
grad = Image.linear_gradient("L").resize((body, body))
bg = Image.composite(Image.new("RGBA", (body, body), bottom + (255,)), Image.new("RGBA", (body, body), top + (255,)), grad)
mask = Image.new("L", (body, body), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, body - 1, body - 1], radius=radius, fill=255)

layer = Image.new("RGBA", (body, body), (0, 0, 0, 0))
d = ImageDraw.Draw(layer)
cx, cy = body / 2, body * 0.56
r = body * 0.33
width = int(body * 0.055)
start, sweep = 135, 270

# Track
d.arc([cx - r, cy - r, cx + r, cy + r], start, start + sweep, fill=(255, 255, 255, 38), width=width)
# Filled portion, light grey to white
filled = 0.72
steps = 160
for i in range(steps):
    t0 = i / steps * filled
    t1 = (i + 1.6) / steps * filled
    colour = lerp((150, 156, 168), (246, 247, 250), i / steps)
    d.arc([cx - r, cy - r, cx + r, cy + r], start + sweep * t0, start + sweep * t1, fill=colour + (255,), width=width)

# Tick marks
for i in range(11):
    angle = math.radians(start + sweep * i / 10)
    inner, outer = r - width * 1.45, r - width * (1.05 if i % 5 else 0.75)
    d.line([(cx + inner * math.cos(angle), cy + inner * math.sin(angle)),
            (cx + outer * math.cos(angle), cy + outer * math.sin(angle))],
           fill=(255, 255, 255, 120 if i % 5 else 190), width=int(body * 0.012))

# Needle with a soft blue tip
angle = math.radians(start + sweep * filled)
length = r - width * 1.9
tip = (cx + length * math.cos(angle), cy + length * math.sin(angle))
perp = angle + math.pi / 2
base_w = body * 0.028
p1 = (cx + base_w * math.cos(perp), cy + base_w * math.sin(perp))
p2 = (cx - base_w * math.cos(perp), cy - base_w * math.sin(perp))
d.polygon([p1, tip, p2], fill=(240, 242, 246, 255))
hub = body * 0.055
d.ellipse([cx - hub, cy - hub, cx + hub, cy + hub], fill=(240, 242, 246, 255))
d.ellipse([cx - hub * 0.45, cy - hub * 0.45, cx + hub * 0.45, cy + hub * 0.45], fill=(122, 166, 236, 255))

glow = layer.filter(ImageFilter.GaussianBlur(body * 0.02))
glow = Image.eval(glow, lambda v: int(v * 0.5))
bg = Image.alpha_composite(bg, glow)
bg = Image.alpha_composite(bg, layer)

# Top sheen
sheen = Image.new("RGBA", (body, body), (255, 255, 255, 0))
sp = ImageDraw.Draw(sheen)
for y in range(body // 2):
    a = int(26 * (1 - y / (body / 2)) ** 2)
    sp.line([(0, y), (body, y)], fill=(255, 255, 255, a))
bg = Image.alpha_composite(bg, sheen)

canvas = Image.new("RGBA", (W, W), (0, 0, 0, 0))
shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle([off, off + 12 * SCALE, off + body, off + body + 12 * SCALE], radius=radius, fill=(0, 0, 0, 110))
shadow = shadow.filter(ImageFilter.GaussianBlur(18 * SCALE))
canvas = Image.alpha_composite(canvas, shadow)
canvas.paste(bg, (off, off), mask)
canvas = canvas.resize((S, S), Image.LANCZOS)
canvas.save(out)
