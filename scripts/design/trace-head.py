#!/usr/bin/env python3
"""trace-head — regenerates `T800HeadArt.swift` from the reference visor.

The T-800 head is not hand-drawn: it is *traced* from the reference mockup so it
matches it pixel for pixel. This script

1. crops the skull out of `docs/design/reference/t800-visor.jpg`,
2. flattens it (mean shift) and snaps every pixel to a 10-step flat metal ramp,
3. erases the red pupils (drawn procedurally so they can glow and look around),
4. splits the head at the jaw line (so the jaw can drop when it speaks),
5. traces every tone with potrace and emits absolute M/L/C/Z paths in *unit space*
   (skull centre = origin, ±1 = dome top / chin bottom), and
6. writes `apps/watch/WatchPilot/UI/T800HeadArt.swift`.

Requirements: numpy, opencv-python, potracer (pip install numpy opencv-python-headless potracer).
Run from anywhere: `python3 scripts/design/trace-head.py`.
"""

import numpy as np, cv2, json, os, potrace, tempfile, time, re

ROOT = __import__('pathlib').Path(__file__).resolve().parents[2]
REF = str(ROOT / 'docs/design/reference/t800-visor.jpg')
OUT_SWIFT = ROOT / 'apps/watch/WatchPilot/UI/T800HeadArt.swift'
ROI, S = (1195, 466, 1545, 996), 3
CX, CY, U = 1370.0, 729.0, 244.0
x0, y0, x1, y1 = ROI

PAL = [(0,0,0),(26,29,34),(50,58,66),(62,72,82),(86,97,106),
       (106,116,128),(122,134,144),(140,152,162),(155,168,177),(172,185,194)]

im = cv2.imread(REF)[y0:y1, x0:x1]
up = cv2.resize(im, None, fx=S, fy=S, interpolation=cv2.INTER_CUBIC)
flat = cv2.pyrMeanShiftFiltering(up, sp=9, sr=14)
lab = cv2.cvtColor(flat, cv2.COLOR_BGR2LAB).astype(np.float32)
pal_bgr = np.array([[b, g, r] for (r, g, b) in PAL], np.uint8)
pal_lab = cv2.cvtColor(pal_bgr.reshape(1, -1, 3), cv2.COLOR_BGR2LAB).reshape(-1, 3).astype(np.float32)
labels = ((lab[:, :, None, :] - pal_lab[None, None, :, :]) ** 2).sum(-1).argmin(-1).astype(np.uint8)
RGB = flat[:, :, ::-1].astype(int); R, G, B = RGB[..., 0], RGB[..., 1], RGB[..., 2]
L = 0.299*R + 0.587*G + 0.114*B

# skull silhouette = largest non-void blob, holes closed
sil = ((L > 40) & (np.abs(R - B) < 70)).astype(np.uint8)
sil = cv2.morphologyEx(sil, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (13, 13)))
n, cc, st, _ = cv2.connectedComponentsWithStats(sil, 8)
sil = (cc == 1 + np.argmax(st[1:, cv2.CC_STAT_AREA])).astype(bool)
sil = cv2.morphologyEx(sil.astype(np.uint8), cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (25, 25))).astype(bool)
labels[~sil] = 0

labels[(R > 110) & (R - G > 55)] = 0     # pupils -> void (drawn procedurally)

def P(px, py): return (int((px-x0)*S), int((py-y0)*S))

for _ in range(2):
    for j in range(1, len(PAL)):
        m = (labels == j).astype(np.uint8)
        nn, ccl, stl, _ = cv2.connectedComponentsWithStats(m, 8)
        for i in range(1, nn):
            if stl[i, cv2.CC_STAT_AREA] < 130:
                yy, xx = np.where(ccl == i)
                patch = labels[yy, xx]
                vals, cnt = np.unique(patch, return_counts=True)
                cand = [(c, v) for v, c in zip(vals, cnt) if v != j]
                if cand: labels[yy, xx] = max(cand)[1]
labels = cv2.medianBlur(labels, 5)
labels[~sil] = 0

jawm = np.zeros(labels.shape, np.uint8)
cv2.fillPoly(jawm, [np.array([P(1299,868), P(1441,868), P(1441,978), P(1299,978)], np.int32)], 1)
jawm = jawm.astype(bool) & sil

def trace(mask):
    if mask.sum() < 120: return []
    H, W = mask.shape
    p = potrace.Bitmap(np.ascontiguousarray(mask, dtype=bool)).trace(
        turdsize=140, alphamax=1.2, opticurve=True, opttolerance=1.5)
    out = []
    for c in p:
        xs = [c.start_point.x] + [s.end_point.x for s in c.segments] + [g.x for s in c.segments for g in (getattr(s, 'c', None), getattr(s, 'c1', None), getattr(s, 'c2', None)) if g is not None]
        ys = [c.start_point.y] + [s.end_point.y for s in c.segments] + [g.y for s in c.segments for g in (getattr(s, 'c', None), getattr(s, 'c1', None), getattr(s, 'c2', None)) if g is not None]
        if min(xs) <= 0.01 and min(ys) <= 0.01 and max(xs) >= W - 1.01 and max(ys) >= H - 1.01:
            continue          # potracer always emits the bitmap rectangle first
        out.append(c)
    return out

