import SwiftUI

/// The assistant's face: a small vector character with one **pose per state**.
///
/// Why not Animoji/Memoji: Apple exposes no public API to instantiate or animate
/// them (the renderer, `AvatarKit`, is a private framework), and watchOS has neither
/// ARKit nor RealityKit for face-driven avatars. See
/// `docs/research/Q8-memoji-animoji.md`. So the character is drawn here with
/// `Canvas`: no assets, no dependencies, 30 Hz, and the poses are **data**
/// (`AvatarPose`) instead of hard-coded drawing branches.
struct AssistantAvatar: View {
    let phase: AssistantPhase
    var isReduceMotion: Bool = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isReduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                AvatarRenderer.draw(context: &context, size: size, time: time, phase: phase)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Assistente Watch Pilot"))
        .accessibilityValue(Text(phase.headline))
    }
}

// MARK: - Poses

/// Everything that changes between states, as numbers. The renderer knows nothing
/// about the app's state machine; it just interpolates this.
struct AvatarPose {
    var eyeOpen: Double = 1      // 0 closed … 1 wide
    var happyEyes = false        // closed upward arcs
    var eyeLook = CGSize.zero    // small gaze offset, in points
    var mouthOpen: Double = 0    // 0 closed … 1 open
    var smile: Double = 0.35     // −1 frown … 1 grin
    var earLift: Double = 0.5    // antennae: 0 droopy … 1 standing
    var headTilt: Double = 0     // radians
    var bounce: Double = 0       // vertical offset, points
    var glow: Double = 0.35
    var thinkingDots = false
    var uploadWaves = false
    var core: Color = Palette.blue
    var halo: Color = Palette.violet
    var broken = false

    static func forPhase(_ phase: AssistantPhase) -> AvatarPose {
        switch phase {
        case .idle:
            return AvatarPose(
                eyeOpen: 1, mouthOpen: 0, smile: 0.25, earLift: 0.45,
                glow: 0.32, core: Palette.blue, halo: Palette.violet
            )
        case .listening(let power):
            return AvatarPose(
                eyeOpen: 1.12, mouthOpen: 0.25 + power * 0.75, smile: 0.15,
                earLift: 1, glow: 0.45 + power * 0.35,
                core: Palette.pink, halo: Palette.violet
            )
        case .uploading:
            return AvatarPose(
                eyeOpen: 0.95, eyeLook: CGSize(width: 0, height: -2.6),
                mouthOpen: 0.18, smile: 0.1, earLift: 0.75,
                glow: 0.55, uploadWaves: true,
                core: Palette.amber, halo: Palette.pink
            )
        case .waiting:
            return AvatarPose(
                eyeOpen: 1, mouthOpen: 0.08, smile: 0.05, earLift: 0.55,
                glow: 0.4, thinkingDots: true,
                core: Palette.violet, halo: Palette.blue
            )
        case .answering:
            return AvatarPose(
                eyeOpen: 0.15, happyEyes: true, mouthOpen: 0.3, smile: 1,
                earLift: 1, bounce: 1.6, glow: 0.6,
                core: Palette.mint, halo: Palette.blue
            )
        case .failed:
            return AvatarPose(
                eyeOpen: 0.45, mouthOpen: 0.05, smile: -0.8, earLift: 0,
                headTilt: -0.06, glow: 0.2,
                core: Palette.red, halo: Palette.amber, broken: true
            )
        }
    }
}

// MARK: - Renderer

