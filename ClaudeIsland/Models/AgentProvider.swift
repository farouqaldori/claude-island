import Foundation

enum AgentProvider: String, CaseIterable, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

extension SessionState {
    var provider: AgentProvider {
        sessionId.hasPrefix("codex:") ? .codex : .claude
    }

    var providerSessionId: String {
        switch provider {
        case .claude:
            return sessionId
        case .codex:
            return String(sessionId.dropFirst("codex:".count))
        }
    }
}
