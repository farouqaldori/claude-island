//
//  SpeechManager.swift
//  ClaudeIsland
//
//  Text-to-speech using macOS `say` command for access to all system voices
//

import Combine
import Foundation
import os.log

/// A voice available via the macOS `say` command
struct SayVoice: Identifiable, Hashable {
    let name: String
    let language: String
    var id: String { name }

    /// Whether this is the Siri voice
    var isSiri: Bool { name.hasPrefix("Voice") }

    /// Display name (show "Siri" instead of "Voice 4")
    var displayName: String {
        if isSiri { return "Siri (\(name))" }
        return name
    }
}

@MainActor
class SpeechManager: NSObject, ObservableObject {
    static let shared = SpeechManager()

    private static let logger = Logger(subsystem: "com.claudeisland", category: "Speech")

    @Published private(set) var isSpeaking: Bool = false

    /// Track the last spoken message ID to avoid repeats
    private var lastSpokenMessageId: String?

    /// The currently running `say` process
    private var sayProcess: Process?

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Speak the given text, stopping any current speech first
    /// Set `force` to true to bypass the readAloudEnabled check (for on-demand playback)
    func speak(_ text: String, messageId: String? = nil, force: Bool = false) {
        // Skip if we already spoke this message
        if let messageId, messageId == lastSpokenMessageId { return }
        if let messageId { lastSpokenMessageId = messageId }

        guard force || AppSettings.readAloudEnabled else { return }

        // Stop any current speech
        stop()

        // Strip markdown formatting for cleaner speech
        let cleanText = stripMarkdown(text)
        guard !cleanText.isEmpty else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")

        var args: [String] = []
        if let voiceName = AppSettings.selectedVoiceId, !voiceName.isEmpty {
            args += ["-v", voiceName]
        }
        args.append(cleanText)
        process.arguments = args

        // Track completion
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                // Only clear if this is still our active process
                if self?.sayProcess === proc {
                    self?.isSpeaking = false
                    self?.sayProcess = nil
                }
            }
        }

        do {
            isSpeaking = true
            sayProcess = process
            try process.run()
            Self.logger.debug("Speaking text (\(cleanText.count) chars) with say command")
        } catch {
            Self.logger.error("Failed to launch say: \(error.localizedDescription)")
            isSpeaking = false
            sayProcess = nil
        }
    }

    /// Stop speaking immediately
    func stop() {
        if let process = sayProcess, process.isRunning {
            process.terminate()
        }
        sayProcess = nil
        isSpeaking = false
    }

    /// Available English voices from the `say` command
    /// Filters out novelty/joke voices and sorts Siri first, then natural voices
    static var availableVoices: [SayVoice] {
        let noveltyNames: Set<String> = [
            "Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles",
            "Cellos", "Good News", "Jester", "Organ", "Superstar",
            "Trinoids", "Whisper", "Wobble", "Zarvox"
        ]

        var voices: [SayVoice] = []

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "?"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return voices }

            for line in output.components(separatedBy: "\n") {
                guard !line.isEmpty else { continue }
                // Format: "Name                lang    # description"
                // The name ends where the language code begins (xx_XX pattern)
                guard let langRange = line.range(of: #"[a-z]{2}_[A-Z]{2}"#, options: .regularExpression) else {
                    continue
                }

                let name = line[line.startIndex..<langRange.lowerBound]
                    .trimmingCharacters(in: .whitespaces)
                let lang = String(line[langRange])

                // Only English voices
                guard lang.hasPrefix("en") else { continue }

                // Skip novelty voices (check base name without locale qualifier)
                let baseName = name.components(separatedBy: " (").first ?? name
                if noveltyNames.contains(baseName) { continue }

                voices.append(SayVoice(name: name, language: lang))
            }
        } catch {
            // Fallback: return a minimal set
            voices = [
                SayVoice(name: "Samantha", language: "en_US"),
                SayVoice(name: "Voice 4", language: "en_US"),
            ]
        }

        // Sort: Siri voices first, then alphabetical
        voices.sort { a, b in
            if a.isSiri != b.isSiri { return a.isSiri }
            return a.name < b.name
        }

        return voices
    }

    // MARK: - Markdown Stripping

    private func stripMarkdown(_ text: String) -> String {
        var result = text

        // Remove code blocks
        result = result.replacingOccurrences(
            of: "```[\\s\\S]*?```",
            with: "",
            options: .regularExpression
        )

        // Remove inline code
        result = result.replacingOccurrences(
            of: "`[^`]+`",
            with: "",
            options: .regularExpression
        )

        // Remove headers
        result = result.replacingOccurrences(
            of: "^#{1,6}\\s+",
            with: "",
            options: .regularExpression
        )

        // Remove bold/italic markers
        result = result.replacingOccurrences(
            of: "[*_]{1,3}",
            with: "",
            options: .regularExpression
        )

        // Remove links [text](url) -> text
        result = result.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\([^)]+\\)",
            with: "$1",
            options: .regularExpression
        )

        // Remove bullet points
        result = result.replacingOccurrences(
            of: "(?m)^[\\s]*[-*+]\\s+",
            with: "",
            options: .regularExpression
        )

        // Collapse whitespace
        result = result.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
