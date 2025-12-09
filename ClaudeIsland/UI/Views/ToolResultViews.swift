//
//  ToolResultViews.swift
//  ClaudeIsland
//
//  Individual views for rendering each tool's result with proper formatting
//

import SwiftUI

// MARK: - Tool Result Content Dispatcher

struct ToolResultContent: View {
    let tool: ToolCallItem

    var body: some View {
        if let structured = tool.structuredResult {
            switch structured {
            case .read(let r):
                ReadResultContent(result: r)
            case .edit(let r):
                EditResultContent(result: r, toolInput: tool.input)
            case .write(let r):
                WriteResultContent(result: r)
            case .bash(let r):
                BashResultContent(result: r)
            case .grep(let r):
                GrepResultContent(result: r)
            case .glob(let r):
                GlobResultContent(result: r)
            case .todoWrite(let r):
                TodoWriteResultContent(result: r)
            case .task(let r):
                TaskResultContent(result: r)
            case .webFetch(let r):
                WebFetchResultContent(result: r)
            case .webSearch(let r):
                WebSearchResultContent(result: r)
            case .askUserQuestion(let r):
                AskUserQuestionResultContent(result: r)
            case .bashOutput(let r):
                BashOutputResultContent(result: r)
            case .killShell(let r):
                KillShellResultContent(result: r)
            case .exitPlanMode(let r):
                ExitPlanModeResultContent(result: r)
            case .mcp(let r):
                MCPResultContent(result: r)
            case .generic(let r):
                GenericResultContent(result: r)
            }
        } else if tool.name == "Edit" {
            // Special fallback for Edit - show diff from input params
            EditInputDiffView(input: tool.input)
        } else if let result = tool.result {
            // Fallback to raw text display
            GenericTextContent(text: result)
        } else {
            EmptyView()
        }
    }
}

// MARK: - Edit Input Diff View (fallback when no structured result)

struct EditInputDiffView: View {
    let input: [String: String]

    private var filename: String {
        if let path = input["file_path"] {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return "file"
    }

    private var oldString: String {
        input["old_string"] ?? ""
    }

    private var newString: String {
        input["new_string"] ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Show diff from input with integrated filename
            if !oldString.isEmpty || !newString.isEmpty {
                SimpleDiffView(oldString: oldString, newString: newString, filename: filename)
            }
        }
    }
}

// MARK: - Read Result View

struct ReadResultContent: View {
    let result: ReadResult

    var body: some View {
        if !result.content.isEmpty {
            FileCodeView(
                filename: result.filename,
                content: result.content,
                startLine: result.startLine,
                totalLines: result.totalLines,
                maxLines: 10
            )
        }
    }
}

// MARK: - Edit Result View

struct EditResultContent: View {
    let result: EditResult
    var toolInput: [String: String] = [:]

    /// Get old string - prefer result, fallback to input
    private var oldString: String {
        if !result.oldString.isEmpty {
            return result.oldString
        }
        return toolInput["old_string"] ?? ""
    }

    /// Get new string - prefer result, fallback to input
    private var newString: String {
        if !result.newString.isEmpty {
            return result.newString
        }
        return toolInput["new_string"] ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Always use SimpleDiffView for consistent styling (no @@ headers)
            if !oldString.isEmpty || !newString.isEmpty {
                SimpleDiffView(oldString: oldString, newString: newString, filename: result.filename)
            }

            if result.userModified {
                Text("(User modified)")
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.7))
            }
        }
    }
}

// MARK: - Write Result View

struct WriteResultContent: View {
    let result: WriteResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Action and filename
            HStack(spacing: 4) {
                Text(result.type == .create ? "Created" : "Wrote")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                Text(result.filename)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }

            // Content preview for new files
            if result.type == .create && !result.content.isEmpty {
                CodePreview(content: result.content, maxLines: 8)
            } else if let patches = result.structuredPatch, !patches.isEmpty {
                DiffView(patches: patches)
            }
        }
    }
}

// MARK: - Bash Result View

