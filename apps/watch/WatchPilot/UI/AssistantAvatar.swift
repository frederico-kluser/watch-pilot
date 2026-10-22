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
    var headYaw: Double      // −1…1: vira a cabeça (aperto + paralaxe das peças)
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
    /// Nível real de fala do T-800 (0…1) medido na reprodução do áudio da resposta.
    /// `-1` mantém a cadência sintética, enquanto o hub devolver texto.
    var speechLevel: Double

    init(
        eyeGlow: Double = 0.72,
        eyeScale: Double = 1,
        eyeLook: CGSize = .zero,
        eyeFlicker: Bool = false,
        jawOpen: Double = 0,
        speaking: Bool = false,
        headTilt: Double = 0,
        headScale: Double = 1,
        headYaw: Double = 0,
        scanning: Bool = false,
        accent: Color = Palette.crimson,
        chrome: Double = 1,
        ringSpeed: Double = 6,
        ringProgress: Double? = nil,
        scanLine: Bool = false,
        hudPulse: Bool = false,
        hudGlitch: Bool = false,
        waveAmplitude: Double = 0.6,
        waveSpeech: Bool = false,
        speechLevel: Double = -1
    ) {
        self.eyeGlow = eyeGlow
        self.eyeScale = eyeScale
        self.eyeLook = eyeLook
        self.eyeFlicker = eyeFlicker
        self.jawOpen = jawOpen
        self.speaking = speaking
        self.headTilt = headTilt
        self.headScale = headScale
        self.headYaw = headYaw
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
        self.speechLevel = speechLevel
    }

    static func forPhase(_ phase: AssistantPhase) -> AvatarPose {
        switch phase {
        case .idle:
            // Em espera: olhos em brasa, cabeça a varrer devagar, waveform calma
            // mas presente — o visor nunca parece desligado.
            return AvatarPose(headYaw: 0.15, scanning: true, ringSpeed: 5)
        case .listening(let power):
            // A ouvir: pupilas abertas e brilhantes, cantos a pulsar, a waveform
            // é o microfone — a amplitude já vem escalada pelo `power`.
            return AvatarPose(
                eyeGlow: 0.85 + power * 0.15, eyeScale: 1.12,
                headScale: 1.02, headYaw: -0.10 + power * 0.12, ringSpeed: 16,
                hudPulse: true, waveAmplitude: 0.25 + power * 0.75
            )
        case .uploading:
            // A enviar: olhar para cima, linha de varredura a subir o anel.
            return AvatarPose(
                eyeGlow: 0.9, eyeLook: CGSize(width: 0, height: -2.6),
                headYaw: 0.05, ringSpeed: 26, scanLine: true, waveAmplitude: 0.4
            )
        case .waiting(let progress, _):
            // A pensar: varredura de busca e o anel mostra o progresso real.
            return AvatarPose(
                eyeGlow: 0.8, headYaw: 0.1, scanning: true,
                ringSpeed: 34, ringProgress: progress, waveAmplitude: 0.35
            )
        case .answering:
            // A responder: a maxila fala e a waveform cospe a voz.
            return AvatarPose(
                eyeGlow: 1, jawOpen: 0.06, speaking: true,
                headYaw: 0.06, ringSpeed: 10, waveAmplitude: 0.9, waveSpeech: true
            )
        case .failed:
            // Falha: metal baço, olho direito a falhar, HUD em glitch.
            return AvatarPose(
                eyeGlow: 0.45, eyeFlicker: true, jawOpen: 0.16, headTilt: -0.06,
                headYaw: -0.08, chrome: 0.72, ringSpeed: 0, hudGlitch: true,
                waveAmplitude: 0.06
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
        // Medido na referência: centro a 43,3 % da altura, meia-altura 30,7 % da largura.
        let skullCenter = CGPoint(x: w / 2, y: h * 0.433)
        let unit = min(h * 0.307, w * 0.3066)
        let ringRadius = w * 0.300

        drawBackdrop(in: &context, center: skullCenter, ringRadius: ringRadius, pose: pose)
        drawHUDFrame(in: &context, size: size, ringRadius: ringRadius, skullCenter: skullCenter, time: time, pose: pose, glitch: glitch)
        drawReticle(in: &context, center: skullCenter, radius: ringRadius, time: time, pose: pose, glitch: glitch)
        drawSkull(in: &context, center: skullCenter, unit: unit, time: time, pose: pose)
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

    // MARK: o crânio T-800

    /// The head is `T800Head`: flat metal traced from the reference visor, driven
    /// by the pose. Everything that changes between states is a number in
    /// `AvatarPose` — the drawing code has no `switch`.
    private static func drawSkull(in context: inout GraphicsContext, center c: CGPoint, unit u: Double, time: TimeInterval, pose: AvatarPose) {
        var head = context
        head.translateBy(x: c.x, y: c.y)
        head.rotate(by: .radians(pose.headTilt))
        head.scaleBy(x: pose.headScale, y: pose.headScale)
        head.translateBy(x: -c.x, y: -c.y)

        let speech = pose.speechLevel >= 0
            ? pose.speechLevel
            : (pose.speaking ? Self.speechEnvelope(time) : 0)
        var p = HeadPose()
        p.eyeGlow = pose.eyeGlow
        p.eyeScale = pose.eyeScale
        p.eyeLook = CGSize(width: pose.eyeLook.width / u, height: pose.eyeLook.height / u)
        p.eyeFlicker = pose.eyeFlicker
        p.jawOpen = pose.jawOpen
        p.speech = pose.speechLevel >= 0 ? speech : speech * pose.waveAmplitude * 1.1
        p.headTilt = 0                        // já aplicado acima
        p.headScale = 1
        p.headYaw = pose.headYaw + (pose.scanning ? sin(time * 0.45) * 0.55 : 0)
        p.nod = sin(time * 1.7) * 0.35 + speech * sin(time * 7.3) * 0.9
        p.chrome = pose.chrome
        p.tear = pose.hudGlitch ? 0.35 + 0.25 * sin(time * 5.1) : 0

        T800Head.draw(in: &head, center: c, unit: u, pose: p, time: time)
    }

    /// Cadência de fala sintética — usada enquanto o hub devolve texto. Quando o
    /// áudio do T-800 tocar no relógio, o nível real entra em `pose.speechLevel`.
    private static func speechEnvelope(_ time: TimeInterval) -> Double {
        let syllable = max(0, sin(time * 7.3)) * (0.45 + 0.55 * (0.5 + 0.5 * sin(time * 1.31)))
        return min(1, 0.15 + syllable)
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
