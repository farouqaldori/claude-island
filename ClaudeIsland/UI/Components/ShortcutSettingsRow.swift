//
//  ShortcutSettingsRow.swift
//  ClaudeIsland
//
//  Keyboard shortcut configuration row for settings menu
//

import AppKit
import SwiftUI

struct ShortcutSettingsRow: View {
    @State private var isExpanded = false
    @State private var isHovered = false
    @State private var shortcutsEnabled = AppSettings.shortcutsEnabled
    @State private var approveCombo = AppSettings.approveShortcut
    @State private var denyCombo = AppSettings.denyShortcut
    @State private var recording: ShortcutTarget?

    private enum ShortcutTarget {
        case approve
        case deny
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text("Keyboard Shortcuts")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    Text(shortcutsEnabled ? "On" : "Off")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
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

            // Expanded settings
            if isExpanded {
                VStack(spacing: 6) {
                    // Enable/disable toggle
                    Button {
                        shortcutsEnabled.toggle()
                        AppSettings.shortcutsEnabled = shortcutsEnabled
                        if shortcutsEnabled {
                            // Re-read current combos
                            approveCombo = AppSettings.approveShortcut
                            denyCombo = AppSettings.denyShortcut
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(shortcutsEnabled ? TerminalColors.green : Color.white.opacity(0.2))
                                .frame(width: 6, height: 6)

                            Text("Enabled")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.7))

                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)

                    if shortcutsEnabled {
                        // Approve shortcut
                        ShortcutRecorderRow(
                            label: "Approve",
                            combo: approveCombo,
                            isRecording: recording == .approve
                        ) {
                            recording = recording == .approve ? nil : .approve
                        }

                        // Deny shortcut
                        ShortcutRecorderRow(
                            label: "Deny",
                            combo: denyCombo,
                            isRecording: recording == .deny
                        ) {
                            recording = recording == .deny ? nil : .deny
                        }

                        // Reset to defaults
                        Button {
                            approveCombo = .defaultApprove
                            denyCombo = .defaultDeny
                            AppSettings.approveShortcut = .defaultApprove
                            AppSettings.denyShortcut = .defaultDeny
                            recording = nil
                        } label: {
                            Text("Reset to Defaults")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.4))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
        .background(
            // Invisible key event catcher when recording
            ShortcutRecorderKeyView(isActive: recording != nil) { combo in
                if let target = recording {
                    switch target {
                    case .approve:
                        approveCombo = combo
                        AppSettings.approveShortcut = combo
                    case .deny:
                        denyCombo = combo
                        AppSettings.denyShortcut = combo
                    }
                    recording = nil
                }
            }
            .frame(width: 0, height: 0)
        )
        .onAppear {
            shortcutsEnabled = AppSettings.shortcutsEnabled
            approveCombo = AppSettings.approveShortcut
            denyCombo = AppSettings.denyShortcut
        }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }
}

// MARK: - Shortcut Recorder Row

private struct ShortcutRecorderRow: View {
    let label: String
    let combo: KeyCombo
    let isRecording: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))

                Spacer()

                Text(isRecording ? "Press keys..." : combo.displayString)
                    .font(.system(size: 11, weight: isRecording ? .regular : .semibold, design: .monospaced))
                    .foregroundColor(isRecording ? .white.opacity(0.5) : .white.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isRecording ? Color.white.opacity(0.15) : Color.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(isRecording ? TerminalColors.blue : Color.clear, lineWidth: 1)
                            )
                    )
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

// MARK: - Key Event Catcher (NSView-based for reliable key capture)

private struct ShortcutRecorderKeyView: NSViewRepresentable {
    let isActive: Bool
    let onRecord: (KeyCombo) -> Void

    func makeNSView(context: Context) -> ShortcutKeyCapture {
        let view = ShortcutKeyCapture()
        view.onRecord = onRecord
        return view
    }

    func updateNSView(_ nsView: ShortcutKeyCapture, context: Context) {
        nsView.isActive = isActive
        nsView.onRecord = onRecord
        if isActive {
            // Use local monitor to capture keys in our app
            nsView.startLocalMonitor()
        } else {
            nsView.stopLocalMonitor()
        }
    }
}

class ShortcutKeyCapture: NSView {
    var isActive = false
    var onRecord: ((KeyCombo) -> Void)?
    private var localMonitor: Any?

    func startLocalMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isActive else { return event }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Require at least one modifier key (command, option, control, or shift)
            guard !modifiers.intersection([.command, .option, .control, .shift]).isEmpty else {
                return event
            }

            // Escape cancels recording
            if event.keyCode == 53 { // kVK_Escape
                return nil
            }

            let combo = KeyCombo(keyCode: event.keyCode, modifiers: modifiers)
            self.onRecord?(combo)
            return nil // Consume the event
        }
    }

    func stopLocalMonitor() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    deinit {
        stopLocalMonitor()
    }
}
