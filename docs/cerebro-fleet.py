#!/usr/bin/env python3
"""Generate docs/cerebro-fleet.svg - a comic-panel picture of the Cerebro fleet.

    python3 docs/cerebro-fleet.py          # from the repository root

The picture is generated rather than hand-drawn because the fleet changes: a role added to
`scripts/roster` is a line here, not an afternoon in an SVG editor. Nothing runs this
automatically - regenerate it when a role, a flow or a name changes, and commit both files.

To look at the result: `rsvg-convert -w 1400 docs/cerebro-fleet.svg -o /tmp/fleet.png`, or just
open the SVG in a browser.
"""
import pathlib

W, H = 1860, 1320
INK = "#17130f"
PAPER = "#f7ecd6"
CRIMSON = "#d7263d"
GOLD = "#f2b705"
COBALT = "#2f6fd0"
TEAL = "#159a8c"
PURPLE = "#7048a8"
ORANGE = "#ee6a2b"
SLATE = "#3d4d63"
SKIN = "#f2c39b"
SKIN2 = "#cf9463"

out = []
add = out.append
HDR = "'Bangers','Luckiest Guy','Impact','Haettenschweiler','Arial Black',sans-serif"
BODY = "'Avenir Next','Helvetica Neue',Helvetica,Arial,sans-serif"


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, size=22, weight=700, fill=INK, anchor="middle", family="hdr", spacing=0):
    fam = HDR if family == "hdr" else BODY
    add(f'<text x="{x}" y="{y}" font-family="{fam}" font-size="{size}" font-weight="{weight}" '
        f'fill="{fill}" text-anchor="{anchor}" letter-spacing="{spacing}">{esc(s)}</text>')


def plate(cx, y, name, role, colour, w=None):
    if role is None:                      # name-only plate, for the small squad figures
        w = w or max(150, int(15 * len(name)) + 30)
        add(f'<rect x="{cx-w//2+7}" y="{y+7}" width="{w}" height="44" rx="10" fill="{INK}" opacity="0.85"/>')
        add(f'<rect x="{cx-w//2}" y="{y}" width="{w}" height="44" rx="10" fill="{colour}" stroke="{INK}" stroke-width="4"/>')
        text(cx, y + 32, name, size=26, fill="#fff", spacing=0.8)
        return
    w = w or max(176, int(13.5 * len(name)) + 34, int(8.4 * len(role)) + 34)
    add(f'<rect x="{cx-w//2+7}" y="{y+7}" width="{w}" height="58" rx="10" fill="{INK}" opacity="0.85"/>')
    add(f'<rect x="{cx-w//2}" y="{y}" width="{w}" height="58" rx="10" fill="{colour}" stroke="{INK}" stroke-width="4"/>')
    text(cx, y + 27, name, size=23, fill="#fff", spacing=0.8)
    text(cx, y + 47, role, size=12.5, fill="#fff", family="body", weight=800, spacing=1.4)


def hero(cx, cy, name, role, suit, cape, emblem):
    """A caped figure with a chest emblem and a name plate under it."""
    add(f'<path d="M{cx-54},{cy-28} q-36,62 -24,120 l156,0 q12,-58 -24,-120 z" '
        f'fill="{cape}" stroke="{INK}" stroke-width="5" stroke-linejoin="round"/>')
    for sx in (-27, 27):
        add(f'<path d="M{cx+sx},{cy+52} l0,44" stroke="{INK}" stroke-width="18" stroke-linecap="round"/>')
        add(f'<path d="M{cx+sx},{cy+52} l0,42" stroke="{suit}" stroke-width="9" stroke-linecap="round"/>')
    add(f'<path d="M{cx-39},{cy-26} q39,-15 78,0 l9,54 q-48,21 -96,0 z" '
        f'fill="{suit}" stroke="{INK}" stroke-width="5" stroke-linejoin="round"/>')
    for s in (-1, 1):
        add(f'<path d="M{cx+40*s},{cy-16} q{34*s},18 {30*s},54" fill="none" stroke="{INK}" stroke-width="17" stroke-linecap="round"/>')
        add(f'<path d="M{cx+40*s},{cy-16} q{34*s},18 {30*s},54" fill="none" stroke="{suit}" stroke-width="8" stroke-linecap="round"/>')
    add(f'<circle cx="{cx}" cy="{cy+4}" r="18" fill="{GOLD}" stroke="{INK}" stroke-width="4"/>')
    text(cx, cy + 12, emblem, size=21, fill=INK)
    add(f'<circle cx="{cx}" cy="{cy-54}" r="28" fill="{SKIN}" stroke="{INK}" stroke-width="5"/>')
    add(f'<path d="M{cx-28},{cy-62} q28,-19 56,0 l0,15 q-28,11 -56,0 z" fill="{cape}" stroke="{INK}" stroke-width="4"/>')
    add(f'<circle cx="{cx-10}" cy="{cy-56}" r="3.8" fill="{INK}"/>')
    add(f'<circle cx="{cx+10}" cy="{cy-56}" r="3.8" fill="{INK}"/>')
    add(f'<path d="M{cx-10},{cy-38} q10,8 20,0" fill="none" stroke="{INK}" stroke-width="3.6" stroke-linecap="round"/>')
    plate(cx, cy + 108, name, role, suit)