enum AvatarRenderer {
    static func draw(context: inout GraphicsContext, size: CGSize, time: TimeInterval, phase: AssistantPhase) {
        var pose = AvatarPose.forPhase(phase)

        // Shared life: breathing everywhere, blinking when the eyes are open, a
        // gentle idle sway. Motion is the difference between "a picture" and "a
        // character waiting for you".
        let breath = sin(time * 1.7) * 0.012
        let sway = sin(time * 0.9) * 0.02
        pose.headTilt += sway
        pose.bounce += sin(time * 2.1) * 0.35

        if pose.eyeOpen > 0.5 {
            pose.eyeOpen *= blink(time)
        }
        if pose.uploadsOrWaiting(phase) {
            pose.eyeLook.width += sin(time * 1.9) * 2.2
        }

        let center = CGPoint(x: size.width / 2, y: size.height * 0.56 + pose.bounce)
        let headRadius = min(size.width, size.height) * 0.285 * (1 + breath)

        // 1. Halo — one continuous gradient, no stacked discs (no banding).
        let glowRadius = headRadius * (1.85 + pose.glow * 0.5)
        context.fill(
            Path(ellipseIn: CGRect(
                x: center.x - glowRadius, y: center.y - glowRadius,
                width: glowRadius * 2, height: glowRadius * 2
            )),
            with: .radialGradient(
                Gradient(colors: [pose.core.opacity(0.16 + pose.glow * 0.22), pose.halo.opacity(0.05), .clear]),
                center: center, startRadius: headRadius * 0.4, endRadius: glowRadius
            )
        )

        // 2. Shoulders, so the head sits on something.
        let shoulderY = center.y + headRadius * 0.92
        var shoulders = Path()
        shoulders.move(to: CGPoint(x: center.x - headRadius * 0.78, y: shoulderY + headRadius * 0.55))
        shoulders.addQuadCurve(
            to: CGPoint(x: center.x + headRadius * 0.78, y: shoulderY + headRadius * 0.55),
            control: CGPoint(x: center.x, y: shoulderY - headRadius * 0.22)
        )
        context.stroke(
            shoulders,
            with: .color(pose.core.opacity(0.35)),
            style: StrokeStyle(lineWidth: 2, lineCap: .round)
        )

        // 3. Antennae — they read the state: perked when listening, drooped on error.
        for side in [-1.0, 1.0] {
            let lift = pose.earLift
            let rootAngle = side * (0.55 - 0.22 * lift)
            let root = CGPoint(
                x: center.x + sin(rootAngle) * headRadius * 0.92,
                y: center.y - cos(rootAngle) * headRadius * 0.92
            )
            let length = headRadius * (0.36 + 0.26 * lift)
            let tip = CGPoint(
                x: root.x + sin(rootAngle) * length,
                y: root.y - cos(rootAngle) * length
            )
            var stalk = Path()
            stalk.move(to: root)
            stalk.addLine(to: tip)
            context.stroke(stalk, with: .color(pose.core.opacity(0.75)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))

            let ball = headRadius * 0.085
            let ballCenter = CGPoint(x: tip.x, y: tip.y - ball * 0.4)
            context.fill(
                Path(ellipseIn: CGRect(x: ballCenter.x - ball, y: ballCenter.y - ball, width: ball * 2, height: ball * 2)),
                with: .color(pose.core.opacity(0.95))
            )
            // a soft light around each antenna tip
            let aura = ball * 3.4
            context.fill(
                Path(ellipseIn: CGRect(x: ballCenter.x - aura, y: ballCenter.y - aura, width: aura * 2, height: aura * 2)),
                with: .radialGradient(
                    Gradient(colors: [pose.core.opacity(0.35 * pose.earLift), .clear]),
                    center: ballCenter, startRadius: 0, endRadius: aura
                )
            )
        }

        // 4. Head: light from the top-left so it reads as a solid object.
        let headRect = CGRect(
            x: center.x - headRadius, y: center.y - headRadius,
            width: headRadius * 2, height: headRadius * 2
        )
        let head = Path(roundedRect: headRect, cornerRadius: headRadius * 0.46)
        let headTransform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: pose.headTilt)
            .translatedBy(x: -center.x, y: -center.y)
        let tiltedHead = head.applying(headTransform)

