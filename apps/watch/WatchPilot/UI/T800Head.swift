import SwiftUI

/// The T-800 head: the Cyberdyne endoskeleton, traced from the reference visor and
/// driven as a machine — pupils that focus, a jaw that talks, a head that sweeps.
///
/// Geometry lives in `T800HeadArt` in **unit space**: the skull centre is the
/// origin, ±1 unit is the top of the dome and the bottom of the chin, ±0.63 the
/// temples. The renderer needs one number — `unit` in points — so the head scales
/// with the watch without touching a single vertex.
struct HeadPose {
    var eyeGlow: Double = 0.55     // halo + pupil brightness
    var eyeScale: Double = 1       // pupil size
    var eyeLook = CGSize.zero      // pupil offset, in units
    var eyeFlicker = false         // the right eye stutters out (failure)
    var jawOpen: Double = 0        // 0 closed … 1 wide (base opening)
    var speech: Double = 0         // 0…1 talk energy: drives jaw + nod
    var headTilt: Double = 0       // radians
    var headScale: Double = 1
    var headYaw: Double = 0        // −1…1: fakes a turn (squeeze + parallax)
    var nod: Double = 0            // −1…1 vertical head offset (units × 0.006)
    var chrome: Double = 1         // metal brightness (failure dims it)
    var tear: Double = 0           // 0…1 glitch: horizontal slice displacement
}

enum T800Head {
    private struct Piece { let path: Path; let jaw: Bool; let tone: Int }

    private static let pieces: [Piece] = T800HeadArt.shapes.compactMap { s in
        guard let p = Path(svg: s.d) else { return nil }
        return Piece(path: p, jaw: s.jaw, tone: s.tone)
    }

