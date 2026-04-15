import SwiftUI

// MARK: - Spacing / Radius tokens

enum Spacing {
    static let xs: CGFloat = 4
    static let s:  CGFloat = 8
    static let m:  CGFloat = 12
    static let l:  CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl:CGFloat = 32
}

enum Radius {
    static let s:    CGFloat = 6
    static let m:    CGFloat = 10
    static let l:    CGFloat = 14
    static let pill: CGFloat = 999
}

// MARK: - Materials wrappers

enum Surfaces {
    static let chrome: Material  = .regularMaterial
    static let sheet: Material   = .thinMaterial
    static let tooltip: Material = .ultraThinMaterial
}

// MARK: - Motion

enum Motion {
    static let spring: Animation = .interactiveSpring(response: 0.35, dampingFraction: 0.8)
    static let hover:  Animation = .easeInOut(duration: 0.12)
    static let fade:   Animation = .easeInOut(duration: 0.2)
}

// MARK: - Typography

enum Typography {
    static let header = Font.system(size: 15, weight: .semibold, design: .default)
    static let body   = Font.system(size: 13, weight: .regular, design: .default)
    static let small  = Font.system(size: 11, weight: .regular, design: .default)
    static let code   = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let tc     = Font.system(size: 11, weight: .medium,  design: .monospaced) // timecode
}

// MARK: - Accent

enum Palette {
    static let accent = Color(.sRGB, red: 94/255, green: 92/255, blue: 230/255, opacity: 1) // systemIndigo
}
