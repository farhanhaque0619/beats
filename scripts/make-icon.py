import sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024
out = sys.argv[1]

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))

# Big Sur style: 824pt squircle body centred on a 1024 canvas, with a soft shadow.
body = 824
off = (S - body) // 2
radius = int(body * 0.2237)

bg = Image.new("RGBA", (body, body))
top, bottom = (44, 46, 64), (12, 12, 20)
px = bg.load()
for y in range(body):
    c = lerp(top, bottom, y / body)
    for x in range(body):
        px[x, y] = c + (255,)

mask = Image.new("L", (body, body), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, body - 1, body - 1], radius=radius, fill=255)

# EQ bars, tall in the bass and tapering off: the app's whole idea in one glance.
bars = Image.new("RGBA", (body, body), (0, 0, 0, 0))
heights = [0.70, 0.78, 0.62, 0.44, 0.32, 0.30, 0.36]
n = len(heights)
margin = 128
gap = 26
bw = (body - 2 * margin - gap * (n - 1)) / n
base = body - 170
pink, orange = (255, 55, 95), (255, 159, 10)
for i, h in enumerate(heights):
    x0 = margin + i * (bw + gap)
    y0 = base - h * (base - 140)
    grad = Image.new("RGBA", (int(bw), int(base - y0)))
    gp = grad.load()
    for yy in range(grad.size[1]):
        c = lerp(orange, pink, yy / max(grad.size[1] - 1, 1))
        for xx in range(grad.size[0]):
            gp[xx, yy] = c + (255,)
    m = Image.new("L", grad.size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, grad.size[0] - 1, grad.size[1] - 1], radius=int(bw / 2), fill=255)
    bars.paste(grad, (int(x0), int(y0)), m)

glow = bars.filter(ImageFilter.GaussianBlur(28))
bg = Image.alpha_composite(bg, Image.eval(glow, lambda v: v) )
bg = Image.alpha_composite(bg, bars)

# Subtle top highlight
hl = Image.new("RGBA", (body, body), (255, 255, 255, 0))
hp = hl.load()
for y in range(body // 2):
    a = int(22 * (1 - y / (body / 2)) ** 2)
    for x in range(body):
        hp[x, y] = (255, 255, 255, a)
bg = Image.alpha_composite(bg, hl)

canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle([off, off + 12, off + body, off + body + 12], radius=radius, fill=(0, 0, 0, 110))
shadow = shadow.filter(ImageFilter.GaussianBlur(18))
canvas = Image.alpha_composite(canvas, shadow)
canvas.paste(bg, (off, off), mask)
canvas.save(out)
