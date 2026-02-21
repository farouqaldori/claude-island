//
//  PythonRuntimeAlert.swift
//  ClaudeIsland
//
//  Handles user-facing alerts for Python runtime issues
//

import AppKit
import os.log

// MARK: - PythonRuntimeAlert

/// Handles user-facing alerts for Python runtime issues
/// MainActor (default) ensures all UI operations happen on the main thread
enum PythonRuntimeAlert {
    // MARK: Internal

    /// Show alert when no suitable Python runtime is available
    static func showUnavailableAlert(reason: PythonRuntimeDetector.UnavailableReason) {
        self.logger.warning("Showing Python runtime unavailable alert: \(String(describing: reason))")

        let alert = NSAlert()
        alert.messageText = "Python Runtime Required"
        alert.informativeText = self.message(for: reason)
        alert.alertStyle = .warning

        alert.addButton(withTitle: "Install uv")
        alert.addButton(withTitle: "Install Python 3.14")
        alert.addButton(withTitle: "Dismiss")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            self.openURL("https://docs.astral.sh/uv/getting-started/installation/")
        case .alertSecondButtonReturn:
            self.openURL("https://www.python.org/downloads/")
        default:
            break
        }
    }

    // MARK: Private

    private nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "PythonRuntimeAlert")

    private static func message(for reason: PythonRuntimeDetector.UnavailableReason) -> String {
        switch reason {
        case .noPythonFound:
            """
            Claude Island hooks require Python 3.14+ or uv to execute.
            Hooks will not function until a suitable runtime is installed.
            """
        case let .pythonTooOld(version):
            """
            Found Python \(version) but Claude Island hooks require Python 3.14+.
            Please upgrade Python or install uv.
            """
        }
    }

    private static func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
