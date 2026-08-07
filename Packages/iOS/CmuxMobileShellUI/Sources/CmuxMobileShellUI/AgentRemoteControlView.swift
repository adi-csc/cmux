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
    let openActivity: () -> Void
    let activityUnreadCount: Int
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: openActivity) {
                        Image(systemName: activityUnreadCount > 0 ? "bell.badge.fill" : "bell")
                    }
                    .accessibilityLabel("Activity")
                    .accessibilityValue(activityUnreadCount > 0 ? "\(activityUnreadCount) unread" : "No unread activity")
                }
            }
            .navigationDestination(for: AgentRemoteRoute.self) { destination in
                if let session = sessions.first(where: { $0.id == destination.sessionID }) {
                    AgentRemoteConversationView(
                        session: session,
                        store: store,
                        title: displayName(for: session),
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
        }
        .task(id: feedKey) { await runSessionFeed() }
        .onChange(of: attentionCount, initial: true) { _, count in
            attentionCountChanged(count)
        }
    }

    private var sessionList: some View {
        List {
            if status != .connected {
                AgentRemoteConnectionRow(status: status)
            }

            if !activeSessions.isEmpty {
                Section {
                    rows(activeSessions)
                }
            }

            if !recentSessions.isEmpty {
                Section("Recent") {
                    rows(recentSessions)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await refreshSnapshot() }
    }

    @ViewBuilder
    private func rows(_ sessions: [ChatSessionDescriptor]) -> some View {
        ForEach(sessions) { session in
            NavigationLink(value: AgentRemoteRoute(sessionID: session.id)) {
                AgentRemoteSessionRow(
                    session: session,
                    title: displayName(for: session),
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
        let foreground = scenePhase == .active ? 1 : 0
        let connected = store.connectionState == .connected ? 1 : 0
        return "\(store.agentChatEventSourceIdentity)#\(connected)#\(foreground)#\(refreshGeneration)"
    }

    private var visibleSessions: [ChatSessionDescriptor] {
        sessions.filter { $0.kind == .agent }
    }

    private var attentionSessions: [ChatSessionDescriptor] {
        sorted(visibleSessions.filter { $0.state.needsAttention })
    }

    private var activeSessions: [ChatSessionDescriptor] {
        visibleSessions.filter { $0.state != .ended }.sorted {
            if $0.state.needsAttention != $1.state.needsAttention {
                return $0.state.needsAttention
            }
            return ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
        }
    }

    private var recentSessions: [ChatSessionDescriptor] {
        Array(sorted(visibleSessions.filter { $0.state == .ended }).prefix(8))
    }

    private var attentionCount: Int { attentionSessions.count }

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

    /// Prefer the name the user gave the cmux workspace over generic producer
    /// labels such as "Codex Session" or "Claude Session".
    private func displayName(for session: ChatSessionDescriptor) -> String {
        let workspaceName = workspaceName(for: session)
        if workspaceName != "Workspace", workspaceName != "Unknown workspace" {
            return workspaceName
        }
        if let path = session.workingDirectory, !path.isEmpty {
            let directory = URL(fileURLWithPath: path).lastPathComponent
            if !directory.isEmpty { return directory }
        }
        return session.title.nonempty ?? session.agentKind.displayName
    }

    private func directoryName(for session: ChatSessionDescriptor) -> String? {
        guard let path = session.workingDirectory, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? url.lastPathComponent : "\(parent)/\(url.lastPathComponent)"
    }

    private func runSessionFeed() async {
        guard scenePhase == .active else { return }
        if sessions.isEmpty { status = .loading }
        var failureCount = 0

        while !Task.isCancelled, scenePhase == .active {
            guard let source = store.makeChatEventSource() else {
                status = .reconnecting
                await store.reconnectOrRefresh()
                failureCount += 1
                await pauseBeforeRetry(failureCount: failureCount)
                continue
            }

            let stream = await source.sessionEvents()
            do {
                sessions = try await source.sessions(workspaceID: nil)
                status = .connected
                failureCount = 0
            } catch {
                if store.chatSessionListFailureMeansUnsupported(error) {
                    status = .unsupported
                    return
                }
                status = .reconnecting
                failureCount += 1
                await pauseBeforeRetry(failureCount: failureCount)
                continue
            }

            var reducer = ChatSessionListReducer(workspaceID: nil)
            for await frame in stream {
                guard !Task.isCancelled else { return }
                let next = reducer.applying(frame, to: sessions)
                if next != sessions {
                    withAnimation(.snappy(duration: 0.22)) { sessions = next }
                }
                status = .connected
                failureCount = 0
            }
            guard !Task.isCancelled else { return }
            status = .reconnecting
            failureCount += 1
            await pauseBeforeRetry(failureCount: failureCount)
        }
    }

    private func pauseBeforeRetry(failureCount: Int) async {
        let milliseconds = AgentRemoteReconnectPolicy.delayMilliseconds(
            afterFailureCount: failureCount
        )
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    private func refreshSnapshot() async {
        guard let source = store.makeChatEventSource() else {
            status = .reconnecting
            await store.reconnectOrRefresh()
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
    let title: String
    let workspaceName: String
    let openWorkspace: (_ workspaceID: String, _ terminalID: String?) -> Void

    @Environment(\.scenePhase) private var scenePhase
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
                    onExitChat: openTerminal,
                    presentation: .remoteControl
                )
            } else if isUnavailable {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Reconnecting to your Mac…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Loading conversation…")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(conversationSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: openTerminal) {
                        Label("Open terminal", systemImage: "terminal")
                    }
                    .disabled(session.workspaceID == nil)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Conversation actions")
            }
        }
        .task(id: conversationKey) { await runConversation() }
    }

    private var conversationKey: String {
        let foreground = scenePhase == .active ? 1 : 0
        let connected = store.connectionState == .connected ? 1 : 0
        return "\(session.id)#\(session.version)#\(store.agentChatEventSourceIdentity)#\(connected)#\(foreground)"
    }

    private var conversationSubtitle: String {
        guard title != workspaceName,
              workspaceName != "Workspace",
              workspaceName != "Unknown workspace" else {
            return session.agentKind.displayName
        }
        return "\(session.agentKind.displayName) · \(workspaceName)"
    }

    private func runConversation() async {
        guard scenePhase == .active else { return }
        var source = store.makeChatEventSource()
        while source == nil, !Task.isCancelled, scenePhase == .active {
            isUnavailable = true
            await store.reconnectOrRefresh()
            guard !Task.isCancelled else { return }
            source = store.makeChatEventSource()
            if source == nil {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        guard let source, !Task.isCancelled else { return }
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
    let title: String
    let directoryName: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            AgentRemoteStateDot(state: session.state)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(session.agentKind.displayName)
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
}

private struct AgentRemoteConnectionRow: View {
    let status: AgentRemoteFeedStatus

    var body: some View {
        HStack(spacing: 8) {
            if status == .unsupported {
                Image(systemName: "exclamationmark.circle")
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(label)
                .font(.caption)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        switch status {
        case .loading: "Finding conversations…"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        case .unsupported: "Update cmux on your Mac"
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

enum AgentRemoteReconnectPolicy {
    static func delayMilliseconds(afterFailureCount failureCount: Int) -> Int {
        let exponent = min(max(failureCount - 1, 0), 4)
        return min(500 * (1 << exponent), 8_000)
    }
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
