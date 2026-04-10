//
//  TerminalMultiplexer.swift
//  ClaudeIsland
//

/// The terminal multiplexer a Claude session is running inside
enum TerminalMultiplexer: Equatable, Sendable {
    case tmux
    case zellij
    case none
}