def human(cx, cy, title, colour, prop):
    """A plain figure - no cape - with the prop that says which job they do."""
    add(f'<path d="M{cx-48},{cy+96} q0,-66 48,-66 q48,0 48,66 z" fill="{colour}" stroke="{INK}" stroke-width="5" stroke-linejoin="round"/>')
    add(f'<path d="M{cx},{cy+30} l0,66" stroke="{INK}" stroke-width="4"/>')
    add(f'<circle cx="{cx}" cy="{cy-8}" r="31" fill="{SKIN2}" stroke="{INK}" stroke-width="5"/>')
    add(f'<path d="M{cx-31},{cy-16} q31,-32 62,0 q-5,-32 -31,-32 q-26,0 -31,32 z" fill="{INK}"/>')
    add(f'<circle cx="{cx-11}" cy="{cy-6}" r="3.8" fill="{INK}"/>')
    add(f'<circle cx="{cx+11}" cy="{cy-6}" r="3.8" fill="{INK}"/>')
    add(f'<path d="M{cx-10},{cy+12} q10,9 20,0" fill="none" stroke="{INK}" stroke-width="3.6" stroke-linecap="round"/>')

    px, py = cx + 58, cy + 46
    if prop == "roadmap":
        add(f'<rect x="{px-30}" y="{py-26}" width="64" height="48" rx="5" fill="#fff" stroke="{INK}" stroke-width="4"/>')
        add(f'<path d="M{px-20},{py+10} l16,-20 l13,11 l17,-24" fill="none" stroke="{CRIMSON}" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>')
    elif prop == "clipboard":
        add(f'<rect x="{px-26}" y="{py-28}" width="56" height="54" rx="5" fill="#fff" stroke="{INK}" stroke-width="4"/>')
        add(f'<rect x="{px-10}" y="{py-35}" width="24" height="13" rx="3" fill="{SLATE}" stroke="{INK}" stroke-width="3"/>')
        for dy in (-12, 1, 14):
            add(f'<path d="M{px-16},{py+dy} l36,0" stroke="{INK}" stroke-width="3.6" stroke-linecap="round"/>')
    elif prop == "blueprint":
        add(f'<rect x="{px-30}" y="{py-26}" width="64" height="48" rx="4" fill="{COBALT}" stroke="{INK}" stroke-width="4"/>')
        add(f'<path d="M{px-19},{py+10} l0,-24 l19,0 l0,24 M{px+3},{py+10} l0,-15 l19,0 l0,15" fill="none" stroke="#fff" stroke-width="3.4"/>')
    elif prop == "magnifier":
        add(f'<circle cx="{px-2}" cy="{py-12}" r="22" fill="#fff" stroke="{INK}" stroke-width="5"/>')
        add(f'<path d="M{px+13},{py+4} l18,18" stroke="{INK}" stroke-width="8" stroke-linecap="round"/>')
        add(f'<path d="M{px-13},{py-12} l9,10 l15,-17" fill="none" stroke="{TEAL}" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>')
    elif prop == "headset":
        add(f'<path d="M{cx-36},{cy-10} q0,-32 36,-32 q36,0 36,32" fill="none" stroke="{INK}" stroke-width="6"/>')
        for sx in (-45, 27):
            add(f'<rect x="{cx+sx}" y="{cy-12}" width="18" height="28" rx="7" fill="{ORANGE}" stroke="{INK}" stroke-width="4"/>')
        add(f'<path d="M{cx+36},{cy+16} q0,22 -22,22" fill="none" stroke="{INK}" stroke-width="4"/>')
        add(f'<circle cx="{cx+12}" cy="{cy+38}" r="5.5" fill="{INK}"/>')
    add(f'<rect x="{cx-104}" y="{cy+112}" width="208" height="34" rx="8" fill="#fff" stroke="{INK}" stroke-width="4"/>')
    text(cx, cy + 136, title, size=16, fill=INK, spacing=0.7)


