import SwiftUI

/// The assistant's face: a Cyberdyne **T-800** endoskeleton skull inside a targeting
/// HUD that fills the whole watch screen, drawn entirely in code with one **pose
/// per state**.
///
/// Why not Animoji/Memoji: Apple exposes no public API to instantiate or animate
/// them (the renderer, `AvatarKit`, is a private framework), and watchOS has neither
/// ARKit nor RealityKit for face-driven avatars. See
/// `docs/research/Q8-memoji-animoji.md`. So the character is drawn here with
/// `Canvas`: no assets, no dependencies, 30 Hz, and the poses are **data**
/// (`AvatarPose`) instead of hard-coded drawing branches.
///
/// Layout (design space 190×231 pt, scaled to fill the screen width): "T-800" and
/// the system clock live on the top row; the HUD frame holds the Cyberdyne logo,
/// the reticle ring with the skull (which overflows the ring, like the reference
/// visor), ruler ticks with a moving scanner mark, corner brackets and decorative
/// data glyphs; a dot-matrix waveform sits under the frame and the status line at
/// the bottom over a dark scrim.
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
        .accessibilityLabel(Text("T-800, assistente Watch Pilot"))
        .accessibilityValue(Text(phase.headline))
    }
}

// MARK: - Poses

/// Everything that changes between states, as numbers. The renderer knows nothing
/// about the app's state machine; it just interpolates this.
struct AvatarPose {
    // Olhos
    var eyeGlow: Double      // 0 apagado … 1 brilho máximo das pupilas vermelhas
    var eyeScale: Double     // tamanho das pupilas
    var eyeLook: CGSize      // desvio do olhar, em pontos
    var eyeFlicker: Bool     // falha: o olho direito pisca avariado
    // Mandíbula
    var jawOpen: Double      // 0 fechada … 1 aberta (abertura base)
    var speaking: Bool       // a maxila fala sozinha (cadência de voz)
    // Cabeça
    var headTilt: Double     // rotação base, radianos
    var headScale: Double    // aproximação (escuta = inclina-se para ti)
    var scanning: Bool       // varredura lenta esquerda↔direita
    // HUD
    var accent: Color        // vermelho Cyberdyne dos olhos e do HUD
    var chrome: Double       // multiplicador de brilho do metal (0…1)
    var ringSpeed: Double    // rotação do anel tracejado, graus/s
    var ringProgress: Double? // arco de progresso no anel (a pensar)
    var scanLine: Bool       // varredura vertical (a enviar)
    var hudPulse: Bool       // cantos da mira pulsam (a ouvir)
    var hudGlitch: Bool      // HUD avariado (falha)
    // Waveform
    var waveAmplitude: Double // 0…1, altura das barras de pontos
    var waveSpeech: Bool     // padrão de fala (resposta) vs. padrão ambiente

    init(
        eyeGlow: Double = 0.72,
        eyeScale: Double = 1,
        eyeLook: CGSize = .zero,
        eyeFlicker: Bool = false,
        jawOpen: Double = 0,
        speaking: Bool = false,
        headTilt: Double = 0,
        headScale: Double = 1,
        scanning: Bool = false,
        accent: Color = Palette.crimson,
        chrome: Double = 1,
        ringSpeed: Double = 6,
        ringProgress: Double? = nil,
        scanLine: Bool = false,
        hudPulse: Bool = false,
        hudGlitch: Bool = false,
        waveAmplitude: Double = 0.6,
        waveSpeech: Bool = false
    ) {
        self.eyeGlow = eyeGlow
        self.eyeScale = eyeScale
        self.eyeLook = eyeLook
        self.eyeFlicker = eyeFlicker
        self.jawOpen = jawOpen
        self.speaking = speaking
        self.headTilt = headTilt
        self.headScale = headScale
        self.scanning = scanning
        self.accent = accent
        self.chrome = chrome
        self.ringSpeed = ringSpeed
        self.ringProgress = ringProgress
        self.scanLine = scanLine
        self.hudPulse = hudPulse
        self.hudGlitch = hudGlitch
        self.waveAmplitude = waveAmplitude
        self.waveSpeech = waveSpeech
    }

