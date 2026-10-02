# Turns square artwork into a macOS icon image: python make-macos-icon.py <artwork.png> <icon-1024.png> (needs Pillow)
import sys
from PIL import Image, ImageDraw, ImageFilter

src, out = sys.argv[1], sys.argv[2]
CANVAS, BODY, RADIUS, SS = 1024, 824, 185, 4
art = Image.open(src).convert("RGBA").resize((BODY, BODY), Image.LANCZOS)
mask = Image.new("L", (BODY * SS, BODY * SS), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, BODY * SS - 1, BODY * SS - 1], radius=RADIUS * SS, fill=255)
mask = mask.resize((BODY, BODY), Image.LANCZOS)
art.putalpha(mask)
offset = (CANVAS - BODY) // 2
shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
shape = Image.new("RGBA", (BODY, BODY), (0, 0, 0, 90))
shape.putalpha(mask.point(lambda v: v * 90 // 255))
shadow.paste(shape, (offset, offset + 12), shape)
shadow = shadow.filter(ImageFilter.GaussianBlur(14))
canvas = Image.alpha_composite(shadow, Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0)))
canvas.paste(art, (offset, offset), art)
canvas.save(out)
