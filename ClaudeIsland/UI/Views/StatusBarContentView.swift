//
//  StatusBarContentView.swift
//  ClaudeIsland
//
//  SwiftUI view for status bar popover content
//  Wraps existing Notch UI components for display in a popover
//

import SwiftUI

struct StatusBarContentView: View {
    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var sessionMonitor = ClaudeSessionMonitor()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()
                .background(Color.white.opacity(0.1))

            // Content
            contentView
        }
        .frame(width: 400)
        .frame(maxHeight: 500)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear {
            sessionMonitor.startMonitoring()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerView: some View {
        HStack(spacing: 12) {
            ClaudeCrabIcon(size: 14)
                .padding(.leading, 8)

            Text(LString.vibeNotch.localized)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.7))

            Spacer()

            // Menu toggle
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewModel.toggleMenu()
                }
            } label: {
                Image(systemName: viewModel.contentType == .menu ? "xmark" : "line.3.horizontal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            switch viewModel.contentType {
            case .instances:
                ClaudeInstancesView(
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )

            case .menu:
                NotchMenuView(viewModel: viewModel)

            case .chat(let session):
                ChatView(
                    sessionId: session.sessionId,
                    initialSession: session,
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
                .id(session.sessionId)
            }
        }
        .frame(maxHeight: 450)
    }
}