    static func forPhase(_ phase: AssistantPhase) -> AvatarPose {
        switch phase {
        case .idle:
            // Em espera: olhos em brasa, cabeça a varrer devagar, waveform calma
            // mas presente — o visor nunca parece desligado.
            return AvatarPose(scanning: true, ringSpeed: 5)
        case .listening(let power):
            // A ouvir: pupilas abertas e brilhantes, cantos a pulsar, a waveform
            // é o microfone — a amplitude já vem escalada pelo `power`.
            return AvatarPose(
                eyeGlow: 0.85 + power * 0.15, eyeScale: 1.12,
                headScale: 1.02, ringSpeed: 16,
                hudPulse: true, waveAmplitude: 0.25 + power * 0.75
            )
        case .uploading:
            // A enviar: olhar para cima, linha de varredura a subir o anel.
            return AvatarPose(
                eyeGlow: 0.9, eyeLook: CGSize(width: 0, height: -2.6),
                ringSpeed: 26, scanLine: true, waveAmplitude: 0.4
            )
        case .waiting(let progress, _):
            // A pensar: varredura de busca e o anel mostra o progresso real.
            return AvatarPose(
                eyeGlow: 0.8, scanning: true,
                ringSpeed: 34, ringProgress: progress, waveAmplitude: 0.35
            )
        case .answering:
            // A responder: a maxila fala e a waveform cospe a voz.
            return AvatarPose(
                eyeGlow: 1, speaking: true,
                ringSpeed: 10, waveAmplitude: 0.9, waveSpeech: true
            )
        case .failed:
            // Falha: metal baço, olho direito a falhar, HUD em glitch.
            return AvatarPose(
                eyeGlow: 0.45, eyeFlicker: true, headTilt: -0.06,
                chrome: 0.72, ringSpeed: 0, hudGlitch: true, waveAmplitude: 0.06
            )
        }
    }
}

// MARK: - Renderer

enum AvatarRenderer {
    static func draw(context: inout GraphicsContext, size: CGSize, time: TimeInterval, phase: AssistantPhase) {
        var pose = AvatarPose.forPhase(phase)

        // Vida partilhada: períodos deliberadamente não múltiplos entre si, para
        // o conjunto nunca repetir visivelmente.
        let scan = sin(time * 0.45)
        if pose.scanning {
            pose.eyeLook.width += scan * 3.2
            pose.headTilt += scan * 0.04
        }
        pose.headTilt += sin(time * 0.9) * 0.012
        if pose.speaking {
            let cadence = max(0, sin(time * 7.3)) * (0.45 + 0.55 * (0.5 + 0.5 * sin(time * 1.31)))
            pose.jawOpen = 0.10 + 0.72 * cadence
        }

        let glitch = glitchValue(time)
        let w = size.width, h = size.height
        let skullCenter = CGPoint(x: w / 2, y: h * 0.42)
        let unit = min(h * 0.235, w * 0.30)
        let ringRadius = w * 0.232

        drawBackdrop(in: &context, center: skullCenter, ringRadius: ringRadius, pose: pose)
        drawHUDFrame(in: &context, size: size, ringRadius: ringRadius, skullCenter: skullCenter, time: time, pose: pose, glitch: glitch)
        drawReticle(in: &context, center: skullCenter, radius: ringRadius, time: time, pose: pose, glitch: glitch)
        drawSkull(in: &context, center: skullCenter, unit: unit, time: time, pose: pose, glitch: glitch)
        if pose.scanLine {
            drawScanLine(in: &context, center: skullCenter, radius: ringRadius, time: time, pose: pose)
        }
        drawWaveform(in: &context, size: size, time: time, pose: pose)
        drawScrim(in: &context, size: size)
    }

    // MARK: fundo e brilho

