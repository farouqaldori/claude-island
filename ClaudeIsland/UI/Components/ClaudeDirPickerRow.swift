//
//  ClaudeDirPickerRow.swift
//  ClaudeIsland
//
//  Settings row for choosing Claude's config directory. Expands inline
//  (matching SoundPickerRow / ScreenPickerRow style) with "Auto-detect"
//  and "Choose folder…" options. Default resolution order when auto:
//  CLAUDE_CONFIG_DIR → ~/.config/claude/ → ~/.claude/.
//

import AppKit
import SwiftUI

struct ClaudeDirPickerRow: View {
    @ObservedObject private var selector = ClaudeDirSelector.shared
    @State private var currentValue: String = AppSettings.claudeDirectoryName
    @State private var isHovered: Bool = false

    private var isExpanded: Bool { selector.isPickerExpanded }

    var body: some View {
        VStack(spacing: 0) {
            // Main row - shows current selection
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selector.isPickerExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text(LString.claudeDirectory.localized)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    Text(displayValue)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.middle)

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

            // Expanded options
            if isExpanded {
                VStack(spacing: 2) {
                    ClaudeDirOptionRow(
                        label: LString.autoDetect.localized,
                        sublabel: isCustom ? nil : resolvedAutoDetectPath,
                        isSelected: !isCustom
                    ) {
                        applyChoice(path: "")
                    }

                    ClaudeDirOptionRow(
                        label: LString.chooseFolder.localized,
                        sublabel: isCustom ? displayValue : nil,
                        isSelected: isCustom
                    ) {
                        openFolderPicker()
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
        .onAppear { currentValue = AppSettings.claudeDirectoryName }
    }

    // MARK: - Presentation

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }

    private var isCustom: Bool {
        !currentValue.isEmpty && currentValue != ".claude"
    }

    /// Short display string for the main row's right side.
    private var displayValue: String {
        isCustom ? shortenedPath(currentValue) : LString.autoDetect.localized
    }

    /// What `Auto-detect` actually resolves to right now (for the sublabel).
    private var resolvedAutoDetectPath: String {
        shortenedPath(ClaudePaths.claudeDir.path)
    }

    /// Shortens paths under the user's home directory to `~/…`.
    private func shortenedPath(_ raw: String) -> String {
        let path = raw.hasPrefix("/") ? raw : NSHomeDirectory() + "/" + raw
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Actions

    private func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.title = "Choose Claude Config Directory"
        panel.message = "Select the folder Claude Code uses (typically ~/.claude or ~/.config/claude)."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.canCreateDirectories = false
        panel.directoryURL = ClaudePaths.claudeDir

        // The notch sits at .mainMenu + 3 and would cover the picker. Drop it
        // for the duration of the modal so the panel is on top and
        // interactive, then restore.
        let notchWindow = NSApp.windows.first { $0 is NotchPanel }
        let originalLevel = notchWindow?.level ?? (.mainMenu + 3)
        let wasIgnoring = notchWindow?.ignoresMouseEvents ?? true
        notchWindow?.level = .normal
        notchWindow?.ignoresMouseEvents = true

        let response = panel.runModal()

        notchWindow?.level = originalLevel
        notchWindow?.ignoresMouseEvents = wasIgnoring

        if response == .OK, let url = panel.url {
            applyChoice(path: url.path)
        }
    }

    private func applyChoice(path: String) {
        currentValue = path
        AppSettings.claudeDirectoryName = path
        ClaudePaths.invalidateCache()
        HookInstaller.installIfNeeded()
    }
}

// MARK: - Option Row (Inline)

private struct ClaudeDirOptionRow: View {
    let label: String
    let sublabel: String?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Color.white.opacity(0.2))
                    .frame(width: 6, height: 6)

                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))

                if let sublabel {
                    Text(sublabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if isSelected {
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
