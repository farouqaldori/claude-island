//
//  SpeechRecognizer.swift
//  ClaudeIsland
//
//  Microphone speech-to-text using macOS Speech framework
//

import AppKit
import AVFoundation
import Combine
import Foundation
import os.log
import Speech

@MainActor
class SpeechRecognizer: ObservableObject {
    static let shared = SpeechRecognizer()

    private static let logger = Logger(subsystem: "com.claudeisland", category: "SpeechRecognizer")

    @Published private(set) var isListening: Bool = false
    @Published private(set) var transcript: String = ""
    @Published private(set) var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @Published private(set) var micDenied: Bool = false

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private init() {
        authorizationStatus = SFSpeechRecognizer.authorizationStatus()
    }

    // MARK: - Authorization

    func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                self?.authorizationStatus = status
                if status == .authorized {
                    Self.logger.info("Speech recognition authorized")
                    // Auto-start listening after authorization is granted
                    self?.startListening()
                } else {
                    Self.logger.warning("Speech recognition denied: \(String(describing: status))")
                }
            }
        }
    }

    // MARK: - Recording

    /// Start listening and transcribing
    func startListening() {
        DebugFileLogger.log("[SpeechRecognizer] startListening called, isListening=\(isListening)")
        guard !isListening else { return }
        micDenied = false

        // Check authorization — request it and auto-start once granted
        DebugFileLogger.log("[SpeechRecognizer] authorizationStatus=\(authorizationStatus.rawValue)")
        if authorizationStatus != .authorized {
            DebugFileLogger.log("[SpeechRecognizer] requesting authorization...")
            requestAuthorization()
            return
        }

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            DebugFileLogger.log("[SpeechRecognizer] speech recognizer NOT available")
            return
        }
        DebugFileLogger.log("[SpeechRecognizer] speech recognizer available")

        // Check microphone permission
        if #available(macOS 14, *) {
            let micPerm = AVAudioApplication.shared.recordPermission
            DebugFileLogger.log("[SpeechRecognizer] mic permission=\(micPerm.rawValue)")
            switch micPerm {
            case .undetermined:
                DebugFileLogger.log("[SpeechRecognizer] requesting mic permission...")
                AVAudioApplication.requestRecordPermission { [weak self] granted in
                    Task { @MainActor in
                        DebugFileLogger.log("[SpeechRecognizer] mic permission result=\(granted)")
                        if granted {
                            self?.startListening()
                        }
                    }
                }
                return
            case .denied:
                DebugFileLogger.log("[SpeechRecognizer] mic permission DENIED, opening System Settings")
                micDenied = true
                // Open Privacy settings for microphone
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

        // Cancel any ongoing task
        recognitionTask?.cancel()
        recognitionTask = nil

        // Set up audio session
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        DebugFileLogger.log("[SpeechRecognizer] audio format: sampleRate=\(recordingFormat.sampleRate), channels=\(recordingFormat.channelCount)")

        // Create recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13, *) {
            request.addsPunctuation = true
        }
        recognitionRequest = request

        // Install audio tap
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        // Start audio engine
        do {
            audioEngine.prepare()
            try audioEngine.start()
            DebugFileLogger.log("[SpeechRecognizer] audio engine started OK")
        } catch {
            DebugFileLogger.log("[SpeechRecognizer] audio engine FAILED: \(error.localizedDescription)")
            cleanup()
            return
        }

        transcript = ""
        isListening = true
        DebugFileLogger.log("[SpeechRecognizer] isListening = true, starting recognition task")

        // Start recognition
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    DebugFileLogger.log("[SpeechRecognizer] partial transcript: \(self.transcript.prefix(80))")
                }

                if let error {
                    DebugFileLogger.log("[SpeechRecognizer] recognition error: \(error.localizedDescription)")
                    self.stopListening()
                }

                if result?.isFinal == true {
                    DebugFileLogger.log("[SpeechRecognizer] final result received")
                    self.stopListening()
                }
            }
        }

        Self.logger.info("Started listening")
    }

    /// Stop listening and return the final transcript
    func stopListening() {
        guard isListening else { return }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil
        isListening = false

        Self.logger.info("Stopped listening, transcript: \(self.transcript.prefix(50))")
    }

    private func cleanup() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
    }
}