    /// Draws the head centred on `center`, `unit` points per head-unit.
    static func draw(in context: inout GraphicsContext, center: CGPoint, unit u: Double,
                     pose: HeadPose, time: TimeInterval) {
        var root = context
        root.translateBy(x: center.x, y: center.y)
        root.scaleBy(x: u, y: u)

        // ---- head transform -------------------------------------------------
        let squeeze = 1 - 0.12 * Swift.min(abs(pose.headYaw), 1)
        var head = root
        head.rotate(by: .radians(pose.headTilt))
        head.scaleBy(x: pose.headScale * squeeze, y: pose.headScale)
        head.translateBy(x: pose.headYaw * 0.02, y: pose.nod * 0.006)

        let drop = (pose.jawOpen + pose.speech * 0.9) * T800HeadArt.jawDropMax

        // ---- the mouth: black behind, so the jaw opens into darkness --------
        if drop > 0.0005 {
            let c = T800HeadArt.mouthCavity
            let mouth = CGRect(x: c.0 + 0.012, y: c.1 - 0.02, width: c.2 - 0.024, height: c.3 + drop + 0.02)
            head.fill(Path(roundedRect: mouth, cornerRadius: 0.05), with: .color(.black))
        }

        // ---- metal ----------------------------------------------------------
        func tone(_ index: Int) -> Color {
            guard index > 0, index < T800HeadArt.palette.count else { return .black }
            let (r, g, b) = T800HeadArt.palette[index]
            return Color(red: r * pose.chrome, green: g * pose.chrome, blue: b * pose.chrome)
        }
        // A hairline stroke of the same colour closes the seams between the
        // traced regions (they share edges, and anti-aliasing leaves gaps).
        func paint(_ path: Path, _ colour: Color, in ctx: inout GraphicsContext) {
            ctx.fill(path, with: .color(colour), style: FillStyle(eoFill: true))
            ctx.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: 0.0035, lineJoin: .round))
        }

        if pose.tear < 0.02 {
            for piece in pieces where !piece.jaw { paint(piece.path, tone(piece.tone), in: &head) }
            var jaw = head
            jaw.translateBy(x: 0, y: drop)
            for piece in pieces where piece.jaw { paint(piece.path, tone(piece.tone), in: &jaw) }
        } else {
            // glitch: draw the head in horizontal slices, each displaced sideways
            let slices = 12
            for index in 0..<slices {
                let y0 = -1.05 + 2.10 * Double(index) / Double(slices)
                let y1 = -1.05 + 2.10 * Double(index + 1) / Double(slices)
                let shift = (hash(index, time) - 0.5) * 0.22 * pose.tear
                var slice = head
                slice.clip(to: Path(CGRect(x: -0.85, y: y0, width: 1.7, height: y1 - y0)))
                slice.translateBy(x: shift, y: 0)
                for piece in pieces where !piece.jaw { paint(piece.path, tone(piece.tone), in: &slice) }
            }
        }

        // ---- pupils ---------------------------------------------------------
        for side in [1.0, -1.0] {
            let (px, py, rOut, rCore) = side > 0 ? T800HeadArt.pupilR : T800HeadArt.pupilL
            let flicker = pose.eyeFlicker && side > 0 && stutter(time) ? 0.15 : 1.0
            let glow = pose.eyeGlow * flicker
            let centre = CGPoint(x: px + pose.eyeLook.width * side, y: py + pose.eyeLook.height)
            let r = rOut * pose.eyeScale * (1 + pose.speech * 0.05)

            if glow > 0.05 {
                let haloR = r * 3.0
                head.fill(Path(ellipseIn: CGRect(x: centre.x - haloR, y: centre.y - haloR,
                                                 width: haloR * 2, height: haloR * 2)),
                          with: .radialGradient(
                            Gradient(colors: [Color(red: 1, green: 0.12, blue: 0.15).opacity(0.20 * glow), .clear]),
                            center: centre, startRadius: r * 0.7, endRadius: haloR))
            }

            let disc = Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
            head.fill(disc, with: .radialGradient(
                Gradient(colors: [Color(red: 0.69, green: 0.07, blue: 0.10).opacity(flicker),
                                  Color(red: 0.83, green: 0.10, blue: 0.13).opacity(flicker),
                                  Color(red: 0.62, green: 0.05, blue: 0.08).opacity(flicker)]),
                center: centre, startRadius: r * 0.6, endRadius: r))

            let coreR = rCore * pose.eyeScale
            let core = Path(ellipseIn: CGRect(x: centre.x - coreR, y: centre.y - coreR,
                                              width: coreR * 2, height: coreR * 2))
            head.fill(core, with: .radialGradient(
                Gradient(colors: [Color(red: 1, green: 0.34, blue: 0.36).opacity(0.45 + 0.5 * glow),
                                  Color(red: 0.97, green: 0.15, blue: 0.18)]),
                center: CGPoint(x: centre.x - coreR * 0.12, y: centre.y - coreR * 0.12),
                startRadius: 0, endRadius: coreR))
        }
    }

    private static func stutter(_ t: TimeInterval) -> Bool {
        let n = (t * 7).rounded(.down)
        return abs(sin(n * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1) > 0.55
    }

    private static func hash(_ i: Int, _ t: TimeInterval) -> Double {
        let n = Double(i) * 3.7 + (t * 9).rounded(.down)
        return abs(sin(n * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
    }
}

// MARK: - geometry reader

extension Path {
    /// Minimal SVG path reader: absolute M, L, C, Z — exactly what the tracer emits.
    init?(svg d: String) {
        var path = Path()
        var i = d.startIndex
        var start = CGPoint.zero
        func number() -> Double? {
            while i < d.endIndex, d[i] == " " { i = d.index(after: i) }
            var s = ""
            if i < d.endIndex, d[i] == "-" { s.append("-"); i = d.index(after: i) }
            while i < d.endIndex, d[i].isNumber || d[i] == "." { s.append(d[i]); i = d.index(after: i) }
            return Double(s)
        }
        var cmd: Character = "M"
        while i < d.endIndex {
            let ch = d[i]
            if ch == "M" || ch == "L" || ch == "C" || ch == "Z" { cmd = ch; i = d.index(after: i) }
            else if ch == " " { i = d.index(after: i); continue }
            switch cmd {
            case "Z":
                path.closeSubpath(); cmd = "M"
            case "M":
                guard let x = number(), let y = number() else { return nil }
                start = CGPoint(x: x, y: y); path.move(to: start); cmd = "L"
            case "L":
                guard let x = number(), let y = number() else { return nil }
                path.addLine(to: CGPoint(x: x, y: y))
            default:
                guard let x1 = number(), let y1 = number(),
                      let x2 = number(), let y2 = number(),
                      let x = number(), let y = number() else { return nil }
                path.addCurve(to: CGPoint(x: x, y: y),
                              control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
            }
        }
        _ = start
        self = path
    }
}
