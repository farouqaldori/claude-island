import Foundation

struct CodexEvent: Sendable {
    let provider: AgentProvider
    let sessionId: String
    let cwd: String
    let status: String
    let tool: String?
    let toolUseId: String?
    let toolInput: [String: AnyCodable]?
    let timestamp: Date

    init(
        provider: AgentProvider = .codex,
        sessionId: String,
        cwd: String,
        status: String,
        tool: String?,
        toolUseId: String?,
        toolInput: [String: AnyCodable]?,
        timestamp: Date = Date()
    ) {
        self.provider = provider
        self.sessionId = sessionId
        self.cwd = cwd
        self.status = status
        self.tool = tool
        self.toolUseId = toolUseId
        self.toolInput = toolInput
        self.timestamp = timestamp
    }
}
