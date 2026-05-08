//
//  PlanDetailView.swift
//  ClaudeIsland
//
//  Full plan content view for the standalone plan window.
//  Uses MarkdownText (swift-markdown) for rich rendering.
//

import SwiftUI

struct PlanDetailView: View {
    var model: PlanContentModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            MarkdownText(model.content, color: .white.opacity(0.85), fontSize: 14)
                .padding(32)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
    }
}