struct BashResultContent: View {
    let result: BashResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Background task indicator
            if let bgId = result.backgroundTaskId {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                    Text("Background task: \(bgId)")
                        .font(.system(size: 10, design: .monospaced))
                }
                .foregroundColor(.blue.opacity(0.7))
            }

            // Return code interpretation
            if let interpretation = result.returnCodeInterpretation {
                Text(interpretation)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }

            // Stdout
            if !result.stdout.isEmpty {
                CodePreview(content: result.stdout, maxLines: 15)
            }

            // Stderr (shown in red)
            if !result.stderr.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("stderr:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.red.opacity(0.7))
                    Text(result.stderr)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.red.opacity(0.8))
                        .lineLimit(10)
                }
            }

            // Empty state
            if !result.hasOutput && result.backgroundTaskId == nil && result.returnCodeInterpretation == nil {
                Text("(No content)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }
}

// MARK: - Grep Result View

struct GrepResultContent: View {
    let result: GrepResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch result.mode {
            case .filesWithMatches:
                // Show file list
                if result.filenames.isEmpty {
                    Text("No matches found")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                } else {
                    FileListView(files: result.filenames, limit: 10)
                }

            case .content:
                // Show matching content
                if let content = result.content, !content.isEmpty {
                    CodePreview(content: content, maxLines: 15)
                } else {
                    Text("No matches found")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                }

            case .count:
                Text("\(result.numFiles) files with matches")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }
}

// MARK: - Glob Result View

struct GlobResultContent: View {
    let result: GlobResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if result.filenames.isEmpty {
                Text("No files found")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
            } else {
                FileListView(files: result.filenames, limit: 10)

                if result.truncated {
                    Text("... and more (truncated)")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
        }
    }
}

// MARK: - TodoWrite Result View

struct TodoWriteResultContent: View {
    let result: TodoWriteResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(result.newTodos.enumerated()), id: \.offset) { _, todo in
                HStack(spacing: 6) {
                    // Status icon
                    Image(systemName: todoIcon(for: todo.status))
                        .font(.system(size: 10))
                        .foregroundColor(todoColor(for: todo.status))
                        .frame(width: 12)

                    Text(todo.content)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(todo.status == "completed" ? 0.4 : 0.7))
                        .strikethrough(todo.status == "completed")
                        .lineLimit(2)
                }
            }
        }
    }

    private func todoIcon(for status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.lefthalf.filled"
        default: return "circle"
        }
    }

    private func todoColor(for status: String) -> Color {
        switch status {
        case "completed": return .green.opacity(0.7)
        case "in_progress": return .orange.opacity(0.7)
        default: return .white.opacity(0.4)
        }
    }
}

// MARK: - Task Result View

struct TaskResultContent: View {
    let result: TaskResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Status and stats
            HStack(spacing: 8) {
                Text(result.status.capitalized)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(statusColor)

                if let duration = result.totalDurationMs {
                    Text("\(formatDuration(duration))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }

                if let tools = result.totalToolUseCount {
                    Text("\(tools) tools")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            // Content summary
            if !result.content.isEmpty {
                Text(result.content.prefix(200) + (result.content.count > 200 ? "..." : ""))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(5)
            }
        }
    }

    private var statusColor: Color {
        switch result.status {
        case "completed": return .green.opacity(0.7)
        case "in_progress": return .orange.opacity(0.7)
        case "failed", "error": return .red.opacity(0.7)
        default: return .white.opacity(0.5)
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        if ms >= 60000 {
            return "\(ms / 60000)m \((ms % 60000) / 1000)s"
        } else if ms >= 1000 {
            return "\(ms / 1000)s"
        }
        return "\(ms)ms"
    }
}

// MARK: - WebFetch Result View

struct WebFetchResultContent: View {
    let result: WebFetchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // URL and status
            HStack(spacing: 6) {
                Text("\(result.code)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(result.code < 400 ? .green.opacity(0.7) : .red.opacity(0.7))

                Text(truncateUrl(result.url))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }

            // Result summary
            if !result.result.isEmpty {
                Text(result.result.prefix(300) + (result.result.count > 300 ? "..." : ""))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(8)
            }
        }
    }

    private func truncateUrl(_ url: String) -> String {
        if url.count > 50 {
            return String(url.prefix(47)) + "..."
        }
        return url
    }
}

// MARK: - WebSearch Result View

struct WebSearchResultContent: View {
    let result: WebSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if result.results.isEmpty {
                Text("No results found")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
            } else {
                ForEach(Array(result.results.prefix(5).enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.blue.opacity(0.8))
                            .lineLimit(1)

                        if !item.snippet.isEmpty {
                            Text(item.snippet)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(2)
                        }
                    }
                }

                if result.results.count > 5 {
                    Text("... and \(result.results.count - 5) more results")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
        }
    }
}

// MARK: - AskUserQuestion Result View

struct AskUserQuestionResultContent: View {
    let result: AskUserQuestionResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(result.questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 4) {
                    // Question
                    Text(question.question)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))

