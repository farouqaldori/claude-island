//
//  SoundPickerRow.swift
//  ClaudeIsland
//
//  Notification sound selection picker for settings menu
//

import AppKit
import SwiftUI

// MARK: - SoundPickerRow

struct SoundPickerRow: View {
    // MARK: Internal

    /// SoundSelector is @Observable, so SwiftUI automatically tracks property access
    var soundSelector: SoundSelector

    var body: some View {
        VStack(spacing: 0) {
            // Main row - shows current selection
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.setExpanded(!self.isExpanded)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 12))
                        .foregroundColor(self.textColor)
                        .frame(width: 16)

                    Text("Notification Sound")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(self.textColor)

                    Spacer()

                    Text(self.selectedSound.rawValue)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)

                    Image(systemName: self.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(self.isHovered ? Color.white.opacity(0.08) : Color.clear),
                )
            }
            .buttonStyle(.plain)
            .onHover { self.isHovered = $0 }

            // Expanded sound list
            if self.isExpanded {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(NotificationSound.allCases, id: \.self) { sound in
                            SoundOptionRowInline(
                                sound: sound,
                                isSelected: self.selectedSound == sound,
                            ) {
                                // Play preview sound
                                if let soundName = sound.soundName {
                                    NSSound(named: soundName)?.play()
                                }
                                self.selectedSound = sound
                                AppSettings.notificationSound = sound
                            }
                        }
                    }
                }
                .frame(maxHeight: CGFloat(min(NotificationSound.allCases.count, 6)) * 32)
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
        .onAppear {
            self.selectedSound = AppSettings.notificationSound
        }
    }

    // MARK: Private

    @State private var isHovered = false
    @State private var selectedSound: NotificationSound = AppSettings.notificationSound

    private var isExpanded: Bool {
        self.soundSelector.isPickerExpanded
    }

    private var textColor: Color {
        .white.opacity(self.isHovered ? 1.0 : 0.7)
    }

    private func setExpanded(_ value: Bool) {
        self.soundSelector.isPickerExpanded = value
    }
}

// MARK: - SoundOptionRowInline

private struct SoundOptionRowInline: View {
    // MARK: Internal

    let sound: NotificationSound
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(self.isSelected ? TerminalColors.green : Color.white.opacity(0.2))
                    .frame(width: 6, height: 6)

                Text(self.sound.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(self.isHovered ? 1.0 : 0.7))

                Spacer()

                if self.isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(TerminalColors.green)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(self.isHovered ? Color.white.opacity(0.06) : Color.clear),
            )
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
    }

    // MARK: Private

    @State private var isHovered = false
}
