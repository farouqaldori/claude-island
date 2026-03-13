//
//  VoicePickerRow.swift
//  ClaudeIsland
//
//  Voice selection for read-aloud TTS feature
//

import SwiftUI

struct VoicePickerRow: View {
    @Binding var isEnabled: Bool
    @ObservedObject private var voiceSelector = VoiceSelector.shared
    @State private var isHovered = false
    @State private var selectedVoiceId: String? = AppSettings.selectedVoiceId

    private let voices = SpeechManager.availableVoices

    private var isExpanded: Bool {
        voiceSelector.isPickerExpanded
    }

    private func setExpanded(_ value: Bool) {
        voiceSelector.isPickerExpanded = value
    }

    private var selectedVoiceName: String {
        if let name = selectedVoiceId,
           let voice = voices.first(where: { $0.name == name }) {
            return voice.displayName
        }
        return "Default"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main row - toggle + voice picker
            Button {
                if isEnabled {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        setExpanded(!isExpanded)
                    }
                } else {
                    isEnabled = true
                    AppSettings.readAloudEnabled = true
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.3")
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text("Read Aloud")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    if isEnabled {
                        Text(selectedVoiceName)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                            .lineLimit(1)

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    } else {
                        Circle()
                            .fill(Color.white.opacity(0.3))
                            .frame(width: 6, height: 6)

                        Text("Off")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            // Expanded voice list
            if isExpanded && isEnabled {
                VStack(spacing: 0) {
                    // Disable option
                    VoiceOptionRow(
                        name: "Disable",
                        badge: nil,
                        isSelected: false,
                        isDisableRow: true
                    ) {
                        isEnabled = false
                        AppSettings.readAloudEnabled = false
                        SpeechManager.shared.stop()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            setExpanded(false)
                        }
                    }

                    Divider()
                        .background(Color.white.opacity(0.06))
                        .padding(.vertical, 2)

                    // Voice options
                    ScrollView {
                        VStack(spacing: 2) {
                            VoiceOptionRow(
                                name: "Default",
                                badge: nil,
                                isSelected: selectedVoiceId == nil
                            ) {
                                selectedVoiceId = nil
                                AppSettings.selectedVoiceId = nil
                                previewVoice(nil)
                            }

                            ForEach(voices) { voice in
                                VoiceOptionRow(
                                    name: voice.displayName,
                                    badge: voice.isSiri ? "Siri" : nil,
                                    isSelected: selectedVoiceId == voice.name
                                ) {
                                    selectedVoiceId = voice.name
                                    AppSettings.selectedVoiceId = voice.name
                                    previewVoice(voice.name)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 6 * 32)
                }
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
        .onAppear {
            selectedVoiceId = AppSettings.selectedVoiceId
        }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }

    private func previewVoice(_ voiceName: String?) {
        AppSettings.selectedVoiceId = voiceName
        SpeechManager.shared.speak("Hello, I'm Claude.", messageId: nil, force: true)
    }
}

// MARK: - Voice Option Row

private struct VoiceOptionRow: View {
    let name: String
    let badge: String?
    let isSelected: Bool
    var isDisableRow: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isDisableRow ? Color.clear : (isSelected ? TerminalColors.green : Color.white.opacity(0.2)))
                    .frame(width: 6, height: 6)

                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isDisableRow ? Color.white.opacity(0.5) : Color.white.opacity(isHovered ? 1.0 : 0.7))

                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(TerminalColors.blue.opacity(0.8))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(TerminalColors.blue.opacity(0.15))
                        )
                }

                Spacer()

                if isSelected && !isDisableRow {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(TerminalColors.green)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
