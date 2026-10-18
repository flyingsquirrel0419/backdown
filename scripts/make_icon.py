import sys, math
from PIL import Image, ImageDraw

out = sys.argv[1]
N = 4096  # supersample, downscale to 1024
# diagonal gradient: indigo (top-left) -> sky blue (bottom-right)
c1, c2 = (58, 36, 200), (24, 160, 240)
big = Image.new("RGB", (N, 1))
for x in range(N):
    t = x / (N - 1)
    big.putpixel((x, 0), tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3)))
big = big.resize((int(N * 1.5), int(N * 1.5))).rotate(-45, resample=Image.BICUBIC)
o = (big.width - N) // 2
img = big.crop((o, o, o + N, o + N))

d = ImageDraw.Draw(img)
cx, cy = N / 2, N / 2
W = (255, 255, 255)

# progress ring (track + ~70% arc)
R, stroke = N * 0.34, N * 0.055
box = (cx - R, cy - R, cx + R, cy + R)
track = Image.new("RGBA", (N, N), (0, 0, 0, 0))
ImageDraw.Draw(track).ellipse(box, outline=(255, 255, 255, 70), width=int(stroke))
img.paste(track, (0, 0), track)
d.arc(box, start=-90, end=-90 + 252, fill=W, width=int(stroke))
# round caps on the arc
for ang in (-90, -90 + 252):
    a = math.radians(ang)
    r_mid = R - stroke / 2
    x, y = cx + r_mid * math.cos(a), cy + r_mid * math.sin(a)
    d.ellipse((x - stroke / 2, y - stroke / 2, x + stroke / 2, y + stroke / 2), fill=W)

# down arrow
sw = N * 0.07          # shaft width
top, tip = cy - N * 0.21, cy + N * 0.12
head_w, head_h = N * 0.28, N * 0.16
d.rounded_rectangle((cx - sw / 2, top, cx + sw / 2, tip - head_h * 0.6), radius=sw / 2, fill=W)
d.polygon([(cx - head_w / 2, tip - head_h), (cx + head_w / 2, tip - head_h), (cx, tip)], fill=W)

# tray under arrow
ty = cy + N * 0.16
tw, th = N * 0.15, N * 0.045
d.rounded_rectangle((cx - tw, ty, cx + tw, ty + th), radius=th / 2, fill=W)

img.resize((1024, 1024), Image.LANCZOS).save(out, "PNG")