    private static func drawBackdrop(in context: inout GraphicsContext, center: CGPoint, ringRadius: Double, pose: AvatarPose) {
        let r = ringRadius * 1.5
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
            with: .radialGradient(
                Gradient(colors: [pose.accent.opacity(0.05 + pose.eyeGlow * 0.05), .clear]),
                center: center, startRadius: ringRadius * 0.3, endRadius: r
            )
        )
    }

    /// Scrim escuro na faixa do texto de estado, para a legenda ler-se sempre.
    private static func drawScrim(in context: inout GraphicsContext, size: CGSize) {
        context.fill(
            Path(CGRect(x: 0, y: size.height * 0.76, width: size.width, height: size.height * 0.24)),
            with: .linearGradient(
                Gradient(colors: [.clear, Palette.background.opacity(0.85), Palette.background]),
                startPoint: CGPoint(x: 0, y: size.height * 0.76),
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
    }

    // MARK: moldura HUD

    private static func drawHUDFrame(in context: inout GraphicsContext, size: CGSize, ringRadius: Double, skullCenter: CGPoint, time: TimeInterval, pose: AvatarPose, glitch: Double) {
        let accent = pose.accent
        let w = size.width, h = size.height
        let flick = pose.hudGlitch && glitch > 0.72

        // Moldura exterior — o rectângulo arredondado do visor.
        let frame = CGRect(x: w * 0.06, y: h * 0.15, width: w * 0.88, height: h * 0.535)
        context.stroke(
            Path(roundedRect: frame, cornerRadius: 14),
            with: .color(Palette.muted.opacity(flick ? 0.15 : 0.4)),
            style: StrokeStyle(lineWidth: 1)
        )

        // Cantos da mira (brackets vermelhos) à volta do anel.
        let bracketRect = CGRect(x: w * 0.215, y: h * 0.21, width: w * 0.57, height: h * 0.43)
        let pulse = pose.hudPulse ? 0.6 + 0.4 * (0.5 + 0.5 * sin(time * 3.1)) : 0.9
        let jx = flick ? (glitch - 0.86) * 16 : 0
        drawBrackets(in: &context, rect: bracketRect.offsetBy(dx: jx, dy: 0), arm: 11,
                     color: accent.opacity(flick ? 0.35 : pulse))

        // Réguas de ticks laterais + marcas de varredura.
        drawTickColumn(in: &context, x: w * 0.075, top: h * 0.28, bottom: h * 0.58, flip: false,
                       time: time, accent: accent, speed: 5.5)
        drawTickColumn(in: &context, x: w * 0.925, top: h * 0.28, bottom: h * 0.58, flip: true,
                       time: time, accent: accent, speed: 4.1)

        // Segmento vermelho fixo na régua esquerda (como no visor de referência).
        context.fill(
            Path(CGRect(x: w * 0.075 + 5.5, y: h * 0.435, width: 3.2, height: h * 0.055)),
            with: .color(accent.opacity(0.9))
        )

        // Logo Cyberdyne: triângulo vermelho vazado + duas linhas de texto.
        drawCyberdyneLogo(in: &context, origin: CGPoint(x: w * 0.105, y: h * 0.165), accent: accent)

        // Glifos de dados — decoração de terminal, sem significado.
        drawGlyphs(in: &context, size: size, accent: accent, dim: flick)
    }

    private static func drawBrackets(in context: inout GraphicsContext, rect: CGRect, arm: Double, color: Color) {
        var path = Path()
        let corners: [(CGPoint, CGSize)] = [
            (CGPoint(x: rect.minX, y: rect.minY), CGSize(width: 1, height: 1)),
            (CGPoint(x: rect.maxX, y: rect.minY), CGSize(width: -1, height: 1)),
            (CGPoint(x: rect.minX, y: rect.maxY), CGSize(width: 1, height: -1)),
            (CGPoint(x: rect.maxX, y: rect.maxY), CGSize(width: -1, height: -1)),
        ]
        for (corner, direction) in corners {
            path.move(to: CGPoint(x: corner.x + direction.width * arm, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + direction.height * arm))
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .square))
    }

    private static func drawTickColumn(in context: inout GraphicsContext, x: Double, top: Double, bottom: Double, flip: Bool, time: TimeInterval, accent: Color, speed: Double) {
        let step = 5.0
        var ticks = Path()
        var y = top
        while y <= bottom {
            ticks.move(to: CGPoint(x: x, y: y))
            ticks.addLine(to: CGPoint(x: x + (flip ? -6 : 6), y: y))
            y += step
        }
        context.stroke(ticks, with: .color(Palette.muted.opacity(0.5)), style: StrokeStyle(lineWidth: 0.9))

        var spine = Path()
        spine.move(to: CGPoint(x: x + (flip ? -8 : 8), y: top - 3))
        spine.addLine(to: CGPoint(x: x + (flip ? -8 : 8), y: bottom + 3))
        context.stroke(spine, with: .color(Palette.muted.opacity(0.28)), style: StrokeStyle(lineWidth: 0.8))

        // A marca vermelha que corre a régua — o "scanner".
        let count = Int((bottom - top) / step)
        let index = Int(time * speed) % (count + 1)
        let markY = top + Double(index) * step
        context.fill(
            Path(CGRect(x: x + (flip ? -7 : 0), y: markY - 1.3, width: 7, height: 2.6)),
            with: .color(accent.opacity(0.95))
        )
    }

    private static func drawCyberdyneLogo(in context: inout GraphicsContext, origin: CGPoint, accent: Color) {
        var triangle = Path()
        triangle.move(to: CGPoint(x: origin.x + 6, y: origin.y))
        triangle.addLine(to: CGPoint(x: origin.x + 12, y: origin.y + 10.5))
        triangle.addLine(to: CGPoint(x: origin.x, y: origin.y + 10.5))
        triangle.closeSubpath()
        context.fill(triangle, with: .color(accent.opacity(0.95)))

        var inner = Path()
        inner.move(to: CGPoint(x: origin.x + 6, y: origin.y + 4))
        inner.addLine(to: CGPoint(x: origin.x + 9.1, y: origin.y + 9.4))
        inner.addLine(to: CGPoint(x: origin.x + 2.9, y: origin.y + 9.4))
        inner.closeSubpath()
        context.fill(inner, with: .color(Palette.background))

        let style = { (text: String) in
            Text(text).font(.system(size: 6.8, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.muted.opacity(0.95))
        }
        context.draw(style("CYBERDYNE"), at: CGPoint(x: origin.x + 16.5, y: origin.y + 4), anchor: .leading)
        context.draw(style("SYSTEMS"), at: CGPoint(x: origin.x + 16.5, y: origin.y + 11), anchor: .leading)
    }

    private static func drawGlyphs(in context: inout GraphicsContext, size: CGSize, accent: Color, dim: Bool) {
        let gray = Palette.muted.opacity(dim ? 0.2 : 0.6)
        let red = accent.opacity(dim ? 0.3 : 0.9)
        let w = size.width, h = size.height

        // Canto superior direito: pequena marca vermelha + linhas de "texto".
        var mark = Path()
        mark.move(to: CGPoint(x: w * 0.775, y: h * 0.165))
        mark.addLine(to: CGPoint(x: w * 0.775, y: h * 0.192))
        mark.addLine(to: CGPoint(x: w * 0.805, y: h * 0.192))
        context.stroke(mark, with: .color(red), style: StrokeStyle(lineWidth: 1.6))
        for (index, width) in [0.09, 0.06, 0.075].enumerated() {
            context.fill(
                Path(CGRect(x: w * 0.825, y: h * (0.165 + Double(index) * 0.016), width: w * width, height: 2.2)),
                with: .color(gray)
            )
        }

        // Canto inferior esquerdo: chevrons vermelhos + barras.
        var chevrons = Path()
        chevrons.move(to: CGPoint(x: w * 0.10, y: h * 0.575))
        chevrons.addLine(to: CGPoint(x: w * 0.078, y: h * 0.59))
        chevrons.addLine(to: CGPoint(x: w * 0.10, y: h * 0.605))
        chevrons.move(to: CGPoint(x: w * 0.128, y: h * 0.575))
        chevrons.addLine(to: CGPoint(x: w * 0.106, y: h * 0.59))
        chevrons.addLine(to: CGPoint(x: w * 0.128, y: h * 0.605))
        context.stroke(chevrons, with: .color(red), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        context.fill(Path(CGRect(x: w * 0.15, y: h * 0.572, width: w * 0.09, height: 2.2)), with: .color(gray))
        context.fill(Path(CGRect(x: w * 0.15, y: h * 0.6, width: w * 0.06, height: 2.2)), with: .color(gray))

        // Canto inferior direito: blocos de estado.
        context.fill(Path(CGRect(x: w * 0.755, y: h * 0.60, width: 10, height: 6)), with: .color(gray))
        context.fill(Path(CGRect(x: w * 0.755 + 12, y: h * 0.60, width: 10, height: 6)), with: .color(gray))
        context.fill(Path(CGRect(x: w * 0.755 + 24, y: h * 0.60, width: 10, height: 6)), with: .color(red))
        context.fill(Path(CGRect(x: w * 0.80, y: h * 0.575, width: 11, height: 2.2)), with: .color(red))
    }

    // MARK: anel retícula

    private static func drawReticle(in context: inout GraphicsContext, center: CGPoint, radius r: Double, time: TimeInterval, pose: AvatarPose, glitch: Double) {
        let ringRect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        let flick = pose.hudGlitch && glitch > 0.72

        context.stroke(
            Path(ellipseIn: ringRect),
            with: .color(Palette.muted.opacity(flick ? 0.2 : 0.55)),
            style: StrokeStyle(lineWidth: 1.4)
        )

        // Arco tracejado rotativo — a "mira" que nunca pára quieta.
        if pose.ringSpeed > 0 {
            var rotating = context
            rotating.translateBy(x: center.x, y: center.y)
            rotating.rotate(by: .degrees(time * pose.ringSpeed))
            rotating.translateBy(x: -center.x, y: -center.y)
            rotating.stroke(
                Path(ellipseIn: ringRect),
                with: .color(pose.accent.opacity(0.75)),
                style: StrokeStyle(lineWidth: 1.6, dash: [6, 15])
            )
        }

        // Arco de progresso real enquanto o hub pensa.
        if let progress = pose.ringProgress {
            var arc = Path()
            arc.addArc(
                center: center, radius: r,
                startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(1, max(0, progress))),
                clockwise: false
            )
            context.stroke(arc, with: .color(pose.accent), style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
        }

        // Segmento vermelho fixo no quadrante inferior esquerdo (como no visor).
        var segment = Path()
        segment.addArc(center: center, radius: r, startAngle: .degrees(118), endAngle: .degrees(162), clockwise: false)
        context.stroke(segment, with: .color(pose.accent.opacity(0.9)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))

        // Cruzes de mira nos quatro pontos cardeais.
        let pulse = 0.55 + 0.4 * (0.5 + 0.5 * sin(time * 2.2))
        var cross = Path()
        for angle in [0.0, .pi / 2, .pi, 3 * .pi / 2] {
            let dir = CGPoint(x: cos(angle), y: sin(angle))
            let outer = CGPoint(x: center.x + dir.x * (r + 9), y: center.y + dir.y * (r + 9))
            let inner = CGPoint(x: center.x + dir.x * (r + 3), y: center.y + dir.y * (r + 3))
            cross.move(to: outer)
            cross.addLine(to: inner)
        }
        context.stroke(cross, with: .color(pose.accent.opacity(pulse)), style: StrokeStyle(lineWidth: 1.8, lineCap: .square))
    }

    // MARK: scanline (a enviar)

    private static func drawScanLine(in context: inout GraphicsContext, center: CGPoint, radius r: Double, time: TimeInterval, pose: AvatarPose) {
        let sweep = (time * 38).truncatingRemainder(dividingBy: 100)
        let y = center.y - r + 6 + sweep * ((r * 2 - 12) / 100)
        let half = r * 0.94

        context.fill(
            Path(CGRect(x: center.x - half, y: y - 8, width: half * 2, height: 8)),
            with: .linearGradient(
                Gradient(colors: [.clear, pose.accent.opacity(0.14)]),
                startPoint: CGPoint(x: center.x, y: y - 8),
                endPoint: CGPoint(x: center.x, y: y)
            )
        )
        context.fill(
            Path(CGRect(x: center.x - half, y: y, width: half * 2, height: 1.4)),
            with: .linearGradient(
                Gradient(colors: [.clear, pose.accent.opacity(0.9), .clear]),
                startPoint: CGPoint(x: center.x - half, y: y),
                endPoint: CGPoint(x: center.x + half, y: y)
            )
        )
    }

    // MARK: o crânio T-800

    private static func drawSkull(in context: inout GraphicsContext, center c: CGPoint, unit u: Double, time: TimeInterval, pose: AvatarPose, glitch: Double) {
        // A cabeça roda/escala como um todo: varredura, inclinação e a queda na falha.
        var head = context
        head.translateBy(x: c.x, y: c.y)
        head.rotate(by: .radians(pose.headTilt))
        head.scaleBy(x: pose.headScale, y: pose.headScale)
        head.translateBy(x: -c.x, y: -c.y)

        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: c.x + x * u, y: c.y + y * u) }
        let b = pose.chrome
        let chromeLight = Color(red: 0.84 * b, green: 0.87 * b, blue: 0.92 * b)
        let chromeMid = Color(red: 0.56 * b, green: 0.61 * b, blue: 0.69 * b)
        let chromeDark = Color(red: 0.28 * b, green: 0.31 * b, blue: 0.39 * b)
        let cavity = Color(red: 0.045, green: 0.05, blue: 0.07)
        let jawDrop = pose.jawOpen * 0.16

        // 1 · Silhueta — cúpula, maçãs, maxila e queixo num só metal.
        var skull = Path()
        skull.move(to: p(0, -1.06))
        skull.addCurve(to: p(0.60, -0.52), control1: p(0.30, -1.09), control2: p(0.52, -0.90))
        skull.addCurve(to: p(0.63, -0.24), control1: p(0.66, -0.44), control2: p(0.65, -0.34))
        skull.addCurve(to: p(0.55, 0.10), control1: p(0.62, -0.10), control2: p(0.60, 0.02))
        skull.addCurve(to: p(0.38, 0.66), control1: p(0.52, 0.30), control2: p(0.46, 0.50))
        skull.addCurve(to: p(0.24, 0.99), control1: p(0.34, 0.82), control2: p(0.30, 0.92))
        skull.addQuadCurve(to: p(-0.24, 0.99), control: p(0, 1.12))
        skull.addCurve(to: p(-0.38, 0.66), control1: p(-0.30, 0.92), control2: p(-0.34, 0.82))
        skull.addCurve(to: p(-0.55, 0.10), control1: p(-0.46, 0.50), control2: p(-0.52, 0.30))
        skull.addCurve(to: p(-0.63, -0.24), control1: p(-0.60, 0.02), control2: p(-0.62, -0.10))
        skull.addCurve(to: p(-0.60, -0.52), control1: p(-0.65, -0.34), control2: p(-0.66, -0.44))
        skull.addCurve(to: p(0, -1.06), control1: p(-0.52, -0.90), control2: p(-0.30, -1.09))
        skull.closeSubpath()

        head.fill(
            skull,
            with: .linearGradient(
                Gradient(colors: [chromeLight, chromeMid, chromeDark]),
                startPoint: p(-0.4, -1.0), endPoint: p(0.4, 1.05)
            )
        )
        head.stroke(skull, with: .color(cavity.opacity(0.6)), style: StrokeStyle(lineWidth: 1))

        // Brilho especular no topo esquerdo da cúpula.
        let gloss = Path(ellipseIn: CGRect(x: c.x - 0.48 * u, y: c.y - 1.02 * u, width: 0.52 * u, height: 0.30 * u))
        head.fill(gloss, with: .color(.white.opacity(0.07)))

        // 2 · Faixa das sobrancelhas + placa da testa.
        var brow = Path()
        brow.move(to: p(-0.60, -0.34))
        brow.addQuadCurve(to: p(0.60, -0.34), control: p(0, -0.47))
        brow.addLine(to: p(0.58, -0.15))
        brow.addQuadCurve(to: p(-0.58, -0.15), control: p(0, -0.23))
        brow.closeSubpath()
        head.fill(brow, with: .color(chromeMid.opacity(0.85)))
        head.stroke(brow, with: .color(cavity.opacity(0.45)), style: StrokeStyle(lineWidth: 0.8))

        var plate = Path()
        plate.move(to: p(-0.17, -0.52))
        plate.addLine(to: p(0.17, -0.52))
        plate.addLine(to: p(0.11, -0.30))
        plate.addQuadCurve(to: p(-0.11, -0.30), control: p(0, -0.26))
        plate.closeSubpath()
        head.fill(plate, with: .color(chromeDark))
        head.stroke(plate, with: .color(cavity.opacity(0.5)), style: StrokeStyle(lineWidth: 0.6))

        // 3 · Órbitas + olhos vermelhos.
        let eyeOut = pose.eyeFlicker && glitch > 0.62
        for side in [-1.0, 1.0] {
            let socketCenter = p(side * 0.30, 0.03)
            func s(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: socketCenter.x + x * u, y: socketCenter.y + y * u)
            }
            var socket = Path()
            socket.move(to: s(-0.175, -0.09))
            socket.addLine(to: s(-0.10, -0.15))
            socket.addLine(to: s(0.13, -0.135))
            socket.addLine(to: s(0.185, -0.02))
            socket.addLine(to: s(0.13, 0.115))
            socket.addLine(to: s(-0.10, 0.14))
            socket.addLine(to: s(-0.185, 0.01))
            socket.closeSubpath()
            head.fill(socket, with: .color(cavity))
            head.stroke(socket, with: .color(chromeLight.opacity(0.30)), style: StrokeStyle(lineWidth: 0.9))

            let thisSideOut = eyeOut && side > 0
            let glow = pose.eyeGlow * (thisSideOut ? 0.15 : 1)
            let eyeCenter = CGPoint(
                x: socketCenter.x + pose.eyeLook.width,
                y: socketCenter.y + pose.eyeLook.height
            )
            let eyeR = 0.105 * u * pose.eyeScale

            // Halo vermelho à volta da pupila.
            let haloR = eyeR * (2.2 + glow * 0.6)
            head.fill(
                Path(ellipseIn: CGRect(x: eyeCenter.x - haloR, y: eyeCenter.y - haloR, width: haloR * 2, height: haloR * 2)),
                with: .radialGradient(
                    Gradient(colors: [pose.accent.opacity(0.45 * glow), .clear]),
                    center: eyeCenter, startRadius: eyeR * 0.3, endRadius: haloR
                )
            )
            // A pupila: núcleo quente → vermelho → borda profunda.
            head.fill(
                Path(ellipseIn: CGRect(x: eyeCenter.x - eyeR, y: eyeCenter.y - eyeR, width: eyeR * 2, height: eyeR * 2)),
                with: .radialGradient(
                    Gradient(colors: [
                        Color(red: 1, green: 0.72, blue: 0.66).opacity(0.35 + 0.65 * glow),
                        pose.accent.opacity(0.55 + 0.45 * glow),
                        Color(red: 0.42, green: 0.02, blue: 0.03),
                    ]),
                    center: CGPoint(x: eyeCenter.x - eyeR * 0.2, y: eyeCenter.y - eyeR * 0.2),
                    startRadius: eyeR * 0.08, endRadius: eyeR
                )
            )
            head.stroke(
                Path(ellipseIn: CGRect(x: eyeCenter.x - eyeR, y: eyeCenter.y - eyeR, width: eyeR * 2, height: eyeR * 2)),
                with: .color(cavity.opacity(0.8)), style: StrokeStyle(lineWidth: 0.8)
            )

            // Parafuso no exterior da órbita.
            let bolt = p(side * 0.615, -0.01)
            head.fill(
                Path(ellipseIn: CGRect(x: bolt.x - 0.018 * u, y: bolt.y - 0.018 * u, width: 0.036 * u, height: 0.036 * u)),
                with: .color(cavity.opacity(0.85))
            )
        }

        // 4 · Nariz — a fenda escura em seta.
        var nose = Path()
        nose.move(to: p(0, 0.14))
        nose.addLine(to: p(0.055, 0.40))
        nose.addQuadCurve(to: p(-0.055, 0.40), control: p(0, 0.47))
        nose.closeSubpath()
        head.fill(nose, with: .color(cavity))

        // 5 · Maçãs do rosto — painéis escuros que afunilam para a maxila.
        for side in [-1.0, 1.0] {
            var cheek = Path()
            cheek.move(to: p(side * 0.20, 0.24))
            cheek.addLine(to: p(side * 0.52, 0.14))
            cheek.addLine(to: p(side * 0.46, 0.44))
            cheek.addQuadCurve(to: p(side * 0.24, 0.42), control: p(side * 0.34, 0.36))
            cheek.closeSubpath()
            head.fill(cheek, with: .color(chromeDark.opacity(0.5)))
        }

        // 6 · Cavidade da boca + dentes superiores (fixos no crânio).
        let mouth = CGRect(x: c.x - 0.28 * u, y: c.y + 0.47 * u, width: 0.56 * u, height: (0.30 + jawDrop) * u)
        head.fill(Path(roundedRect: mouth, cornerRadius: 0.05 * u), with: .color(cavity))
        drawTeethRow(in: &head, center: c, unit: u, top: 0.505, height: 0.125, width: 0.50, count: 6)

        // 7 · Grupo da maxila — dentes inferiores + queixo descem com a fala.
        var jaw = head
        jaw.translateBy(x: 0, y: jawDrop * u)
        drawTeethRow(in: &jaw, center: c, unit: u, top: 0.66, height: 0.095, width: 0.46, count: 6)

        var chin = Path()
        chin.move(to: p(-0.27, 0.78))
        chin.addLine(to: p(0.27, 0.78))
        chin.addQuadCurve(to: p(0.20, 0.97), control: p(0.26, 0.90))
        chin.addQuadCurve(to: p(-0.20, 0.97), control: p(0, 1.06))
        chin.addQuadCurve(to: p(-0.27, 0.78), control: p(-0.26, 0.90))
        chin.closeSubpath()
        jaw.fill(
            chin,
            with: .linearGradient(
                Gradient(colors: [chromeMid, chromeDark]),
                startPoint: p(0, 0.78), endPoint: p(0, 1.0)
            )
        )
        jaw.stroke(chin, with: .color(cavity.opacity(0.5)), style: StrokeStyle(lineWidth: 0.8))

        // 8 · Pistões laterais — esticam quando a maxila desce.
        for side in [-1.0, 1.0] {
            var piston = Path()
            piston.move(to: p(side * 0.47, 0.22))
            piston.addLine(to: p(side * 0.30, 0.68 + jawDrop * 0.7))
            head.stroke(piston, with: .color(chromeDark), style: StrokeStyle(lineWidth: 0.055 * u, lineCap: .round))
            head.stroke(piston, with: .color(chromeLight.opacity(0.55)), style: StrokeStyle(lineWidth: 0.018 * u, lineCap: .round))
        }

        // 9 · Detalhes da cúpula: junta central, placa circular, placa em losango.
        var seam = Path()
        seam.move(to: p(0, -1.05))
        seam.addLine(to: p(0, -0.56))
        head.stroke(seam, with: .color(cavity.opacity(0.5)), style: StrokeStyle(lineWidth: 0.9))

        let plateCenter = p(-0.27, -0.82)
        head.stroke(
            Path(ellipseIn: CGRect(x: plateCenter.x - 0.075 * u, y: plateCenter.y - 0.06 * u, width: 0.15 * u, height: 0.12 * u)),
            with: .color(cavity.opacity(0.6)), style: StrokeStyle(lineWidth: 1)
        )
        head.fill(
            Path(ellipseIn: CGRect(x: plateCenter.x - 0.018 * u, y: plateCenter.y - 0.014 * u, width: 0.036 * u, height: 0.028 * u)),
            with: .color(cavity.opacity(0.6))
        )

        var diamond = Path()
        let d = p(0.31, -0.74)
        diamond.move(to: CGPoint(x: d.x, y: d.y - 0.055 * u))
        diamond.addLine(to: CGPoint(x: d.x + 0.05 * u, y: d.y))
        diamond.addLine(to: CGPoint(x: d.x, y: d.y + 0.055 * u))
        diamond.addLine(to: CGPoint(x: d.x - 0.05 * u, y: d.y))
        diamond.closeSubpath()
        head.fill(diamond, with: .color(chromeDark))
    }

    private static func drawTeethRow(in context: inout GraphicsContext, center c: CGPoint, unit u: Double, top: Double, height: Double, width: Double, count: Int) {
        let gap = 0.012
        let toothWidth = (width - gap * Double(count - 1)) / Double(count)
        let startX = -width / 2
        for index in 0..<count {
            let x = c.x + (startX + Double(index) * (toothWidth + gap)) * u
            let rect = CGRect(x: x, y: c.y + top * u, width: toothWidth * u, height: height * u)
            context.fill(
                Path(roundedRect: rect, cornerRadius: 0.018 * u),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.94, green: 0.95, blue: 0.96),
                        Color(red: 0.72, green: 0.75, blue: 0.80),
                    ]),
                    startPoint: CGPoint(x: x, y: rect.minY),
                    endPoint: CGPoint(x: x, y: rect.maxY)
                )
            )
        }
    }

    // MARK: waveform de pontos

    private static func drawWaveform(in context: inout GraphicsContext, size: CGSize, time: TimeInterval, pose: AvatarPose) {
        let bars = 35
        let left = size.width * 0.12, right = size.width * 0.88
        let pitch = (right - left) / Double(bars - 1)
        let centerY = size.height * 0.745
        let maxHalf = size.height * 0.055
        let dot = 2.2, step = 2.6

        var dots = Path()
        for index in 0..<bars {
            let height = waveHeight(index: index, time: time, pose: pose) * maxHalf
            let stacks = 1 + Int(height / step)
            let x = left + Double(index) * pitch
            for stack in 0..<stacks {
                let dy = Double(stack) * step
                dots.addRect(CGRect(x: x - dot / 2, y: centerY - dy - dot, width: dot, height: dot))
                if stack > 0 {
                    dots.addRect(CGRect(x: x - dot / 2, y: centerY + dy, width: dot, height: dot))
                }
            }
        }
        context.fill(dots, with: .color(pose.accent.opacity(0.92)))
    }

    /// Altura 0…1 de cada barra: soma de senos com períodos não múltiplos, com
    /// rajadas de sílabas na fala e picos avariados na falha.
    private static func waveHeight(index: Int, time: TimeInterval, pose: AvatarPose) -> Double {
        let i = Double(index)
        var value = 0.42 * (0.5 + 0.5 * sin(i * 1.7 + time * 5.1))
        value += 0.35 * (0.5 + 0.5 * sin(i * 0.63 - time * 3.3))
        value += 0.23 * (0.5 + 0.5 * sin(i * 2.9 + time * 7.7))
        if pose.waveSpeech {
            let burst = pow(0.5 + 0.5 * sin(time * 2.9 + sin(time * 0.77) * 2.0), 1.6)
            value *= 0.35 + 0.85 * burst
        }
        if pose.hudGlitch {
            if glitchValue(time + i * 0.13) > 0.86 {
                value = 1
            } else {
                value *= 0.3
            }
        }
        return min(1, value) * pose.waveAmplitude
    }

    // MARK: tempo

    /// Ruído determinístico por fatias de ~110 ms — o glitch da falha sem estado.
    private static func glitchValue(_ time: TimeInterval) -> Double {
        let n = (time * 9).rounded(.down)
        let s = sin(n * 12.9898) * 43758.5453
        return abs(s.truncatingRemainder(dividingBy: 1))
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
    .frame(width: 190, height: 231)
    .background(Palette.background)
}
