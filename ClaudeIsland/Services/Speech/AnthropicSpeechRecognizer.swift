//
//  AnthropicSpeechRecognizer.swift
//  ClaudeIsland
//
//  Speech-to-text using Anthropic's voice_stream WebSocket API
//  (same API used by Claude desktop app and Claude Code)
//

import AppKit
import AVFoundation
import Combine
import Foundation
import os.log

@MainActor
class AnthropicSpeechRecognizer: ObservableObject {
    static let shared = AnthropicSpeechRecognizer()

    private static let logger = Logger(subsystem: "com.claudeisland", category: "AnthropicSTT")

    @Published private(set) var isListening: Bool = false
    @Published private(set) var transcript: String = ""
    @Published private(set) var micDenied: Bool = false

    private let audioEngine = AVAudioEngine()
    private var webSocketTask: URLSessionWebSocketTask?
    private var keepAliveTimer: Timer?

    private let sampleRate: Int = 16000

    /// Accumulated finalized text from completed utterances
    private var finalizedText: String = ""
    /// The last partial transcript for the current utterance
    private var lastPartial: String = ""

    private init() {}

    // MARK: - Public API

    func startListening() {
        DebugFileLogger.log("[AnthropicSTT] startListening called, isListening=\(isListening)")
        guard !isListening else { return }
        micDenied = false

        // Check microphone permission
        if #available(macOS 14, *) {
            let micPerm = AVAudioApplication.shared.recordPermission
            DebugFileLogger.log("[AnthropicSTT] mic permission=\(micPerm.rawValue)")
            switch micPerm {
            case .undetermined:
                AVAudioApplication.requestRecordPermission { [weak self] granted in
                    Task { @MainActor in
                        if granted {
                            self?.startListening()
                        } else {
                            self?.micDenied = true
                        }
                    }
                }
                return
            case .denied:
                micDenied = true
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
                return
            case .granted:
                break
            @unknown default:
                break
            }
        }