def arrow(d, colour=INK, width=6, label=None, lx=0, ly=0, dash=None, marker="end"):
    dashes = f' stroke-dasharray="{dash}"' if dash else ""
    me = f' marker-end="url(#head-{colour[1:]})"' if marker in ("end", "both") else ""
    ms = f' marker-start="url(#tail-{colour[1:]})"' if marker in ("start", "both") else ""
    add(f'<path d="{d}" fill="none" stroke="{colour}" stroke-width="{width}" stroke-linecap="round"{dashes}{me}{ms}/>')
    if label:
        w = int(8.0 * len(label)) + 22
        add(f'<rect x="{lx-w//2}" y="{ly-16}" width="{w}" height="29" rx="14" fill="#fffdf6" stroke="{colour}" stroke-width="3"/>')
        text(lx, ly + 5, label, size=14.5, fill=INK, family="body", weight=800, spacing=0.3)


# ---------------------------------------------------------------- canvas
add("<!-- Generated by docs/cerebro-fleet.py - edit that, not this file. -->")
add(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
    f'role="img" aria-label="The Cerebro fleet: five human roles, six agent roles, the bead board and the fleet view">')
add("<defs>")
add(f'<pattern id="halftone" width="18" height="18" patternUnits="userSpaceOnUse">'
    f'<circle cx="4" cy="4" r="2.2" fill="{INK}" opacity="0.10"/></pattern>')
add('<radialGradient id="burst" cx="52%" cy="40%" r="66%">'
    f'<stop offset="0%" stop-color="#fffaee"/><stop offset="100%" stop-color="{PAPER}"/></radialGradient>')
for c in (INK, CRIMSON, COBALT, TEAL, PURPLE, ORANGE, GOLD, SLATE):
    add(f'<marker id="head-{c[1:]}" viewBox="0 0 12 12" refX="9.5" refY="6" markerWidth="6" markerHeight="6" orient="auto">'
        f'<path d="M0,0 L12,6 L0,12 z" fill="{c}"/></marker>')
    add(f'<marker id="tail-{c[1:]}" viewBox="0 0 12 12" refX="2.5" refY="6" markerWidth="6" markerHeight="6" orient="auto">'
        f'<path d="M12,0 L0,6 L12,12 z" fill="{c}"/></marker>')
add("</defs>")

add(f'<rect width="{W}" height="{H}" fill="url(#burst)"/>')
for i in range(-10, 11):
    add(f'<path d="M980,640 l{i*140},-1200" stroke="{GOLD}" stroke-width="{3 if i % 2 else 6}" opacity="0.13"/>')
add(f'<rect width="{W}" height="{H}" fill="url(#halftone)"/>')
add(f'<rect x="24" y="24" width="{W-48}" height="{H-48}" fill="none" stroke="{INK}" stroke-width="12" rx="8"/>')
add(f'<rect x="44" y="44" width="{W-88}" height="{H-88}" fill="none" stroke="{INK}" stroke-width="3" rx="5"/>')

# ---------------------------------------------------------------- title
add(f'<path d="M64,66 l1732,0 l-24,92 l-1684,0 z" fill="{CRIMSON}" stroke="{INK}" stroke-width="6" stroke-linejoin="round"/>')
text(930, 128, "THE CEREBRO FLEET", size=58, fill="#fff", spacing=4)
text(930, 186, "six agent roles, one bead board, and the humans they answer to",
     size=20, family="body", weight=800, fill=INK, spacing=1.4)

