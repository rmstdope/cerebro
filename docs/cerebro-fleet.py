#!/usr/bin/env python3
"""Generate docs/cerebro-fleet.svg - a comic cover of the Cerebro fleet.

    python3 docs/cerebro-fleet.py          # from the repository root

The picture answers one question: who talks to whom. The navigator is in the middle because every
user-facing decision is his; the agents stand on the bead board because that is the only way they
reach each other. A role added to `scripts/roster` is a line here, not an afternoon in an SVG
editor. Nothing runs this automatically - regenerate it when a role or a flow changes, and commit
both files.

To look at the result, open the SVG in a browser. The headline font stack falls back to whatever
condensed sans the machine has; every plate is sized for the widest of them.
"""
import math
import pathlib

W, H = 2100, 1470
CX, CY = 1050, 775         # centre of the bead-board ellipse, and of the navigator
RX, RY = 720, 375          # its radii

INK = "#14110d"
PAPER = "#fdf3dc"
CRIMSON = "#e01b39"
DEEPRED = "#96122a"
GOLD = "#ffc21a"
AMBER = "#c98600"
COBALT = "#1e6fe0"
NAVY = "#164a99"
TEAL = "#0fa08f"
DEEPTEAL = "#0a6b60"
PURPLE = "#7b3fbf"
DEEPPURPLE = "#4d2278"
ORANGE = "#f6791f"
DEEPORANGE = "#b04708"
GREEN = "#1f9d4d"
DEEPGREEN = "#136632"
SLATE = "#2f3d52"
STEEL = "#5a6c85"
WHITE = "#ffffff"
CREAM = "#ffe9a8"

SKIN = ["#f6cfa8", "#e0a978", "#c2814d", "#8d5a34"]
FUR = "#5182d8"

HDR = "'Bangers','Luckiest Guy','Impact','Haettenschweiler','Arial Narrow Bold','Arial Black',sans-serif"
BODY = "'Avenir Next','Helvetica Neue',Helvetica,Arial,sans-serif"

out = []
add = out.append


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, size=22, weight=700, fill=INK, anchor="middle", family="hdr", spacing=0, opacity=1.0):
    fam = HDR if family == "hdr" else BODY
    op = "" if opacity == 1.0 else f' opacity="{opacity}"'
    add(f'<text x="{x:.1f}" y="{y:.1f}" font-family="{fam}" font-size="{size}" font-weight="{weight}" '
        f'fill="{fill}" text-anchor="{anchor}" letter-spacing="{spacing}"{op}>{esc(s)}</text>')


def pt(angle_deg, fx=1.0, fy=None):
    """A point on the bead-board ellipse. 0 degrees is the top, going clockwise."""
    fy = fx if fy is None else fy
    a = math.radians(angle_deg)
    return CX + RX * fx * math.sin(a), CY - RY * fy * math.cos(a)


def arc_path(a0, a1, fx=1.0, fy=None, step=2.0):
    fy = fx if fy is None else fy
    step = step if a1 >= a0 else -step
    pts, a = [], a0
    while (a <= a1 + 1e-6) if step > 0 else (a >= a1 - 1e-6):
        x, y = pt(a, fx, fy)
        pts.append(f"{x:.1f},{y:.1f}")
        a += step
    return "M" + " L".join(pts)


def burst(cx, cy, r, colour, spikes=17, inner=0.78, rot=0.0, stroke=None, sw=4, opacity=1.0):
    pts = []
    for i in range(spikes * 2):
        a = rot + i * math.pi / spikes
        rr = r if i % 2 == 0 else r * inner
        pts.append(f"{cx + rr * math.sin(a):.1f},{cy - rr * math.cos(a):.1f}")
    st = f' stroke="{stroke}" stroke-width="{sw}" stroke-linejoin="round"' if stroke else ""
    op = "" if opacity == 1.0 else f' opacity="{opacity}"'
    add(f'<polygon points="{" ".join(pts)}" fill="{colour}"{st}{op}/>')


