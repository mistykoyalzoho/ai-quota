import SwiftUI

enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex = "codex"                 // OpenAI ChatGPT / Codex
    case claude = "claude"               // Anthropic Claude
    case supergrok = "supergrok"         // xAI SuperGrok / Grok
    case cursor = "cursor"               // Cursor IDE
    case commandcode = "commandcode"     // Command Code CLI
    case copilot = "copilot"             // GitHub Copilot
    case opencodego = "opencodego"       // OpenCode Go plan
    case antigravity = "antigravity"     // Google Antigravity IDE / agy CLI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "OpenAI Codex"
        case .claude: return "Claude Code"
        case .supergrok: return "SuperGrok"
        case .cursor: return "Cursor"
        case .commandcode: return "Command Code"
        case .copilot: return "GitHub Copilot"
        case .opencodego: return "OpenCode Go"
        case .antigravity: return "Antigravity"
        }
    }

    var shortName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .supergrok: return "SuperGrok"
        case .cursor: return "Cursor"
        case .commandcode: return "CmdCode"
        case .copilot: return "Copilot"
        case .opencodego: return "OC Go"
        case .antigravity: return "Antigrav"
        }
    }

    var iconSystemName: String {
        switch self {
        case .codex: return "terminal.fill"
        case .claude: return "sun.max.fill"
        case .supergrok: return "sparkles"
        case .cursor: return "cursorarrow.rays"
        case .commandcode: return "command"
        case .copilot: return "chevron.left.forwardslash.chevron.right"
        case .opencodego: return "shippingbox.fill"
        case .antigravity: return "sparkles.rectangle.stack"
        }
    }

    var primaryAccent: Color {
        switch self {
        case .codex: return Color(red: 0.06, green: 0.65, blue: 0.54)       // OpenAI Green/Teal
        case .claude: return Color(red: 0.85, green: 0.44, blue: 0.28)      // Anthropic Coral
        case .supergrok: return Color(red: 0.55, green: 0.45, blue: 0.95)    // Grok Purple
        case .cursor: return Color(red: 0.20, green: 0.55, blue: 0.95)      // Cursor Blue
        case .commandcode: return Color(red: 0.95, green: 0.55, blue: 0.18) // Command Code Amber
        case .copilot: return Color(red: 0.18, green: 0.72, blue: 0.62)     // Copilot Teal
        case .opencodego: return Color(red: 0.86, green: 0.32, blue: 0.68)  // OpenCode Magenta
        case .antigravity: return Color(red: 0.0, green: 0.82, blue: 0.88)   // Antigravity Cyan
        }
    }

    var defaultPrimaryLabel: String {
        switch self {
        case .codex: return "5h"
        case .claude: return "5h"
        case .supergrok: return "7d"
        case .cursor: return "Plan"
        case .commandcode: return "5h"
        case .copilot: return "Premium"
        case .opencodego: return "5h"
        case .antigravity: return "5h"
        }
    }

    var defaultSecondaryLabel: String {
        switch self {
        case .codex: return "7d"
        case .claude: return "7d"
        case .supergrok: return "Build"
        case .cursor: return "API"
        case .commandcode: return "7d"
        case .copilot: return "Chat"
        case .opencodego: return "7d"
        case .antigravity: return "7d"
        }
    }

    /// Providers that support browser-based sign-in.
    var supportsWebLogin: Bool {
        switch self {
        case .codex, .claude, .supergrok: return true
        case .cursor, .commandcode, .copilot, .opencodego, .antigravity: return false
        }
    }

    /// Providers that can be imported from local CLI / app state.
    var supportsLocalImport: Bool {
        switch self {
        case .codex, .claude, .supergrok, .cursor, .commandcode, .copilot, .opencodego, .antigravity: return true
        }
    }

    /// Providers that support manual credential entry (token/API key).
    var supportsManualEntry: Bool {
        switch self {
        case .antigravity: return true
        default: return false
        }
    }
}
