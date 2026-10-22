import SwiftUI

/// A small, deliberate palette. One accent per state, low-chroma background so the
/// orb is the only thing that glows on an OLED watch face.
enum Palette {
    static let background = Color(red: 0.020, green: 0.031, blue: 0.047)
    static let surface = Color(red: 0.055, green: 0.074, blue: 0.098)
    static let ink = Color(red: 0.898, green: 0.937, blue: 0.976)
    static let muted = Color(red: 0.494, green: 0.557, blue: 0.639)

    static let mint = Color(red: 0.369, green: 0.949, blue: 0.753)
    static let blue = Color(red: 0.353, green: 0.663, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.478, blue: 0.714)
    static let amber = Color(red: 1.0, green: 0.769, blue: 0.353)
    static let red = Color(red: 1.0, green: 0.420, blue: 0.420)
    static let violet = Color(red: 0.639, green: 0.518, blue: 1.0)
}