# ------------------------------------------------------------------ the busts
def bust(cx, cy, s, spec):
    """A comic head-and-shoulders, drawn in a 216-unit-wide local box and scaled by s."""
    suit, dark = spec["suit"], spec["dark"]
    skin = spec.get("skin", SKIN[0])
    add(f'<g transform="translate({cx:.1f},{cy:.1f}) scale({s})">')

    add(f'<path d="M-108,116 C-108,44 -70,14 -38,4 L38,4 C70,14 108,44 108,116 Z" '
        f'fill="{suit}" stroke="{INK}" stroke-width="6" stroke-linejoin="round"/>')
    add(f'<path d="M-38,4 C-30,44 -14,58 0,58 C14,58 30,44 38,4 L20,0 C14,30 6,38 0,38 '
        f'C-6,38 -14,30 -20,0 Z" fill="{dark}" stroke="{INK}" stroke-width="4"/>')
    if spec.get("emblem"):
        add(f'<circle cx="0" cy="88" r="24" fill="{GOLD}" stroke="{INK}" stroke-width="5"/>')
        text(0, 98, spec["emblem"], size=27, fill=INK)

    add(f'<path d="M-19,-22 L-19,8 Q0,20 19,8 L19,-22 Z" fill="{skin}" stroke="{INK}" stroke-width="5"/>')

    hair = spec.get("hair")
    if hair == "long":
        for sx in (-1, 1):
            add(f'<path d="M{sx*46},-46 C{sx*64},4 {sx*60},46 {sx*50},66 L{sx*26},58 '
                f'C{sx*38},30 {sx*40},-6 {sx*34},-30 Z" fill="{spec["hairc"]}" stroke="{INK}" '
                f'stroke-width="5" stroke-linejoin="round"/>')
    elif hair == "flow":
        for sx in (-1, 1):
            add(f'<path d="M{sx*44},-58 C{sx*100},-32 {sx*96},36 {sx*64},74 L{sx*28},54 '
                f'C{sx*52},26 {sx*56},-16 {sx*34},-40 Z" fill="{spec["hairc"]}" stroke="{INK}" '
                f'stroke-width="5" stroke-linejoin="round"/>')
    elif hair == "fur":
        for a in range(-150, 151, 25):
            r = math.radians(a)
            x0, y0 = 40 * math.sin(r), -44 - 48 * math.cos(r)
            x1, y1 = 61 * math.sin(r), -44 - 71 * math.cos(r)
            add(f'<path d="M{x0:.1f},{y0:.1f} L{x1:.1f},{y1:.1f}" stroke="{spec["hairc"]}" '
                f'stroke-width="14" stroke-linecap="round"/>')

    if hair != "cowl":
        for sx in (-1, 1):
            add(f'<ellipse cx="{sx*41}" cy="-40" rx="9" ry="14" fill="{skin}" stroke="{INK}" stroke-width="4.5"/>')

    add(f'<ellipse cx="0" cy="-44" rx="42" ry="49" fill="{skin}" stroke="{INK}" stroke-width="6"/>')

    if hair == "fur":
        add(f'<path d="M-42,-56 q42,-34 84,0 q-6,-42 -42,-42 q-36,0 -42,42 z" fill="{spec["hairc"]}"/>')
        for sx in (-1, 1):
            add(f'<path d="M{sx*30},-78 L{sx*54},-118 L{sx*55},-68 Z" fill="{spec["hairc"]}" '
                f'stroke="{INK}" stroke-width="5" stroke-linejoin="round"/>')
    elif hair == "short":
        add(f'<path d="M-43,-52 q10,-44 43,-44 q33,0 43,44 q-16,-22 -43,-22 q-27,0 -43,22 z" '
            f'fill="{spec["hairc"]}" stroke="{INK}" stroke-width="5" stroke-linejoin="round"/>')
    elif hair in ("long", "flow"):
        add(f'<path d="M-44,-50 q8,-48 44,-48 q36,0 44,48 q-18,-26 -44,-26 q-26,0 -44,26 z" '
            f'fill="{spec["hairc"]}" stroke="{INK}" stroke-width="5" stroke-linejoin="round"/>')
    elif hair == "cowl":
        add(f'<path d="M-45,-42 q0,-54 45,-54 q45,0 45,54 l0,10 l-21,-6 '
            f'l-6,-24 l-36,0 l-6,24 l-21,6 z" fill="{spec["hairc"]}" stroke="{INK}" '
            f'stroke-width="5" stroke-linejoin="round"/>')
        for sx in (-1, 1):
            add(f'<path d="M{sx*34},-74 L{sx*78},-116 L{sx*59},-56 Z" fill="{spec["hairc"]}" '
                f'stroke="{INK}" stroke-width="5" stroke-linejoin="round"/>')
    elif hair == "band":
        add(f'<path d="M-44,-50 q8,-48 44,-48 q36,0 44,48 q-18,-26 -44,-26 q-26,0 -44,26 z" '
            f'fill="{spec["hairc"]}" stroke="{INK}" stroke-width="5" stroke-linejoin="round"/>')
        add(f'<path d="M-46,-68 q46,-22 92,0 l0,15 q-46,-22 -92,0 z" fill="{spec.get("bandc", GOLD)}" '
            f'stroke="{INK}" stroke-width="4.5"/>')

    mask = spec.get("mask")
    if mask == "visor":
        add(f'<path d="M-46,-58 q46,-12 92,0 l0,26 q-46,12 -92,0 z" fill="{DEEPRED}" '
            f'stroke="{INK}" stroke-width="5" stroke-linejoin="round"/>')
        add(f'<path d="M-34,-48 q34,-8 68,0" stroke="{CRIMSON}" stroke-width="8" fill="none" stroke-linecap="round"/>')
    elif mask == "lenses":
        add(f'<path d="M-41,-60 q41,-15 82,0 l0,24 q-41,13 -82,0 z" fill="{spec.get("maskc", INK)}" '
            f'stroke="{INK}" stroke-width="5" stroke-linejoin="round"/>')
        for sx in (-1, 1):
            add(f'<path d="M{sx*8},-53 q{sx*15},-6 {sx*26},1 q{sx*-3},15 {sx*-14},14 '
                f'q{sx*-11},-1 {sx*-12},-15 z" fill="{WHITE}" stroke="{INK}" stroke-width="3"/>')
    elif mask == "goggles":
        for sx in (-1, 1):
            add(f'<circle cx="{sx*19}" cy="-46" r="17" fill="{spec.get("maskc", "#bfe9ff")}" '
                f'stroke="{INK}" stroke-width="5"/>')
            add(f'<path d="M{sx*13},-53 q{sx*8},-4 {sx*12},3" stroke="{WHITE}" stroke-width="4.5" '
                f'fill="none" stroke-linecap="round"/>')
        add(f'<path d="M-4,-46 l8,0" stroke="{INK}" stroke-width="5"/>')
        add(f'<path d="M-36,-46 l-10,0 M36,-46 l10,0" stroke="{INK}" stroke-width="5" stroke-linecap="round"/>')
    elif mask == "bionic":
        add(f'<circle cx="19" cy="-46" r="16" fill="{GOLD}" stroke="{INK}" stroke-width="5"/>')
        add(f'<circle cx="19" cy="-46" r="6" fill="{CRIMSON}" stroke="{INK}" stroke-width="3"/>')
        add(f'<path d="M4,-46 l-10,0" stroke="{INK}" stroke-width="4" stroke-linecap="round"/>')
        add(f'<path d="M35,-46 l11,-3" stroke="{STEEL}" stroke-width="5" stroke-linecap="round"/>')

    if mask not in ("visor", "lenses", "goggles"):
        for sx in (-1, 1):
            if mask == "bionic" and sx > 0:
                continue
            add(f'<path d="M{sx*7},-61 q{sx*11},-6 {sx*21},-1" stroke="{INK}" stroke-width="4.5" '
                f'fill="none" stroke-linecap="round"/>')
            add(f'<ellipse cx="{sx*17}" cy="-46" rx="9" ry="7.5" fill="{WHITE}" stroke="{INK}" stroke-width="3.5"/>')
            add(f'<circle cx="{sx*17}" cy="-46" r="4" fill="{INK}"/>')

    if spec.get("beard"):
        add(f'<path d="M-34,-30 q4,42 34,42 q30,0 34,-42 q-14,26 -34,26 q-20,0 -34,-26 z" '
            f'fill="{spec["hairc"]}" stroke="{INK}" stroke-width="4.5" stroke-linejoin="round"/>')
    add(f'<path d="M-12,-16 q12,11 24,0" fill="none" stroke="{INK}" stroke-width="4" stroke-linecap="round"/>')
    if spec.get("fangs"):
        add(f'<path d="M-8,-13 l3.5,10 l3.5,-10 M1,-13 l3.5,10 l3.5,-10" fill="{WHITE}" stroke="{INK}" stroke-width="2.5"/>')
    if spec.get("headset"):
        add(f'<path d="M-53,-48 q0,-56 53,-56 q53,0 53,56" fill="none" stroke="{INK}" stroke-width="20" stroke-linecap="round"/>')
        add(f'<path d="M-53,-48 q0,-56 53,-56 q53,0 53,56" fill="none" stroke="{DEEPORANGE}" stroke-width="11" stroke-linecap="round"/>')
        for sx in (-1, 1):
            add(f'<rect x="{sx*53-9}" y="-62" width="18" height="32" rx="8" fill="{DEEPORANGE}" '
                f'stroke="{INK}" stroke-width="4.5"/>')
        add(f'<path d="M53,-30 q0,27 -27,29" fill="none" stroke="{INK}" stroke-width="4.5"/>')
        add(f'<circle cx="22" cy="-1" r="6" fill="{INK}"/>')
    add("</g>")