                    // Answer
                    if let answer = result.answers["\(index)"] {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 9))
                            Text(answer)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.green.opacity(0.7))
                    }
                }
            }
        }
    }
}

// MARK: - BashOutput Result View

struct BashOutputResultContent: View {
    let result: BashOutputResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Status
            HStack(spacing: 6) {
                Text("Status: \(result.status)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))

                if let exitCode = result.exitCode {
                    Text("Exit: \(exitCode)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(exitCode == 0 ? .green.opacity(0.6) : .red.opacity(0.6))
                }
            }

            // Output
            if !result.stdout.isEmpty {
                CodePreview(content: result.stdout, maxLines: 10)
            }

            if !result.stderr.isEmpty {
                Text(result.stderr)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.red.opacity(0.7))
                    .lineLimit(5)
            }
        }
    }
}

// MARK: - KillShell Result View

struct KillShellResultContent: View {
    let result: KillShellResult

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark.circle")
                .font(.system(size: 11))
                .foregroundColor(.red.opacity(0.6))

            Text(result.message.isEmpty ? "Shell \(result.shellId) terminated" : result.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
        }
    }
}

// MARK: - ExitPlanMode Result View

struct ExitPlanModeResultContent: View {
    let result: ExitPlanModeResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let path = result.filePath {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundColor(.white.opacity(0.6))
            }

            if let plan = result.plan, !plan.isEmpty {
                Text(plan.prefix(200) + (plan.count > 200 ? "..." : ""))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(6)
            }
        }
    }
}

// MARK: - MCP Result View

struct MCPResultContent: View {
    let result: MCPResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Server and tool info (formatted as Title Case)
            HStack(spacing: 4) {
                Image(systemName: "puzzlepiece")
                    .font(.system(size: 10))
                Text("\(MCPToolFormatter.toTitleCase(result.serverName)) - \(MCPToolFormatter.toTitleCase(result.toolName))")
                    .font(.system(size: 10, design: .monospaced))
            }
            .foregroundColor(.purple.opacity(0.7))

            // Raw result (formatted as key-value pairs)
            ForEach(Array(result.rawResult.prefix(5)), id: \.key) { key, value in
                HStack(alignment: .top, spacing: 4) {
                    Text("\(key):")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                    Text("\(String(describing: value).prefix(100))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(2)
                }
            }
        }
    }
}

// MARK: - Generic Result View

struct GenericResultContent: View {
    let result: GenericResult

    var body: some View {
        if let content = result.rawContent, !content.isEmpty {
            GenericTextContent(text: content)
        } else {
            Text("Completed")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
        }
    }
}

struct GenericTextContent: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.white.opacity(0.5))
            .lineLimit(15)
    }
}

// MARK: - Helper Views

/// File code view with filename header and line numbers (matches Edit tool styling)
struct FileCodeView: View {
    let filename: String
    let content: String
    let startLine: Int
    let totalLines: Int
    let maxLines: Int

    private var lines: [String] {
        content.components(separatedBy: "\n")
    }

    private var displayLines: [String] {
        Array(lines.prefix(maxLines))
    }

    private var hasMoreAfter: Bool {
        lines.count > maxLines
    }

    private var hasLinesBefore: Bool {
        startLine > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Filename header
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                Text(filename)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedCorner(radius: 6, corners: [.topLeft, .topRight]))

