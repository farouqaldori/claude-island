//
//  PendingQuestion.swift
//  ClaudeIsland
//
//  Models for an AskUserQuestion tool call that is still waiting for an answer.
//
//  Claude Code fires no PreToolUse/PermissionRequest hook for AskUserQuestion —
//  the only real-time signal is the tool_use block landing in the session JSONL.
//  We parse the question set from there and answer it by sending the option's
//  number to the terminal, which is how the picker is driven (a bare digit
//  selects and submits; no Return needed).
//

import Foundation

/// A single selectable option inside a question
struct PendingQuestionOption: Equatable, Sendable {
    let label: String
    let description: String
}

/// One question of an AskUserQuestion tool call
struct PendingQuestion: Equatable, Sendable {
    let header: String
    let question: String
    let multiSelect: Bool
    let options: [PendingQuestionOption]
}

/// The full set of questions for a pending AskUserQuestion tool call
struct PendingQuestionSet: Equatable, Sendable {
    let toolUseId: String
    let questions: [PendingQuestion]

    /// Parse from a ToolCallItem input dictionary.
    /// `input["questions"]` holds the raw JSON array (ConversationParser
    /// serializes non-scalar tool inputs verbatim).
    static func parse(toolUseId: String, input: [String: String]) -> PendingQuestionSet? {
        guard let raw = input["questions"],
              let data = raw.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        let questions: [PendingQuestion] = array.compactMap { dict in
            guard let question = dict["question"] as? String else { return nil }

            let options: [PendingQuestionOption] = (dict["options"] as? [[String: Any]] ?? []).compactMap { opt in
                guard let label = opt["label"] as? String else { return nil }
                return PendingQuestionOption(
                    label: label,
                    description: opt["description"] as? String ?? ""
                )
            }

            guard !options.isEmpty else { return nil }

            return PendingQuestion(
                header: dict["header"] as? String ?? "Question",
                question: question,
                multiSelect: dict["multiSelect"] as? Bool ?? false,
                options: options
            )
        }

        guard !questions.isEmpty else { return nil }
        return PendingQuestionSet(toolUseId: toolUseId, questions: questions)
    }
}
