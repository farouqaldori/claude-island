//
//  PlanPreviewView.swift
//  ClaudeIsland
//
//  Inline plan preview with collapse/expand.
//  Uses MarkdownText (swift-markdown) for rendering.
//

import SwiftUI

struct PlanPreviewView: View {
    let content: String
    var startCollapsed: Bool = false

    @State private var isCollapsed: Bool?

    private var collapsed: Bool {
        isCollapsed ?? startCollapsed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header — tappable toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isCollapsed = !collapsed }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.blue)

                    Text("Plan")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.blue)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.3))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                }
            }
            .buttonStyle(.plain)

            // Markdown content — collapsible, scrollable, selectable
            if !collapsed {
                ScrollView(.vertical, showsIndicators: true) {
                    MarkdownText(content, color: .white.opacity(0.85), fontSize: 12)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(0.04))
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.blue.opacity(0.05))
        )
    }
}