            // Top overflow indicator
            if hasLinesBefore {
                Text("...")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 46)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.06))
            }

            // Code lines with line numbers
            ForEach(Array(displayLines.enumerated()), id: \.offset) { index, line in
                let lineNumber = startLine + index
                let isLast = index == displayLines.count - 1 && !hasMoreAfter
                CodeLineView(
                    line: line,
                    lineNumber: lineNumber,
                    isLast: isLast
                )
            }

            // Bottom overflow indicator
            if hasMoreAfter {
                Text("... (\(lines.count - maxLines) more lines)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 46)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedCorner(radius: 6, corners: [.bottomLeft, .bottomRight]))
            }
        }
    }

    private struct CodeLineView: View {
        let line: String
        let lineNumber: Int
        let isLast: Bool

        var body: some View {
            HStack(spacing: 0) {
                // Line number
                Text("\(lineNumber)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(width: 28, alignment: .trailing)
                    .padding(.trailing, 8)

                // Line content
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 4)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedCorner(radius: 6, corners: isLast ? [.bottomLeft, .bottomRight] : []))
        }
    }
}

struct CodePreview: View {
    let content: String
    let maxLines: Int

    var body: some View {
        let lines = content.components(separatedBy: "\n")
        let displayLines = Array(lines.prefix(maxLines))
        let hasMore = lines.count > maxLines

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }

            if hasMore {
                Text("... (\(lines.count - maxLines) more lines)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.top, 2)
            }
        }
    }
}

struct FileListView: View {
    let files: [String]
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(files.prefix(limit).enumerated()), id: \.offset) { _, file in
                HStack(spacing: 4) {
                    Image(systemName: "doc")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.3))
                    Text(URL(fileURLWithPath: file).lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }

            if files.count > limit {
                Text("... and \(files.count - limit) more files")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }
}