def ux(v): return (v/S + x0 - CX)/U
def uy(v): return (v/S + y0 - CY)/U
def emit(curves):
    out = []
    for c in curves:
        out.append("M%.3f %.3f" % (ux(c.start_point.x), uy(c.start_point.y)))
        for s in c.segments:
            e = s.end_point
            if s.is_corner:
                out.append("L%.3f %.3fL%.3f %.3f" % (ux(s.c.x), uy(s.c.y), ux(e.x), uy(e.y)))
            else:
                out.append("C%.3f %.3f %.3f %.3f %.3f %.3f" % (
                    ux(s.c1.x), uy(s.c1.y), ux(s.c2.x), uy(s.c2.y), ux(e.x), uy(e.y)))
        out.append("Z")
    return "".join(out)

shapes = []
t0 = time.time()
for group, gm in (("head", ~jawm), ("jaw", jawm)):
    for j in range(1, len(PAL)):
        d = emit(trace((labels == j) & gm))
        if d: shapes.append((group, j, d))
silhouette = emit(trace(sil))
print(f"shape groups: {len(shapes)}  time {time.time()-t0:.1f}s  bytes {sum(len(d) for _,_,d in shapes)+len(silhouette)}")

def unit(px, py): return (round((px-CX)/U, 4), round((py-CY)/U, 4))

meta = {
    "pupilL": (*unit(1297.83, 715.78), round(18.58/U, 4), round(10.90/U, 4)),
    "pupilR": (*unit(1442.38, 715.69), round(18.62/U, 4), round(10.90/U, 4)),
    "dotsL": [(*unit(1273.6,700.3), 0.0193), (*unit(1275.1,731.8), 0.0195), (*unit(1320.2,731.9), 0.0190)],
    "dotsR": [(*unit(1467.1,700.2), 0.0198), (*unit(1465.5,731.7), 0.0188), (*unit(1419.9,731.8), 0.0192)],
    "bolts": [(round((1227+3.5-CX)/U,4), round((697+6.5-CY)/U,4), 0.0287, 0.0533),
              (round((1507+4.0-CX)/U,4), round((697+6.5-CY)/U,4), 0.0328, 0.0533)],
    "noseDots": [(*unit(1350,834), 0.0115), (*unit(1391,834), 0.0115)],
    "pistonL": (*unit(1261,815), *unit(1301,910), 0.0295),
    "pistonR": (*unit(1479,815), *unit(1439,910), 0.0295),
    "strutL":  (*unit(1315,806), *unit(1288,850), 0.0189),
    "strutR":  (*unit(1425,806), *unit(1452,850), 0.0189),
    "mouthCavity": (round((1288-CX)/U,4), round((872-CY)/U,4), round((1452-1288)/U,4), round((70)/U,4)),
    "jawDropMax": 0.042,
}
json.dump({"shapes": shapes, "palette": PAL, "silhouette": silhouette, "meta": meta},
          open(os.path.join(tempfile.mkdtemp(prefix='t800-'), 'art.json'), 'w'))

# ------------------------------------------------------------------ Swift emit
def swift():
    L_ = []
    L_.append("// Generated by scripts/design/trace-head.py from docs/design/reference/t800-visor.jpg.")
    L_.append("// Do not edit by hand: re-run the tracer to regenerate.\n")
    L_.append("import SwiftUI\n")
    L_.append("enum T800HeadArt {")
    L_.append("    struct Shape { let jaw: Bool; let tone: Int; let d: String }\n")
    L_.append("    /// Flat metal tones sampled from the reference visor, darkest first (sRGB 0…1).")
    L_.append("    static let palette: [(Double, Double, Double)] = [")
    for r, g, b in PAL:
        L_.append("        (%.4f, %.4f, %.4f)," % (r/255, g/255, b/255))
    L_.append("    ]\n")
    L_.append("    static let shapes: [Shape] = [")
    for g, t, d in shapes:
        L_.append('        Shape(jaw: %s, tone: %d, d: "%s"),' % ("true" if g == "jaw" else "false", t, d))
    L_.append("    ]\n")
    L_.append('    static let silhouette = "%s"\n' % silhouette)
    for k, v in meta.items():
        if isinstance(v, tuple):
            L_.append("    static let %s = (%s)" % (k, ", ".join("%.4f" % x for x in v)))
        elif isinstance(v, list):
            arity = len(v[0])
            fmt = "    static let %s: [(" + ", ".join(["Double"] * arity) + ")] = [%s]"
            L_.append(fmt % (k, ", ".join("(" + ", ".join("%.4f" % x for x in t) + ")" for t in v)))
        else:
            L_.append("    static let %s = %.4f" % (k, v))
    L_.append("}")
    return "\n".join(L_) + "\n"

OUT_SWIFT.write_text(swift())
print('wrote', OUT_SWIFT)
print("swift bytes:", len(swift()))
