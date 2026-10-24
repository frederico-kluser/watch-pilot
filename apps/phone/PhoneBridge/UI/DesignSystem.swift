import SwiftUI

/// The Cyberdyne palette, shared with the watch visor so the bridge reads as the
/// same product: near-black background, crimson HUD accents, blue for capture.
enum Palette {
    static let background = Color(red: 0.020, green: 0.031, blue: 0.047)
    static let surface = Color(red: 0.055, green: 0.074, blue: 0.098)
    static let ink = Color(red: 0.898, green: 0.937, blue: 0.976)
    static let muted = Color(red: 0.494, green: 0.557, blue: 0.639)
    static let crimson = Color(red: 1.0, green: 0.16, blue: 0.20)
    static let blue = Color(red: 0.353, green: 0.663, blue: 1.0)
    static let mint = Color(red: 0.369, green: 0.949, blue: 0.753)
    static let amber = Color(red: 1.0, green: 0.769, blue: 0.353)
}