struct DiffView: View {
    let patches: [PatchHunk]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(patches.prefix(3).enumerated()), id: \.offset) { _, patch in
                VStack(alignment: .leading, spacing: 1) {
                    // Hunk header
                    Text("@@ -\(patch.oldStart),\(patch.oldLines) +\(patch.newStart),\(patch.newLines) @@")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.cyan.opacity(0.7))

                    // Lines
                    ForEach(Array(patch.lines.prefix(10).enumerated()), id: \.offset) { _, line in
                        DiffLineView(line: line)
                    }

                    if patch.lines.count > 10 {
                        Text("... (\(patch.lines.count - 10) more lines)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
            }

            if patches.count > 3 {
                Text("... and \(patches.count - 3) more hunks")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }
}

struct DiffLineView: View {
    let line: String

    private var lineType: DiffLineType {
        if line.hasPrefix("+") {
            return .added
        } else if line.hasPrefix("-") {
            return .removed
        }
        return .context
    }

    var body: some View {
        Text(line)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(lineType.textColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(lineType.backgroundColor)
    }
}

private enum DiffLineType {
    case added
    case removed
    case context

    var textColor: Color {
        switch self {
        case .added: return Color(red: 0.4, green: 0.8, blue: 0.4)
        case .removed: return Color(red: 0.9, green: 0.5, blue: 0.5)
        case .context: return .white.opacity(0.5)
        }
    }

    var backgroundColor: Color {
        switch self {
        case .added: return Color(red: 0.2, green: 0.4, blue: 0.2).opacity(0.3)
        case .removed: return Color(red: 0.4, green: 0.2, blue: 0.2).opacity(0.3)
        case .context: return .clear
        }
    }
}

struct SimpleDiffView: View {
    let oldString: String
    let newString: String
    var filename: String? = nil

    /// Compute diff using LCS algorithm
    private var diffLines: [DiffLine] {
        let oldLines = oldString.components(separatedBy: "\n")
        let newLines = newString.components(separatedBy: "\n")

        // Compute LCS to find matching lines
        let lcs = computeLCS(oldLines, newLines)

        var result: [DiffLine] = []
        var oldIdx = 0
        var newIdx = 0
        var lcsIdx = 0

        while oldIdx < oldLines.count || newIdx < newLines.count {
            // Limit output
            if result.count >= 12 { break }

            let lcsLine = lcsIdx < lcs.count ? lcs[lcsIdx] : nil

            if oldIdx < oldLines.count && (lcsLine == nil || oldLines[oldIdx] != lcsLine) {
                // Line in old but not in LCS - removed
                result.append(DiffLine(text: oldLines[oldIdx], type: .removed, lineNumber: oldIdx + 1))
                oldIdx += 1
            } else if newIdx < newLines.count && (lcsLine == nil || newLines[newIdx] != lcsLine) {
                // Line in new but not in LCS - added
                result.append(DiffLine(text: newLines[newIdx], type: .added, lineNumber: newIdx + 1))
                newIdx += 1
            } else {
                // Matching line in LCS - skip (context)
                oldIdx += 1
                newIdx += 1
                lcsIdx += 1
            }
        }

        return result
    }

    /// Compute Longest Common Subsequence of two string arrays
    private func computeLCS(_ a: [String], _ b: [String]) -> [String] {
        let m = a.count
        let n = b.count

        // DP table
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to find LCS
        var lcs: [String] = []
        var i = m, j = n
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                lcs.append(a[i - 1])
                i -= 1
                j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        return lcs.reversed()
    }

    private var hasMoreChanges: Bool {
        let oldLines = oldString.components(separatedBy: "\n")
        let newLines = newString.components(separatedBy: "\n")
        let lcs = computeLCS(oldLines, newLines)
        let totalChanges = (oldLines.count - lcs.count) + (newLines.count - lcs.count)
        return totalChanges > 12
    }

    /// Whether there are lines before the first diff line
    private var hasLinesBefore: Bool {
        guard let firstLine = diffLines.first else { return false }
        return firstLine.lineNumber > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Filename header
            if let name = filename {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                    Text(name)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedCorner(radius: 6, corners: [.topLeft, .topRight] as RoundedCorner.RectCorner))
            }

            // Top overflow indicator
            if hasLinesBefore {
                Text("...")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 46)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedCorner(radius: 6, corners: filename == nil ? [.topLeft, .topRight] as RoundedCorner.RectCorner : [] as RoundedCorner.RectCorner))
            }

            // Diff lines
            ForEach(Array(diffLines.enumerated()), id: \.offset) { index, line in
                let isFirst = index == 0 && filename == nil && !hasLinesBefore
                let isLast = index == diffLines.count - 1 && !hasMoreChanges
                DiffLineView(
                    line: line.text,
                    type: line.type,
                    lineNumber: line.lineNumber,
                    isFirst: isFirst,
                    isLast: isLast
                )
            }

            // Bottom overflow indicator
            if hasMoreChanges {
                Text("...")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 46)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedCorner(radius: 6, corners: [.bottomLeft, .bottomRight] as RoundedCorner.RectCorner))
            }
        }
    }

    private struct DiffLine {
        let text: String
        let type: DiffLineType
        let lineNumber: Int
    }

    private struct DiffLineView: View {
        let line: String
        let type: DiffLineType
        let lineNumber: Int
        let isFirst: Bool
        let isLast: Bool

        private var corners: RoundedCorner.RectCorner {
            if isFirst && isLast {
                return .allCorners
            } else if isFirst {
                return [.topLeft, .topRight]
            } else if isLast {
                return [.bottomLeft, .bottomRight]
            }
            return []
        }

        var body: some View {
            HStack(spacing: 0) {
                // Line number
                Text("\(lineNumber)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(type.textColor.opacity(0.6))
                    .frame(width: 28, alignment: .trailing)
                    .padding(.trailing, 4)

                // +/- indicator
                Text(type == .added ? "+" : "-")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(type.textColor)
                    .frame(width: 14)

                // Line content
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(type.textColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 4)
            .padding(.vertical, 2)
            .background(type.backgroundColor)
            .clipShape(RoundedCorner(radius: 6, corners: corners))
        }
    }
}

// Helper for selective corner rounding (macOS compatible)
struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: RectCorner

    struct RectCorner: OptionSet {
        let rawValue: Int
        static let topLeft = RectCorner(rawValue: 1 << 0)
        static let topRight = RectCorner(rawValue: 1 << 1)
        static let bottomLeft = RectCorner(rawValue: 1 << 2)
        static let bottomRight = RectCorner(rawValue: 1 << 3)
        static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let tl = corners.contains(.topLeft) ? radius : 0
        let tr = corners.contains(.topRight) ? radius : 0
        let bl = corners.contains(.bottomLeft) ? radius : 0
        let br = corners.contains(.bottomRight) ? radius : 0

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
                       radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
                       radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 {
            path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
                       radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 {
            path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
                       radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        }
        path.closeSubpath()

        return path
    }
}
