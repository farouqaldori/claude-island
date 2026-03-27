import Foundation

/// Resolves the Claude Code configuration directory.
///
/// Checks in order:
/// 1. `CLAUDE_CONFIG_DIR` environment variable (user override)
/// 2. `~/.config/claude/` (new default since Claude Code v2.1.30+)
/// 3. `~/.claude/` (legacy default)
///
/// Returns the first path that contains a `projects/` subdirectory,
/// or falls back to `~/.claude/` if none match.
enum ClaudeConfigDir {
    static var projectsPath: String {
        // 1. Check environment variable
        if let envDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            let candidate = (envDir as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: candidate + "/projects") {
                return candidate + "/projects"
            }
        }

        let home = NSHomeDirectory()

        // 2. Check new default path (~/.config/claude/)
        let newDefault = home + "/.config/claude/projects"
        if FileManager.default.fileExists(atPath: newDefault) {
            return newDefault
        }

        // 3. Fall back to legacy path (~/.claude/)
        return home + "/.claude/projects"
    }
}
