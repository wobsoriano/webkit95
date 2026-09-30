"""Draws every webkit95 icon and writes Sources/Webkit95Kit/Icons.swift."""
import math
import sys

PALETTE = set("kwgslnbtcGLyoMrmpi")
import os
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Sources", "Webkit95Kit", "Icons.swift")


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.px = [["."] * w for _ in range(h)]

    def set(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[y][x] = c

    def get(self, x, y):
        return self.px[y][x] if 0 <= x < self.w and 0 <= y < self.h else "."

    def paint(self, mask, c):
        for x, y in mask:
            self.set(x, y, c)

    def stamp(self, rows, ox, oy):
        for y, row in enumerate(rows):
            for x, c in enumerate(row):
                if c != ".":
                    self.set(ox + x, oy + y, c)

    def rows(self):
        return ["".join(r) for r in self.px]


# Masks are sets of (x, y). Predicates sample pixel centers.

def mask_of(w, h, pred):
    return {(x, y) for y in range(h) for x in range(w) if pred(x + 0.5, y + 0.5)}


def in_poly(pts):
    def pred(px, py):
        inside = False
        j = len(pts) - 1
        for i in range(len(pts)):
            xi, yi = pts[i]
            xj, yj = pts[j]
            if (yi > py) != (yj > py) and px < (xj - xi) * (py - yi) / (yj - yi) + xi:
                inside = not inside
            j = i
        return inside
    return pred


def in_disk(cx, cy, r):
    return lambda x, y: (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def in_rect(x0, y0, x1, y1):
    """Inclusive pixel rectangle."""
    return lambda x, y: x0 <= x - 0.5 <= x1 and y0 <= y - 0.5 <= y1


def seg_dist(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - ax - t * dx, py - ay - t * dy)


def in_capsule(ax, ay, bx, by, r):
    return lambda x, y: seg_dist(x, y, ax, ay, bx, by) <= r


N4 = [(0, -1), (-1, 0), (1, 0), (0, 1)]
N8 = N4 + [(-1, -1), (1, -1), (-1, 1), (1, 1)]


def bevel(cv, mask, fill, hi=None, lo=None, outline="k", outer=False, conn=None):
    """Flat fill with a lit top-left edge, a shaded bottom-right edge and a hard outline.

    outer=True puts the outline outside the mask, which keeps tiny shapes from turning all black.
    """
    conn = conn or N4
    if outer:
        ring = {(x + dx, y + dy) for x, y in mask for dx, dy in conn} - mask
        interior = set(mask)
    else:
        ring = {(x, y) for x, y in mask if any((x + dx, y + dy) not in mask for dx, dy in conn)}
        interior = mask - ring
    cv.paint(interior, fill)
    for x, y in interior:
        if lo and ((x + 1, y) not in interior or (x, y + 1) not in interior):
            cv.set(x, y, lo)
        if hi and ((x - 1, y) not in interior or (x, y - 1) not in interior):
            cv.set(x, y, hi)
    if outline:
        cv.paint(ring, outline)


def drop_shadow(cv, mask, dx=1, dy=1, c="g"):
    cv.paint({(x + dx, y + dy) for x, y in mask} - mask, c)


# The globe's land is a few round blobs (lon, lat, radius in degrees) inside a 120 degree tile,
# repeated three times around the sphere so eight 15 degree frames loop with small, trackable steps.
BLOBS = [
    (20, 30, 18), (36, 14, 14), (8, 44, 11), (42, -2, 8), (47, -14, 5),
    (88, -18, 12), (98, -30, 8), (80, -4, 5),
    (100, 38, 6),
]
LIGHT = (-0.55, -0.6, 0.58)
_ll = math.sqrt(sum(v * v for v in LIGHT))
LIGHT = tuple(v / _ll for v in LIGHT)
HI, LO, LAND_HI = 0.95, 0.0, 0.7


def is_land(lon, lat):
    for blon, blat, br in BLOBS:
        for k in range(-1, 4):
            l0, p0, l1 = math.radians(blon + 120 * k), math.radians(blat), lon % (2 * math.pi)
            c = math.sin(p0) * math.sin(lat) + math.cos(p0) * math.cos(lat) * math.cos(l1 - l0)
            if math.degrees(math.acos(max(-1.0, min(1.0, c)))) <= br:
                return True
    return False


def globe(cv, cx, cy, r, rot, ocean=("b", "c", "n"), land=("G", "L"), outline="k", tilt=0.35):
    """Returns the disk mask. ocean is (base, highlight, shade), land is (base, highlight)."""
    disk = mask_of(cv.w, cv.h, in_disk(cx, cy, r))
    ring = {(x, y) for x, y in disk if any((x + dx, y + dy) not in disk for dx, dy in N4)}
    ct, st = math.cos(tilt), math.sin(tilt)
    for x, y in disk - ring:
        dx, dy = (x + 0.5 - cx) / r, (y + 0.5 - cy) / r
        z = math.sqrt(max(0.0, 1 - dx * dx - dy * dy))
        b = dx * LIGHT[0] + dy * LIGHT[1] + z * LIGHT[2]
        tx, ty = dx * ct - dy * st, dx * st + dy * ct
        lon = math.atan2(tx, z) + rot
        lat = math.asin(max(-1.0, min(1.0, -ty)))
        if is_land(lon, lat):
            cv.set(x, y, land[1] if b > LAND_HI else land[0])
        else:
            c = ocean[0]
            if b > HI:
                c = ocean[1]
            elif b < LO and ocean[2]:
                c = ocean[2]
            cv.set(x, y, c)
    cv.paint(ring, outline)
    return disk


def ellipse_points(cx, cy, a, b, tilt, steps=720):
    ct, st = math.cos(tilt), math.sin(tilt)
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ex, ey = a * math.cos(t), b * math.sin(t)
        yield t, cx + ex * ct - ey * st, cy + ex * st + ey * ct


def star_mask(w, h, cx, cy, ro, ri, rot=-math.pi / 2):
    pts = []
    for i in range(10):
        r = ro if i % 2 == 0 else ri
        a = rot + i * math.pi / 5
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return mask_of(w, h, in_poly(pts))


SPARKLE = [
    "..k..",
    ".kyk.",
    "kywyk",
    ".kyk.",
    "..k..",
]
SPARKLE7 = [
    "...k...",
    "..kyk..",
    ".kyyyk.",
    "kyywyyk",
    ".kyyyk.",
    "..kyk..",
    "...k...",
]

ART = {}


def put(name, cv_or_rows):
    ART[name] = cv_or_rows.rows() if isinstance(cv_or_rows, Canvas) else cv_or_rows


# App icon: a teal globe inside a tilted navy orbit ring with a yellow star riding the ring.

def app_icon(size):
    cv = Canvas(size, size)
    c = (size - 1) / 2 + 0.5
    if size == 32:
        r, a, b, star, sx, sy = 11.0, 15.4, 5.6, SPARKLE7, 24, 1
    else:
        r, a, b, star, sx, sy = 5.3, 7.6, 2.8, SPARKLE, 11, 0
    back, front = [], []
    for t, x, y in ellipse_points(c, c + 0.5, a, b, -0.38):
        (front if math.sin(t) > 0 else back).append((int(x), int(y)))
    for p in back:
        cv.set(*p, "n")
    globe(cv, c, c, r, 0.6, ocean=("t", "c", None), land=("G", "L"))
    for p in front:
        cv.set(*p, "n")
    cv.stamp(star, sx, sy)
    return cv


put("app16", app_icon(16))
put("app32", app_icon(32))


# Toolbar, 20x20.

def arrow(direction):
    cv = Canvas(20, 20)
    cy = 9

    def pred(px, py):
        x, y = int(px), int(py)
        if direction > 0:
            x = 19 - x
        d = abs(y - cy)
        if d > 8:
            return False
        if 1 + d <= x <= 9:
            return True
        return d <= 3 and 1 + d <= x <= 17
    m = mask_of(20, 20, pred)
    drop_shadow(cv, m, 1, 1, "g")
    bevel(cv, m, "G", hi="L", lo=None)
    return cv


put("back", arrow(-1))
put("forward", arrow(1))


def stop():
    cv = Canvas(20, 20)
    c, r, cut = 9.5, 9.0, 5.2
    pts = [(c - r + cut, c - r), (c + r - cut, c - r), (c + r, c - r + cut), (c + r, c + r - cut),
           (c + r - cut, c + r), (c - r + cut, c + r), (c - r, c + r - cut), (c - r, c - r + cut)]
    pts = [(x - 0.5, y - 0.5) for x, y in pts]
    m = mask_of(20, 20, in_poly(pts))
    drop_shadow(cv, m)
    bevel(cv, m, "r", hi=None, lo="m")
    x = mask_of(20, 20, lambda px, py: seg_dist(px, py, 5.5, 5.5, 13.5, 13.5) <= 1.05
                or seg_dist(px, py, 13.5, 5.5, 5.5, 13.5) <= 1.05)
    cv.paint(x, "w")
    return cv


put("stop", stop())


def refresh():
    cv = Canvas(20, 20)
    band = mask_of(20, 20, lambda x, y: 4.1 <= math.hypot(x - 10, y - 10) <= 8.9)
    head = {(x, 9 + i) for i, (x0, x1) in enumerate(((12, 19), (13, 18), (14, 17), (15, 16))) for x in range(x0, x1 + 1)}
    green = {(x, y) for x, y in band if y <= 8 and (x >= 10 or y <= 5)} | head
    blue = {(19 - x, 19 - y) for x, y in green}
    bevel(cv, green, "G", hi="L", conn=N8)
    bevel(cv, blue, "b", hi="c", conn=N8)
    return cv


put("refresh", refresh())


def home():
    cv = Canvas(20, 20)
    walls = mask_of(20, 20, in_rect(3, 9, 16, 18))
    drop_shadow(cv, walls)
    bevel(cv, walls, "i", hi="w", lo="s")
    door = mask_of(20, 20, in_rect(5, 12, 8, 18))
    bevel(cv, door, "m", hi="r")
    cv.set(7, 15, "y")
    win = mask_of(20, 20, in_rect(10, 11, 14, 15))
    bevel(cv, win, "c")
    for i in range(11, 14):
        cv.set(12, i, "k")
        cv.set(i, 13, "k")
    chim = mask_of(20, 20, in_rect(13, 1, 15, 7))
    bevel(cv, chim, "m", hi="r")
    roof = mask_of(20, 20, in_poly([(10, 0), (20.5, 10.5), (-0.5, 10.5)]))
    bevel(cv, roof, "r", hi=None, lo="m")
    return cv


put("home", home())


def search():
    cv = Canvas(20, 20)
    handle = mask_of(20, 20, in_capsule(12.6, 12.6, 17.2, 17.2, 1.9))
    bevel(cv, handle, "m", hi="r")
    rim = mask_of(20, 20, in_disk(8.0, 8.0, 7.3))
    bevel(cv, rim, "s", hi="w", lo="g")
    globe(cv, 8.0, 8.0, 5.0, 0.3, outline="n", tilt=0.35)
    cv.set(6, 5, "w")
    cv.set(5, 6, "w")
    return cv


put("search", search())


def favorites():
    cv = Canvas(20, 20)
    m = star_mask(20, 20, 9.5, 10.6, 10.2, 4.2)
    drop_shadow(cv, m)
    bevel(cv, m, "y", hi="w", lo="o")
    return cv


put("favorites", favorites())


def printer():
    cv = Canvas(20, 20)
    paper = mask_of(20, 20, in_rect(5, 1, 14, 9))
    bevel(cv, paper, "w")
    for y, x1 in ((3, 12), (5, 11), (7, 12)):
        for x in range(7, x1 + 1):
            cv.set(x, y, "g")
    top = mask_of(20, 20, in_poly([(3.5, 7), (16.5, 7), (19, 10), (1, 10)]))
    bevel(cv, top, "l", hi="w")
    body = mask_of(20, 20, in_rect(1, 9, 18, 16))
    drop_shadow(cv, body)
    bevel(cv, body, "s", hi="w", lo="g")
    slot = mask_of(20, 20, in_rect(4, 12, 15, 12))
    cv.paint(slot, "k")
    cv.set(16, 10 + 1, "L")
    out = mask_of(20, 20, in_rect(4, 15, 15, 18))
    bevel(cv, out, "w")
    for x in range(6, 12):
        cv.set(x, 16, "g")
    return cv


put("print", printer())

FONT = [
    "....................",
    "....................",
    "....................",
    "......nn............",
    ".....nnnn...........",
    ".....nnnn...........",
    "....nn.nnn..........",
    "....nn.nnn..........",
    "...nn...nnn.........",
    "...nn...nnn.........",
    "..nnnnnnnnnn........",
    "..nn.....nnn...nnn..",
    ".nn.......nnn....nn.",
    ".nn.......nnn..nnnn.",
    "nn.........nnnnn.nn.",
    "nn.........nnnnn.nn.",
    "nnnn.....nnnnn.nnnnn",
    "....................",
    "....................",
    "....................",
]
put("font", FONT)


def assistant():
    cv = Canvas(20, 20)
    body = mask_of(20, 20, lambda x, y: (
        in_rect(1, 5, 15, 14)(x, y) and not
        any(abs(x - 0.5 - cx) + abs(y - 0.5 - cy) < 1.5 for cx, cy in ((1, 5), (15, 5), (1, 14), (15, 14)))
    ) or in_poly([(3, 14), (8, 14), (2.5, 19.2)])(x, y))
    drop_shadow(cv, body)
    bevel(cv, body, "w", lo="l")
    for x0 in (4, 7, 10):
        for dx in (0, 1):
            for dy in (0, 1):
                cv.set(x0 + dx + 0, 9 + dy, "n")
    cv.stamp(SPARKLE7, 13, 0)
    return cv


put("assistant", assistant())


# Message boxes, 32x32.

def balloon(glyph):
    cv = Canvas(32, 32)
    m = mask_of(32, 32, lambda x, y: in_disk(15, 13.5, 12.8)(x, y) or in_poly([(6, 21), (13, 25.5), (4.5, 30.5)])(x, y))
    drop_shadow(cv, m, 2, 2, "g")
    bevel(cv, m, "w", lo="l")
    cv.stamp(glyph, 15 - len(glyph[0]) // 2, 4)
    return cv


INFO_I = [
    "..bbb..",
    "..bbb..",
    "..bbb..",
    ".......",
    ".......",
    "bbbbb..",
    "..bbb..",
    "..bbb..",
    "..bbb..",
    "..bbb..",
    "..bbb..",
    "..bbb..",
    "..bbb..",
    "bbbbbbb",
]
QUESTION_Q = [
    "..bbbbb..",
    ".bbbbbbb.",
    "bbb...bbb",
    "bbb...bbb",
    "......bbb",
    ".....bbb.",
    "....bbb..",
    "...bbb...",
    "...bbb...",
    "...bbb...",
    ".........",
    "...bbb...",
    "...bbb...",
    "...bbb...",
]
put("info", balloon(INFO_I))
put("question", balloon(QUESTION_Q))


def warning():
    cv = Canvas(32, 32)
    m = mask_of(32, 32, in_poly([(15.5, 0.8), (30.6, 28.6), (0.4, 28.6)]))
    drop_shadow(cv, m, 2, 2, "g")
    bevel(cv, m, "y", lo="o")
    bang = [
        ".kkk.",
        "kkkkk",
        "kkkkk",
        "kkkkk",
        ".kkk.",
        ".kkk.",
        ".kkk.",
        "..k..",
        "..k..",
        ".....",
        ".kkk.",
        ".kkk.",
        ".kkk.",
    ]
    cv.stamp(bang, 13, 10)
    return cv


put("warning", warning())


def error():
    cv = Canvas(32, 32)
    m = mask_of(32, 32, in_disk(15, 15, 14.2))
    drop_shadow(cv, m, 2, 2, "g")
    bevel(cv, m, "r", lo="m")
    x = mask_of(32, 32, lambda px, py: seg_dist(px, py, 10, 10, 20, 20) <= 1.6
                or seg_dist(px, py, 20, 10, 10, 20) <= 1.6)
    cv.paint(x, "w")
    return cv


put("error", error())


# Small icons, 16x16.

def folder():
    cv = Canvas(16, 16)
    back = mask_of(16, 16, lambda x, y: in_rect(1, 2, 6, 5)(x, y) or in_rect(0, 3, 14, 13)(x, y))
    bevel(cv, back, "o", hi="y")
    front = mask_of(16, 16, in_rect(0, 5, 14, 13))
    bevel(cv, front, "y", hi="w", lo="o")
    return cv


put("folder", folder())

PAGE = [
    "..kkkkkkkk......",
    "..kwwwwwwkk.....",
    "..kwwwwwwklk....",
    "..kwwwwwwkllk...",
    "..kwwwwwwkkkkk..",
    "..kwwwwwwwwwwkg.",
    "..kwggggggwwwkg.",
    "..kwwwwwwwwwwkg.",
    "..kwgggggggwwkg.",
    "..kwwwwwwwwwwkg.",
    "..kwggggggggwkg.",
    "..kwwwwwwwwwwkg.",
    "..kwgggggwwwwkg.",
    "..kwwwwwwwwwwkg.",
    "..kkkkkkkkkkkkg.",
    "...gggggggggggg.",
]
put("page", PAGE)

DOCUMENT = [
    "..kkkkkkkkkk....",
    "..knnnnnnnnkk...",
    "..knwwwwnnnklk..",
    "..knnnnnnnnkkkk.",
    "..kwwwwwwwwwwwkg",
    "..kwbbbbbbbbwwkg",
    "..kwwwwwwwwwwwkg",
    "..kwbbbbbbbbbwkg",
    "..kwwwwwwwwwwwkg",
    "..kwbbbbbbbwwwkg",
    "..kwwwwwwwwwwwkg",
    "..kwbbbbbbbbbwkg",
    "..kwwwwwwwwwwwkg",
    "..kwbbbbbwwwwwkg",
    "..kkkkkkkkkkkkkg",
    "...gggggggggggg.",
]
put("document", DOCUMENT)


def small_globe():
    cv = Canvas(16, 16)
    globe(cv, 8, 8, 7.4, 0.35)
    return cv


put("globe", small_globe())

LOCK = [
    "................",
    ".....kkkkkk.....",
    "....kwwwwwgk....",
    "....kwkkkkgk....",
    "....kwk..kgk....",
    "....kwk..kgk....",
    "...kkkkkkkkkk...",
    "...kwwwwwwwwk...",
    "...kwyyyyyyok...",
    "...kwyykkyyok...",
    "...kwykkkkyok...",
    "...kwykkkkyok...",
    "...kwyykkyyok...",
    "...kwyykkyyok...",
    "...kooooooook...",
    "...kkkkkkkkkk...",
]
put("lock", LOCK)


def zone():
    cv = Canvas(16, 16)
    globe(cv, 7.5, 6.5, 5.6, 0.9)
    for t, x, y in ellipse_points(7.5, 6.5, 7.0, 7.0, 0):
        if math.cos(t) > -0.1 and math.sin(t) > -0.8 and cv.get(int(x), int(y)) == ".":
            cv.set(int(x), int(y), "g")
    cv.paint(mask_of(16, 16, in_rect(7, 12, 8, 13)), "k")
    cv.paint(mask_of(16, 16, in_rect(5, 13, 10, 13)), "g")
    cv.paint(mask_of(16, 16, in_rect(3, 14, 12, 14)), "k")
    return cv


put("zone", zone())


def tool():
    cv = Canvas(16, 16)
    hx, hy = 10.8, 5.2
    ux, uy = 1 / math.sqrt(2), -1 / math.sqrt(2)

    def pred(x, y):
        if in_capsule(2.6, 13.4, hx, hy, 1.6)(x, y) or in_disk(hx, hy, 4.1)(x, y):
            along = (x - hx) * ux + (y - hy) * uy
            across = -(x - hx) * uy + (y - hy) * ux
            return not (along > -0.6 and abs(across) < 1.4)
        return False
    m = mask_of(16, 16, pred)
    bevel(cv, m, "s", hi="w", lo="g")
    return cv


put("tool", tool())


def thought():
    cv = Canvas(16, 16)
    bulb = mask_of(16, 16, lambda x, y: in_disk(8, 6, 5.4)(x, y) or in_poly([(4.8, 9), (11.2, 9), (10, 12), (6, 12)])(x, y))
    bevel(cv, bulb, "y", hi="w", lo="o")
    base = mask_of(16, 16, in_rect(5, 11, 10, 14))
    bevel(cv, base, "s", hi="w", lo="g")
    for x in range(6, 10):
        cv.set(x, 13, "g")
    cv.set(7, 15, "k")
    cv.set(8, 15, "k")
    return cv


put("thought", thought())


def favorite_item():
    cv = Canvas(16, 16)
    cv.stamp(PAGE, 0, 0)
    s = star_mask(16, 16, 5.2, 11.0, 4.6, 2.0)
    bevel(cv, s, "y", lo="o", outer=True)
    return cv


put("favoriteItem", favorite_item())

# Title bar and control glyphs.
put("minimize", [
    "........",
    "........",
    "........",
    "........",
    "........",
    ".kkkkkk.",
    ".kkkkkk.",
])
put("maximize", [
    "kkkkkkkkk",
    "kkkkkkkkk",
    "k.......k",
    "k.......k",
    "k.......k",
    "k.......k",
    "k.......k",
    "k.......k",
    "kkkkkkkkk",
])
put("restore", [
    "..kkkkkk",
    "..kkkkkk",
    "..k....k",
    "kkkkkk.k",
    "kkkkkk.k",
    "k....kkk",
    "k....k..",
    "k....k..",
    "kkkkkk..",
])
put("close", [
    "kk....kk",
    ".kk..kk.",
    "..kkkk..",
    "...kk...",
    "..kkkk..",
    ".kk..kk.",
    "kk....kk",
])
put("check", [
    "......k",
    ".....kk",
    "k...kkk",
    "kk.kkk.",
    "kkkkk..",
    ".kkk...",
    "..k....",
])
put("radio", [
    ".kkkk.",
    "kkkkkk",
    "kkkkkk",
    "kkkkkk",
    "kkkkkk",
    ".kkkk.",
])
RIGHT = ["k...", "kk..", "kkk.", "kkkk", "kkk.", "kk..", "k..."]
UP = ["...k...", "..kkk..", ".kkkkk.", "kkkkkkk"]
put("submenuArrow", RIGHT)
put("arrowRight", RIGHT)
put("arrowLeft", [r[::-1] for r in RIGHT])
put("arrowUp", UP)
put("arrowDown", UP[::-1])
put("comboArrow", UP[::-1])


def expander(plus):
    cv = Canvas(9, 9)
    bevel(cv, mask_of(9, 9, in_rect(0, 0, 8, 8)), "w", outline="g")
    for x in range(2, 7):
        cv.set(x, 4, "k")
    if plus:
        for y in range(2, 7):
            cv.set(4, y, "k")
    return cv


put("expandPlus", expander(True))
put("expandMinus", expander(False))


# Logo animation: the globe turns 15 degrees per frame while a comet circles it once per loop.

def logo(i):
    cv = Canvas(32, 32)
    cx = cy = 16.0
    r = 10.0
    a, b, tilt = 14.4, 6.2, -0.55
    ct, st = math.cos(tilt), math.sin(tilt)
    t = math.pi / 8 - i * math.pi / 4

    def orbit(tt):
        ex, ey = a * math.cos(tt), b * math.sin(tt)
        return int(cx + ex * ct - ey * st), int(cy + ex * st + ey * ct)

    disk = mask_of(32, 32, in_disk(cx, cy, r))

    def draw_comet(front):
        if math.sin(t) <= 0 and orbit(t) in disk:
            return
        for k in range(TRAIL, 0, -1):
            tt = t + k * TRAIL_STEP
            p = orbit(tt)
            if (math.sin(tt) > 0) == front and (front or p not in disk):
                cv.set(*p, "y" if k <= TRAIL // 2 else "o")
        if (math.sin(t) > 0) == front:
            hx, hy = orbit(t)
            for y, row in enumerate(SPARKLE):
                for x, c in enumerate(row):
                    p = (hx - 2 + x, hy - 2 + y)
                    if c != "." and (front or p not in disk):
                        cv.set(*p, c)

    draw_comet(False)
    globe(cv, cx, cy, r, -i * 2 * math.pi / 3 / 8)
    draw_comet(True)
    return cv


TRAIL, TRAIL_STEP = 6, 0.07
LOGO = [logo(i).rows() for i in range(8)]


def check(name, rows, size=None):
    w = len(rows[0])
    assert all(len(r) == w for r in rows), f"{name}: ragged rows"
    bad = set("".join(rows)) - PALETTE - {"."}
    assert not bad, f"{name}: unknown {bad}"
    if size:
        assert (w, len(rows)) == size, f"{name}: {w}x{len(rows)} != {size}"


SIZES = {
    "app16": (16, 16), "app32": (32, 32),
    **{n: (20, 20) for n in "back forward stop refresh home search favorites print font assistant".split()},
    **{n: (32, 32) for n in "info warning question error".split()},
    **{n: (16, 16) for n in "folder page document globe lock zone tool thought favoriteItem".split()},
    "minimize": (8, 7), "maximize": (9, 9), "restore": (8, 9), "close": (8, 7),
    "check": (7, 7), "radio": (6, 6), "submenuArrow": (4, 7), "arrowUp": (7, 4), "arrowDown": (7, 4),
    "arrowLeft": (4, 7), "arrowRight": (4, 7), "comboArrow": (7, 4), "expandPlus": (9, 9), "expandMinus": (9, 9),
}
assert set(SIZES) == set(ART), set(SIZES) ^ set(ART)
for n, rows in ART.items():
    check(n, rows, SIZES[n])
for i, rows in enumerate(LOGO):
    check(f"logo{i}", rows, (32, 32))


def swift_art(name, rows, indent="    "):
    body = "\n".join(f'{indent}    "{r}",' for r in rows)
    return f"{indent}static let {name} = PixelArt([\n{body}\n{indent}])\n"


HEADER = '''/// Every icon webkit95 shows, as original pixel art in the Win95 palette. Views render these at
/// integer scale with nearest neighbor sampling.
public enum Icon: String, CaseIterable, Sendable {
    // 16x16 and 32x32 app icon
    case app16, app32
    // 20x20 toolbar icons
    case back, forward, stop, refresh, home, search, favorites, print, font, assistant
    // 32x32 message box icons
    case info, warning, question, error
    // 16x16 small icons
    case folder, page, document, globe, lock, zone, tool, thought, favoriteItem
    // title bar button glyphs, black on the button face
    case minimize, maximize, restore, close
    // menu, scrollbar and control glyphs
    case check, radio, submenuArrow, arrowUp, arrowDown, arrowLeft, arrowRight, comboArrow
    case expandPlus, expandMinus

    public var art: PixelArt { Icons.art[self] ?? Icons.missing }
}

public enum Icons {
    static let missing = PixelArt([
        "kkkkkkkk",
        "krrrrrrk",
        "krrrrrrk",
        "kkkkkkkk",
    ])

    /// Frames of the toolbar logo animation. Frame 0 is the resting frame.
    public static let logoFrames: [PixelArt] = [LOGOS]

    static let art: [Icon: PixelArt] = [
TABLE
    ]

'''

order = list(SIZES)
out = HEADER.replace("[LOGOS]", "[" + ", ".join(f"logo{i}" for i in range(8)) + "]")
out = out.replace("TABLE", "\n".join(f"        .{n}: {n}," for n in order))
out += "\n".join(swift_art(n, ART[n]) for n in order)
out += "\n" + "\n".join(swift_art(f"logo{i}", LOGO[i]) for i in range(8))
out += "}\n"

path = sys.argv[1] if len(sys.argv) > 1 else OUT
with open(path, "w") as f:
    f.write(out)
print("wrote", path)
