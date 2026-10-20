"""Renders Ink's app icons into the asset catalog.

The mark is a lowercase "i": a white stem whose dot is the unread dot, in Ink's electric blue,
on true black. iOS gets a full-bleed square (the system rounds the corners); macOS gets the
rounded tile with margin and shadow that Big Sur-style icons use, at every size.

    python3 scripts/make-icon.py
"""
import json
import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
ASSETS = os.path.join(ROOT, "App", "Resources", "Assets.xcassets")
SS = 4  # supersampling factor

BLUE = (77, 132, 255)
BLUE_HOT = (140, 178, 255)
WHITE = (246, 246, 248)


def glyph(size):
    """The "i" mark on a black square of `size` px (supersampled), RGBA."""
    s = size
    img = Image.new("RGBA", (s, s), (0, 0, 0, 255))

    # Barely-there vertical falloff so the black has depth on a lit screen.
    shade = Image.linear_gradient("L").resize((s, s))
    top = Image.new("RGBA", (s, s), (20, 20, 23, 255))
    img = Image.composite(img, top, shade)

    stem_w = s * 0.155
    stem_h = s * 0.40
    cx = s * 0.5
    stem_top = s * 0.425
    radius = stem_w / 2
    dot_r = s * 0.098
    dot_cy = s * 0.275

    # Soft blue glow around the dot, behind everything else.
    glow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gr = dot_r * 1.9
    gd.ellipse([cx - gr, dot_cy - gr, cx + gr, dot_cy + gr], fill=BLUE + (95,))
    glow = glow.filter(ImageFilter.GaussianBlur(s * 0.055))
    img = Image.alpha_composite(img, glow)

    d = ImageDraw.Draw(img)
    d.rounded_rectangle([cx - stem_w / 2, stem_top, cx + stem_w / 2, stem_top + stem_h], radius=radius, fill=WHITE + (255,))

    dot = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    dd = ImageDraw.Draw(dot)
    dd.ellipse([cx - dot_r, dot_cy - dot_r, cx + dot_r, dot_cy + dot_r], fill=BLUE + (255,))
    # Specular highlight, upper left of the dot.
    hr = dot_r * 0.5
    hx, hy = cx - dot_r * 0.28, dot_cy - dot_r * 0.3
    hl = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(hl).ellipse([hx - hr, hy - hr, hx + hr, hy + hr], fill=BLUE_HOT + (90,))
    hl = hl.filter(ImageFilter.GaussianBlur(dot_r * 0.45))
    dot = Image.alpha_composite(dot, hl)
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).ellipse([cx - dot_r, dot_cy - dot_r, cx + dot_r, dot_cy + dot_r], fill=255)
    img.paste(dot, (0, 0), mask)
    return img


def ios_icon():
    big = glyph(1024 * SS)
    return big.resize((1024, 1024), Image.LANCZOS).convert("RGB")


def mac_icon():
    W = 1024 * SS
    body = int(824 * SS)
    off = (W - body) // 2
    radius = int(body * 0.2237)
    tile = glyph(body)
    # Hairline rim so the black tile separates from dark wallpapers.
    rim = Image.new("RGBA", (body, body), (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle([0, 0, body - 1, body - 1], radius=radius, outline=(255, 255, 255, 34), width=int(3 * SS))
    tile = Image.alpha_composite(tile, rim)
    mask = Image.new("L", (body, body), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, body - 1, body - 1], radius=radius, fill=255)

    canvas = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([off, off + 14 * SS, off + body, off + body + 14 * SS], radius=radius, fill=(0, 0, 0, 120))
    shadow = shadow.filter(ImageFilter.GaussianBlur(20 * SS))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas.paste(tile, (off, off), mask)
    return canvas.resize((1024, 1024), Image.LANCZOS)


def write_json(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")


def main():
    os.makedirs(ASSETS, exist_ok=True)
    write_json(os.path.join(ASSETS, "Contents.json"), {"info": {"author": "xcode", "version": 1}})

    # iOS + macOS share one AppIcon set: a single 1024 for iOS, the classic sizes for macOS.
    iconset = os.path.join(ASSETS, "AppIcon.appiconset")
    os.makedirs(iconset, exist_ok=True)
    ios_icon().save(os.path.join(iconset, "icon-ios-1024.png"))
    mac = mac_icon()
    images = [{"filename": "icon-ios-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}]
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"icon-mac-{pt}@{scale}x.png"
            mac.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}"})
    write_json(os.path.join(iconset, "Contents.json"), {"images": images, "info": {"author": "xcode", "version": 1}})

    # Accent colour (electric blue) and the launch background (white / black).
    def colorset(name, light, dark):
        path = os.path.join(ASSETS, f"{name}.colorset")
        os.makedirs(path, exist_ok=True)

        def comp(rgb):
            return {"color-space": "srgb", "components": {"red": f"{rgb[0] / 255:.3f}", "green": f"{rgb[1] / 255:.3f}", "blue": f"{rgb[2] / 255:.3f}", "alpha": "1.000"}}

        write_json(os.path.join(path, "Contents.json"), {
            "colors": [
                {"idiom": "universal", "color": comp(light)},
                {"idiom": "universal", "appearances": [{"appearance": "luminosity", "value": "dark"}], "color": comp(dark)},
            ],
            "info": {"author": "xcode", "version": 1},
        })

    colorset("AccentColor", (47, 107, 255), (77, 132, 255))
    colorset("LaunchBackground", (255, 255, 255), (0, 0, 0))

    # A copy for the README.
    docs = os.path.join(ROOT, "docs")
    os.makedirs(docs, exist_ok=True)
    mac.resize((256, 256), Image.LANCZOS).save(os.path.join(docs, "icon.png"))
    print("Wrote", iconset)


if __name__ == "__main__":
    main()