        Task {
            await connectAndStream()
        }
    }

    func stopListening() {
        guard isListening else { return }
        DebugFileLogger.log("[AnthropicSTT] stopListening")

        // Send CloseStream to finalize
        sendTextMessage("{\"type\":\"CloseStream\"}")

        // Stop audio and clean up
        cleanupAudioAndConnection(closeSocket: true)
    }

    // MARK: - Cleanup

    private func cleanupAudioAndConnection(closeSocket: Bool) {
        // Stop audio engine
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        // Stop keepalive timer
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil

        if closeSocket {
            // Close WebSocket after a brief delay to receive final transcript
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                webSocketTask?.cancel(with: .normalClosure, reason: nil)
                webSocketTask = nil
                await MainActor.run {
                    isListening = false
                }
            }
        } else {
            webSocketTask?.cancel(with: .normalClosure, reason: nil)
            webSocketTask = nil
            isListening = false
        }
    }

    // MARK: - WebSocket Connection

    private func connectAndStream() async {
        do {
            let creds = try await AnthropicBridgeClient.shared.loadCredentials()

            // Build WebSocket URL matching Claude Code's parameters
            var components = URLComponents()
            components.scheme = "wss"
            components.host = "claude.ai"
            components.path = "/api/ws/speech_to_text/voice_stream"
            components.queryItems = [
                URLQueryItem(name: "encoding", value: "linear16"),
                URLQueryItem(name: "sample_rate", value: "\(sampleRate)"),
                URLQueryItem(name: "channels", value: "1"),
                URLQueryItem(name: "endpointing_ms", value: "300"),
                URLQueryItem(name: "utterance_end_ms", value: "1000"),
                URLQueryItem(name: "language", value: "en"),
            ]

            guard let wsURL = components.url else {
                DebugFileLogger.log("[AnthropicSTT] Invalid WebSocket URL")
                return
            }

            DebugFileLogger.log("[AnthropicSTT] Connecting to \(wsURL.absoluteString)")

            var request = URLRequest(url: wsURL)
            request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("cli", forHTTPHeaderField: "x-app")
            if let orgId = creds.organizationId {
                request.setValue(orgId, forHTTPHeaderField: "anthropic-organization")
            }

            let session = URLSession(configuration: .default)
            webSocketTask = session.webSocketTask(with: request)
            webSocketTask?.resume()

            DebugFileLogger.log("[AnthropicSTT] WebSocket connected")

            transcript = ""
            finalizedText = ""
            lastPartial = ""
            isListening = true

            // Send initial KeepAlive
            sendTextMessage("{\"type\":\"KeepAlive\"}")

            // Start periodic KeepAlive (8s like Claude Code)
            keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
                self?.sendTextMessage("{\"type\":\"KeepAlive\"}")
            }

            // Start receiving messages
            receiveMessages()

            // Start audio capture
            startAudioCapture()

        } catch {
            DebugFileLogger.log("[AnthropicSTT] Failed to connect: \(error.localizedDescription)")
            isListening = false
        }
    }

    // MARK: - Audio Capture

    private func startAudioCapture() {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Target format: mono, 16kHz, 16-bit integer (linear16)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: true
        ) else {
            DebugFileLogger.log("[AnthropicSTT] Failed to create target audio format")
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            DebugFileLogger.log("[AnthropicSTT] Failed to create audio converter")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Convert to linear16
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * Double(self.sampleRate) / inputFormat.sampleRate
            )
            guard frameCount > 0,
                  let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
                return
            }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let error {
                DebugFileLogger.log("[AnthropicSTT] Conversion error: \(error.localizedDescription)")
                return
            }

            // Send raw PCM bytes over WebSocket
            if let channelData = convertedBuffer.int16ChannelData {
                let byteCount = Int(convertedBuffer.frameLength) * 2 // 16-bit = 2 bytes per sample
                let data = Data(bytes: channelData[0], count: byteCount)
                self.sendBinaryData(data)
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            DebugFileLogger.log("[AnthropicSTT] Audio engine started, sampleRate=\(sampleRate)")
        } catch {
            DebugFileLogger.log("[AnthropicSTT] Audio engine failed: \(error.localizedDescription)")
            cleanupAudioAndConnection(closeSocket: false)
        }
    }

    // MARK: - WebSocket Messages

    private func receiveMessages() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.handleServerMessage(text)
                case .data:
                    break
                @unknown default:
                    break
                }
                // Continue receiving
                self?.receiveMessages()

            case .failure(let error):
                DebugFileLogger.log("[AnthropicSTT] WebSocket receive error: \(error.localizedDescription)")
                Task { @MainActor in
                    self?.cleanupAudioAndConnection(closeSocket: false)
                }
            }
        }
    }

    private func handleServerMessage(_ text: String) {
        DebugFileLogger.log("[AnthropicSTT] Server message: \(text.prefix(200))")

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        Task { @MainActor in
            switch type {
            case "TranscriptText":
                let partial = (json["data"] as? String ?? json["transcript"] as? String ?? "")
                    .trimmingCharacters(in: .whitespaces)
                if !partial.isEmpty {
                    DebugFileLogger.log("[AnthropicSTT] TranscriptText: \(partial.prefix(80))")

                    // Auto-finalize if this looks like a new segment
                    if !lastPartial.isEmpty {
                        let prev = lastPartial
                        if !partial.hasPrefix(prev) && !prev.hasPrefix(partial) {
                            DebugFileLogger.log("[AnthropicSTT] Auto-finalizing previous segment: \(lastPartial.prefix(60))")
                            finalizedText += (finalizedText.isEmpty ? "" : " ") + lastPartial
                        }
                    }
                    lastPartial = partial
                    transcript = finalizedText.isEmpty ? partial : finalizedText + " " + partial
                }
            case "TranscriptEndpoint":
                let endpointText = lastPartial
                DebugFileLogger.log("[AnthropicSTT] TranscriptEndpoint: \(endpointText.prefix(80))")
                if !endpointText.isEmpty {
                    finalizedText += (finalizedText.isEmpty ? "" : " ") + endpointText
                    lastPartial = ""
                    transcript = finalizedText
                }
            case "TranscriptError":
                let errorMsg = json["description"] as? String ?? json["error_code"] as? String ?? json["error"] as? String ?? "Unknown"
                DebugFileLogger.log("[AnthropicSTT] TranscriptError: \(errorMsg)")
            case "error":
                let errorMsg = json["message"] as? String ?? json["error"] as? String ?? text
                DebugFileLogger.log("[AnthropicSTT] Server error: \(errorMsg)")
                cleanupAudioAndConnection(closeSocket: false)
            default:
                DebugFileLogger.log("[AnthropicSTT] Unknown message type: \(type)")
            }
        }
    }

    private func sendTextMessage(_ text: String) {
        webSocketTask?.send(.string(text)) { error in
            if let error {
                DebugFileLogger.log("[AnthropicSTT] Send error: \(error.localizedDescription)")
            }
        }
    }

    private func sendBinaryData(_ data: Data) {
        webSocketTask?.send(.data(data)) { _ in }
    }
}
