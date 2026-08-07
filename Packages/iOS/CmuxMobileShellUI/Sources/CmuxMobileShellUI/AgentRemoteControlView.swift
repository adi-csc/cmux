#if os(iOS)
import CmuxAgentChat
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import SwiftUI

/// Agent-first mobile control center. It intentionally presents conversations,
/// attention state, and worktree context instead of exposing a remote terminal
/// as the primary interaction model.
struct AgentRemoteControlView: View {
    @Bindable var store: CMUXMobileShellStore
    let openWorkspace: (_ workspaceID: String, _ terminalID: String?) -> Void
    let attentionCountChanged: (Int) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var sessions: [ChatSessionDescriptor] = []
    @State private var route: [AgentRemoteRoute] = []
    @State private var refreshGeneration = 0
    @State private var status: AgentRemoteFeedStatus = .loading

    var body: some View {
        NavigationStack(path: $route) {
            Group {
                if visibleSessions.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
            .navigationTitle("Agents")
            .navigationDestination(for: AgentRemoteRoute.self) { destination in
                if let session = sessions.first(where: { $0.id == destination.sessionID }) {
                    AgentRemoteConversationView(
                        session: session,
                        store: store,
                        workspaceName: workspaceName(for: session),
                        openWorkspace: openWorkspace
                    )
                    .toolbarVisibility(.hidden, for: .tabBar)
                } else {
                    ContentUnavailableView(
                        "Session unavailable",
                        systemImage: "sparkles",
                        description: Text("The agent session is no longer available on your Mac.")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        refreshGeneration &+= 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh agents")
                    .disabled(status == .loading)
                }
            }
        }
        .task(id: feedKey) { await runSessionFeed() }
        .onChange(of: attentionCount, initial: true) { _, count in
            attentionCountChanged(count)
        }
    }

    private var sessionList: some View {
        List {
            Section {
                AgentRemoteSummaryCard(
                    attentionCount: attentionCount,
                    workingCount: workingSessions.count,
                    worktreeCount: activeWorktreeCount,
                    status: status
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            }

            if !attentionSessions.isEmpty {
                Section("Needs you") {
                    rows(attentionSessions)
                }
            }

            if !workingSessions.isEmpty {
                Section("Working") {
                    rows(workingSessions)
                }
            }

            if !readySessions.isEmpty {
                Section("Ready") {
                    rows(readySessions)
                }
            }

            if !recentSessions.isEmpty {
                Section("Recent") {
                    rows(recentSessions)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await refreshSnapshot() }
    }

    @ViewBuilder
    private func rows(_ sessions: [ChatSessionDescriptor]) -> some View {
        ForEach(sessions) { session in
            NavigationLink(value: AgentRemoteRoute(sessionID: session.id)) {
                AgentRemoteSessionRow(
                    session: session,
                    workspaceName: workspaceName(for: session),
                    directoryName: directoryName(for: session)
                )
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptySymbol)
        } description: {
            Text(emptyDescription)
        } actions: {
            if status != .loading {
                Button("Refresh") { refreshGeneration &+= 1 }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var emptyTitle: String {
        switch status {
        case .loading: "Finding agents"
        case .connected: "No agent sessions"
        case .reconnecting: "Reconnecting to your Mac"
        case .unsupported: "Update cmux on your Mac"
        }
    }

    private var emptySymbol: String {
        status == .reconnecting ? "wifi.slash" : "sparkles"
    }

    private var emptyDescription: String {
        switch status {
        case .loading:
            "Looking for Claude and Codex sessions across your worktrees."
        case .connected:
            "Start Claude or Codex in a cmux workspace and it will appear here automatically."
        case .reconnecting:
            "Keep Tailscale connected on this iPhone and your Mac. Existing sessions will return automatically."
        case .unsupported:
            "The connected cmux build does not support agent remote control."
        }
    }

    private var feedKey: String {
        let foreground = scenePhase == .background ? 0 : 1
        let connected = store.connectionState == .connected ? 1 : 0
        return "\(store.agentChatEventSourceIdentity)#\(connected)#\(foreground)#\(refreshGeneration)"
    }

    private var visibleSessions: [ChatSessionDescriptor] {
        sessions.filter { $0.kind == .agent }
    }

    private var attentionSessions: [ChatSessionDescriptor] {
        sorted(visibleSessions.filter { $0.state.needsAttention })
    }

    private var workingSessions: [ChatSessionDescriptor] {
        sorted(visibleSessions.filter {
            if case .working = $0.state { return true }
            return false
        })
    }

    private var readySessions: [ChatSessionDescriptor] {
        sorted(visibleSessions.filter {
            if case .idle = $0.state { return true }
            return false
        })
    }

    private var recentSessions: [ChatSessionDescriptor] {
        Array(sorted(visibleSessions.filter { $0.state == .ended }).prefix(8))
    }

    private var attentionCount: Int { attentionSessions.count }

    private var activeWorktreeCount: Int {
        Set<String>(visibleSessions.compactMap { session -> String? in
            guard session.state != .ended else { return nil }
            return session.workingDirectory ?? session.workspaceID
        }).count
    }

    private func sorted(_ sessions: [ChatSessionDescriptor]) -> [ChatSessionDescriptor] {
        sessions.sorted {
            ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
        }
    }

    private func workspaceName(for session: ChatSessionDescriptor) -> String {
        guard let workspaceID = session.workspaceID else { return "Unknown workspace" }
        return store.workspaces.first {
            $0.id.rawValue == workspaceID || $0.rpcWorkspaceID.rawValue == workspaceID
        }?.name ?? "Workspace"
    }

    private func directoryName(for session: ChatSessionDescriptor) -> String? {
        guard let path = session.workingDirectory, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? url.lastPathComponent : "\(parent)/\(url.lastPathComponent)"
    }

    private func runSessionFeed() async {
        guard scenePhase != .background else { return }
        guard let source = store.makeChatEventSource() else {
            status = .reconnecting
            return
        }

        status = .loading
        var reducer = ChatSessionListReducer(workspaceID: nil)
        let stream = await source.sessionEvents()
        do {
            sessions = try await source.sessions(workspaceID: nil)
            status = .connected
        } catch {
            status = store.chatSessionListFailureMeansUnsupported(error) ? .unsupported : .reconnecting
        }

        for await frame in stream {
            guard !Task.isCancelled else { break }
            let next = reducer.applying(frame, to: sessions)
            if next != sessions {
                withAnimation(.snappy(duration: 0.22)) { sessions = next }
            }
            status = .connected
        }
        if !Task.isCancelled { status = .reconnecting }
    }

    private func refreshSnapshot() async {
        guard let source = store.makeChatEventSource() else {
            status = .reconnecting
            return
        }
        do {
            sessions = try await source.sessions(workspaceID: nil)
            status = .connected
        } catch {
            status = store.chatSessionListFailureMeansUnsupported(error) ? .unsupported : .reconnecting
        }
    }
}

private struct AgentRemoteConversationView: View {
    let session: ChatSessionDescriptor
    @Bindable var store: CMUXMobileShellStore
    let workspaceName: String
    let openWorkspace: (_ workspaceID: String, _ terminalID: String?) -> Void

    @State private var conversation: ChatConversationStore?
    @State private var draft = ""
    @State private var isUnavailable = false

    var body: some View {
        Group {
            if let conversation {
                WorkspaceChatPane(
                    session: session,
                    conversation: conversation,
                    store: store,
                    draft: $draft,
                    onExitChat: openTerminal
                )
            } else if isUnavailable {
                ContentUnavailableView(
                    "Mac unavailable",
                    systemImage: "wifi.slash",
                    description: Text("Reconnect over Tailscale to continue this conversation.")
                )
            } else {
                ProgressView("Loading conversation…")
            }
        }
        .navigationTitle(session.title.nonempty ?? session.agentKind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openTerminal) {
                    Image(systemName: "terminal")
                }
                .accessibilityLabel("Open terminal")
                .disabled(session.workspaceID == nil)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            AgentRemoteConversationContext(
                session: session,
                workspaceName: workspaceName
            )
        }
        .task(id: conversationKey) { await runConversation() }
    }

    private var conversationKey: String {
        "\(session.id)#\(session.version)#\(store.agentChatEventSourceIdentity)"
    }

    private func runConversation() async {
        guard let source = store.makeChatEventSource() else {
            isUnavailable = true
            return
        }
        isUnavailable = false
        let activeConversation: ChatConversationStore
        if let conversation {
            conversation.replaceSource(
                source,
                descriptor: session,
                sourceIdentity: store.agentChatEventSourceIdentity
            )
            activeConversation = conversation
        } else {
            let created = ChatConversationStore(
                descriptor: session,
                source: source,
                sourceIdentity: store.agentChatEventSourceIdentity
            )
            conversation = created
            activeConversation = created
        }
        await activeConversation.run()
    }

    private func openTerminal() {
        guard let workspaceID = session.workspaceID else { return }
        openWorkspace(workspaceID, session.terminalID)
    }
}

private struct AgentRemoteSessionRow: View {
    let session: ChatSessionDescriptor
    let workspaceName: String
    let directoryName: String?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(agentTint.opacity(0.14))
                    .frame(width: 42, height: 42)
                Image(systemName: agentSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(agentTint)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(session.title.nonempty ?? "\(session.agentKind.displayName) session")
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    AgentRemoteStateDot(state: session.state)
                }
                HStack(spacing: 5) {
                    Text(workspaceName)
                    if let directoryName {
                        Text("·")
                        Text(directoryName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)
            if let date = session.lastActivityAt {
                Text(date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var agentSymbol: String {
        session.agentKind == .codex ? "chevron.left.forwardslash.chevron.right" : "sparkles"
    }

    private var agentTint: Color {
        session.agentKind == .codex ? .blue : .orange
    }
}

private struct AgentRemoteSummaryCard: View {
    let attentionCount: Int
    let workingCount: Int
    let worktreeCount: Int
    let status: AgentRemoteFeedStatus

    var body: some View {
        HStack(spacing: 0) {
            metric(value: attentionCount, label: "Need you", tint: attentionCount > 0 ? .orange : .secondary)
            Divider().frame(height: 34)
            metric(value: workingCount, label: "Working", tint: .blue)
            Divider().frame(height: 34)
            metric(value: worktreeCount, label: "Worktrees", tint: .purple)
        }
        .padding(.vertical, 14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(status == .connected ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
                .padding(10)
                .accessibilityLabel(status == .connected ? "Connected" : "Reconnecting")
        }
    }

    private func metric(value: Int, label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value.formatted())
                .font(.title3.weight(.bold))
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AgentRemoteConversationContext: View {
    let session: ChatSessionDescriptor
    let workspaceName: String

    var body: some View {
        HStack(spacing: 8) {
            AgentRemoteStateDot(state: session.state)
            Text(session.agentKind.displayName)
                .fontWeight(.semibold)
            Text("in")
                .foregroundStyle(.secondary)
            Text(workspaceName)
                .lineLimit(1)
            Spacer()
            Text(stateLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var stateLabel: String {
        switch session.state {
        case .needsInput: "Needs input"
        case .working: "Working"
        case .idle: "Ready"
        case .ended: "Ended"
        }
    }
}

private struct AgentRemoteStateDot: View {
    let state: ChatAgentState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                if case .working = state {
                    Circle().stroke(color.opacity(0.3), lineWidth: 4)
                }
            }
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch state {
        case .needsInput: .orange
        case .working: .blue
        case .idle: .green
        case .ended: .secondary
        }
    }

    private var label: String {
        switch state {
        case .needsInput: "Needs input"
        case .working: "Working"
        case .idle: "Ready"
        case .ended: "Ended"
        }
    }
}

private struct AgentRemoteRoute: Hashable {
    let sessionID: String
}

private enum AgentRemoteFeedStatus: Equatable {
    case loading
    case connected
    case reconnecting
    case unsupported
}

private extension Optional where Wrapped == String {
    var nonempty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
#endif