        context.fill(
            tiltedHead,
            with: .linearGradient(
                Gradient(colors: [
                    pose.core.opacity(0.95),
                    pose.halo.opacity(0.75),
                    pose.halo.opacity(0.22),
                ]),
                startPoint: CGPoint(x: center.x - headRadius * 0.6, y: center.y - headRadius * 0.8),
                endPoint: CGPoint(x: center.x + headRadius * 0.5, y: center.y + headRadius * 0.9)
            )
        )
        context.stroke(
            tiltedHead,
            with: .linearGradient(
                Gradient(colors: [.white.opacity(0.55), pose.core.opacity(0.06)]),
                startPoint: CGPoint(x: center.x, y: center.y - headRadius),
                endPoint: CGPoint(x: center.x, y: center.y + headRadius)
            ),
            style: StrokeStyle(lineWidth: 1.1)
        )

        // 5. Face (inside the head, so it tilts with it).
        var face = context
        face.translateBy(x: center.x, y: center.y)
        face.rotate(by: .radians(pose.headTilt))
        face.translateBy(x: -center.x, y: -center.y)

        drawEyes(in: &face, center: center, radius: headRadius, pose: pose)
        drawMouth(in: &face, center: center, radius: headRadius, pose: pose)

        // 6. Extras that say what the hub is doing.
        if pose.thinkingDots {
            drawThinkingDots(in: &face, center: center, radius: headRadius, time: time, color: pose.core)
        }
        if pose.uploadWaves {
            drawUploadWaves(in: &face, center: center, radius: headRadius, time: time, color: pose.core)
        }
    }

    // MARK: parts

    private static func drawEyes(in context: inout GraphicsContext, center: CGPoint, radius: Double, pose: AvatarPose) {
        let eyeSpacing = radius * 0.40
        let eyeWidth = radius * 0.24
        let baseHeight = radius * 0.34
        let eyeY = center.y - radius * 0.10

        for side in [-1.0, 1.0] {
            let eyeCenter = CGPoint(
                x: center.x + side * eyeSpacing + pose.eyeLook.width,
                y: eyeY + pose.eyeLook.height
            )

            if pose.happyEyes {
                // A closed, upward arc — the universal "content" eye.
                var arc = Path()
                arc.move(to: CGPoint(x: eyeCenter.x - eyeWidth * 0.72, y: eyeCenter.y + eyeWidth * 0.25))
                arc.addQuadCurve(
                    to: CGPoint(x: eyeCenter.x + eyeWidth * 0.72, y: eyeCenter.y + eyeWidth * 0.25),
                    control: CGPoint(x: eyeCenter.x, y: eyeCenter.y - eyeWidth * 0.75)
                )
                context.stroke(arc, with: .color(.white.opacity(0.95)), style: StrokeStyle(lineWidth: radius * 0.075, lineCap: .round))
                continue
            }

            let height = max(radius * 0.045, baseHeight * pose.eyeOpen)
            let rect = CGRect(
                x: eyeCenter.x - eyeWidth / 2,
                y: eyeCenter.y - height / 2,
                width: eyeWidth,
                height: height
            )
            context.fill(Path(roundedRect: rect, cornerRadius: eyeWidth / 2), with: .color(.white.opacity(0.96)))

            // Catch-light: the single detail that makes it feel alive.
            if pose.eyeOpen > 0.55 {
                let sparkle = radius * 0.045
                let sparkleCenter = CGPoint(x: eyeCenter.x + eyeWidth * 0.16, y: eyeCenter.y - height * 0.18)
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: sparkleCenter.x - sparkle, y: sparkleCenter.y - sparkle,
                        width: sparkle * 2, height: sparkle * 2
                    )),
                    with: .color(.black.opacity(0.35))
                )
            }

            if pose.broken {
                // Crossed-out eyes for the failure pose.
                var cross = Path()
                let d = eyeWidth * 0.55
                cross.move(to: CGPoint(x: eyeCenter.x - d, y: eyeCenter.y - d))
                cross.addLine(to: CGPoint(x: eyeCenter.x + d, y: eyeCenter.y + d))
                cross.move(to: CGPoint(x: eyeCenter.x + d, y: eyeCenter.y - d))
                cross.addLine(to: CGPoint(x: eyeCenter.x - d, y: eyeCenter.y + d))
                context.stroke(cross, with: .color(Palette.background.opacity(0.85)), style: StrokeStyle(lineWidth: radius * 0.06, lineCap: .round))
            }
        }
    }

    private static func drawMouth(in context: inout GraphicsContext, center: CGPoint, radius: Double, pose: AvatarPose) {
        let mouthY = center.y + radius * 0.38
        let mouthWidth = radius * 0.42

        if pose.mouthOpen > 0.12 {
            let height = radius * 0.08 + radius * 0.17 * pose.mouthOpen
            let width = mouthWidth * 1.18
            let rect = CGRect(
                x: center.x - width / 2,
                y: mouthY - height / 2 + (1 - pose.smile) * radius * 0.03,
                width: width,
                height: height
            )
            context.fill(Path(roundedRect: rect, cornerRadius: height / 2), with: .color(Palette.background.opacity(0.72)))
            return
        }

        // Closed mouth: a curve whose curvature is the emotional state.
        let curve = radius * 0.16 * pose.smile
        var path = Path()
        path.move(to: CGPoint(x: center.x - mouthWidth / 2, y: mouthY))
        path.addQuadCurve(
            to: CGPoint(x: center.x + mouthWidth / 2, y: mouthY),
            control: CGPoint(x: center.x, y: mouthY + curve)
        )
        context.stroke(path, with: .color(Palette.background.opacity(0.75)), style: StrokeStyle(lineWidth: radius * 0.055, lineCap: .round))
    }

    private static func drawThinkingDots(in context: inout GraphicsContext, center: CGPoint, radius: Double, time: TimeInterval, color: Color) {
        for index in 0..<3 {
            let phase = time * 2.6 - Double(index) * 0.5
            let alpha = 0.25 + 0.65 * (0.5 + 0.5 * sin(phase))
            let dot = radius * 0.06
            let x = center.x + radius * (0.62 + Double(index) * 0.22)
            let y = center.y - radius * (0.72 + Double(index) * 0.06)
            context.fill(
                Path(ellipseIn: CGRect(x: x - dot, y: y - dot, width: dot * 2, height: dot * 2)),
                with: .color(color.opacity(alpha))
            )
        }
    }

    private static func drawUploadWaves(in context: inout GraphicsContext, center: CGPoint, radius: Double, time: TimeInterval, color: Color) {
        for index in 0..<3 {
            let pulse = (sin(time * 3 - Double(index) * 0.7) + 1) / 2
            var arc = Path()
            let arcRadius = radius * (1.15 + Double(index) * 0.18)
            arc.addArc(
                center: CGPoint(x: center.x, y: center.y - radius * 0.35),
                radius: arcRadius,
                startAngle: .degrees(-152), endAngle: .degrees(-28),
                clockwise: false
            )
            context.stroke(
                arc,
                with: .color(color.opacity(0.12 + pulse * 0.42)),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
            )
        }
    }

    // MARK: timing

    /// A blink every ~4 s, closing and opening over ~140 ms.
    private static func blink(_ time: TimeInterval) -> Double {
        let period = 4.2
        let phase = time.truncatingRemainder(dividingBy: period) / period
        if phase > 0.035 { return 1 }
        let progress = phase / 0.035
        return 0.06 + 0.94 * abs(progress * 2 - 1)
    }
}

private extension AvatarPose {
    func uploadsOrWaiting(_ phase: AssistantPhase) -> Bool {
        switch phase {
        case .waiting, .uploading: return true
        default: return false
        }
    }
}

#Preview("Poses") {
    VStack(spacing: 6) {
        AssistantAvatar(phase: .idle)
        AssistantAvatar(phase: .listening(power: 0.7))
        AssistantAvatar(phase: .waiting(progress: 0.5, step: "…"))
        AssistantAvatar(phase: .answering(reply: "Feito"))
        AssistantAvatar(phase: .failed(message: "Falhou"))
    }
    .frame(height: 60)
    .background(Palette.background)
}
