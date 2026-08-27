import SwiftUI

extension Color {
    // Status colors (AIQuota exact thresholds)
    static let warningAmber = Color(red: 0.96, green: 0.62, blue: 0.04) // >= 85%
    static let critical     = Color(red: 0.92, green: 0.26, blue: 0.21) // >= 95% or limit reached
    static let gaugeAccent  = Color(red: 0.60, green: 0.40, blue: 0.95) // Normal state purple

    // Provider brand accents
    static let codexGreen   = Color(red: 0.06, green: 0.68, blue: 0.54) // OpenAI ChatGPT
    static let claudeCoral  = Color(red: 0.85, green: 0.45, blue: 0.30) // Anthropic Claude
    static let grokPurple   = Color(red: 0.58, green: 0.44, blue: 0.96) // xAI SuperGrok
    static let cursorBlue   = Color(red: 0.20, green: 0.55, blue: 0.95) // Cursor IDE
    static let cmdCodeAmber = Color(red: 0.95, green: 0.55, blue: 0.18) // Command Code
    static let copilotTeal  = Color(red: 0.18, green: 0.72, blue: 0.62) // GitHub Copilot
    static let ocGoMagenta  = Color(red: 0.86, green: 0.32, blue: 0.68) // OpenCode Go
    static let antigravityCyan = Color(red: 0.0, green: 0.82, blue: 0.88) // Antigravity

    static func providerColor(for provider: AIProvider) -> Color {
        switch provider {
        case .codex: return .codexGreen
        case .claude: return .claudeCoral
        case .supergrok: return .grokPurple
        case .cursor: return .cursorBlue
        case .commandcode: return .cmdCodeAmber
        case .copilot: return .copilotTeal
        case .opencodego: return .ocGoMagenta
        case .antigravity: return .antigravityCyan
        }
    }
}