def medallion(cx, cy, r, spec):
    """A bust inside a ringed disc with a starburst behind it."""
    s = r / 106.0
    burst(cx, cy, r * 1.32, spec["dark"], spikes=19, inner=0.86, rot=0.08)
    burst(cx, cy, r * 1.23, spec["suit"], spikes=19, inner=0.84, rot=0.08, stroke=INK, sw=4)
    cid = f"clip-{spec['key']}-{int(cx)}"
    add(f'<circle cx="{cx}" cy="{cy+8}" r="{r}" fill="{INK}" opacity="0.9"/>')
    add(f'<clipPath id="{cid}"><circle cx="{cx}" cy="{cy}" r="{r-4}"/></clipPath>')
    add(f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="#fffaf0"/>')
    add(f'<g clip-path="url(#{cid})">')
    add(f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="url(#sky-{spec["key"]})"/>')
    add(f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="url(#halftone)"/>')
    bust(cx, cy + r * 0.30, s, spec)
    add("</g>")
    add(f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="{INK}" stroke-width="7"/>')


def plate(cx, y, name, role, ask, colour, w, nsize=27):
    """Name, role, and - for an agent - the one thing it comes to the navigator for."""
    h = 88 if ask else 64
    add(f'<rect x="{cx-w//2+9}" y="{y+9}" width="{w}" height="{h}" rx="11" fill="{INK}" opacity="0.9"/>')
    add(f'<rect x="{cx-w//2}" y="{y}" width="{w}" height="{h}" rx="11" fill="{colour}" stroke="{INK}" stroke-width="5"/>')
    text(cx, y + 32, name, size=nsize, fill=WHITE, spacing=0.8)
    text(cx, y + 52, role, size=11.5, fill=WHITE, family="body", weight=800, spacing=1.5)
    if ask:
        add(f'<path d="M{cx-w//2+16},{y+62} l{w-32},0" stroke="{WHITE}" stroke-width="2.5" opacity="0.5"/>')
        text(cx, y + 80, ask, size=14, fill=CREAM, family="body", weight=800, spacing=0.2)


def balloon(x, y, s, colour=INK, size=15, fill="#fffdf4"):
    w = int(size * 0.62 * len(s)) + 30
    h = size + 18
    add(f'<rect x="{x-w//2+5}" y="{y-h//2+5}" width="{w}" height="{h}" rx="{h//2}" fill="{INK}" opacity="0.3"/>')
    add(f'<rect x="{x-w//2}" y="{y-h//2}" width="{w}" height="{h}" rx="{h//2}" fill="{fill}" '
        f'stroke="{colour}" stroke-width="4"/>')
    text(x, y + size * 0.37, s, size=size, fill=INK, family="body", weight=800, spacing=0.2)


def chip(x, y, title, fill, w=152):
    add(f'<rect x="{x-w//2+7}" y="{y-18}" width="{w}" height="50" rx="10" fill="{INK}" opacity="0.9"/>')
    add(f'<rect x="{x-w//2}" y="{y-25}" width="{w}" height="50" rx="10" fill="{fill}" stroke="{INK}" stroke-width="5"/>')
    text(x, y + 8, title, size=21, spacing=0.8)


def caption(x, y, w, head, lines, fill=GOLD):
    h = 34 + 21 * len(lines)
    add(f'<rect x="{x+7}" y="{y+7}" width="{w}" height="{h}" rx="6" fill="{INK}" opacity="0.9"/>')
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{fill}" stroke="{INK}" stroke-width="5"/>')
    text(x + w // 2, y + 28, head, size=20, spacing=0.8)
    for i, ln in enumerate(lines):
        text(x + w // 2, y + 50 + 21 * i, ln, size=13.5, family="body", weight=800, spacing=0.2)


def arrow(d, colour=INK, width=7, dash=None, marker="end"):
    dashes = f' stroke-dasharray="{dash}"' if dash else ""
    me = f' marker-end="url(#head-{colour[1:]})"' if marker in ("end", "both") else ""
    ms = f' marker-start="url(#tail-{colour[1:]})"' if marker in ("start", "both") else ""
    add(f'<path d="{d}" fill="none" stroke="{INK}" stroke-width="{width+6}" stroke-linecap="round"{dashes} opacity="0.9"/>')
    add(f'<path d="{d}" fill="none" stroke="{colour}" stroke-width="{width}" stroke-linecap="round"{dashes}{me}{ms}/>')


# ------------------------------------------------------------------ the cast
CAST = {
    "moira": dict(key="moira", name="MOIRA", suit=ORANGE, dark=DEEPORANGE, skin=SKIN[0],
                  hair="long", hairc="#c1440e", headset=True, emblem="M"),
    "xavier": dict(key="xavier", name="XAVIER", suit=CRIMSON, dark=DEEPRED, skin=SKIN[0],
                   hair=None, hairc=INK, emblem="X"),
    "beast": dict(key="beast", name="BEAST", suit=COBALT, dark=NAVY, skin=FUR,
                  hair="fur", hairc="#2f5fb8", fangs=True, emblem="B"),
    "cyclops": dict(key="cyclops", name="CYCLOPS", suit=CRIMSON, dark=DEEPRED, skin=SKIN[1],
                    hair="short", hairc="#6b3a1a", mask="visor"),
    "storm": dict(key="storm", name="STORM", suit=PURPLE, dark=DEEPPURPLE, skin=SKIN[3],
                  hair="flow", hairc="#f4f4f4"),
    "wolvie": dict(key="wolvie", name="WOLVERINE", suit=GOLD, dark=AMBER, skin=SKIN[1],
                   hair="cowl", hairc=NAVY, mask="lenses", maskc=NAVY),
    "psylocke": dict(key="psylocke", name="PSYLOCKE", suit=PURPLE, dark=DEEPPURPLE, skin=SKIN[0],
                     hair="band", hairc="#8b4fd0", bandc=GOLD, mask="lenses", maskc=DEEPPURPLE, emblem="P"),
    "forge": dict(key="forge", name="FORGE", suit=TEAL, dark=DEEPTEAL, skin=SKIN[2],
                  hair="band", hairc="#2b1a12", bandc=CRIMSON, mask="bionic", beard=True, emblem="F"),
    "cypher": dict(key="cypher", name="CYPHER", suit=GREEN, dark=DEEPGREEN, skin=SKIN[0],
                   hair="short", hairc="#e8c25a", mask="goggles", maskc="#9fe0ff", emblem="Y"),
    "nav": dict(key="nav", name="YOU", suit=COBALT, dark=NAVY, skin=SKIN[1],
                hair="short", hairc="#3a2a1c"),
}

# ------------------------------------------------------------------ canvas
add("<!-- Generated by docs/cerebro-fleet.py - edit that, not this file. -->")
add(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" '
    f'aria-label="Comic cover of the Cerebro fleet: the navigator at the centre with a beam to every '
    f'agent, six agent roles and twelve implementers standing on the bead board, and every handover '
    f'between agents a label on a bead rather than a conversation">')
add("<defs>")
add(f'<pattern id="halftone" width="16" height="16" patternUnits="userSpaceOnUse">'
    f'<circle cx="4" cy="4" r="2" fill="{INK}" opacity="0.13"/></pattern>')
add('<radialGradient id="page" cx="50%" cy="46%" r="70%">'
    f'<stop offset="0%" stop-color="#fffbf0"/><stop offset="100%" stop-color="{PAPER}"/></radialGradient>')
for v in CAST.values():
    add(f'<radialGradient id="sky-{v["key"]}" cx="50%" cy="28%" r="82%">'
        f'<stop offset="0%" stop-color="#fffdf6"/><stop offset="100%" stop-color="{v["suit"]}" stop-opacity="0.40"/>'
        f'</radialGradient>')
for c in (INK, CRIMSON, COBALT, TEAL, PURPLE, ORANGE, GOLD, GREEN, SLATE, DEEPRED):
    add(f'<marker id="head-{c[1:]}" viewBox="0 0 12 12" refX="9" refY="6" markerWidth="5.5" markerHeight="5.5" orient="auto">'
        f'<path d="M0,0 L12,6 L0,12 z" fill="{c}"/></marker>')
    add(f'<marker id="tail-{c[1:]}" viewBox="0 0 12 12" refX="3" refY="6" markerWidth="5.5" markerHeight="5.5" orient="auto">'
        f'<path d="M12,0 L0,6 L12,12 z" fill="{c}"/></marker>')
add("</defs>")

add(f'<rect width="{W}" height="{H}" fill="url(#page)"/>')
for i in range(-16, 17):
    add(f'<path d="M{CX},{CY} l{i*150},-1600" stroke="{GOLD}" stroke-width="{3 if i % 2 else 7}" opacity="0.16"/>')
    add(f'<path d="M{CX},{CY} l{i*150},1600" stroke="{GOLD}" stroke-width="{3 if i % 2 else 7}" opacity="0.16"/>')
add(f'<rect width="{W}" height="{H}" fill="url(#halftone)"/>')
add(f'<rect x="20" y="20" width="{W-40}" height="{H-40}" fill="none" stroke="{INK}" stroke-width="13" rx="8"/>')
add(f'<rect x="42" y="42" width="{W-84}" height="{H-84}" fill="none" stroke="{INK}" stroke-width="3" rx="5"/>')

# ------------------------------------------------------------------ masthead
add(f'<path d="M60,54 l1980,0 l-22,126 l-1936,0 z" fill="{CRIMSON}" stroke="{INK}" stroke-width="7" stroke-linejoin="round"/>')
add(f'<path d="M60,54 l1980,0 l-6,32 l-1968,0 z" fill="{DEEPRED}" opacity="0.55"/>')
text(1094, 152, "THE CEREBRO FLEET", size=70, fill=GOLD, spacing=5)
add(f'<rect x="78" y="66" width="152" height="104" rx="6" fill="{INK}"/>')
text(154, 104, "No. 1", size=30, fill=GOLD, spacing=1)
text(154, 130, "ALL-NEW", size=14, fill=WHITE, family="body", weight=800, spacing=1.2)
text(154, 154, "ALL-AGENTIC", size=14, fill=WHITE, family="body", weight=800, spacing=1.2)
burst(1952, 116, 86, GOLD, spikes=13, inner=0.7, rot=0.2, stroke=INK, sw=5)
text(1952, 100, "7 ROLES", size=20, spacing=0.5)
text(1952, 122, "12 BUILDERS", size=16, spacing=0.5)
text(1952, 144, "1 HUMAN", size=20, fill=DEEPRED, spacing=0.5)

# ------------------------------------------------------------------ the bead board they all stand on
quiet = arc_path(160, 302)
board = arc_path(298, 522)
add(f'<path d="{quiet}" fill="none" stroke="{INK}" stroke-width="40" stroke-linecap="round"/>')
add(f'<path d="{quiet}" fill="none" stroke="#e9c96a" stroke-width="28" stroke-linecap="round"/>')
add(f'<path d="{board}" fill="none" stroke="{INK}" stroke-width="48" stroke-linecap="round"/>')
add(f'<path d="{board}" fill="none" stroke="{GOLD}" stroke-width="36" stroke-linecap="round"/>')
add(f'<path d="{board}" fill="none" stroke="#fff3c6" stroke-width="12" stroke-linecap="round" opacity="0.85"/>')
for a in (313, 353, 400, 452, 500):
    x0, y0 = pt(a - 4)
    x1, y1 = pt(a + 4)
    add(f'<path d="M{x0:.1f},{y0:.1f} L{x1:.1f},{y1:.1f}" stroke="{INK}" stroke-width="8" '
        f'marker-end="url(#head-{INK[1:]})"/>')

# a failed verdict, sent round again below and up the right-hand margin - drawn behind everything
arrow("M1392,1152 C1570,1272 1860,1296 1998,1152 C2062,1010 2010,690 1902,596", CRIMSON, 7, dash="17 12")

# what Forge files, cutting up the left-hand corridor to the unplanned end of the board
arrow("M968,1064 C706,1004 606,752 742,462", PURPLE, 6, dash="15 10")

# ------------------------------------------------------------------ the beads on the board
chip(*pt(337), "UNPLANNED", "#efe2c6")
chip(*pt(23), "PLANNED", "#c3e9cf")
chip(*pt(90), "MERGED", "#c6dcf7")
vx, vy = pt(158)
burst(vx, vy, 78, GREEN, spikes=15, inner=0.8, stroke=INK, sw=5)
text(vx, vy - 2, "VERIFIED", size=23, fill=WHITE, spacing=0.6)
text(vx, vy + 22, "a person saw it work", size=11.5, fill=WHITE, family="body", weight=800)

# the board's own nameplate, on the quiet stretch of track where nothing is handed over
bdx, bdy = pt(270)
add(f'<rect x="{bdx-100:.0f}" y="{bdy-40:.0f}" width="200" height="80" rx="12" fill="{GOLD}" stroke="{INK}" stroke-width="6"/>')
text(bdx, bdy - 6, "bd", size=34, spacing=1)
text(bdx, bdy + 22, "THE BEAD BOARD", size=13.5, family="body", weight=800, spacing=0.6)

# ------------------------------------------------------------------ the navigator's beams
NODE_XY = {"planners": (CX, 400), "forge": (CX, 1150),
           "moira": pt(305), "implementers": pt(55), "psylocke": pt(125), "cypher": pt(235)}
for kind, (nx, ny) in NODE_XY.items():
    ux, uy = nx - CX, ny - CY
    d = math.hypot(ux, uy)
    arrow(f"M{CX + ux/d*152:.1f},{CY + uy/d*152:.1f} L{nx - ux/d*130:.1f},{ny - uy/d*130:.1f}",
          CRIMSON, 8, marker="both")

# ------------------------------------------------------------------ the navigator
burst(CX, CY, 168, GOLD, spikes=21, inner=0.83, rot=0.13, stroke=INK, sw=5)
burst(CX, CY, 144, "#fff6d2", spikes=21, inner=0.85, rot=0.13)
bust(CX, CY + 44, 0.80, CAST["nav"])
add(f'<path d="M{CX-56},{CY-40} q56,-62 112,0 l0,22 q-56,-46 -112,0 z" fill="{COBALT}" '
    f'stroke="{INK}" stroke-width="6" stroke-linejoin="round"/>')
add(f'<path d="M{CX-40},{CY-52} q40,-34 80,0" fill="none" stroke="{GOLD}" stroke-width="6" stroke-linecap="round"/>')
for sx in (-1, 1):
    add(f'<path d="M{CX+sx*54},{CY-40} l{sx*16},10" stroke="{INK}" stroke-width="7"/>')
    add(f'<circle cx="{CX+sx*74}" cy="{CY-32}" r="21" fill="{SLATE}" stroke="{INK}" stroke-width="6"/>')
    add(f'<circle cx="{CX+sx*74}" cy="{CY-32}" r="8" fill="{GOLD}" stroke="{INK}" stroke-width="3"/>')
plate(CX, CY + 96, "THE NAVIGATOR", "YOU — AND THERE IS ONLY ONE OF YOU",
      "M-x cerebro · the fleet view is his console", COBALT, w=408, nsize=30)

# ------------------------------------------------------------------ the six around him
mx, my = NODE_XY["moira"]
medallion(mx, my, 92, CAST["moira"])
plate(mx, my - 219, "MOIRA", "USER FEEDBACK · THE ISSUE INBOX", "“bead it, ask them, or close it?”",
      ORANGE, w=372)

px, py = NODE_XY["planners"]
medallion(px - 96, py, 84, CAST["xavier"])
medallion(px + 96, py, 84, CAST["beast"])
plate(px, py - 209, "XAVIER & BEAST", "PLANNERS · THEY TURN WANTS INTO PLANS",
      "“here are two mockups — which one?”", CRIMSON, w=392)

ix, iy = NODE_XY["implementers"]
for j, who in enumerate(("cyclops", "storm", "wolvie")):
    medallion(ix - 122 + j * 122, iy, 76, CAST[who])
burst(ix + 186, iy - 76, 48, CRIMSON, spikes=13, inner=0.68, rot=0.3, stroke=INK, sw=4)
text(ix + 186, iy - 67, "x12", size=28, fill=WHITE, spacing=0.5)
plate(ix, iy - 219, "THE X-MEN", "IMPLEMENTERS · ONE BEAD EACH, THEN A FRESH SESSION",
      "“only you can answer this one”", SLATE, w=452)

sx_, sy_ = NODE_XY["psylocke"]
medallion(sx_, sy_, 92, CAST["psylocke"])
plate(sx_, sy_ + 131, "PSYLOCKE", "VERIFIER · SHE PUTS IT IN FRONT OF YOU",
      "“it is running — passed or failed?”", PURPLE, w=384)

fx_, fy_ = NODE_XY["forge"]
medallion(fx_, fy_, 88, CAST["forge"])
plate(fx_, fy_ + 126, "FORGE", "ARCHITECT · HE READS THE SHAPE OF THE CODE",
      "“this is what it is costing you”", TEAL, w=414)

cx_, cy_ = NODE_XY["cypher"]
medallion(cx_, cy_, 92, CAST["cypher"])
plate(cx_, cy_ + 131, "CYPHER", "REVIEWER · PULL REQUESTS FROM OUTSIDE",
      "“reviewed. you decide if it lands”", GREEN, w=384)

# ------------------------------------------------------------------ labels that ride on top
balloon(654, 830, "Refactoring: P4", PURPLE, 15)
balloon(1706, 1292, "FAILED — REOPENED AT P0", CRIMSON, 15)


# ------------------------------------------------------------------ the world outside the fleet
def outsider(ox, oy, title, colour, glyph, gsize=46):
    burst(ox, oy - 4, 68, colour, spikes=13, inner=0.74, rot=0.25, stroke=INK, sw=4, opacity=0.55)
    add(f'<circle cx="{ox}" cy="{oy}" r="53" fill="#fffaf0" stroke="{INK}" stroke-width="6"/>')
    text(ox, oy + gsize * 0.36, glyph, size=gsize, fill=colour)
    add(f'<rect x="{ox-98}" y="{oy+64}" width="196" height="36" rx="8" fill="#fffdf4" stroke="{INK}" stroke-width="4"/>')
    text(ox, oy + 89, title, size=14, family="body", weight=800, spacing=0.4)


outsider(160, 404, "ANYONE WITH AN ISSUE", ORANGE, "!", 54)
arrow(f"M216,440 C300,490 320,502 {mx-110:.0f},{my-48:.0f}", ORANGE, 6)
outsider(160, 1136, "ANYONE WITH A PATCH", GREEN, "</>", 34)
arrow(f"M216,1098 C300,1052 320,1040 {cx_-110:.0f},{cy_+44:.0f}", GREEN, 6)

# ------------------------------------------------------------------ the two rules that make it make sense
caption(74, 198, 390, "NO AGENT TALKS TO ANOTHER",
        ["Every handover is a label on a bead.", "The board is the only channel they share."])
caption(1636, 198, 390, "ONE HUMAN, EVERY TIME",
        ["Only he starts or stops a session —", "and anything a player sees is his call."])

# ------------------------------------------------------------------ footer
add(f'<path d="M60,1376 l1980,0 l-16,60 l-1948,0 z" fill="{INK}"/>')
text(1050, 1418, "CLOSED IS NOT TERMINAL — A FAILED VERDICT REOPENS THE BEAD AT P0 AND SENDS IT ROUND AGAIN",
     size=24, fill=GOLD, spacing=1.4)

add("</svg>")
svg = "\n".join(out)
target = pathlib.Path("docs/cerebro-fleet.svg")
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(svg)
print("wrote", target, len(svg), "bytes")
