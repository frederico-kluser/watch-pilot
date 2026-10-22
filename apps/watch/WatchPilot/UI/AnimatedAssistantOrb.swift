import SwiftUI

/// The assistant's face: an organic, voice-reactive orb drawn with `Canvas` inside a
/// `TimelineView`, so it animates at display refresh rate without a Timer or state
/// churn. Three concentric layers breathe out of phase; a thin progress ring wraps
/// the whole thing while the Mac mini works.
struct AnimatedAssistantOrb: View {
    let phase: AssistantPhase
    var isReduceMotion: Bool = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isReduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                draw(in: &context, size: size, time: time)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Assistente"))
        .accessibilityValue(Text(phase.headline))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let style = OrbStyle.forPhase(phase)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let base = min(size.width, size.height) * 0.30
        let pressure = audioPressure
        let pulse = 1 + sin(time * style.speed) * style.amplitude
        let axis = 0.5 + 0.5 * sin(time * style.speed * 0.8)

        // 1. One continuous glow — no stacked discs, so no banding.
        let glowRadius = base * (2.05 + pressure * 0.55) * pulse
        context.fill(
            Path(ellipseIn: CGRect(
                x: center.x - glowRadius, y: center.y - glowRadius,
                width: glowRadius * 2, height: glowRadius * 2
            )),
            with: .radialGradient(
                Gradient(colors: [
                    style.core.opacity(0.17 + pressure * 0.20),
                    style.halo.opacity(0.05),
                    .clear,
                ]),
                center: center, startRadius: base * 0.35, endRadius: glowRadius
            )
        )

        // 2. Sphere body: light from the top-left, so it reads as a solid object.
        let bodyRadius = base * pulse
        let body = Path(ellipseIn: CGRect(
            x: center.x - bodyRadius, y: center.y - bodyRadius,
            width: bodyRadius * 2, height: bodyRadius * 2
        ))
        context.fill(
            body,
            with: .linearGradient(
                Gradient(colors: [
                    style.core.opacity(0.92),
                    style.halo.opacity(0.72),
                    style.halo.opacity(0.20),
                ]),
                startPoint: CGPoint(x: center.x - bodyRadius * 0.55, y: center.y - bodyRadius * 0.75),
                endPoint: CGPoint(x: center.x + bodyRadius * 0.45, y: center.y + bodyRadius * 0.85)
            )
        )

        // 3. Rim light separates the orb from the black OLED background.
        context.stroke(
            body,
            with: .linearGradient(
                Gradient(colors: [style.core.opacity(0.95), style.core.opacity(0.06)]),
                startPoint: CGPoint(x: center.x, y: center.y - bodyRadius),
                endPoint: CGPoint(x: center.x, y: center.y + bodyRadius)
            ),
            style: StrokeStyle(lineWidth: 1.2)
        )

        // 4. Pulsing core: the "listening" heartbeat.
        let coreRadius = bodyRadius * (0.30 + pressure * 0.30) * (0.9 + 0.1 * axis)
        context.fill(
            Path(ellipseIn: CGRect(
                x: center.x - coreRadius, y: center.y - coreRadius,
                width: coreRadius * 2, height: coreRadius * 2
            )),
            with: .radialGradient(
                Gradient(colors: [.white.opacity(0.55 + pressure * 0.35), style.core.opacity(0.25), .clear]),
                center: CGPoint(x: center.x, y: center.y),
                startRadius: 0, endRadius: coreRadius
            )
        )

        // 5. Voice bars while listening: the only state that earns extra chrome.
        if case .listening(let power) = phase {
            let bars = 20
            let ringRadius = bodyRadius * 1.22
            for index in 0..<bars {
                let angle = (Double(index) / Double(bars)) * 2 * .pi - .pi / 2
                let flicker = 0.5 + 0.5 * sin(time * 8.5 + Double(index) * 0.85)
                let length = base * (0.05 + power * 0.40 * flicker)
                let start = point(center: center, radius: ringRadius + base * 0.07, angle: angle)
                let end = point(center: center, radius: ringRadius + base * 0.07 + length, angle: angle)
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                context.stroke(
                    path,
                    with: .color(style.core.opacity(0.35 + power * 0.50)),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
            }
        }

        // 6. Progress ring while the Mac mini works.
        if case .waiting(let progress, _) = phase {
            let radius = bodyRadius * 1.22
            var track = Path()
            track.addArc(center: center, radius: radius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
            context.stroke(track, with: .color(Palette.surface.opacity(0.85)), style: StrokeStyle(lineWidth: 2.5))

            var arc = Path()
            arc.addArc(
                center: center, radius: radius,
                startAngle: .degrees(-90),
                endAngle: .degrees(-90 + 360 * max(0.03, progress)),
                clockwise: false
            )
            context.stroke(
                arc,
                with: .linearGradient(
                    Gradient(colors: [style.core, .white.opacity(0.9)]),
                    startPoint: CGPoint(x: center.x, y: center.y - radius),
                    endPoint: CGPoint(x: center.x + radius, y: center.y)
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
        }

        // 7. Uploading: three orbiting sparks over the ring.
        if case .uploading = phase {
            for index in 0..<3 {
                let angle = time * 3.2 + Double(index) * (2 * .pi / 3)
                let dotCenter = point(center: center, radius: bodyRadius * 1.22, angle: angle)
                let dot = CGRect(x: dotCenter.x - 2.4, y: dotCenter.y - 2.4, width: 4.8, height: 4.8)
                context.fill(Path(ellipseIn: dot), with: .color(style.core))
            }
        }
    }

    private func point(center: CGPoint, radius: Double, angle: Double) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    private var audioPressure: Double {
        if case .listening(let power) = phase { return power * 0.35 }
        return 0
    }
}

#Preview("Estados do orbe") {
    VStack(spacing: 8) {
        AnimatedAssistantOrb(phase: .idle).frame(height: 90)
        AnimatedAssistantOrb(phase: .listening(power: 0.7)).frame(height: 90)
        AnimatedAssistantOrb(phase: .waiting(progress: 0.55, step: "A pensar…")).frame(height: 90)
        AnimatedAssistantOrb(phase: .answering(reply: "Feito.")).frame(height: 90)
    }
    .background(Palette.background)
}