# ---------------------------------------------------------------- the five pairs
PAIRS = [
    (300, "CUSTOMER SUPPORT", ORANGE, "headset", "MOIRA", "USER FEEDBACK", ORANGE, "#a8431a", "M",
     "issues in, answers out"),
    (480, "PRODUCT MANAGER", CRIMSON, "roadmap", "XAVIER + BEAST", "PLANNERS", CRIMSON, "#8c1226", "X",
     "priorities + every UI call"),
    (660, "PROJECT MANAGER", COBALT, "clipboard", "CEREBRO", "ORCHESTRATOR", COBALT, "#1b4b96", "C",
     "fleet health, releases"),
    (840, "ARCHITECT", PURPLE, "blueprint", "FORGE", "ARCHITECT", PURPLE, "#4a2e75", "F",
     "code-shape findings"),
    (1020, "QUALITY ASSURANCE", TEAL, "magnifier", "PSYLOCKE", "VERIFIER", TEAL, "#0c6b61", "P",
     "the verdict: pass or fail"),
]
SC = 0.52
HX, AX = 190, 560          # human / agent centres, in page coordinates

for (cy, htitle, hcol, prop, aname, arole, suit, cape, emblem, label) in PAIRS:
    add(f'<g transform="translate({HX},{cy}) scale({SC})">')
    human(0, 0, htitle, hcol, prop)
    add("</g>")
    add(f'<g transform="translate({AX},{cy}) scale({SC})">')
    hero(0, 0, aname, arole, suit, cape, emblem)
    add("</g>")
    arrow(f"M{HX+72},{cy-6} L{AX-72},{cy-6}", hcol, 6, label, (HX + AX) // 2, cy - 22, marker="both")

# ---------------------------------------------------------------- the bead board
BX, BY, BW, BH = 800, 250, 300, 850
add(f'<rect x="{BX+10}" y="{BY+10}" width="{BW}" height="{BH}" rx="16" fill="{INK}" opacity="0.85"/>')
add(f'<rect x="{BX}" y="{BY}" width="{BW}" height="{BH}" rx="16" fill="#fffdf3" stroke="{INK}" stroke-width="7"/>')
add(f'<rect x="{BX}" y="{BY}" width="{BW}" height="74" rx="16" fill="{GOLD}" stroke="{INK}" stroke-width="7"/>')
text(BX + BW // 2, BY + 50, "THE BEAD BOARD", size=27, spacing=1)
text(BX + BW // 2, BY + 104, "bd — one queue, every agent reads it", size=13.5, family="body", weight=800, spacing=0.4)
CARDS = [
    ("UNPLANNED", "filed by anyone", "#efe4cd"),
    ("PLANNING", "a planner holds it", CRIMSON + "33"),
    ("PLANNED", "ready to build", "#cde9d5"),
    ("CLAIMED", "an implementer has it", "#cfe0f7"),
    ("MERGED", "waiting on a verdict", "#d6f0ec"),
    ("VERIFIED", "or reopened at P0", "#e6dcf5"),
]
for i, (t1, t2, col) in enumerate(CARDS):
    yy = BY + 136 + i * 116
    add(f'<rect x="{BX+26}" y="{yy}" width="{BW-52}" height="86" rx="10" fill="{col}" stroke="{INK}" stroke-width="4"/>')
    text(BX + BW // 2, yy + 36, t1, size=21, spacing=0.8)
    text(BX + BW // 2, yy + 62, t2, size=13, family="body", weight=700, spacing=0.2)
    if i < len(CARDS) - 1:
        add(f'<path d="M{BX+BW//2},{yy+88} l0,22" stroke="{INK}" stroke-width="5" marker-end="url(#head-{INK[1:]})"/>')

# ---------------------------------------------------------------- the implementer squad
SX, SY, SW, SH = 1230, 250, 570, 470
add(f'<rect x="{SX+10}" y="{SY+10}" width="{SW}" height="{SH}" rx="16" fill="{INK}" opacity="0.85"/>')
add(f'<rect x="{SX}" y="{SY}" width="{SW}" height="{SH}" rx="16" fill="#fff7e3" stroke="{INK}" stroke-width="7"/>')
add(f'<rect x="{SX}" y="{SY}" width="{SW}" height="74" rx="16" fill="{SLATE}" stroke="{INK}" stroke-width="7"/>')
text(SX + SW // 2, SY + 50, "THE IMPLEMENTERS  ×12", size=27, fill="#fff", spacing=1)
SQUAD = [("CYCLOPS", "#c0392b"), ("STORM", "#8e44ad"), ("ROGUE", "#16a085"), ("GAMBIT", "#e08e0b")]
for i, (nm, col) in enumerate(SQUAD):
    add(f'<g transform="translate({SX+82+i*134},{SY+232}) scale(0.46)">')
    hero(0, 0, nm, None, col, INK, nm[0])
    add("</g>")
text(SX + SW // 2, SY + 392, "claim one bead · build it test-first in its own worktree",
     size=15, family="body", weight=800, spacing=0.3)
text(SX + SW // 2, SY + 420, "open the PR · answer Copilot · merge green · report done",
     size=15, family="body", weight=800, spacing=0.3)
text(SX + SW // 2, SY + 448, "then the fleet view retires it and starts a fresh session",
     size=15, family="body", weight=800, fill=CRIMSON, spacing=0.3)

# ---------------------------------------------------------------- the fleet view
FX, FY, FW, FH = 1230, 790, 570, 310
add(f'<rect x="{FX+10}" y="{FY+10}" width="{FW}" height="{FH}" rx="16" fill="{INK}" opacity="0.85"/>')
add(f'<rect x="{FX}" y="{FY}" width="{FW}" height="{FH}" rx="16" fill="{INK}" stroke="{INK}" stroke-width="7"/>')
text(FX + FW // 2, FY + 46, "M-x cerebro — THE FLEET VIEW", size=24, fill=GOLD, spacing=1)
ROWS_UI = [("XAVIER", "working", "plan", "#7ee787"), ("PSYLOCKE", "asking", "verify", GOLD),
           ("CYCLOPS", "working", "review", "#7ee787"), ("ROGUE", "idle", "—", "#8b949e")]
for i, (nm, st, ph, col) in enumerate(ROWS_UI):
    yy = FY + 86 + i * 34
    add(f'<circle cx="{FX+40}" cy="{yy-5}" r="7" fill="{col}"/>')
    text(FX + 62, yy, nm, size=15, fill="#e6edf3", anchor="start", family="body", weight=800)
    text(FX + 210, yy, st, size=15, fill=col, anchor="start", family="body", weight=800)
    text(FX + 330, yy, ph, size=15, fill="#8b949e", anchor="start", family="body", weight=800)
text(FX + FW // 2, FY + 246, "s starts · k kills · f finishes · one human watching them all",
     size=14.5, fill="#e6edf3", family="body", weight=800, spacing=0.3)

# ---------------------------------------------------------------- flows between the blocks
# Into the board, from the three roles that put work on it.
arrow(f"M{AX+66},300 C700,300 720,320 {BX-8},338", ORANGE, 6, "a bead per issue", 706, 292)
arrow(f"M{AX+66},480 C700,480 730,430 {BX-8},420", CRIMSON, 6, "planned beads", 700, 452)
arrow(f"M{AX+66},870 C700,880 660,400 {BX-8},352", PURPLE, 5, "Refactoring: P4", 672, 752, dash="12 9")

# Out of the board to the squad, and the squad's own loop back through the verifier.
arrow(f"M{BX+BW+8},520 C1150,520 1160,440 {SX-8},440", GOLD, 7, "claim + build", 1160, 480)
arrow(f"M{SX+40},{SY+SH+8} C1190,880 1180,1170 1060,1170 L{AX+120},1170 C660,1170 640,1040 {AX+72},1016",
      TEAL, 6, "merged, unverified", 900, 1140)
arrow(f"M{AX+66},1020 C700,1020 740,1060 {BX-8},1042", TEAL, 6, "the verdict", 700, 1058)

# Cerebro and the fleet view, routed under everything rather than across the board.
arrow(f"M{AX+66},660 C660,660 680,1230 1100,1230 L{FX+120},1230 C{FX+180},1230 {FX+180},{FY+FH+10} {FX+150},{FY+FH+8}",
      COBALT, 6, "stop flags, a release when asked", 900, 1236, dash="12 9")
arrow(f"M{FX-8},900 C1160,900 1140,760 {BX+BW+8},760", SLATE, 5, "reads the queue", 1158, 830, dash="6 8")
arrow(f"M{FX+FW//2},{FY-8} L{FX+FW//2},{SY+SH+8}", SLATE, 5, "starts · kills · retires", FX + FW // 2, 762)

# ---------------------------------------------------------------- footer
add(f'<path d="M64,1258 l1732,0 l-18,44 l-1696,0 z" fill="{INK}"/>')
text(930, 1288, "CLOSED IS NOT TERMINAL — a failed verdict reopens the bead at P0 and sends it round again",
     size=19, family="hdr", weight=700, fill=GOLD, spacing=1)

add("</svg>")
svg = "\n".join(out)
target = pathlib.Path("docs/cerebro-fleet.svg")
target.write_text(svg)
print("wrote", target, len(svg), "bytes")
